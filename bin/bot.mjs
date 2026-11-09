#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Writable } from 'node:stream';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const runtime = path.join(root, '.runtime');
const stateDir = path.join(runtime, 'openclaw');
const configPath = path.join(stateDir, 'openclaw.json');
const wxDir = path.join(runtime, 'wx');
const keyDir = path.join(runtime, 'keys');
const gatewayToken = path.join(keyDir, 'gateway-token');
const modelKey = path.join(keyDir, 'deepseek-key');
const wxToken = path.join(wxDir, 'api-token');
const portsPath = path.join(runtime, 'ports.json');
const modePath = path.join(runtime, 'mode');
const win = process.platform === 'win32';
const wx = path.join(runtime, 'bin', win ? 'wx.exe' : 'wx');
const openclaw = path.join(root, 'node_modules', 'openclaw', 'openclaw.mjs');
const plugin = path.join(root, 'node_modules', '@agent-wechat', 'agent-wechat');
const channel = 'agent-wechat';
const agent = 'wechat-trial';
const groupPattern = /^[^\s@*]+@chatroom$/;

const help = `Lumeebot 微信群机器人

  node bin/bot.mjs setup [--key-stdin] [--desktop]
  node bin/bot.mjs wx <原生命令及参数>
  node bin/bot.mjs groups <微信 accountId> <群ID@chatroom> [其他群ID...]
  node bin/bot.mjs gateway
  node bin/bot.mjs pause
  node bin/bot.mjs resume
  node bin/bot.mjs status
  node bin/bot.mjs openclaw <诊断命令及参数>

setup 通过隐藏输入读取 DeepSeek API Key，也支持 DEEPSEEK_API_KEY 或 --key-stdin。
第一次 setup 可用 LUMEEBOT_GATEWAY_PORT 和 LUMEEBOT_WX_PORT 设置端口，默认 19789 / 6275。
wx 和 openclaw 命令始终使用本项目的 .runtime 数据目录。
默认初始化服务器模式。Windows 图形启动器使用 setup --desktop，在独立目录中部署。
`;

function childEnv() {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(OPENCLAW_|AGENT_WECHAT_|WX_|DEEPSEEK_API_KEY$)/i.test(key)));
  return { ...env, OPENCLAW_STATE_DIR: stateDir, OPENCLAW_CONFIG_PATH: configPath };
}

function privateDirectory(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('运行数据目录必须是真实目录。');
  if (!win) {
    if (stat.uid !== process.getuid()) throw new Error('运行数据目录必须属于当前系统用户。');
    fs.chmodSync(dir, 0o700);
    return;
  }
  const script = `
$ErrorActionPreference='Stop'
$item=Get-Item -LiteralPath $env:LUMEEBOT_PRIVATE_DIRECTORY -Force
if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Directory is a reparse point'}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true,$false)
foreach($principal in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
$item.SetAccessControl($acl)
`;
  const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
    env: { ...childEnv(), LUMEEBOT_PRIVATE_DIRECTORY: dir }, stdio: 'ignore', windowsHide: true,
  });
  if (result.status !== 0) throw new Error('无法为当前 Windows 用户设置运行目录的私有权限。');
}

function verifyPrivateFile(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('运行文件必须是本地普通文件。');
  if (!win && (stat.uid !== process.getuid() || (stat.mode & 0o077) !== 0)) throw new Error('运行文件权限过宽，请确认所属用户并改为 0600。');
}

function readPrivateFile(file) {
  verifyPrivateFile(file);
  return fs.readFileSync(file, 'utf8').trim();
}

function writePrivateFile(file, content) {
  if (fs.existsSync(file)) verifyPrivateFile(file);
  const temp = `${file}.${randomBytes(6).toString('hex')}.tmp`;
  try {
    fs.writeFileSync(temp, content, { mode: 0o600, flag: 'wx' });
    fs.renameSync(temp, file);
  } finally {
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
}

function checkPort(value) {
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('端口需为 1024 到 65535 的整数。');
  return port;
}

function ports() {
  if (!fs.existsSync(portsPath)) throw new Error('请先运行 node bin/bot.mjs setup。');
  const stored = JSON.parse(readPrivateFile(portsPath));
  return { gateway: checkPort(stored.gateway), wx: checkPort(stored.wx) };
}

function config() {
  if (!fs.existsSync(configPath)) throw new Error('请先运行 node bin/bot.mjs setup。');
  return JSON.parse(readPrivateFile(configPath));
}

function mode() {
  if (!fs.existsSync(modePath)) throw new Error('请先运行 node bin/bot.mjs setup。');
  const stored = readPrivateFile(modePath);
  if (stored !== 'server' && stored !== 'desktop') throw new Error('运行模式配置无效。');
  return stored;
}

function requireServer() {
  if (mode() !== 'server') throw new Error('当前目录已配置为 Windows 桌面模式，请使用桌面启动器管理微信。');
}

function checkInstall() {
  if (!fs.existsSync(openclaw) || !fs.existsSync(wx) || !fs.existsSync(path.join(plugin, 'openclaw.plugin.json'))) {
    throw new Error('依赖尚未准备好，请先执行 npm ci 和 node scripts/prepare-runtime.mjs。');
  }
  const patchedFiles = [
    [path.join(root, 'node_modules', 'openclaw', 'dist', 'builtin-openclaw-Ci5YBsOb.mjs'), '591601148ec889f634d0e87e7cd8a7d281c62e1794ebcee8266e925752cb2f6a'],
    [path.join(plugin, 'dist', 'index.js'), '1b40583ab041195c5c1fd0893340441d05fa19296bbf7842807f5a1458d9b90b'],
  ];
  for (const [file, expected] of patchedFiles) {
    if (!fs.existsSync(file) || createHash('sha256').update(fs.readFileSync(file)).digest('hex') !== expected) {
      throw new Error('本项目的版本化修复尚未应用，请执行 node scripts/prepare-runtime.mjs。');
    }
  }
}

const secret = (provider) => ({ source: 'file', provider, id: 'value' });
const providerFile = (file) => ({ source: 'file', path: file, mode: 'singleValue' });

function initialConfig(gatewayPort) {
  const model = 'deepseek-flash';
  return {
    gateway: { mode: 'local', bind: 'loopback', port: gatewayPort, auth: { mode: 'token', token: secret('gateway-token') } },
    logging: { file: path.join(runtime, 'openclaw.log') },
    secrets: { providers: { 'gateway-token': providerFile(gatewayToken), 'deepseek-key': providerFile(modelKey) } },
    models: { providers: { 'lumeebot-deepseek': {
      baseUrl: 'https://api.deepseek.com/v1',
      api: 'openai-completions',
      apiKey: secret('deepseek-key'),
      models: [{ id: model, name: 'DeepSeek Flash', input: ['text'], contextWindow: 1000000, maxTokens: 8192, reasoning: false }],
    } } },
    plugins: { allow: [channel, 'openai'], load: { paths: [plugin] }, entries: { [channel]: { enabled: true } } },
    agents: {
      defaults: { model: { primary: `lumeebot-deepseek/${model}` }, workspace: path.join(root, 'workspace'), maxConcurrent: 4, heartbeat: { every: '0m' } },
      entries: { [agent]: { name: 'Lumeebot 小羊', workspace: path.join(root, 'workspace'), skills: [], tools: { deny: ['*'] } } },
    },
    session: { groupScope: 'per-group' },
    bindings: [],
    channels: { [channel]: { enabled: false, dmPolicy: 'disabled', groupPolicy: 'open', groups: { '*': { enabled: false } } } },
  };
}

async function readKey(fromStdin) {
  if (fromStdin) {
    const value = await new Promise((resolve, reject) => {
      let input = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (chunk) => {
        input += chunk;
        if (input.length > 4096) { process.stdin.pause(); reject(new Error('输入的 API Key 过长。')); }
      });
      process.stdin.on('end', () => resolve(input));
      process.stdin.on('error', reject);
    });
    return value.trim();
  }
  if (process.env.DEEPSEEK_API_KEY) return process.env.DEEPSEEK_API_KEY.trim();
  if (fs.existsSync(modelKey)) return readPrivateFile(modelKey);
  if (!process.stdin.isTTY) throw new Error('请在终端运行 setup，或用安全的私有管道传给 setup --key-stdin。');
  const muted = new Writable({ write(_chunk, _encoding, done) { done(); } });
  const reader = createInterface({ input: process.stdin, output: muted, terminal: true });
  try {
    process.stderr.write('请输入自己的 DeepSeek API Key（输入不会显示）：');
    return (await reader.question('')).trim();
  } finally {
    reader.close();
    process.stderr.write('\n');
  }
}

function runClaw(args, options = {}) {
  return spawnSync(process.execPath, ['--stack-size=8192', openclaw, ...args], {
    cwd: root, env: childEnv(), windowsHide: true, timeout: 120000,
    encoding: 'utf8', ...options,
  });
}

async function setup(args) {
  if (new Set(args).size !== args.length || args.some((arg) => !['--key-stdin', '--desktop'].includes(arg))) {
    throw new Error('setup 仅接受 --key-stdin 和 --desktop。');
  }
  if (args.includes('--desktop') && !win) throw new Error('桌面启动器只在 Windows 上运行。');
  checkInstall();
  for (const dir of [runtime, stateDir, wxDir, keyDir]) privateDirectory(dir);
  const requestedMode = fs.existsSync(modePath) ? mode() : args.includes('--desktop') ? 'desktop' : 'server';
  if (requestedMode !== 'desktop' && args.includes('--desktop')) throw new Error('此目录已配置为服务器模式。桌面模式请使用另一份仓库目录。');
  const requestedPorts = fs.existsSync(portsPath) ? ports() : {
    gateway: checkPort(process.env.LUMEEBOT_GATEWAY_PORT ?? 19789),
    wx: checkPort(process.env.LUMEEBOT_WX_PORT ?? 6275),
  };
  if (requestedPorts.gateway === requestedPorts.wx) throw new Error('网关和微信服务必须用不同端口。');
  if (requestedMode === 'desktop' && requestedPorts.gateway === 6276) throw new Error('桌面启动器使用微信服务端口 6276，请为网关选择其他端口。');
  const key = await readKey(args.includes('--key-stdin'));
  if (!key || /\s/.test(key) || key.length > 4096) throw new Error('DeepSeek API Key 必须为一个非空值。');
  writePrivateFile(modelKey, `${key}\n`);
  if (!fs.existsSync(gatewayToken)) writePrivateFile(gatewayToken, `${randomBytes(32).toString('hex')}\n`);
  if (!fs.existsSync(portsPath)) writePrivateFile(portsPath, `${JSON.stringify(requestedPorts, null, 2)}\n`);
  if (!fs.existsSync(configPath)) {
    const candidate = path.join(stateDir, `config-${randomBytes(6).toString('hex')}.json`);
    try {
      writePrivateFile(candidate, `${JSON.stringify(initialConfig(requestedPorts.gateway), null, 2)}\n`);
      const result = runClaw(['config', 'validate', '--json'], { env: { ...childEnv(), OPENCLAW_CONFIG_PATH: candidate } });
      if (result.status !== 0) throw new Error('OpenClaw 拒绝初始配置，请核对固定版本与插件安装。');
      fs.renameSync(candidate, configPath);
    } finally {
      if (fs.existsSync(candidate)) fs.unlinkSync(candidate);
    }
  }
  if (!fs.existsSync(modePath)) writePrivateFile(modePath, `${requestedMode}\n`);
  console.log(`设置完成。运行模式 ${requestedMode}，网关端口 ${requestedPorts.gateway}。密钥保存在本机私有目录。`);
}

const nativeArgs = (port) => ['--data-dir', wxDir, '--listen', `127.0.0.1:${port}`, '--server', `http://127.0.0.1:${port}`];

async function nativeJson(port, route, tokenFile = wxToken) {
  const token = readPrivateFile(tokenFile);
  if (!token) throw new Error('微信服务令牌尚未建立，请先启动 wx daemon。');
  const response = await fetch(`http://127.0.0.1:${port}${route}`, {
    headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(8000), redirect: 'error',
  });
  if (!response.ok) throw new Error(`微信服务查询失败（HTTP ${response.status}）。`);
  return response.json();
}

async function fetchGroupIds(port, accountId) {
  const active = new Set();
  const removed = new Set();
  for (const kind of ['groups', 'threads']) {
    const cursors = new Set();
    let cursor;
    do {
      const params = new URLSearchParams({ limit: '200' });
      if (cursor) params.set('cursor', cursor);
      const page = await nativeJson(port, `/v1/accounts/${encodeURIComponent(accountId)}/${kind}?${params}`);
      for (const item of page.items ?? []) {
        const id = kind === 'groups' ? item.id : item.peerId;
        if (!groupPattern.test(id ?? '') || (kind === 'threads' && item.kind !== 'group')) continue;
        if (item.deleted || item.tombstone) removed.add(id);
        else active.add(id);
      }
      cursor = page.nextCursor ?? page.next_cursor;
      if (!cursor) break;
      if (cursors.has(cursor) || cursors.size >= 100) throw new Error('群目录分页未完成，请先同步群目录。');
      cursors.add(cursor);
    } while (cursor);
  }
  for (const id of removed) active.delete(id);
  return active;
}

function patchConfig(patch) {
  const result = runClaw(['config', 'patch', '--stdin'], { input: JSON.stringify(patch), stdio: ['pipe', 'pipe', 'pipe'] });
  if (result.status !== 0) throw new Error('OpenClaw 未能保存配置。请运行 node bin/bot.mjs openclaw config validate 检查。');
}

async function ensureScopedWxToken(port, accountId, digest) {
  const scopedToken = path.join(keyDir, `wx-${digest}-token`);
  const route = `/v1/accounts/${encodeURIComponent(accountId)}`;
  if (fs.existsSync(scopedToken)) {
    try {
      const account = await nativeJson(port, route, scopedToken);
      if (account.id === accountId) return scopedToken;
    } catch {
      // A revoked native grant needs a new token when the owner next enables replies.
    }
  }
  const scopes = ['read', 'media', 'send', 'login', 'read-state'];
  const result = spawnSync(wx, [
    ...nativeArgs(port), '--json', 'tokens', 'create', `lumeebot-${digest.slice(0, 12)}`,
    '--accounts', accountId, ...scopes.flatMap((scope) => ['--scopes', scope]),
  ], { cwd: root, env: childEnv(), windowsHide: true, timeout: 15000, encoding: 'utf8' });
  if (result.status !== 0) throw new Error('未能创建仅限所选账号的微信服务令牌。');
  let token;
  try { ({ token } = JSON.parse(result.stdout)); }
  catch { throw new Error('微信服务令牌响应格式无效。'); }
  if (typeof token !== 'string' || !token || /\s/.test(token)) throw new Error('微信服务令牌响应格式无效。');
  writePrivateFile(scopedToken, `${token}\n`);
  return scopedToken;
}

async function chooseGroups([accountId, ...ids]) {
  requireServer();
  checkInstall();
  const current = config();
  const { wx: port } = ports();
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,119}$/.test(accountId ?? '') || !ids.length || ids.some((id) => !groupPattern.test(id))) {
    throw new Error('用法：groups <微信 accountId> <群ID@chatroom> [其他群ID...]');
  }
  const old = current.channels?.[channel];
  const endpoint = `http://127.0.0.1:${port}`;
  if (old?.enabled && (old.native?.endpoint !== endpoint || old.native?.accountId !== accountId)) {
    throw new Error('当前账号或桌面通道仍在运行，请先用 pause 停用后再切换。');
  }
  if (!fs.existsSync(wxToken)) throw new Error('请先启动本项目的 wx daemon 并完成微信扫码。');
  const account = await nativeJson(port, `/v1/accounts/${encodeURIComponent(accountId)}`);
  if (!account.authenticated || account.connection !== 'online' || !account.ownUsername) throw new Error('请先完成这个微信账号的扫码登录并确认在线。');
  if (!account.contactSyncReady) throw new Error('微信仍在同步，请稍后重试。');
  const known = await fetchGroupIds(port, accountId);
  const selected = [...new Set(ids)];
  if (selected.some((id) => !known.has(id))) throw new Error('有群未出现在该微信账号已同步的目录中，请核对群 ID 并先同步。');
  const digest = createHash('sha256').update(accountId).digest('hex');
  const scopedToken = await ensureScopedWxToken(port, accountId, digest);
  const groups = Object.fromEntries(Object.keys(old?.groups ?? {}).map((id) => [id, null]));
  groups['*'] = { enabled: false };
  for (const id of selected) groups[id] = { enabled: true, requireMention: false };
  // Remove previous WeChat bindings and preserve any local non-WeChat bindings.
  const bindings = (current.bindings ?? []).filter((binding) => binding.match?.channel !== channel);
  for (const id of selected) bindings.push({ agentId: agent, match: { channel, peer: { kind: 'group', id } } });
  patchConfig({
    secrets: { providers: { 'lumeebot-wx': providerFile(scopedToken) } },
    bindings,
    channels: { [channel]: {
      enabled: true, dmPolicy: 'disabled', groupPolicy: 'open', groups,
      native: {
        mode: 'external', endpoint, accountId, token: secret('lumeebot-wx'),
        consumerStateDir: path.join(runtime, 'consumer', `account-${digest}`), readPolicy: 'on_inbound',
      },
    } },
  });
  console.log(`已配置 ${selected.length} 个群。网关启动或重新加载后生效。`);
}

async function status() {
  const current = config();
  const { gateway } = ports();
  const wechat = current.channels?.[channel];
  const ready = await fetch(`http://127.0.0.1:${gateway}/readyz`, { signal: AbortSignal.timeout(2000), redirect: 'error' })
    .then((response) => response.ok ? response.json() : null)
    .then((body) => body?.ready === true)
    .catch(() => false);
  console.log(JSON.stringify({ mode: mode(), gatewayReady: ready, channelEnabled: wechat?.enabled === true, selectedGroupCount: Object.entries(wechat?.groups ?? {}).filter(([id, setting]) => id !== '*' && setting?.enabled).length }, null, 2));
}

function runForeground(file, args, stdio = 'inherit') {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { cwd: root, env: childEnv(), stdio, windowsHide: true });
    const forwardTermination = () => {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    };
    if (!win) process.once('SIGTERM', forwardTermination);
    const removeForwarder = () => process.removeListener('SIGTERM', forwardTermination);
    child.once('error', () => {
      removeForwarder();
      reject(new Error('无法启动本项目的运行程序。'));
    });
    child.once('exit', (code, signal) => {
      removeForwarder();
      resolve(code ?? (signal === 'SIGINT' ? 130 : signal === 'SIGTERM' ? 143 : 1));
    });
  });
}

async function runWx(port, args) {
  const commandArgs = args.filter((arg) => arg !== '--json');
  if (commandArgs[0] !== 'daemon' || commandArgs[1] !== 'start') return runForeground(wx, [...nativeArgs(port), ...args]);
  // The background wx child can keep its inherited output handles open.
  // Use a private log file so callers that capture this wrapper's stdout can finish.
  const logPath = path.join(runtime, 'wx-start.log');
  if (fs.existsSync(logPath)) verifyPrivateFile(logPath);
  const log = fs.openSync(logPath, 'a', 0o600);
  try {
    const code = await runForeground(wx, [...nativeArgs(port), ...args], ['ignore', log, log]);
    if (code !== 0) console.error('微信后台未启动。详情见 .runtime/wx-start.log。');
    else if (args.includes('--json')) return runForeground(wx, [...nativeArgs(port), '--json', 'daemon', 'status']);
    else console.log('微信后台已启动。');
    return code;
  } finally {
    fs.closeSync(log);
  }
}

const [command, ...args] = process.argv.slice(2);
try {
  switch (command) {
    case undefined:
    case 'help':
    case '--help': console.log(help); break;
    case 'setup': await setup(args); break;
    case 'groups': await chooseGroups(args); break;
    case 'pause':
      requireServer();
      config();
      patchConfig({ channels: { [channel]: { enabled: false } } });
      console.log('已保存暂停配置。已运行的网关重新加载后停止群回复。');
      break;
    case 'resume': {
      requireServer();
      const wechat = config().channels?.[channel];
      const selected = Object.entries(wechat?.groups ?? {}).filter(([id, value]) => id !== '*' && value?.enabled).map(([id]) => id);
      await chooseGroups([wechat?.native?.accountId, ...selected]);
      break;
    }
    case 'status': await status(); break;
    case 'gateway':
      if (args.length) throw new Error('gateway 不接受覆盖参数。');
      config();
      checkInstall();
      process.exitCode = await runForeground(process.execPath, ['--stack-size=8192', openclaw, 'gateway', 'run']);
      break;
    case 'wx': {
      requireServer();
      checkInstall();
      const { wx: port } = ports();
      const unsafe = new Set(['--data-dir', '--listen', '--network-listen', '--server', '--server-name', '--local-profile', '--token-file', '--token-stdin', '--server-config', '--config', '--official']);
      if (args.some((value) => unsafe.has(value.split('=')[0]))) throw new Error('wx 包装器使用本项目的本地微信实例，请移除覆盖实例的参数。');
      process.exitCode = await runWx(port, args);
      break;
    }
    case 'openclaw':
      config();
      checkInstall();
      if (!['config', 'channels', 'models', 'logs'].includes(args[0]) || args.some((arg) => /^--(?:profile|dev|url|token|password)(?:=|$)/.test(arg))) {
        throw new Error('openclaw 包装器支持本实例的 config、channels、models 和 logs 命令。');
      }
      process.exitCode = await runForeground(process.execPath, ['--stack-size=8192', openclaw, ...args]);
      break;
    default: throw new Error('未知命令，运行 node bin/bot.mjs help 查看用法。');
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}

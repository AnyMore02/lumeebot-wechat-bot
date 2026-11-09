import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { performance } from 'node:perf_hooks';

const channelId = 'agent-wechat';
const repoRoot = fileURLToPath(new URL('../', import.meta.url));
const runtimeRoot = path.join(repoRoot, '.runtime');
const stateDir = path.join(runtimeRoot, 'openclaw');
const configPath = path.join(stateDir, 'openclaw.json');
const desktopSessions = path.join(runtimeRoot, 'windows-launcher', 'sessions');
const consumerRoot = path.join(stateDir, 'agent-wechat-launcher');
const packageRoot = path.join(repoRoot, 'node_modules', 'openclaw');
const nativePort = 6276;
const nativeEndpoint = `http://127.0.0.1:${nativePort}`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function normalizedPath(value) {
  const absolute = path.resolve(value);
  return process.platform === 'win32' ? absolute.toLowerCase() : absolute;
}

function samePath(left, right) {
  return typeof left === 'string' && normalizedPath(left) === normalizedPath(right);
}

function validDesktopSession(session) {
  return typeof session?.id === 'string' && /^scan-\d{8}-\d{6}-[a-f0-9]{10}$/.test(session.id)
    && session.port === nativePort && samePath(session.root, path.join(desktopSessions, session.id));
}

export function requireDesktopGateway(snapshot) {
  if (!snapshot?.valid || !samePath(snapshot.path, configPath)) {
    throw new Error('网关与此仓库的配置不匹配。请在仓库目录启动 node bin/bot.mjs gateway。');
  }
  const channel = snapshot.config?.channels?.[channelId];
  if (channel?.enabled !== true) return;
  const native = channel.native;
  const consumerDir = native?.consumerStateDir;
  if (native?.endpoint !== nativeEndpoint || typeof consumerDir !== 'string'
    || !samePath(path.dirname(consumerDir), consumerRoot)
    || !/^scan-\d{8}-\d{6}-[a-f0-9]{10}$/.test(path.basename(consumerDir))) {
    throw new Error('服务端微信通道正在运行。请先用仓库的 pause 命令停用它，再使用桌面界面。');
  }
}

export async function loadGatewayCall() {
  if ((await fs.readFile(path.join(runtimeRoot, 'mode'), 'utf8')).trim() !== 'desktop') {
    throw new Error('请先在仓库目录运行 node bin/bot.mjs setup --desktop。');
  }
  const config = JSON.parse(await fs.readFile(configPath, 'utf8'));
  const port = config.gateway?.port ?? 19789;
  if (!Number.isInteger(port) || port < 1024 || port > 65535 || port === nativePort || config.gateway?.bind !== 'loopback') {
    throw new Error('仓库网关必须使用本机环回地址及有效端口。');
  }
  const token = (await fs.readFile(path.join(runtimeRoot, 'keys', 'gateway-token'), 'utf8')).trim();
  if (!/^[a-zA-Z0-9_-]{32,128}$/.test(token)) throw new Error('仓库网关令牌无效，请检查初始化步骤。');
  process.env.OPENCLAW_STATE_DIR = stateDir;
  process.env.OPENCLAW_CONFIG_PATH = configPath;
  const dist = path.join(packageRoot, 'dist');
  // Resolve the installed build's exported client instead of pinning a hashed filename.
  for (const name of (await fs.readdir(dist)).filter(name => /^call-.*\.mjs$/.test(name))) {
    const filename = path.join(dist, name);
    const source = await fs.readFile(filename, 'utf8');
    const exported = source.match(/export\s*\{[^}]*\bcallGatewayCli\s+as\s+(\w+)/s);
    if (!exported) continue;
    const module = await import(pathToFileURL(filename).href);
    if (typeof module[exported[1]] !== 'function') continue;
    return async options => {
      const result = await module[exported[1]]({ ...options, url: `ws://127.0.0.1:${port}`, token, configPath, ignoreEnvUrlOverride: true });
      if (options.method === 'config.get') requireDesktopGateway(result);
      return result;
    };
  }
  throw new Error('当前 OpenClaw 版本未提供可识别的网关接口，请检查安装。');
}

export function channelState(payload) {
  const id = payload.channelDefaultAccountId?.[channelId] ?? 'default';
  const account = payload.channelAccounts?.[channelId]?.find(account => account.accountId === id);
  return account ?? payload.channels?.[channelId] ?? {};
}

export function channelReady(state) {
  // Some Gateway runtime snapshots intentionally omit the optional linked field.
  // The native account is independently checked before this can be a successful start.
  return state.enabled !== false && state.running === true && state.connected === true && state.linked !== false;
}

function validGroupIds(value) {
  const ids = typeof value === 'string' ? [value] : value;
  return Array.isArray(ids) && ids.length > 0
    && ids.every(id => typeof id === 'string' && /^[^\s@*]+@chatroom$/.test(id))
    && new Set(ids).size === ids.length ? [...ids] : null;
}

export function sessionGroupIds(session) {
  const selected = session.groupIds ?? session.groups?.map(group => group?.id) ?? session.groupId;
  const ids = validGroupIds(selected);
  if (!ids) throw new Error('请至少选择一个有效微信群。');
  return ids;
}

export function configMatches(config, session, groupIds) {
  if (!validDesktopSession(session)) return false;
  const saved = session.groupIds ?? session.groups?.map(group => group?.id) ?? session.groupId;
  const selected = validGroupIds(groupIds ?? saved);
  if (!selected) return false;
  if (saved !== undefined) {
    const savedIds = validGroupIds(saved);
    if (!savedIds || savedIds.length !== selected.length || !savedIds.every(id => selected.includes(id))) return false;
  }
  const channel = config?.channels?.[channelId];
  const native = channel?.native;
  const active = Object.entries(channel?.groups ?? {}).filter(([, value]) => value?.enabled === true).map(([id]) => id);
  return channel?.enabled === true && native?.accountId === session.accountId
    && native.endpoint === `http://127.0.0.1:${session.port}`
    && samePath(native.consumerStateDir, path.join(consumerRoot, session.id))
    && channel.dmPolicy === 'disabled' && channel.groups?.['*']?.enabled === false
    && active.length === selected.length && active.every(id => selected.includes(id) && channel.groups[id].requireMention === false);
}

export function requireNativeAccountReady(account, session, { requireInitialSync = true } = {}) {
  if (account.ownUsername !== session.ownUsername) {
    const error = new Error('微信账号身份已变化，请重新选择账号。');
    error.code = 'native_identity_mismatch';
    throw error;
  }
  if (!account.authenticated || account.connection !== 'online') {
    throw new Error('微信连接尚未恢复，请返回账号选择并点击继续。');
  }
  // wx 1.2.0 can report online before initial catchup has drained. Messages
  // received in that interval still have origin=catchup and cannot trigger replies.
  if (requireInitialSync && account.contactSyncReady !== true) {
    const error = new Error('微信已登录，正在完成首次同步；同步完成后才能接收群内新消息。');
    error.code = 'native_initial_sync_pending';
    throw error;
  }
  return account;
}

export async function readNativeAccount(session, options) {
  if (!validDesktopSession(session) || !session.accountId || !session.ownUsername) throw new Error('扫码账号身份不完整。');
  const token = (await fs.readFile(path.join(session.root, 'api-token'), 'utf8')).trim();
  const response = await fetch(`http://127.0.0.1:${session.port}/v1/accounts/${encodeURIComponent(session.accountId)}`, {
    headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(8000), redirect: 'error'
  });
  if (!response.ok) throw new Error('微信本地连接暂时不可用，请重试；无需重新扫码。');
  const account = await response.json();
  return requireNativeAccountReady(account, session, options);
}

export async function waitForChannel({ call, session, groupIds, groupId, readAccount = readNativeAccount, timeoutMs = 120000, progress = () => {}, delay = sleep, now = Date.now }) {
  const selected = validGroupIds(groupIds ?? groupId ?? sessionGroupIds(session));
  if (!selected) throw new Error('所选账号或群配置已发生变化，请重新选择。');
  const deadline = now() + timeoutMs;
  let lastState = {};
  let startRequested = false;
  let lastError = '';
  while (now() < deadline) {
    try {
      const snapshot = await call({ method: 'config.get', params: {}, timeoutMs: 5000 });
      if (!configMatches(snapshot.config, session, selected)) throw new Error('所选账号或群配置已发生变化，请重新选择。');
      const applied = snapshot.configRevisionHash && snapshot.configRevisionHash === snapshot.appliedConfigHash;
      if (applied) {
        lastState = channelState(await call({ method: 'channels.status', params: { channel: channelId, probe: false }, timeoutMs: 5000 }));
        if (channelReady(lastState)) {
          await readAccount(session);
          return { healthy: true, initialSyncReady: true, method: 'channel-hot-reload', accountId: session.accountId, groupIds: selected, groupId: selected[0] };
        }
        if (!startRequested && lastState.running === false && !lastState.restartPending && lastState.lifecycle === 'stopped') {
          startRequested = true;
          await call({ method: 'channels.start', params: { channel: channelId, accountId: 'default' }, timeoutMs: 5000 });
        }
      }
      await progress(applied ? (lastState.running && !lastState.connected ? '微信已登录，正在补同步事件并建立消息监听…' : '正在连接微信通道…') : '正在加载所选账号和群配置…');
    } catch (error) {
      if (error.message?.includes('配置已发生变化') || error.code === 'native_identity_mismatch') throw error;
      lastError = error.code ?? error.name ?? 'gateway_request';
      await progress(error.code === 'native_initial_sync_pending'
        ? '微信已登录，正在完成首次同步；完成前请先不要发测试消息…'
        : '连接尚未就绪，正在重试；不会重启整个网关…');
    }
    await delay(500);
  }
  const initialSyncPending = lastError === 'native_initial_sync_pending';
  const error = new Error(initialSyncPending
    ? '微信首次同步尚未完成，暂不能接收新消息。扫码账号已保留，可稍后直接重试，无需重新扫码。'
    : '微信通道暂未连接成功。已保留扫码账号，可直接重试启动；无需重新扫码。');
  error.code = initialSyncPending ? 'native_initial_sync_timeout' : 'channel_timeout';
  error.details = { running: lastState.running === true, connected: lastState.connected === true, cause: lastError };
  throw error;
}

export async function patchConfig(call, patch, replacePaths = []) {
  const snapshot = await call({ method: 'config.get', params: {}, timeoutMs: 8000 });
  if (!snapshot.valid || !snapshot.hash) throw new Error('网关配置不可用，请先检查 OpenClaw。');
  const requestedGroups = patch.channels?.[channelId]?.groups;
  if (requestedGroups !== undefined) {
    if (!requestedGroups || typeof requestedGroups !== 'object' || Array.isArray(requestedGroups)) {
      throw new Error('启动配置必须包含选中的微信群列表。');
    }
    const enabled = Object.entries(requestedGroups).filter(([, group]) => group?.enabled === true);
    if (!validGroupIds(enabled.map(([id]) => id)) || requestedGroups['*']?.enabled !== false
      || enabled.some(([, group]) => group.requireMention !== false)
      || patch.channels[channelId].dmPolicy !== 'disabled') {
      throw new Error('启动配置必须只启用选中的有效微信群，关闭其他群和私聊，并允许无需 @ 的回复。');
    }
    const currentGroups = snapshot.sourceConfig?.channels?.[channelId]?.groups ?? snapshot.config?.channels?.[channelId]?.groups ?? {};
    // OpenClaw replacePaths replaces arrays only. Object maps use merge-patch,
    // so omitted groups survive unless explicitly deleted in this same write.
    const removed = Object.fromEntries(Object.keys(currentGroups)
      .filter(id => !Object.hasOwn(requestedGroups, id)).map(id => [id, null]));
    patch.channels[channelId].groups = { ...removed, ...requestedGroups };
  }
  if (patch.bindings) {
    // Preserve concurrent changes to other channels instead of copying an old file's bindings.
    const current = snapshot.sourceConfig?.bindings ?? snapshot.config?.bindings ?? [];
    patch.bindings = [...current.filter(binding => binding.match?.channel !== channelId), ...patch.bindings.filter(binding => binding.match?.channel === channelId)];
  }
  const result = await call({ method: 'config.patch', params: { baseHash: snapshot.hash, raw: JSON.stringify(patch), replacePaths }, timeoutMs: 20000 });
  if (!result.ok || result.restart) throw new Error('通道配置需要进一步检查，已停止启动；没有执行额外的网关重启。');
  return { noop: result.noop === true, changedPaths: result.changedPaths ?? [] };
}

async function main() {
  const [mode, patchFile, sessionFile] = process.argv.slice(2);
  const started = performance.now();
  let session;
  let progressFile;
  const progress = async message => {
    if (progressFile) await fs.writeFile(progressFile, JSON.stringify({ message, elapsedMs: Math.round(performance.now() - started) }), 'utf8');
  };
  try {
    const call = await loadGatewayCall();
    let result;
    if (mode === 'status') {
      const snapshot = await call({ method: 'config.get', params: {}, timeoutMs: 5000 });
      result = { enabled: snapshot.config?.channels?.[channelId]?.enabled === true };
    } else if (mode === 'pause') {
      const snapshot = await call({ method: 'config.get', params: {}, timeoutMs: 5000 });
      result = snapshot.config?.channels?.[channelId]?.enabled === false ? { noop: true } : await patchConfig(call, { channels: { [channelId]: { enabled: false } } });
    } else if (mode === 'start') {
      session = JSON.parse(await fs.readFile(sessionFile, 'utf8'));
      progressFile = path.join(session.root, 'activation-progress.json');
      const patch = JSON.parse(await fs.readFile(patchFile, 'utf8'));
      const groupIds = sessionGroupIds(session);
      if (!configMatches({ channels: patch.channels }, session, groupIds)) throw new Error('启动配置与扫码账号或选中的群不匹配。');
      await progress('正在确认已扫码的微信连接…');
      await readNativeAccount(session, { requireInitialSync: false });
      await progress('正在更新选中的微信群…');
      await patchConfig(call, patch, ['bindings']);
      result = await waitForChannel({ call, session, groupIds, progress });
    } else throw new Error('不支持的网关操作。');
    console.log(JSON.stringify({ ok: true, ...result, elapsedMs: Math.round(performance.now() - started) }));
  } catch (error) {
    // Never echo configuration, bearer credentials, or raw transport payloads.
    const message = /[\u3400-\u9fff]/u.test(error.message ?? '') ? error.message : '请确认已在仓库目录运行 node bin/bot.mjs gateway，并等待网关就绪。';
    console.log(JSON.stringify({ ok: false, message, code: error.code ?? 'gateway_request_failed', elapsedMs: Math.round(performance.now() - started) }));
    process.exitCode = 1;
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  await main();
  // The installed official RPC client's background handles must not hold up the launcher.
  process.exit(process.exitCode ?? 0);
}

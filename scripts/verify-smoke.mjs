import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { closeSync, existsSync, openSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const root = fileURLToPath(new URL('..', import.meta.url));
const runtime = path.join(root, '.runtime');
const state = path.join(runtime, 'openclaw');
const config = path.join(state, 'openclaw.json');
const cli = path.join(root, 'bin', 'bot.mjs');
const wx = path.join(runtime, 'bin', process.platform === 'win32' ? 'wx.exe' : 'wx');
const host = path.join(root, 'node_modules', 'openclaw', 'openclaw.mjs');
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(OPENCLAW_|AGENT_WECHAT_|WX_|DEEPSEEK_API_KEY$)/i.test(k)));
assert(!existsSync(path.join(runtime, 'mode')) && !existsSync(config), 'Smoke test requires a fresh checkout.');
const setup = spawnSync(process.execPath, [cli, 'setup', '--key-stdin'], {
  cwd: root, env, input: 'ci-fixture-no-network-model\n', encoding: 'utf8', timeout: 120_000
});
assert.equal(setup.status, 0, setup.stderr);
const local = JSON.parse(readFileSync(config, 'utf8'));
assert.equal(local.gateway.bind, 'loopback');
assert.equal(local.channels['agent-wechat'].enabled, false);
assert.equal(local.channels['agent-wechat'].groups['*'].enabled, false);
assert.equal(local.session.groupScope, 'per-group');
const ports = JSON.parse(readFileSync(path.join(runtime, 'ports.json'), 'utf8'));
const children = [];

function start(name, file, args, extraEnv = {}) {
  const log = openSync(path.join(runtime, `${name}-smoke.log`), 'a');
  try {
    const child = spawn(file, args, { cwd: root, env: { ...env, ...extraEnv }, stdio: ['ignore', log, log], windowsHide: true });
    children.push(child);
    child.on('error', error => { child.spawnFailure = error; });
    return child;
  } finally {
    closeSync(log);
  }
}

async function waitFor(child, check) {
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) {
    if (child.spawnFailure || child.exitCode !== null || child.signalCode !== null) {
      throw new Error('Smoke-test process exited before becoming ready.');
    }
    if (await check().catch(() => false)) return;
    await delay(800);
  }
  throw new Error('Smoke-test readiness timed out.');
}

try {
  const wxRoot = path.join(runtime, 'wx');
  const wxService = start('wx', wx, ['--data-dir', wxRoot, '--listen', `127.0.0.1:${ports.wx}`, 'serve']);
  await waitFor(wxService, async () => {
    const token = readFileSync(path.join(wxRoot, 'api-token'), 'utf8').trim();
    const response = await fetch(`http://127.0.0.1:${ports.wx}/v1/accounts`, {
      headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(2000)
    });
    return response.ok;
  });
  const gateway = start('gateway', process.execPath, ['--stack-size=8192', host, 'gateway', 'run'], {
    OPENCLAW_STATE_DIR: state, OPENCLAW_CONFIG_PATH: config
  });
  await waitFor(gateway, async () => {
    const response = await fetch(`http://127.0.0.1:${ports.gateway}/readyz`, { signal: AbortSignal.timeout(2000) });
    return response.ok && (await response.json()).ready === true;
  });
  console.log(JSON.stringify({ platform: process.platform, arch: process.arch, gatewayReady: true, wxReady: true, channelEnabled: false }));
} catch (error) {
  for (const name of ['wx', 'gateway']) {
    const log = path.join(runtime, `${name}-smoke.log`);
    if (existsSync(log)) console.error(readFileSync(log, 'utf8').split('\n').slice(-25).join('\n'));
  }
  throw error;
} finally {
  for (const child of children.reverse()) {
    if (child.exitCode === null && child.signalCode === null) child.kill();
  }
}

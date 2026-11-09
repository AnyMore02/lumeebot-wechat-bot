import { createHash, randomUUID } from 'node:crypto';
import { chmod, lstat, mkdir, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { patchMediaReplay } from '../patches/openclaw-2026.10.7-media-replay.mjs';
import { patchAgentWeChat } from '../patches/agent-wechat-1.2.0.mjs';

const root = await realpath(fileURLToPath(new URL('..', import.meta.url)));
const version = '1.2.0';
const platforms = {
  'win32-x64': ['win32-x64.exe', '5d7792b450d2e237d27e4403eaf2c0baa3851a068f52bd5211bd44eb237033d6'],
  'win32-arm64': ['win32-arm64.exe', '6337e32951fae521bda5eee32351fa8822660c8dd53acae9daa3c467f45262f1'],
  'linux-x64': ['linux-x64-gnu', '286b5661582b8d17594b208bf4bec19f7db182f12f9827733cfc0f6fde61efb1'],
  'linux-arm64': ['linux-arm64-gnu', 'cdd17343373cca86ae096427775e14b2781347759bf69120437eecb2fd457b1f']
};
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');

async function safeDirectory(directory) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  if (path.relative(root, await realpath(directory)).startsWith('..')) {
    throw new Error('Runtime directory resolves outside the repository.');
  }
}

async function installWx() {
  const asset = platforms[`${process.platform}-${process.arch}`];
  if (!asset) throw new Error('Supported systems: Windows and glibc Linux, x64 or ARM64.');
  if (process.platform === 'linux') {
    const version = process.report.getReport().header.glibcVersionRuntime;
    const [major, minor] = String(version ?? '').split('.').map(Number);
    if (!(major > 2 || (major === 2 && minor >= 36))) {
      throw new Error('wx 1.2.0 requires glibc 2.36 or newer.');
    }
  }
  const [suffix, digest] = asset;
  const directory = path.join(root, '.runtime', 'bin');
  await safeDirectory(directory);
  const target = path.join(directory, process.platform === 'win32' ? 'wx.exe' : 'wx');
  try {
    if (!(await lstat(target)).isFile() || sha(await readFile(target)) !== digest) {
      throw new Error('Existing wx binary has an unexpected checksum. Inspect and move it aside before retrying.');
    }
    if (process.platform !== 'win32') await chmod(target, 0o700);
    return;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const url = `https://github.com/thisnick/agent-wechat/releases/download/v${version}/wx-v${version}-${suffix}`;
  const response = await fetch(url, { signal: AbortSignal.timeout(180_000) });
  if (!response.ok) throw new Error(`wx download failed (HTTP ${response.status}).`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (sha(bytes) !== digest) throw new Error('Downloaded wx checksum mismatch.');
  const staged = `${target}.${randomUUID()}.tmp`;
  try {
    await writeFile(staged, bytes, { mode: 0o700, flag: 'wx' });
    await rename(staged, target);
  } finally {
    await rm(staged, { force: true });
  }
}

try {
  await installWx();
  const changed = await patchMediaReplay(root);
  const pluginChanged = await patchAgentWeChat(root);
  console.log(`Runtime ready. wx ${version} verified. OpenClaw reply repair ${changed ? 'applied' : 'already installed'}. WeChat plugin repair ${pluginChanged ? 'applied' : 'already installed'}.`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}

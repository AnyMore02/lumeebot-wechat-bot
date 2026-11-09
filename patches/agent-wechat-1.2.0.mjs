import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

const sha = bytes => createHash('sha256').update(bytes).digest('hex');

export async function patchAgentWeChat(root) {
  const pkg = path.join(root, 'node_modules', '@agent-wechat', 'agent-wechat');
  const file = path.join(pkg, 'dist', 'index.js');
  if (path.relative(root, await realpath(file)).startsWith('..')) {
    throw new Error('agent-wechat resolves outside the repository. Use npm ci for a local copy.');
  }
  const { version } = JSON.parse(await readFile(path.join(pkg, 'package.json'), 'utf8'));
  assert.equal(version, '1.2.0', 'This plugin patch requires agent-wechat 1.2.0.');
  const { upstream, deployed, hunks } = JSON.parse(
    await readFile(new URL('./agent-wechat-1.2.0.json', import.meta.url), 'utf8')
  );
  const source = await readFile(file, 'utf8');
  const digest = sha(source);
  if (digest === deployed) return false;
  assert.equal(digest, upstream, 'agent-wechat checksum mismatch. Reinstall pinned dependencies before retrying.');

  const lines = source.split('\n');
  for (const { offset, before, after } of [...hunks].reverse()) {
    assert.deepEqual(lines.slice(offset, offset + before.length), before, 'Plugin patch context mismatch.');
    lines.splice(offset, before.length, ...after);
  }
  const result = lines.join('\n');
  assert.equal(sha(result), deployed, 'Generated plugin differs from the verified build.');
  const staged = `${file}.${randomUUID()}.tmp`;
  try {
    await writeFile(staged, result, { flag: 'wx' });
    await rename(staged, file);
  } finally {
    await rm(staged, { force: true });
  }
  return true;
}

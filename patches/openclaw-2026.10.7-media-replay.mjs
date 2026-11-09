import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

const originalHash = '0f8ed4873cbba263680bce67dba75c328ad2644a9a6a3867d32a0cc7f43435a4';
const patchedHash = '591601148ec889f634d0e87e7cd8a7d281c62e1794ebcee8266e925752cb2f6a';
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');

function replaceOnce(source, from, to) {
  assert.equal(source.split(from).length, 2, 'OpenClaw patch point must match exactly once.');
  return source.replace(from, to);
}

export async function patchMediaReplay(root) {
  const pkg = path.join(root, 'node_modules', 'openclaw');
  const file = path.join(pkg, 'dist', 'builtin-openclaw-Ci5YBsOb.mjs');
  if (path.relative(root, await realpath(file)).startsWith('..')) {
    throw new Error('OpenClaw resolves outside the repository. Use npm ci to install a local copy.');
  }
  const { version } = JSON.parse(await readFile(path.join(pkg, 'package.json'), 'utf8'));
  assert.equal(version, '2026.10.7', 'This reply repair requires OpenClaw 2026.10.7.');
  const source = await readFile(file, 'utf8');
  const digest = sha(source);
  if (digest === patchedHash) return false;
  assert.equal(digest, originalHash, 'OpenClaw module checksum mismatch. Reinstall pinned dependencies before retrying.');
  const anchor = 'const preparedUserTurnMessage = attempt.skipPreparedUserTurnMessage ? void 0 : await attempt.userTurnTranscriptRecorder?.resolveMessage();';
  let result = replaceOnce(source, anchor, `${anchor}
\t// WeChat transport IDs can be redacted while admitting the input. Re-read the
\t// canonical message owned by this recorder when validating the persisted turn.
\t// Keep raw prepared input for the model, and keep strict replay equality/fences.
\tconst wechatRecorder = attempt.userTurnTranscriptRecorder;
\tconst wechatAdmitted = preparedUserTurnMessage?.role === "user" && preparedUserTurnMessage.__openclaw?.transport?.channel === "agent-wechat" && preparedUserTurnMessage.idempotencyKey?.startsWith("channel-user:v1:") && wechatRecorder?.hasPersisted() && wechatRecorder.getAdmissionReceipt()?.sessionId === attempt.sessionId ? wechatRecorder.getPersistedMessage() : void 0;
\tconst replayUserTurnMessage = wechatAdmitted?.role === "user" && wechatAdmitted.idempotencyKey === preparedUserTurnMessage?.idempotencyKey ? wechatAdmitted : preparedUserTurnMessage;`);
  result = replaceOnce(result, 'const initial = prepareInitialPersistedUserTurnCohort({\n\t\t\ttarget,\n\t\t\tmessage: preparedUserTurnMessage,', 'const initial = prepareInitialPersistedUserTurnCohort({\n\t\t\ttarget,\n\t\t\tmessage: replayUserTurnMessage,');
  result = replaceOnce(result, 'const preparedReplay = await input.withOwnedTranscriptWrite(() => preparePersistedCurrentUserTurn({\n\t\tsessionManager: unguardedSessionManager,\n\t\tmessage: preparedUserTurnMessage,', 'const preparedReplay = await input.withOwnedTranscriptWrite(() => preparePersistedCurrentUserTurn({\n\t\tsessionManager: unguardedSessionManager,\n\t\tmessage: replayUserTurnMessage,');
  assert.equal(sha(result), patchedHash, 'Generated patch differs from the verified build.');
  const staged = `${file}.${randomUUID()}.tmp`;
  try {
    await writeFile(staged, result, { flag: 'wx' });
    await rename(staged, file);
  } finally {
    await rm(staged, { force: true });
  }
  return true;
}

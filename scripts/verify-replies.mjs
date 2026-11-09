import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import { randomUUID, createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { deflateSync, crc32 } from 'node:zlib';
import { pathToFileURL, fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const here = path.join(root, '.runtime');
await fs.mkdir(here, { recursive: true, mode: 0o700 });
const state = await fs.mkdtemp(path.join(here, 'fixture-state-'));
const workspace = path.join(state, 'workspace');
const configPath = path.join(state, 'openclaw.json');
process.env.OPENCLAW_STATE_DIR = state;
process.env.OPENCLAW_CONFIG_PATH = configPath;
process.env.OPENCLAW_HOME = state;
const dist = path.join(root, 'node_modules', 'openclaw', 'dist');
const requests = [];
const server = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
  requests.push({ path: req.url, model: body.model, types: body.messages?.flatMap(m => Array.isArray(m.content) ? m.content.map(c => c.type) : []) });
  if (body.model === 'fixture-image') {
    res.writeHead(400, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'fixture image preprocessing failed', type: 'invalid_request_error' } }));
    return;
  }
  const data = { id:'chatcmpl-fixture', object:'chat.completion.chunk', created:1, model:'fixture-text', choices:[{index:0,delta:{role:'assistant',content:'fixture reply'},finish_reason:null}] };
  res.writeHead(200, {'content-type':'text/event-stream'});
  res.write(`data: ${JSON.stringify(data)}\n\n`);
  res.write(`data: ${JSON.stringify({...data, choices:[{index:0,delta:{},finish_reason:'stop'}],usage:{prompt_tokens:10,completion_tokens:2,total_tokens:12}})}\n\n`);
  res.end('data: [DONE]\n\n');
});
await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
const baseUrl = `http://127.0.0.1:${server.address().port}/v1`;
const config = {
  agents:{defaults:{workspace, model:{primary:'fixture/fixture-text'}, imageModel:{primary:'fixture/fixture-image'}, timeoutSeconds:12, skipBootstrap:true, maxConcurrent:4}, entries:{main:{workspace,tools:{deny:['*']}}}},
  plugins:{enabled:false},
  models:{providers:{fixture:{baseUrl, apiKey:'fixture-key', api:'openai-completions', models:[{id:'fixture-text',name:'fixture-text',input:['text','image'],contextWindow:32000,maxTokens:2048},{id:'fixture-image',name:'fixture-image',input:['text','image'],contextWindow:32000,maxTokens:2048}]}}},
  tools:{media:{image:{enabled:true},models:[{provider:'fixture',model:'fixture-image',capabilities:['image']}]}}
};
await fs.mkdir(workspace);
await fs.writeFile(configPath, JSON.stringify(config));
const mediaDir = path.join(state, 'media', 'inbound');
await fs.mkdir(mediaDir, { recursive:true });
const png = path.join(mediaDir, 'fixture.png');
const pngChunk = (type, data) => {
  const payload = Buffer.concat([Buffer.from(type,'ascii'),data]);
  const length = Buffer.alloc(4), crc = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  crc.writeUInt32BE(crc32(payload));
  return Buffer.concat([length,payload,crc]);
};
const dimension = 256;
const head = Buffer.alloc(13);
head.writeUInt32BE(dimension,0);
head.writeUInt32BE(dimension,4);
head[8]=8; head[9]=2;
const pixels=Buffer.alloc(dimension*(1+dimension*3));
for(let y=0;y<dimension;y++) for(let x=0;x<dimension;x++) {
  const index=y*(1+dimension*3)+1+x*3;
  pixels[index]=x; pixels[index+1]=y; pixels[index+2]=x^y;
}
await fs.writeFile(png,Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),pngChunk('IHDR',head),pngChunk('IDAT',deflateSync(pixels)),pngChunk('IEND',Buffer.alloc(0))]));
let passed = true;
try {
  const {t:getReplyFromConfig} = await import(pathToFileURL(path.join(dist,'get-reply-Cj1AJyZx.mjs')));
  const {t:GatewayScheduler} = await import(pathToFileURL(path.join(dist,'gateway-scheduler-1NWC9JXC.mjs')));
  const {d:setSessionMcpRuntimeScheduler} = await import(pathToFileURL(path.join(dist,'agent-bundle-mcp-manager-api-MgM2jUv6.mjs')));
  await setSessionMcpRuntimeScheduler(new GatewayScheduler());
  const scenarios = [['group-a',true],['group-b',true]];
  const ask = async ([group, image]) => {
    const id = `${group}@chatroom`;
    const account = 'account-11112222333344445555';
    const nativeId = `m1_${Buffer.from(`${id}\0fixture native ID`).toString('base64url')}`;
    const body = image ? `<media:image>\n[Image file: <${png}>]` : 'fixture text';
    const messageSid = `wechat-native:${account}:${nativeId}:${createHash('sha256').update(JSON.stringify([id,'12345678'])).digest('hex')}`;
    const ctx = {
      Body: body, BodyForAgent: body, RawBody: body, CommandBody: image ? '<media:image>' : body,
      From: `wechat:group:${id}`, To: `wechat:${id}`, OriginatingTo: `wechat:${id}`,
      OriginatingChannel: 'agent-wechat', Provider: 'agent-wechat', Surface: 'agent-wechat',
      AccountId: 'default', ChatType: 'group', SenderId: 'wxid_fixture',
      SessionKey: `agent:main:agent-wechat:group:${id}`, MessageSid: messageSid
    };
    if (image) Object.assign(ctx,{MediaPath:png, MediaUrl:png, MediaType:'image/png', Attachments:[{kind:'image',path:png,filename:path.basename(png),messageId:nativeId,sender:ctx.SenderId}]});
    const result = await getReplyFromConfig(ctx, {runId:randomUUID()}, config);
    return { group, image, messageSid, result };
  };
  const settled = await Promise.allSettled(scenarios.map(pair => ask(pair)));
  for (const outcome of settled) {
    assert.equal(outcome.status, 'fulfilled', outcome.reason?.message);
    assert.equal(outcome.value.result?.text, 'fixture reply');
    assert.equal(outcome.value.result?.replyToId, outcome.value.messageSid);
  }
  assert.equal(requests.filter(request => request.model === 'fixture-image').length, 2);
  assert.equal(requests.filter(request => request.model === 'fixture-text').length, 2);
  console.log(JSON.stringify({ twoIndependentGroupReplies: true, simulatedImageFailures: 2 }));
} catch (error) {
  console.error(error);
  passed = false;
} finally {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
process.exit(passed ? 0 : 1);

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createGateway } from '../pr-review/reviewbench/gateway.mjs';

const secrets = { reviewClientToken: 'test-review', judgeClientToken: 'test-judge', reviewToken: 'upstream-review', judgeToken: 'upstream-judge', accountId: 'account' };
function codexBody(extra = {}) { return { model: 'gpt-6.1-sol', stream: true, input: [], tools: [{ type: 'function', name: 'read', parameters: {} }], ...extra }; }
function codexResponse(usage = { input_tokens: 1000, output_tokens: 100, input_tokens_details: { cached_tokens: 200 } }) {
  return new Response(`data: ${JSON.stringify({ type: 'response.completed', response: { model: 'gpt-6.1-sol', status: 'completed', usage } })}\n\ndata: [DONE]\n\n`, { headers: { 'content-type': 'text/event-stream' } });
}
async function fixture(t, fetchImpl, budgets) {
  const dir = mkdtempSync(join(tmpdir(), 'edc-gateway-test-'));
  const gateway = await createGateway({ ledgerPath: join(dir, 'ledger.jsonl'), secrets, fetchImpl, budgets });
  t.after(async () => { await gateway.close(); rmSync(dir, { recursive: true, force: true }); });
  return { ...gateway, dir };
}
async function post(gateway, body = codexBody(), path = '/review/codex/responses', token = secrets.reviewClientToken) {
  const response = await fetch(gateway.url + path, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: response.status, text: await response.text() };
}

test('forwards only approved Codex endpoint and reconciles cached usage without logging secrets', async t => {
  const calls = [];
  const g = await fixture(t, async (url, options) => { calls.push({ url, options }); return codexResponse(); });
  assert.equal((await post(g)).status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://chatgpt.com/backend-api/codex/responses');
  assert.equal(calls[0].options.headers.authorization, 'Bearer upstream-review');
  assert.equal(calls[0].options.headers['chatgpt-account-id'], 'account');
  const ledger = readFileSync(join(g.dir, 'ledger.jsonl'), 'utf8');
  assert.ok(!ledger.includes('upstream-review'));
  const events = ledger.trim().split('\n').map(JSON.parse);
  assert.equal(events[0].type, 'reserved');
  assert.equal(events.at(-1).type, 'settled');
  assert.ok(Math.abs(events.at(-1).cost - 0.00262) < 1e-9);
});

test('Codex prices reported cache writes separately and reserves their higher catalog rate', async t => {
  const g = await fixture(t, async () => codexResponse({ input_tokens: 300000, output_tokens: 0, input_tokens_details: { cached_tokens: 0, cache_write_tokens: 300000 } }));
  assert.equal((await post(g)).status, 200);
  const events = readFileSync(join(g.dir, 'ledger.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(events.at(-1).cost, 1.5);
  assert.equal(events[0].reserve, 4.42);
});

test('budget reserves the configured model envelope before forwarding, not average observed cost', async t => {
  let calls = 0;
  const g = await fixture(t, async () => { calls++; return codexResponse(); }, { total: 2, review: 2, judge: 0 });
  assert.equal((await post(g)).status, 402);
  assert.equal(calls, 0);
});

test('rejects unknown model, hosted tools, wrong route and wrong credential before provider access', async t => {
  let calls = 0;
  const g = await fixture(t, async () => { calls++; return codexResponse(); });
  for (const body of [codexBody({ model: 'other' }), codexBody({ service_tier: 'priority' }), codexBody({ tools: [{ type: 'web_search' }] }), codexBody({ stream: false }), codexBody({ input: [{ type: 'message', content: [{ type: 'input_image', image_url: 'https://example.org/a.png' }] }] })]) {
    assert.equal((await post(g, body)).status, 400);
  }
  assert.equal((await post(g, codexBody(), '/other')).status, 404);
  assert.equal((await post(g, codexBody(), '/review/codex/responses', 'wrong')).status, 401);
  assert.equal(calls, 0);
});

test('validates nested local tool declarations and rejects hosted tool admission before forwarding', async t => {
  let calls = 0;
  const g = await fixture(t, async () => { calls++; return codexResponse(); });
  for (const item of [
    { type: 'additional_tools', role: 'developer', tools: [{ type: 'web_search_preview' }] },
    { type: 'tool_search_output', execution: 'client', tools: [{ type: 'web_search_preview' }] },
    { type: 'tool_search_call', execution: 'server' },
    { type: 'item_reference', id: 'hidden-server-state' },
  ]) assert.equal((await post(g, codexBody({ input: [item] }))).status, 400);
  assert.equal(calls, 0);
  for (const item of [
    { type: 'additional_tools', role: 'developer', tools: [{ type: 'function', name: 'read', parameters: {} }] },
    { type: 'tool_search_output', execution: 'client', tools: [{ type: 'custom', name: 'bash', format: { type: 'text' } }] },
  ]) assert.equal((await post(g, codexBody({ input: [item] }))).status, 200);
  assert.equal(calls, 2);
});

test('rejects unreviewed API beta and version headers before forwarding', async t => {
  let calls = 0;
  const g = await fixture(t, async () => { calls++; return codexResponse(); });
  for (const headers of [{ 'openai-beta': 'unreviewed-feature' }, { 'anthropic-beta': 'unreviewed-feature' }, { 'anthropic-version': '2099-01-01' }]) {
    const response = await fetch(g.url + '/review/codex/responses', { method: 'POST', headers: { authorization: 'Bearer ' + secrets.reviewClientToken, 'content-type': 'application/json', ...headers }, body: JSON.stringify(codexBody()) });
    await response.text();
    assert.equal(response.status, 400);
  }
  assert.equal(calls, 0);
});

test('unknown provider outcome blocks further calls and survives process restart', async t => {
  let calls = 0;
  const dir = mkdtempSync(join(tmpdir(), 'edc-gateway-test-'));
  const config = { ledgerPath: join(dir, 'ledger.jsonl'), secrets, fetchImpl: async () => { calls++; throw Error('connection lost'); } };
  let g = await createGateway(config);
  assert.equal((await post(g)).status, 502);
  assert.equal((await post(g)).status, 409);
  await g.close();
  g = await createGateway(config);
  t.after(async () => { await g.close(); rmSync(dir, { recursive: true, force: true }); });
  assert.equal((await post(g)).status, 409);
  assert.equal(calls, 1);
});

test('missing usage never becomes zero cost and provider errors are not retried', async t => {
  let calls = 0;
  const g = await fixture(t, async () => { calls++; return new Response('data: {"type":"response.completed","response":{"model":"gpt-6.1-sol","status":"completed"}}\n\n'); });
  await assert.rejects(post(g), /fetch failed|terminated/);
  assert.equal((await post(g)).status, 409);
  assert.equal(calls, 1);
});

test('exclusive active request prevents simultaneous spend and duplicate gateway ownership', async t => {
  let release;
  let started;
  const startedPromise = new Promise(resolve => { started = resolve; });
  const g = await fixture(t, async () => { started(); await new Promise(resolve => { release = resolve; }); return codexResponse(); });
  const first = post(g);
  await startedPromise;
  assert.equal((await post(g)).status, 409);
  await assert.rejects(createGateway({ ledgerPath: join(g.dir, 'ledger.jsonl'), secrets, fetchImpl: async () => codexResponse() }), /lock|EEXIST/i);
  release();
  assert.equal((await first).status, 200);
});

test('Anthropic usage includes cache writes, reads, output once and preserves caller max_tokens', async t => {
  const g = await fixture(t, async (url, options) => {
    assert.equal(url, 'https://api.anthropic.com/v1/messages');
    assert.equal(JSON.parse(options.body).max_tokens, 8192);
    return new Response('data: {"type":"message_start","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":1,"cache_creation_input_tokens":100,"cache_read_input_tokens":200}}}\n\ndata: {"type":"message_delta","usage":{"output_tokens":50}}\n\ndata: {"type":"message_stop"}\n\n');
  });
  assert.equal((await post(g, { model: 'claude-sonnet-5', stream: true, max_tokens: 8192, messages: [] }, '/judge/v1/messages', secrets.judgeClientToken)).status, 200);
  const events = readFileSync(join(g.dir, 'ledger.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.ok(Math.abs(events.at(-1).cost - 0.00279) < 1e-9);
});

test('Anthropic folds final cumulative input and cache usage without summing snapshots', async t => {
  const g = await fixture(t, async () => new Response([
    { type: 'message_start', message: { model: 'claude-sonnet-5', usage: { input_tokens: 0, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 0 } } } },
    { type: 'message_delta', usage: { input_tokens: 500, output_tokens: 20, cache_creation_input_tokens: 50, cache_read_input_tokens: 100, cache_creation: { ephemeral_5m_input_tokens: 50, ephemeral_1h_input_tokens: 0 } } },
    { type: 'message_delta', usage: { input_tokens: 1000, output_tokens: 50, cache_creation_input_tokens: 100, cache_read_input_tokens: 200, cache_creation: { ephemeral_5m_input_tokens: 100 } } },
    { type: 'message_delta', usage: { input_tokens: null, output_tokens: null, cache_creation_input_tokens: null, cache_creation: null } },
    { type: 'message_stop' },
  ].map(e => 'data: ' + JSON.stringify(e) + '\n\n').join('')));
  assert.equal((await post(g, { model: 'claude-sonnet-5', stream: true, max_tokens: 8192, messages: [] }, '/judge/v1/messages', secrets.judgeClientToken)).status, 200);
  const events = readFileSync(join(g.dir, 'ledger.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(events.at(-1).usage.input_tokens, 1000);
  assert.equal(events.at(-1).usage.output_tokens, 50);
  assert.ok(Math.abs(events.at(-1).cost - 0.00279) < 1e-9);
});

test('real transport requires explicit acceptance of unverified model ceilings before startup', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'edc-gateway-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  await assert.rejects(async () => {
    const gateway = await createGateway({ ledgerPath: join(dir, 'ledger.jsonl'), secrets });
    t.after(() => gateway.close());
  }, /unverified model ceilings/);
});

test('rejects over-limit judge output and server tools rather than silently changing requested settings', async t => {
  let calls = 0;
  const g = await fixture(t, async () => { calls++; return codexResponse(); });
  for (const body of [{ model: 'claude-sonnet-5', stream: true, max_tokens: 128001, messages: [] }, { model: 'claude-sonnet-5', stream: true, max_tokens: 8193, messages: [] }, { model: 'claude-sonnet-5', stream: true, max_tokens: 8192, messages: [], tools: [{ type: 'web_search_20250305' }] }]) {
    assert.equal((await post(g, body, '/judge/v1/messages', secrets.judgeClientToken)).status, 400);
  }
  assert.equal(calls, 0);
});

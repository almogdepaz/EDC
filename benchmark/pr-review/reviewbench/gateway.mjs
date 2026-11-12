// Pilot-only transport boundary. No reviewer filesystem, provider credentials,
// golden answers, or arbitrary forwarding destinations are exposed by this API.
import http from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
import { appendFileSync, closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { zstdDecompressSync } from 'node:zlib';

// Pi 1.4.0 bundled model catalog, frozen for list-price accounting. Prices are
// USD per million tokens. Reservations use the highest input-category rate,
// catalog input limits and the output policy, not byte/token heuristics or means.
// Codex does not send max_output_tokens: these are NOT verified server bounds.
// Real transport requires separate acceptance of this soft-budget limitation.
export const POLICY = Object.freeze({
  review: { model: 'gpt-6.1-sol', url: 'https://chatgpt.com/backend-api/codex/responses', inputLimit: 500000, outputLimit: 128000, reserve: 4.42 },
  judge: { model: 'claude-sonnet-5', url: 'https://api.anthropic.com/v1/messages', inputLimit: 1000000, outputLimit: 8192, reserve: 4.08192 },
});
const MAX_BODY = 4 * 1024 * 1024;
const MAX_RESPONSE = 32 * 1024 * 1024;
const ROUTES = { '/review/codex/responses': 'review', '/judge/v1/messages': 'judge' };

function integer(value) { return Number.isSafeInteger(value) && value >= 0; }
function validateHeaders(headers) {
  if (headers['openai-beta'] !== undefined && headers['openai-beta'] !== 'responses=experimental') throw Error('unreviewed OpenAI beta');
  if (headers['anthropic-version'] !== undefined && headers['anthropic-version'] !== '2023-06-01') throw Error('unreviewed Anthropic version');
  const betas = new Set(['claude-code-20250219', 'oauth-2025-04-20', 'fine-grained-tool-streaming-2025-05-14', 'interleaved-thinking-2025-05-14']);
  if (headers['anthropic-beta'] !== undefined && (typeof headers['anthropic-beta'] !== 'string' || headers['anthropic-beta'].split(',').some(beta => !betas.has(beta.trim())))) throw Error('unreviewed Anthropic beta');
}
function validateBody(role, body) {
  const policy = POLICY[role];
  if (!body || body.model !== policy.model || body.stream !== true) throw Error('wrong model or non-streaming request');
  if (body.previous_response_id || body.background || body.additional_tools) throw Error('stateful or hosted request unsupported');
  if (body.service_tier !== undefined && body.service_tier !== 'default') throw Error('unapproved service tier');
  if (role === 'judge' && (!integer(body.max_tokens) || body.max_tokens < 1 || body.max_tokens > policy.outputLimit)) throw Error('invalid max_tokens');
  function validateTools(tools) {
    if (!Array.isArray(tools)) throw Error('invalid tools');
    for (const tool of tools) {
      if (!tool || typeof tool !== 'object' || (role === 'review' ? !['function', 'custom'].includes(tool.type) : tool.type !== undefined && tool.type !== 'custom')) throw Error('hosted tools forbidden');
    }
  }
  if (body.tools !== undefined) validateTools(body.tools);
  if (role === 'review') {
    if (!Array.isArray(body.input)) throw Error('unsupported input form');
    const types = new Set(['message', 'reasoning', 'function_call', 'function_call_output', 'custom_tool_call', 'custom_tool_call_output', 'additional_tools', 'tool_search_call', 'tool_search_output', 'configuration_update']);
    for (const item of body.input) {
      if (!item || typeof item !== 'object' || (item.type !== undefined && !types.has(item.type))) throw Error('unsupported input item');
      if (item.type === 'additional_tools' || item.type === 'tool_search_output') validateTools(item.tools);
      if ((item.type === 'tool_search_call' || item.type === 'tool_search_output') && item.execution !== 'client') throw Error('server tool search forbidden');
    }
  }
  // Restrict the accounting envelope to text and local function/custom tools.
  function inspect(value) {
    if (!value || typeof value !== 'object') return;
    if (value.cache_control?.ttl === '1h') throw Error('long cache policy is not enabled for this pilot');
    if (['input_image', 'image', 'input_file', 'document', 'computer_20250124', 'web_search'].includes(value.type) || value.image_url !== undefined || value.file_url !== undefined) throw Error('non-text input forbidden');
    for (const item of Object.values(value)) inspect(item);
  }
  inspect(body);
}

function priceUsage(role, events) {
  if (role === 'review') {
    const finals = events.filter(e => e.type === 'response.completed');
    if (finals.length !== 1) throw Error('missing or duplicate completed response');
    const response = finals[0].response;
    if (response.model !== POLICY.review.model || response.status !== 'completed') throw Error('provider model/status mismatch');
    if (response.service_tier !== undefined && response.service_tier !== 'default') throw Error('provider service tier mismatch');
    const u = response.usage;
    if (!u || !integer(u.input_tokens) || !integer(u.output_tokens) || !integer(u.input_tokens_details?.cached_tokens)) throw Error('missing review usage');
    const cached = u.input_tokens_details.cached_tokens;
    const written = u.input_tokens_details.cache_write_tokens ?? 0;
    if (!integer(written) || cached + written > u.input_tokens || u.input_tokens > POLICY.review.inputLimit || u.output_tokens > POLICY.review.outputLimit) throw Error('usage exceeds approved model envelope');
    const tier = u.input_tokens > 272000;
    return { usage: u, cost: ((u.input_tokens - cached - written) * (tier ? 4 : 2) + cached * (tier ? 0.2 : 0.1) + written * (tier ? 5 : 2.5) + u.output_tokens * (tier ? 15 : 10)) / 1e6 };
  }
  const starts = events.filter(e => e.type === 'message_start');
  const stops = events.filter(e => e.type === 'message_stop');
  if (starts.length !== 1 || stops.length !== 1 || starts[0].message?.model !== POLICY.judge.model) throw Error('incomplete judge response or model mismatch');
  const usage = {};
  let finalOutput = false;
  for (const event of events) {
    const update = event.type === 'message_start' ? event.message?.usage : event.type === 'message_delta' ? event.usage : undefined;
    if (!update) continue;
    for (const name of ['input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens']) {
      if (update[name] === undefined || update[name] === null) continue;
      if (!integer(update[name])) throw Error('invalid judge usage');
      usage[name] = update[name];
      if (event.type === 'message_delta' && name === 'output_tokens') finalOutput = true;
    }
    if (update.cache_creation !== undefined && update.cache_creation !== null) {
      usage.cache_creation ??= {};
      for (const name of ['ephemeral_5m_input_tokens', 'ephemeral_1h_input_tokens']) {
        const count = update.cache_creation[name];
        if (count === undefined || count === null) continue;
        if (!integer(count)) throw Error('invalid cache usage bucket');
        usage.cache_creation[name] = count;
      }
    }
  }
  if (!finalOutput || !integer(usage.input_tokens) || !integer(usage.cache_creation_input_tokens) || !integer(usage.cache_read_input_tokens) || !integer(usage.output_tokens)) throw Error('missing judge usage');
  const input = usage.input_tokens + usage.cache_creation_input_tokens + usage.cache_read_input_tokens;
  if (input > POLICY.judge.inputLimit || usage.output_tokens > POLICY.judge.outputLimit) throw Error('usage exceeds approved model envelope');
  // Prefer explicit TTL buckets. Absent buckets use the documented short-cache
  // rate only when the request had no long-cache policy (validated by caller).
  const buckets = usage.cache_creation;
  let cacheCost = usage.cache_creation_input_tokens * 2.5;
  if (buckets) {
    const short = buckets.ephemeral_5m_input_tokens;
    const long = buckets.ephemeral_1h_input_tokens;
    if (!integer(short) || !integer(long) || short + long !== usage.cache_creation_input_tokens) throw Error('invalid cache usage buckets');
    cacheCost = short * 2.5 + long * 4;
  }
  return { usage, cost: (usage.input_tokens * 2 + cacheCost + usage.cache_read_input_tokens * 0.2 + usage.output_tokens * 10) / 1e6 };
}

export async function createGateway({ ledgerPath, secrets, fetchImpl = fetch, budgets = { total: 25, review: 16, judge: 9 }, host = '127.0.0.1', port = 0, evidenceDir, acceptUnverifiedModelBounds = false }) {
  if (fetchImpl === fetch && acceptUnverifiedModelBounds !== true) throw Error('live transport blocked: unverified model ceilings require explicit risk acceptance');
  for (const name of ['total', 'review', 'judge']) if (!Number.isFinite(budgets[name]) || budgets[name] < 0) throw Error('invalid budget');
  if (budgets.total > 25 || budgets.review + budgets.judge > budgets.total) throw Error('budget exceeds approved pilot ceiling');
  for (const name of ['reviewClientToken', 'judgeClientToken', 'reviewToken', 'judgeToken', 'accountId']) if (typeof secrets[name] !== 'string' || !secrets[name]) throw Error('missing credential material');
  mkdirSync(dirname(ledgerPath), { recursive: true, mode: 0o700 });
  const lockPath = ledgerPath + '.lock';
  const lock = openSync(lockPath, 'wx', 0o600);
  writeFileSync(lock, String(process.pid));
  let ledger;
  let active = false;
  let blocked = false;
  const spent = { review: 0, judge: 0 };
  const pending = new Set();
  try {
    if (existsSync(ledgerPath)) {
      for (const line of readFileSync(ledgerPath, 'utf8').split('\n').filter(Boolean)) {
        const event = JSON.parse(line);
        if (event.type === 'reserved') pending.add(event.id);
        else if (event.type === 'settled') {
          if (!pending.delete(event.id) || !['review', 'judge'].includes(event.role) || !Number.isFinite(event.cost) || event.cost < 0) throw Error('invalid ledger');
          spent[event.role] += event.cost;
        } else if (event.type === 'unknown') blocked = true;
        else throw Error('unknown ledger event');
      }
      if (pending.size) blocked = true;
    }
    ledger = openSync(ledgerPath, 'a', 0o600);
  } catch (error) { closeSync(lock); unlinkSync(lockPath); throw error; }
  function record(event) { appendFileSync(ledger, JSON.stringify({ at: new Date().toISOString(), ...event }) + '\n'); fsyncSync(ledger); }
  function errorResponse(res, status, message) { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { type: 'invalid_request_error', message } })); }
  const server = http.createServer(async (req, res) => {
    const role = ROUTES[req.url];
    if (req.method !== 'POST' || !role) return errorResponse(res, 404, 'unsupported endpoint');
    const expectedToken = secrets[role + 'ClientToken'];
    if (req.headers.authorization !== `Bearer ${expectedToken}` && (role !== 'judge' || req.headers['x-api-key'] !== expectedToken)) return errorResponse(res, 401, 'unauthorized');
    if (blocked || active) return errorResponse(res, 409, blocked ? 'unreconciled provider outcome; pilot paused' : 'another request is active');
    let body;
    let raw;
    try {
      validateHeaders(req.headers);
      const chunks = []; let length = 0;
      for await (const chunk of req) { length += chunk.length; if (length > MAX_BODY) throw Error('request too large'); chunks.push(chunk); }
      raw = Buffer.concat(chunks);
      if (req.headers['content-encoding'] === 'zstd') raw = zstdDecompressSync(raw, { maxOutputLength: MAX_BODY });
      else if (req.headers['content-encoding'] && req.headers['content-encoding'] !== 'identity') throw Error('unsupported content encoding');
      body = JSON.parse(raw.toString('utf8'));
      validateBody(role, body);
    } catch (error) { return errorResponse(res, 400, error.message); }
    // Re-check after asynchronous body reads to prevent admission races.
    if (blocked || active) return errorResponse(res, 409, 'pilot paused or request active');
    const reserve = POLICY[role].reserve;
    if (spent[role] + reserve > budgets[role] || spent.review + spent.judge + reserve > budgets.total) return errorResponse(res, 402, 'insufficient catalog-envelope request reservation');
    active = true;
    const id = randomUUID();
    try {
      record({ type: 'reserved', id, role, reserve, model: body.model, bodySha256: createHash('sha256').update(raw).digest('hex') });
      if (evidenceDir) { mkdirSync(evidenceDir, { recursive: true, mode: 0o700 }); writeFileSync(join(evidenceDir, id + '.request.json'), raw, { mode: 0o600 }); }
      const headers = { 'content-type': 'application/json', accept: 'text/event-stream', 'accept-encoding': 'identity', authorization: `Bearer ${secrets[role + 'Token']}` };
      for (const name of ['anthropic-version', 'anthropic-beta', 'user-agent', 'originator', 'version', 'openai-beta', 'session_id']) if (typeof req.headers[name] === 'string') headers[name] = req.headers[name];
      if (role === 'review') {
        headers['chatgpt-account-id'] = secrets.accountId;
        headers['openai-beta'] = 'responses=experimental';
      } else {
        headers['anthropic-version'] = '2023-06-01';
        headers['anthropic-beta'] ??= 'claude-code-20250219,oauth-2025-04-20';
        headers['x-app'] = 'cli';
        headers['anthropic-dangerous-direct-browser-access'] = 'true';
      }
      const upstream = await fetchImpl(POLICY[role].url, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(900000), redirect: 'error' });
      if (!upstream.ok) throw Error(`upstream HTTP ${upstream.status}; outcome requires reconciliation`);
      if (!upstream.body) throw Error('missing provider stream');
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store' });
      const chunks = []; let length = 0;
      for await (const chunk of upstream.body) {
        length += chunk.length; if (length > MAX_RESPONSE) throw Error('provider response too large');
        chunks.push(Buffer.from(chunk));
        if (!res.destroyed) res.write(chunk);
      }
      const responseText = Buffer.concat(chunks).toString('utf8');
      if (evidenceDir) writeFileSync(join(evidenceDir, id + '.response.sse'), responseText, { mode: 0o600 });
      const events = responseText.split(/\r?\n/).filter(line => line.startsWith('data: ') && line !== 'data: [DONE]').map(line => JSON.parse(line.slice(6)));
      const priced = priceUsage(role, events);
      if (priced.cost > reserve) throw Error('provider usage violated reservation envelope');
      record({ type: 'settled', id, role, ...priced });
      spent[role] += priced.cost;
      res.end();
    } catch (error) {
      blocked = true;
      record({ type: 'unknown', id, role, reserve, reason: error.message });
      if (!res.headersSent) errorResponse(res, 502, 'provider outcome unresolved; pilot paused');
      else res.destroy();
    } finally { active = false; }
  });
  server.headersTimeout = 30000;
  server.requestTimeout = 30000;
  await new Promise((resolveListen, reject) => { server.once('error', reject); server.listen(port, host, resolveListen); });
  return { url: `http://${host}:${server.address().port}`, close: async () => { if (active) throw Error('cannot close with an active provider request'); await new Promise(resolveClose => server.close(resolveClose)); closeSync(ledger); closeSync(lock); unlinkSync(lockPath); } };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const config = JSON.parse(readFileSync(process.argv[2], 'utf8'));
  const secrets = JSON.parse(readFileSync(config.secretsPath, 'utf8'));
  const gateway = await createGateway({ ...config, secrets });
  console.log(JSON.stringify({ listening: gateway.url, policy: POLICY }));
  let closing = false;
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, async () => { if (closing) return; closing = true; try { await gateway.close(); process.exit(0); } catch { process.exit(1); } });
}

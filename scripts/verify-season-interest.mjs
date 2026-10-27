import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { Readable } from 'node:stream';

process.env.SUPABASE_URL = 'https://league-test.invalid';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'test-only-interest-key';
process.env.VERCEL = '1';
const { default: handler } = await import('../api/season-interest.js');
const { default: adminHandler } = await import('../api/league-admin.js');
// Flush Node's asynchronous module-format warning before spying on handlers.
await new Promise(resolve => setImmediate(resolve));
const originalFetch = globalThis.fetch;
const originalConsoleError = console.error;
const logs = [];
console.error = (...args) => logs.push(args);
const valid = { email: '  Racer@Example.COM  ', platform: 'playstation', website: '' };
let requests = [];
let responseFactory = () => Response.json(true);
const mockFetch = async (url, options) => {
  requests.push({ url, options });
  return responseFactory();
};
globalThis.fetch = mockFetch;

async function call(body = valid, extra = {}, target = handler) {
  const req = { method: 'POST', headers: {}, socket: { remoteAddress: '192.0.2.10' }, body, ...extra };
  const result = { headers: {} };
  await target(req, {
    setHeader(name, value) { result.headers[name] = value; },
    status(value) { result.status = value; return this; },
    json(value) { result.body = value; return this; },
    end() { return this; },
  });
  return result;
}
function hash(address) {
  return createHmac('sha256', process.env.SUPABASE_SERVICE_ROLE_KEY).update(address).digest('hex');
}

try {
  for (const method of ['GET', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'HEAD']) {
    const result = await call(valid, { method });
    assert.equal(result.status, 405);
    assert.equal(result.headers.Allow, 'POST');
  }
  for (const body of [null, [], '', '{', 'null', ...['', 'no-email', 'a@example', '.a@example.com', 'a.@example.com', 'a..b@example.com', 'a@-example.com', 'a@exam_ple.com', `${'a'.repeat(65)}@example.com`, `${'a'.repeat(250)}@x.com`].map(email => ({ ...valid, email })),
    ...['PC', 'ps5', 'xbox ', '', null, 3, {}].map(platform => ({ ...valid, platform })),
    { ...valid, email: 123 }, { ...valid, website: false }, { ...valid, extra: 'a'.repeat(2048) }]) {
    assert.equal((await call(body)).status, 400);
  }
  assert.equal((await call(valid, { headers: { 'content-length': '2049' } })).status, 400);
  assert.equal((await call(valid, { headers: { 'content-length': '-1' } })).status, 400);
  assert.equal((await call(valid, { headers: { 'content-type': 'text/plain' } })).status, 400);
  assert.equal(requests.length, 0, 'Invalid input must not touch the database');
  const trapped = await call({ website: 'https://bot.invalid' });
  assert.deepEqual(trapped.body, { ok: true });
  assert.equal(trapped.status, 200);
  assert.equal(requests.length, 0, 'Honeypot must not touch the database');

  const success = await call();
  assert.equal(success.status, 200);
  assert.deepEqual(success.body, { ok: true });
  assert.equal(success.headers['Cache-Control'], 'no-store');
  assert.deepEqual(JSON.parse(requests.at(-1).options.body), { p_email: 'racer@example.com', p_platform: 'playstation', p_client_hash: hash('192.0.2.10') });
  assert.equal(requests.at(-1).url, 'https://league-test.invalid/rest/v1/rpc/n26_submit_season_interest');
  assert.equal(requests.at(-1).options.headers.Authorization, 'Bearer test-only-interest-key');
  assert.equal(requests.at(-1).options.method, 'POST');
  assert.ok(requests.at(-1).options.signal instanceof AbortSignal);
  // The RPC never reports whether the address already existed.
  assert.deepEqual((await call({ ...valid, platform: 'xbox' })).body, success.body);
  for (const platform of ['playstation', 'xbox', 'pc']) {
    assert.equal((await call({ ...valid, platform })).status, 200);
  }
  const boundaryEmail = `${'a'.repeat(64)}@${'b'.repeat(63)}.${'c'.repeat(63)}.${'d'.repeat(61)}`;
  assert.equal(boundaryEmail.length, 254);
  assert.equal((await call({ ...valid, email: boundaryEmail })).status, 200);
  assert.equal((await call({ ...valid, email: boundaryEmail + 'd' })).status, 400);

  await call(valid, { headers: { 'x-vercel-forwarded-for': '198.51.100.4', 'x-forwarded-for': '203.0.113.1' } });
  assert.equal(JSON.parse(requests.at(-1).options.body).p_client_hash, hash('198.51.100.4'));
  await call(valid, { headers: { 'x-vercel-forwarded-for': 'not-an-ip', 'x-forwarded-for': '203.0.113.1' } });
  assert.equal(JSON.parse(requests.at(-1).options.body).p_client_hash, hash('192.0.2.10'));
  process.env.VERCEL = '0';
  await call(valid, { headers: { 'x-vercel-forwarded-for': '198.51.100.4', 'x-forwarded-for': '203.0.113.1' } });
  assert.equal(JSON.parse(requests.at(-1).options.body).p_client_hash, hash('192.0.2.10'));
  await call(valid, { socket: { remoteAddress: '2001:db8::1' } });
  assert.equal(JSON.parse(requests.at(-1).options.body).p_client_hash, hash('2001:db8::1'));
  assert.ok(requests.every(request => !request.options.body.includes('192.0.2.10')));

  const stream = Readable.from([JSON.stringify(valid)]);
  assert.equal((await call(valid, { body: undefined, [Symbol.asyncIterator]: stream[Symbol.asyncIterator].bind(stream) })).status, 200);
  const oversized = Readable.from(['a'.repeat(1024), 'b'.repeat(1025)]);
  const beforeStream = requests.length;
  assert.equal((await call(valid, { body: undefined, [Symbol.asyncIterator]: oversized[Symbol.asyncIterator].bind(oversized) })).status, 400);
  assert.equal(requests.length, beforeStream);
  assert.equal((await call(Buffer.from(JSON.stringify(valid)))).status, 200);

  responseFactory = () => Response.json(false);
  const limited = await call();
  assert.equal(limited.status, 429);
  assert.equal(limited.headers['Retry-After'], '600');
  assert.deepEqual(limited.body, { ok: false, error: 'Too many submissions. Please try again later.' });
  for (const factory of [
    () => Response.json({ message: 'private racer@example.com test-only-interest-key' }, { status: 500 }),
    () => Response.json({ message: 'missing migration' }, { status: 404 }),
    () => Response.json({ email: 'private@example.com' }),
    () => new Response('invalid json'),
    () => { throw new Error('private racer@example.com test-only-interest-key'); },
  ]) {
    responseFactory = factory;
    const unavailable = await call();
    assert.equal(unavailable.status, 503);
    assert.deepEqual(unavailable.body, { ok: false, error: 'Interest signup is temporarily unavailable. Please try again later.' });
  }
  delete process.env.SUPABASE_SERVICE_ROLE_KEY;
  const beforeConfig = requests.length;
  assert.equal((await call()).status, 503);
  assert.equal((await call({ ...valid, email: 'bad' })).status, 400);
  assert.deepEqual((await call({ website: 'bot' })).body, { ok: true });
  assert.equal(requests.length, beforeConfig);
  assert.equal(logs.length, 0, 'Public endpoint must never log PII or errors');

  // Commissioner-only read is a separate action, not part of overview.
  const entries = [{ email: 'racer@example.com', platform: 'pc', created_at: '2026-10-27T00:00:00Z' }];
  let authorized = false;
  let reads = 0;
  globalThis.fetch = async (url, options) => {
    const path = new URL(url);
    if (path.pathname === '/auth/v1/user') return Response.json({ id: 'commissioner' });
    if (path.pathname === '/rest/v1/rpc/is_admin') return Response.json(authorized);
    assert.equal(path.pathname, '/rest/v1/n26_season_interest');
    assert.equal(path.searchParams.get('select'), 'email,platform,created_at');
    assert.equal(path.searchParams.get('order'), 'created_at.desc');
    assert.equal(options.headers.Authorization, 'Bearer test-only-interest-key');
    reads++;
    return Response.json(entries);
  };
  assert.equal((await call({ action: 'season_interest' }, {}, adminHandler)).status, 401);
  assert.equal((await call({ action: 'season_interest' }, { headers: { authorization: 'Bearer test' } }, adminHandler)).status, 403);
  assert.equal(reads, 0);
  authorized = true;
  const admin = await call({ action: 'season_interest' }, { headers: { authorization: 'Bearer test' } }, adminHandler);
  assert.equal(admin.status, 200);
  assert.deepEqual(admin.body, { ok: true, result: { entries } });
  assert.equal(reads, 1);
  console.log('Season interest API verified: validation/body limits, honeypot, normalized submissions, IP HMAC trust, duplicates, throttle, generic failures, no public exposure, commissioner-only read.');
} finally {
  globalThis.fetch = originalFetch;
  console.error = originalConsoleError;
}

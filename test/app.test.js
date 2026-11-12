// Integration tests against a real Postgres.
// Locally: `npm run db:up` first. In CI: a Postgres service container.
// Connection comes from the standard PG* env vars; defaults match compose.yaml.
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import pg from 'pg';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { insertLink, migrate } from '../src/db.js';
import { CODE_PATTERN } from '../src/links.js';

process.env.PGHOST ??= '127.0.0.1';
process.env.PGPORT ??= '5432';
process.env.PGDATABASE ??= 'links';
process.env.PGUSER ??= 'links';
process.env.PGPASSWORD ??= 'links-local-only';

const config = loadConfig({ LOG_LEVEL: 'silent', PUBLIC_BASE_URL: 'https://short.test' });

describe('with a healthy database', () => {
  let pool;
  let app;

  before(async () => {
    pool = new pg.Pool({ connectionTimeoutMillis: 2000 });
    await migrate(pool);
    app = buildApp({ config, pool });
    await app.ready();
  });

  after(async () => {
    await app.close();
    await pool.end();
  });

  it('GET /healthz is 200', async () => {
    const res = await app.inject({ method: 'GET', url: '/healthz' });
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.json(), { status: 'ok' });
  });

  it('GET /readyz is 200 when the DB answers', async () => {
    const res = await app.inject({ method: 'GET', url: '/readyz' });
    assert.equal(res.statusCode, 200);
  });

  it('POST /links then GET /{code} redirects', async () => {
    const target = 'https://example.com/some/page?q=1';
    const created = await app.inject({ method: 'POST', url: '/links', payload: { url: target } });
    assert.equal(created.statusCode, 201);
    const body = created.json();
    assert.match(body.code, CODE_PATTERN);
    assert.equal(body.target_url, target);
    assert.equal(body.short_url, `https://short.test/${body.code}`);

    const res = await app.inject({ method: 'GET', url: `/${body.code}` });
    assert.equal(res.statusCode, 302);
    assert.equal(res.headers.location, target);
    assert.equal(res.headers['cache-control'], 'no-store');
  });

  for (const [name, payload] of [
    ['javascript: URL', { url: 'javascript:alert(1)' }],
    ['non-URL', { url: 'hello' }],
    ['missing url', {}],
    ['url not a string', { url: 123 }],
    ['url too long', { url: `https://e.com/${'a'.repeat(2100)}` }],
  ]) {
    it(`POST /links rejects ${name} with 400`, async () => {
      const res = await app.inject({ method: 'POST', url: '/links', payload });
      assert.equal(res.statusCode, 400);
    });
  }

  it('POST /links rejects invalid JSON with 400', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/links',
      headers: { 'content-type': 'application/json' },
      payload: '{"url":',
    });
    assert.equal(res.statusCode, 400);
  });

  it('GET unknown code is 404', async () => {
    const res = await app.inject({ method: 'GET', url: '/zzzzzzz' });
    assert.equal(res.statusCode, 404);
  });

  it('insertLink reports a duplicate code instead of overwriting', async () => {
    const code = 'dupTest';
    await pool.query('DELETE FROM links WHERE code = $1', [code]);
    assert.equal(await insertLink(pool, code, 'https://a.example/'), true);
    assert.equal(await insertLink(pool, code, 'https://b.example/'), false);
    const { rows } = await pool.query('SELECT target_url FROM links WHERE code = $1', [code]);
    assert.equal(rows[0].target_url, 'https://a.example/');
  });

  it('migrate is safe to run concurrently (several tasks booting at once)', async () => {
    await Promise.all([migrate(pool), migrate(pool), migrate(pool)]);
  });

  it('GET /metrics exposes a latency histogram labelled by route template', async () => {
    await app.inject({ method: 'GET', url: '/abcdefg' });
    const res = await app.inject({ method: 'GET', url: '/metrics' });
    assert.equal(res.statusCode, 200);
    assert.match(res.headers['content-type'], /text\/plain/);
    assert.match(res.body, /http_request_duration_seconds_bucket\{.*route="\/:code".*status_code="404"/);
    assert.doesNotMatch(res.body, /abcdefg/, 'raw codes must not become label values');
  });
});

describe('with the database down', () => {
  let pool;
  let app;

  before(async () => {
    // Nothing listens on port 1, so every connection is refused fast.
    pool = new pg.Pool({ host: '127.0.0.1', port: 1, connectionTimeoutMillis: 500 });
    app = buildApp({ config, pool });
    await app.ready();
  });

  after(async () => {
    await app.close();
    await pool.end();
  });

  it('GET /healthz stays 200 (liveness must not depend on the DB)', async () => {
    const res = await app.inject({ method: 'GET', url: '/healthz' });
    assert.equal(res.statusCode, 200);
  });

  it('GET /readyz is 503', async () => {
    const res = await app.inject({ method: 'GET', url: '/readyz' });
    assert.equal(res.statusCode, 503);
  });

  it('POST /links is 500 without leaking the internal error', async () => {
    const res = await app.inject({ method: 'POST', url: '/links', payload: { url: 'https://e.com' } });
    assert.equal(res.statusCode, 500);
    assert.deepEqual(res.json(), { statusCode: 500, error: 'Internal Server Error' });
  });

  it('GET with a malformed code is 404 without touching the DB', async () => {
    const res = await app.inject({ method: 'GET', url: '/not-a-code!' });
    assert.equal(res.statusCode, 404);
  });
});

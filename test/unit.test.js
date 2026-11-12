import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { loadConfig } from '../src/config.js';
import { CODE_PATTERN, generateCode, normaliseTargetUrl } from '../src/links.js';

describe('generateCode', () => {
  it('produces 7-char base62 codes', () => {
    for (let i = 0; i < 1000; i++) assert.match(generateCode(), CODE_PATTERN);
  });

  it('does not repeat in a small sample', () => {
    const codes = new Set(Array.from({ length: 10_000 }, generateCode));
    assert.equal(codes.size, 10_000);
  });
});

describe('normaliseTargetUrl', () => {
  it('accepts http and https', () => {
    assert.equal(normaliseTargetUrl('https://example.com/a?b=1'), 'https://example.com/a?b=1');
    assert.equal(normaliseTargetUrl('http://example.com'), 'http://example.com/');
  });

  for (const bad of [
    'javascript:alert(1)',
    'data:text/html,<script>alert(1)</script>',
    'file:///etc/passwd',
    'ftp://example.com',
    '/relative/path',
    'not a url',
    '',
    `https://example.com/${'a'.repeat(2048)}`,
    42,
  ]) {
    it(`rejects ${JSON.stringify(bad).slice(0, 40)}`, () => {
      assert.equal(normaliseTargetUrl(bad), null);
    });
  }
});

describe('loadConfig', () => {
  it('has sensible defaults', () => {
    const c = loadConfig({});
    assert.equal(c.port, 3000);
    assert.equal(c.logLevel, 'info');
    assert.equal(c.publicBaseUrl, null);
  });

  it('normalises PUBLIC_BASE_URL to an origin', () => {
    assert.equal(loadConfig({ PUBLIC_BASE_URL: 'https://x.cloudfront.net/' }).publicBaseUrl, 'https://x.cloudfront.net');
  });

  it('fails fast on bad values', () => {
    assert.throws(() => loadConfig({ PORT: 'abc' }), /PORT/);
    assert.throws(() => loadConfig({ PORT: '70000' }), /PORT/);
    assert.throws(() => loadConfig({ LOG_LEVEL: 'loud' }), /LOG_LEVEL/);
    assert.throws(() => loadConfig({ PUBLIC_BASE_URL: 'nope' }));
  });
});

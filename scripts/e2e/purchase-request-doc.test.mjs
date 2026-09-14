#!/usr/bin/env node
import assert from 'node:assert/strict';
import { onRequestGet, onRequestPost } from '../../functions/api/pr-doc.js';

const PR_ID = 'PR-DG2026-0001';
const OBJECT_KEY = `docs/pr/${PR_ID}/00000000-0000-4000-8000-000000000001.png`;
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');

function response(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
}
function env(bucket) {
  return {
    SUPABASE_URL: 'https://project.supabase.co', SUPABASE_ANON_KEY: 'anon-key', SUPPLIER_DOCS: bucket,
  };
}
function postRequest(extraHeaders = {}) {
  return new Request(`https://preview.example/api/pr-doc?pr_id=${PR_ID}&kind=technical`, {
    method: 'POST',
    headers: {
      host: 'preview.example', origin: 'https://preview.example', Authorization: 'Bearer user-jwt',
      'x-file-name': encodeURIComponent('مخطط فني.png'),
      ...extraHeaders,
    },
    body: PNG,
  });
}
function getRequest(key = OBJECT_KEY) {
  return new Request(`https://preview.example/api/pr-doc?key=${encodeURIComponent(key)}`, {
    headers: { host: 'preview.example', origin: 'https://preview.example', Authorization: 'Bearer user-jwt' },
  });
}
async function withFetch(config, fn) {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const text = String(url);
    if (text.includes('/auth/v1/user')) return response({ email: 'employee@aldeyabi.com' });
    if (text.includes('/rpc/proc_can_see_pr')) return response(config.canSee !== false);
    if (text.includes('/rpc/pr_register_attachment')) {
      config.registrationBody = JSON.parse(init.body || '{}');
      return config.registrationFails
        ? response({ message: 'database unavailable' }, 503)
        : response({ ok: true, id: 9, object_key: config.generatedKey || OBJECT_KEY, file_name: 'مخطط فني.png' });
    }
    if (text.includes('/proc_pr_attachments?object_key=')) return response(config.registered === false ? [] : [{ id: 9 }]);
    if (text.includes('/proc_purchase_requests?id=')) return response(config.legacy ? [{ id: PR_ID }] : []);
    return response([]);
  };
  try { return await fn(); } finally { globalThis.fetch = originalFetch; }
}

let passed = 0;
function ok(message) { passed += 1; console.log(`  ✓ ${message}`); }
console.log('▶ purchase-request R2 document boundary');

{
  let writes = 0;
  const bucket = { put: async () => { writes += 1; } };
  const result = await withFetch({}, () => onRequestPost({
    request: postRequest({ 'content-length': String(20 * 1024 * 1024) }), env: env(bucket),
  }));
  assert.equal(result.status, 413); assert.equal(writes, 0);
  ok('rejects a declared oversized body before buffering or writing to R2');
}

{
  let storedKey = ''; const deleted = [];
  const bucket = {
    put: async (key) => { storedKey = key; },
    delete: async (key) => { deleted.push(key); },
  };
  const config = {};
  const result = await withFetch(config, () => onRequestPost({ request: postRequest(), env: env(bucket) }));
  const body = await result.json();
  assert.equal(result.status, 200); assert.equal(body.ok, true); assert.match(storedKey, new RegExp(`^docs/pr/${PR_ID}/`));
  assert.equal(config.registrationBody.p_key, storedKey); assert.equal(config.registrationBody.p_file_name, 'مخطط فني.png');
  assert.equal(config.registrationBody.p_kind, 'technical'); assert.deepEqual(deleted, []);
  ok('stores a validated object and registers the same key with the caller identity');
}

{
  let storedKey = ''; const deleted = [];
  const bucket = {
    put: async (key) => { storedKey = key; },
    delete: async (key) => { deleted.push(key); },
  };
  const result = await withFetch({ registrationFails: true }, () => onRequestPost({ request: postRequest(), env: env(bucket) }));
  assert.equal(result.status, 502); assert.deepEqual(deleted, [storedKey]);
  ok('removes the R2 object when database registration fails');
}

{
  let reads = 0;
  const bucket = { get: async () => { reads += 1; return { body: PNG, httpMetadata: { contentType: 'image/png' } }; } };
  const result = await withFetch({ registered: false }, () => onRequestGet({ request: getRequest(), env: env(bucket) }));
  assert.equal(result.status, 404); assert.equal(reads, 0);
  ok('knowledge of an R2 key is insufficient without a database attachment record');
}

{
  let reads = 0;
  const bucket = { get: async () => { reads += 1; return { body: PNG, httpMetadata: { contentType: 'image/png' } }; } };
  const result = await withFetch({ registered: true }, () => onRequestGet({ request: getRequest(), env: env(bucket) }));
  assert.equal(result.status, 200); assert.equal(reads, 1); assert.equal(result.headers.get('content-type'), 'image/png');
  ok('serves a registered in-scope document with hardened response headers');
}

{
  let reads = 0;
  const bucket = { get: async () => { reads += 1; return null; } };
  const result = await withFetch({ canSee: false }, () => onRequestGet({ request: getRequest(), env: env(bucket) }));
  assert.equal(result.status, 403); assert.equal(reads, 0);
  ok('request scope is enforced before touching R2');
}

console.log(`\nPurchase-request documents: ${passed} checks passed.`);

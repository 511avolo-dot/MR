#!/usr/bin/env node
import assert from 'node:assert/strict';
import { onRequestGet, onRequestPost } from '../../functions/api/portal-doc.js';

const BASE = 'https://vpfnycxzqziltsnzxbpb.supabase.co';
const REQ = 'REQ-DOC-AUTH';
const PAYMENT_KEY = `docs/pay/${REQ}/payment001.pdf`;
const REQUEST_KEY = `docs/reqdoc/${REQ}/request001.pdf`;

function env(bucket) {
  return {
    PORTAL_SUPABASE_URL: BASE,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'test-service-key',
    QUOTES_BUCKET: bucket,
  };
}

function response(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
}

async function withFetch(config, fn) {
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const text = String(url);
    if (text.includes('/auth/v1/user')) return response({ email: 'requester@aldeyabi.com' });
    if (text.includes('/portal_users?email=')) return response([{ username: 'requester', active: true }]);
    if (text.includes('/rpc/portal_can_see_request')) return response(config.canSee !== false);
    if (text.includes('/rpc/portal_effective_perm')) {
      const perm = JSON.parse(init.body || '{}').p_key;
      return response((config.perms || []).includes(perm));
    }
    if (text.includes('/portal_request_documents?storage_key=')) {
      if (config.reference === 'payment') return response([{ id: 1, payment_id: 9, active: true, verification_status: 'verified' }]);
      if (config.reference === 'request') return response([{ id: 1, payment_id: null, active: true, verification_status: 'verified' }]);
      return response([]);
    }
    return response([]);
  };
  try { return await fn(); } finally { globalThis.fetch = original; }
}

function getRequest(key) {
  return new Request(`https://preview.example/api/portal-doc?key=${encodeURIComponent(key)}`, {
    headers: { host: 'preview.example', origin: 'https://preview.example', Authorization: 'Bearer user-jwt' },
  });
}

let passed = 0;
function ok(message) { passed += 1; console.log(`  ✓ ${message}`); }
console.log('▶ portal document authorization');

{
  let reads = 0;
  const bucket = { get: async () => { reads += 1; return { body: 'secret', httpMetadata: { contentType: 'application/pdf' } }; } };
  const result = await withFetch({ reference: 'payment', perms: [] }, () => onRequestGet({ request: getRequest(PAYMENT_KEY), env: env(bucket) }));
  assert.equal(result.status, 403); assert.equal(reads, 0);
  ok('request scope alone cannot download a payment-linked document');
}

{
  let reads = 0;
  const bucket = { get: async () => { reads += 1; return { body: 'secret', httpMetadata: { contentType: 'application/pdf' } }; } };
  const result = await withFetch({ reference: 'payment', perms: ['can_see_finance'] }, () => onRequestGet({ request: getRequest(PAYMENT_KEY), env: env(bucket) }));
  assert.equal(result.status, 200); assert.equal(reads, 1);
  ok('an in-scope effective finance role can download normalized payment evidence');
}

{
  let reads = 0;
  const bucket = { get: async () => { reads += 1; return { body: 'request-doc', httpMetadata: { contentType: 'application/pdf' } }; } };
  const result = await withFetch({ reference: 'request', perms: [] }, () => onRequestGet({ request: getRequest(REQUEST_KEY), env: env(bucket) }));
  assert.equal(result.status, 200); assert.equal(reads, 1);
  ok('an in-scope requester can still download a normalized request document');
}

{
  let reads = 0;
  const bucket = { get: async () => { reads += 1; return null; } };
  const result = await withFetch({ reference: null, perms: ['can_see_finance'] }, () => onRequestGet({ request: getRequest(PAYMENT_KEY), env: env(bucket) }));
  assert.equal(result.status, 404); assert.equal(reads, 0);
  ok('knowledge of an R2 key is insufficient without an authoritative database reference');
}

{
  let writes = 0;
  const bucket = { put: async () => { writes += 1; } };
  const req = new Request(`https://preview.example/api/portal-doc?request_id=${REQ}&kind=pay`, {
    method: 'POST',
    headers: { host: 'preview.example', origin: 'https://preview.example', Authorization: 'Bearer user-jwt' },
    body: new Uint8Array([1, 2, 3]),
  });
  const result = await withFetch({ canSee: false, perms: ['can_disburse'] }, () => onRequestPost({ request: req, env: env(bucket) }));
  assert.equal(result.status, 403); assert.equal(writes, 0);
  ok('upload requires request scope even when the capability is present');
}

console.log(`\nPortal document authorization: ${passed} checks passed.`);


#!/usr/bin/env node
import assert from 'node:assert/strict';
import { onRequestPost } from '../../functions/api/portal-upload-cleanup.js';

const REF = 'vpfnycxzqziltsnzxbpb';
const KEY = 'docs/reqdoc/REQ-CLEAN/orphan001.pdf';

function env(bucket, over = {}) {
  return {
    PORTAL_SUPABASE_URL: `https://${REF}.supabase.co`,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'test-service-key',
    PORTAL_R2_BUCKET_NAME: 'aldeyabi-quotes-staging',
    CRON_SECRET: 'test-cron-secret',
    QUOTES_BUCKET: bucket,
    ...over,
  };
}

function request(secret = 'test-cron-secret') {
  return new Request('https://preview.example/api/portal-upload-cleanup', {
    method: 'POST', headers: { Authorization: `Bearer ${secret}` },
  });
}

let passed = 0;
function ok(message) { passed += 1; console.log(`  ✓ ${message}`); }

console.log('▶ bounded staging upload cleanup');

{
  const bucket = { list: async () => ({ objects: [], truncated: false }), delete: async () => {} };
  const response = await onRequestPost({
    request: request(),
    env: env(bucket, { PORTAL_SUPABASE_URL: 'https://wrongprojectref00000.supabase.co' }),
  });
  assert.equal(response.status, 403);
  ok('refuses every Supabase project except the approved staging ref');
}

{
  const bucket = { list: async () => ({ objects: [], truncated: false }), delete: async () => {} };
  const response = await onRequestPost({ request: request(), env: env(bucket, { PORTAL_R2_BUCKET_NAME: 'wrong-bucket' }) });
  assert.equal(response.status, 403);
  ok('refuses an unapproved R2 bucket identity');
}

{
  const bucket = { list: async () => ({ objects: [], truncated: false }), delete: async () => {} };
  const response = await onRequestPost({ request: request('wrong'), env: env(bucket) });
  assert.equal(response.status, 401);
  ok('requires the cron bearer secret');
}

async function runCleanup({ referenced }) {
  const deleted = [];
  const bucket = {
    list: async () => ({
      objects: [{ key: KEY, uploaded: new Date(Date.now() - 2 * 60 * 60 * 1000) }],
      truncated: false,
    }),
    delete: async (keys) => { deleted.push(...(Array.isArray(keys) ? keys : [keys])); },
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    const text = String(url);
    if (text.includes('portal_upload_receipts?consumed_at=is.null&expires_at=')) {
      return new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    if (referenced && text.includes('portal_request_documents?storage_key=')) {
      return new Response(JSON.stringify([{ storage_key: KEY }]), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    return new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  try {
    const response = await onRequestPost({ request: request(), env: env(bucket) });
    return { response, body: await response.json(), deleted };
  } finally {
    globalThis.fetch = originalFetch;
  }
}

{
  const result = await runCleanup({ referenced: false });
  assert.equal(result.response.status, 200);
  assert.deepEqual(result.deleted, [KEY]);
  assert.equal(result.body.orphanObjects.deleted, 1);
  assert.deepEqual(result.body.bounded, { maxExpiredReceipts: 50, maxListPages: 2, listPageSize: 100 });
  ok('deletes an old unreferenced object within explicit scan bounds');
}

{
  const result = await runCleanup({ referenced: true });
  assert.equal(result.response.status, 200);
  assert.deepEqual(result.deleted, []);
  assert.equal(result.body.orphanObjects.deleted, 0);
  ok('preserves an object referenced by normalized document history');
}

console.log(`\nPortal upload cleanup: ${passed} checks passed.`);


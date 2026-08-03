#!/usr/bin/env node
import assert from 'node:assert/strict';
import { onRequestPost } from '../../functions/api/portal-upload-cleanup.js';

const REF = 'vpfnycxzqziltsnzxbpb';
const KEY = 'docs/reqdoc/REQ-CLEAN/orphan001.pdf';
const SENTINEL = 'aldeyabi-quotes-staging|portal-upload-cleanup|v1';

function env(bucket, over = {}) {
  return {
    PORTAL_SUPABASE_URL: `https://${REF}.supabase.co`,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'test-service-key',
    PORTAL_R2_BUCKET_NAME: 'aldeyabi-quotes-staging',
    CRON_SECRET: 'test-cron-secret',
    QUOTES_BUCKET: {
      get: async () => ({ text: async () => SENTINEL }),
      ...bucket,
    },
    ...over,
  };
}

function request(secret = 'test-cron-secret', body) {
  return new Request('https://preview.example/api/portal-upload-cleanup', {
    method: 'POST',
    headers: { Authorization: `Bearer ${secret}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
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
  let storageTouched = false;
  const bucket = {
    get: async () => ({ text: async () => 'not-the-staging-sentinel' }),
    list: async () => { storageTouched = true; return { objects: [], truncated: false }; },
    delete: async () => { storageTouched = true; },
  };
  const response = await onRequestPost({ request: request(), env: env(bucket) });
  assert.equal(response.status, 403);
  assert.equal(storageTouched, false);
  ok('refuses cleanup when the bound R2 bucket lacks the staging-only sentinel');
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

{
  const deleted = [];
  let receiptLookup = '';
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
    if (text.includes('portal_upload_receipts?storage_key=')) {
      receiptLookup = text;
      const incorrectlyPreserved = !text.includes('consumed_at=is.null') || !text.includes('expires_at=gt.');
      return new Response(JSON.stringify(incorrectlyPreserved ? [{ storage_key: KEY }] : []), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }
    return new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  try {
    const response = await onRequestPost({ request: request(), env: env(bucket) });
    assert.equal(response.status, 200);
    assert.match(receiptLookup, /consumed_at=is\.null/);
    assert.match(receiptLookup, /expires_at=gt\./);
    assert.deepEqual(deleted, [KEY]);
  } finally {
    globalThis.fetch = originalFetch;
  }
  ok('consumed or expired receipts do not preserve an otherwise orphaned object');
}

{
  const seen = [];
  const deleted = [];
  const lateKey = 'docs/reqdoc/REQ-CLEAN/orphan999.pdf';
  const bucket = {
    list: async ({ cursor }) => {
      seen.push(cursor || null);
      if (!cursor) return { objects: [], truncated: true, cursor: 'page-2' };
      if (cursor === 'page-2') return { objects: [], truncated: true, cursor: 'page-3' };
      return {
        objects: [{ key: lateKey, uploaded: new Date(Date.now() - 2 * 60 * 60 * 1000) }],
        truncated: false,
      };
    },
    delete: async (keys) => { deleted.push(...(Array.isArray(keys) ? keys : [keys])); },
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response('[]', { status: 200, headers: { 'Content-Type': 'application/json' } });
  try {
    const first = await onRequestPost({ request: request(), env: env(bucket) });
    const firstBody = await first.json();
    assert.equal(firstBody.orphanObjects.nextCursor, 'page-3');
    const second = await onRequestPost({ request: request('test-cron-secret', { cursor: firstBody.orphanObjects.nextCursor }), env: env(bucket) });
    const secondBody = await second.json();
    assert.equal(second.status, 200);
    assert.equal(secondBody.orphanObjects.nextCursor, null);
    assert.deepEqual(seen, [null, 'page-2', 'page-3']);
    assert.deepEqual(deleted, [lateKey]);
  } finally {
    globalThis.fetch = originalFetch;
  }
  ok('returns and accepts a continuation cursor so later pages are eventually scanned');
}

{
  const bucket = { list: async () => ({ objects: [], truncated: false }), delete: async () => {} };
  const response = await onRequestPost({ request: request('test-cron-secret', { cursor: '\u0000bad' }), env: env(bucket) });
  assert.equal(response.status, 400);
  ok('rejects malformed continuation cursors before touching storage');
}

console.log(`\nPortal upload cleanup: ${passed} checks passed.`);

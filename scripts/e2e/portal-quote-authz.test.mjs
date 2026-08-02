#!/usr/bin/env node
import assert from 'node:assert/strict';
import { onRequestGet } from '../../functions/api/portal-quote.js';

const originalFetch = globalThis.fetch;
const key = 'quotes/REQ-TEST-1/abcdef123456.pdf';

function request(){
  return new Request(`https://preview.example/api/portal-quote?key=${encodeURIComponent(key)}`, {
    headers: {
      host: 'preview.example',
      origin: 'https://preview.example',
      authorization: 'Bearer user-jwt'
    }
  });
}

function env(bucket){
  return {
    PORTAL_SUPABASE_URL: 'https://staging-example.supabase.co',
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'fixture-only',
    QUOTES_BUCKET: bucket
  };
}

function mockFetch({ canSee = true, canView = true, viewStatus = 200 } = {}){
  const calls = [];
  globalThis.fetch = async (url, options = {}) => {
    const value = String(url);
    calls.push({ url: value, options });
    if (value.endsWith('/auth/v1/user')) return new Response(JSON.stringify({ email: 'buyer@example.test' }), { status: 200 });
    if (value.includes('/rest/v1/portal_users?')) return new Response(JSON.stringify([{ username: 'buyer', active: true }]), { status: 200 });
    if (value.endsWith('/rest/v1/rpc/portal_can_see_request')) return new Response(JSON.stringify(canSee), { status: 200 });
    if (value.endsWith('/rest/v1/rpc/portal_can_view_quotes')) return new Response(JSON.stringify(canView), { status: viewStatus });
    throw new Error('Unexpected fetch: ' + value);
  };
  return calls;
}

try {
  console.log('▶ portal-quote confidential document authorization');

  {
    const calls = mockFetch({ canSee: true, canView: false });
    let bucketReads = 0;
    const response = await onRequestGet({
      request: request(),
      env: env({ get: async () => { bucketReads += 1; return null; } })
    });
    assert.equal(response.status, 403);
    assert.equal(bucketReads, 0);
    assert.equal(calls.some((call) => call.url.endsWith('/rest/v1/rpc/portal_can_view_quotes')), true);
    console.log('  ✓ requester visibility alone cannot retrieve a confidential quotation file');
  }

  {
    mockFetch({ canSee: true, canView: true });
    let bucketReads = 0;
    const response = await onRequestGet({
      request: request(),
      env: env({
        get: async () => {
          bucketReads += 1;
          return {
            body: new Uint8Array([0x25, 0x50, 0x44, 0x46]),
            httpMetadata: { contentType: 'application/pdf' }
          };
        }
      })
    });
    assert.equal(response.status, 200);
    assert.equal(bucketReads, 1);
    assert.equal(response.headers.get('content-type'), 'application/pdf');
    console.log('  ✓ authorized quotation viewer can retrieve the R2 object');
  }

  {
    mockFetch({ canSee: true, canView: true, viewStatus: 500 });
    let bucketReads = 0;
    const response = await onRequestGet({
      request: request(),
      env: env({ get: async () => { bucketReads += 1; return null; } })
    });
    assert.equal(response.status, 403);
    assert.equal(bucketReads, 0);
    console.log('  ✓ quote permission RPC failure is fail-closed');
  }
} finally {
  globalThis.fetch = originalFetch;
}

#!/usr/bin/env node
import assert from 'node:assert/strict';

const base = String(process.env.PREVIEW_BASE_URL || '').replace(/\/$/, '');
const expectedRef = String(process.env.EXPECTED_STAGING_REF || '');
const expectedBranch = String(process.env.EXPECTED_PREVIEW_BRANCH || '');
const prodRef = 'mwbjoysuybgbrvfrprex';
const attempts = Number(process.env.MAX_ATTEMPTS || 90);
const delayMs = Number(process.env.DELAY_MS || 5000);

if (!/^https:\/\/[a-z0-9-]+\.aldeyabi-procurement\.pages\.dev$/i.test(base)) {
  throw new Error('PREVIEW_BASE_URL must be the approved aldeyabi-procurement Cloudflare Pages preview host.');
}
if (!/^[a-z0-9]{20}$/.test(expectedRef) || expectedRef === prodRef) {
  throw new Error('EXPECTED_STAGING_REF is missing, malformed, or points to production.');
}
if (!expectedBranch || expectedBranch === 'main') {
  throw new Error('EXPECTED_PREVIEW_BRANCH must be the non-main PR branch.');
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function fetchNoStore(path, init = {}) {
  return fetch(base + path, {
    redirect: 'follow', cache: 'no-store', ...init,
    headers: { 'cache-control': 'no-store', ...(init.headers || {}) },
  });
}

function assertNoProductionReference(text, label) {
  assert.equal(String(text).includes(prodRef), false, `${label} contains the forbidden production project reference.`);
}

async function probeOnce() {
  const configResponse = await fetchNoStore('/api/portal-config');
  if (configResponse.status !== 200) return { ready: false, reason: `portal-config HTTP ${configResponse.status}` };

  let config;
  try { config = await configResponse.json(); }
  catch { return { ready: false, reason: 'portal-config did not return JSON' }; }
  if (config?.ok !== true) return { ready: false, reason: 'portal-config is not ready' };

  assert.equal(config.env, 'preview', 'portal-config env must be preview.');
  assert.equal(config.branch, expectedBranch, 'portal-config branch does not match the PR branch.');
  assert.equal(config.ref, expectedRef, 'portal-config ref does not match isolated staging.');
  assert.equal(config.url, `https://${expectedRef}.supabase.co`, 'portal-config URL does not match isolated staging.');
  assert.equal(typeof config.anonKey, 'string', 'portal-config anonKey is missing.');
  assert.ok(config.anonKey.length >= 20, 'portal-config anonKey is unexpectedly short.');
  assert.equal(config.anonKey.startsWith('sb_secret_'), false, 'portal-config exposed a secret key shape.');
  assertNoProductionReference(config.url, 'portal-config URL');
  assertNoProductionReference(config.ref, 'portal-config ref');

  const authSettings = await fetch(`${config.url}/auth/v1/settings`, {
    headers: { apikey: config.anonKey, 'cache-control': 'no-store' }, cache: 'no-store',
  });
  assert.equal(authSettings.status, 200, 'The staging anon/publishable key failed the live Supabase Auth probe.');

  const portalResponse = await fetchNoStore('/purchase-portal.html');
  if (portalResponse.status !== 200) return { ready: false, reason: `purchase-portal HTTP ${portalResponse.status}` };
  const portalHtml = await portalResponse.text();
  assertNoProductionReference(portalHtml, 'purchase portal HTML');

  const requiredMarkers = [
    '/assets/generated-document-studio.css?v=1',
    '/assets/quote-document-studio.css?v=1',
    '/assets/access-inspector.css?v=1',
    '/assets/document-studio.js?v=2',
    '/assets/generated-document-studio.js?v=1',
    '/assets/quote-document-studio.js?v=1',
    '/assets/policy-studio.js?v=1',
    '/assets/access-inspector.js?v=1',
    '/assets/payment-evidence-guard.js?v=1',
  ];
  const missing = requiredMarkers.filter((marker) => !portalHtml.includes(marker));
  if (missing.length) return { ready: false, reason: `latest functional/security assets not propagated (${missing.length} missing)` };

  // Owner rejected the enterprise visual override. It must not be injected.
  assert.equal(portalHtml.includes('href="/assets/enterprise-ui.css'), false, 'Rejected enterprise CSS is still injected.');
  assert.equal(portalHtml.includes('src="/assets/enterprise-ui.js'), false, 'Rejected enterprise interaction layer is still injected.');

  for (const asset of [
    '/assets/document-studio.js?v=2',
    '/assets/generated-document-studio.js?v=1',
    '/assets/quote-document-studio.js?v=1',
    '/assets/policy-studio.js?v=1',
    '/assets/access-inspector.js?v=1',
    '/assets/payment-evidence-guard.js?v=1',
  ]) {
    const response = await fetchNoStore(asset);
    assert.equal(response.status, 200, `Required preview asset failed: ${asset.split('?')[0]}`);
  }

  const paymentGuardResponse = await fetchNoStore('/assets/payment-evidence-guard.js?v=1');
  const paymentGuard = await paymentGuardResponse.text();
  assert.match(paymentGuard, /portal_payment_request/);
  assert.match(paymentGuard, /proof_key/);
  assert.match(paymentGuard, /pa_docUpload/);

  const origin = new URL(base).origin;
  const quoteResponse = await fetchNoStore('/api/portal-quote?key=quotes/REQ-TEST-1/abcdef123456.pdf', { headers: { Origin: origin } });
  assert.equal(quoteResponse.status, 401, 'Unauthenticated quotation retrieval must return HTTP 401.');

  const documentResponse = await fetchNoStore('/api/portal-doc?key=docs/reqdoc/REQ-TEST-1/abcdef123456.pdf', { headers: { Origin: origin } });
  assert.equal(documentResponse.status, 401, 'Unauthenticated supporting-document retrieval must return HTTP 401.');

  return { ready: true };
}

console.log('▶ Hosted Cloudflare Preview smoke gate');
console.log(`  Preview host: ${new URL(base).host}`);
console.log(`  Expected environment: preview / isolated staging ${expectedRef}`);

let lastReason = 'not started';
for (let attempt = 1; attempt <= attempts; attempt += 1) {
  try {
    const result = await probeOnce();
    if (result.ready) {
      console.log('  ✓ portal-config resolves only to isolated staging');
      console.log('  ✓ staging anon/publishable key passed the live Auth probe');
      console.log('  ✓ owner-approved legacy design is restored; functional/security assets are deployed');
      console.log('  ✓ payment evidence guard is present in the hosted Preview');
      console.log('  ✓ unauthenticated quotation and supporting-document reads are denied');
      console.log(`\nHosted Preview smoke gate: PASS (attempt ${attempt}/${attempts}).`);
      process.exit(0);
    }
    lastReason = result.reason;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/fetch failed|ECONN|ENOTFOUND|HTTP 404|HTTP 503|not propagated/i.test(message)) lastReason = message;
    else throw error;
  }
  if (attempt < attempts) {
    console.log(`  … waiting for Preview propagation (${attempt}/${attempts}): ${lastReason}`);
    await sleep(delayMs);
  }
}

throw new Error(`Hosted Preview did not become ready after ${attempts} attempts. Last state: ${lastReason}`);

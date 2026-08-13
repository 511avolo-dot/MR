#!/usr/bin/env node
// Contract test for the authenticated-E2E isolated-target guard. Proves the journey
// aborts (guard throws) whenever the hosted portal-config could point at production,
// including the key case: staging ref advertised with a production URL.
import assert from 'node:assert/strict';
import { validateTarget, PROD_REF } from './target-guard.mjs';

const STAGING = 'vpfnycxzqziltsnzxbpb';
const ok = { ok: true, env: 'preview', ref: STAGING, url: `https://${STAGING}.supabase.co`, anonKey: 'sb_publishable_x' };
const throws = (cfg, ref, label) => {
  assert.throws(() => validateTarget(cfg, ref), (e) => e instanceof Error, `must reject: ${label}`);
  console.log(`  PASS reject — ${label}`);
};

// Positive: a well-formed isolated-staging config passes.
assert.equal(validateTarget(ok, STAGING), true);
console.log('  PASS accept — valid isolated staging config');

// Negative controls:
throws({ ...ok, url: `https://${PROD_REF}.supabase.co` }, STAGING, 'staging ref but PRODUCTION url');   // the owner's case
throws({ ...ok, ref: PROD_REF, url: `https://${PROD_REF}.supabase.co` }, PROD_REF, 'production ref+url');
throws({ ...ok, url: 'https://evil.example.com' }, STAGING, 'url host not <ref>.supabase.co');
throws({ ...ok, url: `https://other0000000000000.supabase.co` }, STAGING, 'url ref != expected ref');
throws({ ...ok, env: 'production' }, STAGING, 'env not preview');
throws({ ...ok, ok: false }, STAGING, 'portal-config not ok');
throws({ ...ok }, PROD_REF, 'expected ref is the production ref');
throws({ ...ok, url: 'not-a-url' }, STAGING, 'malformed url');

console.log('\n✅ target-guard: 1 accept + 8 reject = 9/9 PASS');

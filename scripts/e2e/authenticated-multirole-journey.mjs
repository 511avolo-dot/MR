#!/usr/bin/env node
/*
 * Authenticated multi-role hosted journey (System 3) — READY-TO-RUN scaffold.
 *
 * Advances binding blocker #1 (authenticated multi-role browser/RLS journeys
 * against hosted Preview/Staging). It performs a REAL Supabase login through the
 * real portal login contract (#pa-email / #pa-pass / #pa-lg-btn) for each
 * owner-supplied role identity, then asserts per-role authorization visibility
 * (positive tabs present, forbidden tabs absent) and cross-environment isolation.
 *
 * For each role it also runs **server-side** authorization/RLS probes through the
 * real authenticated Supabase session (not just client nav): other-user readability
 * on portal_users (RLS self/admin), portal_user_directory safe-column surface,
 * server-evaluated portal_has_perm, and the finance/admin-only portal_audit_verify.
 *
 * SAFETY / SCOPE:
 *  - Credential-gated. With no STAGING_E2E_USERS it SKIPS (exit 0), so CI stays
 *    green and this file is inert until the owner provides staging test users.
 *  - Read-only in the app: it logs in and runs read-only authz/RLS probes. It does
 *    NOT create/approve/disburse — the state-mutating cross-role lifecycle stays in
 *    the SQL suite + the DB-level live verification until a dedicated seed+teardown
 *    is authorized. Those hooks are marked TODO and are not claimed as executed.
 *  - Isolation-guarded: refuses to run unless /api/portal-config resolves to the
 *    expected isolated staging ref, and never to the production project.
 *  - Never prints passwords or tokens.
 *
 * REQUIRED ENV (all absent ⇒ SKIP):
 *  - PREVIEW_BASE_URL        hosted Cloudflare Pages preview host (…pages.dev)
 *  - EXPECTED_STAGING_REF    isolated staging Supabase ref (20 lowercase alnum)
 *  - STAGING_E2E_USERS       JSON: { "<role>": { "email","password",
 *                              "expectTabs":[…], "denyTabs":[…], "admin":bool,
 *                              "finance":bool, "expectManageUsers":bool,
 *                              "expectAuditVerify":bool } }
 *                              (expectManageUsers defaults to admin; expectAuditVerify
 *                               defaults to admin||finance.)
 *
 * RUN: PREVIEW_BASE_URL=… EXPECTED_STAGING_REF=… STAGING_E2E_USERS='{…}' \
 *      node scripts/e2e/authenticated-multirole-journey.mjs
 */
import assert from 'node:assert/strict';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
const base = String(process.env.PREVIEW_BASE_URL || '').replace(/\/$/, '');
const expectedRef = String(process.env.EXPECTED_STAGING_REF || '');
const rawUsers = String(process.env.STAGING_E2E_USERS || '').trim();
const navTimeout = Number(process.env.E2E_NAV_TIMEOUT_MS || 45000);

function skip(reason) {
  console.log(`↷ authenticated-multirole-journey SKIPPED — ${reason}`);
  console.log('  (provide PREVIEW_BASE_URL + EXPECTED_STAGING_REF + STAGING_E2E_USERS to run.)');
  process.exit(0);
}

if (!rawUsers) skip('no STAGING_E2E_USERS supplied');

let users;
try { users = JSON.parse(rawUsers); }
catch { throw new Error('STAGING_E2E_USERS must be valid JSON.'); }
const roleNames = Object.keys(users || {});
if (!roleNames.length) skip('STAGING_E2E_USERS is empty');

if (!/^https:\/\/[a-z0-9-]+\.aldeyabi-procurement\.pages\.dev$/i.test(base)) {
  throw new Error('PREVIEW_BASE_URL must be the approved aldeyabi-procurement Cloudflare Pages preview host.');
}
if (!/^[a-z0-9]{20}$/.test(expectedRef) || expectedRef === PROD_REF) {
  throw new Error('EXPECTED_STAGING_REF is missing, malformed, or points to production.');
}

// Playwright is only present in the browser CI job / when installed locally.
let chromium;
try { ({ chromium } = await import('playwright')); }
catch { skip('playwright is not installed in this environment'); }

// ── Isolation pre-flight: the hosted target must resolve to isolated staging ──
const cfgRes = await fetch(`${base}/api/portal-config`, { cache: 'no-store' });
assert.equal(cfgRes.status, 200, 'portal-config must be reachable (HTTP 200).');
const cfg = await cfgRes.json();
assert.equal(cfg?.ok, true, 'portal-config must report ok:true.');
assert.equal(cfg.env, 'preview', 'portal-config env must be preview (never production).');
assert.equal(cfg.ref, expectedRef, 'portal-config ref must match the isolated staging ref.');
assert.equal(String(cfg.ref).includes(PROD_REF), false, 'portal-config must never expose the production ref.');
assert.equal(String(cfg.url).includes(PROD_REF), false, 'portal-config URL must never expose the production ref.');
console.log('▶ Authenticated multi-role hosted journey');
console.log(`  Target: ${new URL(base).host}  · isolated staging ${expectedRef}`);

// Optional proxy for constrained runners (e.g. an agent sandbox). CI needs neither.
const pwProxy = process.env.PW_PROXY ? { server: process.env.PW_PROXY } : undefined;
const insecureTLS = process.env.PW_INSECURE === '1';
const browser = await chromium.launch({
  args: ['--no-sandbox'], proxy: pwProxy,
  executablePath: process.env.PW_EXECUTABLE || undefined, // pinned browser on constrained runners
});
let failures = 0;

for (const role of roleNames) {
  const u = users[role] || {};
  const u_admin = !!u.admin;
  if (!u.email || !u.password) { console.log(`  ✗ ${role}: missing email/password`); failures++; continue; }
  const expectTabs = Array.isArray(u.expectTabs) ? u.expectTabs : [];
  const denyTabs = Array.isArray(u.denyTabs) ? u.denyTabs : [];
  const ctx = await browser.newContext({ ignoreHTTPSErrors: insecureTLS }); // fresh session per role — no bleed
  const page = await ctx.newPage();
  try {
    await page.goto(`${base}/purchase-portal.html`, { waitUntil: 'domcontentloaded', timeout: navTimeout });
    await page.waitForSelector('#pa-login', { state: 'visible', timeout: navTimeout });
    await page.fill('#pa-email', u.email);
    await page.fill('#pa-pass', u.password);
    await page.click('#pa-lg-btn');

    // Success = ME resolved + login overlay gone; else surface the on-screen error.
    const outcome = await page.waitForFunction(() => {
      const overlay = document.getElementById('pa-login');
      const hidden = !overlay || overlay.style.display === 'none' || overlay.offsetParent === null;
      if (window.ME && hidden) return { ok: true };
      const err = (document.getElementById('pa-lg-err') || {}).textContent || window.__paReason || '';
      return err ? { ok: false, err: String(err) } : false;
    }, { timeout: navTimeout }).then((h) => h.jsonValue());

    if (!outcome.ok) { console.log(`  ✗ ${role}: login failed — ${outcome.err}`); failures++; continue; }

    // Role-scoped authorization visibility, read from the app's own gating.
    const view = await page.evaluate(() => ({
      me: window.ME,
      allowed: (window.TABS || []).filter((t) => window.navAllowed(t[0])).map((t) => t[0]),
      access: typeof window.accessOf === 'function' ? window.accessOf(window.ME) : null,
    }));
    assert.ok(view.me, `${role}: window.ME must be set after login.`);

    const missing = expectTabs.filter((t) => !view.allowed.includes(t));
    const leaked = denyTabs.filter((t) => view.allowed.includes(t));
    assert.equal(missing.length, 0, `${role}: expected tab(s) not visible: ${missing.join(', ')}`);
    assert.equal(leaked.length, 0, `${role}: forbidden tab(s) leaked into nav: ${leaked.join(', ')}`);

    // ── Server-side authorization / RLS probes via the real authenticated session ──
    // (client-side nav visibility is NOT an authorization boundary; these hit the DB.)
    // Each probe returns BOTH data and the raw Supabase error so we never treat a
    // transport/schema/RPC failure as a passing negative result.
    const probes = await page.evaluate(async () => {
      const pack = (r) => ({ rows: Array.isArray(r.data) ? r.data.length : null, data: r.data,
        err: r.error ? { code: r.error.code || null, msg: String(r.error.message || '') } : null });
      const out = {};
      try {
        const me = window.ME;
        out.users = pack(await window.SB.from('portal_users').select('username,email').neq('username', me).limit(5));
        out.dir = pack(await window.SB.from('portal_user_directory').select('*').limit(1));
        out.dirKeys = (out.dir.data && out.dir.data[0]) ? Object.keys(out.dir.data[0]).sort() : [];
        out.perm = pack(await window.SB.rpc('portal_has_perm', { p_key: 'can_manage_users' }));
        out.audit = pack(await window.SB.rpc('portal_audit_verify'));
      } catch (e) { out.fatal = String(e); }
      return out;
    });
    if (probes.fatal) throw new Error(`${role}: probe fatal — ${probes.fatal}`);

    const expManage = (u.expectManageUsers !== undefined) ? !!u.expectManageUsers : u_admin;
    const expAudit = (u.expectAuditVerify !== undefined) ? !!u.expectAuditVerify : (u_admin || !!u.finance);
    const DENY = /permission|denied|not.*allow|صلاحية|غير مخوّل|غير مصرّح/i; // permission-denied signature
    const isDenied = (e) => !!e && (e.code === 'P0001' || e.code === '42501' || DENY.test(e.msg));
    let pos = 0, neg = 0;

    // P-RLS (portal_users): the query must SUCCEED (error === null); RLS then filters rows.
    assert.equal(probes.users.err, null, `${role}: portal_users query errored (${probes.users.err && probes.users.err.msg}) — cannot infer RLS from a failed query`);
    if (u_admin) { assert.ok(probes.users.rows > 0, `${role}: admin should read other portal_users rows`); pos++; }
    else { assert.equal(probes.users.rows, 0, `${role}: non-admin read ${probes.users.rows} other portal_users rows (RLS breach)`); neg++; }

    // P-DIR: the safe view must be readable (error === null), return its allowed columns,
    //        and never expose sensitive ones. An errored/empty shape does NOT pass.
    assert.equal(probes.dir.err, null, `${role}: portal_user_directory query errored (${probes.dir.err && probes.dir.err.msg})`);
    assert.ok(probes.dir.rows >= 1, `${role}: portal_user_directory returned no rows — cannot prove safe surface`);
    for (const need of ['username', 'display_name']) assert.ok(probes.dirKeys.includes(need), `${role}: safe directory missing expected column "${need}"`);
    for (const forbidden of ['email', 'permissions', 'role', 'job_key', 'delegate_to']) assert.equal(probes.dirKeys.includes(forbidden), false, `${role}: portal_user_directory leaked column "${forbidden}"`);
    pos++;

    // P-PERM: server-evaluated capability. The RPC must succeed; its value must match.
    assert.equal(probes.perm.err, null, `${role}: portal_has_perm errored (${probes.perm.err && probes.perm.err.msg})`);
    assert.equal(probes.perm.data === true, expManage, `${role}: can_manage_users server-eval=${probes.perm.data}, expected ${expManage}`);
    expManage ? pos++ : neg++;

    // P-AUDIT: finance/admin-only. Positive ⇒ error null + ok:true. Negative ⇒ a SPECIFIC
    //          permission denial (not any error — a network/missing-fn error must NOT pass).
    if (expAudit) {
      assert.equal(probes.audit.err, null, `${role}: audit_verify should be allowed but errored (${probes.audit.err && probes.audit.err.msg})`);
      assert.ok(probes.audit.data && (probes.audit.data.ok === true || probes.audit.data.ok === undefined), `${role}: audit_verify returned unexpected payload`);
      pos++;
    } else {
      assert.ok(isDenied(probes.audit.err), `${role}: audit_verify should be DENIED with a permission signature, got ${JSON.stringify(probes.audit.err)}`);
      neg++;
    }

    console.log(`  ✓ ${role} (${view.me}) — nav ${JSON.stringify(view.allowed)}; server probes ${pos} positive / ${neg} negative PASS (users.err=null rows=${probes.users.rows}; dir cols=${JSON.stringify(probes.dirKeys)}; manageUsers=${probes.perm.data}; auditVerify=${expAudit ? 'ok' : 'denied:'+(probes.audit.err&&probes.audit.err.code)})`);
    // TODO(owner-authorized seed): state-mutating cross-role lifecycle (create→approve→
    //   PO→disburse→receipt) + browser-driven forbidden-transition probes require a
    //   disposable seed + teardown; not executed here. Server-side authz/RLS/SoD/financial
    //   negatives are already proven at DB level in LIVE_STAGING_VERIFICATION_2026-08-04.md.
  } catch (e) {
    console.log(`  ✗ ${role}: ${(e && e.message) || e}`);
    failures++;
  } finally {
    await ctx.close();
  }
}

await browser.close();
if (failures) throw new Error(`Authenticated multi-role journey: ${failures} role(s) failed.`);
console.log(`\nAuthenticated multi-role journey: PASS (${roleNames.length} role(s)).`);
process.exit(0);

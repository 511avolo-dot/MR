#!/usr/bin/env node
/*
 * Authenticated multi-role hosted journey (System 3).
 *
 * Performs a REAL Supabase login through the real portal login contract
 * (#pa-email / #pa-pass / #pa-lg-btn) for each owner-supplied role identity, then
 * runs authorization/RLS probes as authenticated REST calls using the browser's
 * own persisted session token — proving server-side enforcement per role from the
 * real hosted app.
 *
 * SAFETY / SCOPE:
 *  - Credential-gated: with no STAGING_E2E_USERS it SKIPS (exit 0), so CI stays green.
 *  - Read-only: it logs in and issues read-only authz/RLS probes. It does NOT
 *    create/approve/disburse — the state-mutating cross-role lifecycle stays in the
 *    SQL suite + DB-level live verification until a disposable seed+teardown is
 *    authorized (marked TODO, not claimed as executed).
 *  - Isolation-guarded: refuses to run unless /api/portal-config resolves to the
 *    expected isolated staging ref, never the production project.
 *  - Never prints passwords or tokens.
 *
 * REQUIRED ENV (all absent ⇒ SKIP):
 *  - PREVIEW_BASE_URL        hosted Cloudflare Pages preview host (…pages.dev)
 *  - EXPECTED_STAGING_REF    isolated staging Supabase ref (20 lowercase alnum)
 *  - STAGING_E2E_USERS       JSON: { "<role>": { "email","password","admin":bool,
 *                              "finance":bool, "expectManageUsers":bool,
 *                              "expectAuditVerify":bool } }
 *                              (expectManageUsers defaults to admin; expectAuditVerify
 *                               defaults to admin||finance.)
 *
 * OPTIONAL ENV for constrained runners (CI needs none):
 *  - PW_EXECUTABLE  path to a pinned Chromium binary
 *  - PW_PROXY       proxy server for chromium.launch
 *  - PW_INSECURE=1  ignore TLS errors (intercepting proxy)
 *  - PW_RELAY=1     relay every browser request through Node fetch (when the browser
 *                   cannot egress directly but Node can)
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
try { users = JSON.parse(rawUsers); } catch { throw new Error('STAGING_E2E_USERS must be valid JSON.'); }
const roleNames = Object.keys(users || {});
if (!roleNames.length) skip('STAGING_E2E_USERS is empty');

if (!/^https:\/\/[a-z0-9-]+\.aldeyabi-procurement\.pages\.dev$/i.test(base)) {
  throw new Error('PREVIEW_BASE_URL must be the approved aldeyabi-procurement Cloudflare Pages preview host.');
}
if (!/^[a-z0-9]{20}$/.test(expectedRef) || expectedRef === PROD_REF) {
  throw new Error('EXPECTED_STAGING_REF is missing, malformed, or points to production.');
}

let chromium;
try { ({ chromium } = await import('playwright')); }
catch { skip('playwright is not installed in this environment'); }

const pwProxy = process.env.PW_PROXY ? { server: process.env.PW_PROXY } : undefined;
const insecureTLS = process.env.PW_INSECURE === '1';
const useRelay = process.env.PW_RELAY === '1';
async function attachRelay(ctx) {
  await ctx.route('**', async (route) => {
    const req = route.request();
    const url = req.url();
    if (!/^https?:/i.test(url)) return route.continue();
    try {
      const method = req.method();
      const headers = { ...req.headers() }; delete headers['accept-encoding'];
      const body = ['GET', 'HEAD'].includes(method) ? undefined : (req.postData() ?? undefined);
      const resp = await fetch(url, { method, headers, body, redirect: 'follow' });
      const buf = Buffer.from(await resp.arrayBuffer());
      const h = {}; resp.headers.forEach((v, k) => { if (!/^(content-encoding|content-length|transfer-encoding)$/i.test(k)) h[k] = v; });
      await route.fulfill({ status: resp.status, headers: h, body: buf });
    } catch { await route.abort(); }
  });
}

// ── Isolation pre-flight: the hosted target must resolve to isolated staging ──
const cfgRes = await fetch(`${base}/api/portal-config`, { cache: 'no-store' });
assert.equal(cfgRes.status, 200, 'portal-config must be reachable (HTTP 200).');
const cfg = await cfgRes.json();
assert.equal(cfg?.ok, true, 'portal-config must report ok:true.');
assert.equal(cfg.env, 'preview', 'portal-config env must be preview (never production).');
assert.equal(cfg.ref, expectedRef, 'portal-config ref must match the isolated staging ref.');
assert.equal(String(cfg.ref).includes(PROD_REF), false, 'portal-config must never expose the production ref.');
console.log('▶ Authenticated multi-role hosted journey');
console.log(`  Target: ${new URL(base).host}  · isolated staging ${expectedRef}${useRelay ? ' · relay' : ''}`);

const browser = await chromium.launch({
  args: ['--no-sandbox'], proxy: pwProxy,
  executablePath: process.env.PW_EXECUTABLE || undefined,
});
let failures = 0;

for (const role of roleNames) {
  const u = users[role] || {};
  const u_admin = !!u.admin;
  if (!u.email || !u.password) { console.log(`  ✗ ${role}: missing email/password`); failures++; continue; }
  const ctx = await browser.newContext({ ignoreHTTPSErrors: insecureTLS });
  if (useRelay) await attachRelay(ctx);
  const page = await ctx.newPage();
  try {
    await page.goto(`${base}/purchase-portal.html`, { waitUntil: 'domcontentloaded', timeout: navTimeout });
    await page.waitForSelector('#pa-login', { state: 'visible', timeout: navTimeout });
    await page.fill('#pa-email', u.email);
    await page.fill('#pa-pass', u.password);
    await page.click('#pa-lg-btn');

    // Success = login overlay gone + app shell rendered (ME/SB are app-scoped, not on window).
    const outcome = await page.waitForFunction(() => {
      const overlay = document.getElementById('pa-login');
      const hidden = !overlay || overlay.style.display === 'none' || overlay.offsetParent === null;
      const shell = !!document.querySelector('.topbar') && !!document.querySelector('.wrap');
      if (hidden && shell) return { ok: true };
      const err = (document.getElementById('pa-lg-err') || {}).textContent || window.__paReason || '';
      return err ? { ok: false, err: String(err) } : false;
    }, { timeout: navTimeout }).then((h) => h.jsonValue());
    if (!outcome.ok) { console.log(`  ✗ ${role}: login failed — ${outcome.err}`); failures++; continue; }

    // Authorization probes as authenticated REST calls using the browser's OWN persisted
    // session token (read from localStorage `sb-<ref>-auth-token`). Everything egresses
    // through the page (relayed when PW_RELAY), so it is the real hosted-session path.
    const P = await page.evaluate(async (ref) => {
      const out = {
        nav: Array.from(document.querySelectorAll('#nav button'))
          .map((b) => ((b.getAttribute('onclick') || '').match(/go\('([^']+)'\)/) || [])[1]).filter(Boolean),
      };
      try {
        let sess = null;
        for (let i = 0; i < 20 && !sess; i++) {
          const k = Object.keys(localStorage).find((x) => /-auth-token$/.test(x));
          const raw = k ? localStorage.getItem(k) : null;
          const parsed = raw ? JSON.parse(raw) : null;
          const s = parsed && (parsed.currentSession || parsed);
          if (s && s.access_token && s.user && s.user.email) { sess = s; break; }
          await new Promise((res) => setTimeout(res, 250));
        }
        if (!sess) { out.fatal = 'no persisted session token after login'; return out; }
        const tok = sess.access_token;
        const email = sess.user.email;
        out.email = email;
        const c = await (await fetch('/api/portal-config', { cache: 'no-store' })).json();
        const url = c.url, H = { apikey: c.anonKey, Authorization: 'Bearer ' + tok };
        const jH = Object.assign({}, H, { 'Content-Type': 'application/json', Accept: 'application/json' });
        let r = await fetch(url + '/rest/v1/portal_users?select=username&email=neq.' + encodeURIComponent(email) + '&limit=5', { headers: H });
        out.usersStatus = r.status; out.usersRows = r.ok ? (await r.json()).length : null;
        r = await fetch(url + '/rest/v1/portal_user_directory?select=*&limit=1', { headers: H });
        out.dirStatus = r.status; const dj = r.ok ? await r.json() : []; out.dirKeys = dj[0] ? Object.keys(dj[0]).sort() : [];
        r = await fetch(url + '/rest/v1/rpc/portal_has_perm', { method: 'POST', headers: jH, body: JSON.stringify({ p_key: 'can_manage_users' }) });
        out.permStatus = r.status; out.permData = r.ok ? await r.json() : null;
        r = await fetch(url + '/rest/v1/rpc/portal_audit_verify', { method: 'POST', headers: jH, body: '{}' });
        out.auditStatus = r.status; out.auditBody = (await r.text()).slice(0, 300);
      } catch (e) { out.fatal = String(e).slice(0, 160); }
      return out;
    }, expectedRef);
    if (P.fatal) throw new Error(`${role}: probe fatal — ${P.fatal}`);

    // Real-login proof: the persisted session must belong to THIS role's account.
    assert.equal(P.email, u.email, `${role}: session email "${P.email}" != expected "${u.email}"`);

    const expManage = (u.expectManageUsers !== undefined) ? !!u.expectManageUsers : u_admin;
    const expAudit = (u.expectAuditVerify !== undefined) ? !!u.expectAuditVerify : (u_admin || !!u.finance);
    const DENY = /permission|denied|not.*allow|صلاحية|غير مخوّل|غير مصرّح/i;
    let pos = 0, neg = 0;

    // P-RLS portal_users: query must SUCCEED (200); RLS then filters rows by role.
    assert.equal(P.usersStatus, 200, `${role}: portal_users REST status ${P.usersStatus} (expected 200)`);
    if (u_admin) { assert.ok(P.usersRows > 0, `${role}: admin should read other portal_users rows`); pos++; }
    else { assert.equal(P.usersRows, 0, `${role}: non-admin read ${P.usersRows} other portal_users rows (RLS breach)`); neg++; }

    // P-DIR: safe view readable, returns its allowed columns, never the sensitive ones.
    assert.equal(P.dirStatus, 200, `${role}: portal_user_directory REST status ${P.dirStatus}`);
    assert.ok(P.dirKeys.length >= 1, `${role}: portal_user_directory returned no columns`);
    for (const need of ['username', 'display_name']) assert.ok(P.dirKeys.includes(need), `${role}: safe directory missing "${need}"`);
    for (const bad of ['email', 'permissions', 'role', 'job_key', 'delegate_to']) assert.equal(P.dirKeys.includes(bad), false, `${role}: portal_user_directory leaked column "${bad}"`);
    pos++;

    // P-PERM: server-evaluated capability matches the declared expectation.
    assert.equal(P.permStatus, 200, `${role}: portal_has_perm REST status ${P.permStatus}`);
    assert.equal(P.permData === true, expManage, `${role}: can_manage_users server-eval=${P.permData}, expected ${expManage}`);
    expManage ? pos++ : neg++;

    // P-AUDIT: finance/admin-only. Positive ⇒ 200. Negative ⇒ a SPECIFIC permission denial
    //          (4xx with a P0001/42501 or permission-denied signature), not any error.
    if (expAudit) {
      assert.equal(P.auditStatus, 200, `${role}: audit_verify should be allowed, got ${P.auditStatus} ${P.auditBody}`);
      pos++;
    } else {
      assert.ok(P.auditStatus === 400 || P.auditStatus === 403, `${role}: audit_verify should be denied (4xx), got ${P.auditStatus}`);
      assert.ok(/P0001|42501/.test(P.auditBody) || DENY.test(P.auditBody), `${role}: audit_verify denial lacks a permission signature: ${P.auditBody}`);
      neg++;
    }

    console.log(`  ✓ ${role} (${P.email}) — real login + ${pos} positive / ${neg} negative server probes PASS (usersRows=${P.usersRows}; dirCols=${JSON.stringify(P.dirKeys)}; manageUsers=${P.permData}; audit=${expAudit ? P.auditStatus : 'denied ' + P.auditStatus}); nav=${JSON.stringify(P.nav)}`);
    // TODO(owner-authorized seed): state-mutating cross-role lifecycle + browser-driven
    //   forbidden-transition probes need a disposable seed + teardown; not executed here.
    //   Server-side SoD/financial/lifecycle negatives are proven at DB level in
    //   LIVE_STAGING_VERIFICATION_2026-08-04.md.
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

#!/usr/bin/env node
/**
 * portal-inline-smoke.test.mjs — معاينة متصفّح حقيقيّة للكود المضمَّن في purchase-portal.html.
 *
 * الفجوة التي يسدّها: كل اختبارات المتصفّح القائمة تستخدم صفحات fixture صناعية أو أصول
 * /assets المنفصلة — لا شيء يُحمّل purchase-portal.html الفعليّ ويُنفّذ دوال المُحوِّل. فكانت
 * تغييرات المُحوِّل تُفحَص static فقط (regex + node --check)، ولا تُكتشف أخطاء وقت التشغيل
 * (مثل التكرار اللانهائي في مُغلِّف سابق). هذا الاختبار:
 *   1) يخدم purchase-portal.html الحقيقيّ + كعب /lib/supabase.js + /api/portal-config،
 *   2) يحمّله في Chromium ويلتقط pageerror/console.error،
 *   3) يؤكّد إقلاعاً نظيفاً حتى شاشة الدخول بلا أيّ خطأ غير مُلتقَط (يُنفَّذ كل تركيب مُغلِّفات
 *      المُحوِّل وقت التحميل)،
 *   4) يستدعي دوال العرض الجديدة داخل المتصفّح ببيانات وهميّة ويؤكّد أنّها تُعيد HTML بلا رمي.
 *
 * يتطلّب playwright + Chromium (/opt/pw-browsers). تشغيل: node scripts/e2e/portal-inline-smoke.test.mjs
 */
import { createServer } from 'node:http';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

// حلّ مسار Chromium المُثبَّت مسبقاً (إصدار الحزمة قد لا يطابق مجلّد المتصفّح — نتفادى التنزيل).
function resolveChromium() {
  const bp = process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers';
  try {
    const dirs = readdirSync(bp).filter((d) => d.startsWith('chromium-'));
    for (const d of dirs) { const p = join(bp, d, 'chrome-linux', 'chrome'); if (existsSync(p)) return p; }
  } catch (e) { /* ignore */ }
  return undefined; // دع playwright يحاول افتراضيّاً
}

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const portalHtml = readFileSync(join(root, 'purchase-portal.html'), 'utf8');

// كعب عميل Supabase: بلا جلسة ⇒ boot() يُظهر شاشة الدخول (لا loadAll).
const SUPA_STUB = `
window.supabase = { createClient: function(){
  return {
    auth: {
      onAuthStateChange: function(){ return { data:{ subscription:{ unsubscribe:function(){} } } }; },
      getSession: async function(){ return { data:{ session:null } }; },
      signInWithPassword: async function(){ return { data:{}, error:{ message:'stub' } }; },
      signOut: async function(){ return {}; }
    },
    from: function(){ var q={ select:function(){return q;}, order:function(){return q;}, eq:function(){return q;},
      maybeSingle: async function(){ return { data:null, error:null }; } }; return q; },
    rpc: async function(){ return { data:null, error:null }; }
  };
}};`;

const server = createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (url === '/lib/supabase.js') {
    res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' }); res.end(SUPA_STUB); return;
  }
  if (url === '/api/portal-config') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, env: 'preview', ref: 'abcdefghij0123456789',
      url: 'https://abcdefghij0123456789.supabase.co', anonKey: 'anon-stub-key' }));
    return;
  }
  if (url === '/' || url === '/portal' || url === '/purchase-portal.html') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end(portalHtml); return;
  }
  res.writeHead(200, { 'content-type': 'text/plain' }); res.end(''); // بقيّة الأصول: لا شيء (لا يكسر الإقلاع)
});

await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

let ok = 0; const pass = (m) => { console.log('  ✓ ' + m); ok++; };
const pageErrors = []; const consoleErrors = [];
const browser = await chromium.launch({ args: ['--no-sandbox'], executablePath: resolveChromium() });
try {
  const page = await browser.newPage();
  page.on('pageerror', (e) => pageErrors.push(String(e && e.message || e)));
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });

  await page.goto(base + '/', { waitUntil: 'networkidle' });
  // شاشة الدخول تظهر بعد boot (getSession=null) — دليل أنّ الإقلاع اكتمل
  await page.waitForSelector('#pa-login', { timeout: 8000 });

  // (1) لا أخطاء غير مُلتقَطة أثناء التحميل + الإقلاع (كل مُغلِّفات المُحوِّل نُفِّذت)
  assert.equal(pageErrors.length, 0, 'uncaught pageerror(s): ' + JSON.stringify(pageErrors));
  pass('purchase-portal.html boots to login with zero uncaught page errors');

  // (2) الدوال الجديدة موجودة في النطاق العامّ
  const present = await page.evaluate(() => ['pa_govCard','pa_permMatrixHTML','pa_disbFlow','pa_actionBanner',
    'pa_setGovFlag','pa_saveWorkflow','pa_docView','togglePerm','userCard']
    .filter((n) => typeof window[n] === 'function'));
  assert.deepEqual(present.sort(), ['pa_actionBanner','pa_disbFlow','pa_docView','pa_govCard','pa_permMatrixHTML',
    'pa_saveWorkflow','pa_setGovFlag','togglePerm','userCard'].sort(),
    'missing converter functions: got ' + JSON.stringify(present));
  pass('all new converter functions are defined on window');

  // (3) تنفيذ دوال العرض الجديدة ببيانات وهميّة داخل المتصفّح — تُعيد HTML بلا رمي
  const results = await page.evaluate(() => {
    const out = {};
    window.ME = 'admin';
    window.USERS = { admin: { n:'مدير البوابة', r:'مدير', job:'gm', admin:true, perms:{} },
                     u1: { n:'موظف', r:'موظف', perms:{ can_create:true }, ov:{ can_see_finance:true } } };
    window.PSET = { contract_enforce:1, budget_enforce:0, three_way_tolerance_pct:5 };
    window.isAdmin = () => true;
    const cap = (fn) => { try { const h = fn(); return { ok: typeof h === 'string', len: (h||'').length }; }
      catch (e) { return { ok:false, err: String(e && e.message || e) }; } };
    out.govCard = cap(() => window.pa_govCard());
    out.permMatrix = cap(() => window.pa_permMatrixHTML('u1', window.USERS.u1));
    out.disbFlow = cap(() => window.pa_disbFlow({ reqType:'direct_expense', beneficiary:'مستفيد',
      disbChain:[ { label:'اعتماد أول', user:'admin', decision:'approved', seq:1 },
                  { label:'تنفيذ', user:'admin', decision:'pending', seq:2 } ] }));
    // ملاحظة: REQS مُعرَّف بـlet (ليس خاصيّة window) فلا يمكن حقنه من evaluate؛ نكتفي بأنّ
    // pa_actionBanner يُنفَّذ بلا رمي (يُعيد '' لطلب غير موجود = سلوك صحيح).
    out.actionBanner = cap(() => window.pa_actionBanner('nonexistent'));
    return out;
  });
  const mustRender = { govCard:1, permMatrix:1, disbFlow:1 };
  for (const [name, r] of Object.entries(results)) {
    if (mustRender[name]) { assert.ok(r.ok && r.len > 0, name + ' failed: ' + JSON.stringify(r));
      pass(name + ' renders HTML in-browser (' + r.len + ' chars)'); }
    else { assert.ok(r.ok, name + ' threw: ' + JSON.stringify(r));
      pass(name + ' executes in-browser without throwing'); }
  }

  // (4) لا أخطاء console حرجة من تنفيذنا (تحذيرات الشبكة للأصول المُكعَّبة مقبولة — نتحقّق من عدم رمي دوالنا فقط)
  assert.equal(pageErrors.length, 0, 'late uncaught pageerror(s): ' + JSON.stringify(pageErrors));
  pass('no uncaught errors after exercising converter render functions');

  console.log('\n════ PORTAL INLINE SMOKE: ' + ok + ' checks passed ════');
} finally {
  await browser.close();
  server.close();
}
process.exit(0);

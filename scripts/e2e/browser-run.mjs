#!/usr/bin/env node
/**
 * browser-run.mjs — المُشغّل الوحيد الموثوق لـE2E المتصفّح (F2/F3/F4). حدّ الشبكة على **مستوى سياق المتصفّح**:
 *   • Service Workers **محظورة** (`serviceWorkers:'block'`) فلا تتجاوز عامل الخدمة اعتراضَنا.
 *   • HTTP عبر context.route (كل الطلبات) + WebSocket عبر context.routeWebSocket — كلاهما قبل أيّ صفحة.
 * الإنتاج (HTTP و WSS) محظور دائماً؛ ومرجع Supabase غير staging المُتحقَّق محظور؛ فقط staging مسموح.
 *
 * سيناريو smoke بمُحدِّدات النظام-3 **الحقيقية** (F2): #pa-email · #pa-pass · #pa-lg-btn · نجاح الدخول =
 * إخفاء #pa-login وإظهار .topbar + .wrap. يفشل مغلقاً بلا حزمة playwright أو E2E_BASE_URL أو STAGING_TEST_*.
 *
 * يُستدعى عبر env-guard (--command browser-e2e) وعبر scripts/e2e/run.mjs (يفوّض إليه) — مسار أمر واحد (F4).
 * الاختبار الحتميّ بلا staging خارجيّ: scripts/e2e/browser-fixture.test.mjs.
 */
import { supabaseRefOfHost } from './net-allow.mjs';
import { resolveChromiumExecutable } from './chromium-path.mjs';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
function die(m) { console.error('❌ browser-run: ' + m); process.exit(2); }

const base = process.env.E2E_BASE_URL || '';
const url = process.env.E2E_SUPABASE_URL || '';
const m = /^https:\/\/([a-z0-9]{20})\.supabase\.co\/?$/.exec(url);
const ref = m ? m[1] : (process.env.GUARDED_REF || '').toLowerCase();
if (!/^[a-z0-9]{20}$/.test(ref)) die('لا مرجع staging صالح (يُضبط عبر env-guard).');
if (ref === PROD_REF) die('الهدف الإنتاج — مرفوض.');
if (!base) die('E2E_BASE_URL (نشر staging/fixture) مطلوب — النتيجة مفتوحة بدونه (fail-closed).');
const email = process.env.STAGING_TEST_EMAIL || '';
const pass = process.env.STAGING_TEST_PASSWORD || '';
if (!email || !pass) die('سيناريو smoke يتطلّب STAGING_TEST_EMAIL + STAGING_TEST_PASSWORD — fail-closed.');

let chromium;
try { ({ chromium } = await import('playwright')); }
catch (_) { die('حزمة playwright غير مثبَّتة — npm ci ثم أعِد التشغيل (لا نجاح زائف).'); }

// قرار السماح المشترك (HTTP + WS): غير-Supabase مسموح؛ الإنتاج محظور دائماً؛ Supabase آخر يجب أن يطابق staging.
function allowed(u) {
  let host; try { host = new URL(u).hostname; } catch (_) { return false; }
  const r = supabaseRefOfHost(host);
  if (r === null) return true;
  if (r === PROD_REF) return false;
  return r === ref;
}

// المتصفّح: يُفضَّل مسار صريح (PW_CHROMIUM_PATH) لبيئات بمتصفّح مثبَّت مسبقاً؛ وإلّا حزمة playwright المُدارة.
const execPath = resolveChromiumExecutable();
// --no-sandbox لازم لبيئات الحاويات/CI (يعمل بجذر) وحميد في غيرها.
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'], ...(execPath ? { executablePath: execPath } : {}) });
// (F3) Service Workers محظورة على مستوى السياق.
const context = await browser.newContext({ serviceWorkers: 'block' });

const httpBlocked = new Set(), httpAllowed = new Set(), wsBlocked = new Set(), wsAllowed = new Set();
await context.route('**/*', (route) => {
  const u = route.request().url(); let host; try { host = new URL(u).hostname; } catch (_) { host = u; }
  if (allowed(u)) { if (supabaseRefOfHost(host) !== null) httpAllowed.add(host); return route.continue(); }
  httpBlocked.add(host); return route.abort();
});
// (F3) حدّ WebSocket — يُثبَّت قبل أيّ صفحة.
await context.routeWebSocket(/.*/, (ws) => {
  const u = ws.url(); let host; try { host = new URL(u).hostname; } catch (_) { host = u; }
  if (allowed(u)) { wsAllowed.add(host); try { ws.connectToServer(); } catch (_) {} }
  else { wsBlocked.add(host); try { ws.close(); } catch (_) {} }
});

const page = await context.newPage();

// (F2) افتح صفحة النظام-3 + تحقّق هويّة الإعداد قبل أيّ إجراء (fail-closed).
let resp;
try { resp = await page.goto(base.replace(/\/+$/, '') + '/purchase-portal.html', { waitUntil: 'domcontentloaded' }); }
catch (e) { await browser.close(); die('تعذّر فتح صفحة النظام-3: ' + e.message); }
const cfg = await page.evaluate(async () => { try { const r = await fetch('/api/portal-config'); return { s: r.status, b: await r.json() }; } catch (e) { return { s: 0, b: null }; } });
if (cfg.s !== 200 || !cfg.b || cfg.b.ok !== true) { await browser.close(); die('portal-config غير جاهز/‏ok!=true (fail-closed).'); }
if (cfg.b.env === 'production' || cfg.b.ref === PROD_REF) { await browser.close(); die(`هويّة إنتاج (env=${cfg.b.env}, ref=${cfg.b.ref}) — إيقاف فوريّ.`); }
if (cfg.b.ref !== ref) { await browser.close(); die(`ref (${cfg.b.ref}) ≠ staging (${ref}) — fail-closed.`); }

// (F3) مجسّات أمنية داخل الصفحة قبل تسجيل الدخول.
const OTHER_REF = 'zzzzzzzzzzzzzzzzzzzz';   // مرجع Supabase آخر (ليس staging وليس الإنتاج) — يجب أن يُحظَر
// (G1-FINAL-02) نلتقط نتيجة تسجيل عامل الخدمة صراحةً (لا نكتفي بـcontroller).
const swReg = await page.evaluate(async ({ prod, other, stg }) => {
  const tryFetch = (u) => fetch(u).then(() => 0).catch(() => 0);
  const tryWs = (u) => { try { const w = new WebSocket(u); w.onerror = () => {}; } catch (_) {} };
  await tryFetch(`https://${prod}.supabase.co/rest/v1/`);      // إنتاج HTTP — يُجهَض
  await tryFetch(`https://${other}.supabase.co/rest/v1/`);     // مرجع آخر HTTP — يُجهَض
  await tryFetch(`https://${stg}.supabase.co/rest/v1/`);       // staging HTTP — يمرّ
  tryWs(`wss://${prod}.supabase.co/realtime/v1/websocket`);    // إنتاج WSS — يُحظَر
  tryWs(`wss://${other}.supabase.co/realtime/v1/websocket`);   // مرجع آخر WSS — يُحظَر
  tryWs(`wss://${stg}.supabase.co/realtime/v1/websocket`);     // staging WSS — يُسمَح
  let reg = 'none';
  try { await navigator.serviceWorker.register('/sw.js'); reg = 'registered'; } catch (e) { reg = 'threw:' + (e && e.name); }
  return reg;
}, { prod: PROD_REF, other: OTHER_REF, stg: ref });
await page.waitForTimeout(500);

// (G1-FINAL-02) دليل حاسم: عدد تسجيلات عامل الخدمة يجب أن يكون صفراً (الحظر على مستوى السياق يمنع التسجيل).
const swCount = await page.evaluate(async () => {
  if (!navigator.serviceWorker || !navigator.serviceWorker.getRegistrations) return 0;
  try { return (await navigator.serviceWorker.getRegistrations()).length; } catch (_) { return -1; }
});

// تأكيدات الحدّ بمخرجات مضيف دقيقة (fail-closed على أيّ خرق).
const viol = [];
if (!httpBlocked.has(`${PROD_REF}.supabase.co`)) viol.push('prod HTTP لم يُحظَر');
if (!httpBlocked.has(`${OTHER_REF}.supabase.co`)) viol.push('other-ref HTTP لم يُحظَر');
if (!httpAllowed.has(`${ref}.supabase.co`)) viol.push('staging HTTP لم يُسمَح');
if (!wsBlocked.has(`${PROD_REF}.supabase.co`)) viol.push('prod WSS لم يُحظَر');
if (!wsBlocked.has(`${OTHER_REF}.supabase.co`)) viol.push('other-ref WSS لم يُحظَر');
if (!wsAllowed.has(`${ref}.supabase.co`)) viol.push('staging WSS لم يُسمَح');
if (swCount !== 0) viol.push(`Service Worker مُسجَّل (${swCount}) — الحظر فشل`);
if (viol.length) { await browser.close(); die('خرق حدّ الشبكة: ' + viol.join(' · ')); }

// (F2) تسجيل دخول staging بمُحدِّدات النظام-3 الحقيقية + بلوغ الحالة المحميّة.
await page.fill('#pa-email', email);
await page.fill('#pa-pass', pass);
await page.click('#pa-lg-btn');
try {
  await page.waitForSelector('#pa-login', { state: 'hidden', timeout: 15000 });
  await page.waitForSelector('.topbar', { state: 'visible', timeout: 15000 });
  await page.waitForSelector('.wrap', { state: 'visible', timeout: 15000 });
} catch (e) { await browser.close(); die('فشل بلوغ الحالة المحميّة بعد الدخول (المُحدِّدات/الاعتماد): ' + e.message); }

await browser.close();
// مخرجات مضيف دقيقة (G1-FINAL-02) — تؤكِّدها browser-fixture.test.mjs.
console.log('✅ browser-run: smoke نجح على staging (' + ref + ') — دخول (#pa-login مخفيّ · .topbar+.wrap ظاهران).');
console.log('BOUNDARY'
  + ` prodHTTP=${httpBlocked.has(PROD_REF + '.supabase.co') ? 'blocked' : 'LEAK'}`
  + ` otherHTTP=${httpBlocked.has(OTHER_REF + '.supabase.co') ? 'blocked' : 'LEAK'}`
  + ` stagingHTTP=${httpAllowed.has(ref + '.supabase.co') ? 'allowed' : 'DENIED'}`
  + ` prodWSS=${wsBlocked.has(PROD_REF + '.supabase.co') ? 'blocked' : 'LEAK'}`
  + ` otherWSS=${wsBlocked.has(OTHER_REF + '.supabase.co') ? 'blocked' : 'LEAK'}`
  + ` stagingWSS=${wsAllowed.has(ref + '.supabase.co') ? 'allowed' : 'DENIED'}`
  + ` swRegistrations=${swCount}`
  + ` swRegisterResult=${swReg}`);
process.exit(0);

#!/usr/bin/env node
/**
 * browser-run.mjs — مُشغّل E2E المتصفّح الحقيقي (G1-R4-03). يفرض حدّ الشبكة على **مستوى سياق المتصفّح**
 * (Playwright `context.route`) قبل إنشاء أيّ صفحة، فيغطّي fetch/XHR/التنقّل/‏Supabase JS داخل الصفحة —
 * لا مجرّد `globalThis.fetch` في Node. يمنع أيّ مضيف Supabase غير مرجع staging المُتحقَّق منه، والإنتاج دائماً.
 *
 * fail-closed: يخرج بخطأ (لا «نجاح» زائف) إن غابت حزمة playwright أو staging (`E2E_BASE_URL`/`GUARDED_REF`).
 * ⚠️ حزمة playwright غير مثبَّتة في هذا المستودع بعد + لا staging ⇒ لا يُشغَّل فعليّاً هنا (نتيجة E2E مفتوحة).
 * التثبيت المستقبلي: `npm i -D playwright` (المتصفّحات مثبَّتة في /opt/pw-browsers). الاستدعاء عبر env-guard
 * (browser-e2e) عند تجهيز staging.
 *
 * قاعدة السماح/المنع (مطابقة scripts/e2e/net-allow.mjs، مُطبَّقة على مستوى المتصفّح):
 */
import { supabaseRefOfHost } from './net-allow.mjs';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
function die(m) { console.error('❌ browser-run: ' + m); process.exit(2); }

const base = process.env.E2E_BASE_URL || '';
const url = process.env.E2E_SUPABASE_URL || '';
const m = /^https:\/\/([a-z0-9]{20})\.supabase\.co\/?$/.exec(url);
const ref = m ? m[1] : (process.env.GUARDED_REF || '').toLowerCase();
if (!/^[a-z0-9]{20}$/.test(ref)) die('لا مرجع staging صالح (يُضبط عبر env-guard).');
if (ref === PROD_REF) die('الهدف الإنتاج — مرفوض.');
if (!base) die('E2E_BASE_URL (نشر staging) مطلوب لتشغيل E2E المتصفّح — النتيجة مفتوحة بدونه (fail-closed).');

let chromium;
try { ({ chromium } = await import('playwright')); }
catch (_) { die('حزمة playwright غير مثبَّتة — ثبّتها (npm i -D playwright؛ المتصفّحات في /opt/pw-browsers) ثم أعِد التشغيل. لا ندّعي نجاحاً بدونها.'); }

// قرار السماح على مستوى سياق المتصفّح: يُطبَّق على كلّ الطلبات قبل أيّ صفحة.
function allowed(u) {
  let host; try { host = new URL(u).hostname; } catch (_) { return false; }
  const r = supabaseRefOfHost(host);
  if (r === null) return true;                 // غير Supabase — مسموح (الواجهة)
  if (r === PROD_REF) return false;            // الإنتاج — محظور دائماً
  return r === ref;                            // Supabase آخر يجب أن يطابق staging
}

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
let blocked = 0;
await context.route('**/*', (route) => {
  const u = route.request().url();
  if (!allowed(u)) { blocked++; return route.abort(); }   // يُجهَض قبل الشبكة
  return route.continue();
});
const page = await context.newPage();

// تحقّق الإعداد قبل أيّ إجراء.
await page.goto(base.replace(/\/+$/, '') + '/api/portal-config', { waitUntil: 'domcontentloaded' });
// … سيناريو سير العمل الفعليّ يُضاف هنا (تسجيل دخول staging، دورة صرف، …) …

await browser.close();
console.log(`✅ browser-run: حدّ سياق المتصفّح مُطبَّق (مسموح فقط بـ${ref}؛ الإنتاج محظور). طلبات مُجهَضة=${blocked}.`);
process.exit(0);

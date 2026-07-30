#!/usr/bin/env node
/**
 * run.mjs — مُشغّل E2E الثابت الوحيد (G1-R3-02). يُستدعى حصراً عبر env-guard (--command browser-e2e)،
 * فلا سبيل لتمرير سكربت اعتباطي. يُثبِّت حارس الشبكة (net-allow) قبل أيّ إجراء، ويؤكّد أنّ الهدف
 * ليس الإنتاج. سيناريو المتصفّح الفعلي مؤجَّل حتى تجهيز staging (G1-R3-06)؛ هنا نُثبِت الربط بالهدف.
 */
import { installNetworkAllowlist, isAllowedUrl } from './net-allow.mjs';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
function die(m) { console.error('❌ e2e-run: ' + m); process.exit(2); }

const url = process.env.E2E_SUPABASE_URL || '';
const m = /^https:\/\/([a-z0-9]{20})\.supabase\.co\/?$/.exec(url);
const ref = m ? m[1] : (process.env.GUARDED_REF || '').toLowerCase();
if (!/^[a-z0-9]{20}$/.test(ref)) die('لا مرجع staging صالح (E2E_SUPABASE_URL/GUARDED_REF يُضبطان عبر env-guard).');
if (ref === PROD_REF) die('الهدف هو الإنتاج — مرفوض.');

installNetworkAllowlist(ref);

// (يُنفَّذ حيّاً عند تجهيز staging) قبل أيّ إجراء: تأكّد أنّ /api/portal-config يبلّغ المرجع المُتحقَّق منه.
const base = process.env.E2E_BASE_URL || '';
if (base) {
  try {
    const r = await fetch(base.replace(/\/+$/, '') + '/api/portal-config', { cache: 'no-store' });
    const c = await r.json().catch(() => null);
    if (!c || c.ok !== true || c.ref !== ref) die(`/api/portal-config لا يبلّغ المرجع المُتحقَّق منه (${ref}) — إيقاف قبل أيّ إجراء.`);
    if (!isAllowedUrl(c.url, ref)) die('عنوان Supabase من الإعداد ليس مرجع staging — إيقاف.');
    console.log(`✅ e2e-run: الإعداد يبلّغ staging «${ref}». (سيناريو المتصفّح يُشغَّل هنا.)`);
  } catch (e) { die('تعذّر التحقّق من الإعداد قبل E2E: ' + (e && e.message)); }
} else {
  // ⚠️ (G1-R4-03) هذا حارس على مستوى **Node fetch للمُشغّل فقط** — ليس حدّ متصفّح. لا يعترض طلبات
  // صفحة متصفّح/‏Supabase JS/XHR/WebSocket. المتصفّح الفعليّ في scripts/e2e/browser-run.mjs (Playwright)
  // ويتطلّب الحزمة + staging؛ نتيجة E2E الفعلية تبقى **مفتوحة** حتى ذلك.
  console.log(`✅ e2e-run: حارس Node-fetch مُثبَّت (مسموح فقط بـ«${ref}»؛ الإنتاج محظور) — **ليس حدّ متصفّح**. `
    + 'E2E المتصفّح الفعليّ (browser-run.mjs/Playwright) غير مُنفَّذ هنا (لا حزمة/‏staging) — النتيجة مفتوحة.');
}
process.exit(0);

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
  console.log(`✅ e2e-run: حارس الشبكة مُثبَّت (مسموح فقط بـ«${ref}»؛ الإنتاج محظور). سيناريو المتصفّح مؤجَّل حتى تجهيز staging + E2E_BASE_URL (G1-R3-06).`);
}
process.exit(0);

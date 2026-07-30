#!/usr/bin/env node
/**
 * probe-anon.mjs — مسبار جاهزية للمفتاح العامّ (G1-R3-04). التحقّق في portal-config **بنيويّ** فقط
 * (شكل/مطالبات/اتّساق، بلا تحقّق توقيع). هذا المسبار يُكمِله بتحقّق **حيّ**: ينادي نقطة Supabase غير
 * بيانية بالمفتاح العامّ المُعطى ويؤكّد استجابة المشروع المتوقَّعة — **دون طباعة المفتاح**. اختياري،
 * يُشغَّل وقت النشر/الجاهزية، لا في مسار الطلب. لا يمسّ أيّ بيانات.
 *
 * الاستخدام: node scripts/deploy/probe-anon.mjs --url https://<ref>.supabase.co --key "$ANON"
 *            (أو عبر البيئة PROBE_SUPABASE_URL / PROBE_SUPABASE_ANON)
 */
function arg(n) { const i = process.argv.indexOf('--' + n); return i >= 0 ? process.argv[i + 1] : undefined; }
function die(m, code = 2) { console.error('❌ probe-anon: ' + m); process.exit(code); }

const url = (arg('url') || process.env.PROBE_SUPABASE_URL || '').replace(/\/+$/, '');
const key = arg('key') || process.env.PROBE_SUPABASE_ANON || '';
const m = /^https:\/\/([a-z0-9]{20})\.supabase\.co$/.exec(url);
if (!m) die('عنوان Supabase غير صالح (https://<ref>.supabase.co).');
if (!key) die('المفتاح العامّ مطلوب (--key أو PROBE_SUPABASE_ANON) — لن يُطبَع.');
const ref = m[1];

// نقطة غير بيانية: auth health لا تُرجِع بيانات مستخدمين، وتتطلّب apikey صالحاً للمشروع.
const endpoint = url + '/auth/v1/health';
try {
  const r = await fetch(endpoint, { headers: { apikey: key }, cache: 'no-store' });
  // نجاح المشروع: 200 (health) — بلا تسريب المفتاح في أيّ سجلّ.
  if (r.status === 200) { console.log(`✅ probe-anon: المشروع «${ref}» يستجيب للمفتاح العامّ (auth/health 200). (لم يُطبَع المفتاح.)`); process.exit(0); }
  if (r.status === 401 || r.status === 403) die(`المفتاح مرفوض للمشروع «${ref}» (${r.status}) — مفتاح غير صالح/غير مطابق.`, 1);
  die(`استجابة غير متوقَّعة من «${ref}» (${r.status}).`, 1);
} catch (e) { die('تعذّر الوصول لنقطة الجاهزية: ' + (e && e.message), 1); }

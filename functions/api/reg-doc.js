/**
 * Cloudflare Pages Function — رفع وثائق تسجيل الموردين (نظام 1) عبر الخادم
 * ════════════════════════════════════════════════════════════════════════════
 * POST /api/reg-doc?reg_id=DG-XXXXXX&doc=cr   (body = بايتات PDF/JPG/PNG)
 *
 * لماذا وُجدت هذه النقطة:
 *   كانت `register.html` ترفع الوثائق **مباشرة** إلى Supabase Storage بمفتاح anon
 *   المضمَّن في الصفحة (عام للجميع). فحصُ التوقيع السحري هناك يقع في المتصفّح،
 *   وأي شخص يستدعي واجهة التخزين مباشرةً بالمفتاح العام يتجاوزه كلّياً ويرفع ما يشاء.
 *   هذه النقطة تنقل الرفع إلى الخادم بمفتاح الخدمة، فيصبح الفحص إلزامياً لا تجميلياً،
 *   ويُغلق الوصول العام للتخزين نهائياً (راجع db/system1-storage-hardening.sql).
 *
 * الحرّاس:
 *   1) same-origin (لا استدعاء من مواقع أخرى).
 *   2) صيغة رقم التسجيل ونوع الوثيقة من قائمة بيضاء — لا شيء من مُدخَل المستخدم
 *      يدخل المسار حرفياً، واسم الملف يُولَّد على الخادم.
 *   3) حارس الملفات الطبقي المشترك `_file-guard.js`: توقيع سحري · كشف متعدّد الصيغ ·
 *      سلامة بنيوية · رفض المحتوى النشِط في PDF · (وترويسات التحييد عند العرض).
 *   4) الرفع بمفتاح الخدمة (خادمي) — العميل لا يملك أي صلاحية كتابة على المخزن.
 *
 * ── التخزين: Cloudflare R2 (قرار المالك 2026-09-06: «أريد أكبر حجم تخزيني… R2») ──
 *   binding: `SUPPLIER_DOCS` — حاوية R2 **مستقلّة** عن حاوية البوابة `QUOTES_BUCKET`
 *   (نظام 3 معزول تماماً — القاعدة الذهبية في CLAUDE.md؛ لا تخلط الحاويتين).
 *   لماذا R2: مخزن Supabase على الخطة المجانية 1 GB = نحو 110 موردين فقط (قياس فعليّ:
 *   ≈9 MB للمورد ⇒ 8.8 GB لألف مورد). R2 يعطي 10 GB مجاناً ثم ‎$0.015/GB شهرياً
 *   **بلا رسوم إخراج (egress)** — فألف مورد ≈ 0.13$ شهرياً بدل ترقية بـ‎$25.
 *   **ومكسب إضافي: الرفع على R2 لا يحتاج `SUPABASE_SERVICE_ROLE_KEY` إطلاقاً**، فيزول
 *   الاعتماد على المتغيّر المفقود الذي عطّل الرفع الخادميّ (راجع CLAUDE.md 2026-07-21).
 *
 * ── القراءة: `GET /api/reg-doc?key=<path>` ──
 *   **مُصادَقة إلزامية**: رمز جلسة Supabase للموظّف (Bearer) يُتحقَّق منه عبر
 *   `/auth/v1/user`؛ أي فشل ⇒ 401 (فشل مغلق). ثم يُبَثّ الملف بترويسات التحييد
 *   المشتركة (`fileResponseHeaders`) فلا يُنفَّذ محتوى نشِط ولا يُخزَّن في الكاش.
 *   هذا يُغلق التسريب الذي كان في مخزن Supabase (وثائق تُنزَّل بلا حساب).
 *
 * ── التوافق الخلفي (قراءة مزدوجة، بلا ترحيل ولا انقطاع) ──
 *   الملفات القديمة تبقى في مخزن Supabase؛ الواجهة تسأل R2 أولاً وتسقط إلى الرابط
 *   الموقّع القديم عند 404. الجديد يُكتب على R2 فقط. لا نقل بيانات، لا شيء يُكسر.
 *
 * ⚠️ متغيّرات Cloudflare المطلوبة: binding `SUPPLIER_DOCS` (R2) + `SUPABASE_URL` +
 *    `SUPABASE_ANON_KEY` (عام، للتحقّق من رموز الجلسات؛ يقبل مفتاح الخدمة بديلاً).
 *    بلا R2 يسقط الرفع للمسار القديم (Supabase Storage) إن كان مفتاح الخدمة مضبوطاً.
 */
import { inspectUpload, fileResponseHeaders } from './_file-guard.js';

const BUCKET = 'supplier-docs';
const REG_RE = /^DG-[A-Z0-9]{4,12}$/;
// أنواع الوثائق المعروفة في نموذج التسجيل — **قائمة بيضاء صريحة** (لا regex عامّ).
// ⚠️ يجب أن تطابق REQUIRED_DOCS + OPTIONAL_DOCS في register.html تماماً، وإلا فُقِد رفع
// وثيقة مطلوبة (400 بلا سقوط) وتعطّل التسجيل. (تصحيح تدقيق Codex: القائمة السابقة كانت
// خاطئة — أسقطت chamber/natl_addr/iban_cert المطلوبة وأدرجت iban/address وهما اسما حقلين لا وثيقتين.)
const DOC_ALLOW = new Set([
  // REQUIRED_DOCS
  'cr', 'vat', 'gosi', 'chamber', 'natl_addr', 'iban_cert',
  // OPTIONAL_DOCS
  'municipal', 'quality', 'safety', 'clients', 'brochure',
]);

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}
function sameOrigin(request) {
  const host = request.headers.get('host');
  const src = request.headers.get('origin') || request.headers.get('referer');
  if (!host || !src) return false;
  try { return new URL(src).host === host; } catch (_) { return false; }
}
// مفتاح واجهة Supabase للتحقّق من رمز الجلسة: العام يكفي (وهو عام أصلاً في الصفحة)،
// ونقبل مفتاح الخدمة بديلاً إن كان هو المضبوط.
const apiKey = (env) => env.SUPABASE_ANON_KEY || env.SUPABASE_SERVICE_ROLE_KEY || '';
const legacyConfigured = (env) => !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY);
const r2 = (env) => env.SUPPLIER_DOCS || null;

/* يتحقّق من رمز جلسة الموظّف. فشل مغلق: أي خطأ ⇒ null ⇒ 401. */
async function verifyCaller(env, request) {
  const base = String(env.SUPABASE_URL || '').replace(/\/+$/, '');
  const key = apiKey(env);
  if (!base || !key) return null;
  const auth = request.headers.get('authorization') || '';
  const jwt = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!jwt) return null;
  try {
    const r = await fetch(`${base}/auth/v1/user`, { headers: { apikey: key, Authorization: `Bearer ${jwt}` } });
    if (!r.ok) return null;
    const u = await r.json();
    return u && u.email ? u : null;
  } catch (_) { return null; }
}
/* مسار الوثيقة يُقبل بشكله المولَّد خادمياً فقط: DG-XXXX/<doc>/<اسم>.<امتداد>
   — يمنع اجتياز المسار وقراءة أي كائن آخر في الحاوية. */
function safeKey(k) {
  const key = String(k || '').trim();
  if (!key || key.includes('..') || key.startsWith('/')) return null;
  const m = key.match(/^(DG-[A-Z0-9]{4,12})\/([a-z_]+)\/([A-Za-z0-9._-]{1,120})$/);
  if (!m || !DOC_ALLOW.has(m[2])) return null;
  return key;
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'طلب غير مصرّح به' }, 403);
  const bucket = r2(env);
  if (!bucket && !legacyConfigured(env)) {
    return json({ error: 'خدمة رفع الوثائق غير مهيّأة على الخادم', reason: 'not_configured' }, 503);
  }

  const url = new URL(request.url);
  const regId = String(url.searchParams.get('reg_id') || '').trim().toUpperCase();
  const doc   = String(url.searchParams.get('doc') || '').trim().toLowerCase();
  if (!REG_RE.test(regId)) return json({ error: 'رقم الطلب غير صالح' }, 400);
  if (!DOC_ALLOW.has(doc))  return json({ error: 'نوع الوثيقة غير صالح' }, 400);

  const buf = await request.arrayBuffer();
  const check = inspectUpload(buf);
  if (!check.ok) return json({ error: check.error, reason: 'rejected' }, 400);

  const rand = (globalThis.crypto && crypto.randomUUID) ? crypto.randomUUID() : ('r' + Date.now() + Math.random().toString(36).slice(2, 10));
  const path = `${regId}/${doc}/${rand}.${check.ext}`;

  // المسار المفضَّل: R2 (سعة أكبر، بلا رسوم إخراج، ولا يحتاج مفتاح خدمة).
  if (bucket) {
    try {
      await bucket.put(path, buf, { httpMetadata: { contentType: check.ct } });
      return json({ ok: true, path, store: 'r2' });
    } catch (e) {
      console.error('[reg-doc] r2_put_failed', (e && e.message) || e);
      // لا نسقط للمخزن القديم صامتاً إن كان R2 مقصوداً: خطأ صريح أوضح من ازدواج المخزن.
      if (!legacyConfigured(env)) return json({ error: 'تعذّر حفظ الملف على الخادم' }, 502);
    }
  }

  const base = String(env.SUPABASE_URL).replace(/\/+$/, '');

  try {
    const r = await fetch(`${base}/storage/v1/object/${BUCKET}/${path}`, {
      method: 'POST',
      headers: {
        apikey: env.SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
        'Content-Type': check.ct,
        'x-upsert': 'true',
      },
      body: buf,
    });
    if (!r.ok) {
      const t = await r.text().catch(() => '');
      console.error('[reg-doc] storage_upload_failed', r.status, t.slice(0, 200));
      return json({ error: 'تعذّر حفظ الملف على الخادم' }, 502);
    }
  } catch (_) { return json({ error: 'تعذّر الاتصال بخدمة التخزين' }, 502); }

  // ⚠️ تدقيق SEC-06: أُزيل «تنظيف النسخ السابقة» (list + DELETE) عمداً. كان يحذف كل الملفات
  // تحت `${regId}/${doc}/` عند كل رفع ناجح — فمن يعرف رقم تسجيل مورّد حقيقي (والنقطة بلا
  // مصادقة مستخدم، فقط same-origin قابل للتزوير) يستطيع محو وثائق المورّد الأصلية بإعادة رفع.
  // الآن: أسماء ملفات عشوائية فريدة فقط (لا استبدال، لا حذف) — لا ناقل تدميري.
  // المتبقّي (مُوثَّق): مصادقة حقيقية للرافع (رمز موقَّع مربوط بالتسجيل) = متابعة مع
  // db/system1-storage-hardening.sql؛ إزالة الحذف تُغلق أخطر جزء (المحو) الآن.
  return json({ ok: true, path, store: 'supabase' });
}

/* GET بلا مُعامِلات = فحص صحّة (منطقيات وجود فقط، لا قيم أسرار).
   GET ?key=<path> = بثّ الوثيقة من R2 لموظّف مُصادَق — فشل مغلق. */
export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const raw = url.searchParams.get('key');

  if (!raw) {
    return json({
      ok: !!(r2(env) || legacyConfigured(env)),
      store: r2(env) ? 'r2' : (legacyConfigured(env) ? 'supabase' : null),
      checks: {
        r2_bucket: !!r2(env),
        supabase_url: !!env.SUPABASE_URL,
        api_key: !!apiKey(env),
        service_key: !!env.SUPABASE_SERVICE_ROLE_KEY,
      },
    });
  }

  const bucket = r2(env);
  if (!bucket) return json({ error: 'تخزين R2 غير مهيّأ', reason: 'not_configured' }, 503);

  const key = safeKey(raw);
  if (!key) return json({ error: 'مسار غير صالح' }, 400);

  // مصادقة إلزامية: وثائق الموردين تحمل سجلات تجارية ورسائل بنكية.
  const user = await verifyCaller(env, request);
  if (!user) return json({ error: 'غير مصرّح' }, 401);

  // ?meta=1 — الحجم فقط (لقياس السعة) بلا بثّ البايتات
  if (url.searchParams.get('meta') === '1') {
    const h = await bucket.head(key);
    if (!h) return json({ error: 'غير موجود', reason: 'not_found' }, 404);
    return json({ ok: true, size: h.size || 0 });
  }

  const obj = await bucket.get(key);
  if (!obj) return json({ error: 'غير موجود', reason: 'not_found' }, 404);
  const ct = (obj.httpMetadata && obj.httpMetadata.contentType) || 'application/octet-stream';
  return new Response(obj.body, { status: 200, headers: fileResponseHeaders(ct) });
}

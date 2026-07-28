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
 * ⚠️ يتطلّب `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` في بيئة Cloudflare.
 *    بدونهما يعيد 503 بـ`reason:"not_configured"` — وتقع الصفحة على المسار القديم
 *    مؤقّتاً حتى يضبط المالك المتغيّر (انظر تعليق pushDocsViaServer في register.html).
 */
import { inspectUpload } from './_file-guard.js';

const BUCKET = 'supplier-docs';
const REG_RE = /^DG-[A-Z0-9]{4,12}$/;
// أنواع الوثائق المعروفة في نموذج التسجيل — **قائمة بيضاء صريحة** (لا regex عامّ).
// تدقيق SEC-06: DOC_RE العامّ كان يقبل أي مُعرّف بصيغة سليمة؛ الآن مجموعة مغلقة تطابق register.html.
const DOC_ALLOW = new Set(['cr', 'vat', 'gosi', 'iban', 'address']);

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
const configured = (env) => !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY);

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'طلب غير مصرّح به' }, 403);
  if (!configured(env)) return json({ error: 'خدمة رفع الوثائق غير مهيّأة على الخادم', reason: 'not_configured' }, 503);

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
  return json({ ok: true, path });
}

export function onRequestGet({ env }) {
  // فحص صحّة — منطقيات وجود فقط، لا قيم أسرار.
  return json({
    ok: configured(env),
    checks: { supabase_url: !!env.SUPABASE_URL, service_key: !!env.SUPABASE_SERVICE_ROLE_KEY },
  });
}

/**
 * Cloudflare Pages Function — رفع المورّد لمستند عرضه (نظام 3، معزولة)
 * ════════════════════════════════════════════════════════════════════════════
 * POST /api/portal-supplier-doc?t=<token>   (body = بايتات PDF/JPG/PNG)
 *
 * المسار الوحيد الذي يرفع فيه **طرف خارجي بلا حساب** ملفاً إلى تخزيننا، فالحرّاس مشدّدة:
 *   1) الرمز وحده هو الهوية — ويُتحقَّق منه في **القاعدة** عبر portal_supplier_token_request
 *      بمفتاح الخدمة (خادمي بحت): صالح · غير مُبطَل · غير منتهٍ · والطلب في مرحلة التسعير.
 *   2) **رقم الطلب يأتي من القاعدة لا من العميل** — فلا يستطيع حامل رمزٍ رفعَ ملف
 *      تحت مجلّد طلب آخر (المفتاح يُبنى من request_id المُعاد).
 *   3) نوع الملف بفحص التوقيع السحري (لا الاعتماد على Content-Type) وحجم ≤ 10MB.
 *   4) اسم الملف عشوائي من الخادم — لا شيء من مُدخَل المستخدم يدخل المفتاح.
 *   5) لا قراءة: هذه النقطة **رفع فقط**. عرض الملفات يبقى محصوراً بالموظّفين عبر
 *      /api/portal-quote (جلسة + تحقّق رؤية الطلب) — فلا يقرأ المورّد ملفات غيره.
 *
 * المفتاح المُعاد يُخزَّن في portal_offers.quote_pdf_key عبر portal_supplier_submit،
 * فيظهر مباشرةً في لوحة «ملفات عروض الأسعار» لدى المشتريات بلا أي خطوة إضافية.
 */
import { portalUrl, portalConfigured, svcHeaders } from './_portal-shared.js';
import { inspectUpload } from './_file-guard.js';

const REQID_RE = /^[A-Za-z0-9._-]{3,40}$/;

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

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);
  if (!portalConfigured(env)) return json({ error: 'الخدمة غير مهيّأة' }, 503);
  if (!env.QUOTES_BUCKET) return json({ error: 'تخزين الملفات غير مهيّأ' }, 503);

  const token = String(new URL(request.url).searchParams.get('t') || '').trim();
  if (!token || token.length < 20 || token.length > 120) return json({ error: 'رابط غير صالح' }, 400);

  // تحقّق الرمز في القاعدة (خادمي) — ومنه نأخذ رقم الطلب
  let reqId = '';
  try {
    const r = await fetch(`${portalUrl(env)}/rest/v1/rpc/portal_supplier_token_request`, {
      method: 'POST', headers: { ...svcHeaders(env), 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_token: token }),
    });
    if (!r.ok) return json({ error: 'تعذّر التحقّق من الرابط' }, 502);
    const j = await r.json();
    if (!j || j.ok !== true) {
      const msg = { expired: 'انتهت صلاحية الرابط', closed: 'أُقفل باب التسعير لهذا الطلب',
                    too_many: 'تجاوزتم الحدّ المسموح لرفع الملفات على هذا الرابط' }[j && j.reason] || 'رابط غير صالح';
      return json({ error: msg }, 403);
    }
    reqId = String(j.request_id || '');
  } catch (_) { return json({ error: 'تعذّر الاتصال بقاعدة البيانات' }, 502); }
  if (!REQID_RE.test(reqId)) return json({ error: 'معرّف طلب غير صالح' }, 500);

  const buf = await request.arrayBuffer();
  // حارس الملفات الطبقي: توقيع سحري + كشف متعدّد الصيغ + سلامة بنيوية + رفض المحتوى النشِط
  const sniff = inspectUpload(buf);
  if (!sniff.ok) return json({ error: sniff.error }, 400);

  const rand = (globalThis.crypto && crypto.randomUUID) ? crypto.randomUUID() : ('s' + Date.now() + Math.random().toString(36).slice(2, 10));
  const key = `quotes/${reqId}/${rand}.${sniff.ext}`;   // نفس فضاء مفاتيح عروض المشتريات
  try {
    await env.QUOTES_BUCKET.put(key, buf, { httpMetadata: { contentType: sniff.ct } });
  } catch (_) { return json({ error: 'تعذّر حفظ الملف' }, 502); }
  return json({ ok: true, key });
}

export function onRequestGet({ env }) {
  // فحص صحّة فقط — لا قراءة ملفات من هذه النقطة إطلاقاً.
  return json({ ok: !!(portalConfigured(env) && env.QUOTES_BUCKET),
                checks: { portal: !!portalConfigured(env), storage: !!env.QUOTES_BUCKET } });
}

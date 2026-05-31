/**
 * Cloudflare Pages Function — إطار التحقق الحكومي (السجل التجاري / الضريبي)
 * ----------------------------------------------------------------------
 * يتحقق من السجل التجاري عبر «وثق» (Wathq) عند توفّر المفتاح. جاهز للتوسعة
 * إلى ZATCA/GOSI. المفاتيح أسرار خادم — لا تصل المتصفح.
 *
 * الإعداد (أسرار بيئة Cloudflare Pages):
 *   WATHQ_API_KEY   مفتاح واجهة «وثق» (اختياري — بدونه يُعاد 503)
 *
 * POST /api/verify   { cr?: string, vat?: string }
 */

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
}
function sameOrigin(request) {
  const host = request.headers.get('host');
  const src = request.headers.get('origin') || request.headers.get('referer');
  if (!host || !src) return false;
  try { return new URL(src).host === host; } catch (_) { return false; }
}

export async function onRequestGet({ env }) {
  return json({ ok: !!env.WATHQ_API_KEY, providers: { wathq: !!env.WATHQ_API_KEY } });
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);
  if (!env.WATHQ_API_KEY) {
    return json({ error: 'التحقق الحكومي غير مُهيّأ على الخادم (WATHQ_API_KEY).' }, 503);
  }
  let body;
  try { body = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }
  const cr = (body && body.cr ? String(body.cr) : '').replace(/\D/g, '');
  if (!cr) return json({ error: 'رقم السجل التجاري مطلوب' }, 400);

  try {
    // واجهة «وثق» — معلومات السجل التجاري
    const r = await fetch(`https://api.wathq.sa/v5/commercialregistration/info/${encodeURIComponent(cr)}`, {
      headers: { apiKey: env.WATHQ_API_KEY, Accept: 'application/json' },
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) {
      return json({ ok: false, error: (data && (data.message || data.error)) || `تعذّر التحقق (HTTP ${r.status})` }, r.status === 404 ? 404 : 502);
    }
    // تلخيص النتيجة (الحقول تختلف حسب نسخة الواجهة)
    const name = data.crName || data.name || '';
    const status = (data.status && (data.status.name || data.status)) || '';
    const expiry = data.expiryDate || data.expiry || '';
    const summary = `السجل ${cr}${name ? ' — ' + name : ''}${status ? ' · الحالة: ' + status : ''}${expiry ? ' · ينتهي: ' + expiry : ''}`;
    return json({ ok: true, summary, cr: data });
  } catch (e) {
    return json({ error: 'تعذّر الاتصال بخدمة التحقق' }, 502);
  }
}

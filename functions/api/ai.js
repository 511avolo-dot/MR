/**
 * Cloudflare Pages Function — وسيط آمن لـ Google Gemini
 * ------------------------------------------------------
 * الغرض: إبقاء مفتاح Gemini API على الخادم فقط (سرّ بيئة) بدل تسريبه للمتصفح.
 *
 * الإعداد المطلوب (مرة واحدة):
 *   Cloudflare Dashboard → Pages → المشروع → Settings → Environment variables
 *   أضف متغيّراً سرّياً باسم  GEMINI_API_KEY  بقيمة مفتاح Google AI Studio.
 *
 * نقاط النهاية:
 *   GET  /api/ai           → فحص التوفّر + قائمة النماذج المتاحة
 *   POST /api/ai           → { model, action, body }
 *        action ∈ { "generateContent", "streamGenerateContent" }
 *
 * المفتاح لا يُرسل أبداً إلى العميل. يُمرَّر إلى Google عبر ترويسة x-goog-api-key.
 */

const GEMINI_BASE = 'https://generativelanguage.googleapis.com/v1beta';

// النماذج المسموح بها فقط — يمنع إساءة استخدام نقطة النهاية لاستدعاء نماذج عشوائية
const ALLOWED_MODELS = new Set([
  'gemini-2.5-flash',
  'gemini-2.5-flash-lite',
  'gemini-2.5-pro',
  'gemini-2.0-flash',
  'gemini-2.0-flash-001',
  'gemini-flash-latest',
  'gemini-pro-latest',
]);

const MAX_BODY_BYTES = 16 * 1024 * 1024; // 16MB (الوثائق المصوّرة base64 قد تكون كبيرة)

function jsonError(message, status, extra) {
  return new Response(
    JSON.stringify({ error: { message, status, ...(extra || {}) } }),
    { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } }
  );
}

/**
 * يقبل الطلب فقط إذا كان قادماً من نفس الموقع (Origin/Referer مطابق للمضيف).
 * هذا ضابط خفيف يمنع إساءة الاستخدام العابرة للمواقع واستهلاك حصّة Gemini من سكربتات بسيطة.
 * للحماية القوية ضد الإساءة: أضِف Cloudflare Turnstile أو مصادقة لاحقاً.
 */
function sameOrigin(request) {
  const host = request.headers.get('host');
  if (!host) return false;
  const origin = request.headers.get('origin');
  const referer = request.headers.get('referer');
  const src = origin || referer;
  if (!src) return false;
  try {
    return new URL(src).host === host;
  } catch (_) {
    return false;
  }
}

export async function onRequestGet({ request, env }) {
  if (!env.GEMINI_API_KEY) {
    return jsonError('لم يُضبط مفتاح الذكاء الاصطناعي على الخادم (GEMINI_API_KEY).', 503);
  }
  // فحص توفّر + قائمة النماذج (يُستخدم لاختبار الاتصال)
  try {
    const upstream = await fetch(`${GEMINI_BASE}/models`, {
      headers: { 'x-goog-api-key': env.GEMINI_API_KEY },
    });
    const headers = new Headers({ 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    return new Response(upstream.body, { status: upstream.status, headers });
  } catch (e) {
    return jsonError('تعذّر الاتصال بـ Gemini من الخادم.', 502);
  }
}

export async function onRequestPost({ request, env }) {
  if (!env.GEMINI_API_KEY) {
    return jsonError('لم يُضبط مفتاح الذكاء الاصطناعي على الخادم (GEMINI_API_KEY).', 503);
  }
  if (!sameOrigin(request)) {
    return jsonError('طلب غير مصرّح به (origin).', 403);
  }

  const lenHeader = request.headers.get('content-length');
  if (lenHeader && Number(lenHeader) > MAX_BODY_BYTES) {
    return jsonError('حجم الطلب كبير جداً.', 413);
  }

  let payload;
  try {
    payload = await request.json();
  } catch (_) {
    return jsonError('JSON غير صالح.', 400);
  }

  const { model, action, body } = payload || {};
  if (!ALLOWED_MODELS.has(model)) {
    return jsonError('النموذج غير مسموح به.', 400);
  }
  if (action !== 'generateContent' && action !== 'streamGenerateContent') {
    return jsonError('الإجراء غير مدعوم.', 400);
  }
  if (!body || typeof body !== 'object') {
    return jsonError('جسم الطلب مفقود.', 400);
  }

  const qs = action === 'streamGenerateContent' ? '?alt=sse' : '';
  const url = `${GEMINI_BASE}/models/${model}:${action}${qs}`;

  let upstream;
  try {
    upstream = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
      body: JSON.stringify(body),
    });
  } catch (e) {
    return jsonError('تعذّر الاتصال بـ Gemini من الخادم.', 502);
  }

  // تمرير الاستجابة كما هي (يدعم تدفّق SSE عبر تمرير body مباشرة)
  const headers = new Headers();
  headers.set('Content-Type', upstream.headers.get('Content-Type') || 'application/json');
  headers.set('Cache-Control', 'no-store');
  return new Response(upstream.body, { status: upstream.status, headers });
}

/**
 * /api/pr-doc — مرفق طلب الشراء الداخليّ (النظام 2): الطلب موقَّعاً من المدير.
 *
 * الاعتماد يقع على الورق خارج النظام بقرار المالك («ما في مواضيع اعتمادات…
 * إلا إذا مكنتهم من رفع الطلب PDF موقع من المدير»)، فهذا المرفق هو **دليل**
 * ذلك الاعتماد — ولذلك يُحفظ داخل النظام ولا يُحذف أبداً.
 *
 * POST /api/pr-doc?pr_id=<id>   جسم الطلب = بايتات الملف
 *   • same-origin + جلسة موظّف مُصادَقة (فشل مغلق ⇒ 401)
 *   • رؤية الطلب تُتحقَّق **بهوية المتصل نفسه** عبر `proc_can_see_pr` (RLS
 *     هي الحكم، لا فحصٌ نتخيّله هنا)
 *   • حارس `_file-guard` الطبقيّ نفسه المستعمَل في وثائق الموردين والبوابة
 *   • **المفتاح يُولَّد خادميّاً** (`docs/pr/<pr_id>/<uuid>.<ext>`) فلا يكتب
 *     العميل مساراً، ولا يرفع تحت مجلّد طلب آخر
 *
 * GET /api/pr-doc?key=<key>     بثّ الملف بترويسات التحييد المشتركة
 *   • نفس المصادقة + نفس فحص الرؤية على `pr_id` المستخرَج من المفتاح
 *
 * ⚠️ يعيد استعمال binding `SUPPLIER_DOCS` القائم (حاوية R2 نفسها لنظامَي 1 و2)
 * تحت بادئة `docs/pr/` — فلا إعداد Cloudflare جديد مطلوب من المالك.
 * ولا يلمس `QUOTES_BUCKET` (حاوية البوابة — النظام 3 معزول).
 */
import { inspectUpload, fileResponseHeaders, MAX_UPLOAD_BYTES } from './_file-guard.js';

const PREFIX = 'docs/pr/';
const PR_RE = /^[A-Za-z0-9._-]{3,60}$/;

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
const apiKey = (env) => env.SUPABASE_ANON_KEY || env.SUPABASE_SERVICE_ROLE_KEY || '';
const r2 = (env) => env.SUPPLIER_DOCS || null;

/** المفتاح يُقبل بشكله المولَّد خادمياً فقط — لا اجتياز مسار ولا قراءة كائن آخر. */
function parseKey(k) {
  const key = String(k || '').trim();
  if (!key || key.includes('..') || key.startsWith('/')) return null;
  const m = key.match(/^docs\/pr\/([A-Za-z0-9._-]{3,60})\/([A-Za-z0-9._-]{1,80})$/);
  return m ? { key, prId: m[1] } : null;
}

/**
 * فحص الرؤية **بهوية المتصل** لا بمفتاح الخدمة: نستدعي `proc_can_see_pr`
 * برمزه، فتحكم RLS ونطاق القطاع كما تحكمان في التطبيق. فشل مغلق: أي خطأ
 * أو أي ردّ غير `true` صريح ⇒ منع.
 */
async function canSeeRequest(env, jwt, prId) {
  const base = String(env.SUPABASE_URL || '').replace(/\/+$/, '');
  const key = apiKey(env);
  if (!base || !key || !jwt) return false;
  try {
    const r = await fetch(`${base}/rest/v1/rpc/proc_can_see_pr`, {
      method: 'POST',
      headers: { apikey: key, Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_pr_id: prId }),
    });
    if (!r.ok) return false;
    return (await r.json()) === true;
  } catch (_) { return false; }
}

/** رمز جلسة الموظّف. فشل مغلق: أي خطأ ⇒ null ⇒ 401. */
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
    return (u && u.email) ? jwt : null;
  } catch (_) { return null; }
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'طلب غير مصرّح به' }, 403);
  const bucket = r2(env);
  if (!bucket) return json({ error: 'خدمة رفع المرفقات غير مهيّأة', reason: 'not_configured' }, 503);

  const jwt = await verifyCaller(env, request);
  if (!jwt) return json({ error: 'غير مصرّح' }, 401);

  const prId = String(new URL(request.url).searchParams.get('pr_id') || '').trim();
  if (!PR_RE.test(prId)) return json({ error: 'رقم الطلب غير صالح' }, 400);
  if (!(await canSeeRequest(env, jwt, prId))) return json({ error: 'هذا الطلب خارج نطاقك' }, 403);

  const buf = await request.arrayBuffer();
  if (buf.byteLength > MAX_UPLOAD_BYTES) return json({ error: 'حجم الملف يتجاوز الحدّ المسموح' }, 400);
  const check = inspectUpload(buf);
  if (!check.ok) return json({ error: check.error, reason: 'rejected' }, 400);

  // الامتداد ونوع المحتوى من **التوقيع السحريّ** الذي فحصه الحارس، لا من اسم
  // الملف ولا من Content-Type الذي أرسله العميل.
  const key = `${PREFIX}${prId}/${crypto.randomUUID()}.${check.ext}`;
  try {
    await bucket.put(key, buf, { httpMetadata: { contentType: check.ct } });
  } catch (_) {
    return json({ error: 'تعذّر حفظ المرفق' }, 502);
  }
  // ⚠️ المفتاح لا يُثبَّت على الصفّ هنا: تفعل ذلك `pr_set_doc` بهوية المتصل
  // (حارس ملكية + قيد مجال المفتاح) — فلا يمنح هذا المسار كتابةً على الجدول.
  return json({ ok: true, key, content_type: check.ct, size: buf.byteLength });
}

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const bucket = r2(env);

  // نقطة فحص الصحّة (بلا مفتاح): منطقيات وجود فقط — لا قيم ولا أسرار.
  if (!url.searchParams.get('key')) {
    return json({ ok: !!bucket, checks: { r2_bucket: !!bucket, supabase_url: !!env.SUPABASE_URL, api_key: !!apiKey(env) } });
  }
  if (!bucket) return json({ error: 'خدمة المرفقات غير مهيّأة', reason: 'not_configured' }, 503);

  const parsed = parseKey(url.searchParams.get('key'));
  if (!parsed) return json({ error: 'مفتاح غير صالح' }, 400);

  const jwt = await verifyCaller(env, request);
  if (!jwt) return json({ error: 'غير مصرّح' }, 401);
  if (!(await canSeeRequest(env, jwt, parsed.prId))) return json({ error: 'هذا الطلب خارج نطاقك' }, 403);

  let obj = null;
  try { obj = await bucket.get(parsed.key); } catch (_) { obj = null; }
  if (!obj) return json({ error: 'المرفق غير موجود' }, 404);

  const ct = (obj.httpMetadata && obj.httpMetadata.contentType) || 'application/octet-stream';
  return new Response(obj.body, { status: 200, headers: fileResponseHeaders(ct) });
}

/**
 * Cloudflare Pages Function — رفع/عرض ملف عرض السعر (PDF) للبوابة (نظام 3)
 * ════════════════════════════════════════════════════════════════════════
 * معزولة تماماً عن نظام 1/2 (لا proc_*). التخزين في Cloudflare R2 (binding: QUOTES_BUCKET).
 *
 * POST /api/portal-quote?request_id=REQ-...   (body = بايتات PDF، Content-Type: application/pdf)
 *   - same-origin + مستخدم بوابة نشط + صلاحية can_manage_procurement.
 *   - تحقّق النوع/الحجم/توقيع %PDF. يخزّن في R2 بمفتاح quotes/<request_id>/<random>.pdf.
 *   - يُرجِع { ok, key }. ثم تمرّر الواجهة key إلى portal_submit_offer(p_quote_pdf_key).
 *
 * GET  /api/portal-quote?key=quotes/REQ-.../....pdf
 *   - same-origin + مستخدم بوابة نشط (+ تحقّق رؤية الطلب دفاعاً في العمق).
 *   - يبثّ الملف inline (لا رابط R2 مكشوف). الواجهة تجلبه بجلستها وتعرضه عبر object URL في iframe.
 */
import { portalUrl, portalKey, portalConfigured, svcHeaders } from './_portal-shared.js';
import { inspectUpload, fileResponseHeaders } from './_file-guard.js';

// المورّد قد يرفع صورة عرضه (تصوير مستند ورقي) عبر /api/portal-supplier-doc — فنقبل الصور عرضاً أيضاً.
const KEY_RE = /^quotes\/[A-Za-z0-9._-]{3,40}\/[A-Za-z0-9._-]{6,80}\.(pdf|jpg|jpeg|png)$/;
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
async function verifyStaff(env, base, jwt) {
  try {
    const r = await fetch(`${base}/auth/v1/user`, { headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}` } });
    if (!r.ok) return { ok: false, reason: 'الجلسة غير صالحة أو منتهية' };
    const u = await r.json();
    if (!u || !u.email) return { ok: false, reason: 'لا يوجد بريد في جلسة الدخول' };
    const email = String(u.email).toLowerCase();
    const safe = email.replace(/[\\%_]/g, c => '\\' + c);
    const resp = await fetch(`${base}/rest/v1/portal_users?email=ilike.${encodeURIComponent(safe)}&select=username,active`, { headers: svcHeaders(env) });
    if (!resp.ok) return { ok: false, reason: 'تعذّر التحقّق من المستخدمين' };
    const rows = await resp.json();
    const match = (Array.isArray(rows) ? rows : []).find((x) => x.active === true);
    if (!match) return { ok: false, reason: 'المستخدم غير نشط' };
    return { ok: true, username: match.username };
  } catch (_) { return { ok: false, reason: 'خطأ غير متوقّع' }; }
}
// يعيد استخدام منطق الصلاحيات الخادمي نفسه (portal_has_perm) بجلسة المستخدم.
async function hasPerm(env, base, jwt, perm) {
  try {
    const r = await fetch(`${base}/rest/v1/rpc/portal_has_perm`, {
      method: 'POST',
      headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_key: perm }),
    });
    if (!r.ok) return false;
    return (await r.json()) === true;
  } catch (_) { return false; }
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);
  if (!portalConfigured(env)) return json({ error: 'الخدمة غير مهيّأة' }, 503);
  if (!env.QUOTES_BUCKET) return json({ error: 'تخزين الملفات غير مهيّأ (QUOTES_BUCKET)' }, 503);

  const base = portalUrl(env);
  const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);
  const vs = await verifyStaff(env, base, jwt);
  if (!vs.ok) return json({ error: 'غير مصرّح', detail: vs.reason }, 403);
  if (!(await hasPerm(env, base, jwt, 'can_manage_procurement'))) return json({ error: 'تحتاج صلاحية إدارة المشتريات' }, 403);

  const reqId = String(new URL(request.url).searchParams.get('request_id') || '').trim();
  if (!REQID_RE.test(reqId)) return json({ error: 'معرّف طلب غير صالح' }, 400);

  const buf = await request.arrayBuffer();
  // حارس الملفات الطبقي (نفس الحارس المطبَّق على رفع المورّد الخارجي)
  const sniff = inspectUpload(buf);
  if (!sniff.ok) return json({ error: sniff.error }, 400);

  const rand = (globalThis.crypto && crypto.randomUUID) ? crypto.randomUUID() : ('q' + Date.now() + Math.random().toString(36).slice(2, 10));
  const key = `quotes/${reqId}/${rand}.${sniff.ext}`;
  try {
    await env.QUOTES_BUCKET.put(key, buf, { httpMetadata: { contentType: sniff.ct } });
  } catch (_) { return json({ error: 'تعذّر حفظ الملف' }, 502); }
  return json({ ok: true, key });
}

export async function onRequestGet({ request, env }) {
  if (!sameOrigin(request)) return new Response('forbidden', { status: 403 });
  if (!portalConfigured(env) || !env.QUOTES_BUCKET) return new Response('unavailable', { status: 503 });

  const base = portalUrl(env);
  const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return new Response('unauthorized', { status: 401 });
  const vs = await verifyStaff(env, base, jwt);
  if (!vs.ok) return new Response('forbidden', { status: 403 });

  const key = String(new URL(request.url).searchParams.get('key') || '').trim();
  if (!KEY_RE.test(key)) return new Response('bad key', { status: 400 });

  // تحقّق أن المستخدم يرى الطلب صاحب الملف — **يفشل مغلقاً** (لا يُبَثّ إلا بتأكيد رؤية صريح).
  const reqId = key.split('/')[1];
  let canSee = false;
  try {
    const r = await fetch(`${base}/rest/v1/rpc/portal_can_see_request`, {
      method: 'POST',
      headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_id: reqId }),
    });
    if (r.ok) canSee = (await r.json()) === true;
  } catch (_) { canSee = false; }
  if (!canSee) return new Response('forbidden', { status: 403 });

  const obj = await env.QUOTES_BUCKET.get(key);
  if (!obj) return new Response('not found', { status: 404 });
  const ct = (obj.httpMetadata && obj.httpMetadata.contentType) || 'application/pdf';
  return new Response(obj.body, { status: 200, headers: fileResponseHeaders(ct) });
}

/**
 * Cloudflare Pages Function — رفع/عرض مستندات الصرف والاستلام (البوابة، نظام 3)
 * ════════════════════════════════════════════════════════════════════════
 * معزولة تماماً عن نظام 1/2 (لا proc_*). التخزين في Cloudflare R2 (binding: QUOTES_BUCKET).
 * تكمّل portal-quote.js: هذه لمحاضر الصرف (محضر/سند تحويل) ومشاهد/محاضر الاستلام.
 *
 * POST /api/portal-doc?request_id=REQ-...&kind=pay|grn   (body = بايتات PDF/صورة)
 *   - same-origin + مستخدم بوابة نشط + الصلاحية حسب النوع:
 *       kind=pay → can_disburse   (محضر الصرف)   · kind=grn → can_verify_stock (مشهد الاستلام)
 *   - يقبل PDF أو JPEG أو PNG، ≤ 10MB، بفحص magic bytes. مفتاح docs/<kind>/<request_id>/<random>.<ext>.
 *   - يُرجِع { ok, key }. تخزّن الواجهة key في details.proof_key (صرف) أو portal_receipts.doc_key (استلام).
 *
 * GET  /api/portal-doc?key=docs/pay/REQ-.../....pdf
 *   - same-origin + مستخدم نشط + تحقّق رؤية الطلب. يبثّ الملف inline (لا رابط R2 مكشوف).
 */
import { portalUrl, portalKey, portalConfigured, svcHeaders } from './_portal-shared.js';
import { inspectUpload, fileResponseHeaders } from './_file-guard.js';

const KEY_RE = /^docs\/(pay|grn|inst|inv|ret|disb|reqdoc)\/[A-Za-z0-9._-]{3,40}\/[A-Za-z0-9._-]{6,80}\.(pdf|jpg|jpeg|png)$/;
const REQID_RE = /^[A-Za-z0-9._-]{3,40}$/;
// pay=محضر صرف (مالية) · grn=مشهد استلام (مستودع) · inst=مرفق دفعة (مشتريات) · inv=أصل فاتورة المورد (مشتريات/مالية)
// ret=محضر مرتجع/تالف (استلام/جودة أو مشتريات) · disb=سند تحويل الصرف المباشر (مسؤول البنك).
// reqdoc=مستند داعم لطلب الصرف المباشر (062) — يرفعه المُقدِّم/المحرِّر على مسودّته؛ ثم تُنشئ
//   الواجهة صفّ portal_request_documents عبر RPC (portal_attach_document) الذي يفرض الحالة/النوع/الصيغة.
// القيمة مصفوفة صلاحيات — يكفي امتلاك إحداها للرفع (والـRPC يفرض التحكّم الدقيق: المُقدّم/can_edit/أدمن + مسودّة).
const KIND_PERM = {
  pay:    ['can_disburse'],
  grn:    ['can_verify_stock'],
  inst:   ['can_manage_procurement'],
  inv:    ['can_manage_procurement', 'can_see_finance'],
  ret:    ['can_verify_stock', 'can_manage_procurement'],
  disb:   ['can_disburse'],
  reqdoc: ['can_create', 'can_edit'],
};

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
async function canSeeRequest(env, base, jwt, reqId) {
  try {
    const r = await fetch(`${base}/rest/v1/rpc/portal_can_see_request`, {
      method: 'POST',
      headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_id: reqId }),
    });
    return r.ok && (await r.json()) === true;
  } catch (_) { return false; }
}
// (Codex round-3) قبل كتابة كائن reqdoc إلى R2: تأكّد أنّ الطلب موجود ومرئيّ للمُستدعي وفي حالة
// مسودّة/مُعاد — يمنع تراكم كائنات يتيمة تحت معرّفات طلبات عشوائية أو لا يملكها المُستدعي.
async function reqdocTargetOk(env, base, jwt, reqId) {
  try {
    if (!(await canSeeRequest(env, base, jwt, reqId))) return false;
    const r = await fetch(`${base}/rest/v1/portal_requests?id=eq.${encodeURIComponent(reqId)}&select=status`, { headers: svcHeaders(env) });
    if (!r.ok) return false;
    const rows = await r.json();
    if (!Array.isArray(rows) || !rows.length) return false;
    return rows[0].status === 'draft' || rows[0].status === 'returned';
  } catch (_) { return false; }
}
// تحقّق أنّ للمفتاح صفّاً في portal_request_documents (لعرض reqdoc). الوجود يكفي (لا شرط active):
//  • المُزال (portal_remove_document) يحذف الصفّ ⇒ لا صفّ ⇒ 404 (يُغلق الكشف بعد الإزالة).
//  • المُستبدَل/المؤرشف (active=false) يبقى صفّه ⇒ يظلّ قابلاً للعرض في سجلّ الإصدارات (طلب المالك).
async function reqdocRowExists(env, base, jwt, key) {
  try {
    const r = await fetch(`${base}/rest/v1/portal_request_documents?storage_key=eq.${encodeURIComponent(key)}&select=id&limit=1`,
      { headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}` } });
    if (!r.ok) return false;
    const rows = await r.json();
    return Array.isArray(rows) && rows.length > 0;
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

  const url = new URL(request.url);
  const kind = String(url.searchParams.get('kind') || '').trim();
  const perms = KIND_PERM[kind];
  if (!perms) return json({ error: 'نوع مستند غير صالح (pay|grn|inst|inv|ret|disb|reqdoc)' }, 400);
  let permitted = false;
  for (const p of perms) { if (await hasPerm(env, base, jwt, p)) { permitted = true; break; } }
  if (!permitted) return json({ error: 'صلاحية غير كافية لرفع هذا المستند' }, 403);

  const reqId = String(url.searchParams.get('request_id') || '').trim();
  if (!REQID_RE.test(reqId)) return json({ error: 'معرّف طلب غير صالح' }, 400);
  // (Codex round-3) مستند طلب داعم: تحقّق من الطلب الهدف (وجود/رؤية/حالة مسودّة-مُعاد) قبل الكتابة إلى R2.
  if (kind === 'reqdoc' && !(await reqdocTargetOk(env, base, jwt, reqId))) {
    return json({ error: 'طلب غير صالح لإرفاق مستند (غير مرئي لك أو ليس مسودّة/مُعاداً)' }, 403);
  }

  const buf = await request.arrayBuffer();
  // حارس الملفات الطبقي المشترك
  const sniff = inspectUpload(buf);
  if (!sniff.ok) return json({ error: sniff.error }, 400);

  const rand = (globalThis.crypto && crypto.randomUUID) ? crypto.randomUUID() : ('d' + Date.now() + Math.random().toString(36).slice(2, 10));
  const key = `docs/${kind}/${reqId}/${rand}.${sniff.ext}`;
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

  // تحقّق أن المستخدم يرى الطلب صاحب الملف — يفشل مغلقاً (لا يُبَثّ إلا بتأكيد رؤية صريح).
  // مفتاح docs/<kind>/<reqId>/... — أي خطأ/تعذّر تحقّق ⇒ رفض (fail-closed).
  const reqId = key.split('/')[2];
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

  // (Codex round-3) مستند طلب داعم (reqdoc): لا يُبَثّ إلا إن كان له صفّ — المُزال (المحذوف) يصير غير قابل للعرض.
  if (key.startsWith('docs/reqdoc/') && !(await reqdocRowExists(env, base, jwt, key))) {
    return new Response('not found', { status: 404 });
  }

  const obj = await env.QUOTES_BUCKET.get(key);
  if (!obj) return new Response('not found', { status: 404 });
  const ct = (obj.httpMetadata && obj.httpMetadata.contentType) || 'application/octet-stream';
  return new Response(obj.body, { status: 200, headers: fileResponseHeaders(ct) });
}

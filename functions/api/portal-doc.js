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

const MAX_BYTES = 10 * 1024 * 1024; // 10 MB
const KEY_RE = /^docs\/(pay|grn|inst)\/[A-Za-z0-9._-]{3,40}\/[A-Za-z0-9._-]{6,80}\.(pdf|jpg|jpeg|png)$/;
const REQID_RE = /^[A-Za-z0-9._-]{3,40}$/;
// pay=محضر صرف (مالية) · grn=مشهد استلام (مستودع) · inst=مرفق دفعة مستحقة (مشتريات)
const KIND_PERM = { pay: 'can_disburse', grn: 'can_verify_stock', inst: 'can_manage_procurement' };

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
// يتحقّق من التوقيع السحري ويعيد الامتداد المطابق، أو null إن لم يكن نوعاً مسموحاً.
function sniffExt(buf) {
  const h = new Uint8Array(buf.slice(0, 8));
  if (h[0] === 0x25 && h[1] === 0x50 && h[2] === 0x44 && h[3] === 0x46) return { ext: 'pdf', ct: 'application/pdf' }; // %PDF
  if (h[0] === 0xff && h[1] === 0xd8 && h[2] === 0xff) return { ext: 'jpg', ct: 'image/jpeg' };                        // JPEG
  if (h[0] === 0x89 && h[1] === 0x50 && h[2] === 0x4e && h[3] === 0x47) return { ext: 'png', ct: 'image/png' };        // PNG
  return null;
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
  const perm = KIND_PERM[kind];
  if (!perm) return json({ error: 'نوع مستند غير صالح (pay|grn)' }, 400);
  if (!(await hasPerm(env, base, jwt, perm))) {
    return json({ error: kind === 'pay' ? 'تحتاج صلاحية الصرف' : 'تحتاج صلاحية تأكيد الاستلام' }, 403);
  }

  const reqId = String(url.searchParams.get('request_id') || '').trim();
  if (!REQID_RE.test(reqId)) return json({ error: 'معرّف طلب غير صالح' }, 400);

  const buf = await request.arrayBuffer();
  if (buf.byteLength === 0) return json({ error: 'ملف فارغ' }, 400);
  if (buf.byteLength > MAX_BYTES) return json({ error: 'حجم الملف يتجاوز 10 ميجابايت' }, 400);
  const sniff = sniffExt(buf);
  if (!sniff) return json({ error: 'الملف يجب أن يكون PDF أو صورة (JPG/PNG)' }, 400);

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

  // دفاع في العمق: تحقّق أن المستخدم يرى الطلب صاحب الملف. مفتاح docs/<kind>/<reqId>/...
  const reqId = key.split('/')[2];
  try {
    const r = await fetch(`${base}/rest/v1/rpc/portal_can_see_request`, {
      method: 'POST',
      headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_id: reqId }),
    });
    if (r.ok && (await r.json()) === false) return new Response('forbidden', { status: 403 });
  } catch (_) { /* best-effort */ }

  const obj = await env.QUOTES_BUCKET.get(key);
  if (!obj) return new Response('not found', { status: 404 });
  const ct = (obj.httpMetadata && obj.httpMetadata.contentType) || 'application/octet-stream';
  return new Response(obj.body, {
    status: 200,
    headers: {
      'Content-Type': ct,
      'Content-Disposition': 'inline',
      'Cache-Control': 'private, no-store',
    },
  });
}

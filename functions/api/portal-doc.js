/**
 * Cloudflare Pages Function — رفع/عرض مستندات الصرف والاستلام (البوابة، نظام 3)
 * ════════════════════════════════════════════════════════════════════════
 * معزولة تماماً عن نظام 1/2 (لا proc_*). التخزين في Cloudflare R2 (binding: QUOTES_BUCKET).
 *
 * POST /api/portal-doc?request_id=REQ-...&kind=pay|grn|inst|inv|ret|disb|reqdoc
 *   - same-origin + مستخدم بوابة نشط + الصلاحية حسب النوع.
 *   - يقبل PDF أو JPEG أو PNG، ≤ 10MB، بفحص magic bytes.
 *   - بعد نجاح R2 put فقط، يسجل إيصال رفع خادمي قصير العمر في Supabase.
 *   - أي فشل في تسجيل الإيصال يحذف كائن R2 ويُغلق الطلب؛ لا metadata بلا ملف.
 *
 * GET /api/portal-doc?key=docs/<kind>/<request>/...
 *   - same-origin + مستخدم نشط + تحقّق رؤية الطلب، مع fail-closed.
 */
import { portalUrl, portalKey, portalConfigured, svcHeaders } from './_portal-shared.js';
import { inspectUpload, fileResponseHeaders } from './_file-guard.js';

const KEY_RE = /^docs\/(pay|grn|inst|inv|ret|disb|reqdoc)\/[A-Za-z0-9._-]{3,40}\/[A-Za-z0-9._-]{6,80}\.(pdf|jpg|jpeg|png)$/;
const REQID_RE = /^[A-Za-z0-9._-]{3,40}$/;
const KIND_PERM = {
  pay: ['can_disburse'],
  grn: ['can_verify_stock'],
  inst: ['can_manage_procurement'],
  inv: ['can_manage_procurement', 'can_see_finance'],
  ret: ['can_verify_stock', 'can_manage_procurement'],
  disb: ['can_disburse'],
  reqdoc: ['can_create_direct_expense', 'can_create', 'can_edit'],
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
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
    const r = await fetch(`${base}/auth/v1/user`, {
      headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}` },
    });
    if (!r.ok) return { ok: false, reason: 'الجلسة غير صالحة أو منتهية' };
    const u = await r.json();
    if (!u || !u.email) return { ok: false, reason: 'لا يوجد بريد في جلسة الدخول' };
    const email = String(u.email).toLowerCase();
    const safe = email.replace(/[\\%_]/g, c => '\\' + c);
    const resp = await fetch(
      `${base}/rest/v1/portal_users?email=ilike.${encodeURIComponent(safe)}&select=username,active`,
      { headers: svcHeaders(env) },
    );
    if (!resp.ok) return { ok: false, reason: 'تعذّر التحقّق من المستخدمين' };
    const rows = await resp.json();
    const match = (Array.isArray(rows) ? rows : []).find(x => x.active === true);
    if (!match) return { ok: false, reason: 'المستخدم غير نشط' };
    return { ok: true, username: match.username };
  } catch (_) {
    return { ok: false, reason: 'خطأ غير متوقّع' };
  }
}

async function hasPerm(env, base, jwt, perm) {
  try {
    const r = await fetch(`${base}/rest/v1/rpc/portal_has_perm`, {
      method: 'POST',
      headers: {
        apikey: portalKey(env),
        Authorization: `Bearer ${jwt}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ p_key: perm }),
    });
    return r.ok && (await r.json()) === true;
  } catch (_) {
    return false;
  }
}

async function canSeeRequest(env, base, jwt, reqId) {
  try {
    const r = await fetch(`${base}/rest/v1/rpc/portal_can_see_request`, {
      method: 'POST',
      headers: {
        apikey: portalKey(env),
        Authorization: `Bearer ${jwt}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ p_id: reqId }),
    });
    return r.ok && (await r.json()) === true;
  } catch (_) {
    return false;
  }
}

async function reqdocTargetOk(env, base, jwt, reqId, username) {
  try {
    if (!(await canSeeRequest(env, base, jwt, reqId))) return false;
    const r = await fetch(
      `${base}/rest/v1/portal_requests?id=eq.${encodeURIComponent(reqId)}&select=status,requester`,
      { headers: svcHeaders(env) },
    );
    if (!r.ok) return false;
    const rows = await r.json();
    if (!Array.isArray(rows) || !rows.length) return false;
    const row = rows[0];
    if (row.status !== 'draft' && row.status !== 'returned') return false;
    if (row.requester === username) return true;
    return await hasPerm(env, base, jwt, 'can_edit');
  } catch (_) {
    return false;
  }
}

async function reqdocRowExists(env, base, jwt, key) {
  try {
    const r = await fetch(
      `${base}/rest/v1/portal_request_documents?storage_key=eq.${encodeURIComponent(key)}&select=id&limit=1`,
      { headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}` } },
    );
    if (!r.ok) return false;
    const rows = await r.json();
    return Array.isArray(rows) && rows.length > 0;
  } catch (_) {
    return false;
  }
}

async function sha256Hex(buf) {
  const digest = await crypto.subtle.digest('SHA-256', buf);
  return Array.from(new Uint8Array(digest))
    .map(byte => byte.toString(16).padStart(2, '0'))
    .join('');
}

async function registerUploadReceipt(env, base, receipt) {
  const headers = {
    ...svcHeaders(env),
    'Content-Type': 'application/json',
    Prefer: 'return=minimal',
  };
  const r = await fetch(`${base}/rest/v1/portal_upload_receipts`, {
    method: 'POST',
    headers,
    body: JSON.stringify(receipt),
  });
  return r.ok;
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);
  if (!portalConfigured(env)) return json({ error: 'الخدمة غير مهيّأة' }, 503);
  if (!env.QUOTES_BUCKET) return json({ error: 'تخزين الملفات غير مهيّأ (QUOTES_BUCKET)' }, 503);

  const base = portalUrl(env);
  const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);
  const staff = await verifyStaff(env, base, jwt);
  if (!staff.ok) return json({ error: 'غير مصرّح', detail: staff.reason }, 403);

  const url = new URL(request.url);
  const kind = String(url.searchParams.get('kind') || '').trim();
  const perms = KIND_PERM[kind];
  if (!perms) return json({ error: 'نوع مستند غير صالح' }, 400);

  let permitted = false;
  for (const perm of perms) {
    if (await hasPerm(env, base, jwt, perm)) {
      permitted = true;
      break;
    }
  }
  if (!permitted) return json({ error: 'صلاحية غير كافية لرفع هذا المستند' }, 403);

  const reqId = String(url.searchParams.get('request_id') || '').trim();
  if (!REQID_RE.test(reqId)) return json({ error: 'معرّف طلب غير صالح' }, 400);
  if (kind === 'reqdoc' && !(await reqdocTargetOk(env, base, jwt, reqId, staff.username))) {
    return json({ error: 'طلب غير صالح لإرفاق مستند' }, 403);
  }

  const buf = await request.arrayBuffer();
  const sniff = inspectUpload(buf);
  if (!sniff.ok) return json({ error: sniff.error }, 400);

  const rand = globalThis.crypto && crypto.randomUUID
    ? crypto.randomUUID()
    : `d${Date.now()}${Math.random().toString(36).slice(2, 10)}`;
  const key = `docs/${kind}/${reqId}/${rand}.${sniff.ext}`;
  if (!KEY_RE.test(key)) return json({ error: 'تعذّر إنشاء مفتاح تخزين آمن' }, 500);

  let checksum;
  try {
    checksum = await sha256Hex(buf);
    await env.QUOTES_BUCKET.put(key, buf, { httpMetadata: { contentType: sniff.ct } });
  } catch (_) {
    return json({ error: 'تعذّر حفظ الملف' }, 502);
  }

  const receiptOk = await registerUploadReceipt(env, base, {
    storage_key: key,
    request_id: reqId,
    kind,
    mime_type: sniff.ct,
    size_bytes: buf.byteLength,
    checksum,
    uploaded_by: staff.username,
    expires_at: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
    metadata: { source: 'cloudflare-pages', verified_magic_bytes: true },
  });

  if (!receiptOk) {
    try { await env.QUOTES_BUCKET.delete(key); } catch (_) { /* best-effort cleanup */ }
    return json({ error: 'تعذّر توثيق الرفع — لم يُعتمد الملف' }, 502);
  }

  return json({ ok: true, key });
}

export async function onRequestGet({ request, env }) {
  if (!sameOrigin(request)) return new Response('forbidden', { status: 403 });
  if (!portalConfigured(env) || !env.QUOTES_BUCKET) {
    return new Response('unavailable', { status: 503 });
  }

  const base = portalUrl(env);
  const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return new Response('unauthorized', { status: 401 });
  const staff = await verifyStaff(env, base, jwt);
  if (!staff.ok) return new Response('forbidden', { status: 403 });

  const key = String(new URL(request.url).searchParams.get('key') || '').trim();
  if (!KEY_RE.test(key)) return new Response('bad key', { status: 400 });

  const reqId = key.split('/')[2];
  if (!(await canSeeRequest(env, base, jwt, reqId))) {
    return new Response('forbidden', { status: 403 });
  }

  if (key.startsWith('docs/reqdoc/') && !(await reqdocRowExists(env, base, jwt, key))) {
    return new Response('not found', { status: 404 });
  }

  const obj = await env.QUOTES_BUCKET.get(key);
  if (!obj) return new Response('not found', { status: 404 });
  const ct = (obj.httpMetadata && obj.httpMetadata.contentType) || 'application/octet-stream';
  return new Response(obj.body, { status: 200, headers: fileResponseHeaders(ct) });
}

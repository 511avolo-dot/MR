/**
 * /api/pr-doc — مستندات طلب الشراء الداخلي (النظام 2).
 *
 * POST /api/pr-doc?pr_id=<id>&kind=<kind>
 *   يستقبل PDF/JPEG/PNG خاماً، يفحص محتواه، يحفظه في SUPPLIER_DOCS تحت
 *   docs/pr/<pr_id>/<uuid>.<ext>، ثم يسجله في proc_pr_attachments بهوية
 *   الموظف. إذا فشل التسجيل تُحذف نسخة R2 فوراً حتى لا يبقى ملف يتيم.
 *
 * GET /api/pr-doc?key=<key>
 *   يبث مستنداً مسجلاً فقط بعد التحقق من جلسة الموظف ونطاق رؤيته للطلب.
 *   يدعم مفاتيح doc_key القديمة أثناء الانتقال، ولا يلمس QUOTES_BUCKET
 *   الخاص ببوابة الطلبات والموافقات المنفصلة (النظام 3).
 */
import { inspectUpload, fileResponseHeaders, MAX_UPLOAD_BYTES } from './_file-guard.js';

const PREFIX = 'docs/pr/';
const PR_RE = /^[A-Za-z0-9._-]{3,60}$/;
const KINDS = new Set(['source_form', 'quote', 'support', 'technical', 'comparison', 'other']);

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
const supabaseBase = (env) => String(env.SUPABASE_URL || '').replace(/\/+$/, '');
const userHeaders = (env, jwt) => ({
  apikey: apiKey(env), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json',
});

function parseKey(value) {
  const key = String(value || '').trim();
  if (!key || key.includes('..') || key.startsWith('/')) return null;
  const match = key.match(/^docs\/pr\/([A-Za-z0-9._-]{3,60})\/([A-Za-z0-9._-]{1,80})$/);
  return match ? { key, prId: match[1] } : null;
}
function originalName(request) {
  const raw = request.headers.get('x-file-name') || 'مرفق';
  let decoded = raw;
  try { decoded = decodeURIComponent(raw); } catch (_) { /* keep the safe raw value */ }
  return String(decoded).replace(/[\u0000-\u001f\u007f/\\]+/g, '_').trim().slice(0, 160) || 'مرفق';
}

async function verifyCaller(env, request) {
  const base = supabaseBase(env); const key = apiKey(env);
  if (!base || !key) return null;
  const auth = request.headers.get('authorization') || '';
  const jwt = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!jwt) return null;
  try {
    const response = await fetch(`${base}/auth/v1/user`, {
      headers: { apikey: key, Authorization: `Bearer ${jwt}` },
    });
    if (!response.ok) return null;
    const user = await response.json();
    return user && user.email ? jwt : null;
  } catch (_) { return null; }
}

async function canSeeRequest(env, jwt, prId) {
  const base = supabaseBase(env); const key = apiKey(env);
  if (!base || !key || !jwt) return false;
  try {
    const response = await fetch(`${base}/rest/v1/rpc/proc_can_see_pr`, {
      method: 'POST', headers: userHeaders(env, jwt), body: JSON.stringify({ p_pr_id: prId }),
    });
    return response.ok && (await response.json()) === true;
  } catch (_) { return false; }
}

async function registerAttachment(env, jwt, attachment) {
  const response = await fetch(`${supabaseBase(env)}/rest/v1/rpc/pr_register_attachment`, {
    method: 'POST', headers: userHeaders(env, jwt), body: JSON.stringify({
      p_pr_id: attachment.prId,
      p_key: attachment.key,
      p_file_name: attachment.fileName,
      p_kind: attachment.kind,
      p_content_type: attachment.contentType,
      p_size_bytes: attachment.size,
    }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || !body || body.ok !== true) {
    throw new Error(body.message || body.error || `HTTP ${response.status}`);
  }
  return body;
}

async function attachmentIsRegistered(env, jwt, parsed) {
  const headers = userHeaders(env, jwt); delete headers['Content-Type'];
  const base = supabaseBase(env); const key = encodeURIComponent(parsed.key); const prId = encodeURIComponent(parsed.prId);
  try {
    const current = await fetch(
      `${base}/rest/v1/proc_pr_attachments?object_key=eq.${key}&pr_id=eq.${prId}&deleted_at=is.null&select=id&limit=1`,
      { headers },
    );
    if (current.ok && (await current.json()).length > 0) return true;
    const legacy = await fetch(
      `${base}/rest/v1/proc_purchase_requests?id=eq.${prId}&doc_key=eq.${key}&select=id&limit=1`,
      { headers },
    );
    return legacy.ok && (await legacy.json()).length > 0;
  } catch (_) { return false; }
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'طلب غير مصرّح به' }, 403);
  const bucket = r2(env);
  if (!bucket) return json({ error: 'خدمة رفع المرفقات غير مهيّأة', reason: 'not_configured' }, 503);
  if (!supabaseBase(env) || !apiKey(env)) return json({ error: 'خدمة تسجيل المرفقات غير مهيّأة' }, 503);

  const jwt = await verifyCaller(env, request);
  if (!jwt) return json({ error: 'غير مصرّح' }, 401);
  const url = new URL(request.url);
  const prId = String(url.searchParams.get('pr_id') || '').trim();
  const kindParam = String(url.searchParams.get('kind') || 'support').trim();
  const kind = KINDS.has(kindParam) ? kindParam : 'support';
  if (!PR_RE.test(prId)) return json({ error: 'رقم الطلب غير صالح' }, 400);
  if (!(await canSeeRequest(env, jwt, prId))) return json({ error: 'هذا الطلب خارج نطاقك' }, 403);

  const declaredLength = Number(request.headers.get('content-length') || 0);
  if (Number.isFinite(declaredLength) && declaredLength > MAX_UPLOAD_BYTES) {
    return json({ error: 'حجم الملف يتجاوز الحدّ المسموح' }, 413);
  }
  const buf = await request.arrayBuffer();
  if (buf.byteLength > MAX_UPLOAD_BYTES) return json({ error: 'حجم الملف يتجاوز الحدّ المسموح' }, 413);
  const check = inspectUpload(buf);
  if (!check.ok) return json({ error: check.error, reason: 'rejected' }, 400);

  const key = `${PREFIX}${prId}/${crypto.randomUUID()}.${check.ext}`;
  try {
    await bucket.put(key, buf, { httpMetadata: { contentType: check.ct } });
  } catch (_) {
    return json({ error: 'تعذّر حفظ المرفق' }, 502);
  }

  try {
    const record = await registerAttachment(env, jwt, {
      prId, key, kind, fileName: originalName(request), contentType: check.ct, size: buf.byteLength,
    });
    return json({ ok: true, attachment: record });
  } catch (error) {
    console.error('pr-doc registration failed', { prId, error: String(error && error.message || error) });
    try { await bucket.delete(key); }
    catch (cleanupError) { console.error('pr-doc orphan cleanup failed', { prId, error: String(cleanupError && cleanupError.message || cleanupError) }); }
    return json({ error: 'تعذّر تسجيل المرفق؛ لم يُعتمد الرفع', reason: 'registration_failed' }, 502);
  }
}

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url); const bucket = r2(env);
  if (!url.searchParams.get('key')) {
    return json({ ok: !!bucket, checks: {
      r2_bucket: !!bucket, supabase_url: !!env.SUPABASE_URL, api_key: !!apiKey(env),
    } });
  }
  if (!bucket) return json({ error: 'خدمة المرفقات غير مهيّأة', reason: 'not_configured' }, 503);
  const parsed = parseKey(url.searchParams.get('key'));
  if (!parsed) return json({ error: 'مفتاح غير صالح' }, 400);

  const jwt = await verifyCaller(env, request);
  if (!jwt) return json({ error: 'غير مصرّح' }, 401);
  if (!(await canSeeRequest(env, jwt, parsed.prId))) return json({ error: 'هذا الطلب خارج نطاقك' }, 403);
  if (!(await attachmentIsRegistered(env, jwt, parsed))) return json({ error: 'المرفق غير مسجّل على الطلب' }, 404);

  let obj = null;
  try { obj = await bucket.get(parsed.key); } catch (_) { obj = null; }
  if (!obj) return json({ error: 'المرفق غير موجود' }, 404);
  const contentType = (obj.httpMetadata && obj.httpMetadata.contentType) || 'application/octet-stream';
  return new Response(obj.body, { status: 200, headers: fileResponseHeaders(contentType) });
}

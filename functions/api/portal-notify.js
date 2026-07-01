/**
 * Cloudflare Pages Function — إشعارات بريد بوابة الطلبات المستقلة (portal_*)
 * ════════════════════════════════════════════════════════════════════════
 * معزولة تماماً عن notify.js (تسجيل الموردين) و_pr-shared.js (requests.html):
 * لا تلمس أي جدول proc_ أو pr_. تتعامل حصراً مع جداول ودوال portal_ عبر _portal-shared.js.
 *
 * POST /api/portal-notify   { kind, request_id, event, comment }
 *   kind: 'request' | 'award' | 'payment' | 'receipt'
 *
 * الأمان:
 *   - same-origin فقط.
 *   - المستدعي يرسل رمز جلسته؛ نتحقّق أنه مستخدم بوابة نشط (portal_users.active).
 *   - المستقبِلون يُحدَّدون دائماً من قاعدة البيانات (سلسلة الاعتماد/الصلاحيات) —
 *     لا عنوان بريد من العميل إطلاقاً.
 *   - نُعيد قراءة حالة الطلب من القاعدة ونطابقها مع الحدث المطلوب قبل الإرسال
 *     (كبح انتحال حدث لا يطابق الحالة الفعلية) — الإرسال «أفضل جهد» ولا يُفشل
 *     أي عملية في الواجهة إن تعذّر.
 */
import {
  loadRequest, deptName, loadApprovals, loadAwardApprovals,
  notifyPending, notifyResult, notifyInfo, notifyProcurement,
  resolveAwardStageApprovers, currentPendingStage, publicOrigin,
} from './_portal-shared.js';

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
const emailConfigured = (env) => !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY && env.RESEND_API_KEY);

async function verifyPortalStaff(env, base, jwt) {
  try {
    const r = await fetch(`${base}/auth/v1/user`, { headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${jwt}` } });
    if (!r.ok) return { ok: false, reason: 'الجلسة غير صالحة أو منتهية' };
    const u = await r.json();
    if (!u || !u.email) return { ok: false, reason: 'لا يوجد بريد في جلسة الدخول' };
    const email = String(u.email).toLowerCase();
    const svc = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` };
    const safe = email.replace(/[\\%_]/g, c => '\\' + c);
    const resp = await fetch(`${base}/rest/v1/portal_users?email=ilike.${encodeURIComponent(safe)}&select=username,active`, { headers: svc });
    if (!resp.ok) return { ok: false, reason: 'تعذّر التحقّق من قائمة المستخدمين' };
    const rows = await resp.json();
    const match = (Array.isArray(rows) ? rows : []).find((x) => x.active !== false);
    if (!match) return { ok: false, reason: `بريد جلستك (${email}) لا يطابق أي مستخدم بوابة نشط` };
    return { ok: true, username: match.username };
  } catch (_) { return { ok: false, reason: 'خطأ غير متوقّع أثناء التحقّق' }; }
}

export async function onRequestGet({ env }) {
  return json({ ok: emailConfigured(env) });
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);
  if (!emailConfigured(env)) return json({ skipped: true, reason: 'email_not_configured' });

  let payload;
  try { payload = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }

  const base = env.SUPABASE_URL;
  const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);
  const vs = await verifyPortalStaff(env, base, jwt);
  if (!vs.ok) return json({ error: 'غير مصرّح', detail: vs.reason }, 403);

  const kind = String(payload && payload.kind || '').trim();
  const requestId = String(payload && payload.request_id || '').trim();
  const event = String(payload && payload.event || '').trim();
  const comment = payload && payload.comment ? String(payload.comment) : '';
  if (!requestId || !kind || !event) return json({ error: 'مدخلات غير صالحة' }, 400);

  const req = await loadRequest(env, base, requestId);
  if (!req) return json({ error: 'الطلب غير موجود' }, 404);
  const deptLabel = await deptName(env, base, req.department_id);

  let origin = ''; try { origin = new URL(request.headers.get('origin') || request.headers.get('referer')).origin; } catch (_) {}
  origin = publicOrigin(env, origin);

  try {
    let res;

    if (kind === 'request') {
      if (event === 'submitted') {
        if (req.status !== 'in_review') return json({ skipped: true, reason: 'status_mismatch' });
        const approvals = await loadApprovals(env, base, requestId);
        const r1 = await notifyResult(env, base, req, deptLabel, 'submitted', origin, '');
        const r2 = await notifyPending(env, base, req, deptLabel, approvals, origin);
        res = mergeResults(r1, r2);
      } else if (event === 'stage') {
        if (req.status !== 'in_review') return json({ skipped: true, reason: 'status_mismatch' });
        const approvals = await loadApprovals(env, base, requestId);
        res = await notifyPending(env, base, req, deptLabel, approvals, origin);
      } else if (event === 'approved') {
        if (req.status !== 'pricing') return json({ skipped: true, reason: 'status_mismatch' });
        const r1 = await notifyResult(env, base, req, deptLabel, 'approved', origin, comment);
        const r2 = await notifyProcurement(env, base, req, deptLabel, origin);
        res = mergeResults(r1, r2);
      } else if (event === 'rejected' || event === 'returned') {
        if (req.status !== event) return json({ skipped: true, reason: 'status_mismatch' });
        res = await notifyResult(env, base, req, deptLabel, event, origin, comment);
      } else {
        return json({ error: 'حدث غير معروف' }, 400);
      }
    } else if (kind === 'award') {
      if (event === 'pending') {
        if (req.status !== 'award_review') return json({ skipped: true, reason: 'status_mismatch' });
        const approvals = await loadAwardApprovals(env, base, requestId);
        const stage = currentPendingStage(approvals);
        const recips = await resolveAwardStageApprovers(env, base, req, stage);
        res = await notifyInfo(env, base, req, deptLabel, 'award_pending', origin, recips, stage ? `المرحلة: ${stage.stage_label || ''}` : '');
      } else if (event === 'approved') {
        if (req.status !== 'awarded') return json({ skipped: true, reason: 'status_mismatch' });
        res = await notifyResult(env, base, req, deptLabel, 'award_approved', origin, comment);
      } else if (event === 'rejected') {
        if (req.status !== 'pricing') return json({ skipped: true, reason: 'status_mismatch' });
        res = await notifyResult(env, base, req, deptLabel, 'award_rejected', origin, comment);
      } else {
        return json({ error: 'حدث غير معروف' }, 400);
      }
    } else if (kind === 'payment') {
      if (event === 'pending') {
        if (req.status !== 'payment_pending') return json({ skipped: true, reason: 'status_mismatch' });
        const recips = await resolveAwardStageApprovers(env, base, req, { role_key: 'can_disburse' });
        res = await notifyInfo(env, base, req, deptLabel, 'payment_pending', origin, recips);
      } else if (event === 'disbursed') {
        if (req.status !== 'receipt_pending') return json({ skipped: true, reason: 'status_mismatch' });
        res = await notifyResult(env, base, req, deptLabel, 'disbursed', origin, comment);
      } else {
        return json({ error: 'حدث غير معروف' }, 400);
      }
    } else if (kind === 'receipt') {
      if (event === 'recorded') {
        if (req.status !== 'receipt_pending') return json({ skipped: true, reason: 'status_mismatch' });
        res = await notifyInfo(env, base, req, deptLabel, 'receipt_recorded', origin, [req.requester], comment);
      } else if (event === 'closed') {
        if (req.status !== 'closed') return json({ skipped: true, reason: 'status_mismatch' });
        res = await notifyResult(env, base, req, deptLabel, 'closed', origin, comment);
      } else {
        return json({ error: 'حدث غير معروف' }, 400);
      }
    } else {
      return json({ error: 'kind غير معروف' }, 400);
    }

    if (res && res.error) { console.warn('[portal-notify] resend error:', res.detail || ''); return json({ error: 'تعذّر إرسال البريد' }, 502); }
    if (res && res.skipped) return json({ skipped: true, reason: res.reason });
    return json({ ok: true, sent: (res && res.sent) || 0 });
  } catch (e) {
    return json({ error: 'تعذّر إرسال البريد' }, 502);
  }
}

function mergeResults(a, b) {
  const err = (a && a.error) || (b && b.error);
  if (err) return { error: true, detail: (a && a.detail) || (b && b.detail) || '' };
  return { ok: true, sent: ((a && a.sent) || 0) + ((b && b.sent) || 0) };
}

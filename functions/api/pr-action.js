/**
 * Cloudflare Pages Function — اتخاذ قرار اعتماد طلب شراء من داخل البريد.
 * ════════════════════════════════════════════════════════════════════════
 *  GET  /api/pr-action?token=…&do=approve|return|reject
 *       يعرض صفحة تأكيد بشرية فقط (لا ينفّذ شيئاً) — كي لا تُنفّذ معاينة عميل
 *       البريد القرارَ تلقائياً عبر جلب الرابط مسبقاً.
 *  POST /api/pr-action   (token, do, comment)
 *       يتحقّق من الرمز (موجود/غير مستخدَم/غير منتهٍ + مطابقة المرحلة المعلّقة)
 *       ثم ينفّذ الانتقال بصلاحية الخادم، يُبطل الرمز، ويرسل بريد المتابعة.
 *
 *  تحصين: لا يقبل أي هوية/عنوان من العميل؛ المعتمِد مُضمَّن في الرمز نفسه.
 *  حتى لو سُرّب الرمز، أقصى ضرر = قرار واحد على مرحلة واحدة لطلب واحد، يُبطَل فوراً.
 * ════════════════════════════════════════════════════════════════════════
 */
import {
  BRAND, esc, loadPR, loadApprovals, currentPendingStage,
  applyAction, readToken, notifyPending, notifyResult,
} from './_pr-shared.js';

const emailConfigured = (env) =>
  !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY && env.RESEND_API_KEY && env.NOTIFY_FROM);

const ACTIONS = { approve: ['اعتماد الطلب', '#16a34a', '✓'], return: ['إرجاع الطلب للتعديل', '#2563eb', '↩'], reject: ['رفض الطلب', '#dc2626', '✕'] };

function page(title, bodyHtml, accent) {
  const B = BRAND; const a = accent || B.navy;
  return `<!DOCTYPE html><html dir="rtl" lang="ar"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title>
<style>
  body{margin:0;background:${B.wash};font-family:'Segoe UI',Tahoma,Arial,sans-serif;color:${B.ink};min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
  .card{background:#fff;max-width:480px;width:100%;border-radius:18px;overflow:hidden;box-shadow:0 14px 50px -18px rgba(11,27,54,.4)}
  .hd{background:linear-gradient(135deg,${B.navy},#16315c);padding:22px 28px;text-align:center}
  .hd .br{color:#E9D9B4;font-size:11px;letter-spacing:.08em;text-transform:uppercase}
  .hd .t{color:#fff;font-size:18px;font-weight:800;margin-top:8px}
  .bar{height:3px;background:${B.gold}}
  .bd{padding:24px 28px;text-align:center}
  .ic{width:62px;height:62px;border-radius:50%;background:${a};color:#fff;font-size:30px;line-height:62px;margin:4px auto 14px;font-weight:700}
  h1{font-size:20px;color:${a};margin:0 0 6px}
  p{font-size:14.5px;line-height:1.9;color:${B.ink};margin:8px 0}
  .meta{background:${B.wash};border:1px solid ${B.line};border-radius:12px;padding:12px 16px;margin:14px 0;font-size:13px;color:${B.soft}}
  .meta b{color:${B.navy}}
  textarea{width:100%;box-sizing:border-box;border:1px solid ${B.line};border-radius:12px;padding:12px;font:inherit;font-size:14px;resize:vertical;min-height:84px;margin:6px 0}
  .btn{display:block;width:100%;box-sizing:border-box;border:0;border-radius:12px;padding:15px;color:#fff;font-weight:800;font-size:15px;cursor:pointer;text-decoration:none;margin:10px 0 0}
  .muted{color:${B.soft};font-size:12px;margin-top:14px}
  .ft{background:${B.navy};padding:14px;text-align:center;color:#fff;opacity:.85;font-size:11px}
</style></head>
<body><div class="card">
  <div class="hd"><div class="br">AL-DEYABI GROUP · مجموعة الذيابي</div><div class="t">بوابة طلبات الشراء</div></div>
  <div class="bar"></div>
  <div class="bd">${bodyHtml}</div>
  <div class="ft">رسالة آلية — مجموعة الذيابي</div>
</div></body></html>`;
}
function htmlResp(html, status = 200) {
  return new Response(html, { status, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Robots-Tag': 'noindex, nofollow' } });
}
function errPage(msg, status = 400) {
  return htmlResp(page('تعذّر إتمام الطلب', `<div class="ic" style="background:#9aa3b2">!</div><h1 style="color:#475569">تعذّر إتمام الطلب</h1><p>${esc(msg)}</p><p class="muted">قد يكون الرمز مُستخدَماً أو منتهياً، أو اتُّخذ القرار مسبقاً. يمكنك فتح البوابة لمتابعة الطلب.</p>`, '#475569'), status);
}

// ── GET: صفحة تأكيد فقط (لا تنفيذ) ──
export async function onRequestGet({ request, env }) {
  if (!emailConfigured(env)) return errPage('الخدمة غير مهيأة حالياً.', 503);
  const url = new URL(request.url);
  const token = url.searchParams.get('token') || '';
  const act = (url.searchParams.get('do') || '').toLowerCase();
  if (!ACTIONS[act]) return errPage('إجراء غير معروف.', 400);
  const base = env.SUPABASE_URL;
  const tk = await readToken(env, base, token);
  if (tk.error) return errPage(tk.error, tk.code || 400);
  const pr = await loadPR(env, base, tk.row.pr_id);
  if (!pr) return errPage('الطلب غير موجود.', 404);
  if (pr.status !== 'in_review') return errPage('لم يعد هذا الطلب قيد المراجعة.', 409);
  const approvals = await loadApprovals(env, base, pr.id);
  const stage = currentPendingStage(approvals);
  if (!stage || stage.seq !== tk.row.seq) return errPage('هذه المرحلة لم تعد بانتظار قرارك.', 409);

  const A = ACTIONS[act];
  const needComment = (act === 'reject' || act === 'return');
  const meta = `<div class="meta">رقم الطلب: <b dir="ltr">${esc(pr.id)}</b><br>${esc(pr.title || 'طلب شراء')} · القسم: ${esc(pr.department || '—')}${pr.requester_name ? '<br>الطالب: ' + esc(pr.requester_name) : ''}</div>`;
  const commentField = needComment
    ? `<label style="display:block;text-align:right;font-size:13px;color:${BRAND.soft};margin-top:6px">السبب (مطلوب):</label><textarea name="comment" required placeholder="${act === 'reject' ? 'سبب الرفض…' : 'ما المطلوب تعديله؟'}"></textarea>`
    : '';
  const body = `
    <div class="ic" style="background:${A[1]}">${A[2]}</div>
    <h1 style="color:${A[1]}">تأكيد ${esc(A[0])}</h1>
    <p>أنت على وشك <b>${esc(A[0])}</b>. يرجى التأكيد لإتمام القرار.</p>
    ${meta}
    <form method="POST" action="/api/pr-action">
      <input type="hidden" name="token" value="${esc(token)}">
      <input type="hidden" name="do" value="${esc(act)}">
      ${commentField}
      <button class="btn" type="submit" style="background:${A[1]}">تأكيد ${esc(A[0])}</button>
    </form>
    <p class="muted">هذا الإجراء صالح لمرة واحدة فقط.</p>`;
  return htmlResp(page('تأكيد القرار', body, A[1]));
}

// ── POST: تنفيذ القرار ──
export async function onRequestPost({ request, env }) {
  if (!emailConfigured(env)) return errPage('الخدمة غير مهيأة حالياً.', 503);
  const base = env.SUPABASE_URL;
  let token = '', act = '', comment = '';
  try {
    const ct = request.headers.get('content-type') || '';
    if (ct.includes('application/json')) {
      const j = await request.json();
      token = String(j.token || ''); act = String(j.do || '').toLowerCase(); comment = String(j.comment || '');
    } else {
      const f = await request.formData();
      token = String(f.get('token') || ''); act = String(f.get('do') || '').toLowerCase(); comment = String(f.get('comment') || '');
    }
  } catch (_) { return errPage('طلب غير صالح.', 400); }
  if (!ACTIONS[act]) return errPage('إجراء غير معروف.', 400);

  const tk = await readToken(env, base, token);
  if (tk.error) return errPage(tk.error, tk.code || 400);

  const result = await applyAction(env, base, tk.row, act, comment);
  if (result.error) return errPage(result.error, result.code || 400);

  // بريد المتابعة (أفضل جهد — لا يُفشل القرار إن تعذّر).
  let origin = ''; try { origin = url0(request); } catch (_) {}
  try {
    if (result.action === 'approve' && !result.finalized) {
      const approvals = await loadApprovals(env, base, result.pr.id);
      await notifyPending(env, base, result.pr, approvals, origin);
    } else if (result.finalized) {
      const ev = result.status === 'approved' ? 'approved' : result.status === 'rejected' ? 'rejected' : 'returned';
      await notifyResult(env, base, result.pr, ev, origin, comment);
    }
  } catch (_) {}

  const A = ACTIONS[act];
  const done = result.action === 'approve'
    ? (result.finalized ? 'تم اعتماد الطلب نهائياً عبر كامل سلسلة الموافقات.' : 'تم اعتماد مرحلتك، وأُرسل الطلب إلى المعتمِد التالي.')
    : result.action === 'reject' ? 'تم رفض الطلب وإشعار مُقدّمه.' : 'أُعيد الطلب لمُقدّمه للتعديل.';
  const body = `
    <div class="ic" style="background:${A[1]}">${A[2]}</div>
    <h1 style="color:${A[1]}">تم تنفيذ القرار</h1>
    <p>${esc(done)}</p>
    <div class="meta">رقم الطلب: <b dir="ltr">${esc(result.pr.id)}</b></div>
    <p class="muted">تم تسجيل قرارك في سجل التدقيق. يمكنك إغلاق هذه الصفحة.</p>`;
  return htmlResp(page('تم تنفيذ القرار', body, A[1]));
}

function url0(request) {
  const src = request.headers.get('origin') || request.headers.get('referer') || request.url;
  return new URL(src).origin;
}

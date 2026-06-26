/**
 * وحدة مشتركة لبوابة طلبات الشراء — الإشعارات والاعتماد من داخل البريد.
 * ════════════════════════════════════════════════════════════════════════
 * تحصين أمني (نطاق ضرر محصور):
 *  • رموز الاعتماد عشوائية 256-بت، لمرة واحدة، وبصلاحية زمنية قصيرة.
 *  • تُخزَّن في proc_email_tokens (RLS بلا سياسة) ⇒ لا يقرأها/يكتبها أي عميل،
 *    الخادم فقط (service-role) — فحتى لو سُرّب رمز لا يُكشف الجدول ولا يُزوَّر.
 *  • كل رمز يخصّ (طلب + مرحلة + معتمِد) واحداً فقط؛ لا يمنح أي صلاحية على
 *    القاعدة أو النظام الأساسي، ويُبطَل فور الاستخدام.
 *  • فصل المهام: لا يُنشأ رمز لمُقدّم الطلب نفسه.
 *  • طلب GET لا ينفّذ أي تغيير (يمنع التنفيذ التلقائي من معاينة عميل البريد)؛
 *    التنفيذ عبر POST فقط بعد تأكيد بشري.
 * ════════════════════════════════════════════════════════════════════════
 */

export const BRAND = { navy: '#0B1B36', gold: '#B8923D', ink: '#1f2937', soft: '#6b7280', line: '#e6e8ee', wash: '#f6f4ee' };

export function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// خريطة بريد↔مستخدم (تطابق notify.js / admin-users.js / index.html)
export const AUTH_EMAIL_MAP = { abdullah: 'abdullah@aldeyabi.com', mostafa: 'supply@aldeyabi.com', mahmoud: 'mahmoud@aldeyabi.com' };

// النطاق الموثّق للإرسال في Resend (Verified sending domain). يجب أن يكون عنوان
// المُرسِل من هذا النطاق وإلا يرفض Resend الإرسال.
export const SENDER_DOMAIN = 'suppliers.aldeyabi.com';
// الاسم الظاهر للمستقبِل = النطاق الموثّق نفسه «suppliers.aldeyabi.com». العنوان خلفه
// إلزامي تقنياً (لا يمكن إرسال بريد بنطاق فقط) وهو على نفس النطاق الموثّق.
export const DEFAULT_FROM = `suppliers.aldeyabi.com <suppliers@${SENDER_DOMAIN}>`;
// عنوان ردّ حقيقي يستقبل الرسائل (نطاق الإرسال subdomain قد لا يستقبل) — يرفع ثقة صندوق الوارد.
export const DEFAULT_REPLY_TO = 'supply@aldeyabi.com';
// عنوان المُرسِل: نستخدم NOTIFY_FROM فقط إذا كان من النطاق الموثّق؛ وإلا الافتراضي الصحيح
// (يضمن الإرسال حتى لو بقي NOTIFY_FROM على النطاق القديم @aldeyabi.com أو فارغاً).
export function fromAddress(env) {
  const f = String((env && env.NOTIFY_FROM) || '').trim();
  return f.toLowerCase().includes('@' + SENDER_DOMAIN) ? f : DEFAULT_FROM;
}
// عنوان الردّ: قيمة البيئة إن وُجدت، وإلا بريد حقيقي افتراضي (لا نترك الرسالة بلا Reply-To).
export function replyTo(env) {
  const r = String((env && env.NOTIFY_REPLY_TO) || '').trim();
  return r || DEFAULT_REPLY_TO;
}

// النطاق العام الثابت لروابط البريد: إن ضُبط env.PUBLIC_ORIGIN استُخدم دائماً (مثل
// https://portal.aldeyabi.com) لتطابق روابط البريد مع نطاق الإرسال وتقليل السبام؛
// وإلا يُستخدم أصل الطلب الفعلي (توافق خلفي — لا تغيير سلوك إن لم يُضبط).
export function publicOrigin(env, fallbackOrigin) {
  const o = String((env && env.PUBLIC_ORIGIN) || '').trim().replace(/\/+$/, '');
  return /^https?:\/\//i.test(o) ? o : (fallbackOrigin || '');
}

// نسخة نصّية (text/plain) من قالب HTML — لإرسال multipart/alternative.
// غياب النسخة النصّية إشارة سبام معروفة (MIME_HTML_ONLY)؛ وجودها يرفع الوصول للوارد.
export function htmlToText(html) {
  return String(html || '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<head[\s\S]*?<\/head>/gi, '')
    .replace(/<a\b[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, (m, href, txt) => {
      const t = txt.replace(/<[^>]+>/g, '').trim();
      const u = String(href).replace(/&amp;/g, '&');
      return t && !/^https?:/i.test(t) ? `${t}: ${u}` : u;
    })
    .replace(/<(?:br|\/p|\/div|\/tr|\/h[1-6]|\/li)\s*>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/[ \t]+/g, ' ')
    .replace(/ *\n */g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

export const emailToUsername = (email) => {
  const e = String(email || '').toLowerCase();
  for (const [u, m] of Object.entries(AUTH_EMAIL_MAP)) { if (m.toLowerCase() === e) return u; }
  return e.split('@')[0];
};
export const usernameToEmail = (u) => {
  const k = String(u || '').trim().toLowerCase();
  return AUTH_EMAIL_MAP[k] || (k + '@aldeyabi.com');
};

export const svcHeaders = (env) => ({
  apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
  'Content-Type': 'application/json',
});

// رمز عشوائي ~256-بت بترميز base62 (يُولّد على الخادم فقط).
// عيّنة-رفض (نتجاهل البايتات ≥ 248) لإزالة انحياز القسمة تماماً؛ 43 رمزاً ≈ 256 بت.
export function genToken() {
  const A = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  const out = [];
  const buf = new Uint8Array(64);
  while (out.length < 43) {
    crypto.getRandomValues(buf);
    for (let i = 0; i < buf.length && out.length < 43; i++) {
      if (buf[i] < 248) out.push(A[buf[i] % 62]);
    }
  }
  return out.join('');
}

// مدّة صلاحية الرمز (افتراضي 7 أيام) — قابلة للضبط عبر env.PR_TOKEN_TTL_HOURS.
function tokenTtlMs(env) {
  const h = Number(env && env.PR_TOKEN_TTL_HOURS);
  return (Number.isFinite(h) && h > 0 ? h : 168) * 3600 * 1000;
}

// ── قراءة بيانات الطلب وسلسلة اعتماده (بصلاحية الخادم) ──
export async function loadPR(env, base, prId) {
  const cols = 'id,title,department,department_id,requester,requester_name,status,current_seq,est_total';
  const r = await fetch(`${base}/rest/v1/proc_purchase_requests?id=eq.${encodeURIComponent(prId)}&select=${cols}`, { headers: svcHeaders(env) });
  if (!r.ok) return null;
  const rows = await r.json();
  return Array.isArray(rows) ? rows[0] || null : null;
}
export async function loadApprovals(env, base, prId) {
  const r = await fetch(`${base}/rest/v1/proc_pr_approvals?pr_id=eq.${encodeURIComponent(prId)}&order=seq.asc&select=seq,stage_label,resolver,role_key,approver,decision`, { headers: svcHeaders(env) });
  if (!r.ok) return [];
  const rows = await r.json();
  return Array.isArray(rows) ? rows : [];
}
export function currentPendingStage(approvals) {
  return (approvals || []).filter((a) => a.decision === 'pending').sort((a, b) => (a.seq || 0) - (b.seq || 0))[0] || null;
}

// عند غياب المُعتمِد (is_away) يُوجَّه إلى مفوَّضه (delegate_to).
async function applyDelegation(env, base, names) {
  const out = [];
  for (const n of names) {
    if (!n) continue;
    try {
      const safe = String(n).replace(/[\\%_,]/g, '');
      const r = await fetch(`${base}/rest/v1/proc_users?username=ilike.${encodeURIComponent(safe)}&select=username,is_away,delegate_to`, { headers: svcHeaders(env) });
      const rows = await r.json();
      const u = (rows || []).find((x) => String(x.username).toLowerCase() === String(n).toLowerCase());
      out.push(u && u.is_away && u.delegate_to ? u.delegate_to : n);
    } catch (_) { out.push(n); }
  }
  return [...new Set(out.filter(Boolean))];
}

// ── تحليل معتمِدي مرحلة (قد يكونون أكثر من واحد لقاعدة بصلاحية role) ──
export async function resolveStageApprovers(env, base, pr, stage) {
  if (!stage) return [];
  if (stage.approver) return applyDelegation(env, base, [stage.approver]);
  if (stage.resolver === 'dept_manager' && pr.department_id) {
    try {
      const dr = await fetch(`${base}/rest/v1/proc_departments?id=eq.${encodeURIComponent(pr.department_id)}&select=manager_user`, { headers: svcHeaders(env) });
      const rows = await dr.json();
      if (rows && rows[0] && rows[0].manager_user) return applyDelegation(env, base, [rows[0].manager_user]);
    } catch (_) {}
    return [];
  }
  if (stage.role_key) {
    try {
      const ur = await fetch(`${base}/rest/v1/proc_users?active=eq.true&select=username,role,permissions`, { headers: svcHeaders(env) });
      const users = await ur.json();
      const explicit = (users || []).filter((u) => u.permissions && u.permissions[stage.role_key] === true).map((u) => u.username);
      return explicit.length ? explicit : (users || []).filter((u) => u.role === 'admin').map((u) => u.username);
    } catch (_) {}
  }
  return [];
}

// ── إنشاء رمز اعتماد لمرة واحدة (يُبطل الرموز السابقة غير المستخدَمة لنفس الطلب/المرحلة/المعتمِد) ──
export async function createToken(env, base, prId, seq, approver) {
  const token = genToken();
  const expires = new Date(Date.now() + tokenTtlMs(env)).toISOString();
  // أبطل أي رموز سابقة غير مستخدَمة لنفس (الطلب/المرحلة/المعتمِد) كي لا يعمل رمز قديم.
  try {
    await fetch(`${base}/rest/v1/proc_email_tokens?pr_id=eq.${encodeURIComponent(prId)}&seq=eq.${seq}&approver=eq.${encodeURIComponent(approver)}&used=eq.false`,
      { method: 'PATCH', headers: { ...svcHeaders(env), Prefer: 'return=minimal' }, body: JSON.stringify({ used: true, used_at: new Date().toISOString() }) });
  } catch (_) {}
  const r = await fetch(`${base}/rest/v1/proc_email_tokens`, {
    method: 'POST', headers: { ...svcHeaders(env), Prefer: 'return=minimal' },
    body: JSON.stringify({ token, pr_id: prId, seq, approver, expires_at: expires }),
  });
  if (!r.ok) return null;
  return token;
}

// ── إرسال عبر Resend (قالب ثابت على الخادم، نطاق الشركة فقط) ──
export async function sendResend(env, toList, subject, html) {
  const to = [...new Set((toList || []).filter(Boolean))].filter((e) => /@aldeyabi\.com$/i.test(e));
  if (!to.length) return { skipped: true, reason: 'no_recipient' };
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST', headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: fromAddress(env), to, subject, html, text: htmlToText(html), reply_to: replyTo(env) }),
  });
  if (!r.ok) { const t = await r.text().catch(() => ''); return { error: true, status: r.status, detail: t.slice(0, 300) }; }
  return { ok: true, sent: to.length };
}

/* ════════ قوالب البريد ════════ */
const META = {
  pending:   ['طلب بانتظار اعتمادك', '#d97706', '✎'],
  approved:  ['اعتُمد الطلب نهائياً', '#16a34a', '✓'],
  rejected:  ['تم رفض الطلب', '#dc2626', '✕'],
  returned:  ['أُعيد الطلب للتعديل', '#2563eb', '↩'],
  submitted: ['تم استلام طلبك', '#2563eb', '⏳'],
};
const LINES = (title) => ({
  pending:   `لديك طلب شراء بانتظار اعتمادك ضمن سلسلة الموافقات. يمكنك اتخاذ القرار مباشرةً من هذا البريد، أو فتح البوابة لمراجعة كامل التفاصيل.`,
  approved:  `تم اعتماد طلبك «${title}» نهائياً عبر كامل سلسلة الموافقات، وسيُحوَّل إلى المشتريات لبدء عروض الأسعار والتوريد.`,
  rejected:  `نأسف لإبلاغك بأن طلبك «${title}» قد رُفض.`,
  returned:  `أُعيد طلبك «${title}» إليك للتعديل. يرجى مراجعته وتحديث المطلوب ثم إعادة إرساله.`,
  submitted: `تم استلام طلبك «${title}» بنجاح، وبدأ مساره في سلسلة الاعتماد. ستصلك التحديثات تلقائياً.`,
});

function emailShell(inner, heroEvent) {
  const B = BRAND; const m = META[heroEvent] || META.submitted; const heroBg = m[1] + '14';
  return `<!DOCTYPE html><html dir="rtl" lang="ar"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:${B.wash};font-family:'Segoe UI',Tahoma,Arial,sans-serif;color:${B.ink}">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${B.wash};padding:22px 12px"><tr><td align="center">
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#fff;border-radius:18px;overflow:hidden;box-shadow:0 10px 40px -16px rgba(11,27,54,.35)">
      <tr><td style="background:linear-gradient(135deg,${B.navy},#16315c);padding:22px 30px" align="center">
        <div style="color:#E9D9B4;font-size:11.5px;letter-spacing:.08em;text-transform:uppercase">AL-DEYABI GROUP · مجموعة الذيابي</div>
        <div style="color:#fff;font-size:19px;font-weight:800;margin-top:8px">بوابة طلبات الشراء</div>
      </td></tr>
      <tr><td style="height:3px;background:${B.gold}"></td></tr>
      <tr><td style="background:${heroBg};padding:22px 30px" align="center">
        <div style="width:58px;height:58px;border-radius:50%;background:${m[1]};color:#fff;font-size:28px;line-height:58px;margin:0 auto;font-weight:700">${m[2]}</div>
        <div style="font-size:20px;font-weight:800;color:${m[1]};margin-top:10px">${esc(m[0])}</div>
      </td></tr>
      ${inner}
      <tr><td style="background:${B.navy};padding:16px 30px" align="center">
        <div style="color:#fff;font-size:12px;opacity:.9">مجموعة الذيابي · بوابة طلبات الشراء</div>
        <div style="color:#fff;opacity:.5;font-size:10.5px;margin-top:6px">رسالة آلية — لا يلزم الرد</div>
      </td></tr>
    </table>
  </td></tr></table>
</body></html>`;
}

function prMetaBox(pr) {
  const B = BRAND;
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0 6px"><tr>
    <td style="background:${B.wash};border:1px solid ${B.line};border-radius:12px;padding:12px 16px" align="center">
      <span style="font-size:12px;color:${B.soft}">رقم الطلب</span><br>
      <span dir="ltr" style="font-size:17px;font-weight:800;color:${B.navy};letter-spacing:.05em">${esc(pr.id)}</span>
      <div style="font-size:12px;color:${B.soft};margin-top:6px">${esc(pr.title || 'طلب شراء')} · القسم: ${esc(pr.department || '—')}${pr.requester_name ? ' · الطالب: ' + esc(pr.requester_name) : ''}</div>
    </td></tr></table>`;
}

// بريد «بانتظار اعتمادك» مع أزرار اتخاذ القرار من داخل البريد (لكل معتمِد رمزه الخاص).
export function buildActionEmail(pr, origin, actionBase, stageLabel) {
  const B = BRAND; const title = pr.title || 'طلب شراء';
  const portalUrl = origin ? `${origin}/requests.html` : '';
  const approveUrl = `${actionBase}&do=approve`;
  const returnUrl = `${actionBase}&do=return`;
  const rejectUrl = `${actionBase}&do=reject`;
  const stageNote = stageLabel ? `<div style="font-size:12.5px;color:${B.soft};margin:2px 0 10px">مرحلتك: <b style="color:${B.navy}">${esc(stageLabel)}</b></div>` : '';
  const actions = origin ? `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:8px 0 4px"><tr>
      <td align="center" bgcolor="#16a34a" style="background:#16a34a;border-radius:12px"><a href="${esc(approveUrl)}" style="display:block;padding:14px 18px;color:#fff;text-decoration:none;font-weight:800;font-size:15px">✓ اعتماد الطلب</a></td>
    </tr></table>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:8px 0 4px"><tr>
      <td width="49%" align="center" bgcolor="#2563eb" style="background:#2563eb;border-radius:12px"><a href="${esc(returnUrl)}" style="display:block;padding:12px 14px;color:#fff;text-decoration:none;font-weight:700;font-size:14px">↩ إرجاع للتعديل</a></td>
      <td width="2%"></td>
      <td width="49%" align="center" bgcolor="#dc2626" style="background:#dc2626;border-radius:12px"><a href="${esc(rejectUrl)}" style="display:block;padding:12px 14px;color:#fff;text-decoration:none;font-weight:700;font-size:14px">✕ رفض</a></td>
    </tr></table>` : '';
  const portalBtn = portalUrl ? `<p style="text-align:center;margin:12px 0 0"><a href="${esc(portalUrl)}" style="color:${B.navy};font-size:13px;font-weight:700;text-decoration:underline">فتح البوابة لمراجعة كامل التفاصيل</a></p>` : '';
  const inner = `<tr><td dir="rtl" style="padding:24px 30px 8px;text-align:right">
    <p style="font-size:14.5px;line-height:1.95;margin:6px 0;color:${B.ink}">${esc(LINES(title).pending)}</p>
    ${stageNote}
    ${prMetaBox(pr)}
    ${actions}
    ${portalBtn}
    <p style="font-size:11px;color:${B.soft};text-align:center;line-height:1.7;margin:14px 0 0">أزرار القرار صالحة لمرة واحدة ولفترة محدودة. لا تُعِد توجيه هذه الرسالة.</p>
  </td></tr>`;
  return emailShell(inner, 'pending');
}

// بريد نتيجة (للطالب): approved | rejected | returned | submitted.
export function buildResultEmail(event, pr, origin, comment) {
  const B = BRAND; const title = pr.title || 'طلب شراء';
  const portalUrl = origin ? `${origin}/requests.html` : '';
  const cmt = comment ? `<div dir="rtl" style="text-align:right;background:${B.wash};border:1px solid ${B.line};border-right:4px solid ${(META[event] || META.submitted)[1]};border-radius:12px;padding:12px 16px;margin:14px 0;font-size:13.5px;color:${B.ink}"><b>ملاحظة:</b> ${esc(comment)}</div>` : '';
  const btn = portalUrl ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0 4px"><tr><td align="center" bgcolor="${B.gold}" style="background:${B.gold};border-radius:12px"><a href="${esc(portalUrl)}" style="display:block;padding:15px 18px;color:#fff;text-decoration:none;font-weight:800;font-size:15px">فتح بوابة الطلبات</a></td></tr></table>` : '';
  const inner = `<tr><td dir="rtl" style="padding:24px 30px 8px;text-align:right">
    <p style="font-size:14.5px;line-height:1.95;margin:6px 0;color:${B.ink}">${esc((LINES(title)[event]) || LINES(title).submitted)}</p>
    ${cmt}${btn}
    ${prMetaBox(pr)}
  </td></tr>`;
  return emailShell(inner, event);
}

export function subjectFor(event, pr) {
  const m = META[event] || META.submitted;
  return `${m[0]} — طلب ${pr.id} | مجموعة الذيابي`;
}

/**
 * إشعار المرحلة الحالية: لكل معتمِد مُحلّ أنشئ رمزاً خاصاً وأرسل بريد قرار.
 * يتطلّب أصل الموقع (origin) لبناء روابط الإجراء؛ بدونه يُرسَل بريد بلا أزرار.
 */
export async function notifyPending(env, base, pr, approvals, origin) {
  const stage = currentPendingStage(approvals);
  if (!stage) return { skipped: true, reason: 'no_pending_stage' };
  let approvers = await resolveStageApprovers(env, base, pr, stage);
  // فصل المهام: لا تُرسل رمز اعتماد لمُقدّم الطلب نفسه.
  approvers = [...new Set(approvers.filter((u) => u && u !== pr.requester))];
  if (!approvers.length) return { skipped: true, reason: 'no_approver' };
  let sent = 0, failed = 0, lastDetail = '';
  for (const uname of approvers) {
    const email = await userEmail(env, base, uname);
    if (!/@aldeyabi\.com$/i.test(email)) continue;
    let html;
    if (origin) {
      const token = await createToken(env, base, pr.id, stage.seq, uname);
      if (!token) { failed++; continue; }
      const actionBase = `${origin}/api/pr-action?token=${encodeURIComponent(token)}`;
      html = buildActionEmail(pr, origin, actionBase, stage.stage_label);
    } else {
      html = buildActionEmail(pr, '', '', stage.stage_label);
    }
    const res = await sendResend(env, [email], subjectFor('pending', pr), html);
    if (res && res.ok) sent += res.sent;
    else if (res && res.error) { failed++; lastDetail = res.detail || ''; }
  }
  // إن فشلت كل المحاولات ولم يُرسَل أيّ بريد للمعتمِدين: أبلغ بالخطأ بدل ادّعاء النجاح
  // (حتى لا يبقى الطلب عالقاً بصمت بانتظار اعتماد لم يصل بريده).
  if (sent === 0 && failed > 0) return { error: true, detail: lastDetail || 'all_sends_failed' };
  return { ok: true, sent };
}

// بريد المستخدم: يفضّل البريد الحقيقي المخزَّن في proc_users.email على الاشتقاق من الاسم.
export async function userEmail(env, base, username) {
  if (!username) return '';
  try {
    const r = await fetch(`${base}/rest/v1/proc_users?username=eq.${encodeURIComponent(username)}&select=email`, { headers: svcHeaders(env) });
    const rows = await r.json();
    const e = rows && rows[0] && rows[0].email ? String(rows[0].email).trim() : '';
    if (e && /@aldeyabi\.com$/i.test(e)) return e.toLowerCase();
  } catch (_) {}
  return usernameToEmail(username);
}

// إشعار نتيجة لمُقدّم الطلب.
export async function notifyResult(env, base, pr, event, origin, comment) {
  const email = await userEmail(env, base, pr.requester);
  const html = buildResultEmail(event, pr, origin, comment);
  return sendResend(env, [email], subjectFor(event, pr), html);
}

// بريد المشتريات عند الاعتماد النهائي — طلب جاهز للمعالجة (توريد/تسعير داخل النظام أو خارجه).
export function buildProcurementEmail(pr, origin) {
  const B = BRAND;
  const portalUrl = origin ? `${origin}/requests.html` : '';
  const btn = portalUrl ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0 4px"><tr><td align="center" bgcolor="${B.gold}" style="background:${B.gold};border-radius:12px"><a href="${esc(portalUrl)}" style="display:block;padding:15px 18px;color:#fff;text-decoration:none;font-weight:800;font-size:15px">فتح بوابة الطلبات</a></td></tr></table>` : '';
  const inner = `<tr><td dir="rtl" style="padding:24px 30px 8px;text-align:right">
    <p style="font-size:14.5px;line-height:1.95;margin:6px 0;color:${B.ink}">اعتُمد طلب الشراء «${esc(pr.title || 'طلب شراء')}» نهائياً عبر كامل سلسلة الموافقات، وهو الآن <b>جاهز لمعالجة المشتريات</b> (عروض أسعار / توريد). راجع التفاصيل والبنود في البوابة.</p>
    ${btn}
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0 6px"><tr>
      <td style="background:${B.wash};border:1px solid ${B.line};border-radius:12px;padding:12px 16px" align="center">
        <span style="font-size:12px;color:${B.soft}">رقم الطلب</span><br>
        <span dir="ltr" style="font-size:17px;font-weight:800;color:${B.navy};letter-spacing:.05em">${esc(pr.id)}</span>
        <div style="font-size:12px;color:${B.soft};margin-top:6px">القسم: ${esc(pr.department || '—')}${pr.requester_name ? ' · الطالب: ' + esc(pr.requester_name) : ''}</div>
      </td></tr></table>
  </td></tr>`;
  return emailShell(inner, 'approved');
}

// إشعار فريق المشتريات (أصحاب صلاحية can_manage_rfq، وإلا الأدمن) عند الاعتماد النهائي.
export async function notifyProcurement(env, base, pr, origin) {
  let recips = [];
  try {
    const ur = await fetch(`${base}/rest/v1/proc_users?active=eq.true&select=username,role,permissions,email`, { headers: svcHeaders(env) });
    const users = await ur.json();
    let pick = (users || []).filter((u) => u.permissions && u.permissions.can_manage_rfq === true);
    if (!pick.length) pick = (users || []).filter((u) => u.role === 'admin');
    // البريد الحقيقي المخزَّن إن وُجد، وإلا الاشتقاق.
    recips = pick.filter((u) => u.username !== pr.requester)
      .map((u) => (u.email && /@aldeyabi\.com$/i.test(u.email)) ? String(u.email).toLowerCase() : usernameToEmail(u.username));
  } catch (_) {}
  const toList = [...new Set(recips)];
  if (!toList.length) return { skipped: true, reason: 'no_procurement' };
  const html = buildProcurementEmail(pr, origin);
  return sendResend(env, toList, `طلب معتمد جاهز للمشتريات — طلب ${pr.id} | مجموعة الذيابي`, html);
}

// ملاحظة: تنفيذ قرار البريد انتقل بالكامل إلى دالة قاعدة البيانات pr_transition_email
// (معاملة ذرّية واحدة: استهلاك الرمز + إعادة التحقّق من المعتمِد + الانتقال). لم يعد
// هناك مسار كتابة يدوي بصلاحية الخادم — استدعاؤها في functions/api/pr-action.js.

// قراءة رمز (بصلاحية الخادم) مع التحقّق من الصلاحية الزمنية والاستخدام (للعرض في صفحة GET فقط).
export async function readToken(env, base, token) {
  if (!token || !/^[0-9A-Za-z]{16,128}$/.test(token)) return { error: 'رمز غير صالح', code: 400 };
  const r = await fetch(`${base}/rest/v1/proc_email_tokens?token=eq.${encodeURIComponent(token)}&select=token,pr_id,seq,approver,used,used_at,expires_at`, { headers: svcHeaders(env) });
  if (!r.ok) return { error: 'تعذّر التحقّق', code: 502 };
  const rows = await r.json();
  const row = Array.isArray(rows) ? rows[0] : null;
  if (!row) return { error: 'رمز غير معروف', code: 404 };
  if (row.used) return { error: 'استُخدم هذا الرمز من قبل', code: 410 };
  if (new Date(row.expires_at).getTime() < Date.now()) return { error: 'انتهت صلاحية الرمز', code: 410 };
  return { ok: true, row };
}

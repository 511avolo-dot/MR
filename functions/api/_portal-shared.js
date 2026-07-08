/**
 * وحدة مشتركة لبوابة الطلبات المستقلة (portal_*) — الإشعارات والاعتماد من داخل البريد.
 * ════════════════════════════════════════════════════════════════════════
 * معزولة تماماً عن _pr-shared.js (خاصة بـ requests.html/proc_*): لا تستورد
 * منها ولا تُستورَد فيها، ولا تلمس أي جدول أو دالة تبدأ بـ proc_ أو pr_.
 *
 * تحصين أمني (نفس معايير _pr-shared.js المُثبَتة):
 *  • رموز الاعتماد عشوائية 256-بت (portal_gen_token)، لمرة واحدة، صلاحية زمنية قصيرة.
 *  • تُخزَّن في portal_email_tokens (RLS بلا سياسة) ⇒ خادم فقط.
 *  • كل رمز يخصّ (طلب + مرحلة + معتمِد) واحداً فقط؛ يُبطَل فور الاستخدام.
 *  • فصل المهام: لا يُنشأ رمز لمُقدّم الطلب نفسه.
 *  • GET لا ينفّذ شيئاً (صفحة تأكيد فقط) — التنفيذ عبر POST بعد تأكيد بشري.
 *  • أزرار القرار من داخل البريد مبنية فقط لمرحلة الاعتماد الأولى (الحاجة)، لأنها
 *    الوحيدة التي لها RPC ذرّي مُختبَر بالكامل (portal_pr_transition_email). بقية
 *    الأحداث (تعميد/صرف/استلام) تصلها رسائل إعلامية فقط بزر فتح البوابة، تفادياً
 *    لبناء مسارات رموز جديدة غير مُختبَرة بنفس الصرامة.
 * ════════════════════════════════════════════════════════════════════════
 */

// اللوحة الباردة — موحّدة مع واجهة البوابة (purchase-portal.html): كحلي #16243d،
// ذهبي #c2a063، خلفية #f2f4f8، حدود #e2e7ef، سطح ثانوي #f7f9fc.
export const BRAND = { navy: '#16243d', gold: '#c2a063', ink: '#1f2937', soft: '#5d6b80', line: '#e2e7ef', wash: '#f2f4f8', surface: '#f7f9fc' };
// خط أحادي المسافة لأرقام «دفتر القيد» (معرّفات الطلبات) — نفس هوية البوابة.
export const MONO = "'IBM Plex Mono','SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace";

export function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// نفس النطاق الموثّق للإرسال في Resend المستخدَم فعلياً للنظام (مشروع Resend واحد
// للشركة) — القوالب والمحتوى مستقلة بالكامل، فقط المُرسِل التقني مشترك.
export const SENDER_DOMAIN = 'suppliers.aldeyabi.com';
// مُرسِل غير «no-reply» (توصية Resend لتحسين التسليم وتقليل السبام). الردود تذهب إلى
// DEFAULT_REPLY_TO (صندوق حقيقي). أي عنوان @suppliers.aldeyabi.com صالح للإرسال.
export const DEFAULT_FROM = `مجموعة الذيابي — بوابة الطلبات <notifications@${SENDER_DOMAIN}>`;
export const DEFAULT_REPLY_TO = 'supply@aldeyabi.com';
export function fromAddress(env) {
  const f = String((env && env.NOTIFY_FROM) || '').trim();
  // نتجاهل أي إعداد يحوي no-reply/noreply (يضرّ بالتسليم) ونرجع للمُرسِل الجيّد.
  if (f && f.toLowerCase().includes('@' + SENDER_DOMAIN) && !/no-?reply/i.test(f)) return f;
  return DEFAULT_FROM;
}
export function replyTo(env) {
  const r = String((env && env.NOTIFY_REPLY_TO) || '').trim();
  return r || DEFAULT_REPLY_TO;
}
export function publicOrigin(env, fallbackOrigin) {
  const o = String((env && env.PUBLIC_ORIGIN) || '').trim().replace(/\/+$/, '');
  return /^https?:\/\//i.test(o) ? o : (fallbackOrigin || '');
}

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

// مشروع Supabase الخاص بالبوابة — منفصل تماماً عن مشروع النظام القديم.
// يُقرأ من متغيّرات بيئة مستقلة (PORTAL_SUPABASE_*) كي لا تُخلَط أبداً مع
// SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY اللذين يخصّان مشروع index.html القديم.
export const portalUrl = (env) => String((env && env.PORTAL_SUPABASE_URL) || '').replace(/\/+$/, '');
export const portalKey = (env) => String((env && env.PORTAL_SUPABASE_SERVICE_ROLE_KEY) || '');
export const portalConfigured = (env) => !!(portalUrl(env) && portalKey(env));

export const svcHeaders = (env) => ({
  apikey: portalKey(env),
  Authorization: `Bearer ${portalKey(env)}`,
  'Content-Type': 'application/json',
});

// ── قراءة الطلب/الأقسام/سلاسل الاعتماد (بصلاحية الخادم) ──
export async function loadRequest(env, base, id) {
  const cols = 'id,title,department_id,requester,requester_name,status,current_seq,phase,est_total,currency';
  const r = await fetch(`${base}/rest/v1/portal_requests?id=eq.${encodeURIComponent(id)}&select=${cols}`, { headers: svcHeaders(env) });
  if (!r.ok) return null;
  const rows = await r.json();
  return Array.isArray(rows) ? rows[0] || null : null;
}
export async function deptName(env, base, deptId) {
  if (!deptId) return '';
  try {
    const r = await fetch(`${base}/rest/v1/portal_departments?id=eq.${encodeURIComponent(deptId)}&select=name_ar`, { headers: svcHeaders(env) });
    const rows = await r.json();
    return (rows && rows[0] && rows[0].name_ar) || '';
  } catch (_) { return ''; }
}
export async function loadApprovals(env, base, id) {
  const r = await fetch(`${base}/rest/v1/portal_approvals?request_id=eq.${encodeURIComponent(id)}&order=seq.asc&select=seq,stage_label,resolver,role_key,approver,decision`, { headers: svcHeaders(env) });
  if (!r.ok) return [];
  const rows = await r.json();
  return Array.isArray(rows) ? rows : [];
}
export async function loadAwardApprovals(env, base, id) {
  const r = await fetch(`${base}/rest/v1/portal_award_approvals?request_id=eq.${encodeURIComponent(id)}&order=seq.asc&select=seq,stage_label,role_key,approver,decision`, { headers: svcHeaders(env) });
  if (!r.ok) return [];
  const rows = await r.json();
  return Array.isArray(rows) ? rows : [];
}
export function currentPendingStage(approvals) {
  return (approvals || []).filter((a) => a.decision === 'pending').sort((a, b) => (a.seq || 0) - (b.seq || 0))[0] || null;
}

// عند غياب المُعتمِد (is_away) يُوجَّه إلى مفوَّضه (delegate_to) — portal_users فقط.
async function applyDelegation(env, base, names) {
  const out = [];
  for (const n of names) {
    if (!n) continue;
    try {
      const safe = String(n).replace(/[\\%_,]/g, '');
      const r = await fetch(`${base}/rest/v1/portal_users?username=ilike.${encodeURIComponent(safe)}&select=username,is_away,delegate_to`, { headers: svcHeaders(env) });
      const rows = await r.json();
      const u = (rows || []).find((x) => String(x.username).toLowerCase() === String(n).toLowerCase());
      out.push(u && u.is_away && u.delegate_to ? u.delegate_to : n);
    } catch (_) { out.push(n); }
  }
  return [...new Set(out.filter(Boolean))];
}

// ── تحليل معتمِدي مرحلة (دورة الحاجة الأولى) ──
export async function resolveStageApprovers(env, base, req, stage) {
  if (!stage) return [];
  if (stage.approver) return applyDelegation(env, base, [stage.approver]);
  if (stage.resolver === 'dept_manager' && req.department_id) {
    try {
      const dr = await fetch(`${base}/rest/v1/portal_departments?id=eq.${encodeURIComponent(req.department_id)}&select=manager_user`, { headers: svcHeaders(env) });
      const rows = await dr.json();
      if (rows && rows[0] && rows[0].manager_user) return applyDelegation(env, base, [rows[0].manager_user]);
    } catch (_) {}
    return [];
  }
  if (stage.role_key) return resolveByPermission(env, base, stage.role_key, req.requester);
  return [];
}
// ── معتمِدو مرحلة تعميد (دورة الثانية) — دائماً role_key ──
export async function resolveAwardStageApprovers(env, base, req, stage) {
  if (!stage || !stage.role_key) return [];
  return resolveByPermission(env, base, stage.role_key, req.requester);
}
async function resolveByPermission(env, base, roleKey, excludeUsername) {
  try {
    const ur = await fetch(`${base}/rest/v1/portal_users?active=eq.true&select=username,role,permissions`, { headers: svcHeaders(env) });
    const users = await ur.json();
    let pick = (users || []).filter((u) => u.permissions && u.permissions[roleKey] === true);
    if (!pick.length) pick = (users || []).filter((u) => u.role === 'admin');
    return applyDelegation(env, base, pick.filter((u) => u.username !== excludeUsername).map((u) => u.username));
  } catch (_) { return []; }
}

// بريد المستخدم من portal_users.email (المصدر الوحيد للحقيقة — لا اشتقاق).
export async function userEmail(env, base, username) {
  if (!username) return '';
  try {
    const r = await fetch(`${base}/rest/v1/portal_users?username=eq.${encodeURIComponent(username)}&select=email`, { headers: svcHeaders(env) });
    const rows = await r.json();
    const e = rows && rows[0] && rows[0].email ? String(rows[0].email).trim() : '';
    return e ? e.toLowerCase() : '';
  } catch (_) { return ''; }
}

// ── إنشاء رمز اعتماد لمرة واحدة عبر RPC القاعدة (portal_create_token) ──
export async function createToken(env, base, requestId, kind, seq, approver) {
  const r = await fetch(`${base}/rest/v1/rpc/portal_create_token`, {
    method: 'POST', headers: svcHeaders(env),
    body: JSON.stringify({ p_request_id: requestId, p_kind: kind, p_seq: seq, p_approver: approver }),
  });
  if (!r.ok) return null;
  const t = await r.json().catch(() => null);
  return typeof t === 'string' ? t : null;
}

// ── إرسال عبر Resend — لا يقبل إلا بريد نطاق الشركة (لا مُرسِل مفتوح) ──
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
  submitted: ['تم استلام طلبك', '#2563eb', '⏳'],
  pending:   ['طلب بانتظار اعتمادك', '#d97706', '✎'],
  approved:  ['اعتُمد الطلب نهائياً', '#16a34a', '✓'],
  rejected:  ['تم رفض الطلب', '#dc2626', '✕'],
  returned:  ['أُعيد الطلب للتعديل', '#2563eb', '↩'],
  pricing:   ['الطلب جاهز للتسعير', '#2563eb', '💰'],
  award_pending:  ['تعميد بانتظار اعتمادك', '#d97706', '✎'],
  award_approved: ['اعتُمد التعميد — أمر شراء صادر', '#16a34a', '✓'],
  award_rejected: ['رُفض التعميد', '#dc2626', '✕'],
  payment_pending:  ['طلب صرف بانتظار اعتمادك', '#d97706', '✎'],
  payment_approved: ['اعتُمد طلب الصرف', '#16a34a', '✓'],
  disbursed:        ['تم الصرف', '#16a34a', '✓'],
  receipt_recorded: ['تسجيل استلام جديد', '#2563eb', '📦'],
  closed:           ['أُغلق الطلب — اكتمل الاستلام', '#16a34a', '✓'],
};

function emailShell(inner, ev) {
  const B = BRAND; const m = META[ev] || META.submitted; const heroBg = m[1] + '14';
  return `<!DOCTYPE html><html dir="rtl" lang="ar"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:${B.wash};font-family:'Segoe UI',Tahoma,Arial,sans-serif;color:${B.ink}">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${B.wash};padding:22px 12px"><tr><td align="center">
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#fff;border-radius:18px;overflow:hidden;box-shadow:0 10px 40px -16px rgba(11,27,54,.35)">
      <tr><td style="background:linear-gradient(135deg,${B.navy},#22355a);padding:24px 30px" align="center">
        <div style="color:#E9D9B4;font-size:11.5px;letter-spacing:.09em;text-transform:uppercase">AL-DEYABI GROUP · مجموعة الذيابي</div>
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
function reqMetaBox(req, deptLabel) {
  const B = BRAND;
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0 6px"><tr>
    <td style="background:${B.wash};border:1px solid ${B.line};border-radius:12px;padding:12px 16px" align="center">
      <span style="font-size:12px;color:${B.soft}">رقم الطلب</span><br>
      <span dir="ltr" style="font-size:17px;font-weight:700;color:${B.navy};letter-spacing:.04em;font-family:${MONO}">${esc(req.id)}</span>
      <div style="font-size:12px;color:${B.soft};margin-top:6px">${esc(req.title || 'طلب شراء')}${deptLabel ? ' · القسم: ' + esc(deptLabel) : ''}${req.requester_name ? ' · الطالب: ' + esc(req.requester_name) : ''}</div>
    </td></tr></table>`;
}
function portalButton(url, label, color) {
  const B = BRAND;
  return url ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:14px 0 4px"><tr><td align="center" bgcolor="${color || B.gold}" style="background:${color || B.gold};border-radius:12px"><a href="${esc(url)}" style="display:block;padding:15px 18px;color:#fff;text-decoration:none;font-weight:800;font-size:15px">${esc(label)}</a></td></tr></table>` : '';
}

// بريد «بانتظار اعتمادك» (دورة الحاجة) — أزرار قرار موقّعة من داخل البريد.
export function buildActionEmail(req, deptLabel, origin, actionBase, stageLabel) {
  const B = BRAND;
  const portalUrl = origin ? `${origin}/portal` : '';
  const stageNote = stageLabel ? `<div style="font-size:12.5px;color:${B.soft};margin:2px 0 10px">مرحلتك: <b style="color:${B.navy}">${esc(stageLabel)}</b></div>` : '';
  const actions = origin ? `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:8px 0 4px"><tr>
      <td align="center" bgcolor="#16a34a" style="background:#16a34a;border-radius:12px"><a href="${esc(actionBase)}&do=approve" style="display:block;padding:14px 18px;color:#fff;text-decoration:none;font-weight:800;font-size:15px">✓ اعتماد الطلب</a></td>
    </tr></table>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:8px 0 4px"><tr>
      <td width="49%" align="center" bgcolor="#2563eb" style="background:#2563eb;border-radius:12px"><a href="${esc(actionBase)}&do=return" style="display:block;padding:12px 14px;color:#fff;text-decoration:none;font-weight:700;font-size:14px">↩ إرجاع للتعديل</a></td>
      <td width="2%"></td>
      <td width="49%" align="center" bgcolor="#dc2626" style="background:#dc2626;border-radius:12px"><a href="${esc(actionBase)}&do=reject" style="display:block;padding:12px 14px;color:#fff;text-decoration:none;font-weight:700;font-size:14px">✕ رفض</a></td>
    </tr></table>` : '';
  const portalBtn = portalUrl ? `<p style="text-align:center;margin:12px 0 0"><a href="${esc(portalUrl)}" style="color:${B.navy};font-size:13px;font-weight:700;text-decoration:underline">فتح البوابة لمراجعة كامل التفاصيل</a></p>` : '';
  const inner = `<tr><td dir="rtl" style="padding:24px 30px 8px;text-align:right">
    <p style="font-size:14.5px;line-height:1.95;margin:6px 0;color:${B.ink}">لديك طلب شراء بانتظار اعتمادك ضمن سلسلة الموافقات. يمكنك اتخاذ القرار مباشرةً من هذا البريد، أو فتح البوابة لمراجعة كامل التفاصيل.</p>
    ${stageNote}
    ${reqMetaBox(req, deptLabel)}
    ${actions}
    ${portalBtn}
    <p style="font-size:11px;color:${B.soft};text-align:center;line-height:1.7;margin:14px 0 0">أزرار القرار صالحة لمرة واحدة ولفترة محدودة. لا تُعِد توجيه هذه الرسالة.</p>
  </td></tr>`;
  return emailShell(inner, 'pending');
}

// بريد نتيجة (للطالب): submitted | approved | rejected | returned | pricing | award_approved | ... إلخ.
const RESULT_LINES = {
  submitted: (t) => `تم استلام طلبك «${esc(t)}» بنجاح، وبدأ مساره في سلسلة الاعتماد. ستصلك التحديثات تلقائياً.`,
  approved:  (t) => `تم اعتماد طلبك «${esc(t)}» نهائياً عبر كامل سلسلة الموافقات، وسينتقل الآن لمرحلة التسعير.`,
  rejected:  (t) => `نأسف لإبلاغك بأن طلبك «${esc(t)}» قد رُفض.`,
  returned:  (t) => `أُعيد طلبك «${esc(t)}» إليك للتعديل. يرجى مراجعته وتحديث المطلوب ثم إعادة إرساله.`,
  award_approved: (t) => `اعتُمد تعميد الشراء لطلبك «${esc(t)}» وصدر أمر الشراء.`,
  award_rejected: (t) => `رُفض تعميد الشراء لطلبك «${esc(t)}».`,
  disbursed: (t) => `تم صرف مستحقات طلبك «${esc(t)}».`,
  closed:    (t) => `اكتمل استلام كل بنود طلبك «${esc(t)}» وأُغلق الطلب.`,
};
export function buildResultEmail(event, req, deptLabel, origin, comment) {
  const B = BRAND; const title = req.title || 'طلب شراء';
  const portalUrl = origin ? `${origin}/portal` : '';
  const line = (RESULT_LINES[event] || RESULT_LINES.submitted)(title);
  const cmt = comment ? `<div dir="rtl" style="text-align:right;background:${B.wash};border:1px solid ${B.line};border-right:4px solid ${(META[event] || META.submitted)[1]};border-radius:12px;padding:12px 16px;margin:14px 0;font-size:13.5px;color:${B.ink}"><b>ملاحظة:</b> ${esc(comment)}</div>` : '';
  const btn = portalButton(portalUrl, 'فتح بوابة الطلبات', B.gold);
  const inner = `<tr><td dir="rtl" style="padding:24px 30px 8px;text-align:right">
    <p style="font-size:14.5px;line-height:1.95;margin:6px 0;color:${B.ink}">${line}</p>
    ${cmt}${btn}
    ${reqMetaBox(req, deptLabel)}
  </td></tr>`;
  return emailShell(inner, event);
}

// بريد إعلامي عام (بلا أزرار قرار) — لأحداث تعميد/صرف/استلام بانتظار اعتماد أحد.
const PENDING_LINES = {
  award_pending:   'يوجد تعميد شراء بانتظار اعتمادك.',
  payment_pending: 'يوجد طلب صرف بانتظار اعتمادك.',
  receipt_recorded: 'سُجِّل استلام جديد لبنود هذا الطلب.',
};
export function buildInfoEmail(event, req, deptLabel, origin, extra) {
  const B = BRAND;
  const portalUrl = origin ? `${origin}/portal` : '';
  const line = PENDING_LINES[event] || 'تحديث جديد على طلب الشراء.';
  const extraLine = extra ? `<div style="font-size:13px;color:${B.soft};margin-top:6px">${esc(extra)}</div>` : '';
  const btn = portalButton(portalUrl, 'فتح البوابة لاتخاذ الإجراء', B.gold);
  const inner = `<tr><td dir="rtl" style="padding:24px 30px 8px;text-align:right">
    <p style="font-size:14.5px;line-height:1.95;margin:6px 0;color:${B.ink}">${esc(line)}</p>
    ${extraLine}
    ${reqMetaBox(req, deptLabel)}
    ${btn}
  </td></tr>`;
  return emailShell(inner, event);
}

export function subjectFor(event, req) {
  const m = META[event] || META.submitted;
  return `${m[0]} — طلب ${req.id} | مجموعة الذيابي`;
}

/**
 * إشعار المرحلة الحالية لدورة الحاجة الأولى: لكل معتمِد مُحلّ أنشئ رمزاً خاصاً
 * وأرسل بريد قرار (أزرار من داخل البريد).
 */
export async function notifyPending(env, base, req, deptLabel, approvals, origin) {
  const stage = currentPendingStage(approvals);
  if (!stage) return { skipped: true, reason: 'no_pending_stage' };
  let approvers = await resolveStageApprovers(env, base, req, stage);
  approvers = [...new Set(approvers.filter((u) => u && u !== req.requester))];
  if (!approvers.length) return { skipped: true, reason: 'no_approver' };
  let sent = 0, failed = 0, lastDetail = '';
  for (const uname of approvers) {
    const email = await userEmail(env, base, uname);
    if (!/@aldeyabi\.com$/i.test(email)) continue;
    let html;
    if (origin) {
      const token = await createToken(env, base, req.id, 'approval', stage.seq, uname);
      if (!token) { failed++; continue; }
      const actionBase = `${origin}/api/portal-action?token=${encodeURIComponent(token)}`;
      html = buildActionEmail(req, deptLabel, origin, actionBase, stage.stage_label);
    } else {
      html = buildActionEmail(req, deptLabel, '', '', stage.stage_label);
    }
    const res = await sendResend(env, [email], subjectFor('pending', req), html);
    if (res && res.ok) sent += res.sent;
    else if (res && res.error) { failed++; lastDetail = res.detail || ''; }
  }
  if (sent === 0 && failed > 0) return { error: true, detail: lastDetail || 'all_sends_failed' };
  return { ok: true, sent };
}

// إشعار نتيجة لمُقدّم الطلب (submitted/approved/rejected/returned/award_*/disbursed/closed).
export async function notifyResult(env, base, req, deptLabel, event, origin, comment) {
  const email = await userEmail(env, base, req.requester);
  const html = buildResultEmail(event, req, deptLabel, origin, comment);
  return sendResend(env, [email], subjectFor(event, req), html);
}

// إشعار إعلامي (بلا أزرار) لمجموعة مستلمين — تعميد/صرف/استلام بانتظار اعتماد.
export async function notifyInfo(env, base, req, deptLabel, event, origin, recipients, extra) {
  const toList = [...new Set((recipients || []).filter((u) => u && u !== req.requester))];
  if (!toList.length) return { skipped: true, reason: 'no_recipient' };
  const emails = [];
  for (const u of toList) {
    const e = await userEmail(env, base, u);
    if (/@aldeyabi\.com$/i.test(e)) emails.push(e);
  }
  if (!emails.length) return { skipped: true, reason: 'no_recipient' };
  const html = buildInfoEmail(event, req, deptLabel, origin, extra);
  return sendResend(env, emails, subjectFor(event, req), html);
}

// إشعار فريق المشتريات عند دخول الطلب مرحلة التسعير.
export async function notifyProcurement(env, base, req, deptLabel, origin) {
  const recips = await resolveByPermission(env, base, 'can_manage_procurement', req.requester);
  return notifyInfo(env, base, req, deptLabel, 'pricing', origin, recips);
}

// قراءة رمز (بصلاحية الخادم) — للعرض في صفحة GET فقط، لا تنفيذ.
export async function readToken(env, base, token) {
  if (!token || !/^[0-9A-Za-z]{16,128}$/.test(token)) return { error: 'رمز غير صالح', code: 400 };
  const r = await fetch(`${base}/rest/v1/portal_email_tokens?token=eq.${encodeURIComponent(token)}&select=token,request_id,kind,seq,approver,used,used_at,expires_at`, { headers: svcHeaders(env) });
  if (!r.ok) return { error: 'تعذّر التحقّق', code: 502 };
  const rows = await r.json();
  const row = Array.isArray(rows) ? rows[0] : null;
  if (!row) return { error: 'رمز غير معروف', code: 404 };
  if (row.used) return { error: 'استُخدم هذا الرمز من قبل', code: 410 };
  if (new Date(row.expires_at).getTime() < Date.now()) return { error: 'انتهت صلاحية الرمز', code: 410 };
  return { ok: true, row };
}

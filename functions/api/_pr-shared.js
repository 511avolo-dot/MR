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
// اسم مُرسِل موحّد «Aldeyabi Group» بلا no-reply (يظهر باسم الشركة للموردين ويحسّن
// التسليم). أي عنوان @suppliers.aldeyabi.com صالح للإرسال؛ الردود إلى صندوق حقيقي.
export const DEFAULT_FROM = `Aldeyabi Group <notifications@${SENDER_DOMAIN}>`;
// عنوان ردّ حقيقي يستقبل الرسائل (نطاق الإرسال subdomain قد لا يستقبل) — يرفع ثقة صندوق الوارد.
export const DEFAULT_REPLY_TO = 'supply@aldeyabi.com';
// نستخدم NOTIFY_FROM فقط إن كان من النطاق الموثّق ولا يحوي no-reply؛ وإلا الافتراضي الصحيح.
export function fromAddress(env) {
  const f = String((env && env.NOTIFY_FROM) || '').trim();
  if (f && f.toLowerCase().includes('@' + SENDER_DOMAIN) && !/no-?reply/i.test(f)) return f;
  return DEFAULT_FROM;
}
// عنوان الردّ: قيمة البيئة إن وُجدت، وإلا بريد حقيقي افتراضي (لا نترك الرسالة بلا Reply-To).
export function replyTo(env) {
  const r = String((env && env.NOTIFY_REPLY_TO) || '').trim();
  return r || DEFAULT_REPLY_TO;
}

// النطاق العام لروابط بريد نظام المشتريات/الموردين. نُفضّل SUPPLIERS_ORIGIN (نطاق الموردين
// الموثّق suppliers.aldeyabi.com) كي تتطابق روابط البريد مع دومين المُرسِل نفسه (@suppliers.aldeyabi.com)
// فتقلّ إشارة السبام؛ ثم PUBLIC_ORIGIN كتوافق خلفي؛ وإلا أصل الطلب الفعلي (لا تغيير سلوك إن لم يُضبط).
// ملاحظة: البوابة (نظام 3) لها publicOrigin مستقلّ في _portal-shared.js — لا يتأثّر بهذا.
export function publicOrigin(env, fallbackOrigin) {
  const o = String((env && (env.SUPPLIERS_ORIGIN || env.PUBLIC_ORIGIN)) || '').trim().replace(/\/+$/, '');
  return /^https?:\/\//i.test(o) ? o : (fallbackOrigin || '');
}

/* رابط الطلب داخل النظام الحاليّ — **رابط عميق يفتح الطلب نفسه**.
   ⚠️ بلاغ المالك (2026-09-13): كانت الأزرار الثلاثة تشير إلى `/requests.html`
   وهي **صفحة الطلبات القديمة المستقلّة** لا الشاشة التي يعمل عليها الفريق اليوم
   (`index.html` ← تبويب الطلبات)، وزرّها كان مكتوباً «فتح بوابة الطلبات»
   فيقرؤه المستلِم نظاماً آخر — وهو محقّ: واجهة مختلفة، ولا تفتح الطلب بعينه
   بل قائمةً يبحث فيها. الآن: جذر النظام + `?pr=<id>` يفتح متابعة ذلك الطلب مباشرةً
   (`index.html` يقرأ المعامل عند الإقلاع).
   ⚠️ ولا علاقة لهذا ببوابة نظام 3 (`purchase-portal.html`) — تلك روابطها في
   `_portal-shared.js` المعزول. */
export function requestUrl(origin, prId) {
  if (!origin) return '';
  return prId ? `${origin}/?pr=${encodeURIComponent(prId)}` : `${origin}/`;
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
  // ⚠️ `proc_started_by`/`quotes_collected_by` ليسا زينة: بدونهما كان فرع
  // «الأولوية لمن بدأ العمل عليه» في notifyProcurementEvent **ميّتاً دائماً**،
  // فردّ الطالب على استفسارٍ شخصيّ يذهب بريداً جماعيّاً لكل فريق المشتريات.
  // ⚠️ حقول القرار ليست زينة: بلا `project`/`needed_by`/`priority`/`justification`
  // كان بريد «بانتظار اعتمادك» يعرض رقم الطلب وسطراً واحداً فقط — فيُطلب من
  // المعتمِد أن يقرّر وهو لا يعرف لأي جهة، ولا متى يُطلب التوريد، ولا ما البنود.
  const cols = 'id,request_no,title,department,department_id,sector,project,requester,requester_name,'
    + 'status,current_seq,est_total,currency,po_number,proc_status,proc_started_by,quotes_collected_by,'
    + 'needed_by,request_date,priority,justification,doc_name,revision,return_reason';
  const r = await fetch(`${base}/rest/v1/proc_purchase_requests?id=eq.${encodeURIComponent(prId)}&select=${cols}`, { headers: svcHeaders(env) });
  if (!r.ok) return null;
  const rows = await r.json();
  return Array.isArray(rows) ? rows[0] || null : null;
}
// بنود الطلب — ما يقرّر عليه المعتمِد فعلاً. تُجلب مرّة واحدة لكل إشعار
// (لا مرّة لكل مستلِم)، والسعر يُجلب لكنه لا يُعرَض إلا لمن يملك الرؤية المالية.
export async function loadItems(env, base, prId) {
  try {
    const cols = 'seq,description,unit,requested_qty,stock_balance,unit_price,line_total,notes';
    const r = await fetch(`${base}/rest/v1/proc_pr_items?pr_id=eq.${encodeURIComponent(prId)}&order=seq.asc&select=${cols}`, { headers: svcHeaders(env) });
    if (!r.ok) return [];
    const rows = await r.json();
    return Array.isArray(rows) ? rows : [];
  } catch (_) { return []; }
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
      const ur = await fetch(`${base}/rest/v1/proc_users?active=eq.true&select=username,role,permissions,pr_profile_key,pr_permission_overrides`, { headers: svcHeaders(env) });
      const users = await ur.json();
      const explicit = (users || []).filter((u) =>
        (u.permissions && u.permissions[stage.role_key] === true)
        || (u.pr_permission_overrides && u.pr_permission_overrides[stage.role_key] === true)
        || (stage.role_key === 'pr_approve_maintenance' && u.pr_profile_key === 'maintenance_manager')
        || (stage.role_key === 'pr_authorize_pricing' && u.pr_profile_key === 'procurement_manager')
      ).map((u) => u.username);
      return explicit.length ? explicit : (users || []).filter((u) => u.role === 'admin').map((u) => u.username);
    } catch (_) {}
  }
  return [];
}

/* ⚠️ حُذفت `prRevision` (استعلام مستقلّ لعمود `revision` وحده): صار `loadPR`
   يجلب الإصدار **مع** حقول القرار في استعلام واحد، فبقاؤها مسارُ قراءةٍ ثانٍ
   مهجور يدعو للتفارق. سبب الختم نفسه لم يتغيّر: بريد القرار يصف محتوىً بعينه،
   فلو أُعيد الطلب وعُدِّل ثمّ أُعيد إرساله وجب أن يموت الرمز القديم — والختم
   يُفحَص في القاعدة (`pr_transition_email`) لا في طبقة البريد. */

// ── إنشاء رمز اعتماد لمرة واحدة (يُبطل الرموز السابقة غير المستخدَمة لنفس الطلب/المرحلة/المعتمِد) ──
export async function createToken(env, base, prId, seq, approver, revision) {
  const token = genToken();
  const expires = new Date(Date.now() + tokenTtlMs(env)).toISOString();
  // أبطل أي رموز سابقة غير مستخدَمة لنفس (الطلب/المرحلة/المعتمِد) كي لا يعمل رمز قديم.
  try {
    await fetch(`${base}/rest/v1/proc_email_tokens?pr_id=eq.${encodeURIComponent(prId)}&seq=eq.${seq}&approver=eq.${encodeURIComponent(approver)}&used=eq.false`,
      { method: 'PATCH', headers: { ...svcHeaders(env), Prefer: 'return=minimal' }, body: JSON.stringify({ used: true, used_at: new Date().toISOString() }) });
  } catch (_) {}
  const row = { token, pr_id: prId, seq, approver, expires_at: expires };
  if (Number.isInteger(revision)) row.revision = revision;
  const post = (body) => fetch(`${base}/rest/v1/proc_email_tokens`, {
    method: 'POST', headers: { ...svcHeaders(env), Prefer: 'return=minimal' }, body: JSON.stringify(body),
  });
  let r = await post(row);
  // ⚠️ تسامح مقصود: قاعدة لم تُطبَّق عليها هجرة الختم بعدُ ترفض العمود بـ400.
  // بريد الاعتماد أهمّ من الختم في تلك النافذة — أعِد المحاولة بلا الختم بدل
  // أن يبقى الطلب عالقاً بلا بريد قرار (نفس نمط `local_content_expiry`).
  if (!r.ok && 'revision' in row) {
    const { revision: _drop, ...bare } = row;
    r = await post(bare);
  }
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
  // ── أحداث معالجة المشتريات ومحادثة الطلب ──
  // بلا هذه كان الطالب يرفع طلبه ثم لا يعلم شيئاً حتى الاعتماد النهائي،
  // والمشتريات لا سبيل لها للاستفهام إلا خارج النظام فتضيع المعلومة.
  proc_started:     ['بدأ العمل على طلبك', '#0891b2', '▶'],
  quotes_collected: ['اكتمل جمع عروض الأسعار', '#16a34a', '✓'],
  po_issued:        ['صدر أمر الشراء لطلبك', '#15803d', '🧾'],
  question:         ['استفسار على طلبك', '#d97706', '؟'],
  answer:           ['وصل ردّ على استفسارك', '#0891b2', '↪'],
};
const LINES = (title) => ({
  pending:   `لديك طلب شراء بانتظار قرارك في المرحلة الحالية. راجع الحاجة والبنود ثم اتخذ القرار مباشرةً من هذا البريد أو من مساحة الطلب.`,
  approved:  `اكتملت موافقة مدير الصيانة، وسمح مدير المشتريات ببدء تسعير طلبك «${title}». ستظهر روابط أوامر الشراء وتغطية البنود في مساحة الطلب.`,
  rejected:  `نأسف لإبلاغك بأن طلبك «${title}» قد رُفض.`,
  returned:  `أُعيد طلبك «${title}» إليك للتعديل. يرجى مراجعته وتحديث المطلوب ثم إعادة إرساله.`,
  submitted: `تم استلام طلبك «${title}» وإرساله إلى مدير الصيانة والتشغيل لاعتماد الحاجة. ستصلك التحديثات تلقائياً حتى اكتمال التنفيذ.`,
  proc_started:     `بدأ فريق المشتريات العمل فعلياً على طلبك «${title}»: جارٍ التواصل مع الموردين وجمع عروض الأسعار. ستصلك التحديثات في كل خطوة.`,
  quotes_collected: `اكتمل جمع عروض الأسعار لطلبك «${title}»، وهو الآن في مرحلة المقارنة تمهيداً لإصدار أمر الشراء.`,
  po_issued:        `صدر أمر الشراء لطلبك «${title}». يمكنك متابعة التوريد من شاشة الطلب في النظام — لا حاجة للاتصال بالمشتريات.`,
  question:         `لدى فريق المشتريات استفسار بخصوص طلبك «${title}». الردّ عليه من داخل النظام يُسرّع التنفيذ ويبقى محفوظاً على الطلب.`,
  answer:           `وصل ردّ من مُقدّم الطلب «${title}» على استفسارك. راجعه لمتابعة التنفيذ.`,
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

/* ── تفاصيل القرار داخل البريد ────────────────────────────────────────────────
   بلاغ المالك: «التمبلت يجب أن تكون واضحة فيه تفاصيل الطلب — المشروع أو الجهة
   وموعد التوريد المطلوب… بناءً على ماذا يقرّر وهو لا يعلم أي شيء عن الطلب؟»
   الجذر كان في `loadPR`: لم تكن تجلب المشروع ولا الموعد ولا المبرّر ولا أي بند.

   ⚠️ المبالغ **مقنّعة افتراضاً**: تُعرَض فقط حين يملك المستلِم رؤية مالية فعلية
   (`showMoney` يُحسب لكل معتمِد من `pr_effective_permissions`) — البريد لا تحرسه
   RLS، فطباعة المبلغ فيه بلا بوّابة تتجاوز نظام الصلاحيات كلّه. */

const AR_MONTHS = ['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
export function fmtDateAr(v) {
  if (!v) return '';
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(v));
  if (!m) return String(v);
  return `${Number(m[3])} ${AR_MONTHS[Number(m[2]) - 1] || m[2]} ${m[1]}`;
}
// صيغة الأيام العربية الصحيحة (نفس قاعدة poDays في index.html).
export function arDays(n) {
  const a = Math.abs(n);
  if (a === 1) return 'يوم واحد';
  if (a === 2) return 'يومان';
  if (a >= 3 && a <= 10) return `${a} أيام`;
  return `${a} يوماً`;
}
// صيغة «بند» العربية — مستقلّة عن arDays عمداً (الاشتقاق بـreplace من صيغة
// الأيام كان يُنتج «و3 أيام آخر»؛ التمييز العربيّ يختلف بين المعدودات).
export function arItems(n) {
  const a = Math.abs(n);
  if (a === 1) return 'بند واحد';
  if (a === 2) return 'بندان';
  if (a >= 3 && a <= 10) return `${a} بنود`;
  return `${a} بنداً`;
}
// «باقٍ/متأخّر» بالنسبة لليوم — هذا ما يجعل الأولوية ملموسة للمعتمِد.
export function dueHint(needed_by, now) {
  if (!needed_by) return null;
  const t = Date.parse(`${String(needed_by).slice(0, 10)}T00:00:00Z`);
  if (!Number.isFinite(t)) return null;
  const today = now instanceof Date ? now : new Date();
  const d0 = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
  const diff = Math.round((t - d0) / 86400000);
  if (diff < 0) return { text: `تجاوز الموعد بـ${arDays(diff)}`, color: '#dc2626' };
  if (diff === 0) return { text: 'الموعد اليوم', color: '#dc2626' };
  if (diff <= 7) return { text: `باقٍ ${arDays(diff)}`, color: '#d97706' };
  return { text: `باقٍ ${arDays(diff)}`, color: '#6b7280' };
}
const numTxt = (v) => {
  const n = Number(v);
  if (!Number.isFinite(n)) return '';
  return String(Math.round(n * 100) / 100);
};
const money = (v, cur) => `${Number(v).toLocaleString('en-US', { maximumFractionDigits: 2 })} ${cur || 'ر.س'}`;

const MAX_ROWS = 12;   // بريدٌ بـ60 بنداً لا يُقرأ — الباقي يُفتح في النظام

export function prDetailsBlock(pr, items, opts) {
  const B = BRAND;
  const showMoney = !!(opts && opts.showMoney);
  const list = Array.isArray(items) ? items : [];

  const cell = (label, value, strong) => value
    ? `<tr>
         <td style="padding:7px 0;font-size:12.5px;color:${B.soft};white-space:nowrap;vertical-align:top;width:40%">${esc(label)}</td>
         <td style="padding:7px 0;font-size:13.5px;color:${strong || B.navy};font-weight:700;vertical-align:top">${value}</td>
       </tr>` : '';

  const due = dueHint(pr.needed_by);
  const neededVal = pr.needed_by
    // nowrap: بدونها تتيتّم «أيام» في سطر مستقلّ على عرض الجوال (مقيس).
    ? `${esc(fmtDateAr(pr.needed_by))}${due ? ` <span style="font-weight:600;color:${due.color};white-space:nowrap">· ${esc(due.text)}</span>` : ''}`
    : '';
  const urgent = /عاجل|فوري/.test(String(pr.priority || ''));

  const facts = `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:4px 0 0">
      ${cell('المشروع / الجهة', esc(pr.project || '') || `<span style="color:#dc2626;font-weight:600">غير محدّدة</span>`)}
      ${cell('القسم', esc(pr.department || pr.sector || ''))}
      ${cell('مقدّم الطلب', esc(pr.requester_name || pr.requester || ''))}
      ${cell('تاريخ الطلب', esc(fmtDateAr(pr.request_date)))}
      ${cell('موعد التوريد المطلوب', neededVal)}
      ${cell('الأولوية', pr.priority ? `<span style="color:${urgent ? '#dc2626' : B.navy}">${esc(pr.priority)}</span>` : '')}
      ${showMoney && Number(pr.est_total) > 0 ? cell('القيمة التقديرية', esc(money(pr.est_total, pr.currency))) : ''}
      ${cell('السند المرفق', pr.doc_name ? esc(pr.doc_name) : '')}
    </table>`;

  const just = pr.justification ? `
    <div style="margin:14px 0 0;padding:11px 14px;background:#fffbeb;border:1px solid #fde68a;border-radius:10px">
      <div style="font-size:11.5px;color:#92400e;font-weight:700;margin-bottom:4px">مبرّر الحاجة</div>
      <div style="font-size:13px;color:${B.ink};line-height:1.8">${esc(pr.justification)}</div>
    </div>` : '';

  // طلبٌ أُعيد ثم عاد: سبب الإعادة السابق سياقٌ يلزم المعتمِد قبل قراره.
  const prev = (Number(pr.revision) > 1 && pr.return_reason) ? `
    <div style="margin:10px 0 0;padding:11px 14px;background:#eff6ff;border:1px solid #bfdbfe;border-radius:10px">
      <div style="font-size:11.5px;color:#1d4ed8;font-weight:700;margin-bottom:4px">سبق إرجاعه للتعديل (إصدار ${esc(pr.revision)}) — السبب</div>
      <div style="font-size:13px;color:${B.ink};line-height:1.8">${esc(pr.return_reason)}</div>
    </div>` : '';

  let itemsHtml = '';
  if (list.length) {
    const shown = list.slice(0, MAX_ROWS);
    const anyStock = shown.some((i) => Number(i.stock_balance) > 0);
    const priced = showMoney && shown.some((i) => Number(i.unit_price) > 0);
    const th = (t, align) => `<th style="padding:8px 6px;font-size:11.5px;font-weight:700;color:#fff;text-align:${align || 'right'}">${esc(t)}</th>`;
    const rows = shown.map((i, n) => {
      const bg = n % 2 ? '#fbfaf7' : '#fff';
      return `<tr style="background:${bg}">
        <td style="padding:8px 6px;font-size:11.5px;color:${B.soft};text-align:center;border-top:1px solid ${B.line}">${esc(i.seq || n + 1)}</td>
        <td style="padding:8px 6px;font-size:12.5px;color:${B.ink};border-top:1px solid ${B.line};line-height:1.6">${esc(i.description || '—')}${i.notes ? `<div style="font-size:11px;color:${B.soft};margin-top:2px">${esc(i.notes)}</div>` : ''}</td>
        <td style="padding:8px 6px;font-size:12px;color:${B.soft};text-align:center;border-top:1px solid ${B.line};white-space:nowrap">${esc(i.unit || '—')}</td>
        <td style="padding:8px 6px;font-size:13px;color:${B.navy};font-weight:800;text-align:center;border-top:1px solid ${B.line};white-space:nowrap">${esc(numTxt(i.requested_qty) || '—')}</td>
        ${anyStock ? `<td style="padding:8px 6px;font-size:12px;color:${B.soft};text-align:center;border-top:1px solid ${B.line}">${esc(numTxt(i.stock_balance) || '—')}</td>` : ''}
        ${priced ? `<td style="padding:8px 6px;font-size:12px;color:${B.ink};text-align:center;border-top:1px solid ${B.line};white-space:nowrap" dir="ltr">${Number(i.unit_price) > 0 ? esc(numTxt(i.unit_price)) : '—'}</td>` : ''}
      </tr>`;
    }).join('');
    const more = list.length > MAX_ROWS
      ? `<tr><td colspan="${4 + (anyStock ? 1 : 0) + (priced ? 1 : 0)}" style="padding:9px 6px;font-size:12px;color:${B.soft};text-align:center;background:${B.wash};border-top:1px solid ${B.line}">و${esc(arItems(list.length - MAX_ROWS))} أخرى — افتح الطلب في النظام لعرض القائمة كاملة</td></tr>`
      : '';
    itemsHtml = `
      <div style="font-size:12.5px;color:${B.navy};font-weight:800;margin:18px 0 8px">البنود المطلوبة (${esc(list.length)})</div>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;border:1px solid ${B.line};border-radius:10px;overflow:hidden">
        <tr style="background:${B.navy}">
          ${th('#', 'center')}${th('الصنف')}${th('الوحدة', 'center')}${th('الكمية', 'center')}
          ${anyStock ? th('الرصيد', 'center') : ''}${priced ? th('سعر الوحدة', 'center') : ''}
        </tr>
        ${rows}${more}
      </table>`;
  } else {
    itemsHtml = `<div style="margin:16px 0 0;padding:11px 14px;background:#fef2f2;border:1px solid #fecaca;border-radius:10px;font-size:12.5px;color:#991b1b">لا توجد بنود مسجّلة على هذا الطلب — راجعه في النظام قبل اتخاذ القرار.</div>`;
  }

  return `<div style="margin:16px 0 4px;padding:16px 18px;background:#fff;border:1px solid ${B.line};border-radius:14px">
    ${facts}${just}${prev}${itemsHtml}
  </div>`;
}

// بريد «بانتظار اعتمادك» مع أزرار اتخاذ القرار من داخل البريد (لكل معتمِد رمزه الخاص).
export function buildActionEmail(pr, origin, actionBase, stageLabel, items, showMoney) {
  const B = BRAND; const title = pr.title || 'طلب شراء';
  const portalUrl = requestUrl(origin, pr.id);
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
  const portalBtn = portalUrl ? `<p style="text-align:center;margin:12px 0 0"><a href="${esc(portalUrl)}" style="color:${B.navy};font-size:13px;font-weight:700;text-decoration:underline">فتح الطلب في النظام لمراجعة كامل التفاصيل</a></p>` : '';
  const inner = `<tr><td dir="rtl" style="padding:24px 30px 8px;text-align:right">
    <p style="font-size:14.5px;line-height:1.95;margin:6px 0;color:${B.ink}">${esc(LINES(title).pending)}</p>
    ${stageNote}
    ${prMetaBox(pr)}
    ${prDetailsBlock(pr, items, { showMoney })}
    ${actions}
    ${portalBtn}
    <p style="font-size:11px;color:${B.soft};text-align:center;line-height:1.7;margin:14px 0 0">أزرار القرار صالحة لمرة واحدة ولفترة محدودة. لا تُعِد توجيه هذه الرسالة.</p>
  </td></tr>`;
  return emailShell(inner, 'pending');
}

// بريد نتيجة (للطالب): approved | rejected | returned | submitted.
export function buildResultEmail(event, pr, origin, comment) {
  const B = BRAND; const title = pr.title || 'طلب شراء';
  const portalUrl = requestUrl(origin, pr.id);
  const cmt = comment ? `<div dir="rtl" style="text-align:right;background:${B.wash};border:1px solid ${B.line};border-right:4px solid ${(META[event] || META.submitted)[1]};border-radius:12px;padding:12px 16px;margin:14px 0;font-size:13.5px;color:${B.ink}"><b>ملاحظة:</b> ${esc(comment)}</div>` : '';
  const btn = portalUrl ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0 4px"><tr><td align="center" bgcolor="${B.gold}" style="background:${B.gold};border-radius:12px"><a href="${esc(portalUrl)}" style="display:block;padding:15px 18px;color:#fff;text-decoration:none;font-weight:800;font-size:15px">فتح الطلب في النظام</a></td></tr></table>` : '';
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
  // إصدار الطلب يُقرأ مرّة واحدة لكل الرموز (لا مرّة لكل معتمِد). و`pr` قد يأتي
  // من `loadPR` أو من حمولة الـRPC، وكلاهما قد لا يحمله ⇒ يُستكمَل من القاعدة.
  /* ⚠️ استعلام واحد يخدم الإصدار **وحقول القرار** معاً (مشروع/موعد/مبرّر).
     `pr` قد يأتي من حمولة RPC بلا هذه الحقول، فيلزم استكمالها وإلّا عاد البريد
     أعمى كما كان. والثابت المحروس: **استعلام واحد لكل الإشعار لا واحد لكل
     معتمِد** — وهو ما يهمّ فعلاً حين تكون المرحلة لعدّة مؤهَّلين. */
  const items = await loadItems(env, base, pr.id);
  const hasFields = ('project' in pr) && ('needed_by' in pr);
  const hasRevision = Number.isInteger(pr.revision);
  let full = pr;
  let revision = hasRevision ? pr.revision : null;
  if (!hasFields || !hasRevision) {
    const fresh = await loadPR(env, base, pr.id);
    // حمولة الـRPC لها الأولوية على القراءة (هي الأحدث)، والقراءة تسدّ النواقص.
    if (fresh) full = { ...fresh, ...pr };
    if (!hasRevision && fresh && Number.isInteger(fresh.revision)) revision = fresh.revision;
  }
  let sent = 0, failed = 0, lastDetail = '';
  for (const uname of approvers) {
    const email = await userEmail(env, base, uname);
    if (!/@aldeyabi\.com$/i.test(email)) continue;
    // ⚠️ بوّابة المبالغ لكل مستلِم: البريد لا تحرسه RLS، فلا يُطبَع مبلغ إلا لمن
    // يملك رؤية مالية فعلية (`pr_view_financials`). التعذّر ⇒ إخفاء (فشل مغلق).
    const showMoney = await seesFinancials(env, base, uname);
    let html;
    if (origin) {
      const token = await createToken(env, base, pr.id, stage.seq, uname, revision);
      if (!token) { failed++; continue; }
      const actionBase = `${origin}/api/pr-action?token=${encodeURIComponent(token)}`;
      html = buildActionEmail(full, origin, actionBase, stage.stage_label, items, showMoney);
    } else {
      html = buildActionEmail(full, '', '', stage.stage_label, items, showMoney);
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

/**
 * هل يرى هذا المستخدم المبالغ؟ المصدر الوحيد هو `pr_effective_permissions`
 * (ملفّ الوظيفة + التجاوزات) — نفس ما تحتكم إليه الواجهة والقاعدة، فلا تتفارق
 * بوّابتان. **يفشل مغلقاً:** أي تعذّر (شبكة/دالّة غائبة) ⇒ إخفاء المبلغ.
 */
export async function seesFinancials(env, base, username) {
  if (!username) return false;
  try {
    const r = await fetch(`${base}/rest/v1/rpc/pr_effective_permissions`, {
      method: 'POST',
      headers: { ...svcHeaders(env), 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_username: username }),
    });
    if (!r.ok) return false;
    const perms = await r.json();
    return !!(perms && perms.pr_view_financials === true);
  } catch (_) { return false; }
}

// عنوان **المراسلة** لصفّ مستخدم — مستقلّ عن بريد الدخول عمداً.
//
// ⚠️ الترتيب مقصود: notify_email ← email ← الاشتقاق من الاسم.
//   `notify_email` هو صندوق المراسلة حين لا يملك الموظّف صندوقاً خاصّاً (قسم
//   المشتريات عندنا يتشارك supply@aldeyabi.com — قرار المالك 2026-09-16).
//   و`email` هو بريد الدخول، وهو المصدر حين يكون الصندوق شخصيّاً فعلاً.
//   والاشتقاق آخر مَلاذ: عنوانٌ **مُخمَّن** من ثابت في الكود، وهو الذي أرسل
//   بريد المشتريات شهراً كاملاً إلى صندوق شخص لا علاقة له بالشركة. فلا تجعله
//   الطريق الأوّل، ولا تُوسّعه بأسماء جديدة — خزّن العنوان في القاعدة بدلاً منه.
export function rowNotifyEmail(row) {
  const pick = (v) => {
    const s = String(v || '').trim();
    return (s && /@aldeyabi\.com$/i.test(s)) ? s.toLowerCase() : '';
  };
  return pick(row && row.notify_email) || pick(row && row.email) || usernameToEmail(row && row.username);
}

// بريد المستخدم: يفضّل بريد المراسلة ثمّ بريد الدخول المخزَّن على الاشتقاق من الاسم.
export async function userEmail(env, base, username) {
  if (!username) return '';
  try {
    const r = await fetch(`${base}/rest/v1/proc_users?username=eq.${encodeURIComponent(username)}&select=username,email,notify_email`, { headers: svcHeaders(env) });
    if (r.ok) {
      const rows = await r.json();
      if (rows && rows[0]) return rowNotifyEmail(rows[0]);
    } else {
      // قاعدة قبل الهجرة (لا عمود notify_email) ⇒ 400: أعِد المحاولة بالأعمدة القديمة
      // كي لا يسقط البريد كلّه في نافذة ما قبل التطبيق.
      const r2 = await fetch(`${base}/rest/v1/proc_users?username=eq.${encodeURIComponent(username)}&select=username,email`, { headers: svcHeaders(env) });
      if (r2.ok) {
        const rows2 = await r2.json();
        if (rows2 && rows2[0]) return rowNotifyEmail(rows2[0]);
      }
    }
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
export function buildProcurementEmail(pr, origin, items) {
  const B = BRAND;
  const portalUrl = requestUrl(origin, pr.id);
  const btn = portalUrl ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0 4px"><tr><td align="center" bgcolor="${B.gold}" style="background:${B.gold};border-radius:12px"><a href="${esc(portalUrl)}" style="display:block;padding:15px 18px;color:#fff;text-decoration:none;font-weight:800;font-size:15px">فتح الطلب في النظام</a></td></tr></table>` : '';
  const inner = `<tr><td dir="rtl" style="padding:24px 30px 8px;text-align:right">
    <p style="font-size:14.5px;line-height:1.95;margin:6px 0;color:${B.ink}">اعتُمد طلب الشراء «${esc(pr.title || 'طلب شراء')}» نهائياً عبر كامل سلسلة الموافقات، وهو الآن <b>جاهز لمعالجة المشتريات</b> (عروض أسعار / توريد). راجع التفاصيل والبنود في البوابة.</p>
    ${btn}
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0 6px"><tr>
      <td style="background:${B.wash};border:1px solid ${B.line};border-radius:12px;padding:12px 16px" align="center">
        <span style="font-size:12px;color:${B.soft}">رقم الطلب</span><br>
        <span dir="ltr" style="font-size:17px;font-weight:800;color:${B.navy};letter-spacing:.05em">${esc(pr.id)}</span>
        <div style="font-size:12px;color:${B.soft};margin-top:6px">القسم: ${esc(pr.department || '—')}${pr.requester_name ? ' · الطالب: ' + esc(pr.requester_name) : ''}</div>
      </td></tr></table>
    ${prDetailsBlock(pr, items, { showMoney: true })}
  </td></tr>`;
  return emailShell(inner, 'approved');
}

// مستلِمو بريد المشتريات — مصدر واحد للموضعين (الاعتماد النهائي · أحداث الطلب).
// يُرجِع عناوين مراسلة جاهزة، ولا يقبل أي عنوان من العميل.
// ⚠️ الصندوق المشترك يعني أنّ عدّة موظّفين قد يُنتجون العنوان نفسه — والتخلّص من
// التكرار يقع عند المُستدعي (`new Set`) فلا تصل الرسالة مرّتين.
export async function procurementRecipients(env, base, excludeUsername) {
  const cols = 'username,role,permissions,email,notify_email,pr_profile_key,pr_permission_overrides';
  const legacy = 'username,role,permissions,email,pr_profile_key,pr_permission_overrides';
  try {
    let ur = await fetch(`${base}/rest/v1/proc_users?active=eq.true&select=${cols}`, { headers: svcHeaders(env) });
    // قاعدة قبل الهجرة (لا عمود notify_email) ⇒ 400: أعِد الطلب بالأعمدة القديمة.
    if (!ur.ok) ur = await fetch(`${base}/rest/v1/proc_users?active=eq.true&select=${legacy}`, { headers: svcHeaders(env) });
    if (!ur.ok) return [];
    const users = await ur.json();
    let pick = (users || []).filter((u) =>
      (u.permissions && (u.permissions.can_manage_rfq === true || u.permissions.pr_manage_pricing === true))
      || (u.pr_permission_overrides && u.pr_permission_overrides.pr_manage_pricing === true)
      || ['procurement_officer','procurement_manager'].includes(u.pr_profile_key));
    if (!pick.length) pick = (users || []).filter((u) => u.role === 'admin');
    return pick.filter((u) => u.username !== excludeUsername).map(rowNotifyEmail).filter(Boolean);
  } catch (_) { return []; }
}

// إشعار فريق المشتريات (أصحاب صلاحية can_manage_rfq، وإلا الأدمن) عند الاعتماد النهائي.
export async function notifyProcurement(env, base, pr, origin) {
  const recips = await procurementRecipients(env, base, pr.requester);
  const toList = [...new Set(recips)];
  if (!toList.length) return { skipped: true, reason: 'no_procurement' };
  // ⚠️ `showMoney:true` هنا مقصود ومبرَّر: المستلِمون مُنتقَون بصلاحية التسعير
  // (can_manage_rfq / pr_manage_pricing / ملفّات المشتريات) أو أدمن — وكلّهم
  // أصحاب رؤية مالية بحكم الدور. وهذا إرسال دفعيّ واحد فلا بوّابة لكل شخص.
  const items = await loadItems(env, base, pr.id);
  const full = ('project' in pr && 'needed_by' in pr) ? pr : ((await loadPR(env, base, pr.id)) || pr);
  const html = buildProcurementEmail(full, origin, items);
  return sendResend(env, toList, `طلب معتمد جاهز للمشتريات — طلب ${pr.id} | مجموعة الذيابي`, html);
}

/**
 * إشعار فريق المشتريات على طلب بعينه (رَدُّ الطالب على استفسار مثلاً).
 * المستلِمون يُحسبون على الخادم: مَن يعمل على الطلب فعلاً إن وُجد، وإلا
 * أصحاب صلاحية المشتريات — ولا يُقبَل أي عنوان من العميل.
 */
export async function notifyProcurementEvent(env, base, pr, event, origin, comment) {
  let recips = [];
  // الأولوية لمن بدأ العمل عليه فعلاً — هو صاحب السياق.
  const owner = pr.proc_started_by || pr.quotes_collected_by || '';
  if (owner && owner !== pr.requester) {
    const e = await userEmail(env, base, owner);
    if (e) recips.push(e);
  }
  if (!recips.length) recips = await procurementRecipients(env, base, pr.requester);
  const toList = [...new Set(recips.filter(Boolean))];
  if (!toList.length) return { skipped: true, reason: 'no_procurement' };
  return sendResend(env, toList, subjectFor(event, pr), buildResultEmail(event, pr, origin, comment));
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

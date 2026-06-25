/**
 * Cloudflare Pages Function — إشعارات البريد لطلبات تسجيل الموردين
 * ----------------------------------------------------------------
 * يرسل بريداً احترافياً (عربي + إنجليزي) عند كل حالة:
 *   received | approved | rejected | needs_revision
 *
 * الإعداد (أسرار بيئة Cloudflare Pages):
 *   SUPABASE_URL                رابط مشروع Supabase
 *   SUPABASE_SERVICE_ROLE_KEY   مفتاح service_role (سرّ — لقراءة بريد المتقدّم فقط)
 *   RESEND_API_KEY              مفتاح Resend (https://resend.com) لإرسال البريد
 *   NOTIFY_FROM (اختياري)       المُرسِل من النطاق الموثّق، مثل: "طلبات الذيابي <noreply@suppliers.aldeyabi.com>"
 *                               (إن لم يُضبط أو كان من نطاق غير موثّق، يستخدم الكود مُرسِلاً افتراضياً صحيحاً)
 *   NOTIFY_REPLY_TO (اختياري)   بريد الرد، مثل supply@aldeyabi.com
 *
 * الأمان (لا مُرسِل مفتوح / no open relay):
 *   - same-origin فقط.
 *   - المستقبل يُؤخذ حصراً من بريد الطلب المخزّن (لا يقبل عنواناً من العميل).
 *   - المحتوى قوالب ثابتة على الخادم (لا نص من العميل).
 *   - يجب أن تطابق حالة الطلب في قاعدة البيانات نوع الحدث المطلوب،
 *     فلا يمكن انتحال بريد "قبول" لطلب قيد المراجعة.
 */

import { loadPR as prLoadPR, loadApprovals as prLoadApprovals, notifyPending as prNotifyPending, notifyResult as prNotifyResult, notifyProcurement as prNotifyProcurement, fromAddress } from './_pr-shared.js';

const EVENTS = new Set(['received', 'approved', 'rejected', 'needs_revision']);

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
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
// NOTIFY_FROM لم يعد إلزامياً: للكود مُرسِل افتراضي صحيح من النطاق الموثّق (fromAddress).
const emailConfigured = (env) =>
  !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY && env.RESEND_API_KEY);

// خريطة بريد→مستخدم (تطابق index.html / admin-users.js)
const AUTH_EMAIL_MAP = { abdullah: 'abdullah@aldeyabi.com', mostafa: 'supply@aldeyabi.com', mahmoud: 'mahmoud@aldeyabi.com' };
const emailToUsername = (email) => {
  const e = String(email || '').toLowerCase();
  for (const [u, m] of Object.entries(AUTH_EMAIL_MAP)) { if (m.toLowerCase() === e) return u; }
  return e.split('@')[0];
};
const usernameToEmail = (u) => {
  const k = String(u || '').trim().toLowerCase();
  return AUTH_EMAIL_MAP[k] || (k + '@aldeyabi.com');
};
// تحقّق أن المستدعي موظف نشط (جلسة Supabase صالحة + سجل في proc_users).
// يُعيد بريد الموظف عند النجاح (يُستخدم كمستقبِل للبريد التجريبي)، وإلا null.
// يُعيد { ok:true, email } عند نجاح التحقّق، أو { ok:false, reason } مع سبب واضح
// (يُعرض للمستدعي — وهو موظف مُصادَق — لتشخيص سبب الرفض بدل «غير مصرّح» المبهمة).
async function verifyStaff(env, base, jwt) {
  try {
    const r = await fetch(`${base}/auth/v1/user`, { headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${jwt}` } });
    if (!r.ok) return { ok: false, reason: 'الجلسة غير صالحة أو منتهية' };
    const u = await r.json();
    if (!u || !u.email) return { ok: false, reason: 'لا يوجد بريد في جلسة الدخول' };
    const email = String(u.email).toLowerCase();
    const svc = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` };
    // مطابقة متينة: نقبل المستدعي موظفاً إذا كان بريد جلسته يساوي البريد المخزَّن لأي
    // حساب نشط، أو البريد المشتقّ من اسمه (usernameToEmail) — يُصلح فروق الحالة وحالة
    // غياب عمود email، ويُغلق الانتحال (بريد خارجي لن يساوي أي بريد شركة قانوني).
    let resp = await fetch(`${base}/rest/v1/proc_users?select=username,email,active`, { headers: svc });
    if (!resp.ok) {
      // قاعدة قديمة بلا عمود email: طابِق بالاسم المشتقّ فقط (توافق خلفي).
      resp = await fetch(`${base}/rest/v1/proc_users?select=username,active`, { headers: svc });
      if (!resp.ok) return { ok: false, reason: 'تعذّر التحقّق من قائمة المستخدمين' };
    }
    const rows = await resp.json();
    const match = (Array.isArray(rows) ? rows : []).find((x) => {
      if (x.active === false) return false;
      const stored = x.email ? String(x.email).toLowerCase() : '';
      const derived = usernameToEmail(x.username).toLowerCase();
      return stored === email || derived === email;
    });
    if (!match) return { ok: false, reason: `بريد جلستك (${email}) لا يطابق أي حساب موظف نشط في النظام` };
    return { ok: true, email: String(u.email) };
  } catch (_) { return { ok: false, reason: 'خطأ غير متوقّع أثناء التحقّق' }; }
}

export async function onRequestGet({ env }) {
  return json({ ok: emailConfigured(env) });
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);
  // إن لم يُضبط البريد على الخادم: تجاهل بهدوء كي لا تتعطّل عملية التسجيل/المراجعة.
  if (!emailConfigured(env)) return json({ skipped: true, reason: 'email_not_configured' });

  let payload;
  try { payload = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }

  // ════ إشعارات بوابة طلبات الشراء (kind:'pr') ════
  // المستقبِل يُحدَّد على الخادم من حالة الطلب (لا عنوان من العميل) + يُقيَّد بنطاق الشركة.
  if (payload && payload.kind === 'pr') {
    const base = env.SUPABASE_URL;
    const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);
    const vsPr = await verifyStaff(env, base, jwt);
    if (!vsPr.ok) return json({ error: 'غير مصرّح', detail: vsPr.reason }, 403);
    const prId = String(payload.pr_id || '').trim();
    const ev = String(payload.event || '').trim();
    if (!prId || !['pending', 'approved', 'rejected', 'returned', 'submitted'].includes(ev)) return json({ error: 'مدخلات غير صالحة' }, 400);
    const pr = await prLoadPR(env, base, prId);
    if (!pr) return json({ error: 'الطلب غير موجود' }, 404);
    let origin = ''; try { origin = new URL(request.headers.get('origin') || request.headers.get('referer')).origin; } catch (_) {}
    const comment = payload && payload.comment ? String(payload.comment) : '';
    try {
      let res;
      if (ev === 'pending') {
        // بريد «بانتظار اعتمادك» مع أزرار قرار موقّعة لكل معتمِد (الاعتماد من داخل البريد).
        const approvals = await prLoadApprovals(env, base, prId);
        res = await prNotifyPending(env, base, pr, approvals, origin);
      } else if (ev === 'approved') {
        // الاعتماد النهائي: بريد للطالب + بريد لفريق المشتريات (طلب جاهز للمعالجة).
        const r1 = await prNotifyResult(env, base, pr, 'approved', origin, comment);
        const r2 = await prNotifyProcurement(env, base, pr, origin);
        const aerr = (r1 && r1.error) || (r2 && r2.error);
        res = aerr
          ? { error: true, detail: (r1 && r1.detail) || (r2 && r2.detail) || '' }
          : { ok: true, sent: ((r1 && r1.sent) || 0) + ((r2 && r2.sent) || 0) };
      } else {
        // بريد نتيجة لمُقدّم الطلب (رُفض/أُعيد/استُلم).
        res = await prNotifyResult(env, base, pr, ev, origin, comment);
      }
      if (res && res.error) return json({ error: 'تعذّر إرسال البريد', detail: res.detail || '' }, 502);
      if (res && res.skipped) return json({ skipped: true, reason: res.reason });
      return json({ ok: true, sent: true, to: (res && res.sent) || 0 });
    } catch (e) { return json({ error: 'تعذّر إرسال البريد' }, 502); }
  }

  const id = String(payload?.id || '').trim();
  const event = String(payload?.event || '').trim();

  // ── بريد تجريبي: يُرسَل حصراً إلى بريد الموظف المستدعي (لا يقبل أي عنوان من العميل) ──
  if (event === 'test') {
    const tbase = env.SUPABASE_URL;
    const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);
    const vsTest = await verifyStaff(env, tbase, jwt);
    if (!vsTest.ok) return json({ error: 'غير مصرّح', detail: vsTest.reason }, 403);
    const staffEmail = vsTest.email;
    const status = EVENTS.has(payload?.status) ? payload.status : 'received';
    const tpl = (payload && payload.tpl && typeof payload.tpl === 'object') ? payload.tpl : null;
    let origin = ''; try { origin = new URL(request.headers.get('origin') || request.headers.get('referer')).origin; } catch (_) {}
    const resumeUrl = status === 'needs_revision' ? `${origin}/register.html?resume=reg_demo&t=demo` : '';
    const trackUrl = origin ? `${origin}/register.html?track=DG-DEMO12` : '';
    const sampleRow = { legal_name_ar: 'شركة النور للمقاولات (تجربة)', legal_name_en: 'Al-Noor Contracting Co. (Test)' };
    const sampleRev = status === 'needs_revision'
      ? { general: 'يرجى تحديث السجل التجاري بنسخة سارية المفعول.', fields: ['cr', 'vat'], sections: ['contact_info'] }
      : null;
    let { subject, html } = buildEmail(status, sampleRow, 'DG-DEMO12', resumeUrl, tpl, sampleRev, trackUrl, origin);
    subject = '[تجربة] ' + subject;
    try {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: fromAddress(env), to: [staffEmail], subject, html, ...(env.NOTIFY_REPLY_TO ? { reply_to: env.NOTIFY_REPLY_TO } : {}) }),
      });
      if (!r.ok) { const t = await r.text().catch(() => ''); return json({ error: 'تعذّر إرسال البريد التجريبي', detail: t.slice(0, 300) }, 502); }
      return json({ ok: true, sent: true, to: staffEmail });
    } catch (e) { return json({ error: 'تعذّر إرسال البريد التجريبي' }, 502); }
  }

  if (!id || !EVENTS.has(event)) return json({ error: 'مدخلات غير صالحة' }, 400);

  const base = env.SUPABASE_URL;

  // إشعارات تغيّر الحالة (قبول/رفض/تعديل) يبدؤها موظف فقط → اشترط جلسة موظف صالحة.
  // إشعار "الاستلام" يبدؤه المتقدّم العام عند الإرسال (محدود: لا يُرسَل إلا لبريد الطلب نفسه).
  if (event !== 'received') {
    const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);
    const vsReg = await verifyStaff(env, base, jwt);
    if (!vsReg.ok) return json({ error: 'غير مصرّح', detail: vsReg.reason }, 403);
  }
  const headers = {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    'Content-Type': 'application/json',
  };

  // اقرأ الحقول العامة فقط من سجل الطلب (لا وثائق)
  let row;
  try {
    const cols = 'id,legal_name_ar,legal_name_en,email,contact_email,status,revision_token,review_notes,last_notify';
    const r = await fetch(
      `${base}/rest/v1/proc_supplier_registrations?id=eq.${encodeURIComponent(id)}&select=${cols}`,
      { headers });
    if (!r.ok) return json({ error: 'تعذّر جلب الطلب' }, 502);
    const rows = await r.json();
    row = Array.isArray(rows) ? rows[0] : null;
  } catch (_) { return json({ error: 'تعذّر الاتصال بقاعدة البيانات' }, 502); }
  // S2: حدث «الاستلام» عام (anon) — ردّ موحّد دائماً كي لا يُكشف وجود الطلب أو حالته
  // (يمنع استخدام النقطة كأوراكل لتعداد أرقام الطلبات). أحداث الموظف تحتفظ بردّها الحقيقي.
  if (!row) return event === 'received' ? json({ ok: true }) : json({ error: 'الطلب غير موجود' }, 404);

  // تحقّق من تطابق الحالة (منع الانتحال)
  const expectStatus = event === 'received' ? 'pending' : event;
  if (String(row.status) !== expectStatus) {
    return event === 'received' ? json({ ok: true }) : json({ skipped: true, reason: 'status_mismatch', status: row.status });
  }

  // S2: كبح معدّل «الاستلام» — لا نُعيد الإرسال إن أُرسل إشعار استلام خلال 5 دقائق
  // (يمنع تضخيم البريد بإعادة الطلب لرقم طلب معروف). يستخدم عمود last_notify الموجود.
  if (event === 'received' && row.last_notify) {
    try {
      const ln = typeof row.last_notify === 'string' ? JSON.parse(row.last_notify) : row.last_notify;
      if (ln && ln.event === 'received' && ln.at && (Date.now() - new Date(ln.at).getTime()) < 5 * 60 * 1000) {
        return json({ ok: true }); // مكبوح بهدوء
      }
    } catch (_) {}
  }

  // إشعار جرس داخلي للمراجعين بطلب تسجيل جديد (أفضل جهد — لا يُعطّل البريد إن فشل).
  // البوابة العامة (anon) لا تستطيع الكتابة في proc_notifications، فننشئه هنا بصلاحية الخادم.
  if (event === 'received') {
    try {
      const ur = await fetch(`${base}/rest/v1/proc_users?select=username,role,active,permissions&active=eq.true`, { headers });
      if (ur.ok) {
        const users = await ur.json();
        const name = row.legal_name_ar || row.legal_name_en || id;
        const recips = (Array.isArray(users) ? users : []).filter(
          u => u.username && (u.role === 'admin' || !u.permissions || u.permissions.can_review_registrations !== false));
        const notifs = recips.map(u => ({
          id: 'ntf_' + Date.now() + '_' + Math.random().toString(36).slice(2, 7) + '_' + u.username,
          recipient: u.username, type: 'system',
          title: 'طلب تسجيل مورد جديد',
          body: `${name} — بانتظار المراجعة (${id})`,
          link: 'registrations', read: false,
        }));
        if (notifs.length) {
          await fetch(`${base}/rest/v1/proc_notifications`, {
            method: 'POST', headers: { ...headers, Prefer: 'return=minimal' }, body: JSON.stringify(notifs),
          });
        }
      }
    } catch (_) { /* لا يؤثر على إرسال البريد */ }
  }

  // الأولوية لبريد مسؤول التواصل (هو من سجّل وسيتابع حالة الطلب)، ثم بريد الشركة احتياطاً
  const to = (row.contact_email || row.email || '').trim();
  if (!to || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) {
    return event === 'received' ? json({ ok: true }) : json({ skipped: true, reason: 'no_recipient' });
  }

  let origin = '';
  try { origin = new URL(request.headers.get('origin') || request.headers.get('referer')).origin; } catch (_) {}
  const resumeUrl = (event === 'needs_revision' && row.revision_token)
    ? `${origin}/register.html?resume=${encodeURIComponent(id)}&t=${encodeURIComponent(row.revision_token)}`
    : '';
  const trackUrl = origin ? `${origin}/register.html?track=${encodeURIComponent(id)}` : '';

  // اقرأ القوالب المخصّصة من قاعدة البيانات (إن وُجدت) — وإلا تُستخدم الافتراضية المدمجة
  let custom = null;
  try {
    const tr = await fetch(`${base}/rest/v1/proc_settings?key=eq.email_templates&select=value`, { headers });
    if (tr.ok) {
      const rows = await tr.json();
      let v = rows && rows[0] ? rows[0].value : null;
      if (typeof v === 'string') { try { v = JSON.parse(v); } catch (_) { v = null; } }
      if (v && typeof v === 'object') custom = v[event] || null;
    }
  } catch (_) {}

  // عند «يحتاج تعديل»: استخرج البنود المطلوبة بالتحديد (وثائق/أقسام/ملاحظة) من ملاحظات المراجِع
  let revisionInfo = null;
  if (event === 'needs_revision' && row.review_notes) {
    try {
      const rn = typeof row.review_notes === 'string' ? JSON.parse(row.review_notes) : row.review_notes;
      if (rn && ((rn.fields && rn.fields.length) || (rn.sections && rn.sections.length) || rn.general)) revisionInfo = rn;
    } catch (_) {}
  }

  const { subject, html } = buildEmail(event, row, id, resumeUrl, custom, revisionInfo, trackUrl, origin);

  // أرسل عبر Resend
  try {
    const body = {
      from: fromAddress(env),
      to: [to],
      subject,
      html,
      ...(env.NOTIFY_REPLY_TO ? { reply_to: env.NOTIFY_REPLY_TO } : {}),
    };
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!r.ok) {
      const t = await r.text().catch(() => '');
      return event === 'received' ? json({ ok: true }) : json({ error: 'تعذّر إرسال البريد', detail: t.slice(0, 300) }, 502);
    }
    // S2: سجّل وقت إشعار «الاستلام» لتفعيل كبح المعدّل (للحدث العام فقط، قبل أي قرار موظف)
    if (event === 'received') {
      try {
        await fetch(`${base}/rest/v1/proc_supplier_registrations?id=eq.${encodeURIComponent(id)}`, {
          method: 'PATCH', headers: { ...headers, Prefer: 'return=minimal' },
          body: JSON.stringify({ last_notify: { event: 'received', sent: true, at: new Date().toISOString() } }),
        });
      } catch (_) {}
    }
    return json({ ok: true, sent: true });
  } catch (e) {
    return json({ error: 'تعذّر إرسال البريد' }, 502);
  }
}

/* ── قوالب البريد الاحترافية (ثنائية اللغة) — افتراضية، تُتجاوز بقوالب قاعدة البيانات ── */
const BRAND = { navy: '#0B1B36', gold: '#B8923D', ink: '#1f2937', soft: '#6b7280', line: '#e6e8ee', wash: '#f6f4ee' };

// المتغيّرات المدعومة في النصوص: {name} اسم المنشأة · {name_en} الاسم الإنجليزي · {id} رقم الطلب
const DEFAULTS = {
  received: {
    badge: ['تم الاستلام', 'Received', '#2563eb'],
    subject: `تم استلام طلب تسجيلكم — مجموعة الذيابي | Application Received`,
    ar: `شكراً لتسجيلكم كمورد لدى مجموعة الذيابي. تم استلام طلبكم بنجاح وهو الآن قيد المراجعة من فريق إدارة علاقات الموردين. سنتواصل معكم خلال 3–5 أيام عمل.\n\nيمكنكم متابعة حالة الطلب في أي وقت عبر بوابة الموردين باستخدام رقم الطلب أدناه.`,
    en: `Thank you for registering as a supplier with Al-Deyabi Group. Your application has been received and is now under review by our Supplier Relations team. We will contact you within 3–5 business days.\n\nYou can track your application status anytime via the supplier portal using the application number below.`,
  },
  approved: {
    badge: ['تم القبول', 'Approved', '#16a34a'],
    subject: `تهانينا — تم اعتماد تسجيلكم كمورد | Supplier Application Approved`,
    ar: `يسعدنا إبلاغكم بقبول طلب تسجيلكم واعتمادكم ضمن قائمة الموردين المعتمدين لدى مجموعة الذيابي. سيتواصل معكم فريق المشتريات بالخطوات التالية وفرص التوريد.`,
    en: `We are pleased to inform you that your application has been approved and you are now part of Al-Deyabi Group's accredited suppliers. Our procurement team will contact you with next steps and supply opportunities.`,
  },
  rejected: {
    badge: ['غير مقبول', 'Not Approved', '#dc2626'],
    subject: `بخصوص طلب تسجيلكم — مجموعة الذيابي | Application Update`,
    ar: `نشكر لكم اهتمامكم بالتسجيل كمورد لدى مجموعة الذيابي. بعد المراجعة، نأسف لإبلاغكم بعدم قبول الطلب في الوقت الحالي. للاستفسار أو إعادة التقديم مستقبلاً يسعدنا تواصلكم مع إدارة المشتريات.`,
    en: `Thank you for your interest in registering as a supplier with Al-Deyabi Group. After review, we regret to inform you that the application was not approved at this time. For inquiries or to re-apply in the future, please contact our procurement department.`,
  },
  needs_revision: {
    badge: ['يحتاج تعديل', 'Action Required', '#d97706'],
    subject: `طلبكم بحاجة إلى استكمال — مجموعة الذيابي | Action Required`,
    ar: `راجعنا طلبكم ونحتاج إلى تعديل أو استكمال بعض البيانات/الوثائق لإتمام الاعتماد. يرجى فتح الطلب عبر الزر أدناه وتحديث المطلوب ثم إعادة إرساله.`,
    en: `We have reviewed your application and need some data/documents to be revised or completed before approval. Please open your application using the button below, update the required items, and resubmit.`,
  },
};

// تسميات ثنائية اللغة لبنود التعديل (تطابق معرّفات لوحة المراجعة في index.html)
const DOC_LABELS = {
  cr: { ar: 'السجل التجاري', en: 'Commercial Registration' },
  vat: { ar: 'شهادة الزكاة / ضريبة القيمة المضافة', en: 'Zakat / VAT Certificate' },
  gosi: { ar: 'شهادة التأمينات الاجتماعية', en: 'GOSI Certificate' },
  chamber: { ar: 'شهادة الغرفة التجارية', en: 'Chamber of Commerce Certificate' },
  natl_addr: { ar: 'وثيقة العنوان الوطني', en: 'National Address Document' },
  municipal: { ar: 'رخصة البلدية / الترخيص الصناعي', en: 'Municipal / Industrial License' },
  quality: { ar: 'شهادات الجودة', en: 'Quality Certificates' },
  safety: { ar: 'شهادات السلامة والبيئة', en: 'Safety & Environment Certificates' },
  clients: { ar: 'قائمة العملاء والمشاريع', en: 'Clients & Projects List' },
  brochure: { ar: 'بروشور / ملف تعريفي', en: 'Company Profile' },
};
const SEC_LABELS = {
  general_info: { ar: 'بيانات المنشأة', en: 'Company Information' },
  contact_info: { ar: 'بيانات التواصل', en: 'Contact Information' },
  activity_info: { ar: 'النشاط والخدمات', en: 'Activity & Services' },
};
// صندوق بنود التعديل — ثنائي اللغة (كل عنوان/بند: عربي · English)
function renderRevisionBox(rev) {
  const B = BRAND;
  const bi = (m) => (m ? `${m.ar} · ${m.en}` : '');
  const docs = (rev.fields || []).map((id) => bi(DOC_LABELS[id]) || id);
  const secs = (rev.sections || []).map((id) => bi(SEC_LABELS[id]) || id);
  let items = '';
  if (docs.length) items += `<div style="margin-top:8px;font-weight:700;color:${B.navy};font-size:13px">وثائق مطلوب إعادة رفعها · Documents to re-upload</div><ul style="margin:4px 18px 0;padding:0;color:${B.ink};font-size:13px;line-height:1.9">${docs.map((d) => `<li>${esc(d)}</li>`).join('')}</ul>`;
  if (secs.length) items += `<div style="margin-top:8px;font-weight:700;color:${B.navy};font-size:13px">أقسام تحتاج مراجعة · Sections to review</div><ul style="margin:4px 18px 0;padding:0;color:${B.ink};font-size:13px;line-height:1.9">${secs.map((s) => `<li>${esc(s)}</li>`).join('')}</ul>`;
  const gen = rev.general ? `<div style="margin-top:10px;font-size:13px;color:${B.ink}"><b>ملاحظة الفريق · Team note:</b> ${esc(rev.general)}</div>` : '';
  if (!items && !gen) return '';
  return `<div dir="rtl" style="text-align:right;background:#fff7ed;border:1px solid #fed7aa;border-right:4px solid #d97706;border-radius:12px;padding:14px 16px;margin:16px 0">
    <div style="font-weight:800;color:#c2410c;font-size:14px">المطلوب تعديله أو استكماله · Items to update or complete</div>
    ${items}${gen}
  </div>`;
}
function fillVars(t, v) {
  // مُستبدِلات دالّية: تُدرِج القيمة حرفياً وتتفادى تأويل عميل البريد لرموز مثل $& أو $1
  // إن وردت ضمن اسم منشأة (تشويه نصّي سابق).
  return String(t == null ? '' : t)
    .replace(/\{name_en\}/g, () => (v.name_en == null ? '' : String(v.name_en)))
    .replace(/\{name\}/g, () => (v.name == null ? '' : String(v.name)))
    .replace(/\{id\}/g, () => (v.id == null ? '' : String(v.id)));
}
function paragraphs(text, style) {
  return String(text || '').split(/\n{2,}/).filter(s => s.trim() !== '')
    .map(p => `<p style="${style}">${esc(p).replace(/\n/g, '<br>')}</p>`).join('');
}

export function buildEmail(event, row, id, resumeUrl, custom, revisionInfo, trackUrl, origin) {
  const nameAr = row.legal_name_ar || row.legal_name_en || 'المورد الكريم';
  const nameEn = row.legal_name_en || row.legal_name_ar || 'Valued Supplier';
  const D = DEFAULTS[event] || DEFAULTS.received;
  const c = custom || {};
  const NAVY2 = '#16315c';
  const HERO = { received:'⏳', approved:'✓', rejected:'✕', needs_revision:'✎' };
  const heroIcon = HERO[event] || '•';
  const heroColor = D.badge[2];
  const heroBg = D.badge[2] + '14';

  const revBox = revisionInfo ? renderRevisionBox(revisionInfo) : '';

  const subjectRaw = (c.subject && String(c.subject).trim()) ? c.subject : D.subject;
  const arRaw = (c.ar && String(c.ar).trim()) ? c.ar : D.ar;
  const enRaw = (c.en && String(c.en).trim()) ? c.en : D.en;

  const subject = fillVars(subjectRaw, { name: nameAr, name_en: nameEn, id });
  const arHtml = paragraphs(fillVars(arRaw, { name: nameAr, name_en: nameEn, id }), `font-size:14.5px;line-height:1.95;margin:6px 0;color:${BRAND.ink};direction:rtl;text-align:right`);
  const enHtml = paragraphs(fillVars(enRaw, { name: nameEn, name_en: nameEn, id }), `font-size:13.5px;line-height:1.8;margin:6px 0;color:${BRAND.ink};direction:ltr;text-align:left`);

  // أزرار مبنية بجدول (bulletproof) لتظهر بعرض كامل ومتوسّطة في كل عملاء البريد
  const cta = resumeUrl
    ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:14px 0 0"><tr><td align="center" bgcolor="${BRAND.gold}" style="background:${BRAND.gold};border-radius:12px"><a href="${esc(resumeUrl)}" style="display:block;padding:15px 18px;color:#ffffff;text-decoration:none;font-weight:800;font-size:15px;text-align:center">فتح الطلب وتعديله · Open &amp; edit</a></td></tr></table>`
    : '';
  const trackBlock = trackUrl
    ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:12px 0 6px"><tr><td align="center" bgcolor="${BRAND.navy}" style="background:${BRAND.navy};border-radius:12px"><a href="${esc(trackUrl)}" style="display:block;padding:15px 18px;color:#ffffff;text-decoration:none;font-weight:800;font-size:15px;text-align:center">تتبّع حالة طلبك · Track your application</a></td></tr></table>
       <p style="font-size:12px;color:${BRAND.soft};text-align:center;line-height:1.7;margin:8px 0 0">تابع حالة طلبك في أي وقت برقم الطلب أعلاه، وستصلك رسالة تلقائية عند أي تحديث على حالته.<br><span dir="ltr">You'll automatically receive an email whenever your application status is updated.</span></p>`
    : '';
  const html = `<!DOCTYPE html><html dir="rtl" lang="ar"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:${BRAND.wash};font-family:'Segoe UI',Tahoma,Arial,sans-serif;color:${BRAND.ink}">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${BRAND.wash};padding:22px 12px">
    <tr><td align="center">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#fff;border-radius:18px;overflow:hidden;box-shadow:0 10px 40px -16px rgba(11,27,54,.35)">
        <tr><td style="background:linear-gradient(135deg,${BRAND.navy},${NAVY2});padding:24px 30px" align="center">
          <div style="color:#E9D9B4;font-size:11.5px;letter-spacing:.08em;text-transform:uppercase">AL-DEYABI GROUP · مجموعة الذيابي</div>
          <div style="color:#fff;font-size:13px;margin-top:6px">بوابة الموردين · <span dir="ltr">Supplier Portal</span></div>
          <div style="height:1px;width:60px;background:${BRAND.gold};margin:12px auto;opacity:.6"></div>
          <div style="color:#fff;font-size:19px;font-weight:800">إشعار حالة طلب التسجيل</div>
          <div dir="ltr" style="color:#cdd6e6;font-size:12.5px;font-weight:600;margin-top:2px">Registration Status Notification</div>
        </td></tr>
        <tr><td style="height:3px;background:${BRAND.gold}"></td></tr>

        <tr><td style="background:${heroBg};padding:24px 30px" align="center">
          <div style="width:60px;height:60px;border-radius:50%;background:${heroColor};color:#fff;font-size:29px;line-height:60px;margin:0 auto;font-weight:700">${heroIcon}</div>
          <div style="font-size:21px;font-weight:800;color:${heroColor};margin-top:12px">${esc(D.badge[0])}</div>
          <div dir="ltr" style="font-size:13px;color:${BRAND.soft};margin-top:2px;letter-spacing:.04em">${esc(D.badge[1])}</div>
        </td></tr>

        <tr><td dir="rtl" style="padding:26px 30px 6px;text-align:right">
          <div style="font-size:16px;font-weight:700;color:${BRAND.navy};margin-bottom:8px">عزيزنا ${esc(nameAr)}،</div>
          ${arHtml}
          ${revBox}
          ${cta}
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:18px 0 8px"><tr>
            <td style="background:${BRAND.wash};border:1px solid ${BRAND.line};border-radius:12px;padding:12px 16px" align="center">
              <span style="font-size:12px;color:${BRAND.soft}">رقم الطلب · Application No.</span><br>
              <span dir="ltr" style="font-size:18px;font-weight:800;color:${BRAND.navy};letter-spacing:.06em">${esc(id)}</span>
            </td></tr></table>
          ${trackBlock}
        </td></tr>

        <tr><td style="padding:6px 30px"><div style="border-top:1px solid ${BRAND.line}"></div></td></tr>
        <tr><td dir="ltr" style="padding:6px 30px 22px;text-align:left">
          <div style="font-size:15px;font-weight:700;color:${BRAND.navy};margin-bottom:6px">Dear ${esc(nameEn)},</div>
          ${enHtml}
        </td></tr>

        <tr><td style="background:${BRAND.navy};padding:18px 30px" align="center">
          <div style="color:#fff;font-size:12px;opacity:.9">مجموعة الذيابي · إدارة علاقات الموردين · Al-Deyabi Group</div>
          <div style="color:${BRAND.gold};font-size:12px;margin-top:4px" dir="ltr">supply@aldeyabi.com</div>
          <div style="color:#fff;opacity:.5;font-size:10.5px;margin-top:6px">رسالة آلية — لا يلزم الرد · This is an automated message.</div>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;

  return { subject, html };
}

/* قوالب بريد بوابة طلبات الشراء انتقلت إلى functions/api/_pr-shared.js
   (مع دعم الاعتماد من داخل البريد برموز موقّعة لمرة واحدة). */

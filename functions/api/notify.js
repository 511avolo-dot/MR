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
 *   NOTIFY_FROM                 المُرسِل، مثل: "موردو الذيابي <noreply@aldeyabi.com>"
 *   NOTIFY_REPLY_TO (اختياري)   بريد الرد، مثل supply@aldeyabi.com
 *
 * الأمان (لا مُرسِل مفتوح / no open relay):
 *   - same-origin فقط.
 *   - المستقبل يُؤخذ حصراً من بريد الطلب المخزّن (لا يقبل عنواناً من العميل).
 *   - المحتوى قوالب ثابتة على الخادم (لا نص من العميل).
 *   - يجب أن تطابق حالة الطلب في قاعدة البيانات نوع الحدث المطلوب،
 *     فلا يمكن انتحال بريد "قبول" لطلب قيد المراجعة.
 */

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
const emailConfigured = (env) =>
  !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY && env.RESEND_API_KEY && env.NOTIFY_FROM);

// خريطة بريد→مستخدم (تطابق index.html / admin-users.js)
const AUTH_EMAIL_MAP = { abdullah: 'abdullah@aldeyabi.com', mostafa: 'supply@aldeyabi.com', mahmoud: 'mahmoud@aldeyabi.com' };
const emailToUsername = (email) => {
  const e = String(email || '').toLowerCase();
  for (const [u, m] of Object.entries(AUTH_EMAIL_MAP)) { if (m.toLowerCase() === e) return u; }
  return e.split('@')[0];
};
// تحقّق أن المستدعي موظف نشط (جلسة Supabase صالحة + سجل في proc_users).
// يُعيد بريد الموظف عند النجاح (يُستخدم كمستقبِل للبريد التجريبي)، وإلا null.
async function verifyStaff(env, base, jwt) {
  try {
    const r = await fetch(`${base}/auth/v1/user`, { headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${jwt}` } });
    if (!r.ok) return null;
    const u = await r.json();
    if (!u || !u.email) return null;
    const uname = emailToUsername(u.email);
    const safe = String(uname).replace(/[\\%_]/g, (c) => '\\' + c);
    const svc = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` };
    const pr = await fetch(`${base}/rest/v1/proc_users?username=ilike.${encodeURIComponent(safe)}&select=username,role,active`, { headers: svc });
    if (!pr.ok) return null;
    const rows = await pr.json();
    const prof = (rows || []).find((x) => String(x.username).toLowerCase() === String(uname).toLowerCase());
    return (prof && prof.active !== false) ? String(u.email) : null;
  } catch (_) { return null; }
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
  const id = String(payload?.id || '').trim();
  const event = String(payload?.event || '').trim();

  // ── بريد تجريبي: يُرسَل حصراً إلى بريد الموظف المستدعي (لا يقبل أي عنوان من العميل) ──
  if (event === 'test') {
    const tbase = env.SUPABASE_URL;
    const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);
    const staffEmail = await verifyStaff(env, tbase, jwt);
    if (!staffEmail) return json({ error: 'غير مصرّح' }, 403);
    const status = EVENTS.has(payload?.status) ? payload.status : 'received';
    const tpl = (payload && payload.tpl && typeof payload.tpl === 'object') ? payload.tpl : null;
    let origin = ''; try { origin = new URL(request.headers.get('origin') || request.headers.get('referer')).origin; } catch (_) {}
    const resumeUrl = status === 'needs_revision' ? `${origin}/register.html?resume=reg_demo&t=demo` : '';
    const trackUrl = origin ? `${origin}/register.html?track=DG-DEMO12` : '';
    const sampleRow = { legal_name_ar: 'شركة النور للمقاولات (تجربة)', legal_name_en: 'Al-Noor Contracting Co. (Test)' };
    const sampleRev = status === 'needs_revision'
      ? { general: 'يرجى تحديث السجل التجاري بنسخة سارية المفعول.', fields: ['cr', 'vat'], sections: ['contact_info'] }
      : null;
    let { subject, html } = buildEmail(status, sampleRow, 'DG-DEMO12', resumeUrl, tpl, sampleRev, trackUrl);
    subject = '[تجربة] ' + subject;
    try {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: env.NOTIFY_FROM, to: [staffEmail], subject, html, ...(env.NOTIFY_REPLY_TO ? { reply_to: env.NOTIFY_REPLY_TO } : {}) }),
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
    if (!(await verifyStaff(env, base, jwt))) return json({ error: 'غير مصرّح' }, 403);
  }
  const headers = {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    'Content-Type': 'application/json',
  };

  // اقرأ الحقول العامة فقط من سجل الطلب (لا وثائق)
  let row;
  try {
    const cols = 'id,legal_name_ar,legal_name_en,email,contact_email,status,revision_token,review_notes';
    const r = await fetch(
      `${base}/rest/v1/proc_supplier_registrations?id=eq.${encodeURIComponent(id)}&select=${cols}`,
      { headers });
    if (!r.ok) return json({ error: 'تعذّر جلب الطلب' }, 502);
    const rows = await r.json();
    row = Array.isArray(rows) ? rows[0] : null;
  } catch (_) { return json({ error: 'تعذّر الاتصال بقاعدة البيانات' }, 502); }
  if (!row) return json({ error: 'الطلب غير موجود' }, 404);

  // تحقّق من تطابق الحالة (منع الانتحال)
  const expectStatus = event === 'received' ? 'pending' : event;
  if (String(row.status) !== expectStatus) {
    return json({ skipped: true, reason: 'status_mismatch', status: row.status });
  }

  const to = (row.email || row.contact_email || '').trim();
  if (!to || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) {
    return json({ skipped: true, reason: 'no_recipient' });
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

  const { subject, html } = buildEmail(event, row, id, resumeUrl, custom, revisionInfo, trackUrl);

  // أرسل عبر Resend
  try {
    const body = {
      from: env.NOTIFY_FROM,
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
      return json({ error: 'تعذّر إرسال البريد', detail: t.slice(0, 300) }, 502);
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
    ar: `شكراً لتسجيلكم كمورد لدى مجموعة الذيابي. تم استلام طلبكم بنجاح وهو الآن قيد المراجعة من فريق إدارة العمليات وسلاسل الإمداد. سنتواصل معكم خلال 3–5 أيام عمل.\n\nيمكنكم متابعة حالة الطلب في أي وقت عبر بوابة الموردين باستخدام رقم الطلب أدناه.`,
    en: `Thank you for registering as a supplier with Al-Deyabi Group. Your application has been received and is now under review by our Operations & Supply Chain team. We will contact you within 3–5 business days.\n\nYou can track your application status anytime via the supplier portal using the application number below.`,
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
  return String(t == null ? '' : t)
    .replace(/\{name_en\}/g, v.name_en).replace(/\{name\}/g, v.name).replace(/\{id\}/g, v.id);
}
function paragraphs(text, style) {
  return String(text || '').split(/\n{2,}/).filter(s => s.trim() !== '')
    .map(p => `<p style="${style}">${esc(p).replace(/\n/g, '<br>')}</p>`).join('');
}

function buildEmail(event, row, id, resumeUrl, custom, revisionInfo, trackUrl) {
  const nameAr = row.legal_name_ar || row.legal_name_en || 'المورد الكريم';
  const nameEn = row.legal_name_en || row.legal_name_ar || 'Valued Supplier';
  const D = DEFAULTS[event] || DEFAULTS.received;
  const c = custom || {};
  const revBox = revisionInfo ? renderRevisionBox(revisionInfo) : '';
  // كتلة تتبّع الطلب + تنبيه البريد التلقائي (تظهر في كل الرسائل)
  const trackBlock = trackUrl ? `
          <div style="background:#eef4ff;border:1px solid #cdddff;border-radius:12px;padding:16px;margin:14px 0;text-align:center">
            <a href="${esc(trackUrl)}" style="display:inline-block;background:${BRAND.navy};color:#fff;text-decoration:none;font-weight:700;padding:11px 24px;border-radius:9px;font-size:14px">تتبّع حالة الطلب · Track your application</a>
            <p style="font-size:12.5px;color:${BRAND.soft};margin:11px 0 0;line-height:1.7">تابع حالة طلبك في أي وقت برقم الطلب أعلاه. وستصلك رسالة تلقائية عند أي تحديث على حالته.<br>Track your status anytime using the application number above. You'll automatically receive an email whenever your application status is updated.</p>
          </div>` : '';

  const subjectRaw = (c.subject && String(c.subject).trim()) ? c.subject : D.subject;
  const arRaw = (c.ar && String(c.ar).trim()) ? c.ar : D.ar;
  const enRaw = (c.en && String(c.en).trim()) ? c.en : D.en;

  const subject = fillVars(subjectRaw, { name: nameAr, name_en: nameEn, id });
  const arHtml = paragraphs(fillVars(arRaw, { name: nameAr, name_en: nameEn, id }), `font-size:14.5px;line-height:1.9;margin:6px 0;color:${BRAND.ink};direction:rtl;text-align:right`);
  const enHtml = paragraphs(fillVars(enRaw, { name: nameEn, name_en: nameEn, id }), `font-size:13.5px;line-height:1.8;margin:6px 0;color:${BRAND.ink};direction:ltr;text-align:left`);

  const cta = resumeUrl
    ? `<tr><td style="padding:8px 0 4px">
         <a href="${esc(resumeUrl)}" style="display:inline-block;background:${BRAND.gold};color:#fff;text-decoration:none;font-weight:700;padding:12px 26px;border-radius:10px;font-size:15px">فتح الطلب وتعديله · Open &amp; edit</a>
       </td></tr>`
    : '';

  const html = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:${BRAND.wash};font-family:'Segoe UI',Tahoma,Arial,sans-serif;color:${BRAND.ink}">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${BRAND.wash};padding:24px 12px">
    <tr><td align="center">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#fff;border:1px solid ${BRAND.line};border-radius:16px;overflow:hidden">
        <tr><td style="background:${BRAND.navy};padding:26px 30px">
          <div style="color:#fff;font-size:12px;letter-spacing:.12em;text-transform:uppercase;opacity:.8">AL-DEYABI GROUP · بوابة الموردين</div>
          <div style="color:#fff;font-size:21px;font-weight:800;margin-top:6px">إشعار حالة طلب التسجيل</div>
        </td></tr>
        <tr><td style="height:4px;background:${BRAND.gold}"></td></tr>
        <tr><td dir="rtl" style="padding:30px;text-align:right">
          <span style="display:inline-block;background:${D.badge[2]}1a;color:${D.badge[2]};font-weight:700;font-size:13px;padding:7px 16px;border-radius:999px">${esc(D.badge[0])} · ${esc(D.badge[1])}</span>

          <h2 style="font-size:17px;margin:18px 0 6px;color:${BRAND.navy}">${esc(nameAr)}</h2>
          ${arHtml}
          ${revBox}
          <table role="presentation" cellpadding="0" cellspacing="0" style="margin:14px 0">${cta}</table>

          <div style="background:${BRAND.wash};border:1px solid ${BRAND.line};border-radius:10px;padding:12px 16px;margin:14px 0">
            <span style="font-size:12px;color:${BRAND.soft}">رقم الطلب · Application No.</span><br>
            <span style="font-size:15px;font-weight:700;direction:ltr;display:inline-block;color:${BRAND.navy}">${esc(id)}</span>
          </div>
          ${trackBlock}

          <hr style="border:none;border-top:1px solid ${BRAND.line};margin:22px 0">
          <div dir="ltr" style="text-align:left">
            <h3 style="font-size:15px;margin:0 0 6px;color:${BRAND.navy}">${esc(nameEn)}</h3>
            ${enHtml}
          </div>
        </td></tr>
        <tr><td style="background:${BRAND.navy};padding:18px 30px;text-align:center">
          <div style="color:#fff;opacity:.85;font-size:12px">مجموعة الذيابي · Al-Deyabi Group · Operations &amp; Supply Chain</div>
          <div style="color:#fff;opacity:.55;font-size:11px;margin-top:4px">هذه رسالة آلية — يرجى عدم الرد عليها مباشرة · This is an automated message.</div>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;

  return { subject, html };
}

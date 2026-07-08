/**
 * Cloudflare Pages Function — إرسال دعوة تسجيل مورد عبر Resend.
 * ════════════════════════════════════════════════════════════════════════
 * مستقلّة تماماً: لا تلمس أي نظام (proc_/pr_/portal_) ولا أي قاعدة بيانات —
 * ترسل قالب الدعوة ثنائي اللغة (نفس تصميم supplier-invitation-bilingual.html)
 * لأي بريد مورد خارجي عبر Resend فقط.
 *
 * POST /api/invite-supplier   { email, name?, token }
 *   - token يجب أن يطابق env.INVITE_TOKEN (حماية من الإساءة/السبام).
 *   - same-origin فقط.
 *   - المُرسِل: noreply@suppliers.aldeyabi.com (النطاق الموثّق) — reply-to: supply@aldeyabi.com.
 */

const SENDER_DOMAIN = 'suppliers.aldeyabi.com';
const DEFAULT_FROM = `مجموعة الذيابي — بوابة الموردين <notifications@${SENDER_DOMAIN}>`;
const DEFAULT_REPLY_TO = 'supply@aldeyabi.com';
const REGISTER_URL = 'https://aldeyabi.com/suppliers';

function fromAddress(env) {
  const f = String((env && env.NOTIFY_FROM) || '').trim();
  if (f && f.toLowerCase().includes('@' + SENDER_DOMAIN) && !/no-?reply/i.test(f)) return f;
  return DEFAULT_FROM;
}
function replyTo(env) {
  const r = String((env && env.NOTIFY_REPLY_TO) || '').trim();
  return r || DEFAULT_REPLY_TO;
}
function htmlToText(html) {
  return String(html || '')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&larr;/g, '<-').replace(/&ldquo;|&rdquo;/g, '"')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ').trim();
}
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
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/* قالب الدعوة — نسخة Outlook (نفس supplier-invitation-bilingual.html بالضبط) */
function inviteHtml() {
  return `<!DOCTYPE html>
<html dir="rtl" lang="ar" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<title>دعوة التسجيل كمورد معتمد — مجموعة الذيابي</title>
<!--[if mso]><style>body,table,td,a{font-family:Tahoma,Arial,sans-serif !important}</style><![endif]-->
</head>
<body style="margin:0;padding:0;background:#e9e5dd;font-family:'Segoe UI',Tahoma,Arial,sans-serif;color:#1b2333;-webkit-text-size-adjust:100%;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#e9e5dd" style="background:#e9e5dd;padding:28px 12px;">
<tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" bgcolor="#ffffff" style="width:600px;max-width:600px;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 10px 40px rgba(15,26,46,.12);">
  <tr><td bgcolor="#16243d" style="background:#16243d;background:linear-gradient(135deg,#16243d,#22355a);padding:30px 40px;text-align:center;">
    <div style="color:#E9D9B4;font-size:12px;letter-spacing:.1em;text-transform:uppercase;">AL-DEYABI GROUP</div>
    <div style="color:#ffffff;font-size:22px;font-weight:800;margin-top:8px;">مجموعة الذيابي</div>
  </td></tr>
  <tr><td height="4" bgcolor="#c2a063" style="height:4px;background:#c2a063;background:linear-gradient(90deg,#876734,#c2a063,#876734);font-size:0;line-height:0;">&nbsp;</td></tr>
  <tr><td style="padding:30px 40px 4px;text-align:center;">
    <p style="margin:0;font-size:16px;line-height:1.9;color:#2a3346;font-weight:600;">يسعد <b style="color:#16243d;">مجموعة الذيابي</b> دعوتكم للانضمام إلى منظومة الموردين المعتمدين.</p>
    <p dir="ltr" style="margin:10px 0 0;font-size:13.5px;line-height:1.7;color:#93a0b3;"><b style="color:#5c6678;">Al-Deyabi Group</b> is pleased to invite you to join our network of approved suppliers.</p>
  </td></tr>
  <tr><td style="padding:24px 40px 6px;">
    <div style="font-size:13px;font-weight:700;color:#a37f43;text-align:center;letter-spacing:1px;margin-bottom:3px;">خطوات التسجيل</div>
    <div dir="ltr" style="font-size:11px;font-weight:600;color:#a8a08e;text-align:center;letter-spacing:1.5px;margin-bottom:20px;">REGISTRATION STEPS</div>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:15px;"><tr>
      <td width="24" valign="top" style="width:24px;padding-top:3px;"><div style="color:#c2a063;font-size:16px;line-height:1;">&#9679;</div></td>
      <td valign="top" style="padding-right:12px;">
        <div style="font-size:15.5px;font-weight:700;color:#16243d;">ادخل موقع مجموعة الذيابي</div>
        <div dir="ltr" style="font-size:13px;font-weight:600;color:#a37f43;margin-top:2px;">Visit the Al-Deyabi Group website</div>
        <div style="font-size:13.5px;color:#5c6678;line-height:1.7;margin-top:3px;">افتح الموقع الإلكتروني الرسمي عبر الرابط: <span style="color:#a37f43;font-weight:600;" dir="ltr">aldeyabi.com</span></div>
        <div dir="ltr" style="font-size:12px;color:#93a0b3;margin-top:3px;">Open the official website at <span style="color:#a37f43;font-weight:600;">aldeyabi.com</span></div>
      </td></tr></table>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:15px;"><tr>
      <td width="24" valign="top" style="width:24px;padding-top:3px;"><div style="color:#c2a063;font-size:16px;line-height:1;">&#9679;</div></td>
      <td valign="top" style="padding-right:12px;">
        <div style="font-size:15.5px;font-weight:700;color:#16243d;">اضغط على «التسجيل كمورد»</div>
        <div dir="ltr" style="font-size:13px;font-weight:600;color:#a37f43;margin-top:2px;">Click &ldquo;Register as a Supplier&rdquo;</div>
        <div style="font-size:13.5px;color:#5c6678;line-height:1.7;margin-top:3px;">من القائمة العلوية في الموقع، اختر <b>التسجيل كمورد</b> للوصول إلى بوابة الموردين.</div>
        <div dir="ltr" style="font-size:12px;color:#93a0b3;margin-top:3px;">From the top menu, select <b style="color:#5c6678;">Register as a Supplier</b> to access the suppliers portal.</div>
      </td></tr></table>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:6px;"><tr>
      <td width="24" valign="top" style="width:24px;padding-top:3px;"><div style="color:#c2a063;font-size:16px;line-height:1;">&#9679;</div></td>
      <td valign="top" style="padding-right:12px;">
        <div style="font-size:15.5px;font-weight:700;color:#16243d;">ابدأ التسجيل وأرفق وثائقكم</div>
        <div dir="ltr" style="font-size:13px;font-weight:600;color:#a37f43;margin-top:2px;">Start registration and attach your documents</div>
        <div style="font-size:13.5px;color:#5c6678;line-height:1.7;margin-top:3px;">اضغط <b>ابدأ التسجيل الآن</b>، واملأ النموذج الإلكتروني وأرفق الوثائق النظامية. يستغرق نحو ١٠ دقائق.</div>
        <div dir="ltr" style="font-size:12px;color:#93a0b3;margin-top:3px;">Click <b style="color:#5c6678;">Start Registration Now</b>, fill in the online form and attach the required legal documents. It takes about 10 minutes.</div>
      </td></tr></table>
  </td></tr>
  <tr><td style="padding:20px 40px 30px;text-align:center;">
    <table role="presentation" cellpadding="0" cellspacing="0" align="center"><tr>
      <td bgcolor="#a37f43" style="border-radius:10px;background:#a37f43;background:linear-gradient(180deg,#c2a063,#a37f43);box-shadow:0 6px 16px rgba(163,127,67,.30);">
        <a href="${REGISTER_URL}" target="_blank" style="display:inline-block;padding:12px 34px;font-size:14.5px;font-weight:800;color:#ffffff;text-decoration:none;letter-spacing:.2px;">ابدأ التسجيل كمورد &nbsp;·&nbsp; <span dir="ltr">Start Supplier Registration</span> &larr;</a>
      </td></tr></table>
  </td></tr>
  <tr><td style="padding:0 40px 26px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#faf8f2" style="background:#faf8f2;border:1px solid #eee6d6;border-radius:12px;">
      <tr><td style="padding:18px 22px;">
        <div style="font-size:13px;font-weight:700;color:#16243d;margin-bottom:2px;">مزايا التسجيل معنا</div>
        <div dir="ltr" style="font-size:11.5px;font-weight:600;color:#a8a08e;margin-bottom:12px;letter-spacing:.5px;">Benefits of Registering With Us</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:13px;color:#4a5265;line-height:1.6;">
          <tr>
            <td width="50%" valign="top" style="padding:4px 0;">✓ الإدراج في قاعدة الموردين المعتمدين<div dir="ltr" style="font-size:11px;color:#9aa3b2;margin-top:1px;">Listing in the approved suppliers database</div></td>
            <td width="50%" valign="top" style="padding:4px 0;">✓ فرص المشاركة في المناقصات والمشتريات<div dir="ltr" style="font-size:11px;color:#9aa3b2;margin-top:1px;">Opportunities in tenders and procurement</div></td>
          </tr>
          <tr>
            <td width="50%" valign="top" style="padding:4px 0;">✓ الوصول لخمسة قطاعات متخصصة<div dir="ltr" style="font-size:11px;color:#9aa3b2;margin-top:1px;">Access to five specialized sectors</div></td>
            <td width="50%" valign="top" style="padding:4px 0;">✓ مراجعة واعتماد سريع وشراكة موثوقة<div dir="ltr" style="font-size:11px;color:#9aa3b2;margin-top:1px;">Fast review, approval, and a trusted partnership</div></td>
          </tr>
        </table>
      </td></tr></table>
  </td></tr>
  <tr><td bgcolor="#16243d" style="background:#16243d;padding:24px 40px;text-align:center;">
    <div style="color:#e9dfca;font-size:14px;font-weight:700;">مجموعة الذيابي للمقاولات</div>
    <div dir="ltr" style="color:#b7a67f;font-size:11.5px;font-weight:600;margin-top:2px;letter-spacing:.5px;">Al-Deyabi Contracting Group</div>
    <div style="color:#8fa0bb;font-size:12px;margin-top:8px;line-height:1.8;">نبني مستقبلاً آمناً ومزدهراً · حلول متكاملة عبر خمسة قطاعات<br><span dir="ltr" style="color:#7385a3;">Building a safe and prosperous future · Integrated solutions across five sectors</span><br><span dir="ltr">920000194</span> &nbsp;·&nbsp; info@aldeyabi.com &nbsp;·&nbsp; <span dir="ltr">aldeyabi.com</span></div>
    <div style="color:#5f708c;font-size:10.5px;margin-top:14px;letter-spacing:1px;">ISO 9001 · ISO 45001 · ISO 41001</div>
  </td></tr>
</table>
<div style="max-width:600px;margin:16px auto 0;font-size:11px;color:#9a9488;text-align:center;line-height:1.6;">هذه الرسالة موجّهة للموردين الراغبين في التسجيل لدى مجموعة الذيابي. إن وصلتك عن طريق الخطأ فتجاهلها.<br><span dir="ltr">This message is intended for suppliers wishing to register with Al-Deyabi Group. If you received it by mistake, please disregard it.</span></div>
</td></tr>
</table>
</body>
</html>`;
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'forbidden' }, 403);
  if (!env.RESEND_API_KEY) return json({ error: 'email_not_configured', detail: 'RESEND_API_KEY مفقود' }, 500);

  let body = {};
  try { body = await request.json(); } catch (_) { return json({ error: 'bad_json' }, 400); }

  const email = String(body.email || '').trim().toLowerCase();
  if (!EMAIL_RE.test(email)) return json({ error: 'bad_email', detail: 'بريد غير صالح' }, 400);

  // معاينة داخلية: بُرد @aldeyabi.com + بريد المالك للمعاينة تُرسَل بلا رمز؛ البُرد الخارجية (الموردون) تتطلّب INVITE_TOKEN.
  const PREVIEW_ALLOW = ['511avolo@gmail.com'];
  const isInternal = /@aldeyabi\.com$/i.test(email) || PREVIEW_ALLOW.includes(email);
  if (!isInternal) {
    if (!env.INVITE_TOKEN) return json({ error: 'not_configured', detail: 'INVITE_TOKEN غير مضبوط في Cloudflare (مطلوب للبُرد الخارجية)' }, 500);
    const token = String(body.token || '');
    if (token.length !== String(env.INVITE_TOKEN).length || token !== String(env.INVITE_TOKEN)) {
      return json({ error: 'unauthorized', detail: 'رمز الإرسال غير صحيح' }, 401);
    }
  }

  const subject = 'دعوة التسجيل كمورد معتمد — مجموعة الذيابي · Supplier Registration Invitation';
  const html = inviteHtml();

  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: fromAddress(env), to: [email], subject, html, text: htmlToText(html), reply_to: replyTo(env) }),
  });
  if (!r.ok) {
    const t = await r.text().catch(() => '');
    return json({ error: 'send_failed', status: r.status, detail: t.slice(0, 300) }, 502);
  }
  return json({ ok: true, sent_to: email });
}

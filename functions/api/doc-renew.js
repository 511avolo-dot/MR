/**
 * Cloudflare Pages Function — طلب تجديد وثيقة مورّد منتهية/مقاربة على الانتهاء
 * ════════════════════════════════════════════════════════════════════════════
 * قرار المالك (2026-09-07): «السجلات والأوراق التي ستنتهي — يُرسَل بريد من Resend
 * برفع المستند الجديد بتاريخه الجديد واستبدال القديم.»
 *
 * ثلاث نقاط في ملف واحد:
 *   1) POST /api/doc-renew              (موظّف مُصادَق، same-origin)
 *      body: { reg_id, docs: ['cr','chamber'] }
 *      → يبني رمزاً موقَّعاً، ويرسل بريداً للمورّد برابط تحديث واحد يغطّي الوثائق المطلوبة.
 *   2) GET  /api/doc-renew?t=<token>    (عام — للصفحة `renew-doc.html`)
 *      → يعيد اسم المنشأة والوثائق المطلوبة وتواريخها الحالية. لا يكشف أي بيانات أخرى.
 *   3) POST /api/doc-renew?t=<token>&doc=cr&expiry=YYYY-MM-DD   (عام، body = بايتات الملف)
 *      → يفحص الملف بالحارس الطبقي، يرفعه إلى R2، ثم **يستبدل مؤشّر الوثيقة**
 *        في صفّ التسجيل ويحدّث تاريخ الانتهاء.
 *
 * ── لماذا رمز موقَّع (HMAC) بلا جدول ولا عمود جديد ──
 *   لا حاجة لأي تغيير في المخطّط: الرمز يحمل حمولته موقَّعة على الخادم
 *   `base64url(payload).base64url(HMAC-SHA256)`، فيُتحقَّق منه حسابيّاً لا بالبحث.
 *   المفتاح: `DOC_RENEW_SECRET` وإلا `CRON_SECRET` وإلا مفتاح الخدمة (كلها أسرار
 *   خادمية لا تغادر العامل؛ الـHMAC لا يكشف المفتاح).
 *
 * ── الاستبدال منطقيّ لا تدميريّ (قاعدة مثبَّتة في هذا النظام) ──
 *   الملف القديم **يبقى** في المخزن (سلامة الأدلّة — لا مسار في النظام يحذف وثيقة
 *   مورّد؛ راجع تدقيق SEC-06 في `reg-doc.js`)، والصفّ يشير للجديد، ومسار القديم
 *   يُحفظ في سجلّ التدقيق `proc_audit_log.old_value` فيبقى قابلاً للاسترجاع.
 *
 * ⚠️ متغيّرات Cloudflare: binding `SUPPLIER_DOCS` (R2) + `SUPABASE_URL` +
 *    `SUPABASE_SERVICE_ROLE_KEY` (لتحديث الصفّ) + `SUPABASE_ANON_KEY` (تحقّق جلسة
 *    الموظّف) + `RESEND_API_KEY` + `NOTIFY_FROM`/`PUBLIC_ORIGIN` (اختياريان).
 */
import { inspectUpload } from './_file-guard.js';

const REG_RE = /^DG-[A-Z0-9]{4,12}$/;
const TOKEN_TTL_DAYS = 21;
const MAX_UPLOADS_PER_DAY = 20;   // سقف مضادّ للإغراق لكل تسجيل (راجع recentUploadCount)

/* الوثائق التي تحمل تاريخ انتهاء في نموذج التسجيل — العمود مقصود وصريح لكل نوع.
   الأنواع الأخرى تُجدَّد بلا تاريخ (رفع نسخة أحدث فقط). */
const DOC_META = {
  cr:        { label: 'السجل التجاري',        expiryCol: 'cr_expiry_date' },
  chamber:   { label: 'شهادة الغرفة التجارية', expiryCol: 'chamber_expiry' },
  // شهادة المحتوى المحلي: عمود التاريخ **اختياريّ** — إن لم تُشغَّل الترقية بعد،
  // يُحفَظ المستند ويُتخطّى التاريخ بهدوء (راجع patchRow) بدل تعطيل الرفع.
  local_content: { label: 'شهادة المحتوى المحلي', expiryCol: 'local_content_expiry', optionalCol: true },
  vat:       { label: 'شهادة الزكاة/VAT',      expiryCol: null },
  gosi:      { label: 'شهادة التأمينات',       expiryCol: null },
  natl_addr: { label: 'العنوان الوطني',        expiryCol: null },
  iban_cert: { label: 'شهادة الآيبان',         expiryCol: null },
  municipal: { label: 'رخصة البلدية',          expiryCol: null },
  quality:   { label: 'شهادات الجودة',         expiryCol: null },
  safety:    { label: 'شهادات السلامة',        expiryCol: null },
};

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
const apiKey = (env) => env.SUPABASE_ANON_KEY || env.SUPABASE_SERVICE_ROLE_KEY || '';
const r2 = (env) => env.SUPPLIER_DOCS || null;
const configured = (env) => !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY);

/* المُرسِل من النطاق الموثّق (نفس اتفاقية notify.js — لا no-reply) */
function fromAddress(env) {
  const v = String(env.NOTIFY_FROM || '').trim();
  if (v && !/no-?reply/i.test(v)) return v;
  return 'Aldeyabi Group <notifications@suppliers.aldeyabi.com>';
}
function replyTo(env) {
  return String(env.NOTIFY_REPLY_TO || 'supply@aldeyabi.com').trim();
}
/* الأصل العامّ: `PUBLIC_ORIGIN` أولاً — لا نبني رابطاً من ترويسة يتحكّم بها الطالب
   إن كان المتغيّر مضبوطاً (نفس درس `portal-action.js`: تسريب رمز عبر Host مزوَّر). */
function publicOrigin(env, fallback) {
  const v = String(env.PUBLIC_ORIGIN || '').trim().replace(/\/+$/, '');
  if (/^https:\/\/[a-z0-9.-]+$/i.test(v)) return v;
  return fallback || '';
}
function htmlToText(html) {
  return String(html)
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n').replace(/<\/(p|div|tr|h[1-6])>/gi, '\n')
    .replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/\n{3,}/g, '\n\n').trim();
}

/* ── الرمز الموقَّع ─────────────────────────────────────────────────────── */
const b64urlEnc = (bytes) => {
  let s = '';
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const b64urlDec = (str) => {
  const s = String(str).replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(s + '='.repeat((4 - (s.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
};
function tokenSecret(env) {
  return String(env.DOC_RENEW_SECRET || env.CRON_SECRET || env.SUPABASE_SERVICE_ROLE_KEY || '');
}
async function hmac(env, data) {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(tokenSecret(env)),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data)));
}
async function signToken(env, payload) {
  const body = b64urlEnc(new TextEncoder().encode(JSON.stringify(payload)));
  return body + '.' + b64urlEnc(await hmac(env, body));
}
/* مقارنة ثابتة الزمن — لا تُسرِّب موضع أول اختلاف */
function timingSafeEq(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
async function verifyToken(env, token) {
  if (!tokenSecret(env)) return null;
  const parts = String(token || '').split('.');
  if (parts.length !== 2) return null;
  const expect = b64urlEnc(await hmac(env, parts[0]));
  if (!timingSafeEq(expect, parts[1])) return null;
  let p;
  try { p = JSON.parse(new TextDecoder().decode(b64urlDec(parts[0]))); } catch (_) { return null; }
  if (!p || !REG_RE.test(String(p.i || ''))) return null;
  if (!Array.isArray(p.d) || !p.d.length || !p.d.every(d => DOC_META[d])) return null;
  if (!p.e || Date.now() / 1000 > Number(p.e)) return null;
  return p;
}

/* ── قاعدة البيانات (مفتاح الخدمة) ─────────────────────────────────────── */
function svcHeaders(env) {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    'Content-Type': 'application/json',
  };
}
/* أعمدة قد لا تكون الترقية شُغِّلت لها بعد — طلبها يُفشِل الاستعلام كلّه في PostgREST،
   فنُعيد المحاولة بإسقاطها بدل كسر الصفحة (نمط OPTIONAL_COLS في register.html). */
const OPTIONAL_COLS = ['local_content_expiry'];
async function fetchReg(env, id, cols) {
  const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
  const get = (c) => fetch(
    `${base}/rest/v1/proc_supplier_registrations?id=eq.${encodeURIComponent(id)}&select=${c}`,
    { headers: svcHeaders(env) });
  let r = await get(cols);
  if (!r.ok && OPTIONAL_COLS.some(c => cols.includes(c))) {
    const trimmed = cols.split(',').filter(c => !OPTIONAL_COLS.includes(c.trim())).join(',');
    r = await get(trimmed);
  }
  if (!r.ok) return null;
  const rows = await r.json();
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}
/* عدد عمليات التجديد لهذا التسجيل خلال 24 ساعة — سقف مضادّ للإغراق.
   الرابط قد يُعاد توجيهه، فبلا سقف يمكن ملء المخزن برفع متكرّر طوال صلاحيته.
   يستعمل سجلّ التدقيق القائم (لا جدول ولا عمود جديد). فشل العدّ ⇒ نسمح
   (السقف حماية من الإساءة لا بوّابة أمنية؛ الأمن في الرمز والحارس). */
async function recentUploadCount(env, regId) {
  try {
    const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const r = await fetch(
      `${base}/rest/v1/proc_audit_log?entity_type=eq.supplier_doc&entity_id=eq.${encodeURIComponent(regId)}` +
      `&action=eq.edit&ts=gte.${encodeURIComponent(since)}&select=id`,
      { headers: { ...svcHeaders(env), Prefer: 'count=exact', Range: '0-0' } });
    const cr = r.headers.get('content-range') || '';
    const n = parseInt(String(cr).split('/')[1], 10);
    return isFinite(n) ? n : 0;
  } catch (_) { return 0; }
}

/* إشعار داخليّ للمراجعين بأن مورّداً حدّث وثيقة — يُغلق الحلقة:
   بلا هذا يمرّ الرفع صامتاً ولا يراه أحد إلا بزيارة اللوحة صدفةً. */
async function notifyReviewers(env, regId, company, docLabel, expiry) {
  try {
    const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
    const ur = await fetch(`${base}/rest/v1/proc_users?select=username,role,active,permissions&active=eq.true`,
      { headers: svcHeaders(env) });
    if (!ur.ok) return;
    const users = await ur.json();
    const recips = (Array.isArray(users) ? users : []).filter(
      u => u.username && (u.role === 'admin' || !u.permissions || u.permissions.can_review_registrations !== false));
    if (!recips.length) return;
    const rows = recips.map(u => ({
      id: 'ntf_' + Date.now() + '_' + Math.random().toString(36).slice(2, 7) + '_' + u.username,
      recipient: u.username, type: 'system',
      title: 'مورّد حدّث مستنداً',
      body: `${company} — ${docLabel}${expiry ? ` (ينتهي ${expiry})` : ''}`,
      link: 'registrations', read: false,
    }));
    await fetch(`${base}/rest/v1/proc_notifications`, {
      method: 'POST', headers: { ...svcHeaders(env), Prefer: 'return=minimal' }, body: JSON.stringify(rows),
    });
  } catch (_) { /* أفضل جهد — لا يُعطّل الرفع */ }
}

async function audit(env, entry) {
  try {
    const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
    await fetch(`${base}/rest/v1/proc_audit_log`, {
      method: 'POST',
      headers: { ...svcHeaders(env), Prefer: 'return=minimal' },
      body: JSON.stringify([entry]),
    });
  } catch (_) { /* التدقيق أفضل جهد — لا يُعطّل العملية */ }
}

/* تحقّق جلسة الموظّف — فشل مغلق (نفس نمط `reg-doc.js`) */
async function verifyStaff(env, request) {
  const base = String(env.SUPABASE_URL || '').replace(/\/+$/, '');
  const key = apiKey(env);
  if (!base || !key) return null;
  const auth = request.headers.get('authorization') || '';
  const jwt = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!jwt) return null;
  try {
    const r = await fetch(`${base}/auth/v1/user`, { headers: { apikey: key, Authorization: `Bearer ${jwt}` } });
    if (!r.ok) return null;
    const u = await r.json();
    return u && u.email ? u : null;
  } catch (_) { return null; }
}

/* ── البريد ────────────────────────────────────────────────────────────── */
const BRAND = { navy: '#0B1B36', gold: '#C4A265', ink: '#1f2937', muted: '#6b7280' };

function renewEmail(company, items, link) {
  const rows = items.map(it => `
    <tr>
      <td style="padding:9px 12px;border-bottom:1px solid #eef1f6;font-size:14px;color:${BRAND.ink}">${esc(it.label)}</td>
      <td style="padding:9px 12px;border-bottom:1px solid #eef1f6;font-size:13px;color:${it.expired ? '#b13434' : '#8a6d1f'};font-weight:700" dir="rtl">${esc(it.note)}</td>
    </tr>`).join('');
  const subject = `تحديث مستندات — ${company}`;
  const html = `<!doctype html><html dir="rtl" lang="ar"><body style="margin:0;background:#f4f6f9;font-family:'Segoe UI',Tahoma,Arial,sans-serif">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6f9;padding:24px 12px">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:14px;overflow:hidden;box-shadow:0 2px 12px rgba(11,27,54,.08)">
        <tr><td style="background:${BRAND.navy};padding:20px 24px">
          <div style="color:#ffffff;font-size:17px;font-weight:800">مجموعة الذيابي</div>
          <div style="color:${BRAND.gold};font-size:12px;margin-top:3px">إدارة المشتريات — تحديث مستندات المورّدين</div>
        </td></tr>
        <tr><td style="padding:24px">
          <div style="font-size:15px;color:${BRAND.ink};line-height:1.9">
            السادة / <b>${esc(company)}</b> المحترمين،<br>
            نفيدكم بأن المستندات التالية المسجّلة لديكم في نظامنا تحتاج إلى تحديث:
          </div>
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0;border:1px solid #eef1f6;border-radius:10px;overflow:hidden">
            ${rows}
          </table>
          <div style="font-size:14px;color:${BRAND.ink};line-height:1.9">
            يُرجى رفع <b>النسخة الجديدة</b> مع <b>تاريخ الانتهاء الجديد</b> عبر الزرّ أدناه — وستحلّ تلقائياً محلّ النسخة القديمة في ملفّكم لدينا،
            دون الحاجة إلى إعادة التسجيل أو إرسال المستندات بالبريد.
          </div>
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:20px 0 6px">
            <tr><td align="center" bgcolor="${BRAND.gold}" style="background:${BRAND.gold};border-radius:12px">
              <a href="${esc(link)}" style="display:block;padding:15px 18px;color:#ffffff;text-decoration:none;font-weight:800;font-size:15px">رفع المستند المحدَّث</a>
            </td></tr>
          </table>
          <div style="font-size:12px;color:${BRAND.muted};line-height:1.8;margin-top:10px">
            الرابط خاصّ بمنشأتكم وصالح لمدّة ${TOKEN_TTL_DAYS} يوماً. الصيغ المقبولة: PDF أو صورة (JPG/PNG) بحدّ أقصى 10 ميغابايت.<br>
            إن لم يعمل الزرّ، انسخ هذا الرابط في المتصفّح:<br>
            <span style="word-break:break-all;color:${BRAND.ink}">${esc(link)}</span>
          </div>
        </td></tr>
        <tr><td style="background:#f8fafc;padding:14px 24px;font-size:12px;color:${BRAND.muted};text-align:center">
          للاستفسار: <a href="mailto:supply@aldeyabi.com" style="color:${BRAND.navy}">supply@aldeyabi.com</a>
        </td></tr>
      </table>
    </td></tr>
  </table></body></html>`;
  return { subject, html };
}

/* أيام حتى تاريخ (سالب = انتهى) */
function daysTo(dateStr) {
  if (!dateStr) return null;
  const t = Date.parse(String(dateStr).slice(0, 10) + 'T00:00:00Z');
  if (!isFinite(t)) return null;
  return Math.round((t - Date.parse(new Date().toISOString().slice(0, 10) + 'T00:00:00Z')) / 86400000);
}

/* ══════════════════ التذكير المجدوَل (30/14/7 يوماً ثم دوريّاً) ══════════════
   بلا هذا يبقى التذكير يدويّاً: يتذكّر أحدهم فتح اللوحة والضغط. الآن يمرّ الكرون
   يوميّاً فيرسل التذكير في موعده تلقائيّاً.

   ── منع التكرار بلا جدول ولا عمود ──
   كل إرسال يُقيَّد أصلاً في `proc_audit_log` (action=notify · entity_type=supplier_doc)
   ومعه **وسم المرحلة**. فقبل أي إرسال نقرأ قيود آخر 60 يوماً ونتخطّى ما أُرسِل
   لنفس (التسجيل + المرحلة). فالمورّد يصله تذكير واحد لكل مرحلة، لا رسالة كل يوم.

   المراحل: d30 (≤30 يوماً) · d14 · d7 · exp<n> (بعد الانتهاء، كل أسبوعين)
   · gap<n> (نقص بلا تاريخ — تذكير شهريّ). الأعجل يحكم بريد المورّد الواحد. */
const SWEEP_MAX_PER_RUN = 40;      // سقف رسائل التشغيلة الواحدة
const SWEEP_MIN_HOURS = 20;        // لا تشغيلتان في اليوم ولو نُودي كل دقيقة
const SWEEP_LOOKBACK_DAYS = 60;

function stageFor(days) {
  if (days == null) return 'gap' + Math.floor(Date.now() / (30 * 86400000)); // نقص بلا تاريخ: شهريّاً
  if (days < 0) return 'exp' + Math.floor(-days / 14);                       // منتهٍ: كل أسبوعين
  if (days <= 7) return 'd7';
  if (days <= 14) return 'd14';
  if (days <= 30) return 'd30';
  return null;                                                              // بعيد — لا تذكير
}
/* الأعجل يحكم: منتهٍ ثمّ d7 ثمّ d14 ثمّ d30 ثمّ النقص */
const STAGE_RANK = (s) => s.startsWith('exp') ? 0 : s === 'd7' ? 1 : s === 'd14' ? 2 : s === 'd30' ? 3 : 4;

async function sweepReminders(env, request) {
  const secret = String(env.CRON_SECRET || '').trim();
  if (!secret) return json({ error: 'غير مهيّأ', reason: 'no_cron_secret' }, 503);
  const url = new URL(request.url);
  const auth = request.headers.get('authorization') || '';
  const given = auth.startsWith('Bearer ') ? auth.slice(7).trim() : String(url.searchParams.get('key') || '');
  if (!timingSafeEq(given, secret)) return json({ error: 'غير مصرّح' }, 401);
  if (!configured(env) || !env.RESEND_API_KEY || !tokenSecret(env)) {
    return json({ error: 'الخدمة غير مهيّأة', reason: 'not_configured' }, 503);
  }

  const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
  const since = new Date(Date.now() - SWEEP_LOOKBACK_DAYS * 86400000).toISOString();

  /* خانق التشغيل: قيد تدقيق واحد لكل تشغيلة — يمنع الإغراق لو نُودي كل دقيقة */
  const force = url.searchParams.get('force') === '1';
  if (!force) {
    try {
      const r = await fetch(`${base}/rest/v1/proc_audit_log?entity_type=eq.supplier_doc&action=eq.sweep` +
        `&ts=gte.${encodeURIComponent(new Date(Date.now() - SWEEP_MIN_HOURS * 3600000).toISOString())}` +
        `&select=id&limit=1`, { headers: svcHeaders(env) });
      const rows = r.ok ? await r.json() : [];
      if (Array.isArray(rows) && rows.length) return json({ ok: true, skipped: 'throttled' });
    } catch (_) { /* تعذّر القراءة ⇒ تابع (التكرار أهون من صمت دائم) */ }
  }

  // (1) الموردون المعتمدون + (2) ما سبق إرساله
  let regs = [], sentKeys = new Set();
  try {
    const cols = 'id,legal_name_ar,legal_name_en,email,contact_email,doc_paths,' +
                 'cr_expiry_date,chamber_expiry,local_content_has,local_content_expiry';
    const get = (c) => fetch(`${base}/rest/v1/proc_supplier_registrations?status=eq.approved&select=${c}&limit=2000`,
      { headers: svcHeaders(env) });
    let r = await get(cols);
    if (!r.ok) r = await get(cols.split(',').filter(c => !OPTIONAL_COLS.includes(c)).join(','));
    if (!r.ok) return json({ error: 'تعذّر جلب الموردين' }, 502);
    regs = await r.json();

    const ar = await fetch(`${base}/rest/v1/proc_audit_log?entity_type=eq.supplier_doc&action=eq.notify` +
      `&ts=gte.${encodeURIComponent(since)}&select=entity_id,new_value&limit=5000`, { headers: svcHeaders(env) });
    if (ar.ok) {
      for (const row of await ar.json()) {
        const st = row && row.new_value && row.new_value.stage;
        if (row && row.entity_id && st) sentKeys.add(row.entity_id + ':' + st);
      }
    }
  } catch (_) { return json({ error: 'تعذّر الاتصال بقاعدة البيانات' }, 502); }

  // (3) من يستحقّ تذكيراً الآن
  const due = [];
  for (const row of (Array.isArray(regs) ? regs : [])) {
    const paths = (row.doc_paths && typeof row.doc_paths === 'object') ? row.doc_paths : {};
    const items = [];
    for (const [key, meta] of Object.entries(DOC_META)) {
      if (!meta.expiryCol) continue;
      if (key === 'local_content' && row.local_content_has !== true) continue;
      const d = row[meta.expiryCol];
      const days = daysTo(d);
      // مُعلَنة/مطلوبة لكن بلا تاريخ أو بلا مرفق ⇒ نقص (days = null)
      const missing = (key === 'local_content') ? (!paths.local_content || !d) : !d;
      const st = stageFor(missing ? null : days);
      if (!st) continue;
      items.push({ key, label: meta.label, days: missing ? null : days, stage: st });
    }
    if (!items.length) continue;
    items.sort((a, b) => STAGE_RANK(a.stage) - STAGE_RANK(b.stage));
    const stage = items[0].stage;
    if (sentKeys.has(row.id + ':' + stage)) continue;
    const to = String(row.contact_email || row.email || '').trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) continue;
    due.push({ row, to, stage, items });
  }

  // (4) الإرسال (بسقف ومباعدة — مزوّد البريد يحدّ المعدّل)
  let sent = 0; const failures = [];
  const exp = Math.floor(Date.now() / 1000) + TOKEN_TTL_DAYS * 86400;
  for (const d of due.slice(0, SWEEP_MAX_PER_RUN)) {
    const company = d.row.legal_name_ar || d.row.legal_name_en || d.row.id;
    const docs = d.items.map(i => i.key);
    const mailItems = d.items.map(i => ({
      label: i.label,
      note: i.days == null ? 'بيانات ناقصة' : (i.days < 0 ? `منتهية منذ ${Math.abs(i.days)} يوماً`
            : i.days === 0 ? 'تنتهي اليوم' : `تنتهي خلال ${i.days} يوماً`),
      expired: i.days != null && i.days < 0,
    }));
    const token = await signToken(env, { i: d.row.id, d: docs, e: exp });
    const link = `${publicOrigin(env, '')}/renew-doc.html?t=${encodeURIComponent(token)}`;
    const { subject, html } = renewEmail(company, mailItems, link);
    try {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: fromAddress(env), to: [d.to], subject, html, text: htmlToText(html), reply_to: replyTo(env) }),
      });
      if (!r.ok) { failures.push(d.row.id); continue; }
    } catch (_) { failures.push(d.row.id); continue; }
    sent++;
    await audit(env, {
      username: 'system', display_name: 'تذكير مجدوَل', user_role: 'system',
      action: 'notify', entity_type: 'supplier_doc', entity_id: d.row.id,
      new_value: { docs, to: d.to, stage: d.stage }, meta: { kind: 'doc_renewal_request', scheduled: true },
    });
    await new Promise(z => setTimeout(z, 300));
  }

  await audit(env, {
    username: 'system', display_name: 'تذكير مجدوَل', user_role: 'system',
    action: 'sweep', entity_type: 'supplier_doc', entity_id: 'sweep',
    new_value: { candidates: due.length, sent, failed: failures.length }, meta: { kind: 'doc_renewal_sweep' },
  });
  return json({ ok: true, candidates: due.length, sent, failed: failures.length,
                capped: due.length > SWEEP_MAX_PER_RUN });
}

/* ══════════════════════════════ GET ══════════════════════════════════════
   بلا مُعامِلات = فحص صحّة · `?t=` = بيانات الطلب لصفحة المورّد
   · `?sweep=1` = التذكير المجدوَل (كرون بـCRON_SECRET). */
export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  if (url.searchParams.get('sweep') === '1') return sweepReminders(env, request);
  const t = url.searchParams.get('t');

  if (!t) {
    return json({
      ok: !!(configured(env) && env.RESEND_API_KEY && r2(env) && tokenSecret(env)),
      checks: {
        r2_bucket: !!r2(env),
        supabase_url: !!env.SUPABASE_URL,
        service_key: !!env.SUPABASE_SERVICE_ROLE_KEY,
        api_key: !!apiKey(env),
        resend: !!env.RESEND_API_KEY,
        token_secret: !!tokenSecret(env),
        public_origin: !!publicOrigin(env, ''),
        cron_secret: !!String(env.CRON_SECRET || '').trim(),
      },
    });
  }

  const p = await verifyToken(env, t);
  if (!p) return json({ error: 'الرابط غير صالح أو انتهت صلاحيته' }, 403);
  if (!configured(env)) return json({ error: 'الخدمة غير مهيّأة' }, 503);

  const row = await fetchReg(env, p.i, 'id,legal_name_ar,legal_name_en,cr_expiry_date,chamber_expiry,local_content_expiry');
  if (!row) return json({ error: 'السجل غير موجود' }, 404);

  return json({
    ok: true,
    company: row.legal_name_ar || row.legal_name_en || row.id,
    docs: p.d.map(d => ({
      key: d,
      label: DOC_META[d].label,
      has_expiry: !!DOC_META[d].expiryCol,
      current_expiry: DOC_META[d].expiryCol ? (row[DOC_META[d].expiryCol] || null) : null,
    })),
  });
}

/* ══════════════════════════════ POST ═════════════════════════════════════
   `?t=` موجود ⇒ رفع المورّد للنسخة الجديدة (عام).
   بلا `t` ⇒ طلب موظّف بإرسال بريد التجديد. */
export async function onRequestPost(ctx) {
  const url = new URL(ctx.request.url);
  if (url.searchParams.get('sweep') === '1') return sweepReminders(ctx.env, ctx.request);
  return url.searchParams.get('t') ? uploadRenewal(ctx, url) : sendRenewalRequest(ctx);
}

/* (1) الموظّف يطلب إرسال البريد */
async function sendRenewalRequest({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'طلب غير مصرّح به' }, 403);
  if (!configured(env)) return json({ error: 'الخدمة غير مهيّأة على الخادم', reason: 'not_configured' }, 503);
  if (!env.RESEND_API_KEY) return json({ error: 'خدمة البريد غير مهيّأة', reason: 'no_email' }, 503);
  if (!tokenSecret(env)) return json({ error: 'الخدمة غير مهيّأة', reason: 'no_secret' }, 503);

  const staff = await verifyStaff(env, request);
  if (!staff) return json({ error: 'غير مصرّح' }, 401);

  let body;
  try { body = await request.json(); } catch (_) { return json({ error: 'طلب غير صالح' }, 400); }
  const regId = String(body.reg_id || '').trim().toUpperCase();
  const docs = Array.isArray(body.docs) ? [...new Set(body.docs.map(d => String(d).trim().toLowerCase()))] : [];
  if (!REG_RE.test(regId)) return json({ error: 'رقم التسجيل غير صالح' }, 400);
  const valid = docs.filter(d => DOC_META[d]);
  if (!valid.length) return json({ error: 'لم تُحدَّد وثائق صالحة' }, 400);

  const row = await fetchReg(env, regId,
    'id,legal_name_ar,legal_name_en,email,contact_email,status,cr_expiry_date,chamber_expiry,local_content_expiry');
  if (!row) return json({ error: 'السجل غير موجود' }, 404);

  const to = String(row.contact_email || row.email || '').trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return json({ error: 'لا يوجد بريد صالح لهذا المورّد', reason: 'no_recipient' }, 400);

  const company = row.legal_name_ar || row.legal_name_en || row.id;
  const items = valid.map(d => {
    const col = DOC_META[d].expiryCol;
    const dd = col ? daysTo(row[col]) : null;
    let note = 'تحديث مطلوب';
    if (dd != null) note = dd < 0 ? `منتهية منذ ${Math.abs(dd)} يوماً` : (dd === 0 ? 'تنتهي اليوم' : `تنتهي خلال ${dd} يوماً`);
    return { key: d, label: DOC_META[d].label, note, expired: dd != null && dd < 0 };
  });

  const exp = Math.floor(Date.now() / 1000) + TOKEN_TTL_DAYS * 86400;
  const token = await signToken(env, { i: regId, d: valid, e: exp });

  let origin = '';
  try { origin = new URL(request.headers.get('origin') || request.headers.get('referer')).origin; } catch (_) {}
  origin = publicOrigin(env, origin);
  const link = `${origin}/renew-doc.html?t=${encodeURIComponent(token)}`;

  const { subject, html } = renewEmail(company, items, link);
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: fromAddress(env), to: [to], subject, html, text: htmlToText(html), reply_to: replyTo(env) }),
    });
    if (!r.ok) {
      const txt = await r.text().catch(() => '');
      return json({ error: 'تعذّر إرسال البريد', detail: txt.slice(0, 200) }, 502);
    }
  } catch (_) { return json({ error: 'تعذّر الاتصال بخدمة البريد' }, 502); }

  await audit(env, {
    username: staff.email, display_name: staff.email, user_role: 'staff',
    action: 'notify', entity_type: 'supplier_doc', entity_id: regId,
    new_value: { docs: valid, to, ttl_days: TOKEN_TTL_DAYS }, meta: { kind: 'doc_renewal_request' },
  });

  return json({ ok: true, sent_to: to, docs: valid });
}

/* (2) المورّد يرفع النسخة الجديدة */
async function uploadRenewal({ request, env }, url) {
  const p = await verifyToken(env, url.searchParams.get('t'));
  if (!p) return json({ error: 'الرابط غير صالح أو انتهت صلاحيته' }, 403);
  if (!configured(env)) return json({ error: 'الخدمة غير مهيّأة' }, 503);
  const bucket = r2(env);
  if (!bucket) return json({ error: 'تخزين الوثائق غير مهيّأ', reason: 'not_configured' }, 503);

  const doc = String(url.searchParams.get('doc') || '').trim().toLowerCase();
  if (!DOC_META[doc] || !p.d.includes(doc)) return json({ error: 'نوع الوثيقة غير مطلوب في هذا الرابط' }, 400);

  const expiryCol = DOC_META[doc].expiryCol;
  const expiry = String(url.searchParams.get('expiry') || '').trim();
  if (expiryCol) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(expiry)) return json({ error: 'تاريخ الانتهاء مطلوب بصيغة YYYY-MM-DD' }, 400);
    const dd = daysTo(expiry);
    if (dd == null) return json({ error: 'تاريخ غير صالح' }, 400);
    if (dd < 0) return json({ error: 'تاريخ الانتهاء الجديد يجب أن يكون مستقبليّاً' }, 400);
    if (dd > 365 * 10) return json({ error: 'تاريخ الانتهاء بعيد بشكل غير منطقيّ' }, 400);
  }

  if (await recentUploadCount(env, p.i) >= MAX_UPLOADS_PER_DAY) {
    return json({ error: 'تجاوزت الحدّ المسموح لليوم — تواصل مع إدارة المشتريات', reason: 'rate_limited' }, 429);
  }

  const buf = await request.arrayBuffer();
  const check = inspectUpload(buf);
  if (!check.ok) return json({ error: check.error, reason: 'rejected' }, 400);

  const row = await fetchReg(env, p.i, 'id,legal_name_ar,legal_name_en,doc_paths');
  if (!row) return json({ error: 'السجل غير موجود' }, 404);

  const rand = (globalThis.crypto && crypto.randomUUID) ? crypto.randomUUID() : ('r' + Date.now() + Math.random().toString(36).slice(2, 10));
  const path = `${p.i}/${doc}/${rand}.${check.ext}`;
  try {
    await bucket.put(path, buf, { httpMetadata: { contentType: check.ct } });
  } catch (e) {
    console.error('[doc-renew] r2_put_failed', (e && e.message) || e);
    return json({ error: 'تعذّر حفظ الملف' }, 502);
  }

  // استبدال منطقيّ: الصفّ يشير للجديد؛ القديم يبقى في المخزن ومساره في التدقيق.
  const prevPaths = (row.doc_paths && typeof row.doc_paths === 'object') ? row.doc_paths : {};
  const oldPath = prevPaths[doc] || null;
  const patch = { doc_paths: { ...prevPaths, [doc]: path } };
  if (expiryCol) patch[expiryCol] = expiry;

  const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
  const patchRow = async (obj) => fetch(
    `${base}/rest/v1/proc_supplier_registrations?id=eq.${encodeURIComponent(p.i)}`,
    { method: 'PATCH', headers: { ...svcHeaders(env), Prefer: 'return=minimal' }, body: JSON.stringify(obj) });

  let expirySaved = !!expiryCol;
  try {
    let r = await patchRow(patch);
    /* إعادة محاولة رشيقة للعمود الاختياريّ: إن لم تُشغَّل ترقية `local_content_expiry`
       بعد، يردّ PostgREST بخطأ العمود المفقود — عندها نحفظ **المستند** بلا التاريخ
       بدل خسارة الرفع كلّه (المستند أهمّ، والتاريخ يُضبط بعد الترقية). */
    if (!r.ok && expiryCol && DOC_META[doc].optionalCol) {
      const txt = await r.text().catch(() => '');
      if (/42703|column|does not exist/i.test(txt)) {
        const { [expiryCol]: _drop, ...rest } = patch;
        expirySaved = false;
        r = await patchRow(rest);
      } else {
        console.error('[doc-renew] patch_failed', r.status, txt.slice(0, 200));
        return json({ error: 'تعذّر تحديث السجل' }, 502);
      }
    }
    if (!r.ok) {
      const txt = await r.text().catch(() => '');
      console.error('[doc-renew] patch_failed', r.status, txt.slice(0, 200));
      return json({ error: 'تعذّر تحديث السجل' }, 502);
    }
  } catch (_) { return json({ error: 'تعذّر الاتصال بقاعدة البيانات' }, 502); }

  await audit(env, {
    username: 'supplier', display_name: p.i, user_role: 'supplier',
    action: 'edit', entity_type: 'supplier_doc', entity_id: p.i,
    old_value: { doc, path: oldPath }, new_value: { doc, path, expiry: expirySaved ? expiry : null },
    meta: { kind: 'doc_renewal_upload' },
  });
  await notifyReviewers(env, p.i, row.legal_name_ar || row.legal_name_en || p.i,
    DOC_META[doc].label, expirySaved ? expiry : '');

  return json({ ok: true, doc, label: DOC_META[doc].label,
    expiry: expirySaved ? expiry : null, expiry_saved: expirySaved });
}

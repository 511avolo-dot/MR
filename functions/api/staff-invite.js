/**
 * /api/staff-invite — دعوة موظفي القطاع للتسجيل الذاتيّ (النظام 2).
 *
 * طلب المالك: «رابط لدعوة موظفين ومدير الصيانة والتشغيل للدخول وتسجيل بياناتهم
 * لتوصلهم الإشعارات والمتابعة». وقراراته: **رابط واحد للقطاع** يُنشَر ·
 * **بريد الشركة حصراً** · **الحساب ينتظر تفعيل المالك**.
 *
 * ⚠️ المبدأ الحاكم: **الرابط المشترك لا يمنح صلاحية.** من يسجّل عبره يحصل على
 * حساب **موقوف** (`active=false`) بقطاعٍ يأتي من **الرمز الموقَّع** لا من العميل،
 * وبدور `user` وصلاحيات ميدانية ثابتة. فرابطٌ مسرَّب لا يفتح النظام لأحد —
 * أقصى أثره صفوف بانتظار المراجعة، وهي مسقوفة بعدد.
 *
 * الرمز موقَّع HMAC ويحمل حمولته (نمط `doc-renew.js`/`supplier-invite-link.js`):
 * **لا جدول رموز ولا هجرة**. والإبطال بمفتاح `staff_invite.epoch` في
 * `proc_settings`: أي رمز صدر قبله يسقط — فيُبطِل المالك كل الروابط بنقرة.
 *
 *   GET                      فحص صحّة (منطقيات وجود فقط، بلا قيم)
 *   GET  ?t=<token>          بيانات الدعوة للصفحة العامّة (القطاع والصلاحية — بلا PII)
 *   POST {action:'mint'}     أدمن مُصادَق same-origin ⇒ يسكّ رابط القطاع
 *   POST {action:'revoke'}   أدمن ⇒ يُبطل كل الروابط الصادرة
 *   POST ?t=<token>          تسجيل عامّ محكوم بالرمز
 */
import { svcHeaders, sendResend, emailToUsername, publicOrigin, esc, BRAND } from './_pr-shared.js';

const COMPANY_DOMAIN = 'aldeyabi.com';
const EMAIL_RE = /^[a-z0-9._%+-]+@aldeyabi\.com$/i;
const DEFAULT_DAYS = 14;
const MAX_DAYS = 60;
/* سقف الصفوف المعلّقة لكل قطاع: رابطٌ مسرَّب لا يستطيع إغراق اللوحة. */
const MAX_PENDING_PER_SECTOR = 40;

/* صلاحيات الموظّف الميدانيّ — **ثابتة هنا لا تأتي من العميل**. المبالغ محجوبة
   افتراضاً بقرار المالك، والاستلام ممنوح لأنّه جوهر عمله. أي توسعة يمنحها
   المالك بنفسه من لوحة المستخدمين بعد التفعيل. */
const FIELD_PERMISSIONS = { can_receive_po: true, can_view_amounts: false };

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
const configured = (env) => !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY);
/* نفس سلسلة الاحتياط في `doc-renew.js`: يعمل اليوم بلا أي متغيّر جديد. */
const secretOf = (env) =>
  env.STAFF_INVITE_SECRET || env.DOC_RENEW_SECRET || env.CRON_SECRET || env.SUPABASE_SERVICE_ROLE_KEY || '';

const b64u = {
  enc: (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''),
  dec: (s) => Uint8Array.from(atob(String(s).replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0)),
};
async function hmac(secret, msg) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64u.enc(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg)));
}
/* مقارنة ثابتة الزمن: لا تسرّب طول التطابق. */
function timingSafeEq(a, b) {
  const x = String(a), y = String(b);
  if (x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return d === 0;
}

async function mintToken(env, payload) {
  const body = b64u.enc(new TextEncoder().encode(JSON.stringify(payload)));
  return `${body}.${await hmac(secretOf(env), body)}`;
}
/** يتحقّق حسابيّاً ثم زمنيّاً ثم من الإبطال. فشل مغلق: أي خلل ⇒ null. */
async function readToken(env, token) {
  const parts = String(token || '').split('.');
  if (parts.length !== 2) return null;
  const expect = await hmac(secretOf(env), parts[0]);
  if (!timingSafeEq(expect, parts[1])) return null;
  let p = null;
  try { p = JSON.parse(new TextDecoder().decode(b64u.dec(parts[0]))); } catch (_) { return null; }
  if (!p || !p.s || !p.exp || !p.iat) return null;
  if (Date.now() > Number(p.exp)) return null;
  if (Number(p.iat) < await inviteEpoch(env)) return null;   // أُبطلت كل الروابط بعده
  return p;
}

/* لحظة الإبطال المخزَّنة في الإعدادات (0 = لم يُبطَل شيء). */
async function inviteEpoch(env) {
  const base = String(env.SUPABASE_URL || '').replace(/\/+$/, '');
  try {
    const r = await fetch(`${base}/rest/v1/proc_settings?key=eq.staff_invite&select=value`, { headers: svcHeaders(env) });
    const rows = await r.json();
    return Number(rows && rows[0] && rows[0].value && rows[0].value.epoch) || 0;
  } catch (_) { return 0; }
}

/** رمز جلسة المستدعي ⇒ صفّه في proc_users. فشل مغلق. */
async function callerProfile(env, request) {
  const base = String(env.SUPABASE_URL || '').replace(/\/+$/, '');
  const key = apiKey(env);
  const auth = request.headers.get('authorization') || '';
  const jwt = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!base || !key || !jwt) return null;
  try {
    const ur = await fetch(`${base}/auth/v1/user`, { headers: { apikey: key, Authorization: `Bearer ${jwt}` } });
    if (!ur.ok) return null;
    const u = await ur.json();
    if (!(u && u.email)) return null;
    const uname = emailToUsername(u.email);
    /* ⚠️ مطابقة **غير حسّاسة لحالة الأحرف** — وهذا ليس تجميلاً: الإنتاج يحمل
       صفَّين يختلفان بالحالة فقط (`Abdullah` أدمن نشط · `abdullah` مستخدم
       موقوف)، و`emailToUsername` تُعيد الاسم بحروف صغيرة. فـ`eq.` كانت تطابق
       **الصفّ الخاطئ** ⇒ المالك نفسه يُرفَض بـ403 عند توليد رابط الدعوة.
       (`admin-users.js` تعلّم الدرس بـ`ilike` — وهذا الملف فاته.)
       وتهريب أحرف البدل (% _ \) يمنع مطابقة أوسع تلتقط مستخدماً آخر. */
    const safe = String(uname).replace(/[\\%_]/g, (c) => '\\' + c);
    const pr = await fetch(
      `${base}/rest/v1/proc_users?username=ilike.${encodeURIComponent(safe)}&select=username,role,active`,
      { headers: svcHeaders(env) });
    if (!pr.ok) return null;
    const rows = await pr.json();
    const lower = String(uname).toLowerCase();
    /* ومع تعدّد المطابقات نختار **الأدمن النشط** صراحةً لا أوّل صفّ يعود —
       ترتيب PostgREST ليس عقداً، فاختيار «الأوّل» يجعل الصلاحية رهن الحظّ. */
    return (Array.isArray(rows) ? rows : []).find(
      (x) => String(x.username).toLowerCase() === lower
        && x.role === 'admin' && x.active !== false) || null;
  } catch (_) { return null; }
}

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const token = url.searchParams.get('t');
  if (!token) {
    return json({ ok: configured(env), checks: {
      supabase_url: !!env.SUPABASE_URL, service_key: !!env.SUPABASE_SERVICE_ROLE_KEY,
      api_key: !!apiKey(env), token_secret: !!secretOf(env), resend: !!env.RESEND_API_KEY } });
  }
  if (!configured(env)) return json({ error: 'الخدمة غير مهيّأة', reason: 'not_configured' }, 503);
  const p = await readToken(env, token);
  if (!p) return json({ error: 'الرابط غير صالح أو انتهت صلاحيته' }, 401);
  // لا PII: القطاع والصلاحية وشرط النطاق فقط.
  return json({ ok: true, sector: p.s, expires_at: new Date(Number(p.exp)).toISOString(), domain: COMPANY_DOMAIN });
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'طلب غير مصرّح به' }, 403);
  if (!configured(env)) return json({ error: 'الخدمة غير مهيّأة', reason: 'not_configured' }, 503);
  const base = String(env.SUPABASE_URL || '').replace(/\/+$/, '');
  const url = new URL(request.url);
  const token = url.searchParams.get('t');

  let body = {};
  try { body = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }

  /* ── المسار الإداريّ: سكّ رابط أو إبطال كل الروابط ── */
  if (!token) {
    const admin = await callerProfile(env, request);
    if (!admin) return json({ error: 'هذه العملية متاحة للمدير فقط' }, 403);

    if (body.action === 'revoke') {
      const now = Date.now();
      await fetch(`${base}/rest/v1/proc_settings`, {
        method: 'POST',
        headers: { ...svcHeaders(env), 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates' },
        body: JSON.stringify({ key: 'staff_invite', value: { epoch: now, by: admin.username } }),
      });
      return json({ ok: true, revoked_at: new Date(now).toISOString() });
    }

    if (body.action === 'mint') {
      const sector = String(body.sector || '').trim();
      if (!sector) return json({ error: 'القطاع مطلوب' }, 400);
      const days = Math.min(MAX_DAYS, Math.max(1, Number(body.days) || DEFAULT_DAYS));
      const now = Date.now();
      const t = await mintToken(env, { s: sector, iat: now, exp: now + days * 86400000, v: 1 });
      const origin = publicOrigin(env, url.origin);
      return json({ ok: true, url: `${origin}/staff-register.html?t=${encodeURIComponent(t)}`,
        sector, expires_at: new Date(now + days * 86400000).toISOString() });
    }
    return json({ error: 'إجراء غير معروف' }, 400);
  }

  /* ── المسار العامّ: تسجيل محكوم بالرمز ── */
  const p = await readToken(env, token);
  if (!p) return json({ error: 'الرابط غير صالح أو انتهت صلاحيته' }, 401);

  const displayName = String(body.display_name || '').trim();
  const email = String(body.email || '').trim().toLowerCase();
  const mobile = String(body.mobile || '').trim();
  const jobTitle = String(body.job_title || '').trim();
  const password = String(body.password || '');

  if (displayName.length < 3) return json({ error: 'الاسم الكامل مطلوب' }, 400);
  // ⚠️ بريد الشركة حصراً (قرار المالك): وهو أيضاً شرط وصول الإشعار — دالّة
  // `userEmail` في `_pr-shared.js` تُسقِط أي بريد خارج النطاق فلا يصل شيء.
  if (!EMAIL_RE.test(email)) return json({ error: `يجب استخدام بريد الشركة (@${COMPANY_DOMAIN})` }, 400);
  if (password.length < 8) return json({ error: 'كلمة المرور 8 أحرف على الأقل' }, 400);
  if (mobile && !/^[0-9+\-\s()]{7,20}$/.test(mobile)) return json({ error: 'رقم الجوال غير صالح' }, 400);

  const username = email.split('@')[0].replace(/[^a-z0-9_]/g, '').slice(0, 30);
  if (username.length < 2) return json({ error: 'تعذّر اشتقاق اسم مستخدم من بريدك' }, 400);

  try {
    // موجود مسبقاً؟ (بالاسم أو بالبريد) — لا نُنشئ نسخة ثانية ولا نُفشي حالته.
    const ex = await fetch(
      `${base}/rest/v1/proc_users?or=(username.eq.${encodeURIComponent(username)},email.eq.${encodeURIComponent(email)})&select=username,active`,
      { headers: svcHeaders(env) });
    const exRows = await ex.json();
    if (Array.isArray(exRows) && exRows.length) {
      return json({ ok: true, already: true,
        message: 'لديك حساب في النظام بالفعل. إن لم تستطع الدخول فراجع مدير النظام.' });
    }

    // سقف الصفوف المعلّقة **لهذا القطاع** — حزام أمان ضدّ إغراق اللوحة برابط
    // مسرَّب. ⚠️ كان الاستعلام بلا مرشّح قطاع فكان سقفاً عالميّاً يحتسب حتى
    // الحسابات الموقوفة القديمة، فيمنع قطاعاً بسبب قطاع آخر.
    const pend = await fetch(
      `${base}/rest/v1/proc_users?active=eq.false&created_by=eq.staff_invite`
      + `&scope_sectors=cs.${encodeURIComponent(JSON.stringify([p.s]))}`
      + `&select=username&limit=${MAX_PENDING_PER_SECTOR + 1}`,
      { headers: svcHeaders(env) });
    const pendRows = await pend.json();
    if (Array.isArray(pendRows) && pendRows.length > MAX_PENDING_PER_SECTOR) {
      return json({ error: 'تعذّر التسجيل الآن — راجع مدير النظام' }, 429);
    }

    // حساب الدخول (مؤكَّد البريد: الدعوة نفسها هي التحقّق)
    const au = await fetch(`${base}/auth/v1/admin/users`, {
      method: 'POST', headers: { ...svcHeaders(env), 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, email_confirm: true,
        user_metadata: { username, source: 'staff_invite' } }),
    });
    const auData = await au.json().catch(() => ({}));
    if (!au.ok && !/already|exists|registered/i.test(JSON.stringify(auData))) {
      return json({ error: 'تعذّر إنشاء حساب الدخول' }, 400);
    }

    /* ⚠️ كل الحقول الحوكمية مفروضة هنا لا من العميل: الدور `user`، والصلاحيات
       الميدانية الثابتة، والقطاع من **الرمز**، والحساب **موقوف** حتى يفعّله المالك. */
    const prof = await fetch(`${base}/rest/v1/proc_users`, {
      method: 'POST', headers: { ...svcHeaders(env), 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({
        username, display_name: displayName, email, mobile: mobile || null,
        job_title: jobTitle || null, password_hash: 'managed_by_supabase_auth',
        role: 'user', permissions: FIELD_PERMISSIONS, active: false,
        scope_sectors: [p.s], requested_role: 'field_staff',
        created_by: 'staff_invite',
        notes: `تسجيل ذاتيّ عبر رابط دعوة القطاع «${p.s}»`,
      }),
    });
    if (!prof.ok) {
      // لا نترك حساب دخول يتيماً يمنع إعادة المحاولة (نفس درس portal-register).
      try {
        const uid = auData && auData.id;
        if (uid) await fetch(`${base}/auth/v1/admin/users/${uid}`, { method: 'DELETE', headers: svcHeaders(env) });
      } catch (_) {}
      return json({ error: 'تعذّر حفظ بياناتك — حاول مرّة أخرى' }, 400);
    }

    // تنبيه المدراء ليُفعّلوا الحساب — وإلّا انتظر الموظّف بلا أن يعلم أحد.
    try { await notifyAdmins(env, base, { displayName, email, mobile, jobTitle, sector: p.s }); } catch (_) {}

    return json({ ok: true, pending: true });
  } catch (_) {
    return json({ error: 'تعذّر إتمام التسجيل' }, 500);
  }
}

async function notifyAdmins(env, base, info) {
  const r = await fetch(`${base}/rest/v1/proc_users?active=eq.true&role=eq.admin&select=username,email`,
    { headers: svcHeaders(env) });
  const rows = await r.json();
  const to = [...new Set((rows || [])
    .map((u) => (u.email && EMAIL_RE.test(u.email)) ? String(u.email).toLowerCase() : '')
    .filter(Boolean))];
  if (!to.length) return;
  const row = (k, v) => v
    ? `<tr><td style="padding:6px 10px;color:${BRAND.soft};font-size:13px">${esc(k)}</td>
         <td style="padding:6px 10px;font-size:13px;font-weight:600">${esc(v)}</td></tr>` : '';
  const html = `<div style="font-family:Segoe UI,Tahoma,Arial,sans-serif;direction:rtl;text-align:right;
      background:${BRAND.wash};padding:24px">
    <div style="max-width:520px;margin:0 auto;background:#fff;border:1px solid ${BRAND.line};border-radius:14px;overflow:hidden">
      <div style="background:${BRAND.navy};color:#fff;padding:18px 22px;font-weight:700">
        👤 تسجيل موظّف جديد بانتظار التفعيل</div>
      <div style="padding:18px 22px;color:${BRAND.ink};font-size:14px;line-height:1.8">
        سجّل موظّف بياناته عبر رابط دعوة القطاع، و<b>حسابه موقوف</b> حتى تُفعّله.
        <table style="width:100%;border-collapse:collapse;margin:12px 0">
          ${row('الاسم', info.displayName)}${row('البريد', info.email)}
          ${row('الجوال', info.mobile)}${row('الوظيفة', info.jobTitle)}${row('القطاع', info.sector)}
        </table>
        فعّله من: <b>الإعدادات ← المستخدمون</b> بعد مراجعة بياناته وقطاعه.
      </div>
    </div></div>`;
  await sendResend(env, to, 'موظّف جديد بانتظار التفعيل | مجموعة الذيابي', html);
}

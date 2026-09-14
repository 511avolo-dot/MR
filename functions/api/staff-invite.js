/**
 * /api/staff-invite — دعوة موظّف بعينه للانضمام (النظام 2).
 *
 * طلب المالك (2026-09-13): «اجعله يرسل بتمبلت احترافيّ عن طريق Resend — فقط
 * أضع اسم الموظف وإيميله وأحدّد الوظيفة ويتم الإرسال». وقراراته:
 * **القطاع + مسمّى نصّيّ** · **يدخل مباشرةً بعد ضبط كلمة مروره** ·
 * **الرابط المشترك يُحذَف** (لم يعُد له `action:'mint'`).
 *
 * ⚠️ المبدأ الحاكم بعد التحوّل: **الرمز صار شخصيّاً، فهو الاعتماد.** الاسم
 * والبريد والقطاع والمسمّى كلّها **داخل الرمز الموقَّع**، والعميل لا يُقدّم إلا
 * كلمة المرور والجوال. فلا يستطيع حاملُ الرابط تغيير بريده ولا قطاعه ولا أن
 * يمنح نفسه صلاحية. وقُوّة الضمان = أنّ الرابط سُلّم إلى **صندوق بريد الشركة
 * لذلك الموظّف وحده** (نفس نموذج أي دعوة بالبريد).
 * ⚠️ ولا تُرسَل كلمة مرور في البريد إطلاقاً — الموظّف يضبطها بنفسه.
 *
 * أحاديّة الاستعمال بلا جدول رموز: بعد الإتمام يوجد صفّ بذلك البريد، فإعادة
 * استعمال الرابط تسقط على فحص «موجود مسبقاً».
 *
 * الرمز موقَّع HMAC ويحمل حمولته (نمط `doc-renew.js`/`supplier-invite-link.js`):
 * **لا جدول ولا هجرة**. والإبطال بمفتاح `staff_invite.epoch` في `proc_settings`:
 * أي رمز صدر قبله يسقط — فيُبطِل المالك كل الدعوات المعلّقة بنقرة.
 *
 *   GET                        فحص صحّة (منطقيات وجود فقط، بلا قيم)
 *   GET  ?t=<token>            بيانات الدعوة لتعبئة الصفحة العامّة
 *   POST {action:'invite'}     أدمن مُصادَق same-origin ⇒ يسكّ ويُرسل الدعوة
 *   POST {action:'revoke'}     أدمن ⇒ يُبطل كل الدعوات المعلّقة
 *   POST ?t=<token>            إتمام التسجيل (كلمة المرور فقط)
 */
import { svcHeaders, sendResend, publicOrigin, emailToUsername, esc, BRAND } from './_pr-shared.js';

const COMPANY_DOMAIN = 'aldeyabi.com';
const EMAIL_RE = /^[a-z0-9._%+-]+@aldeyabi\.com$/i;
const DEFAULT_DAYS = 14;
const MAX_DAYS = 60;

/* صلاحيات الموظّف الميدانيّ — **ثابتة هنا لا تأتي من العميل**. المبالغ محجوبة
   افتراضاً بقرار المالك، والاستلام ممنوح لأنّه جوهر عمله. أي توسعة يمنحها
   المالك بنفسه من لوحة المستخدمين. */
/* صلاحيات الموظّف الميدانيّ المفروضة خادميّاً (قرار المالك 2026-09-13:
   «كل قدرات الميدان ممنوحة عدا المبالغ»، والمدير يسحب ما لا يريده من اللوحة).
   ⚠️ المفاتيح الأربعة الجديدة **تُكتب صراحةً ولا تُترك للافتراضيّ**: المُنطَّق
   افتراضه «المنح صريح أو لا شيء» في `hasPermission` و`proc_has_perm` معاً، فلو
   غابت هنا وصل المدعوّ إلى نظامٍ لا يرفع فيه طلباً ولا مستنداً ولا يعلّق —
   حسابٌ يعمل على الورق ومشلولٌ فعليّاً. (هذا نفس سبب كتابة `can_view_amounts:false`
   صراحةً بدل الاتّكال على افتراضٍ.)
   ونظيرتها في الواجهة: قالب «👷 موظّف ميدانيّ» في `ROLE_PRESETS` — نفس المجموعة. */
const FIELD_PERMISSIONS = {
  can_create_pr: true,
  can_upload_docs: true,
  can_comment: true,
  can_print_followup: true,
  can_receive_po: true,
  can_view_amounts: false,
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
  /* ⚠️ الحمولة عربية، وbtoa تعمل على بايتات latin1 — فالترميز يمرّ عبر
     TextEncoder (UTF-8) لا btoa مباشرةً على النصّ، وإلّا رمى على أوّل حرف عربيّ. */
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
  /* ⚠️ الرمز الشخصيّ يجب أن يحمل بريداً وقطاعاً — ورمز v1 القديم (قطاع فقط)
     لا يحملهما فيسقط هنا. وهذا مقصود: الروابط المشتركة القديمة تموت مع الحذف. */
  if (!p || !p.e || !p.s || !p.exp || !p.iat) return null;
  if (!EMAIL_RE.test(String(p.e))) return null;
  if (Date.now() > Number(p.exp)) return null;
  if (Number(p.iat) < await inviteEpoch(env)) return null;   // أُبطلت كل الدعوات بعده
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
       **الصفّ الخاطئ** ⇒ المالك نفسه يُرفَض بـ403 عند إصدار الدعوة.
       (`admin-users.js` تعلّم الدرس بـ`ilike` — وهذا الملف فاته.)
       وتهريب أحرف البدل (% _ \) يمنع مطابقة أوسع تلتقط مستخدماً آخر. */
    const safe = String(uname).replace(/[\\%_]/g, (c) => '\\' + c);
    const pr = await fetch(
      `${base}/rest/v1/proc_users?username=ilike.${encodeURIComponent(safe)}&select=username,display_name,email,role,active`,
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

/* هل لهذا البريد (أو اسم المستخدم المشتقّ منه) حساب قائم؟
   ⚠️ المطابقة على الاسم **غير حسّاسة لحالة الأحرف**: الإنتاج يحمل `Mostafa`
   و`Mahmoud` بحرف كبير، فـ`eq.mahmoud` كانت **لا تطابقهما** — فتُرسَل دعوة
   لبريد له حساب أصلاً. وتهريب أحرف البدل يمنع مطابقة أوسع. */
async function existingUser(env, base, email, username) {
  const safe = String(username).replace(/[\\%_]/g, (c) => '\\' + c);
  const r = await fetch(
    `${base}/rest/v1/proc_users?or=(username.ilike.${encodeURIComponent(safe)},email.eq.${encodeURIComponent(email)})&select=username,active`,
    { headers: svcHeaders(env) });
  if (!r.ok) return null;                       // فشل مغلق يُعالَج عند المستدعي
  const rows = await r.json();
  return (Array.isArray(rows) && rows.length) ? rows[0] : false;
}

/* ⚠️ اشتقاق اسم المستخدم من البريد **يجب أن يطابق ما يفعله مسار الدخول** —
   وإلّا صار الحساب المُنشأ هويّةً ثالثة لا الواجهة تجدها ولا القاعدة.
   كان هنا اشتقاق خاصّ (`local-part` بعد حذف كل ما ليس [a-z0-9_]) وهو يُخطئ مرّتين:

   (أ) **يتجاهل خريطة الأسماء المستقرّة** `AUTH_EMAIL_MAP`: بريد `supply@aldeyabi.com`
       اسمه في النظام `mostafa` لا `supply`. وصفّ `Mostafa` في الإنتاج **بلا بريد**،
       فلا فحصُ الاسم ولا فحصُ البريد يجده ⇒ تُرسَل الدعوة، ثمّ يقول Auth عند
       التفعيل «مسجَّل مسبقاً» فيُنشأ صفّ `supply` ثانٍ ببريد مضبوط — و`proc_me()`
       تُطابق بالبريد أوّلاً ⇒ **هويّة مصطفى (أدمن) تنقلب إلى موظّف ميدانيّ مُنطَّق**،
       وكلمة مروره لم تتغيّر أصلاً. (بلاغ Codex P2 — مؤكَّد بالقياس على الإنتاج.)
   (ب) **يُسقِط النقطة**: `ali.salem@aldeyabi.com` كان يصير `alisalem`، بينما
       `usernameToEmail` في الدخول تبني البريد من `ali.salem` — فالملفّ لا يُعثَر
       عليه بعد المصادقة، ويدخل الموظّف بلا نطاق ولا صلاحيات. (بلاغ Codex P1.)

   العلاج: `emailToUsername` نفسها التي يستعملها بقية النظام. */
const usernameFrom = (email) => emailToUsername(String(email).toLowerCase());

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
  /* بيانات المدعوّ نفسه — وهي بياناته هو، والرابط وصل صندوقَه. */
  return json({ ok: true, display_name: p.n || '', email: p.e, sector: p.s,
    job_title: p.j || '', expires_at: new Date(Number(p.exp)).toISOString(), domain: COMPANY_DOMAIN });
}

export async function onRequestPost({ request, env }) {
  if (!sameOrigin(request)) return json({ error: 'طلب غير مصرّح به' }, 403);
  if (!configured(env)) return json({ error: 'الخدمة غير مهيّأة', reason: 'not_configured' }, 503);
  const base = String(env.SUPABASE_URL || '').replace(/\/+$/, '');
  const url = new URL(request.url);
  const token = url.searchParams.get('t');

  let body = {};
  try { body = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }

  /* ── المسار الإداريّ ── */
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

    if (body.action === 'invite') {
      const displayName = String(body.display_name || '').trim();
      const email = String(body.email || '').trim().toLowerCase();
      const sector = String(body.sector || '').trim();
      const jobTitle = String(body.job_title || '').trim().slice(0, 60);
      const days = Math.min(MAX_DAYS, Math.max(1, Number(body.days) || DEFAULT_DAYS));

      if (displayName.length < 3) return json({ error: 'اسم الموظّف مطلوب' }, 400);
      // ⚠️ بريد الشركة حصراً: وهو أيضاً شرط وصول الإشعار — `userEmail` في
      // `_pr-shared.js` تُسقِط أي بريد خارج النطاق فلا يصل شيء. و`sendResend`
      // تُصفّي المستلمين بالنطاق نفسه، فبريد خارجيّ = دعوة لا تُرسَل أصلاً.
      if (!EMAIL_RE.test(email)) return json({ error: `يجب استخدام بريد الشركة (@${COMPANY_DOMAIN})` }, 400);
      if (!sector) return json({ error: 'القطاع مطلوب' }, 400);

      const username = usernameFrom(email);
      if (username.length < 2) return json({ error: 'تعذّر اشتقاق اسم مستخدم من هذا البريد' }, 400);

      // موجود مسبقاً؟ نقولها **الآن** لا بعد أن يضغط الموظّف الرابط.
      const ex = await existingUser(env, base, email, username);
      if (ex === null) return json({ error: 'تعذّر التحقّق من الحسابات القائمة' }, 502);
      if (ex) return json({ error: 'لهذا البريد حساب في النظام بالفعل' }, 409);

      const now = Date.now();
      const t = await mintToken(env, {
        n: displayName, e: email, s: sector, j: jobTitle,
        by: admin.username, iat: now, exp: now + days * 86400000, v: 2,
      });
      const origin = publicOrigin(env, url.origin);
      const link = `${origin}/staff-register.html?t=${encodeURIComponent(t)}`;

      const sent = await sendResend(env, [email],
        'دعوة للانضمام إلى نظام متابعة المشتريات | مجموعة الذيابي',
        inviteEmail({ displayName, sector, jobTitle, email, username, link,
          expiresAt: now + days * 86400000, inviter: admin.display_name || admin.username }));

      /* ⚠️ الرابط يُعاد للمدير **حتى عند نجاح الإرسال**: بريدٌ يقع في مجلّد
         المهملات يترك الموظّف بلا طريق، فالنسخ اليدويّ هو المخرج. */
      return json({
        ok: true, url: link, email, sector,
        expires_at: new Date(now + days * 86400000).toISOString(),
        sent: !!(sent && sent.ok),
        send_error: (sent && (sent.error || sent.skipped)) ? (sent.detail || sent.reason || 'send_failed') : null,
      });
    }
    return json({ error: 'إجراء غير معروف' }, 400);
  }

  /* ── المسار العامّ: إتمام التسجيل ──
     الهويّة كلّها من الرمز؛ العميل يُقدّم كلمة المرور والجوال فقط. */
  const p = await readToken(env, token);
  if (!p) return json({ error: 'الرابط غير صالح أو انتهت صلاحيته' }, 401);

  const email = String(p.e).toLowerCase();
  const displayName = String(p.n || '').trim() || email.split('@')[0];
  const sector = String(p.s);
  const jobTitle = String(p.j || '').trim();
  const password = String(body.password || '');
  const mobile = String(body.mobile || '').trim();

  if (password.length < 8) return json({ error: 'كلمة المرور 8 أحرف على الأقل' }, 400);
  if (mobile && !/^[0-9+\-\s()]{7,20}$/.test(mobile)) return json({ error: 'رقم الجوال غير صالح' }, 400);

  const username = usernameFrom(email);
  if (username.length < 2) return json({ error: 'تعذّر اشتقاق اسم مستخدم من بريدك' }, 400);

  try {
    // إعادة استعمال الرابط بعد الإتمام تسقط هنا — وهي أحاديّة الاستعمال بلا جدول.
    const ex = await existingUser(env, base, email, username);
    if (ex === null) return json({ error: 'تعذّر إتمام التسجيل — حاول مرّة أخرى' }, 502);
    if (ex) {
      return json({ ok: true, already: true,
        message: 'لديك حساب في النظام بالفعل. ادخل بكلمة مرورك، وإن نسيتها فراجع مدير النظام.' });
    }

    // حساب الدخول (مؤكَّد البريد: الدعوة نفسها هي التحقّق)
    const au = await fetch(`${base}/auth/v1/admin/users`, {
      method: 'POST', headers: { ...svcHeaders(env), 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, email_confirm: true,
        user_metadata: { username, source: 'staff_invite' } }),
    });
    const auData = await au.json().catch(() => ({}));
    if (!au.ok) {
      /* ⚠️ «مسجَّل مسبقاً» كان يُعامَل **نجاحاً** فيمضي الكود لإنشاء ملفّ ثانٍ —
         وهو ناقل الضرر الحقيقيّ في بلاغ Codex: بريدٌ له حساب Auth تحت اسم آخر
         (مثل `supply@` ⇒ `Mostafa`) ينتهي بصفّ `proc_users` ثانٍ ببريد مضبوط،
         فتُطابقه `proc_me()` بالبريد أوّلاً و**تنقلب هويّة صاحب الحساب الأصليّ**.
         وكلمة المرور التي اختارها الموظّف لم تُثبَّت أصلاً (Auth رفض الإنشاء)،
         فحتى «النجاح» كان كاذباً. الآن يفشل مغلقاً بلا أي كتابة. */
      const already = /already|exists|registered/i.test(JSON.stringify(auData));
      return json({ error: already
        ? 'لهذا البريد حساب دخول في النظام بالفعل — راجع مدير النظام'
        : 'تعذّر إنشاء حساب الدخول' }, already ? 409 : 400);
    }

    /* ⚠️ كل الحقول الحوكمية مفروضة هنا لا من العميل: الدور `user`، والصلاحيات
       الميدانية الثابتة، والقطاع والاسم والبريد من **الرمز**.
       و`active: true` بقرار المالك — المراجعة تمّت لحظة الدعوة بالاسم. */
    const prof = await fetch(`${base}/rest/v1/proc_users`, {
      method: 'POST', headers: { ...svcHeaders(env), 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({
        username, display_name: displayName, email, mobile: mobile || null,
        job_title: jobTitle || null, password_hash: 'managed_by_supabase_auth',
        role: 'user', permissions: FIELD_PERMISSIONS, active: true,
        scope_sectors: [sector], requested_role: 'field_staff',
        created_by: 'staff_invite',
        notes: `انضمّ عبر دعوة شخصية${p.by ? ` من ${p.by}` : ''} — قطاع «${sector}»`,
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

    // إشعار الداعي بالإتمام — لا «بانتظار التفعيل»، فالحساب صار نشطاً.
    try { await notifyInviter(env, base, p.by, { displayName, email, mobile, jobTitle, sector }); } catch (_) {}

    return json({ ok: true, active: true });
  } catch (_) {
    return json({ error: 'تعذّر إتمام التسجيل' }, 500);
  }
}

/* ═══════════ قالب بريد الدعوة ═══════════
   جداول لا flexbox، وأنماط سطريّة، وألوان BRAND — فعملاء البريد (Outlook
   خاصّة) لا يدعمون الشبكات الحديثة ولا الأنماط الخارجية. */
function inviteEmail({ displayName, sector, jobTitle, email, username, link, expiresAt, inviter }) {
  const until = new Date(expiresAt).toISOString().slice(0, 10);
  const row = (k, v) => v
    ? `<tr>
         <td style="padding:9px 14px;color:${BRAND.soft};font-size:13px;white-space:nowrap">${esc(k)}</td>
         <td style="padding:9px 14px;font-size:13.5px;font-weight:600;color:${BRAND.ink}">${esc(v)}</td>
       </tr>` : '';
  return `<div style="font-family:'Segoe UI',Tahoma,Arial,sans-serif;direction:rtl;text-align:right;
      background:${BRAND.wash};padding:28px 16px;margin:0">
  <span style="display:none;font-size:0;line-height:0;max-height:0;overflow:hidden;opacity:0">
    دعوتك لتفعيل حسابك في نظام متابعة المشتريات — تُنشئ كلمة مرورك وتبدأ فوراً.
  </span>
  <div style="max-width:560px;margin:0 auto;background:#fff;border:1px solid ${BRAND.line};
       border-radius:16px;overflow:hidden">

    <div style="background:${BRAND.navy};padding:26px 26px 22px">
      <div style="color:${BRAND.gold};font-size:12px;letter-spacing:2px;font-weight:700">مجموعة الذيابي</div>
      <div style="color:#fff;font-size:20px;font-weight:700;margin-top:8px">دعوة للانضمام إلى نظام متابعة المشتريات</div>
    </div>

    <div style="padding:24px 26px;color:${BRAND.ink};font-size:14.5px;line-height:1.9">
      <p style="margin:0 0 14px">أهلاً <b>${esc(displayName)}</b>،</p>
      <p style="margin:0 0 18px">
        ${inviter ? `دعاك <b>${esc(inviter)}</b> للانضمام إلى` : 'دُعيت للانضمام إلى'}
        نظام متابعة المشتريات في مجموعة الذيابي. من خلاله تتابع
        <b>أوامر الشراء التي تخصّ قطاعك</b>، وتُسجّل استلام البضاعة،
        وترفع طلبات الشراء وتتابع مسارها — وتصلك الإشعارات على بريدك.
      </p>

      <table style="width:100%;border-collapse:collapse;background:${BRAND.wash};
             border:1px solid ${BRAND.line};border-radius:10px;margin:0 0 22px">
        ${row('القطاع', sector)}${row('المسمّى الوظيفيّ', jobTitle)}
        ${row('اسم الدخول', username)}${row('بريدك', email)}
      </table>

      <div style="text-align:center;margin:26px 0 18px">
        <a href="${esc(link)}"
           style="display:inline-block;background:${BRAND.navy};color:#fff;text-decoration:none;
                  font-size:15px;font-weight:700;padding:14px 38px;border-radius:10px">
          تفعيل الحساب وإنشاء كلمة المرور
        </a>
      </div>

      <p style="margin:0 0 6px;color:${BRAND.soft};font-size:12.5px;text-align:center">
        الرابط شخصيّ لك ولا يصلح لغيرك · صالح حتى <b>${esc(until)}</b>
      </p>

      <div style="border-top:1px solid ${BRAND.line};margin-top:22px;padding-top:16px;
           color:${BRAND.soft};font-size:12px;line-height:1.8">
        لا يعمل الزرّ؟ انسخ هذا العنوان في متصفّحك:
        <div style="direction:ltr;text-align:left;word-break:break-all;color:${BRAND.ink};
             background:${BRAND.wash};border:1px solid ${BRAND.line};border-radius:8px;
             padding:9px 11px;margin-top:7px;font-size:11.5px">${esc(link)}</div>
        <p style="margin:14px 0 0">
          لم تتوقّع هذه الدعوة؟ تجاهل الرسالة ولا تضغط الرابط، وأبلغ مدير النظام.
        </p>
      </div>
    </div>

    <div style="background:${BRAND.wash};border-top:1px solid ${BRAND.line};
         padding:14px 26px;color:${BRAND.soft};font-size:11.5px">
      رسالة آليّة من نظام المشتريات — مجموعة الذيابي
    </div>
  </div>
</div>`;
}

/** إشعار الداعي بأنّ الموظّف أتمّ التفعيل ودخل. */
async function notifyInviter(env, base, inviterUsername, info) {
  const safe = String(inviterUsername || '').replace(/[\\%_]/g, (c) => '\\' + c);
  const q = safe
    ? `${base}/rest/v1/proc_users?username=ilike.${encodeURIComponent(safe)}&active=eq.true&select=email`
    : `${base}/rest/v1/proc_users?active=eq.true&role=eq.admin&select=email`;
  const r = await fetch(q, { headers: svcHeaders(env) });
  const rows = await r.json();
  const to = [...new Set((rows || [])
    .map((u) => (u.email && EMAIL_RE.test(u.email)) ? String(u.email).toLowerCase() : '')
    .filter(Boolean))];
  if (!to.length) return;
  const row = (k, v) => v
    ? `<tr><td style="padding:6px 10px;color:${BRAND.soft};font-size:13px">${esc(k)}</td>
         <td style="padding:6px 10px;font-size:13px;font-weight:600">${esc(v)}</td></tr>` : '';
  const html = `<div style="font-family:'Segoe UI',Tahoma,Arial,sans-serif;direction:rtl;text-align:right;
      background:${BRAND.wash};padding:24px">
    <div style="max-width:520px;margin:0 auto;background:#fff;border:1px solid ${BRAND.line};border-radius:14px;overflow:hidden">
      <div style="background:${BRAND.navy};color:#fff;padding:18px 22px;font-weight:700">
        ✅ الموظّف فعّل حسابه</div>
      <div style="padding:18px 22px;color:${BRAND.ink};font-size:14px;line-height:1.8">
        أتمّ الموظّف الذي دعوتَه ضبط كلمة مروره، و<b>حسابه نشط الآن</b>.
        <table style="width:100%;border-collapse:collapse;margin:12px 0">
          ${row('الاسم', info.displayName)}${row('البريد', info.email)}
          ${row('الجوال', info.mobile)}${row('المسمّى الوظيفيّ', info.jobTitle)}${row('القطاع', info.sector)}
        </table>
        صلاحياته الميدانية الافتراضية: تسجيل الاستلام، بلا عرض المبالغ.
        لتعديلها: <b>الإعدادات ← المستخدمون</b>.
      </div>
    </div></div>`;
  await sendResend(env, to, 'موظّف فعّل حسابه | مجموعة الذيابي', html);
}

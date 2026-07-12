/**
 * Cloudflare Pages Function — إدارة مستخدمي بوابة الطلبات (portal_users) بأمان
 * ════════════════════════════════════════════════════════════════════════
 * معزولة تماماً عن admin-users.js (التي تُدير proc_users لنظام index.html):
 * لا تلمس أي جدول أو دالة proc_*، تتعامل حصراً مع portal_users/Supabase Auth.
 *
 * الإعداد (نفس أسرار بيئة Cloudflare Pages المستخدمة أصلاً):
 *   PORTAL_SUPABASE_URL, PORTAL_SUPABASE_SERVICE_ROLE_KEY (مشروع البوابة المنفصل)
 *
 * الأمان:
 *   - المستدعي يرسل رمز جلسته (Authorization: Bearer <JWT>).
 *   - نتحقّق من الرمز عبر Supabase Auth، ثم نتأكّد أنه أدمن نشط في portal_users
 *     (نفس شرط portal_is_admin() في قاعدة البيانات — تحقّق مطابق على الخادم).
 *   - فقط حينها تُنفَّذ العملية بصلاحية service_role.
 *
 * نقطة النهاية:
 *   GET  /api/portal-users  → فحص التوفّر { ok: true }
 *   POST /api/portal-users  → { action, ... }
 *     action: "create" | "setProfile" | "setActive" | "setPassword" | "delete"
 */

const COMPANY_EMAIL_RE = /^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/i;

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

function sameOrigin(request) {
  const host = request.headers.get('host');
  const src = request.headers.get('origin') || request.headers.get('referer');
  if (!host || !src) return false;
  try { return new URL(src).host === host; } catch (_) { return false; }
}

// مشروع Supabase الخاص بالبوابة (منفصل تماماً عن مشروع النظام القديم).
const PORTAL_URL = (env) => String((env && env.PORTAL_SUPABASE_URL) || '').replace(/\/+$/, '');
const PORTAL_KEY = (env) => String((env && env.PORTAL_SUPABASE_SERVICE_ROLE_KEY) || '');

function sb(env) {
  const base = PORTAL_URL(env);
  const key = PORTAL_KEY(env);
  const headers = { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' };
  return {
    async verifyCaller(jwt) {
      const r = await fetch(`${base}/auth/v1/user`, { headers: { apikey: key, Authorization: `Bearer ${jwt}` } });
      if (!r.ok) return null;
      const u = await r.json();
      return u && u.email ? u : null;
    },
    async getPortalProfileByEmail(email) {
      const safe = String(email).replace(/[\\%_]/g, c => '\\' + c);
      const r = await fetch(`${base}/rest/v1/portal_users?email=ilike.${encodeURIComponent(safe)}&select=username,role,active,email`, { headers });
      if (!r.ok) return null;
      const rows = await r.json();
      const e = String(email).toLowerCase();
      return (rows || []).find(x => String(x.email).toLowerCase() === e) || null;
    },
    async usernameExists(username) {
      const r = await fetch(`${base}/rest/v1/portal_users?username=eq.${encodeURIComponent(username)}&select=username`, { headers });
      if (!r.ok) return true; // تحفّظاً: افترض التعارض إن تعذّر التحقّق
      const rows = await r.json();
      return Array.isArray(rows) && rows.length > 0;
    },
    async emailExists(email) {
      const safe = String(email).replace(/[\\%_]/g, c => '\\' + c);
      const r = await fetch(`${base}/rest/v1/portal_users?email=ilike.${encodeURIComponent(safe)}&select=username`, { headers });
      if (!r.ok) return true;
      const rows = await r.json();
      return Array.isArray(rows) && rows.length > 0;
    },
    async findAuthUserByEmail(email) {
      const r = await fetch(`${base}/auth/v1/admin/users?per_page=500`, { headers });
      if (!r.ok) return null;
      const data = await r.json();
      const list = Array.isArray(data) ? data : (data.users || []);
      return list.find((x) => (x.email || '').toLowerCase() === String(email).toLowerCase()) || null;
    },
    async createAuthUser(email, password, meta) {
      const r = await fetch(`${base}/auth/v1/admin/users`, {
        method: 'POST', headers,
        body: JSON.stringify({ email, password, email_confirm: true, user_metadata: meta || {} }),
      });
      return { ok: r.ok, data: await r.json().catch(() => ({})) };
    },
    async updateAuthUser(id, patch) {
      const r = await fetch(`${base}/auth/v1/admin/users/${id}`, {
        method: 'PUT', headers, body: JSON.stringify(patch),
      });
      return { ok: r.ok, data: await r.json().catch(() => ({})) };
    },
    async deleteAuthUser(id) {
      const r = await fetch(`${base}/auth/v1/admin/users/${id}`, { method: 'DELETE', headers });
      return { ok: r.ok };
    },
    async restWrite(method, path, body) {
      const r = await fetch(`${base}/rest/v1/${path}`, {
        method, headers: { ...headers, Prefer: 'return=minimal' },
        body: body ? JSON.stringify(body) : undefined,
      });
      return { ok: r.ok, status: r.status, text: await r.text().catch(() => '') };
    },
  };
}

// عدد الأدمن النشطين (لحماية «آخر أدمن نشط» في الحذف/التعطيل/التخفيض).
// يفشل مغلقاً: عند تعذّر القراءة يُرجع { ok:false } كي يوقِف المستدعي العملية الخطرة
// بدل تجاوز الحماية (خلل شبكي لحظي كان قد يسمح بإزالة آخر أدمن → قفل البوابة).
async function activeAdminCount(env) {
  const r = await fetch(`${PORTAL_URL(env)}/rest/v1/portal_users?role=eq.admin&active=eq.true&select=username`, {
    headers: { apikey: PORTAL_KEY(env), Authorization: `Bearer ${PORTAL_KEY(env)}` },
  });
  if (!r.ok) return { ok: false };
  const rows = await r.json().catch(() => null);
  if (!Array.isArray(rows)) return { ok: false };
  return { ok: true, count: rows.length };
}
// هل الهدف أدمن نشط؟ (نقرأ الدور والحالة الحاليّين قبل أي تعديل خطر). يفشل مغلقاً.
async function targetAdminState(env, username) {
  const r = await fetch(`${PORTAL_URL(env)}/rest/v1/portal_users?username=eq.${encodeURIComponent(username)}&select=role,active`, {
    headers: { apikey: PORTAL_KEY(env), Authorization: `Bearer ${PORTAL_KEY(env)}` },
  });
  if (!r.ok) return { ok: false };
  const rows = await r.json().catch(() => null);
  if (!Array.isArray(rows)) return { ok: false };
  const u = rows[0];
  return { ok: true, isAdmin: !!(u && u.role === 'admin'), isActive: !!(u && u.active !== false) };
}

export async function onRequestGet({ env }) {
  const configured = !!(PORTAL_URL(env) && PORTAL_KEY(env));
  return json({ ok: configured });
}

export async function onRequestPost({ request, env }) {
  if (!PORTAL_URL(env) || !PORTAL_KEY(env)) {
    return json({ error: 'إدارة مستخدمي البوابة غير مهيّأة على الخادم (PORTAL_SUPABASE_SERVICE_ROLE_KEY).' }, 503);
  }
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);

  const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);

  const api = sb(env);

  // 1) تحقّق من هوية المستدعي عبر Supabase Auth
  const caller = await api.verifyCaller(jwt);
  if (!caller) return json({ error: 'جلسة غير صالحة' }, 401);

  // 2) تأكّد أنه أدمن نشط في portal_users (مطابق لشرط portal_is_admin() في القاعدة)
  const callerProfile = await api.getPortalProfileByEmail(caller.email || '');
  if (!callerProfile || callerProfile.role !== 'admin' || callerProfile.active !== true) {
    return json({ error: 'هذه العملية متاحة لأدمن البوابة فقط' }, 403);
  }
  const callerUsername = callerProfile.username;

  let payload;
  try { payload = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }
  const action = payload && payload.action;

  if (action === 'create') {
    const { email, password, displayName, permissions, active, departmentId, jobKey } = payload;
    if (!email || !password || !displayName) return json({ error: 'حقول ناقصة' }, 400);
    const realEmail = String(email).trim().toLowerCase();
    if (!COMPANY_EMAIL_RE.test(realEmail)) return json({ error: 'بريد إلكتروني غير صالح' }, 400);
    // سياسة النطاق: @<allowed_email_domain> (الافتراضي aldeyabi.com) أو قائمة بيضاء
    // يعتمدها الأدمن مسبقاً — القرار من الإعدادات الخادمية لا من العميل.
    {
      const sr = await fetch(`${PORTAL_URL(env)}/rest/v1/portal_settings?key=eq.portal_settings&select=value`, {
        headers: { apikey: PORTAL_KEY(env), Authorization: `Bearer ${PORTAL_KEY(env)}` },
      });
      const srows = sr.ok ? await sr.json().catch(() => []) : [];
      const val = (srows && srows[0] && srows[0].value) || {};
      const domain = String(val.allowed_email_domain || 'aldeyabi.com').toLowerCase();
      const wl = Array.isArray(val.email_whitelist) ? val.email_whitelist : [];
      const allowed = realEmail.endsWith('@' + domain) || wl.some((w) => String(w || '').trim().toLowerCase() === realEmail);
      if (!allowed) return json({ error: `البريد خارج نطاق الشركة (@${domain}) وغير مُدرَج في القائمة البيضاء المعتمَدة` }, 400);
    }
    if (String(password).length < 8) return json({ error: 'كلمة السر 8 أحرف على الأقل' }, 400);
    if (await api.emailExists(realEmail)) return json({ error: 'هذا البريد مسجّل مسبقاً في البوابة' }, 409);

    // الوظيفة من الكتالوج (نموذج الوظائف): تُورَّث صلاحياتها من الخادم — لا تُقبل
    // صلاحيات خام من العميل عند تحديد وظيفة. gm = دور أدمن (كما النموذج المرجعي).
    let job = null;
    if (jobKey) {
      const jr = await fetch(`${PORTAL_URL(env)}/rest/v1/portal_jobs?key=eq.${encodeURIComponent(String(jobKey))}&active=eq.true&select=key,permissions`, {
        headers: { apikey: PORTAL_KEY(env), Authorization: `Bearer ${PORTAL_KEY(env)}` },
      });
      const jrows = jr.ok ? await jr.json() : [];
      job = jrows && jrows[0] ? jrows[0] : null;
      if (!job) return json({ error: 'وظيفة غير موجودة أو غير مفعّلة' }, 400);
    }

    // اشتقاق اسم مستخدم فريد (مفتاح أساسي داخلي) من مقطع البريد
    let baseUser = realEmail.split('@')[0].toLowerCase().replace(/[^a-z0-9_]/g, '_').replace(/^_+|_+$/g, '').slice(0, 26) || 'user';
    let username = baseUser;
    for (let i = 0; i < 50; i++) {
      if (!(await api.usernameExists(username))) break;
      username = baseUser + (i + 2);
    }

    const permObj = job ? job.permissions
      : ((permissions && typeof permissions === 'object' && !Array.isArray(permissions)) ? permissions : {});

    const auth = await api.createAuthUser(realEmail, password, { portal_username: username });
    if (!auth.ok && !/already|exists|registered/i.test(JSON.stringify(auth.data))) {
      console.error('[portal-users] createAuthUser failed:', auth.data && (auth.data.msg || auth.data.message));
      return json({ error: 'تعذّر إنشاء حساب الدخول' }, 400);
    }

    const prof = await api.restWrite('POST', 'portal_users', {
      username, display_name: String(displayName).trim(), email: realEmail,
      role: job && job.key === 'gm' ? 'admin' : 'user',
      permissions: permObj, active: active !== false,
      department_id: departmentId || null, job_key: job ? job.key : null,
      created_by: callerUsername,
    });
    if (!prof.ok) { console.error('[portal-users] insert profile failed:', prof.text); return json({ error: 'أُنشئ حساب الدخول لكن تعذّر حفظ الملف التعريفي' }, 400); }
    return json({ ok: true, username });
  }

  if (action === 'setProfile') {
    // تحديث الحقول الحسّاسة (الصلاحيات/القسم/التفويض/الإجازة) بصلاحية الخادم فقط،
    // بعد التحقّق أعلاه أن المستدعي أدمن — يسدّ مسار رفع الصلاحية الذاتي من العميل
    // (المحرس portal_users_guard في القاعدة يرفض هذه الكتابة مباشرة من المتصفح أصلاً؛
    // هذا المسار هو الوحيد المصرَّح به لتعديلها).
    const { username } = payload;
    if (!username) return json({ error: 'اسم المستخدم مطلوب' }, 400);
    const patch = {};
    if ('permissions' in payload) {
      const p = payload.permissions;
      if (p === null || (typeof p === 'object' && !Array.isArray(p))) patch.permissions = p || {};
      else return json({ error: 'صيغة الصلاحيات غير صالحة' }, 400);
    }
    if ('departmentId' in payload) patch.department_id = payload.departmentId ? String(payload.departmentId) : null;
    if ('delegateTo' in payload) patch.delegate_to = payload.delegateTo ? String(payload.delegateTo) : null;
    if ('isAway' in payload) patch.is_away = !!payload.isAway;
    if ('role' in payload) patch.role = payload.role === 'admin' ? 'admin' : 'user';
    if (!Object.keys(patch).length) return json({ error: 'لا تغييرات' }, 400);
    // منع تخفيض دور آخر أدمن نشط (يُبقي البوابة بلا مدير).
    if (patch.role === 'user') {
      const t = await targetAdminState(env, username);
      if (!t.ok) return json({ error: 'تعذّر التحقّق من حالة المستخدم — أعد المحاولة' }, 503);
      if (t.isAdmin && t.isActive) {
        const c = await activeAdminCount(env);
        if (!c.ok) return json({ error: 'تعذّر التحقّق من عدد المدراء — أعد المحاولة' }, 503);
        if (c.count <= 1) return json({ error: 'لا يمكن تخفيض دور آخر أدمن نشط للبوابة' }, 400);
      }
    }
    const r = await api.restWrite('PATCH', `portal_users?username=eq.${encodeURIComponent(username)}`, patch);
    if (!r.ok) return json({ error: 'تعذّر حفظ التغييرات' }, 400);
    return json({ ok: true });
  }

  if (action === 'setActive') {
    const { username, active } = payload;
    if (!username) return json({ error: 'اسم المستخدم مطلوب' }, 400);
    // منع تعطيل آخر أدمن نشط (يُبقي البوابة بلا مدير).
    if (!active) {
      const t = await targetAdminState(env, username);
      if (!t.ok) return json({ error: 'تعذّر التحقّق من حالة المستخدم — أعد المحاولة' }, 503);
      if (t.isAdmin && t.isActive) {
        const c = await activeAdminCount(env);
        if (!c.ok) return json({ error: 'تعذّر التحقّق من عدد المدراء — أعد المحاولة' }, 503);
        if (c.count <= 1) return json({ error: 'لا يمكن تعطيل آخر أدمن نشط للبوابة' }, 400);
      }
    }
    const r0 = await fetch(`${PORTAL_URL(env)}/rest/v1/portal_users?username=eq.${encodeURIComponent(username)}&select=email`, {
      headers: { apikey: PORTAL_KEY(env), Authorization: `Bearer ${PORTAL_KEY(env)}` },
    });
    const rows0 = r0.ok ? await r0.json() : [];
    const email0 = rows0 && rows0[0] && rows0[0].email;
    if (email0) {
      const u = await api.findAuthUserByEmail(email0);
      if (u) await api.updateAuthUser(u.id, { ban_duration: active ? 'none' : '876000h' });
    }
    const r = await api.restWrite('PATCH', `portal_users?username=eq.${encodeURIComponent(username)}`, { active: !!active });
    if (!r.ok) return json({ error: 'تعذّر حفظ التغييرات' }, 400);
    return json({ ok: true });
  }

  if (action === 'setPassword') {
    const { username, password } = payload;
    if (!username || String(password || '').length < 8) return json({ error: 'كلمة السر 8 أحرف على الأقل' }, 400);
    const r0 = await fetch(`${PORTAL_URL(env)}/rest/v1/portal_users?username=eq.${encodeURIComponent(username)}&select=email`, {
      headers: { apikey: PORTAL_KEY(env), Authorization: `Bearer ${PORTAL_KEY(env)}` },
    });
    const rows0 = r0.ok ? await r0.json() : [];
    const email0 = rows0 && rows0[0] && rows0[0].email;
    if (!email0) return json({ error: 'لا يوجد حساب لهذا المستخدم' }, 404);
    const u = await api.findAuthUserByEmail(email0);
    if (!u) return json({ error: 'لا يوجد حساب دخول لهذا المستخدم' }, 404);
    const r = await api.updateAuthUser(u.id, { password });
    if (!r.ok) return json({ error: 'تعذّر تغيير كلمة المرور' }, 400);
    return json({ ok: true });
  }

  if (action === 'delete') {
    const { username } = payload;
    if (!username) return json({ error: 'اسم المستخدم مطلوب' }, 400);
    if (username === callerUsername) return json({ error: 'لا يمكنك حذف حسابك' }, 400);
    const r0 = await fetch(`${PORTAL_URL(env)}/rest/v1/portal_users?username=eq.${encodeURIComponent(username)}&select=email,role,active`, {
      headers: { apikey: PORTAL_KEY(env), Authorization: `Bearer ${PORTAL_KEY(env)}` },
    });
    if (!r0.ok) return json({ error: 'تعذّر التحقّق من حالة المستخدم — أعد المحاولة' }, 503);
    const rows0 = await r0.json().catch(() => null);
    if (!Array.isArray(rows0)) return json({ error: 'تعذّر التحقّق من حالة المستخدم — أعد المحاولة' }, 503);
    // منع حذف آخر أدمن نشط (لئلّا تبقى البوابة بلا مدير) — دفاع في العمق فوق RPC القاعدة. يفشل مغلقاً.
    if (rows0[0] && rows0[0].role === 'admin' && rows0[0].active !== false) {
      const c = await activeAdminCount(env);
      if (!c.ok) return json({ error: 'تعذّر التحقّق من عدد المدراء — أعد المحاولة' }, 503);
      if (c.count <= 1) return json({ error: 'لا يمكن حذف آخر أدمن نشط للبوابة' }, 400);
    }
    // سلامة التدقيق: لا حذف صلب لمن له طلبات مسجّلة (FK requester = NOT NULL) —
    // يُعطَّل حسابه بدلاً من ذلك (setActive:false يحفظ السجلّ والمراجع).
    const rq = await fetch(`${PORTAL_URL(env)}/rest/v1/portal_requests?requester=eq.${encodeURIComponent(username)}&select=id&limit=1`, {
      headers: { apikey: PORTAL_KEY(env), Authorization: `Bearer ${PORTAL_KEY(env)}` },
    });
    const rqRows = rq.ok ? await rq.json().catch(() => []) : [];
    if (Array.isArray(rqRows) && rqRows.length) {
      return json({ error: 'لا يمكن حذف مستخدم له طلبات مسجّلة (سلامة التدقيق) — عطّل حسابه بدلاً من الحذف' }, 409);
    }
    // فُكّ المراجع (تفويض/مدير/مدير قسم) لتفادي انتهاك FK.
    await api.restWrite('PATCH', `portal_users?delegate_to=eq.${encodeURIComponent(username)}`, { delegate_to: null });
    await api.restWrite('PATCH', `portal_users?manager_user=eq.${encodeURIComponent(username)}`, { manager_user: null });
    await api.restWrite('PATCH', `portal_departments?manager_user=eq.${encodeURIComponent(username)}`, { manager_user: null });
    // احذف الملف التعريفي أولاً؛ ولا تُتلِف حساب الدخول إلا إذا نجح حذف الملف
    // (وإلا يبقى ملف يتيم بلا دخول ويُبلَّغ الأدمن زوراً بالنجاح).
    const del = await api.restWrite('DELETE', `portal_users?username=eq.${encodeURIComponent(username)}`);
    if (!del.ok) return json({ error: 'تعذّر حذف المستخدم (قد يكون مرتبطاً بسجلات) — عطّل حسابه بدلاً من ذلك' }, 400);
    const email0 = rows0 && rows0[0] && rows0[0].email;
    if (email0) {
      const u = await api.findAuthUserByEmail(email0);
      if (u) await api.deleteAuthUser(u.id);
    }
    return json({ ok: true });
  }

  return json({ error: 'إجراء غير معروف' }, 400);
}

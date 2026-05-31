/**
 * Cloudflare Pages Function — إدارة مستخدمي Supabase Auth بأمان
 * --------------------------------------------------------------
 * تتيح للوحة الإدارة إنشاء/حذف المستخدمين وإعادة تعيين كلمات المرور وتعطيلها،
 * دون وضع مفتاح service_role في المتصفح.
 *
 * الإعداد (أسرار بيئة Cloudflare Pages):
 *   SUPABASE_URL                 رابط مشروع Supabase
 *   SUPABASE_SERVICE_ROLE_KEY    مفتاح service_role (سرّ — لا يُكشف للعميل أبداً)
 *
 * الأمان:
 *   - يجب أن يرسل المستدعي رمز جلسته (Authorization: Bearer <JWT>).
 *   - نتحقّق من الرمز، ثم نتأكد أن المستخدم «مدير» نشط في proc_users.
 *   - فقط حينها تُنفَّذ العملية بصلاحية service_role.
 *
 * نقطة النهاية:
 *   GET  /api/admin-users   → فحص التوفّر { ok: true }
 *   POST /api/admin-users   → { action, ... }
 *     action: "create" | "setPassword" | "setActive" | "delete"
 */

const AUTH_EMAIL_DOMAIN = 'aldeyabi.local';
const usernameToEmail = (u) => String(u || '').trim().toLowerCase() + '@' + AUTH_EMAIL_DOMAIN;

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

// طبقة وصول مباشرة لـ Supabase (REST + Admin Auth) بصلاحية service_role
function sb(env) {
  const base = env.SUPABASE_URL;
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  const headers = { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' };
  return {
    // التحقق من رمز جلسة المستدعي وإرجاع بريده
    async verifyCaller(jwt) {
      const r = await fetch(`${base}/auth/v1/user`, { headers: { apikey: key, Authorization: `Bearer ${jwt}` } });
      if (!r.ok) return null;
      const u = await r.json();
      return u && u.email ? u : null;
    },
    async getProfile(username) {
      // مطابقة غير حسّاسة لحالة الأحرف (البريد lowercase وusername قد يكون Abdullah)،
      // مع تهريب أحرف البدل في ILIKE (% _ \) لمنع مطابقة أوسع تُطابق مستخدماً آخر.
      const safe = String(username).replace(/[\\%_]/g, c => '\\' + c);
      const r = await fetch(`${base}/rest/v1/proc_users?username=ilike.${encodeURIComponent(safe)}&select=username,role,active`, { headers });
      if (!r.ok) return null;
      const rows = await r.json();
      // تأكيد المطابقة الدقيقة (بلا حساسية حالة) دفاعياً
      const u = String(username).toLowerCase();
      return (rows || []).find(x => String(x.username).toLowerCase() === u) || null;
    },
    async findAuthUserByEmail(email) {
      // قائمة المستخدمين (فريق داخلي صغير — صفحة واحدة تكفي)
      const r = await fetch(`${base}/auth/v1/admin/users?per_page=500`, { headers });
      if (!r.ok) return null;
      const data = await r.json();
      const list = Array.isArray(data) ? data : (data.users || []);
      return list.find((x) => (x.email || '').toLowerCase() === email.toLowerCase()) || null;
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

export async function onRequestGet({ env }) {
  const configured = !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY);
  return json({ ok: configured });
}

export async function onRequestPost({ request, env }) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    return json({ error: 'إدارة المستخدمين غير مهيّأة على الخادم (SUPABASE_SERVICE_ROLE_KEY).' }, 503);
  }
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);

  const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);

  const api = sb(env);

  // 1) تحقّق من هوية المستدعي
  const caller = await api.verifyCaller(jwt);
  if (!caller) return json({ error: 'جلسة غير صالحة' }, 401);

  // 2) تأكّد أنه مدير نشط
  const callerUsername = (caller.email || '').split('@')[0];
  const callerProfile = await api.getProfile(callerUsername);
  if (!callerProfile || callerProfile.role !== 'admin' || callerProfile.active === false) {
    return json({ error: 'هذه العملية متاحة للمدير فقط' }, 403);
  }

  // 3) نفّذ العملية
  let payload;
  try { payload = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }
  const action = payload && payload.action;

  if (action === 'create') {
    const { username, password, displayName, role, permissions, active } = payload;
    if (!username || !password || !displayName) return json({ error: 'حقول ناقصة' }, 400);
    if (!/^[A-Za-z0-9_]{2,30}$/.test(username)) return json({ error: 'اسم مستخدم غير صالح' }, 400);
    if (String(password).length < 6) return json({ error: 'كلمة السر 6 أحرف على الأقل' }, 400);
    const r = await api.createAuthUser(usernameToEmail(username), password, { username, role });
    if (!r.ok && !/already|exists|registered/i.test(JSON.stringify(r.data))) {
      return json({ error: 'تعذّر إنشاء حساب الدخول: ' + (r.data.msg || r.data.message || '') }, 400);
    }
    const prof = await api.restWrite('POST', 'proc_users', {
      username, display_name: displayName,
      password_hash: 'managed_by_supabase_auth',
      role: role === 'admin' ? 'admin' : 'user',
      permissions: permissions || {}, active: active !== false,
      created_by: callerUsername,
    });
    if (!prof.ok) return json({ error: 'أنشئ حساب الدخول لكن فشل حفظ الملف التعريفي: ' + prof.text }, 400);
    return json({ ok: true });
  }

  if (action === 'setPassword') {
    const { username, password } = payload;
    if (!username || String(password || '').length < 6) return json({ error: 'بيانات غير صالحة' }, 400);
    const u = await api.findAuthUserByEmail(usernameToEmail(username));
    if (!u) return json({ error: 'لا يوجد حساب دخول لهذا المستخدم' }, 404);
    const r = await api.updateAuthUser(u.id, { password });
    if (!r.ok) return json({ error: 'تعذّر تغيير كلمة المرور' }, 400);
    return json({ ok: true });
  }

  if (action === 'setActive') {
    const { username, active } = payload;
    if (!username) return json({ error: 'اسم المستخدم مطلوب' }, 400);
    const u = await api.findAuthUserByEmail(usernameToEmail(username));
    if (u) {
      // حظر/فك حظر على مستوى Auth (يمنع إصدار JWT جديد للمعطّل)
      await api.updateAuthUser(u.id, { ban_duration: active ? 'none' : '876000h' });
    }
    await api.restWrite('PATCH', `proc_users?username=eq.${encodeURIComponent(username)}`, { active: !!active });
    return json({ ok: true });
  }

  if (action === 'delete') {
    const { username } = payload;
    if (!username) return json({ error: 'اسم المستخدم مطلوب' }, 400);
    if (username === callerUsername) return json({ error: 'لا يمكنك حذف حسابك' }, 400);
    const u = await api.findAuthUserByEmail(usernameToEmail(username));
    if (u) await api.deleteAuthUser(u.id);
    await api.restWrite('DELETE', `proc_users?username=eq.${encodeURIComponent(username)}`);
    return json({ ok: true });
  }

  return json({ error: 'إجراء غير معروف' }, 400);
}

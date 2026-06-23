/**
 * Cloudflare Pages Function — التسجيل الذاتي لبوابة الطلبات (عام لكن محصّن)
 * ════════════════════════════════════════════════════════════════════════
 *  POST /api/portal-signup  { name, email, password, requested_role, invite_code }
 *
 *  يتيح للموظف إنشاء حسابه بنفسه عبر رابط دعوة، دون أن يُنشئ الأدمن مئات الحسابات.
 *
 *  التحصين (نطاق ضرر محصور حتى لو تسرّب رمز الدعوة):
 *   - same-origin فقط، وبلا أي مفتاح خادم في العميل.
 *   - يجب أن يطابق رمز الدعوة الرمزَ السرّي المخزّن في الإعدادات (portal_settings.invite_code).
 *   - يجب أن يكون البريد ضمن نطاق الشركة @aldeyabi.com.
 *   - الحساب يُنشأ **معطّلاً (active=false) وبلا أي صلاحية** — لا يعمل حتى يفعّله الأدمن.
 *   - «requested_role» مجرّد تلميح للأدمن؛ لا يمنح صلاحية اعتماد إطلاقاً (تُمنح يدوياً فقط).
 */

const json = (obj, status = 200) => new Response(JSON.stringify(obj), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
});
function sameOrigin(request) {
  const host = request.headers.get('host');
  const src = request.headers.get('origin') || request.headers.get('referer');
  if (!host || !src) return false;
  try { return new URL(src).host === host; } catch (_) { return false; }
}
const COMPANY_EMAIL_RE = /^[a-z0-9._%+-]+@aldeyabi\.com$/i;

function sb(env) {
  const base = env.SUPABASE_URL;
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  const headers = { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' };
  return {
    base, headers,
    async inviteCode() {
      try {
        const r = await fetch(`${base}/rest/v1/proc_settings?key=eq.portal_settings&select=value`, { headers });
        if (!r.ok) return null;
        const rows = await r.json();
        let v = rows && rows[0] ? rows[0].value : null;
        if (typeof v === 'string') { try { v = JSON.parse(v); } catch (_) { v = null; } }
        return v && v.invite_code ? String(v.invite_code) : null;
      } catch (_) { return null; }
    },
    async userExists(username, email) {
      const r = await fetch(`${base}/rest/v1/proc_users?or=(username.eq.${encodeURIComponent(username)},email.eq.${encodeURIComponent(email)})&select=username`, { headers });
      if (!r.ok) return false;
      const rows = await r.json();
      return Array.isArray(rows) && rows.length > 0;
    },
    async createAuthUser(email, password, meta) {
      const r = await fetch(`${base}/auth/v1/admin/users`, {
        method: 'POST', headers,
        body: JSON.stringify({ email, password, email_confirm: true, user_metadata: meta || {} }),
      });
      return { ok: r.ok, data: await r.json().catch(() => ({})) };
    },
    // حظر حساب Auth حتى يفعّله الأدمن (يمنع إصدار/قبول JWT — التحصين الفعلي للحساب المعلّق).
    async banUser(id) {
      try { await fetch(`${base}/auth/v1/admin/users/${id}`, { method: 'PUT', headers, body: JSON.stringify({ ban_duration: '876000h' }) }); } catch (_) {}
    },
    async insertProfile(row) {
      const r = await fetch(`${base}/rest/v1/proc_users`, {
        method: 'POST', headers: { ...headers, Prefer: 'return=minimal' }, body: JSON.stringify(row),
      });
      return { ok: r.ok, status: r.status, text: await r.text().catch(() => '') };
    },
  };
}

export async function onRequestGet({ env }) {
  // فحص توفّر + هل ضُبط رمز الدعوة (للعميل كي يُظهر التسجيل أو يطلب من الأدمن ضبط الرمز).
  const configured = !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY);
  let hasCode = false;
  if (configured) { try { hasCode = !!(await sb(env).inviteCode()); } catch (_) {} }
  return json({ ok: configured, invite_required: true, has_code: hasCode });
}

export async function onRequestPost({ request, env }) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    return json({ error: 'التسجيل غير مهيّأ على الخادم حالياً.' }, 503);
  }
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);

  let p;
  try { p = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }

  const name = String(p.name || '').trim();
  const email = String(p.email || '').trim().toLowerCase();
  const password = String(p.password || '');
  const requested = p.requested_role === 'approver' ? 'approver' : 'employee';
  const code = String(p.invite_code || '').trim();

  if (name.length < 3) return json({ error: 'يرجى إدخال الاسم الكامل' }, 400);
  if (!COMPANY_EMAIL_RE.test(email)) return json({ error: 'يجب أن يكون البريد ضمن نطاق الشركة @aldeyabi.com' }, 400);
  if (password.length < 8) return json({ error: 'كلمة المرور 8 أحرف على الأقل' }, 400);

  const api = sb(env);

  // رمز الدعوة السرّي
  const expected = await api.inviteCode();
  if (!expected) return json({ error: 'التسجيل الذاتي غير مفعّل حالياً — يرجى مراجعة الإدارة.' }, 403);
  if (code !== expected) return json({ error: 'رمز الدعوة غير صحيح' }, 403);

  // اشتقاق اسم مستخدم فريد من مقطع البريد
  let baseUser = email.split('@')[0].toLowerCase().replace(/[^a-z0-9_]/g, '_').replace(/^_+|_+$/g, '').slice(0, 26) || 'user';
  let username = baseUser;
  for (let i = 0; i < 50; i++) {
    if (!(await api.userExists(username, email === username + '@aldeyabi.com' ? email : '__none__'))) break;
    username = baseUser + (i + 2);
  }
  // رفض إن كان البريد نفسه مسجّلاً مسبقاً
  if (await api.userExists('__none__', email)) {
    return json({ error: 'هذا البريد مسجّل مسبقاً — جرّب تسجيل الدخول.' }, 409);
  }

  // إنشاء حساب الدخول
  const auth = await api.createAuthUser(email, password, { username, role: 'user' });
  if (!auth.ok && !/already|exists|registered/i.test(JSON.stringify(auth.data))) {
    return json({ error: 'تعذّر إنشاء الحساب: ' + (auth.data.msg || auth.data.message || '') }, 400);
  }
  // حظر الحساب حتى يفعّله الأدمن (إلغاء الحظر يتم تلقائياً عبر «تفعيل» في لوحة المستخدمين).
  if (auth.ok && auth.data && auth.data.id) await api.banUser(auth.data.id);

  // الملف التعريفي — معطّل وبلا صلاحيات (الأدمن يفعّل ويمنح)
  const prof = await api.insertProfile({
    username, display_name: name, email,
    password_hash: 'managed_by_supabase_auth',
    role: 'user', permissions: {}, active: false,
    requested_role: requested, created_by: 'self-signup',
  });
  if (!prof.ok) return json({ error: 'أُنشئ حساب الدخول لكن تعذّر حفظ الملف التعريفي.' }, 400);

  return json({ ok: true, pending: true, username });
}

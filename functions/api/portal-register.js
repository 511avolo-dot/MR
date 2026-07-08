/**
 * Cloudflare Pages Function — تسجيل الموظف عبر رمز دعوة (portal_invitations)
 * ════════════════════════════════════════════════════════════════════════
 * نقطة نهاية عامة لكنها محكومة برمز الدعوة (لمرة واحدة + صلاحية زمنية):
 *   GET  /api/portal-register?token=... → { email, displayName, jobKey, departmentId }
 *   POST /api/portal-register { token, password } → ينشئ حساب Auth + ملف portal_users
 *
 * يُعيد التحقّق خادمياً من: الدعوة معلّقة وغير منتهية؛ البريد يجتاز سياسة النطاق
 * (نطاق الشركة أو القائمة البيضاء)؛ البريد غير مسجّل مسبقاً. صلاحيات الوظيفة
 * تُورَّث من portal_jobs (لا تُقبل صلاحيات من العميل). لا يمسّ أي جدول proc_*.
 */

import { portalUrl, portalKey, portalConfigured, svcHeaders } from './_portal-shared.js';

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

async function getInvite(env, base, token) {
  if (!token || !/^[a-f0-9]{16,64}$/i.test(token)) return null;
  const r = await fetch(`${base}/rest/v1/portal_invitations?token=eq.${encodeURIComponent(token)}&select=*`, { headers: svcHeaders(env) });
  if (!r.ok) return null;
  const rows = await r.json().catch(() => []);
  return (rows && rows[0]) || null;
}
function inviteValid(inv) {
  if (!inv) return { ok: false, reason: 'الدعوة غير موجودة' };
  if (inv.status !== 'pending') return { ok: false, reason: 'الدعوة مستهلكة أو ملغاة' };
  if (inv.expires_at && new Date(inv.expires_at).getTime() < Date.now()) return { ok: false, reason: 'انتهت صلاحية الدعوة' };
  return { ok: true };
}
async function emailAllowed(env, base, email) {
  const e = String(email || '').trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(e)) return false;
  const r = await fetch(`${base}/rest/v1/portal_settings?key=eq.portal_settings&select=value`, { headers: svcHeaders(env) });
  const rows = r.ok ? await r.json().catch(() => []) : [];
  const val = (rows && rows[0] && rows[0].value) || {};
  const domain = String(val.allowed_email_domain || 'aldeyabi.com').toLowerCase();
  if (e.endsWith('@' + domain)) return true;
  const wl = Array.isArray(val.email_whitelist) ? val.email_whitelist : [];
  return wl.some((w) => String(w || '').trim().toLowerCase() === e);
}

export async function onRequestGet({ request, env }) {
  if (!portalConfigured(env)) return json({ error: 'التسجيل غير مهيّأ على الخادم' }, 503);
  const base = portalUrl(env);
  const token = new URL(request.url).searchParams.get('token') || '';
  const inv = await getInvite(env, base, token);
  const v = inviteValid(inv);
  if (!v.ok) return json({ error: v.reason }, 400);
  return json({ ok: true, email: inv.email, displayName: inv.display_name, jobKey: inv.job_key, departmentId: inv.department_id });
}

export async function onRequestPost({ request, env }) {
  if (!portalConfigured(env)) return json({ error: 'التسجيل غير مهيّأ على الخادم' }, 503);
  const base = portalUrl(env);
  const headers = svcHeaders(env);

  let payload; try { payload = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }
  const token = String(payload.token || '');
  const password = String(payload.password || '');
  if (password.length < 8) return json({ error: 'كلمة السر 8 أحرف على الأقل' }, 400);

  const inv = await getInvite(env, base, token);
  const v = inviteValid(inv);
  if (!v.ok) return json({ error: v.reason }, 400);

  const email = String(inv.email).trim().toLowerCase();
  if (!(await emailAllowed(env, base, email))) return json({ error: 'البريد خارج النطاق المسموح' }, 400);

  // لا تسمح بتسجيل بريد مسجّل مسبقاً (تعارض دعوة/إنشاء يدوي).
  const safe = email.replace(/[\\%_]/g, (c) => '\\' + c);
  const ex = await fetch(`${base}/rest/v1/portal_users?email=ilike.${encodeURIComponent(safe)}&select=username`, { headers });
  const exRows = ex.ok ? await ex.json().catch(() => []) : [];
  if (Array.isArray(exRows) && exRows.length) {
    await fetch(`${base}/rest/v1/portal_invitations?id=eq.${inv.id}`, { method: 'PATCH', headers: { ...headers, Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'accepted', accepted_at: new Date().toISOString() }) });
    return json({ error: 'هذا البريد مسجّل مسبقاً — يمكنك تسجيل الدخول مباشرة' }, 409);
  }

  // صلاحيات الوظيفة من الكتالوج (لا من العميل).
  let job = null;
  if (inv.job_key) {
    const jr = await fetch(`${base}/rest/v1/portal_jobs?key=eq.${encodeURIComponent(inv.job_key)}&active=eq.true&select=key,permissions`, { headers });
    const jrows = jr.ok ? await jr.json().catch(() => []) : [];
    job = (jrows && jrows[0]) || null;
  }

  // اسم مستخدم فريد من مقطع البريد.
  const baseUser = (email.split('@')[0] || 'user').toLowerCase().replace(/[^a-z0-9_]/g, '_').replace(/^_+|_+$/g, '').slice(0, 26) || 'user';
  let username = baseUser;
  for (let i = 0; i < 60; i++) {
    const ur = await fetch(`${base}/rest/v1/portal_users?username=eq.${encodeURIComponent(username)}&select=username`, { headers });
    const urows = ur.ok ? await ur.json().catch(() => []) : [{}];
    if (!(Array.isArray(urows) && urows.length)) break;
    username = baseUser + (i + 2);
  }

  // أنشئ حساب Auth.
  const au = await fetch(`${base}/auth/v1/admin/users`, {
    method: 'POST', headers, body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { portal_username: username } }),
  });
  const auData = await au.json().catch(() => ({}));
  if (!au.ok && !/already|exists|registered/i.test(JSON.stringify(auData))) {
    console.error('[portal-register] auth create failed'); return json({ error: 'تعذّر إنشاء حساب الدخول' }, 400);
  }

  // أنشئ ملف portal_users (gm = أدمن كما النموذج؛ وإلا حسب دور الدعوة).
  const role = (job && job.key === 'gm') ? 'admin' : (inv.role === 'admin' ? 'admin' : 'user');
  const pr = await fetch(`${base}/rest/v1/portal_users`, {
    method: 'POST', headers: { ...headers, Prefer: 'return=minimal' },
    body: JSON.stringify({
      username, email, display_name: inv.display_name || username, role,
      permissions: job ? job.permissions : {}, department_id: inv.department_id || null,
      job_key: job ? job.key : null, created_by: inv.invited_by || 'invite',
    }),
  });
  if (!pr.ok) { const t = await pr.text().catch(() => ''); console.error('[portal-register] profile insert failed:', t); return json({ error: 'تعذّر حفظ الملف التعريفي' }, 400); }

  await fetch(`${base}/rest/v1/portal_invitations?id=eq.${inv.id}`, {
    method: 'PATCH', headers: { ...headers, Prefer: 'return=minimal' },
    body: JSON.stringify({ status: 'accepted', accepted_at: new Date().toISOString(), accepted_user: username }),
  });

  return json({ ok: true, username, email });
}

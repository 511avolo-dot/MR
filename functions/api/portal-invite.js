/**
 * Cloudflare Pages Function — بوابة دعوات الموظفين (portal_invitations)
 * ════════════════════════════════════════════════════════════════════════
 * معزولة تماماً عن نظام index.html: تتعامل حصراً مع portal_* والمشروع المنفصل.
 *
 * الأمان:
 *   - المستدعي أدمن نشط في portal_users (تحقّق مطابق لـ portal_is_admin()).
 *   - البريد المدعوّ يجب أن يجتاز سياسة النطاق: @<allowed_email_domain> (الافتراضي
 *     aldeyabi.com) أو قائمة email_whitelist التي يعتمدها الأدمن مسبقاً — القرار من
 *     الإعدادات الخادمية (portal_settings)، لا من العميل.
 *   - الدعوة رمز عشوائي لمرة واحدة بصلاحية 7 أيام؛ تُستهلك عبر /api/portal-register.
 *
 * نقطة النهاية:
 *   GET  /api/portal-invite            → { ok } فحص التوفّر
 *   POST /api/portal-invite { action }
 *     action: "send"   { email, displayName, jobKey?, departmentId?, role? }
 *     action: "list"    → { invitations: [...] }
 *     action: "revoke"  { id }
 */

import {
  BRAND, esc, fromAddress, replyTo, publicOrigin,
  portalUrl, portalKey, portalConfigured, svcHeaders, htmlToText,
} from './_portal-shared.js';

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
function randToken() {
  const b = new Uint8Array(24); crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
}

async function verifyAdmin(env, base, jwt) {
  const r = await fetch(`${base}/auth/v1/user`, { headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}` } });
  if (!r.ok) return null;
  const u = await r.json().catch(() => null);
  if (!u || !u.email) return null;
  const safe = String(u.email).replace(/[\\%_]/g, (c) => '\\' + c);
  const pr = await fetch(`${base}/rest/v1/portal_users?email=ilike.${encodeURIComponent(safe)}&select=username,role,active,email`, { headers: svcHeaders(env) });
  if (!pr.ok) return null;
  const rows = await pr.json().catch(() => []);
  const e = String(u.email).toLowerCase();
  const prof = (rows || []).find((x) => String(x.email).toLowerCase() === e);
  if (!prof || prof.role !== 'admin' || prof.active !== true) return null;
  return prof;
}

// سياسة النطاق البريدي من الإعدادات الخادمية (نطاق الشركة أو القائمة البيضاء).
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

function inviteEmail(displayName, url, expiresDays) {
  const B = BRAND;
  return `<!DOCTYPE html><html dir="rtl" lang="ar"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:${B.wash};font-family:'Segoe UI',Tahoma,Arial,sans-serif;color:${B.ink}">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${B.wash};padding:22px 12px"><tr><td align="center">
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#fff;border-radius:18px;overflow:hidden;box-shadow:0 10px 40px -16px rgba(11,27,54,.35)">
      <tr><td style="background:linear-gradient(135deg,${B.navy},#16315c);padding:22px 30px" align="center">
        <div style="color:#E9D9B4;font-size:11.5px;letter-spacing:.08em;text-transform:uppercase">AL-DEYABI GROUP · مجموعة الذيابي</div>
        <div style="color:#fff;font-size:19px;font-weight:800;margin-top:8px">بوابة طلبات الشراء</div>
      </td></tr>
      <tr><td style="height:3px;background:${B.gold}"></td></tr>
      <tr><td style="padding:26px 30px">
        <p style="font-size:15px;margin:0 0 12px">مرحباً ${esc(displayName || '')}،</p>
        <p style="font-size:14px;line-height:1.9;margin:0 0 18px">تمّت دعوتك لإنشاء حسابك في <b>بوابة طلبات الشراء</b> بمجموعة الذيابي. اضغط الزر أدناه لتعيين كلمة المرور وتفعيل حسابك.</p>
        <div align="center" style="margin:22px 0">
          <a href="${url}" style="display:inline-block;background:${B.navy};color:#fff;text-decoration:none;font-weight:700;font-size:15px;padding:13px 30px;border-radius:12px">تفعيل الحساب</a>
        </div>
        <p style="font-size:12px;color:${B.soft};line-height:1.8;margin:14px 0 0">هذه الدعوة صالحة لمدة ${expiresDays} أيام ولمرة واحدة. إن لم تكن تتوقّع هذه الرسالة فتجاهلها.</p>
      </td></tr>
      <tr><td style="background:${B.navy};padding:16px 30px" align="center">
        <div style="color:#fff;font-size:12px;opacity:.9">مجموعة الذيابي · بوابة طلبات الشراء</div>
        <div style="color:#fff;opacity:.5;font-size:10.5px;margin-top:6px">رسالة آلية — لا يلزم الرد</div>
      </td></tr>
    </table>
  </td></tr></table>
</body></html>`;
}

export async function onRequestGet({ env }) {
  return json({ ok: portalConfigured(env) });
}

export async function onRequestPost({ request, env }) {
  if (!portalConfigured(env)) return json({ error: 'بوابة الدعوات غير مهيّأة على الخادم' }, 503);
  if (!sameOrigin(request)) return json({ error: 'origin غير مصرّح' }, 403);
  const base = portalUrl(env);
  const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);

  const admin = await verifyAdmin(env, base, jwt);
  if (!admin) return json({ error: 'هذه العملية متاحة لأدمن البوابة فقط' }, 403);

  let payload; try { payload = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }
  const action = payload && payload.action;

  if (action === 'list') {
    const r = await fetch(`${base}/rest/v1/portal_invitations?select=id,email,display_name,job_key,department_id,role,status,invited_by,created_at,expires_at,accepted_at&order=created_at.desc&limit=200`, { headers: svcHeaders(env) });
    const rows = r.ok ? await r.json().catch(() => []) : [];
    const sr = await fetch(`${base}/rest/v1/portal_settings?key=eq.portal_settings&select=value`, { headers: svcHeaders(env) });
    const srows = sr.ok ? await sr.json().catch(() => []) : [];
    const val = (srows && srows[0] && srows[0].value) || {};
    return json({ ok: true, invitations: rows, domain: String(val.allowed_email_domain || 'aldeyabi.com'), whitelist: Array.isArray(val.email_whitelist) ? val.email_whitelist : [] });
  }

  if (action === 'whitelist_add' || action === 'whitelist_remove') {
    const em = String(payload.email || '').trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(em)) return json({ error: 'بريد غير صالح' }, 400);
    const sr = await fetch(`${base}/rest/v1/portal_settings?key=eq.portal_settings&select=value`, { headers: svcHeaders(env) });
    const srows = sr.ok ? await sr.json().catch(() => []) : [];
    const val = (srows && srows[0] && srows[0].value) || {};
    let wl = Array.isArray(val.email_whitelist) ? val.email_whitelist.map((x) => String(x).trim().toLowerCase()) : [];
    if (action === 'whitelist_add') { if (!wl.includes(em)) wl.push(em); }
    else wl = wl.filter((x) => x !== em);
    const nv = { ...val, email_whitelist: wl };
    const up = await fetch(`${base}/rest/v1/portal_settings?key=eq.portal_settings`, {
      method: 'PATCH', headers: { ...svcHeaders(env), Prefer: 'return=minimal' }, body: JSON.stringify({ value: nv }),
    });
    if (!up.ok) return json({ error: 'تعذّر حفظ القائمة البيضاء' }, 400);
    return json({ ok: true, whitelist: wl });
  }

  if (action === 'revoke') {
    const id = payload.id;
    if (!id) return json({ error: 'معرّف الدعوة مطلوب' }, 400);
    const r = await fetch(`${base}/rest/v1/portal_invitations?id=eq.${encodeURIComponent(id)}&status=eq.pending`, {
      method: 'PATCH', headers: { ...svcHeaders(env), Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'revoked' }),
    });
    if (!r.ok) return json({ error: 'تعذّر إلغاء الدعوة' }, 400);
    return json({ ok: true });
  }

  if (action === 'send') {
    const email = String(payload.email || '').trim().toLowerCase();
    const displayName = String(payload.displayName || '').trim();
    const jobKey = payload.jobKey ? String(payload.jobKey) : null;
    const departmentId = payload.departmentId ? String(payload.departmentId) : null;
    const role = payload.role === 'admin' ? 'admin' : 'user';
    if (!email || !displayName) return json({ error: 'البريد والاسم مطلوبان' }, 400);
    if (!(await emailAllowed(env, base, email))) {
      return json({ error: 'البريد خارج نطاق الشركة (@aldeyabi.com) وغير مُدرَج في القائمة البيضاء المعتمَدة' }, 400);
    }
    // رفض إن كان البريد مسجّلاً مسبقاً في البوابة.
    const safe = email.replace(/[\\%_]/g, (c) => '\\' + c);
    const ex = await fetch(`${base}/rest/v1/portal_users?email=ilike.${encodeURIComponent(safe)}&select=username`, { headers: svcHeaders(env) });
    const exRows = ex.ok ? await ex.json().catch(() => []) : [];
    if (Array.isArray(exRows) && exRows.length) return json({ error: 'هذا البريد مسجّل مسبقاً في البوابة' }, 409);

    // ألغِ أي دعوات معلّقة سابقة لنفس البريد (دعوة واحدة نشطة).
    await fetch(`${base}/rest/v1/portal_invitations?email=ilike.${encodeURIComponent(safe)}&status=eq.pending`, {
      method: 'PATCH', headers: { ...svcHeaders(env), Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'revoked' }),
    });

    const token = randToken();
    const ins = await fetch(`${base}/rest/v1/portal_invitations`, {
      method: 'POST', headers: { ...svcHeaders(env), Prefer: 'return=minimal' },
      body: JSON.stringify({ token, email, display_name: displayName, job_key: jobKey, department_id: departmentId, role, invited_by: admin.username }),
    });
    if (!ins.ok) { const t = await ins.text().catch(() => ''); console.error('[portal-invite] insert failed:', t); return json({ error: 'تعذّر إنشاء الدعوة' }, 400); }

    const origin = publicOrigin(env, new URL(request.url).origin);
    const url = `${origin}/register-portal?token=${token}`;
    let mail = { skipped: true };
    if (env.RESEND_API_KEY) {
      const html = inviteEmail(displayName, url, 7);
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST', headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: fromAddress(env), to: [email], subject: 'دعوة لتفعيل حسابك — بوابة طلبات الشراء', html, text: htmlToText(html), reply_to: replyTo(env) }),
      });
      mail = r.ok ? { ok: true } : { error: true, status: r.status };
    }
    // نُعيد الرابط دائماً كي يتمكّن الأدمن من مشاركته يدوياً إن تعذّر البريد.
    return json({ ok: true, url, mail });
  }

  return json({ error: 'إجراء غير معروف' }, 400);
}

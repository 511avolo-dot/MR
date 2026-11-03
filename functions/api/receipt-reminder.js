/**
 * /api/receipt-reminder — تذكير صاحب الطلب باستلام أوامره المتأخرة
 * ============================================================================
 *   GET               → فحص صحّة (منطقيات وجود فقط، لا قيم).
 *   GET|POST ?sweep=1 → الكنس: الكرون بـ`CRON_SECRET` · أو نبضة كسولة من جلسة موظّف.
 *
 * ⚠️ مُطفأ افتراضاً و**يفشل مغلقاً** (نمط `supplier-invite-link.js` المُثبَت):
 *    لا إرسال إلا إن قُرئ `proc_settings.receipt_reminder_auto.enabled === true`.
 *    تعذّر قراءة الإعداد · الروابط · الطلبات · الأوامر · المستخدمين · سجلّ الإرسال ·
 *    الخانق ⇒ لا إرسال (502). تذكيرٌ على بيانات ناقصة يسأل عمّا استُلم أو يكرّر ما أُرسل.
 * ⚠️ لا مبالغ في البريد (انظر `_receipt-reminder.js`).
 * ⚠️ الأزرار روابط عميقة تفتح النظام بحساب المستلِم — لا تسجّل استلاماً بنفسها:
 *    الاستلام كمياتٌ قد تكون جزئية، ويُكتب بهويّة من سجّله عبر `po_record_receipt`.
 */

import { rowNotifyEmail, publicOrigin, fromAddress, replyTo, htmlToText } from './_pr-shared.js';
import {
  RECEIPT_AUTO_KEY, RR_MAX_ROWS, rrBuildDigests, receiptReminderEmail,
} from './_receipt-reminder.js';

const SWEEP_MIN_HOURS = 20;    // تشغيلة واحدة يوميّاً ولو نُودي كل دقيقة
const SWEEP_MAX_EMAILS = 40;   // سقف الرسائل في التشغيلة
const SWEEP_SPACING_MS = 300;
const AUDIT_DAYS = 120;        // نافذة سجلّ الإرسال/الردود المقروءة

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
function timingSafeEq(a, b) {
  a = String(a); b = String(b);
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
const configured = (env) => !!(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY && env.RESEND_API_KEY);
const baseUrl = (env) => String(env.SUPABASE_URL || '').replace(/\/+$/, '');
const svc = (env) => ({
  apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
  'Content-Type': 'application/json',
});

/* تحقّق جلسة الموظّف — فشل مغلق */
async function verifyStaff(env, request) {
  const key = env.SUPABASE_ANON_KEY || env.SUPABASE_SERVICE_ROLE_KEY || '';
  const auth = request.headers.get('authorization') || '';
  const jwt = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!baseUrl(env) || !key || !jwt) return null;
  try {
    const r = await fetch(`${baseUrl(env)}/auth/v1/user`, { headers: { apikey: key, Authorization: `Bearer ${jwt}` } });
    if (!r.ok) return null;
    const u = await r.json();
    return u && u.email ? u : null;
  } catch (_) { return null; }
}

async function audit(env, entry) {
  try {
    await fetch(`${baseUrl(env)}/rest/v1/proc_audit_log`, {
      method: 'POST', headers: { ...svc(env), Prefer: 'return=minimal' }, body: JSON.stringify([entry]),
    });
  } catch (_) { /* أفضل جهد */ }
}

/* true | false | null (تعذّرت القراءة) */
async function autoEnabled(env) {
  try {
    const r = await fetch(`${baseUrl(env)}/rest/v1/proc_settings?key=eq.${RECEIPT_AUTO_KEY}&select=value`, { headers: svc(env) });
    if (!r.ok) return null;
    const rows = await r.json();
    if (!Array.isArray(rows) || !rows[0]) return false;
    let v = rows[0].value;
    if (typeof v === 'string') { try { v = JSON.parse(v); } catch (_) { v = null; } }
    return !!(v && v.enabled === true);
  } catch (_) { return null; }
}

/* قراءة جدول — `null` عند أي تعذّر (فيفشل الكنس مغلقاً) */
async function readRows(env, path) {
  try {
    const r = await fetch(`${baseUrl(env)}/rest/v1/${path}`, { headers: svc(env) });
    if (!r.ok) return null;
    const rows = await r.json();
    return Array.isArray(rows) ? rows : null;
  } catch (_) { return null; }
}

async function sweep(env, request) {
  const url = new URL(request.url);
  const secret = String(env.CRON_SECRET || '').trim();
  const auth = request.headers.get('authorization') || '';
  const given = auth.startsWith('Bearer ') ? auth.slice(7).trim() : String(url.searchParams.get('key') || '');

  let by = '';
  if (secret && given && timingSafeEq(given, secret)) by = 'cron';
  if (!by && sameOrigin(request) && await verifyStaff(env, request)) by = 'staff';
  if (!by) return json({ error: 'غير مصرّح' }, 401);
  if (!configured(env)) return json({ error: 'الخدمة غير مهيّأة', reason: 'not_configured' }, 503);

  const enabled = await autoEnabled(env);
  if (enabled === null) return json({ ok: false, skipped: 'settings_unreadable' }, 502);
  if (!enabled) return json({ ok: true, skipped: 'disabled' });

  const force = url.searchParams.get('force') === '1' && by === 'cron';
  if (!force) {
    const since = new Date(Date.now() - SWEEP_MIN_HOURS * 3600000).toISOString();
    const t = await readRows(env, `proc_audit_log?entity_type=eq.receipt_reminder&action=eq.sweep` +
      `&ts=gte.${encodeURIComponent(since)}&select=id&limit=1`);
    if (t === null) return json({ ok: false, skipped: 'throttle_unreadable' }, 502);
    if (t.length) return json({ ok: true, skipped: 'throttled' });
  }

  const auditSince = new Date(Date.now() - AUDIT_DAYS * 86400000).toISOString();
  const [links, prs, pos, users, auditRows] = await Promise.all([
    readRows(env, 'proc_pr_po_links?active=eq.true&select=pr_id,po_number,active&limit=10000'),
    readRows(env, 'proc_purchase_requests?select=id,requester,status,archived_at&limit=10000'),
    readRows(env, 'proc_purchase_orders?select=po_number,status,expected_delivery,project,supplier,items,receipts&limit=10000'),
    (async () => {
      const a = await readRows(env, 'proc_users?select=username,display_name,email,notify_email,active&limit=1000');
      // قاعدة قبل عمود بريد المراسلة ⇒ 400: الأعمدة القديمة (لا ينقطع البريد في تلك النافذة)
      return a !== null ? a : readRows(env, 'proc_users?select=username,display_name,email,active&limit=1000');
    })(),
    readRows(env, `proc_audit_log?entity_type=eq.receipt_reminder&action=in.(notify,reply)` +
      `&ts=gte.${encodeURIComponent(auditSince)}&select=entity_type,entity_id,action,new_value,ts&limit=10000`),
  ]);
  if (links === null || prs === null || pos === null || users === null) {
    return json({ ok: false, skipped: 'data_unreadable' }, 502);
  }
  if (auditRows === null) return json({ ok: false, skipped: 'history_unreadable' }, 502);

  const now = Date.now();
  const digests = rrBuildDigests({ links, prs, pos, users, audit: auditRows, now });
  let reqOrigin = '';
  try { reqOrigin = new URL(request.url).origin; } catch (_) {}
  const origin = publicOrigin(env, reqOrigin);

  let sent = 0, orders = 0; const failures = [];
  for (const d of digests.slice(0, SWEEP_MAX_EMAILS)) {
    const to = rowNotifyEmail(d.user);
    if (!to) { failures.push(d.username); continue; }
    const shown = d.items.slice(0, RR_MAX_ROWS);
    const { subject, html } = receiptReminderEmail({
      name: d.name, items: shown, origin, more: d.items.length - shown.length });
    try {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: fromAddress(env), to: [to], subject, html,
                               text: htmlToText(html), reply_to: replyTo(env) }),
      });
      // فشل الإرسال لا يُقيَّد ⇒ يُعاد في الدفعة التالية
      if (!r.ok) { failures.push(d.username); continue; }
    } catch (_) { failures.push(d.username); continue; }
    sent++;
    // يُقيَّد **ما ظهر في البريد فقط** — ما فاض عن السقف يبقى مستحقّاً للدفعة التالية
    for (const it of shown) {
      orders++;
      await audit(env, {
        username: 'system', display_name: 'تذكير الاستلام', user_role: 'system',
        action: 'notify', entity_type: 'receipt_reminder', entity_id: String(it.po.po_number),
        new_value: { to, username: d.username, pr_ids: it.pr_ids, days_late: it.late, round: it.sent + 1 },
        meta: { kind: 'receipt_reminder', by },
      });
    }
    await new Promise((z) => setTimeout(z, SWEEP_SPACING_MS));
  }

  await audit(env, {
    username: 'system', display_name: 'تذكير الاستلام', user_role: 'system',
    action: 'sweep', entity_type: 'receipt_reminder', entity_id: 'sweep',
    new_value: { people: digests.length, sent, orders, failed: failures.length, by },
    meta: { kind: 'receipt_reminder_sweep', by },
  });
  return json({ ok: true, by, people: digests.length, sent, orders, failed: failures.length,
                capped: digests.length > SWEEP_MAX_EMAILS });
}

export async function onRequestGet({ request, env }) {
  if (new URL(request.url).searchParams.get('sweep') === '1') return sweep(env, request);
  // منطقيات وجود فقط — لا قيم (درس عطل بريد التسجيل 2026-07-21)
  return json({
    ok: configured(env),
    checks: {
      supabase_url: !!env.SUPABASE_URL,
      service_key: !!env.SUPABASE_SERVICE_ROLE_KEY,
      resend: !!env.RESEND_API_KEY,
      cron_secret: !!String(env.CRON_SECRET || '').trim(),
    },
  });
}
export async function onRequestPost({ request, env }) {
  if (new URL(request.url).searchParams.get('sweep') === '1') return sweep(env, request);
  return json({ error: 'غير مدعوم' }, 405);
}

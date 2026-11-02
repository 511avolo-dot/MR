/**
 * /api/supplier-invite-link — رابط دعوة تسجيل شخصيّ مربوط ببطاقة مورد قائمة
 * ============================================================================
 * المشكلة: 117 مورداً في `proc_suppliers` أُدخِلوا يدويّاً أو من عروض الأسعار بلا
 * تسجيل. لو سجّلوا عبر الرابط العامّ لأنشأ اعتمادُ طلبهم **بطاقة ثانية** — لأن
 * المطابقة كانت بالسجل التجاري وحده و73 من 155 فقط لديهم سجل.
 *
 * الحل: رابط شخصيّ يحمل رمزاً موقَّعاً بمعرّف البطاقة، فيصير الربط قاطعاً:
 *   POST (موظّف مُصادَق، same-origin) → يسكّ رمزاً لكل معرّف مورد ويعيد الرابط.
 *   GET  ?s=<token>  (عامّ)          → يتحقّق حسابيّاً ويعيد بيانات التعبئة فقط.
 *
 * ⚠️ بلا جدول رموز: الحمولة موقَّعة بـHMAC فيُتحقَّق منها حسابيّاً (نفس نمط
 *    `doc-renew.js` المُثبَت) — لا جدول ولا صفّ ولا تنظيف مجدوَل.
 * ⚠️ قائمة بيضاء صارمة للأعمدة المُعادة: **لا حقول بنكية إطلاقاً** (`iban` /
 *    `account_number` / `bank_name` / `account_holder`) ولا ملاحظات داخلية —
 *    الرمز مقروء لمن يملك الرابط، فلا يُبَثّ عبره إلا ما يكتبه المورّد بنفسه
 *    في النموذج أصلاً. (محروس بتأكيد.)
 */

import {
  INVITE_AUTO_KEY, inviteRegisteredFn, inviteEmailOf,
  inviteSendsFromAudit, inviteNextStage, supplierInviteEmail,
} from './_supplier-invite.js';

const TOKEN_TTL_DAYS = 180;                 // الحملة تمتدّ أسابيع — رابط قصير العمر يُحبِط المورّد
const MAX_BATCH = 200;                      // سقف السكّ في الطلب الواحد
const SUP_ID_RE = /^[A-Za-z0-9_-]{3,64}$/;  // شكل معرّف `proc_suppliers.id`

/* الأعمدة المسموح ببثّها للمورّد عن بطاقته — تعبئة مسبقة فقط */
const PREFILL_COLS = [
  'id', 'name', 'contact', 'phone', 'mobile', 'email',
  'address', 'city', 'commercial_reg', 'tax_id', 'specialty',
];

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

/* الأصل العامّ: `PUBLIC_ORIGIN` أولاً — لا نبني رابط دعوة من ترويسة Host يتحكّم
   بها الطالب إن كان المتغيّر مضبوطاً (درس `portal-action.js`). */
function publicOrigin(env, request) {
  const v = String(env.PUBLIC_ORIGIN || '').trim().replace(/\/+$/, '');
  if (/^https:\/\/[a-z0-9.-]+$/i.test(v)) return v;
  try { return new URL(request.url).origin; } catch (_) { return ''; }
}

/* ── الرمز الموقَّع (نفس آلية doc-renew.js) ──────────────────────────────── */
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
  if (!p || p.k !== 'sup-invite') return null;
  if (!SUP_ID_RE.test(String(p.s || ''))) return null;
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
async function fetchSupplier(env, id) {
  const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
  const r = await fetch(
    `${base}/rest/v1/proc_suppliers?id=eq.${encodeURIComponent(id)}&select=${PREFILL_COLS.join(',')}`,
    { headers: svcHeaders(env) });
  if (!r.ok) return null;
  const rows = await r.json();
  return Array.isArray(rows) && rows[0] ? rows[0] : null;
}

/* تحقّق جلسة الموظّف — فشل مغلق (نفس نمط `reg-doc.js` و`doc-renew.js`) */
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

/* ── الإرسال الآليّ للدعوات (بريد) ──────────────────────────────────────────
   المشكلة المقيسة: 132 مورداً بلا تسجيل، ودعوة واحدة أُرسلت في شهرين لأنّ كل
   دعوة نقرة يدويّة. الكنس يرسل **المرحلة المستحقّة** لكل مورد له بريد صالح:
   الدعوة ← تذكير بعد 7 أيام ← تذكير أخير بعد 14 — ثمّ يتوقّف، ويتوقّف فوراً
   بمجرّد أن يسجّل المورّد (بأي حالة).

   ⚠️ مُطفأ افتراضاً، و**يفشل مغلقاً**: لا إرسال إلا إن قرأ الإعداد
      `proc_settings.supplier_invite_auto.enabled === true` فعلاً. تعذّر القراءة
      = لا إرسال (رسالة لمورّدين خارجيين باسم الشركة لا تُرسَل على تخمين).
   ⚠️ وتعذّر قراءة التسجيلات أو سجلّ الإرسال = لا إرسال أيضاً: الأولى تعني دعوة
      من سجّل، والثانية تعني تكرار رسالة أُرسلت.
   ⚠️ المرحلة لكل **مورد** لا لكل قناة: دعوة واتساب أرسلها موظّف تُحتسَب
      «الدعوة»، فالبريد التالي هو التذكير لا دعوة ثانية.
   الواتساب لا يُرسَل آليّاً: لا واجهة WhatsApp Business مهيّأة، و`wa.me` يفتح
   محادثة في جهاز الموظّف — فهو طابور بالمرحلة في الواجهة لا إرسال خادميّ. */
const SWEEP_MIN_HOURS = 20;     // تشغيلة واحدة يوميّاً ولو نُودي كل دقيقة
const SWEEP_MAX_PER_RUN = 40;   // سقف الرسائل في التشغيلة (مزوّد البريد يحدّ المعدّل)
const SWEEP_SPACING_MS = 300;

function fromAddress(env) {
  const v = String(env.NOTIFY_FROM || '').trim();
  if (v && !/no-?reply/i.test(v)) return v;
  return 'Aldeyabi Group <notifications@suppliers.aldeyabi.com>';
}
function replyTo(env) {
  return String(env.NOTIFY_REPLY_TO || 'supply@aldeyabi.com').trim();
}
function htmlToText(html) {
  return String(html)
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n').replace(/<\/(p|div|tr|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
async function audit(env, entry) {
  try {
    const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
    await fetch(`${base}/rest/v1/proc_audit_log`, {
      method: 'POST', headers: { ...svcHeaders(env), Prefer: 'return=minimal' },
      body: JSON.stringify([entry]),
    });
  } catch (_) { /* أفضل جهد */ }
}

/* هل الأتمتة مفعّلة؟ ← true | false | null (تعذّرت القراءة) */
async function autoEnabled(env) {
  try {
    const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
    const r = await fetch(`${base}/rest/v1/proc_settings?key=eq.${INVITE_AUTO_KEY}&select=value`,
      { headers: svcHeaders(env) });
    if (!r.ok) return null;
    const rows = await r.json();
    if (!Array.isArray(rows) || !rows[0]) return false;
    let v = rows[0].value;
    if (typeof v === 'string') { try { v = JSON.parse(v); } catch (_) { v = null; } }
    return !!(v && v.enabled === true);
  } catch (_) { return null; }
}

async function sweepInvites(env, request) {
  const url = new URL(request.url);
  const secret = String(env.CRON_SECRET || '').trim();
  const auth = request.headers.get('authorization') || '';
  const given = auth.startsWith('Bearer ') ? auth.slice(7).trim() : String(url.searchParams.get('key') || '');

  // مساران كـ`doc-renew.js`: الكرون بالسرّ · أو نبضة كسولة من جلسة موظّف same-origin
  let by = '';
  if (secret && given && timingSafeEq(given, secret)) by = 'cron';
  if (!by && sameOrigin(request) && await verifyStaff(env, request)) by = 'staff';
  if (!by) return json({ error: 'غير مصرّح' }, 401);
  if (!configured(env) || !env.RESEND_API_KEY || !tokenSecret(env)) {
    return json({ error: 'الخدمة غير مهيّأة', reason: 'not_configured' }, 503);
  }

  const enabled = await autoEnabled(env);
  if (enabled === null) return json({ ok: false, skipped: 'settings_unreadable' }, 502);
  if (!enabled) return json({ ok: true, skipped: 'disabled' });

  const base = String(env.SUPABASE_URL).replace(/\/+$/, '');
  const force = url.searchParams.get('force') === '1' && by === 'cron';
  if (!force) {
    try {
      const r = await fetch(`${base}/rest/v1/proc_audit_log?entity_type=eq.supplier_invite&action=eq.sweep` +
        `&ts=gte.${encodeURIComponent(new Date(Date.now() - SWEEP_MIN_HOURS * 3600000).toISOString())}` +
        `&select=id&limit=1`, { headers: svcHeaders(env) });
      // تعذّر قراءة الخانق ⇒ لا إرسال (الخانق هو ما يمنع الإغراق)
      if (!r.ok) return json({ ok: false, skipped: 'throttle_unreadable' }, 502);
      const rows = await r.json();
      if (Array.isArray(rows) && rows.length) return json({ ok: true, skipped: 'throttled' });
    } catch (_) { return json({ ok: false, skipped: 'throttle_unreadable' }, 502); }
  }

  let sups = [], regs = [], auditRows = [];
  try {
    const sr = await fetch(`${base}/rest/v1/proc_suppliers?select=id,name,email,commercial_reg,tax_id&limit=5000`,
      { headers: svcHeaders(env) });
    if (!sr.ok) return json({ error: 'تعذّر جلب الموردين' }, 502);
    sups = await sr.json();

    const getRegs = (c) => fetch(`${base}/rest/v1/proc_supplier_registrations?select=${c}&limit=5000`,
      { headers: svcHeaders(env) });
    let rr = await getRegs('commercial_reg,vat_number,legal_name_ar,link_supplier_id');
    if (!rr.ok) rr = await getRegs('commercial_reg,vat_number,legal_name_ar');
    if (!rr.ok) return json({ error: 'تعذّر جلب التسجيلات' }, 502);
    regs = await rr.json();

    const ar = await fetch(`${base}/rest/v1/proc_audit_log?or=(and(entity_type.eq.supplier_invite,action.eq.notify),` +
      `and(entity_type.eq.supplier,action.eq.supplier_invite_wa))&select=entity_id,action,new_value,ts&limit=10000`,
      { headers: svcHeaders(env) });
    if (!ar.ok) return json({ error: 'تعذّر جلب سجلّ الإرسال' }, 502);
    auditRows = await ar.json();
  } catch (_) { return json({ error: 'تعذّر الاتصال بقاعدة البيانات' }, 502); }

  const isRegistered = inviteRegisteredFn(regs);
  const sends = inviteSendsFromAudit(auditRows);
  const now = Date.now();
  const due = [];
  for (const s of (Array.isArray(sups) ? sups : [])) {
    if (!s || !SUP_ID_RE.test(String(s.id || ''))) continue;
    if (isRegistered(s)) continue;
    const to = inviteEmailOf(s);
    if (!to) continue;
    const next = inviteNextStage(sends.get(String(s.id)), now);
    if (next.done || !next.due) continue;
    due.push({ s, to, next });
  }
  // الأقدم استحقاقاً أوّلاً — فلا يحجب السقفُ تذكيراً مستحقّاً منذ أيام خلف دعوات جديدة
  due.sort((a, b) => a.next.dueAt - b.next.dueAt);

  const origin = publicOrigin(env, request);
  const exp = Math.floor(now / 1000) + TOKEN_TTL_DAYS * 86400;
  let sent = 0; const failures = [];
  for (const d of due.slice(0, SWEEP_MAX_PER_RUN)) {
    const t = await signToken(env, { k: 'sup-invite', s: String(d.s.id), e: exp });
    const link = `${origin}/register?s=${t}`;
    const { subject, html } = supplierInviteEmail(d.s.name, link, d.next.stage);
    try {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: fromAddress(env), to: [d.to], subject, html,
                               text: htmlToText(html), reply_to: replyTo(env) }),
      });
      if (!r.ok) { failures.push(String(d.s.id)); continue; }
    } catch (_) { failures.push(String(d.s.id)); continue; }
    sent++;
    await audit(env, {
      username: 'system', display_name: 'دعوة موردين آليّة', user_role: 'system',
      action: 'notify', entity_type: 'supplier_invite', entity_id: String(d.s.id),
      new_value: { stage: d.next.stage, channel: 'email', to: d.to, name: d.s.name || '' },
      meta: { kind: 'supplier_invite', scheduled: true, by },
    });
    await new Promise((z) => setTimeout(z, SWEEP_SPACING_MS));
  }

  await audit(env, {
    username: 'system', display_name: 'دعوة موردين آليّة', user_role: 'system',
    action: 'sweep', entity_type: 'supplier_invite', entity_id: 'sweep',
    new_value: { candidates: due.length, sent, failed: failures.length, by },
    meta: { kind: 'supplier_invite_sweep', by },
  });
  return json({ ok: true, by, candidates: due.length, sent, failed: failures.length,
                capped: due.length > SWEEP_MAX_PER_RUN });
}

/* ── GET: فحص صحّة · أو تعبئة مسبقة برمز · أو `?sweep=1` ──────────────────── */
export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  if (url.searchParams.get('sweep') === '1') return sweepInvites(env, request);
  const token = url.searchParams.get('s');

  if (!token) {
    // منطقيات وجود فقط — لا قيم (درس عطل بريد التسجيل 2026-07-21)
    return json({
      ok: configured(env) && !!tokenSecret(env),
      checks: {
        supabase_url: !!env.SUPABASE_URL,
        service_key: !!env.SUPABASE_SERVICE_ROLE_KEY,
        token_secret: !!tokenSecret(env),
        resend: !!env.RESEND_API_KEY,
        cron_secret: !!String(env.CRON_SECRET || '').trim(),
      },
    });
  }
  if (!configured(env)) return json({ error: 'not_configured' }, 503);

  const p = await verifyToken(env, token);
  if (!p) return json({ error: 'رابط الدعوة غير صالح أو انتهت صلاحيته' }, 401);

  const sup = await fetchSupplier(env, p.s);
  if (!sup) return json({ error: 'تعذّر العثور على بطاقة المورد' }, 404);

  const out = { supplier_id: sup.id };
  PREFILL_COLS.forEach((c) => { if (c !== 'id' && sup[c]) out[c] = sup[c]; });
  return json({ ok: true, supplier: out });
}

/* ── POST: سكّ روابط دعوة (موظّف مُصادَق) ───────────────────────────────── */
export async function onRequestPost({ request, env }) {
  if (new URL(request.url).searchParams.get('sweep') === '1') return sweepInvites(env, request);
  if (!sameOrigin(request)) return json({ error: 'غير مصرّح' }, 401);
  if (!configured(env)) return json({ error: 'not_configured' }, 503);
  if (!tokenSecret(env)) return json({ error: 'not_configured' }, 503);

  const staff = await verifyStaff(env, request);
  if (!staff) return json({ error: 'غير مصرّح' }, 401);

  let body = {};
  try { body = await request.json(); } catch (_) { return json({ error: 'bad_request' }, 400); }

  const ids = [...new Set((Array.isArray(body.supplier_ids) ? body.supplier_ids : [])
    .map(v => String(v || '').trim()).filter(v => SUP_ID_RE.test(v)))];
  if (!ids.length) return json({ error: 'لا معرّفات صالحة' }, 400);
  if (ids.length > MAX_BATCH) return json({ error: 'دفعة كبيرة جداً' }, 400);

  const origin = publicOrigin(env, request);
  const exp = Math.floor(Date.now() / 1000) + TOKEN_TTL_DAYS * 86400;
  const links = [];
  for (const id of ids) {
    const t = await signToken(env, { k: 'sup-invite', s: id, e: exp });
    links.push({ supplier_id: id, token: t, url: `${origin}/register?s=${t}` });
  }
  return json({ ok: true, links, expires_at: new Date(exp * 1000).toISOString() });
}

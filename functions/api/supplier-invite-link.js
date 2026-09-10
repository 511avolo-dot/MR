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

/* ── GET: فحص صحّة · أو تعبئة مسبقة برمز ────────────────────────────────── */
export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const token = url.searchParams.get('s');

  if (!token) {
    // منطقيات وجود فقط — لا قيم (درس عطل بريد التسجيل 2026-07-21)
    return json({
      ok: configured(env) && !!tokenSecret(env),
      checks: {
        supabase_url: !!env.SUPABASE_URL,
        service_key: !!env.SUPABASE_SERVICE_ROLE_KEY,
        token_secret: !!tokenSecret(env),
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

/**
 * Cloudflare Pages Function — إعداد البوابة الواعي بالبيئة (env-aware) — fail-closed.
 * ════════════════════════════════════════════════════════════════════════════
 * كان purchase-portal.html يُضمِّن عنوان مشروع Supabase الإنتاجي + anon مباشرةً، فمعاينة
 * الفرع على Cloudflare كانت تتحدّث مع **الإنتاج**. هذه النقطة تُزيل ذلك: الصفحة تجلب الإعداد
 * وقت التشغيل، وتُحدَّد القيم من متغيّرات Cloudflare **لكل بيئة**:
 *   • Production: PORTAL_SUPABASE_URL + PORTAL_SUPABASE_ANON_KEY (قيم الإنتاج).
 *   • Preview (فرع): نفس المتغيّرين مضبوطين في نطاق Preview بقيم **staging منفصلة**.
 *
 * ضمانات fail-closed (Codex round-3 — لا سقوط صامت على الإنتاج):
 *   1) البيئة تُحدَّد بإيجاب: CF_PAGES_BRANCH (أو PORTAL_ENV صراحةً). غيابهما ⇒ 503 (لا نفترض إنتاجاً).
 *   2) عنوان Supabase يُحلَّل تحليلاً قانونيّاً (new URL): يُرفض userinfo/منفذ غير 443/مسار غير جذر،
 *      ويُستخلص المرجع من hostname القانوني فقط (لا regex بادئة يمكن خداعه بـ user@host).
 *   3) معاينة + مرجع = الإنتاج ⇒ رفض (409).
 *   4) anon يجب أن يكون مفتاح anon فعليّاً (JWT role=anon أو sb_publishable_): يُرفض service_role/sb_secret_.
 *   5) جاهزية الخادم: مفتاح الخدمة + تخزين الملفات لازمان (تُعاد كبوليانات فقط، بلا قيم) وإلّا 503.
 * لا يُطبَع أي سرّ سوى anon (عام بطبيعته). service_role لا يُعاد أبداً.
 */
const PROD_REF = 'mwbjoysuybgbrvfrprex';   // مرجع مشروع الإنتاج — يُرفض في المعاينة

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

// تحليل قانونيّ لعنوان Supabase: يُرجِع {host, ref} أو null. يرفض أي شكل غير https://<ref>.supabase.co[/].
function parseSupabase(raw) {
  let u;
  try { u = new URL(String(raw || '')); } catch (_) { return null; }
  if (u.protocol !== 'https:') return null;
  if (u.username || u.password) return null;                 // لا userinfo (user@host)
  if (u.port && u.port !== '443') return null;               // منفذ قياسي فقط
  if (u.pathname && u.pathname !== '/' && u.pathname !== '') return null;
  if (u.search || u.hash) return null;
  const host = u.hostname.toLowerCase();
  const m = /^([a-z0-9]{20})\.supabase\.co$/.exec(host);     // مرجع المشروع = 20 محرفاً
  return m ? { host, ref: m[1] } : null;
}

// فكّ base64url آمن (بيئة Workers فيها atob).
function b64urlDecode(s) {
  try {
    const pad = s.length % 4 === 2 ? '==' : s.length % 4 === 3 ? '=' : '';
    return atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
  } catch (_) { return null; }
}

// يتحقّق أنّ المفتاح مفتاح anon/publishable عامّ — لا service_role ولا سرّ.
function isAnonKey(key) {
  const k = String(key || '');
  if (!k) return false;
  if (k.startsWith('sb_secret_')) return false;              // مفتاح سرّي (صيغة جديدة) — يُرفض
  if (k.startsWith('sb_publishable_')) return true;          // مفتاح عامّ (صيغة جديدة) — مقبول
  // صيغة JWT الكلاسيكية: header.payload.sig — نفكّ الحمولة ونتحقّق من role=anon.
  const parts = k.split('.');
  if (parts.length !== 3) return false;
  const payloadRaw = b64urlDecode(parts[1]);
  if (!payloadRaw) return false;
  let payload;
  try { payload = JSON.parse(payloadRaw); } catch (_) { return false; }
  return payload && payload.role === 'anon';                 // يُرفض service_role وأي دور آخر
}

export function onRequestGet({ env }) {
  const url     = env.PORTAL_SUPABASE_URL || '';
  const anonKey = env.PORTAL_SUPABASE_ANON_KEY || '';

  // (1) تحديد البيئة بإيجاب — لا افتراض. CF_PAGES_BRANCH يضبطه Cloudflare في الإنتاج والمعاينة معاً.
  const branch     = env.CF_PAGES_BRANCH || '';
  const prodBranch = env.PORTAL_PROD_BRANCH || 'main';
  const override   = String(env.PORTAL_ENV || '').toLowerCase();   // 'production' | 'preview' (اختياري)
  let mode = null;
  if (override === 'production' || override === 'preview') mode = override;
  else if (branch) mode = (branch === prodBranch) ? 'production' : 'preview';
  if (!mode) {
    return json({ ok: false, error: 'تعذّر تحديد البيئة (production/preview) بإيجاب — اضبط CF_PAGES_BRANCH أو PORTAL_ENV. (fail-closed)' }, 503);
  }
  const isPreview = mode === 'preview';

  // (5) جاهزية الخادم لازمة لتدفّق المستندات (مفتاح الخدمة + تخزين الملفات) — بوليانات فقط.
  const hasService = !!env.PORTAL_SUPABASE_SERVICE_ROLE_KEY;
  const hasBucket  = !!env.QUOTES_BUCKET;

  if (!url || !anonKey) {
    return json({ ok: false, env: mode, error: 'إعداد Supabase غير مضبوط لهذه البيئة (fail-closed). اضبط PORTAL_SUPABASE_URL + PORTAL_SUPABASE_ANON_KEY في Cloudflare.',
      checks: { url: !!url, anonKey: !!anonKey, serviceRole: hasService, bucket: hasBucket } }, 503);
  }

  // (2) تحليل العنوان القانوني واستخلاص المرجع.
  const parsed = parseSupabase(url);
  if (!parsed) {
    return json({ ok: false, env: mode, error: 'عنوان Supabase غير صالح — يجب أن يكون https://<ref>.supabase.co بلا userinfo/منفذ/مسار. (fail-closed)' }, 503);
  }
  // (3) الحارس الحاسم: معاينة فرع لا يجوز أن تتّصل بمشروع الإنتاج.
  if (isPreview && parsed.ref === PROD_REF) {
    return json({ ok: false, env: 'preview',
      error: 'معاينة الفرع مضبوطة على مشروع الإنتاج — مرفوض (fail-closed). اضبط مشروع staging منفصلاً في متغيّرات Preview.' }, 409);
  }
  // (4) المفتاح يجب أن يكون anon/publishable عامّاً (لا service_role/سرّ يُبثّ للعموم).
  if (!isAnonKey(anonKey)) {
    return json({ ok: false, env: mode,
      error: 'المفتاح المضبوط ليس مفتاح anon/publishable عامّاً — مرفوض (fail-closed). لا تضع مفتاح service_role أو سرّاً في PORTAL_SUPABASE_ANON_KEY.' }, 500);
  }
  // (5) جاهزية الخادم.
  if (!hasService || !hasBucket) {
    return json({ ok: false, env: mode,
      error: 'ربط الخادم ناقص (مفتاح الخدمة/تخزين الملفات) — البوابة تحتاجهما لتدفّق المستندات. (fail-closed)',
      checks: { url: true, anonKey: true, serviceRole: hasService, bucket: hasBucket } }, 503);
  }

  return json({ ok: true, url, anonKey, ref: parsed.ref, env: mode, branch });
}

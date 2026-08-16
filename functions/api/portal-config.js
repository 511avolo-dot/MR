/**
 * Exact-head Preview revalidation marker: staging key rotation 2026-08-10.
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
// احتياطيّ الإنتاج فقط: عنوان المشروع + مفتاح anon **العامّ** (يُشحن في العميل بطبيعته، وكان
// مضمَّناً في التطبيق شهوراً). يُستخدم حصراً على فرع الإنتاج (main) حين يغيب متغيّر البيئة، كي
// لا يتعطّل الدخول لسبب إعداد Cloudflare. المعاينة لا تستخدمه إطلاقاً (تتطلّب متغيّرها أو تفشل
// مغلقةً) فيبقى عزل المعاينة عن الإنتاج سليماً. متغيّر البيئة — إن ضُبِط — له الأسبقية.
const PROD_URL_FALLBACK  = 'https://mwbjoysuybgbrvfrprex.supabase.co';
const PROD_ANON_FALLBACK = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im13YmpveXN1eWJnYnJ2ZnJwcmV4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI5MjcxOTksImV4cCI6MjA5ODUwMzE5OX0.MGaA9WP-tAEicyZAAbVk7sGiNzj3nW6NVkuZCeq4vME';

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

// يصنّف المفتاح: {anon, ref, opaque}. anon=مفتاح عامّ مقبول؛ ref=مرجع مشروعه من مطالبة JWT
// (أو null للمبهم)؛ opaque=مفتاح publishable مبهم لا يحمل مرجعاً (يلزمه ربط خارجي).
function keyKind(key) {
  const k = String(key || '');
  if (!k) return { anon: false, ref: null, opaque: false };
  if (k.startsWith('sb_secret_')) return { anon: false, ref: null, opaque: false };   // سرّي — يُرفض
  if (k.startsWith('sb_publishable_')) return { anon: true, ref: null, opaque: true }; // عامّ مبهم
  const parts = k.split('.');                                 // JWT: header.payload.sig
  if (parts.length !== 3) return { anon: false, ref: null, opaque: false };
  const payloadRaw = b64urlDecode(parts[1]);
  if (!payloadRaw) return { anon: false, ref: null, opaque: false };
  let payload;
  try { payload = JSON.parse(payloadRaw); } catch (_) { return { anon: false, ref: null, opaque: false }; }
  let anon = !!payload && payload.role === 'anon';            // يُرفض service_role وأي دور آخر
  // (G1-R2-03) تحقّق من المطالبات الثابتة حيثما وُجدت: المُصدِر supabase، وعدم انتهاء الصلاحية.
  if (anon && typeof payload.iss === 'string' && payload.iss !== 'supabase') anon = false;
  if (anon && typeof payload.exp === 'number' && payload.exp * 1000 <= Date.now()) anon = false;
  const ref = (payload && typeof payload.ref === 'string') ? payload.ref.toLowerCase() : null;
  // مفتاح anon بلا مطالبة ref = غير مربوط (يُعامَل كالمبهم: يلزمه expected-ref خارجي).
  return { anon, ref, opaque: ref === null };
}

export function onRequestGet({ env }) {
  let url       = env.PORTAL_SUPABASE_URL || '';
  let anonKey   = env.PORTAL_SUPABASE_ANON_KEY || '';
  const commit  = String(env.CF_PAGES_COMMIT_SHA || '').toLowerCase();
  // Transitional workflow persistence (P0-1u) remains disabled until the
  // target database has been independently migrated and verified. Absence or
  // any unrecognised value fails closed to a read-only designer.
  const workflowDesignerWrite = /^(1|true|yes|on)$/i.test(
    String(env.PORTAL_WORKFLOW_DESIGNER_WRITE_ENABLED || '').trim()
  );

  // (1 · G1-R2-02) هوية النشر ثابتة في الكود: الفرع الموثوق للإنتاج = 'main' (لا يُتجاوَز بمتغيّر بيئة
  // مثل PORTAL_PROD_BRANCH/PORTAL_ENV على النقطة العامّة). غياب CF_PAGES_BRANCH ⇒ فشل مغلق.
  const PROD_BRANCH = 'main';
  const branch = env.CF_PAGES_BRANCH || '';
  if (!branch) {
    return json({ ok: false, error: 'CF_PAGES_BRANCH غائب — النقطة العامّة تفشل مغلقةً (fail-closed). لا تجاوز ببيئة على النقطة المنشورة.' }, 503);
  }
  const mode = branch === PROD_BRANCH ? 'production' : 'preview';
  const isPreview = mode === 'preview';

  // احتياطيّ الإنتاج فقط (main): إن غاب متغيّر البيئة العامّ نستعمل عنوان/مفتاح anon الإنتاجيّ
  // المضمَّن (كلاهما عامّ) كي يُقلِع الدخول بموثوقية دون تعطّل بسبب إعداد Cloudflare. المعاينة لا
  // تلمسه (تبقى معزولة عبر متغيّرها أو تفشل مغلقةً). المتغيّر إن ضُبِط له الأسبقية.
  if (mode === 'production') {
    if (!url)     url     = PROD_URL_FALLBACK;
    if (!anonKey) anonKey = PROD_ANON_FALLBACK;
  }

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
  // (3 · G1-R2-02) الإنتاج يلزمه (main + مرجع الإنتاج)؛ المعاينة يلزمها (≠main + ≠الإنتاج).
  if (mode === 'production' && parsed.ref !== PROD_REF) {
    return json({ ok: false, env: mode,
      error: 'نشر الإنتاج (الفرع main) يجب أن يشير لمشروع الإنتاج — إعداد خاطئ (fail-closed).' }, 409);
  }
  if (isPreview && parsed.ref === PROD_REF) {
    return json({ ok: false, env: 'preview',
      error: 'معاينة الفرع مضبوطة على مشروع الإنتاج — مرفوض (fail-closed). اضبط مشروع staging منفصلاً في متغيّرات Preview.' }, 409);
  }
  // (4 · G1-02/G1-R2-03/G1-R3-04) **تحقّق بنيويّ من الإعداد** (shape/claims/consistency) لا تحقّق
  // أصالة: التوقيع غير مُتحقَّق، والمفتاح المبهم يُقبَل ببساطة عند مطابقة expected-ref. هذا يمنع بثّ
  // service_role/سرّ ويضمن ربط المشروع، لكنه لا يُثبِت أنّ المفتاح حيّ/أصيل. التحقّق الحيّ = مسبار
  // الجاهزية `scripts/deploy/probe-anon.mjs` (اختياري، وقت النشر، لا يُطبَع المفتاح). السلوك هنا fail-closed.
  const ki = keyKind(anonKey);
  if (!ki.anon) {
    return json({ ok: false, env: mode,
      error: 'المفتاح المضبوط ليس مفتاح anon/publishable عامّاً صالحاً (أو انتهت صلاحيته/مُصدِره غير supabase) — مرفوض (fail-closed).' }, 500);
  }
  if (ki.ref) {                                                 // مفتاح مربوط: مطالبة ref يجب أن تطابق العنوان
    if (ki.ref !== parsed.ref) {
      return json({ ok: false, env: mode,
        error: `مفتاح anon يخصّ مشروعاً (${ki.ref}) مختلفاً عن مشروع العنوان (${parsed.ref}) — مرفوض (fail-closed).` }, 500);
    }
  } else {                                                      // (G1-R2-03) غير مربوط (مبهم أو JWT بلا ref)
    if (String(env.PORTAL_SUPABASE_EXPECTED_REF || '').toLowerCase() !== parsed.ref) {
      return json({ ok: false, env: mode,
        error: 'مفتاح anon غير مربوط بمشروع (publishable مبهم أو JWT بلا مطالبة ref) يتطلّب PORTAL_SUPABASE_EXPECTED_REF مطابقاً لمرجع العنوان — مرفوض (fail-closed).' }, 500);
    }
  }
  // (5) جاهزية الخادم.
  if (!hasService || !hasBucket) {
    return json({ ok: false, env: mode,
      error: 'ربط الخادم ناقص (مفتاح الخدمة/تخزين الملفات) — البوابة تحتاجهما لتدفّق المستندات. (fail-closed)',
      checks: { url: true, anonKey: true, serviceRole: hasService, bucket: hasBucket } }, 503);
  }

  return json({
    ok: true, url, anonKey, ref: parsed.ref, env: mode, branch, commit,
    capabilities: { workflowDesignerWrite },
  });
}

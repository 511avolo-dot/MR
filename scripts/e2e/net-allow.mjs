/**
 * net-allow.mjs — حارس شبكة E2E (G1-R3-02): يمنع أيّ اتّصال بمضيف Supabase غير المرجع
 * المُتحقَّق منه (وبمشروع الإنتاج قطعاً). يُثبَّت قبل أيّ إجراء في مُشغّل E2E الثابت، فسكربت
 * سيناريو خبيث يحاول الاتّصال بالإنتاج مباشرةً يُحظَر **قبل إرسال أيّ طلب**.
 */
const PROD_REF = 'mwbjoysuybgbrvfrprex';

// مضيف Supabase (‎<ref>.supabase.co أو db.<ref>.supabase.co أو <ref>.pooler.supabase.com) → مرجعه، وإلّا null.
export function supabaseRefOfHost(host) {
  const h = String(host || '').toLowerCase();
  let m = /^(?:db\.)?([a-z0-9]{20})\.supabase\.co$/.exec(h);
  if (m) return m[1];
  m = /^([a-z0-9]{20})\.pooler\.supabase\.com$/.exec(h);
  if (m) return m[1];
  m = /\.([a-z0-9]{20})\.supabase\.(co|net)$/.exec(h);   // أشكال فرعية أخرى
  return m ? m[1] : null;
}

// هل يُسمح بهذا العنوان لمرجع staging المُعطى؟ (غير Supabase مسموح؛ Supabase يجب أن يطابق المرجع وليس الإنتاج)
export function isAllowedUrl(url, ref) {
  let host;
  try { host = new URL(String(url)).hostname; } catch (_) { return false; }   // عنوان غير صالح ⇒ منع
  const r = supabaseRefOfHost(host);
  if (r === null) return true;                 // ليس مضيف Supabase — مسموح (الواجهة/الوسيط)
  if (r === PROD_REF) return false;            // الإنتاج — محظور دائماً
  return r === String(ref).toLowerCase();      // Supabase آخر يجب أن يطابق staging المُتحقَّق منه
}

// يُثبِّت قائمة السماح على fetch العامّة؛ يرمي قبل أيّ طلب لمضيف غير مسموح. يُرجِع دالة الإزالة.
export function installNetworkAllowlist(ref) {
  const orig = globalThis.fetch;
  globalThis.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    if (!isAllowedUrl(url, ref)) {
      throw new Error(`E2E network-deny: «${url}» — مسموح فقط بمرجع staging «${ref}» (الإنتاج ومضيفات Supabase الأخرى محظورة).`);
    }
    return orig.apply(this, arguments);
  };
  return () => { globalThis.fetch = orig; };
}

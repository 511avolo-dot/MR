/**
 * Cloudflare Pages Function — إعداد البوابة الواعي بالبيئة (env-aware) — fail-closed.
 * ════════════════════════════════════════════════════════════════════════════
 * كان purchase-portal.html يُضمِّن عنوان مشروع Supabase الإنتاجي + anon مباشرةً، فمعاينة
 * الفرع على Cloudflare كانت تتحدّث مع **الإنتاج**. هذه النقطة تُزيل ذلك: الصفحة تجلب الإعداد
 * وقت التشغيل، وتُحدَّد القيم من متغيّرات Cloudflare **لكل بيئة**:
 *   • Production: PORTAL_SUPABASE_URL + PORTAL_SUPABASE_ANON_KEY (قيم الإنتاج).
 *   • Preview (فرع): نفس المتغيّرين مضبوطين في نطاق Preview بقيم **staging منفصلة**.
 *
 * ضمانات fail-closed (لا سقوط صامت على الإنتاج):
 *   1) إن غابت المتغيّرات ⇒ { ok:false } (الصفحة تُظهر خطأ إعداد ولا تتّصل).
 *   2) إن كانت البيئة **معاينة** وعنوان المشروع = مرجع الإنتاج ⇒ **رفض** (409): المعاينة
 *      يجب أن تستخدم مشروع staging مستقلّاً؛ لا تتّصل بالإنتاج من فرع.
 * لا يُطبَع أي سرّ سوى anon (عام بطبيعته). service_role لا يُعاد أبداً.
 */
const PROD_REF = 'mwbjoysuybgbrvfrprex';   // مرجع مشروع الإنتاج — يُرفض في المعاينة

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}
function refOf(url) {
  const m = /^https:\/\/([a-z0-9]+)\.supabase\.co/i.exec(String(url || ''));
  return m ? m[1].toLowerCase() : null;
}

export function onRequestGet({ env }) {
  const url     = env.PORTAL_SUPABASE_URL || '';
  const anonKey = env.PORTAL_SUPABASE_ANON_KEY || '';
  // Cloudflare Pages يضبط CF_PAGES_BRANCH؛ الإنتاج = فرع الإنتاج (افتراضي main).
  const branch   = env.CF_PAGES_BRANCH || '';
  const prodBranch = env.PORTAL_PROD_BRANCH || 'main';
  const isPreview = !!branch && branch !== prodBranch;

  if (!url || !anonKey) {
    return json({ ok: false, error: 'إعداد Supabase غير مضبوط لهذه البيئة (fail-closed). اضبط PORTAL_SUPABASE_URL + PORTAL_SUPABASE_ANON_KEY في Cloudflare.',
      env: isPreview ? 'preview' : 'production' }, 503);
  }
  const ref = refOf(url);
  // الحارس الحاسم: معاينة فرع لا يجوز أن تتّصل بمشروع الإنتاج.
  if (isPreview && ref === PROD_REF) {
    return json({ ok: false, env: 'preview',
      error: 'معاينة الفرع مضبوطة على مشروع الإنتاج — مرفوض (fail-closed). اضبط مشروع staging منفصلاً في متغيّرات Preview.' }, 409);
  }
  return json({ ok: true, url, anonKey, ref, env: isPreview ? 'preview' : 'production', branch });
}

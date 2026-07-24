-- ═══════════════════════════════════════════════════════════════════════════
--  045 — سدّ ارتداد أمني: portal_update_request كانت قابلة للتنفيذ من anon
--  ─────────────────────────────────────────────────────────────────────────
--  المصدر: مدقّق Supabase الأمني على القاعدة الحيّة (2026-07-24) —
--  «Public Can Execute SECURITY DEFINER Function» على portal_update_request.
--
--  السبب الجذري: الدالة أُضيفت في الهجرة 043 (الإعادة الذكية للتصحيح)، أي **بعد**
--  هجرة التصليب 030 التي سحبت EXECUTE من PUBLIC/anon عن دوال الكتابة. فلم يشملها
--  السحب وبقيت مكشوفة. (نمط ارتداد متكرّر: أي دالة كتابة جديدة بعد 030 يجب أن
--  تُسحب صلاحيتها العامة صراحةً — قاعدة مثبَّتة الآن.)
--
--  الأثر: الدالة SECURITY DEFINER وتستبدل بنود/محتوى الطلب. حمايتها الداخلية قائمة
--  (تشترط هوية معروفة + حالة returned + صلاحية المقدّم/can_edit/أدمن)، فالاستغلال
--  الفعلي من anon مستبعَد — لكن كشفها لـanon سطح هجوم بلا داعٍ ويخالف مبدأ
--  «رفض افتراضي» المعتمد في البوابة.
--
--  ✅ مُطبَّقة حيّاً على mwbjoysuybgbrvfrprex (2026-07-24) ومُتحقَّق منها:
--     anon_exec=false · authenticated_exec=true (الدورة سليمة، لا كسر للواجهة).
-- ═══════════════════════════════════════════════════════════════════════════

REVOKE ALL ON FUNCTION public.portal_update_request(text,text,jsonb,text,text,date,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.portal_update_request(text,text,jsonb,text,text,date,text,text,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.portal_update_request(text,text,jsonb,text,text,date,text,text,text) TO authenticated;

-- تحقّق:
--   SELECT has_function_privilege('anon', p.oid,'EXECUTE') AS anon_exec,
--          has_function_privilege('authenticated', p.oid,'EXECUTE') AS auth_exec
--   FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
--     AND p.proname='portal_update_request';
--   المتوقَّع: anon_exec=false · auth_exec=true

-- ═══════════════════════════════════════════════════════════════════════════
--  045 — سدّ ارتداد أمني: portal_update_request كانت قابلة للتنفيذ من anon
--  ─────────────────────────────────────────────────────────────────────────
--  المصدر: مدقّق Supabase الأمني على القاعدة الحيّة (2026-07-24) —
--  «Public Can Execute SECURITY DEFINER Function» على portal_update_request.
--
--  ⚠️ السبب الجذري الحقيقي (مؤكَّد بالفحص، وليس «نسيان REVOKE»):
--  الهجرة 043 و portal-standalone.sql **تحتويان** REVOKE فعلاً — لكن بصيغة
--  «REVOKE ALL ... FROM public» فقط. وهذا لا يكفي على Supabase:
--    SELECT defaclacl FROM pg_default_acl WHERE defaclnamespace='public'::regnamespace
--           AND defaclobjtype='f';
--    ⇒ {postgres=X/…, anon=X/…, authenticated=X/…, service_role=X/…}
--  أي أنّ Supabase تمنح anon صلاحية EXECUTE **صريحة لكل دالة جديدة** عبر
--  ALTER DEFAULT PRIVILEGES. و«REVOKE ... FROM PUBLIC» يزيل امتياز PUBLIC الضمني
--  فقط ولا يمسّ منحاً صريحاً لدور — فيبقى anon قادراً على التنفيذ.
--  لذلك الهجرة 030 كانت تسحب من الاثنين معاً (FROM PUBLIC ثم FROM anon) وهي المحقّة.
--
--  ⇒ قاعدة مثبَّتة لكل دالة جديدة في البوابة:
--     REVOKE ALL ON FUNCTION <sig> FROM public;
--     REVOKE ALL ON FUNCTION <sig> FROM anon;      -- ← لا تنسَ هذا السطر
--     GRANT EXECUTE ON FUNCTION <sig> TO authenticated;
--  وأُضيف تأكيد دائم في db/portal-tests/11_security.sql (S8) يُفشِل الـCI إن
--  عادت أي دالة portal_* لتكون قابلة للتنفيذ من anon.
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

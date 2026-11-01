-- ════════════════════════════════════════════════════════════════════════════
--  سحب تنفيذ anon عن مساعدات الهويّة والنطاق
--  ---------------------------------------------------------------------------
--  من دراسة النظام (2026-11-01) ومن مدقّق Supabase الحيّ: **ثماني دوال
--  SECURITY DEFINER تبقى قابلة للتنفيذ من `anon`** (زائرٌ بلا حساب):
--    pr_is_admin · pr_is_service · pr_username · proc_me · proc_is_scoped
--    proc_scope_sectors · proc_can_see_po · proc_users_guard
--  لا تسريب واقعاً اليوم (تُرجِع فراغاً بلا JWT — مقيس)، لكنّها سطحُ هجوم
--  بلا داعٍ: الزائر لا مسار مشروع له إلا إدراج طلب تسجيل مورّد.
--
--  القياس هو ما حدّد **ما يُسحَب من مَن** (لا تخمين):
--    · `proc_is_scoped` في 30 سياسة · `proc_me` في 7 · `proc_scope_sectors`
--      و`proc_can_see_po` في 1 لكلٍّ ⇒ **المستخدم المسجَّل يحتفظ بها**،
--      فسياسات RLS تُقيَّم بهويّته لا بهويّة مالك الدالّة.
--    · `pr_is_admin`/`pr_is_service`/`pr_username` بصفر سياسة، وتُنادى من داخل
--      دوال DEFINER أخرى (فتُقيَّم بامتياز المالك) ⇒ تُسحَب من المسجَّل أيضاً.
--    · `proc_users_guard` دالّة مُشغِّل بصفر مستدعٍ ⇒ تُسحَب من الجميع.
--    · وصفر استدعاء RPC لأيٍّ منها في `index.html` و`functions/api/*` (مقيس).
--
--  ⚠️ التحقّق **بالتشغيل لا بالقراءة**: سحب EXECUTE عن دالّة مُشغِّل قد يُعطّلها
--     (سابقة موثّقة في هذا المستودع)، فاختبار 28 يُجرِّب الحارس فعلاً بعد السحب
--     ويؤكّد أنّه ما زال يمنع تصعيد الصلاحية، وأنّ تسجيل المورّد العامّ ما زال يعمل.
--
--  ⚠️ يُطبَّق بعد db/system2-closure-on-link.sql (لا تبعية منطقية — ترتيب فقط).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ① مساعدات تستعملها سياسات RLS ⇒ anon فقط يُسحَب منها
REVOKE ALL ON FUNCTION proc_me()             FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION proc_is_scoped()      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION proc_scope_sectors()  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION proc_can_see_po(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION proc_me(), proc_is_scoped(), proc_scope_sectors(),
                          proc_can_see_po(text) TO authenticated;

-- ② مساعدات داخلية بصفر سياسة وصفر استدعاء من العميل ⇒ تُسحَب من الجميع
REVOKE ALL ON FUNCTION pr_is_admin()    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION pr_is_service()  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION pr_username()    FROM PUBLIC, anon, authenticated;

-- ③ دالّة مُشغِّل: تُستدعى عبر المُشغِّل وحده
REVOKE ALL ON FUNCTION proc_users_guard() FROM PUBLIC, anon, authenticated;

COMMIT;

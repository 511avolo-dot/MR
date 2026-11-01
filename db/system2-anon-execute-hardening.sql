-- ════════════════════════════════════════════════════════════════════════════
--  سحب تنفيذ anon عن مساعدات الهويّة والنطاق
--  ---------------------------------------------------------------------------
--  من دراسة النظام (2026-11-01) ومن مدقّق Supabase الحيّ: **سبع دوال
--  SECURITY DEFINER تبقى قابلة للتنفيذ من `anon`** (زائرٌ بلا حساب):
--    pr_is_admin · pr_is_service · pr_username · proc_me · proc_is_scoped
--    proc_scope_sectors · proc_can_see_po
--  (و`proc_users_guard` مسحوبة أصلاً على الإنتاج ومكشوفة على تنصيبٍ نظيف من
--   المستودع — السحب أدناه يُوحّد الحالتين، وهو idempotent على الإنتاج.)
--  لا تسريب واقعاً اليوم (تُرجِع فراغاً بلا JWT — مقيس)، لكنّها سطحُ هجوم
--  بلا داعٍ: الزائر لا مسار مشروع له إلا إدراج طلب تسجيل مورّد.
--
--  القياس هو ما حدّد **ما يُسحَب من مَن** (لا تخمين):
--    · `proc_is_scoped` في 30 سياسة · `proc_me` في 7 · `proc_scope_sectors`
--      و`proc_can_see_po` في 1 لكلٍّ ⇒ **المستخدم المسجَّل يحتفظ بها**،
--      فسياسات RLS تُقيَّم بهويّته لا بهويّة مالك الدالّة.
--    · `pr_username` بصفر سياسة وصفر مستدعٍ غير-DEFINER ⇒ تُسحَب من المسجَّل أيضاً.
--    · `proc_users_guard` دالّة مُشغِّل بصفر مستدعٍ ⇒ تُسحَب من الجميع.
--    · وصفر استدعاء RPC لأيٍّ منها في `index.html` و`functions/api/*` (مقيس).
--
--  ⚠️⚠️ **`pr_is_admin` و`pr_is_service` تبقيان للمستخدم المسجَّل — ولا تُسحَبا**:
--     القياس على الإنتاج أظهر مستدعيَين **غير** SECURITY DEFINER لهما، وكلاهما
--     دالّة مُشغِّل حوكميّة: `pr_guard_status` (trg_pr_guard_status) و
--     `pr_guard_approval` (trg_pr_guard_approval). الدالّة غير-DEFINER تُنفَّذ
--     **بهويّة المتصل**، فسحب تنفيذهما من `authenticated` يجعل الحارسَين
--     يرميان «permission denied for function» بدل أن يعملا — أي يتحوّل حارسُ
--     حوكمة إلى عطل. وكانت صياغتي الأولى تسحبهما، ومرّت الحزمة المحلّية كلّها
--     لأنّ الكتابة المباشرة على هذين الجدولين مسحوبة أصلاً فلا مسار يُشعِل
--     الحارس بهويّة `authenticated` — **فالحزمة الخضراء لم تكن تستطيع كشفه،
--     وكشفه قياسُ الإنتاج.** و`28_anon_execute.sql` يحرس بقاءهما بتأكيد صريح.
--
--  ⚠️ والتحقّق **بالتشغيل لا بالقراءة**: سحب EXECUTE عن دالّة مُشغِّل قد يُعطّلها
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

-- ② مساعدا الحارسَين غير-DEFINER: anon فقط (انظر التحذير أعلاه — سحبهما من
--    المستخدم المسجَّل يُعطّل trg_pr_guard_status و trg_pr_guard_approval)
REVOKE ALL ON FUNCTION pr_is_admin()   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_is_service() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_is_admin(), pr_is_service() TO authenticated;

-- ③ مساعدة داخلية بصفر سياسة وصفر مستدعٍ غير-DEFINER ⇒ تُسحَب من الجميع
REVOKE ALL ON FUNCTION pr_username() FROM PUBLIC, anon, authenticated;

-- ④ دالّة مُشغِّل: تُستدعى عبر المُشغِّل وحده (مسحوبة أصلاً على الإنتاج)
REVOKE ALL ON FUNCTION proc_users_guard() FROM PUBLIC, anon, authenticated;

COMMIT;

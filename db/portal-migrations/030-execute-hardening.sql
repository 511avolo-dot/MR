-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 030 — تصليب صلاحيات التنفيذ + تثبيت search_path
--  (P0 من التدقيق، مؤكَّد بمدقّق Supabase الحيّ: "Public Can Execute SECURITY
--   DEFINER Function" ×50، و"Function Search Path Mutable" ×4)
--
--  الخطر: إنشاء الدالة يمنح EXECUTE لـPUBLIC افتراضياً ⇒ أي مجهول (anon) عبر
--  PostgREST يستطيع استدعاء دوال الكتابة. الدفاع الحالي (فحص الهوية داخل كل دالة)
--  سليم لكنه سطح هجوم واسع؛ الأصل سحب التنفيذ العام وإبقاء المسجَّلين/الخادم فقط.
--
--  ⚠️ مبدأ أمان صارم (يمنع كسر الإنتاج): لا نسحب PUBLIC/anon إلا من دالة تملك
--  أصلاً منحاً صريحاً لـauthenticated أو service_role — فلا نحذف آخر صلاحية عن
--  دالة يعتمد عليها المستخدم المسجَّل. الدوال ذات صلاحية PUBLIC فقط (بلا منح
--  صريح) تُترك كما هي (قد يحتاجها anon قبل الدخول) ولا يُخاطَر بها هنا.
--
--  idempotent — يُعاد تشغيلها بأمان. مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) سحب EXECUTE العام عن دوال portal_ المحميّة بمنح صريح ──────────────────
DO $mig$
DECLARE r record; v_revoked int := 0;
BEGIN
  FOR r IN
    SELECT p.oid, (p.oid::regprocedure)::text AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname LIKE 'portal\_%'
      -- شرط الأمان: لها منح صريح لـauthenticated أو service_role في acl
      AND p.proacl IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM aclexplode(p.proacl) a
        JOIN pg_roles gr ON gr.oid = a.grantee
        WHERE a.privilege_type = 'EXECUTE'
          AND gr.rolname IN ('authenticated','service_role')
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.sig);
    v_revoked := v_revoked + 1;
  END LOOP;
  RAISE NOTICE '030: سُحب EXECUTE العام عن % دالة portal_ (بقي authenticated/service_role الصريح).', v_revoked;
END $mig$;

-- ── (2) تثبيت search_path على كل دالة SECURITY DEFINER تفتقده ─────────────────
-- (يمنع اختطاف search_path — تصليب معياري لدوال DEFINER)
DO $mig$
DECLARE r record; v_fixed int := 0;
BEGIN
  FOR r IN
    SELECT (p.oid::regprocedure)::text AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname LIKE 'portal\_%'
      AND p.prosecdef = true
      AND (p.proconfig IS NULL
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'))
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public', r.sig);
    v_fixed := v_fixed + 1;
  END LOOP;
  RAISE NOTICE '030: ثُبِّت search_path على % دالة DEFINER كانت تفتقده.', v_fixed;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
--  046 — إتمام تصليب صلاحيات التنفيذ: سدّ الفجوة التي تركتها الهجرة 030
--  ─────────────────────────────────────────────────────────────────────────
--  المصدر: فشل تأكيد S8 في CI على تنصيب نظيف (PostgreSQL 16) — كشف 40 دالة
--  portal_ قابلة للتنفيذ من anon، منها دوال كتابة حقيقية:
--    portal_create_request · portal_submit_request · portal_award ·
--    portal_award_transition · portal_cancel_request · portal_apply_job ·
--    portal_save_job / delete_job · portal_save_department / delete_department ·
--    portal_delete_supplier · portal_resume_hold · portal_gen_token ·
--    portal_outbox_enqueue  (+ دوال مُشغِّلات ومساعدات داخلية).
--
--  ⚠️ السبب الجذري (دقيق): كتلة التصليب في 030 مشروطة بـ
--        AND p.proacl IS NOT NULL
--        AND EXISTS(... grantee IN ('authenticated','service_role'))
--     أي أنّها تعالج فقط الدوال التي تملك **منحاً صريحاً** (وهذا كان مقصوداً
--     لئلّا تُكسر آخر صلاحية). أمّا الدوال بلا منح صريح (proacl IS NULL) فتبقى
--     على الافتراض في PostgreSQL: EXECUTE ممنوح لـPUBLIC — و anon يرث منه.
--     فالتنصيب النظيف من portal-standalone.sql كان يُولَد مكشوفاً.
--
--  ملاحظة عن القاعدة الحيّة: مُتحقَّق أنّها **غير متأثّرة** (0 دالة مكشوفة لـanon
--  بعد الهجرة 045)، لأنّ Supabase تمنح anon منحاً صريحاً عبر pg_default_acl
--  فتقع الدوال داخل شرط 030 وتُعالَج. هذه الهجرة تُعيد التنصيب النظيف إلى
--  نفس مستوى القاعدة الحيّة (تكافؤ)، وهي **idempotent وآمنة** على الحيّة.
--
--  المعالجة: لكل دالة portal_ ما تزال قابلة للتنفيذ من anon:
--    (أ) REVOKE EXECUTE من PUBLIC ومن anon.
--    (ب) GRANT EXECUTE لـauthenticated — لغير المجموعة الخادمية — كي لا تنكسر
--        الدورة (هذه الدوال كانت تصل للمستخدم المسجَّل عبر PUBLIC ضمناً).
--  التحقّق الدائم: تأكيد S8 في db/portal-tests/11_security.sql يُفشِل CI عند العودة.
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE r record; v_done int := 0;
  server_only CONSTANT text[] := ARRAY[
    'portal_audit_write','portal_award_total','portal_budget_committed','portal_contract_consumed',
    'portal_create_token','portal_invoiced_total','portal_outbox_claim','portal_outbox_mark',
    'portal_outbox_purge','portal_pr_transition_email','portal_returns_total','portal_run_sla'];
BEGIN
  FOR r IN
    SELECT (p.oid::regprocedure)::text AS sig, p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'portal\_%'
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon',   r.sig);
    IF NOT (r.proname = ANY(server_only)) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.sig);
    END IF;
    v_done := v_done + 1;
  END LOOP;
  RAISE NOTICE '046: أُغلق كشف anon عن % دالة portal_ متبقّية.', v_done;
END $mig$;

-- تحقّق (المتوقَّع 0):
--   SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--   WHERE n.nspname='public' AND p.proname LIKE 'portal\_%'
--     AND has_function_privilege('anon', p.oid, 'EXECUTE');

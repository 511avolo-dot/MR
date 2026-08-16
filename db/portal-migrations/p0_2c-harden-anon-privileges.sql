-- ════════════════════════════════════════════════════════════════════════════
--  p0_2c — إغلاق منح anon المباشرة على جداول وتسلسلات البوابة
--  طُبّقت على الإنتاج كـ 20260816091223_harden_anon_privileges.
--  تبقى واجهة المورد العامة محصورة في RPCين SECURITY DEFINER يتحقق كلٌ منهما
--  من رمز دعوة عشوائي، الصلاحية الزمنية، النطاق، وحالة الطلب.
-- ════════════════════════════════════════════════════════════════════════════

DO $migration$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname LIKE 'portal\_%' ESCAPE '\'
      AND c.relkind IN ('r','p','v','m','f')
  LOOP
    EXECUTE format('REVOKE ALL PRIVILEGES ON TABLE %I.%I FROM anon', r.nspname, r.relname);

    IF EXISTS (
      SELECT 1
      FROM pg_class c2
      JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
      WHERE n2.nspname = r.nspname
        AND c2.relname = r.relname
        AND c2.relkind IN ('r','p')
    ) THEN
      EXECUTE format(
        'REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE %I.%I FROM authenticated',
        r.nspname, r.relname
      );
    END IF;
  END LOOP;

  FOR r IN
    SELECT n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname LIKE 'portal\_%' ESCAPE '\'
      AND c.relkind = 'S'
  LOOP
    EXECUTE format('REVOKE ALL PRIVILEGES ON SEQUENCE %I.%I FROM anon', r.nspname, r.relname);
  END LOOP;
END
$migration$;

DO $rls_auto$
BEGIN
  -- هذه دالة صيانة قديمة موجودة في بعض بيئات الإنتاج وليست جزءاً من التثبيت النظيف.
  IF to_regprocedure('public.rls_auto_enable()') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION public.rls_auto_enable() TO service_role;
  END IF;
END
$rls_auto$;

-- واجهة المورد ذات الرمز فقط — منح مقصود ومختبَر.
GRANT EXECUTE ON FUNCTION public.portal_supplier_rfq(text)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_supplier_submit(text, jsonb, integer, integer, text, text)
  TO anon, authenticated, service_role;

-- Fail closed للهياكل المستقبلية التي ينشئها postgres في public.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL PRIVILEGES ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL PRIVILEGES ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon;

DO $assertions$
DECLARE leaked_tables text;
DECLARE leaked_sequences text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
  INTO leaked_tables
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname LIKE 'portal\_%' ESCAPE '\'
    AND c.relkind IN ('r','p','v','m','f')
    AND (
      has_table_privilege('anon', c.oid, 'SELECT')
      OR has_table_privilege('anon', c.oid, 'INSERT')
      OR has_table_privilege('anon', c.oid, 'UPDATE')
      OR has_table_privilege('anon', c.oid, 'DELETE')
      OR has_table_privilege('anon', c.oid, 'TRUNCATE')
      OR has_table_privilege('anon', c.oid, 'REFERENCES')
      OR has_table_privilege('anon', c.oid, 'TRIGGER')
    );

  IF leaked_tables IS NOT NULL THEN
    RAISE EXCEPTION 'anon still has direct portal relation privileges: %', leaked_tables;
  END IF;

  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
  INTO leaked_sequences
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname LIKE 'portal\_%' ESCAPE '\'
    AND c.relkind = 'S'
    AND (
      has_sequence_privilege('anon', c.oid, 'USAGE')
      OR has_sequence_privilege('anon', c.oid, 'SELECT')
      OR has_sequence_privilege('anon', c.oid, 'UPDATE')
    );

  IF leaked_sequences IS NOT NULL THEN
    RAISE EXCEPTION 'anon still has direct portal sequence privileges: %', leaked_sequences;
  END IF;

  IF to_regprocedure('public.rls_auto_enable()') IS NOT NULL THEN
    IF has_function_privilege(
      'anon',
      to_regprocedure('public.rls_auto_enable()'),
      'EXECUTE'
    ) THEN
      RAISE EXCEPTION 'anon must not execute rls_auto_enable';
    END IF;
  END IF;

  IF NOT has_function_privilege('anon', 'public.portal_supplier_rfq(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'supplier RFQ token RPC must remain public';
  END IF;

  IF NOT has_function_privilege(
    'anon',
    'public.portal_supplier_submit(text,jsonb,integer,integer,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'supplier submit token RPC must remain public';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.portal_run_sla()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.portal_recurring_run()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.portal_outbox_claim(integer)', 'EXECUTE')
     OR NOT has_function_privilege(
       'service_role',
       'public.portal_outbox_mark(bigint,boolean,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'service_role background-job grants are incomplete';
  END IF;
END
$assertions$;

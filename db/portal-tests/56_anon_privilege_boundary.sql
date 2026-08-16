-- p0_2c regression: portal relations/sequences are closed to anon while token RPCs remain public.
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $seed$
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
    EXECUTE format('GRANT ALL PRIVILEGES ON TABLE %I.%I TO anon', r.nspname, r.relname);
  END LOOP;

  FOR r IN
    SELECT n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname LIKE 'portal\_%' ESCAPE '\'
      AND c.relkind = 'S'
  LOOP
    EXECUTE format('GRANT ALL PRIVILEGES ON SEQUENCE %I.%I TO anon', r.nspname, r.relname);
  END LOOP;

  GRANT EXECUTE ON FUNCTION public.rls_auto_enable() TO PUBLIC, anon, authenticated;
  RAISE NOTICE 'PASS AP0 seeded legacy broad grants before applying the real migration';
END
$seed$;

\ir ../portal-migrations/p0_2c-harden-anon-privileges.sql

DO $test$
DECLARE bad text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
  INTO bad
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
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'AP1 fail: anon retains portal relation privileges: %', bad;
  END IF;
  RAISE NOTICE 'PASS AP1 anon has no direct privilege on any portal relation';

  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
  INTO bad
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
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'AP2 fail: anon retains portal sequence privileges: %', bad;
  END IF;
  RAISE NOTICE 'PASS AP2 anon has no direct privilege on any portal sequence';

  IF has_function_privilege('anon', 'public.rls_auto_enable()', 'EXECUTE') THEN
    RAISE EXCEPTION 'AP3 fail: rls_auto_enable remains public';
  END IF;
  RAISE NOTICE 'PASS AP3 rls_auto_enable is server-only';

  IF NOT has_function_privilege('anon', 'public.portal_supplier_rfq(text)', 'EXECUTE')
     OR NOT has_function_privilege(
       'anon',
       'public.portal_supplier_submit(text,jsonb,integer,integer,text,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'AP4 fail: token-scoped supplier RPC grants regressed';
  END IF;
  RAISE NOTICE 'PASS AP4 token-scoped supplier RPCs remain available to anon';

  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
  INTO bad
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname LIKE 'portal\_%' ESCAPE '\'
    AND c.relkind IN ('r','p')
    AND (
      has_table_privilege('authenticated', c.oid, 'TRUNCATE')
      OR has_table_privilege('authenticated', c.oid, 'REFERENCES')
      OR has_table_privilege('authenticated', c.oid, 'TRIGGER')
    );
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'AP5 fail: authenticated retains non-application privileges: %', bad;
  END IF;
  RAISE NOTICE 'PASS AP5 authenticated has no TRUNCATE/REFERENCES/TRIGGER on portal tables';

  IF NOT has_function_privilege('service_role', 'public.portal_run_sla()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.portal_recurring_run()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.portal_outbox_claim(integer)', 'EXECUTE')
     OR NOT has_function_privilege(
       'service_role',
       'public.portal_outbox_mark(bigint,boolean,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'AP6 fail: background-job service_role grants regressed';
  END IF;
  RAISE NOTICE 'PASS AP6 background-job RPCs remain service_role-only';

  RAISE NOTICE '════ P0-2C ANON PRIVILEGE BOUNDARY: AP0–AP6 = 7/7 PASS ════';
END
$test$;

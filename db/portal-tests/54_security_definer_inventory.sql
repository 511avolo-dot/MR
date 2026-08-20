-- 54 — exhaustive SECURITY DEFINER execution-boundary inventory.
-- Catalog-driven: every public.portal_* SECURITY DEFINER signature is inspected
-- on every clean build. New signatures cannot silently inherit API execution.
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND p.proname LIKE 'portal\_%' ESCAPE '\'
    AND EXISTS (
      SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'
    );
  IF v_n <> 0 THEN RAISE EXCEPTION 'SDI1 FAIL: % portal definers executable by PUBLIC', v_n; END IF;
  RAISE NOTICE 'PASS SDI1 no portal SECURITY DEFINER is executable by PUBLIC';
END $t$;

DO $t$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND p.proname LIKE 'portal\_%' ESCAPE '\'
    AND (pg_get_userbyid(p.proowner) <> 'postgres'
      OR NOT (
        coalesce(array_to_string(p.proconfig, ','), '') LIKE '%search_path=public%'
        OR coalesce(array_to_string(p.proconfig, ','), '') LIKE '%search_path=""%'
      ));
  IF v_n <> 0 THEN RAISE EXCEPTION 'SDI2 FAIL: % portal definers have unsafe owner/search_path', v_n; END IF;
  RAISE NOTICE 'PASS SDI2 every portal definer is postgres-owned with a pinned safe search_path';
END $t$;

DO $t$
DECLARE v_names text[];
BEGIN
  SELECT coalesce(array_agg(p.proname ORDER BY p.proname), ARRAY[]::text[]) INTO v_names
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND p.proname LIKE 'portal\_%' ESCAPE '\'
    AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF v_names IS DISTINCT FROM ARRAY['portal_supplier_rfq','portal_supplier_submit']::text[] THEN
    RAISE EXCEPTION 'SDI3 FAIL: unexpected anon definer inventory: %', v_names;
  END IF;
  RAISE NOTICE 'PASS SDI3 anon execution is exactly the two supplier-token RPCs';
END $t$;

DO $t$
DECLARE v_n int; v_seen int;
BEGIN
  SELECT count(DISTINCT p.proname) INTO v_seen
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND p.proname IN (
      'portal_audit_write', 'portal_create_token', 'portal_outbox_claim',
      'portal_outbox_mark', 'portal_outbox_purge', 'portal_pr_transition_email',
      'portal_recurring_run', 'portal_supplier_token_request'
    );
  IF v_seen <> 8 THEN RAISE EXCEPTION 'SDI4 FAIL: expected 8 explicit server-routed definer families, found %', v_seen; END IF;

  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND p.proname LIKE 'portal\_%' ESCAPE '\'
    AND p.proname IN (
      'portal_audit_write',
      'portal_create_token',
      'portal_outbox_claim',
      'portal_outbox_mark',
      'portal_outbox_purge',
      'portal_pr_transition_email',
      'portal_recurring_run',
      'portal_supplier_token_request'
    )
    AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE');
  IF v_n <> 0 THEN RAISE EXCEPTION 'SDI4 FAIL: % explicitly server-routed definers unavailable to service_role', v_n; END IF;
  RAISE NOTICE 'PASS SDI4 explicit server-only definer allowlist retains service execution';
END $t$;

DO $t$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND p.proname LIKE 'portal\_%' ESCAPE '\'
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND p.prosrc ~* '\mEXECUTE\M';
  IF v_n <> 0 THEN RAISE EXCEPTION 'SDI5 FAIL: % authenticated definers contain dynamic SQL', v_n; END IF;
  RAISE NOTICE 'PASS SDI5 authenticated definer bodies contain no dynamic SQL';
END $t$;

DO $t$
DECLARE v_names text[];
BEGIN
  SELECT coalesce(array_agg(p.proname ORDER BY p.proname), ARRAY[]::text[]) INTO v_names
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND p.proname LIKE 'portal\_%' ESCAPE '\'
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND p.prosrc ~* '\m(insert|update|delete|truncate)\M'
    AND p.prosrc !~* 'portal_username\s*\(|auth\.uid\s*\(|auth\.jwt\s*\(|request\.jwt\.claims|current_setting\s*\('
    AND p.prosrc !~* 'portal_(has_perm|effective_perm|is_admin|is_service|is_privileged|can_see_request|can_view_quotes|assert_[a-z0-9_]*|require_[a-z0-9_]*)\s*\(';
  IF v_names IS DISTINCT FROM ARRAY['portal_supplier_submit']::text[] THEN
    RAISE EXCEPTION 'SDI6 FAIL: unclassified authenticated mutation definers: %', v_names;
  END IF;
  RAISE NOTICE 'PASS SDI6 every authenticated mutation is body-authorized except the classified token RPC';
END $t$;

DO $t$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND p.proname LIKE 'portal\_%' ESCAPE '\'
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND p.prosrc ~* '\m(insert|update|delete|truncate)\M'
    AND p.prosrc !~* '\mRAISE\s+EXCEPTION\M';
  IF v_n <> 0 THEN RAISE EXCEPTION 'SDI7 FAIL: % mutation definers have no rejection path', v_n; END IF;
  RAISE NOTICE 'PASS SDI7 every authenticated mutation definer has an explicit rejection path';
END $t$;

DO $t$
DECLARE v_names text[];
BEGIN
  SELECT coalesce(array_agg(p.proname ORDER BY p.proname), ARRAY[]::text[]) INTO v_names
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef
    AND p.proname LIKE 'portal\_%' ESCAPE '\'
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND p.prosrc !~* 'portal_username\s*\(|auth\.uid\s*\(|auth\.jwt\s*\(|request\.jwt\.claims|current_setting\s*\('
    AND p.prosrc !~* 'portal_(has_perm|effective_perm|is_admin|is_service|is_privileged|can_see_request|can_view_quotes|assert_[a-z0-9_]*|require_[a-z0-9_]*)\s*\(';
  IF v_names IS DISTINCT FROM ARRAY[
      'portal_committee_route', 'portal_create_expense', 'portal_currency_rate',
      'portal_email_allowed', 'portal_get_committee_policy', 'portal_setting_bool',
      'portal_setting_num', 'portal_sla_hours', 'portal_supplier_rfq',
      'portal_supplier_submit'
    ]::text[] THEN
    RAISE EXCEPTION 'SDI8 FAIL: unreviewed identity-less definer inventory: %', v_names;
  END IF;
  RAISE NOTICE 'PASS SDI8 identity-less definer inventory is exact and review-allowlisted';
END $t$;

DO $t$
DECLARE v_body text;
BEGIN
  SELECT p.prosrc INTO v_body
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'portal_supplier_submit'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_token text, p_items jsonb, p_delivery_days integer, p_payment_days integer, p_note text, p_quote_pdf_key text';
  IF v_body IS NULL
     OR v_body !~* 'WHERE\s+token\s*=\s*p_token\s+FOR\s+UPDATE'
     OR v_body !~* 't\.revoked'
     OR v_body !~* 't\.expires_at\s*<\s*now\s*\(\s*\)'
     OR v_body !~* 'v_phase\s*<>\s*''pricing'''
     OR v_body !~* 'quotes/''\s*\|\|\s*t\.request_id'
  THEN
    RAISE EXCEPTION 'SDI9 FAIL: supplier token mutation gates drifted';
  END IF;
  RAISE NOTICE 'PASS SDI9 supplier mutation pins token, expiry, revocation, phase, lock, and object scope';
END $t$;

DO $t$
DECLARE v_create text; v_scope text; v_quotes text;
BEGIN
  SELECT p.prosrc INTO v_create
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='portal_create_expense'
    AND pg_get_function_identity_arguments(p.oid) LIKE 'p_beneficiary text,%';
  SELECT p.prosrc INTO v_scope
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='portal_can_see_request'
    AND pg_get_function_identity_arguments(p.oid)='p_id text';
  SELECT p.prosrc INTO v_quotes
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='portal_can_view_quotes'
    AND pg_get_function_identity_arguments(p.oid)='p_request_id text';
  IF v_create !~* 'portal_create_expense_draft\s*\('
     OR v_scope !~* 'portal_can_see_request\s*\(r\.id,\s*r\.requester,\s*r\.department_id\)'
     OR v_quotes !~* 'portal_can_see_request\s*\(p_request_id\)'
     OR v_quotes !~* 'portal_effective_perm\s*\('
  THEN
    RAISE EXCEPTION 'SDI10 FAIL: reviewed authorization wrapper drifted';
  END IF;
  RAISE NOTICE 'PASS SDI10 expense and request/quote wrappers preserve the reviewed authorization chain';
END $t$;

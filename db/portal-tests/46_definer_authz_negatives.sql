-- ════════════════════════════════════════════════════════════════════════════
--  46 — per-signature negative-authz for authenticated-executable SECURITY DEFINER
--       write RPCs (Security Advisor closure bar: prove each enforces authz internally).
--  A bare authenticated user (only can_create, dept OPS) must be REJECTED by every
--  privileged write RPC below. Identity via request.jwt.claims (Supabase auth.jwt()).
--  Each RAISE on failure ⇒ non-zero exit (build fails).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 'n46_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id)
    VALUES ('n46_bare','n46_bare@aldeyabi.com','بلا صلاحيات','user','{"can_create":true}','OPS');
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $t$
DECLARE v_n int := 0;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"n46_bare@aldeyabi.com","role":"authenticated"}',true);

  -- N1 portal_save_job (admin-only)
  BEGIN PERFORM portal_save_job('n46job','x','ops','all','{}'::jsonb,'x');
    RAISE EXCEPTION 'N1 FAIL: bare user saved a job';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N1 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N1 portal_save_job denied'; END;

  -- N2 portal_delete_user (admin-only)
  BEGIN PERFORM portal_delete_user('n46_bare');
    RAISE EXCEPTION 'N2 FAIL: bare user deleted a user';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N2 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N2 portal_delete_user denied'; END;

  -- N3 portal_set_committee (admin-only)
  BEGIN PERFORM portal_set_committee('["n46_bare"]'::jsonb);
    RAISE EXCEPTION 'N3 FAIL: bare user set committee';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N3 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N3 portal_set_committee denied'; END;

  -- N4 portal_set_committee_policy (admin-only)
  BEGIN PERFORM portal_set_committee_policy('{"enabled":true}'::jsonb);
    RAISE EXCEPTION 'N4 FAIL: bare user set committee policy';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N4 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N4 portal_set_committee_policy denied'; END;

  -- N5 portal_budget_set (finance/admin only)
  BEGIN PERFORM portal_budget_set('OPS',2026,1000,'x');
    RAISE EXCEPTION 'N5 FAIL: bare user set a budget';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N5 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N5 portal_budget_set denied'; END;

  -- N6 portal_currency_set (admin-only)
  BEGIN PERFORM portal_currency_set('XXX','x',1,true);
    RAISE EXCEPTION 'N6 FAIL: bare user set a currency';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N6 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N6 portal_currency_set denied'; END;

  -- N7 portal_beneficiary_save (finance/procurement/admin only)
  BEGIN PERFORM portal_beneficiary_save(NULL,'x','individual','SA0000000000000000000000','x','x','x','x');
    RAISE EXCEPTION 'N7 FAIL: bare user saved a beneficiary';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N7 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N7 portal_beneficiary_save denied'; END;

  -- N8 portal_save_department (admin-only)
  BEGIN PERFORM portal_save_department('OPS','x','OPS',NULL,true);
    RAISE EXCEPTION 'N8 FAIL: bare user saved a department';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N8 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N8 portal_save_department denied'; END;

  -- N9 portal_recurring_save (finance/procurement/admin only)
  BEGIN PERFORM portal_recurring_save(NULL,'x','OPS',1000,'custody','{}'::jsonb,'monthly',current_date,NULL);
    RAISE EXCEPTION 'N9 FAIL: bare user saved a recurring template';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N9 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N9 portal_recurring_save denied'; END;

  -- N10 portal_delete_department (admin-only)
  BEGIN PERFORM portal_delete_department('LOG');
    RAISE EXCEPTION 'N10 FAIL: bare user deleted a department';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'N10 FAIL%' THEN RAISE; END IF; v_n:=v_n+1; RAISE NOTICE 'PASS N10 portal_delete_department denied'; END;

  IF v_n <> 10 THEN RAISE EXCEPTION 'expected 10 negative-authz passes, got %', v_n; END IF;
  RAISE NOTICE '════ DEFINER AUTHZ NEGATIVES: N1..N10 = 10/10 PASS ════';
END $t$;

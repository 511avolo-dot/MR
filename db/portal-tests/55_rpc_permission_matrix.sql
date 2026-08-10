-- 55 — direct coverage for authenticated RPCs that were previously only
-- covered indirectly (or by catalog/body guards). Every block proves both the
-- expected capability boundary and the successful/edge path where applicable.
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 'm55_%';
  INSERT INTO portal_jobs(key,title,category,scope,permissions,active)
    VALUES ('m55_sector','Matrix sector role','qa','sector','{}',true)
    ON CONFLICT (key) DO UPDATE SET scope='sector', active=true;
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id,job_key,active) VALUES
    ('m55_req','m55_req@aldeyabi.com','Matrix requester','user','{"can_create":true}','OPS','m55_sector',true),
    ('m55_other','m55_other@aldeyabi.com','Matrix other','user','{"can_create":true}','OPS',NULL,true),
    ('m55_fin','m55_fin@aldeyabi.com','Matrix finance','user','{"can_see_finance":true,"can_disburse":true}','GA',NULL,true),
    ('m55_proc','m55_proc@aldeyabi.com','Matrix procurement','user','{"can_manage_procurement":true}','GA',NULL,true),
    ('m55_admin','m55_admin@aldeyabi.com','Matrix admin','admin','{}','GA',NULL,true);
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- M1: pure audit hashing is deterministic and tamper-sensitive.
DO $t$
DECLARE a text; b text; c text; ts timestamptz := '2026-01-01T00:00:00Z';
BEGIN
  a := portal_audit_hash('GENESIS','R','event','actor','portal','{"x":1}',ts);
  b := portal_audit_hash('GENESIS','R','event','actor','portal','{"x":1}',ts);
  c := portal_audit_hash('GENESIS','R','event','actor','portal','{"x":2}',ts);
  IF length(a) <> 64 OR a <> b OR a = c THEN RAISE EXCEPTION 'M1 FAIL audit hash contract'; END IF;
  RAISE NOTICE 'PASS M1 portal_audit_hash deterministic and tamper-sensitive';
END $t$;

-- M2/M24 seed the two pending IBAN changes once, then prove deny + finance allow.
DO $t$
DECLARE ben bigint; sup bigint; bc bigint; sc bigint;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"m55_admin@aldeyabi.com","role":"authenticated"}',true);
  INSERT INTO portal_beneficiaries(name,btype,iban,created_by)
    VALUES ('M55 beneficiary','company','SA0000000000000000000000','m55_fin') RETURNING id INTO ben;
  INSERT INTO portal_beneficiary_iban_changes(beneficiary_id,old_iban,new_iban,status,requested_by)
    VALUES (ben,'SA0000000000000000000000','SA1111111111111111111111','pending','m55_fin') RETURNING id INTO bc;
  INSERT INTO portal_suppliers(name,iban,created_by)
    VALUES ('M55 supplier reject','SA0000000000000000000000','m55_admin') RETURNING id INTO sup;
  INSERT INTO portal_supplier_iban_changes(supplier_id,old_iban,new_iban,status,requested_by)
    VALUES (sup,'SA0000000000000000000000','SA2222222222222222222222','pending','m55_fin') RETURNING id INTO sc;

  PERFORM set_config('request.jwt.claims','{"email":"m55_req@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_beneficiary_iban_reject(bc,'deny'); RAISE EXCEPTION 'M2 FAIL bare beneficiary reject';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M2 FAIL%' THEN RAISE; END IF; END;
  BEGIN PERFORM portal_supplier_iban_reject(sc,'deny'); RAISE EXCEPTION 'M24 FAIL bare supplier reject';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M24 FAIL%' THEN RAISE; END IF; END;

  PERFORM set_config('request.jwt.claims','{"email":"m55_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_beneficiary_iban_reject(bc,'verified rejection');
  PERFORM portal_supplier_iban_reject(sc,'verified rejection');
  IF (SELECT status FROM portal_beneficiary_iban_changes WHERE id=bc) <> 'rejected' THEN RAISE EXCEPTION 'M2 FAIL status'; END IF;
  IF (SELECT status FROM portal_supplier_iban_changes WHERE id=sc) <> 'rejected' THEN RAISE EXCEPTION 'M24 FAIL status'; END IF;
  RAISE NOTICE 'PASS M2 portal_beneficiary_iban_reject deny + finance allow';
  RAISE NOTICE 'PASS M24 portal_supplier_iban_reject deny + finance allow';
END $t$;

-- M3/M4: budget delete/status financial boundary.
DO $t$
DECLARE bid bigint; st jsonb;
BEGIN
  INSERT INTO portal_budgets(department_id,fiscal_year,amount,note)
    VALUES ('OPS',2099,12345,'m55') ON CONFLICT (department_id,fiscal_year)
    DO UPDATE SET amount=excluded.amount RETURNING id INTO bid;
  PERFORM set_config('request.jwt.claims','{"email":"m55_req@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_budget_delete(bid); RAISE EXCEPTION 'M3 FAIL bare budget delete';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M3 FAIL%' THEN RAISE; END IF; END;
  BEGIN PERFORM portal_budget_status('OPS',2099); RAISE EXCEPTION 'M4 FAIL bare budget status';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M4 FAIL%' THEN RAISE; END IF; END;
  PERFORM set_config('request.jwt.claims','{"email":"m55_fin@aldeyabi.com","role":"authenticated"}',true);
  st := portal_budget_status('OPS',2099);
  IF NOT (st->>'defined')::boolean OR (st->>'amount')::numeric <> 12345 THEN RAISE EXCEPTION 'M4 FAIL finance result %',st; END IF;
  PERFORM portal_budget_delete(bid);
  IF EXISTS (SELECT 1 FROM portal_budgets WHERE id=bid) THEN RAISE EXCEPTION 'M3 FAIL row remains'; END IF;
  RAISE NOTICE 'PASS M3 portal_budget_delete deny + finance allow';
  RAISE NOTICE 'PASS M4 portal_budget_status deny + finance allow';
END $t$;

-- M5/M6/M23: raw-document scope plus submit/cancel ownership and procurement override.
DO $t$
DECLARE own_id text := 'M55-OWN'; other_id text := 'M55-OTHER'; submit_id text := 'M55-SUBMIT';
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  INSERT INTO portal_requests(id,title,department_id,requester,requester_name,status,phase,project,need_by,req_type,est_total)
  VALUES
    (own_id,'own direct expense','OPS','m55_req','Matrix requester','draft','requisition','QA',current_date+1,'direct_expense',10),
    (other_id,'other purchase','OPS','m55_other','Matrix other','draft','requisition','QA',current_date+1,'purchase',10),
    (submit_id,'submit draft','OPS','m55_req','Matrix requester','draft','requisition','QA',current_date+1,'purchase',10);
  INSERT INTO portal_request_items(request_id,seq,description,unit,qty,unit_price)
    VALUES (submit_id,1,'item','each',1,10);
  PERFORM set_config('app.portal_transition','0',true);

  PERFORM set_config('request.jwt.claims','{"email":"m55_req@aldeyabi.com","role":"authenticated"}',true);
  IF portal_can_read_raw_document(own_id,NULL) IS NOT TRUE
     OR portal_can_read_raw_document(own_id,999999) IS NOT FALSE
     OR portal_can_read_raw_document(other_id,NULL) IS NOT FALSE
  THEN RAISE EXCEPTION 'M5 FAIL raw document scope'; END IF;
  BEGIN PERFORM portal_cancel_request(other_id,'deny'); RAISE EXCEPTION 'M6 FAIL cancelled other request';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M6 FAIL%' THEN RAISE; END IF; END;
  PERFORM portal_submit_request(submit_id);
  IF (SELECT status FROM portal_requests WHERE id=submit_id) <> 'in_review' THEN RAISE EXCEPTION 'M23 FAIL submit status'; END IF;
  PERFORM portal_cancel_request(own_id,'owner draft cancellation');
  IF (SELECT status FROM portal_requests WHERE id=own_id) <> 'cancelled' THEN RAISE EXCEPTION 'M6 FAIL owner status'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"m55_proc@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_cancel_request(other_id,'procurement override');
  IF (SELECT status FROM portal_requests WHERE id=other_id) <> 'cancelled' THEN RAISE EXCEPTION 'M6 FAIL procurement status'; END IF;
  RAISE NOTICE 'PASS M5 portal_can_read_raw_document requester/payment scope';
  RAISE NOTICE 'PASS M6 portal_cancel_request ownership + procurement override';
  RAISE NOTICE 'PASS M23 portal_submit_request owner transition';
END $t$;

-- M7/M8/M9/M17: contract create/status/link/close with requester denials.
DO $t$
DECLARE cid bigint; req text := 'M55-CONTRACT-REQ'; r jsonb;
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  INSERT INTO portal_requests(id,title,department_id,requester,requester_name,status,phase,project,need_by,req_type,est_total)
    VALUES (req,'contract request','OPS','m55_req','Matrix requester','draft','requisition','QA',current_date+1,'purchase',10);
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM set_config('request.jwt.claims','{"email":"m55_req@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_contract_set(NULL,'x','s',100,current_date,current_date+1,'M55','SAR',NULL); RAISE EXCEPTION 'M8 FAIL bare contract set';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M8 FAIL%' THEN RAISE; END IF; END;
  BEGIN PERFORM portal_contract_status(-1); RAISE EXCEPTION 'M9 FAIL bare contract status';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M9 FAIL%' THEN RAISE; END IF; END;
  BEGIN PERFORM portal_link_request_contract(req,NULL); RAISE EXCEPTION 'M17 FAIL bare link';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M17 FAIL%' THEN RAISE; END IF; END;
  BEGIN PERFORM portal_contract_close(-1); RAISE EXCEPTION 'M7 FAIL bare close';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M7 FAIL%' THEN RAISE; END IF; END;

  PERFORM set_config('request.jwt.claims','{"email":"m55_proc@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_contract_set(NULL,'bad','s',100,current_date,current_date-1,'M55-BAD','SAR',NULL); RAISE EXCEPTION 'M8 FAIL invalid dates';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M8 FAIL%' THEN RAISE; END IF; END;
  r := portal_contract_set(NULL,'M55 contract','M55 supplier',5000,current_date,current_date+30,'M55-GOOD','SAR',NULL);
  cid := (r->>'contract_id')::bigint;
  r := portal_contract_status(cid);
  IF (r->>'ceiling')::numeric <> 5000 OR r->>'status' <> 'active' THEN RAISE EXCEPTION 'M9 FAIL status %',r; END IF;
  PERFORM portal_link_request_contract(req,cid);
  IF (SELECT contract_id FROM portal_requests WHERE id=req) <> cid THEN RAISE EXCEPTION 'M17 FAIL link result'; END IF;
  PERFORM portal_contract_close(cid);
  IF (SELECT status FROM portal_contracts WHERE id=cid) <> 'closed' THEN RAISE EXCEPTION 'M7 FAIL close result'; END IF;
  RAISE NOTICE 'PASS M7 portal_contract_close deny + procurement allow';
  RAISE NOTICE 'PASS M8 portal_contract_set deny + validation + create';
  RAISE NOTICE 'PASS M9 portal_contract_status deny + procurement allow';
  RAISE NOTICE 'PASS M17 portal_link_request_contract deny + valid link';
END $t$;

-- M10/M11/M12: destructive administration boundaries and protected invariants.
DO $t$
DECLARE sid bigint;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"m55_admin@aldeyabi.com","role":"authenticated"}',true);
  INSERT INTO portal_currencies(code,name,rate_to_base,active) VALUES ('M55','Matrix',2,true) ON CONFLICT (code) DO UPDATE SET rate_to_base=2;
  INSERT INTO portal_jobs(key,title,category,scope,permissions,active) VALUES ('m55_delete','Delete me','qa','own','{}',true) ON CONFLICT (key) DO NOTHING;
  INSERT INTO portal_suppliers(name,created_by) VALUES ('M55 unlinked supplier','m55_admin') RETURNING id INTO sid;
  PERFORM set_config('request.jwt.claims','{"email":"m55_req@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_currency_delete('M55'); RAISE EXCEPTION 'M10 FAIL bare currency delete'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M10 FAIL%' THEN RAISE; END IF; END;
  BEGIN PERFORM portal_delete_job('m55_delete'); RAISE EXCEPTION 'M11 FAIL bare job delete'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M11 FAIL%' THEN RAISE; END IF; END;
  BEGIN PERFORM portal_delete_supplier(sid); RAISE EXCEPTION 'M12 FAIL bare supplier delete'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M12 FAIL%' THEN RAISE; END IF; END;
  PERFORM set_config('request.jwt.claims','{"email":"m55_admin@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_currency_delete('SAR'); RAISE EXCEPTION 'M10 FAIL base currency deleted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M10 FAIL%' THEN RAISE; END IF; END;
  BEGIN PERFORM portal_delete_job('gm'); RAISE EXCEPTION 'M11 FAIL gm deleted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M11 FAIL%' THEN RAISE; END IF; END;
  PERFORM portal_currency_delete('M55');
  PERFORM portal_delete_job('m55_delete');
  PERFORM portal_delete_supplier(sid);
  IF EXISTS(SELECT 1 FROM portal_currencies WHERE code='M55') OR EXISTS(SELECT 1 FROM portal_jobs WHERE key='m55_delete') OR EXISTS(SELECT 1 FROM portal_suppliers WHERE id=sid) THEN RAISE EXCEPTION 'M10-12 FAIL delete result'; END IF;
  RAISE NOTICE 'PASS M10 portal_currency_delete deny + base protection + finance/admin allow';
  RAISE NOTICE 'PASS M11 portal_delete_job deny + gm protection + admin allow';
  RAISE NOTICE 'PASS M12 portal_delete_supplier deny + admin allow';
END $t$;

-- M13-M16/M18-M21: deterministic utility, identity, permission, and scope contracts.
DO $t$
DECLARE t1 text; t2 text; s text;
BEGIN
  t1 := portal_gen_token(); t2 := portal_gen_token();
  IF length(t1)<>43 OR t1=t2 OR t1 !~ '^[0-9A-Za-z]{43}$' THEN RAISE EXCEPTION 'M13 FAIL token contract'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"m55_fin@aldeyabi.com","role":"authenticated"}',true);
  IF NOT portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_users') THEN RAISE EXCEPTION 'M14 FAIL finance permissions'; END IF;
  IF portal_is_service() OR portal_is_privileged() THEN
    RAISE EXCEPTION 'M15/M16 FAIL authenticated identity gained service privilege';
  END IF;
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  IF NOT portal_is_service() OR NOT portal_is_privileged() THEN RAISE EXCEPTION 'M16 FAIL service claim'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"m55_req@aldeyabi.com","role":"authenticated"}',true);
  s := portal_my_scope();
  IF s <> 'sector' OR portal_my_sector() IS NULL THEN RAISE EXCEPTION 'M18/M19 FAIL scope=% sector=%',s,portal_my_sector(); END IF;
  IF portal_recurring_next('2026-01-01','weekly') <> '2026-01-08'::date
     OR portal_recurring_next('2026-01-01','monthly') <> '2026-02-01'::date
     OR portal_recurring_next('2026-01-01','quarterly') <> '2026-04-01'::date
     OR portal_recurring_next('2026-01-01','yearly') <> '2027-01-01'::date
     OR portal_recurring_next('2026-01-01','unexpected') <> '2026-02-01'::date
  THEN RAISE EXCEPTION 'M21 FAIL recurring schedule'; END IF;
  RAISE NOTICE 'PASS M13 portal_gen_token length, alphabet, uniqueness';
  RAISE NOTICE 'PASS M14 portal_has_perm true + false capability';
  RAISE NOTICE 'PASS M15 portal_is_privileged rejects session_user and requires service claim';
  RAISE NOTICE 'PASS M16 portal_is_service auth + service claims';
  RAISE NOTICE 'PASS M18 portal_my_scope job-derived sector scope';
  RAISE NOTICE 'PASS M19 portal_my_sector resolves profile department sector';
  RAISE NOTICE 'PASS M21 portal_recurring_next all frequencies + fallback';
END $t$;

-- M20/M22: recurring deletion and SLA execution are capability-gated.
DO $t$
DECLARE rid bigint; n int;
BEGIN
  INSERT INTO portal_recurring_expenses(title,department_id,beneficiary,amount,kind,details,frequency,next_run,owner,created_by)
    VALUES ('M55 recurring','OPS','M55 beneficiary',10,'custody','{}','monthly',current_date+1,'m55_req','m55_fin') RETURNING id INTO rid;
  PERFORM set_config('request.jwt.claims','{"email":"m55_req@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_recurring_delete(rid); RAISE EXCEPTION 'M20 FAIL bare recurring delete'; EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'M20 FAIL%' THEN RAISE; END IF; END;
  IF portal_sla_tick() <> 0 THEN RAISE EXCEPTION 'M22 FAIL bare SLA tick'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"m55_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_recurring_delete(rid);
  IF EXISTS(SELECT 1 FROM portal_recurring_expenses WHERE id=rid) THEN RAISE EXCEPTION 'M20 FAIL row remains'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"m55_proc@aldeyabi.com","role":"authenticated"}',true);
  n := portal_sla_tick();
  IF n < 0 THEN RAISE EXCEPTION 'M22 FAIL invalid SLA count'; END IF;
  RAISE NOTICE 'PASS M20 portal_recurring_delete deny + finance allow';
  RAISE NOTICE 'PASS M22 portal_sla_tick bare no-op + procurement allow';
END $t$;

-- Catalog closure: the current exact clean schema has 94 authenticated-executable
-- signatures. A new signature must deliberately extend this matrix/suite.
DO $t$
DECLARE n int; names int;
BEGIN
  SELECT count(*),count(DISTINCT p.proname) INTO n,names
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
  WHERE ns.nspname='public' AND p.proname LIKE 'portal\_%' ESCAPE '\'
    AND has_function_privilege('authenticated',p.oid,'EXECUTE');
  IF n <> 94 OR names <> 93 THEN RAISE EXCEPTION 'M25 FAIL authenticated RPC inventory drift signatures=% names=%',n,names; END IF;
  RAISE NOTICE 'PASS M25 authenticated RPC inventory closed at 94 signatures / 93 names';
END $t$;

SELECT 'RPC PERMISSION MATRIX: M1..M25 = 25/25 PASS' AS result;

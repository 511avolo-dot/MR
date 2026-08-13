-- 45 -- P0-1l final independent-review regressions
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $duplicate_reconciliation$
DECLARE
  v_rows int;
  v_keys int;
  v_active int;
BEGIN
  SELECT count(*), count(DISTINCT storage_key), count(*) FILTER (WHERE active)
    INTO v_rows, v_keys, v_active
  FROM portal_request_documents
  WHERE request_id = 'REQ-P0L-DUP';

  IF v_rows <> 2 OR v_keys <> 2 OR v_active <> 0 THEN
    RAISE EXCEPTION 'P0L-01 fail: rows=% keys=% active=%', v_rows, v_keys, v_active;
  END IF;
  IF EXISTS (
    SELECT 1 FROM portal_request_documents
    WHERE request_id='REQ-P0L-DUP'
      AND storage_key NOT LIKE 'legacy-quarantine/duplicate/%'
  ) THEN
    RAISE EXCEPTION 'P0L-01 fail: duplicate key was not deterministically quarantined';
  END IF;
  IF to_regclass('public.ux_portal_request_documents_storage_key') IS NULL THEN
    RAISE EXCEPTION 'P0L-01 fail: unique storage-key index is absent';
  END IF;
  RAISE NOTICE 'PASS P0L-01 duplicate pre-P0-1i document keys are preserved but quarantined before UNIQUE';
END;
$duplicate_reconciliation$;

BEGIN;

SELECT set_config('app.portal_transition','1',true);
INSERT INTO portal_users(username,email,display_name,department_id,role,permissions,active)
VALUES ('p0l_finance','p0l_finance@aldeyabi.com','P0L Finance','QA-P0L','user','{"can_see_finance":true}'::jsonb,true)
ON CONFLICT (username) DO UPDATE SET
  email=excluded.email, department_id=excluded.department_id,
  permissions=excluded.permissions, active=true;
INSERT INTO portal_users(username,email,display_name,department_id,role,permissions,active)
VALUES ('p0l_stage','p0l_stage@aldeyabi.com','P0L Stage Approver','QA-P0L','user','{"can_approve_stage":true}'::jsonb,true)
ON CONFLICT (username) DO UPDATE SET
  email=excluded.email, department_id=excluded.department_id,
  permissions=excluded.permissions, active=true;

INSERT INTO portal_requests(
  id,title,department_id,requester,requester_name,est_total,status,phase,
  created_by,req_type,justification
) VALUES (
  'REQ-P0L-PRIVATE','P0L requester safe purchase','QA-P0L','p0l_owner','P0L Owner',
  76543,'in_review','need','p0l_owner','purchase','P0L safe justification'
);
INSERT INTO portal_request_items(request_id,seq,description,unit,qty,unit_price)
VALUES ('REQ-P0L-PRIVATE',1,'P0L secret-priced item','unit',2,38271.5);
INSERT INTO portal_approvals(request_id,cycle,seq,stage_label,resolver,approver,decision,comment)
VALUES ('REQ-P0L-PRIVATE','need',1,'P0L approval','user','p0l_finance','pending','SECRET APPROVAL COMMENT 76543');
INSERT INTO portal_audit(request_id,event,actor,channel,detail)
VALUES ('REQ-P0L-PRIVATE','p0l_secret_event','p0l_finance','portal','{"winner_total":76543,"iban":"SA0000000000000000000000"}'::jsonb);

INSERT INTO portal_requests(
  id,title,department_id,requester,requester_name,est_total,status,phase,
  created_by,req_type,beneficiary,expense_method,expense_details
) VALUES (
  'REQ-P0L-DIRECT','P0L private direct expense','QA-P0L','p0l_owner','P0L Owner',
  900,'draft','need','p0l_owner','direct_expense','P0L Beneficiary','bank',
  '{"iban":"SA1234567890123456789012","account_name":"P0L Private Account","iban_source":"manual"}'::jsonb
);
INSERT INTO portal_approvals(request_id,cycle,seq,stage_label,resolver,approver,decision)
VALUES
  ('REQ-P0L-DIRECT','need',1,'P0L stage approval','user','p0l_stage','pending'),
  ('REQ-P0L-DIRECT','need',2,'P0L finance approval','user','p0l_finance','pending');

UPDATE portal_settings
   SET value=jsonb_set(coalesce(value,'{}'::jsonb),'{expense_docs_required}','0'::jsonb,true)
 WHERE key='portal_settings';
SELECT set_config('app.portal_transition','0',true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0l_owner@aldeyabi.com","role":"authenticated"}',true);

DO $raw_requester_denial$
DECLARE
  v_requests int;
  v_items int;
  v_approvals int;
  v_audit int;
BEGIN
  SELECT count(*) INTO v_requests FROM portal_requests WHERE id='REQ-P0L-PRIVATE';
  SELECT count(*) INTO v_items FROM portal_request_items WHERE request_id='REQ-P0L-PRIVATE';
  SELECT count(*) INTO v_approvals FROM portal_approvals WHERE request_id='REQ-P0L-PRIVATE';
  SELECT count(*) INTO v_audit FROM portal_audit WHERE request_id='REQ-P0L-PRIVATE';
  IF v_requests + v_items + v_approvals + v_audit <> 0 THEN
    RAISE EXCEPTION 'P0L-02 fail: requester raw rows leaked req=% item=% approval=% audit=%',
      v_requests,v_items,v_approvals,v_audit;
  END IF;
  RAISE NOTICE 'PASS P0L-02 purchase requester cannot read raw request/item/approval/audit rows';
END;
$raw_requester_denial$;

DO $safe_dossier$
DECLARE
  v_payload jsonb := portal_my_purchase_dossiers();
  v_row jsonb;
BEGIN
  SELECT r INTO v_row
  FROM jsonb_array_elements(v_payload->'requests') r
  WHERE r->>'id'='REQ-P0L-PRIVATE';
  IF v_row IS NULL OR v_row#>>'{items,0,description}' <> 'P0L secret-priced item' THEN
    RAISE EXCEPTION 'P0L-03 fail: safe purchase dossier is missing the requester row';
  END IF;
  IF v_payload::text LIKE '%76543%'
     OR v_payload::text LIKE '%38271.5%'
     OR v_payload::text LIKE '%SECRET APPROVAL COMMENT%'
     OR v_payload::text LIKE '%SA0000000000000000000000%' THEN
    RAISE EXCEPTION 'P0L-03 fail: financial/audit secret leaked through safe dossier';
  END IF;
  RAISE NOTICE 'PASS P0L-03 requester safe dossier retains workflow data without financial/audit secrets';
END;
$safe_dossier$;

DO $fail_closed_setting$
DECLARE
  v_result jsonb;
  v_id text;
BEGIN
  v_result := portal_create_expense(
    'P0L beneficiary',100,'bank','P0L rollback test','QA-P0L',current_date+3,
    '{"iban":"SA1234567890123456789012","account_name":"P0L Account","iban_manual_reason":"P0L QA"}'::jsonb,
    NULL,NULL
  );
  v_id := v_result->>'id';
  IF v_result->>'needs_documents' <> 'true' OR v_result->>'status' <> 'draft' THEN
    RAISE EXCEPTION 'P0L-04 fail: legacy create path bypassed the document draft: %',v_result;
  END IF;

  BEGIN
    PERFORM portal_submit_expense(v_id);
    RAISE EXCEPTION 'P0L-04 fail: expense_docs_required=0 bypassed verified evidence';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0L-04 fail:%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS P0L-04 expense_docs_required=0 cannot bypass or strand the mandatory evidence workflow';
END;
$fail_closed_setting$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0l_stage@aldeyabi.com","role":"authenticated"}',true);

DO $direct_expense_raw_boundary$
DECLARE
  v_raw int;
  v_safe jsonb;
BEGIN
  SELECT count(*) INTO v_raw FROM portal_requests WHERE id='REQ-P0L-DIRECT';
  SELECT to_jsonb(x) INTO v_safe
  FROM portal_safe_visible_direct_expenses() x
  WHERE x.id='REQ-P0L-DIRECT';
  IF v_raw <> 0 THEN
    RAISE EXCEPTION 'P0L-07 fail: non-finance stage approver can read raw direct expense';
  END IF;
  IF v_safe IS NULL
     OR v_safe#>>'{expense_details,iban}' IS NOT NULL
     OR v_safe::text LIKE '%P0L Private Account%'
     OR v_safe::text LIKE '%SA1234567890123456789012%' THEN
    RAISE EXCEPTION 'P0L-07 fail: safe direct-expense feed missing or leaked bank data: %',v_safe;
  END IF;
  RAISE NOTICE 'PASS P0L-07 non-finance stage approver receives only the redacted direct-expense feed';
END;
$direct_expense_raw_boundary$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0l_finance@aldeyabi.com","role":"authenticated"}',true);

DO $privileged_raw_read$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM portal_requests WHERE id IN ('REQ-P0L-PRIVATE','REQ-P0L-DIRECT');
  IF v_count <> 2 THEN RAISE EXCEPTION 'P0L-05 fail: in-scope finance raw read count=%',v_count; END IF;
  RAISE NOTICE 'PASS P0L-05 in-scope effective finance capability retains the raw operational contract';
END;
$privileged_raw_read$;

RESET ROLE;

DO $function_contract$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef('public.portal_direct_expense_verified_evidence_guard()'::regprocedure)
    INTO v_def;
  IF v_def LIKE '%portal_setting_num%' THEN
    RAISE EXCEPTION 'P0L-06 fail: evidence trigger still honors the unsupported rollback setting';
  END IF;
  IF has_function_privilege('anon','public.portal_can_read_raw_request(text)','EXECUTE') THEN
    RAISE EXCEPTION 'P0L-06 fail: anon can probe raw-request authorization';
  END IF;
  RAISE NOTICE 'PASS P0L-06 evidence trigger is unconditional and anon cannot call the raw-read helper';
END;
$function_contract$;

ROLLBACK;

DO $fixture_cleanup$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_request_documents WHERE request_id='REQ-P0L-DUP';
  DELETE FROM portal_requests WHERE id='REQ-P0L-DUP';
  DELETE FROM portal_users WHERE username='p0l_owner';
  DELETE FROM portal_user_directory WHERE username='p0l_owner';
  DELETE FROM portal_departments WHERE id='QA-P0L';
  PERFORM set_config('app.portal_transition','0',true);
END;
$fixture_cleanup$;

DO $done$ BEGIN
  RAISE NOTICE '==== FINAL INDEPENDENT REVIEW REMEDIATION: P0L-01..07 = 7/7 PASS ====';
END;
$done$;

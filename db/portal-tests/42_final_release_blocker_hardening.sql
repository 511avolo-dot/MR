-- ════════════════════════════════════════════════════════════════════════════
-- 42 — P0-1i final release-blocker regression tests
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

BEGIN;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);

  INSERT INTO portal_departments(id,name_ar,sector,active)
  VALUES ('QA-P0I','QA Final Hardening','QA',true)
  ON CONFLICT (id) DO UPDATE SET name_ar=excluded.name_ar,sector=excluded.sector,active=true;

  INSERT INTO portal_users(username,email,display_name,department_id,role,permissions,active)
  VALUES
    ('p0i_requester','p0i_requester@aldeyabi.com','P0I Requester','QA-P0I','user','{"can_create":true}'::jsonb,true),
    ('p0i_proc','p0i_proc@aldeyabi.com','P0I Procurement','QA-P0I','user','{"can_manage_procurement":true}'::jsonb,true),
    ('p0i_fin1','p0i_fin1@aldeyabi.com','P0I Finance Approver','QA-P0I','user','{"can_disburse":true,"can_see_finance":true}'::jsonb,true),
    ('p0i_fin2','p0i_fin2@aldeyabi.com','P0I Finance Executor','QA-P0I','user','{"can_disburse":true,"can_see_finance":true}'::jsonb,true)
  ON CONFLICT (username) DO UPDATE SET
    email=excluded.email,display_name=excluded.display_name,department_id=excluded.department_id,
    role=excluded.role,permissions=excluded.permissions,active=true;

  INSERT INTO portal_beneficiaries(id,name,btype,iban,account_name,active,created_by)
  VALUES (99004201,'P0I Secret Beneficiary','company','SA1234567890123456789012','P0I Secret Account',true,'p0i_proc')
  ON CONFLICT (id) DO UPDATE SET iban=excluded.iban,account_name=excluded.account_name,active=true;

  DELETE FROM portal_request_documents WHERE request_id IN ('REQ-P0I-PAY','REQ-P0I-DOC');
  DELETE FROM portal_upload_receipts WHERE request_id IN ('REQ-P0I-PAY','REQ-P0I-DOC');
  DELETE FROM portal_payments WHERE request_id IN ('REQ-P0I-PAY','REQ-P0I-DOC');
  DELETE FROM portal_award WHERE request_id='REQ-P0I-PAY';
  DELETE FROM portal_offers WHERE id=99004201;
  DELETE FROM portal_requests WHERE id IN ('REQ-P0I-PAY','REQ-P0I-DOC');

  INSERT INTO portal_requests(id,title,department_id,requester,requester_name,est_total,status,phase,created_by,req_type)
  VALUES
    ('REQ-P0I-PAY','P0I purchase payment','QA-P0I','p0i_requester','P0I Requester',1000,'awarded','payment','p0i_requester','purchase'),
    ('REQ-P0I-DOC','P0I direct document','QA-P0I','p0i_requester','P0I Requester',500,'draft','disbursement','p0i_requester','direct_expense');

  INSERT INTO portal_offers(id,request_id,supplier_name,total,delivery_days,quality,payment_days,entered_by)
  VALUES (99004201,'REQ-P0I-PAY','P0I Supplier',1000,3,90,30,'p0i_proc');

  INSERT INTO portal_award(request_id,winner_offer_id,winner_total,award_reason,status,awarded_by)
  VALUES ('REQ-P0I-PAY',99004201,1000,'P0I award','approved','p0i_proc');

  PERFORM set_config('app.portal_transition','0',true);
END;
$seed$;

-- A. Internal SECURITY DEFINER helpers are no longer public RPCs.
DO $helper_grants$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count
  FROM (VALUES
    ('portal_build_chain(text,text)'::regprocedure),
    ('portal_build_po_chain(text,numeric)'::regprocedure),
    ('portal_open_direct_payment(text,text)'::regprocedure),
    ('portal_effective_approver(text)'::regprocedure),
    ('portal_qualified_approver(text,text)'::regprocedure),
    ('portal_resolve_stage(text,portal_approvals)'::regprocedure),
    ('portal_enqueue_stage_notifications(text,text)'::regprocedure)
  ) f(oid)
  WHERE has_function_privilege('authenticated',f.oid,'EXECUTE');
  IF v_count <> 0 THEN RAISE EXCEPTION 'P0I-01 fail: % internal helpers remain executable',v_count; END IF;
  RAISE NOTICE 'PASS P0I-01 internal SECURITY DEFINER helpers revoked from authenticated';

  IF has_table_privilege('authenticated','portal_upload_receipts','SELECT')
     OR has_table_privilege('authenticated','portal_upload_receipts','INSERT') THEN
    RAISE EXCEPTION 'P0I-02 fail: authenticated can access upload receipts';
  END IF;
  RAISE NOTICE 'PASS P0I-02 upload receipts are service-only';
END;
$helper_grants$;

-- B. Requester cannot see raw beneficiary banking or financial status RPCs.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0i_requester@aldeyabi.com","role":"authenticated"}',true);
DO $requester_privacy$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM portal_beneficiaries WHERE id=99004201;
  IF v_count <> 0 THEN RAISE EXCEPTION 'P0I-03 fail: requester sees beneficiary/IBAN row'; END IF;
  RAISE NOTICE 'PASS P0I-03 requester cannot read raw beneficiary IBAN';

  BEGIN
    PERFORM portal_three_way_status('REQ-P0I-PAY');
    RAISE EXCEPTION 'P0I-04 fail: requester received three-way financial totals';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS P0I-04 requester denied three-way financial totals';
  WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0I-04 fail:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS P0I-04 requester denied three-way financial totals';
  END;

  BEGIN
    PERFORM portal_return_status('REQ-P0I-PAY');
    RAISE EXCEPTION 'P0I-05 fail: requester received return financial totals';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS P0I-05 requester denied return financial totals';
  WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0I-05 fail:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS P0I-05 requester denied return financial totals';
  END;

  BEGIN
    PERFORM portal_attach_document('REQ-P0I-DOC','memo','docs/reqdoc/REQ-P0I-DOC/../fake.pdf','application/pdf','fake',null,'fake.pdf',100,repeat('a',64),null,null);
    RAISE EXCEPTION 'P0I-06 fail: traversal/fabricated key accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0I-06 fail:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS P0I-06 traversal/fabricated document key rejected';
  END;
END;
$requester_privacy$;
RESET ROLE;

-- Valid R2 receipt for requester document.
INSERT INTO portal_upload_receipts(storage_key,request_id,kind,mime_type,size_bytes,checksum,uploaded_by)
VALUES ('docs/reqdoc/REQ-P0I-DOC/12345678.pdf','REQ-P0I-DOC','reqdoc','application/pdf',128,repeat('b',64),'p0i_requester');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0i_requester@aldeyabi.com","role":"authenticated"}',true);
DO $valid_doc$
DECLARE v_result jsonb; v_count int;
BEGIN
  v_result:=portal_attach_document('REQ-P0I-DOC','memo','docs/reqdoc/REQ-P0I-DOC/12345678.pdf','application/pdf','valid',null,'valid.pdf',999,repeat('c',64),null,null);
  IF NOT coalesce((v_result->>'ok')::boolean,false) THEN RAISE EXCEPTION 'P0I-07 fail: valid receipt not accepted'; END IF;
  SELECT count(*) INTO v_count FROM portal_request_documents
   WHERE request_id='REQ-P0I-DOC' AND storage_key='docs/reqdoc/REQ-P0I-DOC/12345678.pdf'
     AND size_bytes=128 AND checksum=repeat('b',64);
  IF v_count<>1 THEN RAISE EXCEPTION 'P0I-07 fail: trusted receipt metadata not persisted'; END IF;
  RAISE NOTICE 'PASS P0I-07 valid receipt consumed and trusted metadata persisted';

  BEGIN
    PERFORM portal_attach_document('REQ-P0I-DOC','memo','docs/reqdoc/REQ-P0I-DOC/12345678.pdf','application/pdf','reuse',null,'reuse.pdf',128,repeat('b',64),null,null);
    RAISE EXCEPTION 'P0I-08 fail: consumed receipt reused';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0I-08 fail:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS P0I-08 upload receipt is exactly-once';
  END;
END;
$valid_doc$;
RESET ROLE;

-- C. Payment request requires evidence; trusted receipt creates linked document.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0i_proc@aldeyabi.com","role":"authenticated"}',true);
DO $payment_missing_doc$
BEGIN
  BEGIN
    PERFORM portal_payment_request('REQ-P0I-PAY','bank',1150,null,'{"iban":"SA1234567890123456789012","account_name":"P0I"}'::jsonb,null);
    RAISE EXCEPTION 'P0I-09 fail: payment created without evidence';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0I-09 fail:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS P0I-09 payment request without evidence rejected';
  END;
END;
$payment_missing_doc$;
RESET ROLE;

INSERT INTO portal_upload_receipts(storage_key,request_id,kind,mime_type,size_bytes,checksum,uploaded_by)
VALUES ('docs/inst/REQ-P0I-PAY/12345678.pdf','REQ-P0I-PAY','inst','application/pdf',256,repeat('d',64),'p0i_proc');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0i_proc@aldeyabi.com","role":"authenticated"}',true);
SELECT set_config(
  'app.p0i_payment_id',
  portal_payment_request('REQ-P0I-PAY','bank',1150,null,
    jsonb_build_object('iban','SA1234567890123456789012','account_name','P0I','proof_key','docs/inst/REQ-P0I-PAY/12345678.pdf'),null)->>'id',
  true
);
RESET ROLE;
DO $payment_with_doc$
DECLARE v_pid bigint := current_setting('app.p0i_payment_id')::bigint; v_count int;
BEGIN
  IF v_pid IS NULL OR NOT EXISTS(SELECT 1 FROM portal_payments WHERE id=v_pid) THEN
    RAISE EXCEPTION 'P0I-10 fail: payment was not created';
  END IF;
  SELECT count(*) INTO v_count FROM portal_request_documents
   WHERE payment_id=v_pid AND storage_key='docs/inst/REQ-P0I-PAY/12345678.pdf'
     AND document_type='advance_payment';
  IF v_count<>1 THEN RAISE EXCEPTION 'P0I-10 fail: payment evidence not linked'; END IF;
  IF NOT EXISTS(SELECT 1 FROM portal_upload_receipts WHERE storage_key='docs/inst/REQ-P0I-PAY/12345678.pdf' AND consumed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'P0I-10 fail: payment receipt not consumed';
  END IF;
  RAISE NOTICE 'PASS P0I-10 payment evidence receipt consumed and linked to payment';
END;
$payment_with_doc$;

-- Finance approver approves. Different finance executor must provide a fresh execution proof.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0i_fin1@aldeyabi.com","role":"authenticated"}',true);
SELECT portal_payment_transition(current_setting('app.p0i_payment_id')::bigint,'approve',null,null,null,null);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0i_fin2@aldeyabi.com","role":"authenticated"}',true);
DO $disburse_missing_proof$
BEGIN
  BEGIN
    PERFORM portal_payment_transition(current_setting('app.p0i_payment_id')::bigint,'disburse',null,null,null,'p0i-no-proof');
    RAISE EXCEPTION 'P0I-11 fail: disbursement executed without proof';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0I-11 fail:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS P0I-11 disbursement without fresh execution proof rejected';
  END;
END;
$disburse_missing_proof$;
RESET ROLE;

INSERT INTO portal_upload_receipts(storage_key,request_id,kind,mime_type,size_bytes,checksum,uploaded_by)
VALUES ('docs/pay/REQ-P0I-PAY/87654321.pdf','REQ-P0I-PAY','pay','application/pdf',300,repeat('e',64),'p0i_fin2');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0i_fin2@aldeyabi.com","role":"authenticated"}',true);
SELECT portal_payment_transition(current_setting('app.p0i_payment_id')::bigint,'disburse',null,null,
  jsonb_build_object('proof_key','docs/pay/REQ-P0I-PAY/87654321.pdf'),'p0i-with-proof');
RESET ROLE;
DO $disburse_with_proof$
DECLARE v_pid bigint := current_setting('app.p0i_payment_id')::bigint; v_count int;
BEGIN
  IF (SELECT status FROM portal_payments WHERE id=v_pid) <> 'disbursed' THEN
    RAISE EXCEPTION 'P0I-12 fail: valid proof did not disburse';
  END IF;
  SELECT count(*) INTO v_count FROM portal_request_documents
   WHERE payment_id=v_pid AND storage_key='docs/pay/REQ-P0I-PAY/87654321.pdf' AND source_stage='payment_execution';
  IF v_count<>1 THEN RAISE EXCEPTION 'P0I-12 fail: execution proof not linked'; END IF;
  IF NOT EXISTS(SELECT 1 FROM portal_upload_receipts WHERE storage_key='docs/pay/REQ-P0I-PAY/87654321.pdf' AND consumed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'P0I-12 fail: execution receipt not consumed';
  END IF;
  RAISE NOTICE 'PASS P0I-12 fresh execution proof required, consumed and linked';
END;
$disburse_with_proof$;

-- D. Owner-approved committee boundary.
DO $doa_boundary$
DECLARE v_125 jsonb; v_125001 jsonb;
BEGIN
  v_125:=portal_committee_route(125000);
  v_125001:=portal_committee_route(125001);
  IF NOT coalesce((v_125->>'use_committee')::boolean,false) THEN RAISE EXCEPTION 'P0I-13 fail: 125000 not in committee band'; END IF;
  IF coalesce((v_125001->>'use_committee')::boolean,false) THEN RAISE EXCEPTION 'P0I-13 fail: 125001 still in committee band'; END IF;
  IF (portal_get_committee_policy()->>'max_amount_inclusive')::numeric<>125000 THEN RAISE EXCEPTION 'P0I-13 fail: published max not 125000'; END IF;
  RAISE NOTICE 'PASS P0I-13 committee band is 25,001–125,000 inclusive';
END;
$doa_boundary$;

ROLLBACK;

\echo '✅ P0-1i: 13 final release-blocker assertions passed.'

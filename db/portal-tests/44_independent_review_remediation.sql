-- 44 -- P0-1k independent review regressions
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

BEGIN;

DO $reconciliation$
DECLARE v_status text; v_decision text;
BEGIN
  SELECT status INTO v_status FROM portal_requests WHERE id='REQ-P0K-INFLIGHT';
  IF v_status <> 'returned' THEN
    RAISE EXCEPTION 'P0K-01 fail: invalid in-flight request stayed runnable: %',v_status;
  END IF;
  RAISE NOTICE 'PASS P0K-01 invalid in-flight direct expense was returned';

  SELECT decision INTO v_decision FROM portal_approvals
   WHERE request_id='REQ-P0K-INFLIGHT' AND cycle='disbursement' AND seq=1;
  IF v_decision <> 'returned' THEN
    RAISE EXCEPTION 'P0K-02 fail: pending in-flight approval stayed runnable: %',v_decision;
  END IF;
  RAISE NOTICE 'PASS P0K-02 pending approval was closed as returned';
END;
$reconciliation$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  INSERT INTO portal_users(username,email,display_name,department_id,role,permissions,active) VALUES
    ('p0k_finance','p0k_finance@aldeyabi.com','P0K Finance','QA-P0K','user','{"can_disburse":true,"can_see_finance":true}'::jsonb,true)
  ON CONFLICT (username) DO UPDATE SET
    email=excluded.email,department_id=excluded.department_id,role=excluded.role,
    permissions=excluded.permissions,active=true;

  DELETE FROM portal_request_documents WHERE request_id LIKE 'REQ-P0K-%' AND request_id<>'REQ-P0K-INFLIGHT';
  DELETE FROM portal_upload_receipts WHERE request_id LIKE 'REQ-P0K-%' AND request_id<>'REQ-P0K-INFLIGHT';
  DELETE FROM portal_payments WHERE request_id LIKE 'REQ-P0K-%' AND request_id<>'REQ-P0K-INFLIGHT';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-P0K-%' AND id<>'REQ-P0K-INFLIGHT';

  INSERT INTO portal_requests(
    id,title,department_id,requester,requester_name,est_total,status,phase,
    created_by,req_type,expense_method,expense_details
  ) VALUES
    ('REQ-P0K-OK','P0K valid evidence','QA-P0K','p0k_owner','P0K Owner',200,'draft','disbursement','p0k_owner','direct_expense','bank','{}'::jsonb),
    ('REQ-P0K-NONE','P0K no evidence','QA-P0K','p0k_owner','P0K Owner',300,'payment_pending','payment','p0k_owner','direct_expense','bank','{}'::jsonb),
    ('REQ-P0K-RECOVER','P0K recovery','QA-P0K','p0k_owner','P0K Owner',400,'payment_pending','payment','p0k_owner','direct_expense','bank','{}'::jsonb);

  INSERT INTO portal_approvals(request_id,cycle,seq,stage_label,resolver,role_key,approver,decision,acted_at)
  VALUES ('REQ-P0K-RECOVER','disbursement',1,'P0K finance','user','can_disburse','p0k_finance','approved',now());
  PERFORM set_config('app.portal_transition','0',true);
END;
$seed$;

INSERT INTO portal_upload_receipts(
  storage_key,request_id,kind,mime_type,size_bytes,checksum,uploaded_by
) VALUES (
  'docs/reqdoc/REQ-P0K-OK/evidence001.pdf','REQ-P0K-OK','reqdoc',
  'application/pdf',128,repeat('a',64),'p0k_owner'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0k_owner@aldeyabi.com","role":"authenticated"}',true);
SELECT portal_attach_document(
  'REQ-P0K-OK','memo','docs/reqdoc/REQ-P0K-OK/evidence001.pdf',
  'application/pdf','P0K evidence',NULL,'evidence.pdf',128,repeat('a',64),NULL,NULL
);
RESET ROLE;

DO $classification$
DECLARE v_stage text; v_verification text;
BEGIN
  SELECT source_stage,verification_status INTO v_stage,v_verification
  FROM portal_request_documents
  WHERE storage_key='docs/reqdoc/REQ-P0K-OK/evidence001.pdf';
  IF v_stage <> 'payment_request' OR v_verification <> 'verified' THEN
    RAISE EXCEPTION 'P0K-03 fail: direct evidence classification=% verification=%',v_stage,v_verification;
  END IF;
  RAISE NOTICE 'PASS P0K-03 receipt-backed direct evidence is classified payment_request';
END;
$classification$;

DO $direct_payment_gate$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  BEGIN
    INSERT INTO portal_payments(request_id,kind,amount,status,requested_by,details)
    VALUES ('REQ-P0K-NONE','bank',300,'approved_pay','p0k_owner','{}'::jsonb);
    RAISE EXCEPTION 'P0K-04 fail: direct payment inserted without evidence';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0K-04 fail:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS P0K-04 direct payment insert is blocked without distinct verified evidence';
  END;

  UPDATE portal_requests
     SET status='payment_pending',phase='payment'
   WHERE id='REQ-P0K-OK';
  INSERT INTO portal_payments(id,request_id,kind,amount,status,requested_by,approved_by,approved_at,details)
  VALUES (99004401,'REQ-P0K-OK','bank',200,'approved_pay','p0k_owner','p0k_finance',now(),'{}'::jsonb);
  PERFORM set_config('app.portal_transition','0',true);
  RAISE NOTICE 'PASS P0K-05 direct payment insert succeeds with distinct verified evidence';
END;
$direct_payment_gate$;

DO $linked_evidence$
DECLARE v_payment_id bigint; v_proof text;
BEGIN
  SELECT payment_id INTO v_payment_id FROM portal_request_documents
   WHERE storage_key='docs/reqdoc/REQ-P0K-OK/evidence001.pdf';
  SELECT details->>'proof_key' INTO v_proof FROM portal_payments WHERE id=99004401;
  IF v_payment_id <> 99004401 OR v_proof <> 'docs/reqdoc/REQ-P0K-OK/evidence001.pdf' THEN
    RAISE EXCEPTION 'P0K-06 fail: evidence was not atomically linked: payment=% proof=%',v_payment_id,v_proof;
  END IF;
  RAISE NOTICE 'PASS P0K-06 verified evidence is atomically linked and copied to the payment';
END;
$linked_evidence$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0k_owner@aldeyabi.com","role":"authenticated"}',true);
DO $status_only_feed$
DECLARE v_pay portal_payments%ROWTYPE;
BEGIN
  SELECT * INTO v_pay FROM portal_safe_visible_payments() WHERE id=99004401;
  IF v_pay.id <> 99004401 OR v_pay.request_id <> 'REQ-P0K-OK' OR v_pay.status <> 'approved_pay' THEN
    RAISE EXCEPTION 'P0K-07 fail: status projection identity/status missing';
  END IF;
  IF v_pay.kind IS NOT NULL OR v_pay.amount IS NOT NULL OR v_pay.custody_to IS NOT NULL
     OR v_pay.requested_by IS NOT NULL OR v_pay.approved_by IS NOT NULL
     OR v_pay.approved_at IS NOT NULL OR v_pay.disbursed_by IS NOT NULL
     OR v_pay.disbursed_at IS NOT NULL OR v_pay.comment IS NOT NULL
     OR v_pay.created_at IS NOT NULL OR v_pay.legacy_evidence_quarantined IS NOT NULL THEN
    RAISE EXCEPTION 'P0K-08 fail: status feed leaked a financial/actor/timestamp field: %',to_jsonb(v_pay);
  END IF;
  RAISE NOTICE 'PASS P0K-07/P0K-08 requester payment feed contains identity and status only';
END;
$status_only_feed$;
RESET ROLE;

DO $legacy_seed$
BEGIN
  ALTER TABLE portal_payments DISABLE TRIGGER USER;
  INSERT INTO portal_payments(
    id,request_id,kind,amount,status,requested_by,details,
    legacy_evidence_quarantined,legacy_evidence_reason,legacy_evidence_quarantined_at
  ) VALUES (
    99004402,'REQ-P0K-RECOVER','bank',400,'approved_pay','p0k_owner','{}'::jsonb,
    true,'P0K test quarantine',now()
  );
  ALTER TABLE portal_payments ENABLE TRIGGER USER;
END;
$legacy_seed$;

INSERT INTO portal_upload_receipts(
  storage_key,request_id,kind,mime_type,size_bytes,checksum,uploaded_by
) VALUES (
  'docs/pay/REQ-P0K-RECOVER/recovery001.pdf','REQ-P0K-RECOVER','pay',
  'application/pdf',256,repeat('b',64),'p0k_finance'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0k_finance@aldeyabi.com","role":"authenticated"}',true);
SELECT portal_recover_legacy_payment_evidence(
  99004402,'docs/pay/REQ-P0K-RECOVER/recovery001.pdf'
);
RESET ROLE;

DO $recovery$
DECLARE v_quarantined boolean; v_n int; v_consumed timestamptz;
BEGIN
  SELECT legacy_evidence_quarantined INTO v_quarantined FROM portal_payments WHERE id=99004402;
  IF v_quarantined IS NOT FALSE THEN
    RAISE EXCEPTION 'P0K-09 fail: recovery did not clear quarantine';
  END IF;
  RAISE NOTICE 'PASS P0K-09 controlled finance recovery clears the legacy quarantine';

  SELECT count(*) INTO v_n FROM portal_request_documents
   WHERE payment_id=99004402 AND request_id='REQ-P0K-RECOVER'
     AND source_stage='payment_request' AND verification_status='verified';
  SELECT consumed_at INTO v_consumed FROM portal_upload_receipts
   WHERE storage_key='docs/pay/REQ-P0K-RECOVER/recovery001.pdf';
  IF v_n <> 1 OR v_consumed IS NULL THEN
    RAISE EXCEPTION 'P0K-10 fail: recovery evidence not verified/consumed: docs=% consumed=%',v_n,v_consumed;
  END IF;
  RAISE NOTICE 'PASS P0K-10 recovery consumes a fresh receipt and creates verified normalized evidence';
END;
$recovery$;

ROLLBACK;
\echo 'P0-1k: 10 independent-review remediation assertions passed.'

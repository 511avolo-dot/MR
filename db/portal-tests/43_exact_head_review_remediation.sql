-- 43 -- P0-1j exact-head review regressions
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
  INSERT INTO portal_departments(id,name_ar,sector,active) VALUES
    ('QA-P0J-A','P0J A','P0JA',true),
    ('QA-P0J-B','P0J B','P0JB',true)
  ON CONFLICT (id) DO UPDATE SET active=true;

  INSERT INTO portal_users(username,email,display_name,department_id,role,permissions,active) VALUES
    ('p0j_owner','p0j_owner@aldeyabi.com','P0J Owner','QA-P0J-A','user','{"can_create_direct_expense":true}'::jsonb,true),
    ('p0j_quote','p0j_quote@aldeyabi.com','P0J Quote','QA-P0J-A','user','{"can_view_quotes":true}'::jsonb,true),
    ('p0j_other','p0j_other@aldeyabi.com','P0J Other','QA-P0J-B','user','{}'::jsonb,true)
  ON CONFLICT (username) DO UPDATE SET
    email=excluded.email,department_id=excluded.department_id,role=excluded.role,
    permissions=excluded.permissions,active=true;

  DELETE FROM portal_request_documents WHERE request_id LIKE 'REQ-P0J-%';
  DELETE FROM portal_upload_receipts WHERE request_id LIKE 'REQ-P0J-%';
  DELETE FROM portal_payments WHERE request_id LIKE 'REQ-P0J-%';
  DELETE FROM portal_supplier_invoices WHERE request_id LIKE 'REQ-P0J-%';
  DELETE FROM portal_returns WHERE request_id LIKE 'REQ-P0J-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-P0J-%';

  INSERT INTO portal_requests(
    id,title,department_id,requester,requester_name,est_total,status,phase,
    created_by,req_type,expense_details
  ) VALUES
    ('REQ-P0J-DIRECT','P0J direct','QA-P0J-A','p0j_owner','P0J Owner',500,'draft','disbursement','p0j_owner','direct_expense',
      '{"iban":"SA1234567890123456789012","account_name":"Secret Name","bank_name":"Secret Bank","iban_source":"manual","iban_entered_by":"p0j_owner","iban_manual_reason":"approved exception"}'::jsonb),
    ('REQ-P0J-QUOTE-OWN','P0J quote own','QA-P0J-A','p0j_quote','P0J Quote',100,'draft','requisition','p0j_quote','purchase',NULL),
    ('REQ-P0J-QUOTE-OTHER','P0J quote other','QA-P0J-B','p0j_other','P0J Other',100,'draft','requisition','p0j_other','purchase',NULL);

  ALTER TABLE portal_payments DISABLE TRIGGER USER;
  INSERT INTO portal_payments(
    id,request_id,kind,amount,status,requested_by,details,
    legacy_evidence_quarantined,legacy_evidence_reason,legacy_evidence_quarantined_at
  ) VALUES (
    99004301,'REQ-P0J-DIRECT','bank',500,'pending_pay','p0j_owner',
    '{"iban":"SA1234567890123456789012","account_name":"Secret Name","proof_key":"docs/pay/REQ-P0J-DIRECT/legacy001.pdf","proof_checksum":"secret"}'::jsonb,
    true,'test legacy quarantine',now()
  ) ON CONFLICT (id) DO UPDATE SET details=excluded.details,status='pending_pay',
      legacy_evidence_quarantined=true,legacy_evidence_reason=excluded.legacy_evidence_reason,
      legacy_evidence_quarantined_at=now();
  ALTER TABLE portal_payments ENABLE TRIGGER USER;

  INSERT INTO portal_supplier_invoices(request_id,supplier_name,invoice_no,amount,recorded_by)
  VALUES ('REQ-P0J-DIRECT','Secret Supplier','P0J-INV',500,'p0j_other')
  ON CONFLICT (request_id,invoice_no) DO UPDATE SET amount=excluded.amount;
  INSERT INTO portal_returns(request_id,supplier_name,reason,debit_amount,created_by)
  VALUES ('REQ-P0J-DIRECT','Secret Supplier','P0J return',25,'p0j_other');

  ALTER TABLE portal_request_documents DISABLE TRIGGER USER;
  INSERT INTO portal_request_documents(
    request_id,payment_id,document_type,title,storage_key,mime_type,size_bytes,
    checksum,uploaded_by,source_stage,verification_status
  ) VALUES (
    'REQ-P0J-DIRECT',99004301,'memo','legacy payment evidence',
    'docs/pay/REQ-P0J-DIRECT/legacy001.pdf','application/pdf',20,repeat('a',64),
    'p0j_owner','payment_request','quarantined'
  );
  ALTER TABLE portal_request_documents ENABLE TRIGGER USER;
  PERFORM set_config('app.portal_transition','0',true);
END;
$seed$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0j_quote@aldeyabi.com","role":"authenticated"}',true);
DO $quote_scope$
BEGIN
  IF NOT portal_can_view_quotes('REQ-P0J-QUOTE-OWN') THEN
    RAISE EXCEPTION 'P0J-01 fail: in-scope quote capability denied';
  END IF;
  RAISE NOTICE 'PASS P0J-01 quote capability works in request scope';
  IF portal_can_view_quotes('REQ-P0J-QUOTE-OTHER') THEN
    RAISE EXCEPTION 'P0J-02 fail: quote capability crossed request scope';
  END IF;
  RAISE NOTICE 'PASS P0J-02 quote capability cannot cross request scope';
END;
$quote_scope$;
RESET ROLE;

DO $accountant_backfill$
BEGIN
  IF NOT coalesce((SELECT (permissions->>'can_create_direct_expense')::boolean
                     FROM portal_jobs WHERE key='fin_accountant'),false) THEN
    RAISE EXCEPTION 'P0J-03 fail: accountant direct-expense capability absent';
  END IF;
  RAISE NOTICE 'PASS P0J-03 fin_accountant capability backfilled';
END;
$accountant_backfill$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0j_owner@aldeyabi.com","role":"authenticated"}',true);
DO $requester_redaction$
DECLARE v_n int; v_details jsonb;
BEGIN
  SELECT count(*) INTO v_n FROM portal_requests WHERE id='REQ-P0J-DIRECT';
  IF v_n<>0 THEN RAISE EXCEPTION 'P0J-04 fail: raw direct-expense row visible'; END IF;
  RAISE NOTICE 'PASS P0J-04 requester denied raw direct-expense row';

  SELECT expense_details INTO v_details FROM portal_safe_visible_direct_expenses()
   WHERE id='REQ-P0J-DIRECT';
  IF v_details ? 'iban' OR v_details ? 'account_name' OR v_details ? 'bank_name'
     OR NOT (v_details ? 'iban_masked')
     OR coalesce((v_details->>'manual_iban_exception')::boolean,false) IS NOT TRUE
     OR v_details->>'iban_manual_reason' <> 'approved exception' THEN
    RAISE EXCEPTION 'P0J-05 fail: unsafe or incomplete direct-expense redaction: %',v_details;
  END IF;
  RAISE NOTICE 'PASS P0J-05 safe direct-expense feed masks IBAN and preserves exception audit markers';

  SELECT count(*) INTO v_n FROM portal_payments WHERE id=99004301;
  IF v_n<>0 THEN RAISE EXCEPTION 'P0J-06 fail: raw payment row visible'; END IF;
  SELECT details INTO v_details FROM portal_safe_visible_payments() WHERE id=99004301;
  IF v_details ? 'iban' OR v_details ? 'account_name' OR v_details ? 'proof_key'
     OR v_details ? 'proof_checksum' THEN
    RAISE EXCEPTION 'P0J-07 fail: payment details not redacted: %',v_details;
  END IF;
  RAISE NOTICE 'PASS P0J-06/P0J-07 requester gets only redacted payment progress';

  SELECT count(*) INTO v_n FROM portal_supplier_invoices WHERE request_id='REQ-P0J-DIRECT';
  IF v_n<>0 THEN RAISE EXCEPTION 'P0J-08 fail: requester sees invoice amount'; END IF;
  SELECT count(*) INTO v_n FROM portal_returns WHERE request_id='REQ-P0J-DIRECT';
  IF v_n<>0 THEN RAISE EXCEPTION 'P0J-09 fail: requester sees return amount'; END IF;
  RAISE NOTICE 'PASS P0J-08/P0J-09 invoice and return financial rows hidden';

  SELECT count(*) INTO v_n FROM portal_request_documents WHERE payment_id=99004301;
  IF v_n<>0 THEN RAISE EXCEPTION 'P0J-10 fail: requester sees payment document metadata'; END IF;
  RAISE NOTICE 'PASS P0J-10 payment document metadata hidden from requester';

  BEGIN
    PERFORM portal_submit_expense('REQ-P0J-DIRECT');
    RAISE EXCEPTION 'P0J-11 fail: quarantined evidence allowed submission';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0J-11 fail:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS P0J-11 quarantined evidence does not satisfy submission gate';
  END;
END;
$requester_redaction$;
RESET ROLE;

INSERT INTO portal_upload_receipts(storage_key,request_id,kind,mime_type,size_bytes,checksum,uploaded_by)
VALUES ('docs/reqdoc/REQ-P0J-DIRECT/verified001.pdf','REQ-P0J-DIRECT','reqdoc','application/pdf',128,repeat('b',64),'p0j_owner');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"email":"p0j_owner@aldeyabi.com","role":"authenticated"}',true);
SELECT portal_attach_document(
  'REQ-P0J-DIRECT','memo','docs/reqdoc/REQ-P0J-DIRECT/verified001.pdf',
  'application/pdf','verified',NULL,'verified.pdf',999,repeat('c',64),NULL,NULL
);
DO $verified_and_quarantine$
DECLARE v_status text;
BEGIN
  SELECT verification_status INTO v_status FROM portal_request_documents
   WHERE storage_key='docs/reqdoc/REQ-P0J-DIRECT/verified001.pdf';
  IF v_status<>'verified' THEN RAISE EXCEPTION 'P0J-12 fail: receipt-backed document not verified'; END IF;
  RAISE NOTICE 'PASS P0J-12 receipt-backed document is verified';
END;
$verified_and_quarantine$;
RESET ROLE;

DO $legacy_payment_gate$
BEGIN
  BEGIN
    UPDATE portal_payments SET status='approved_pay' WHERE id=99004301;
    RAISE EXCEPTION 'P0J-13 fail: quarantined legacy payment transitioned';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'P0J-13 fail:%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS P0J-13 legacy payment transition blocked without verified normalized evidence';
  END;
END;
$legacy_payment_gate$;

ROLLBACK;
\echo 'P0-1j: 13 exact-head remediation assertions passed.'


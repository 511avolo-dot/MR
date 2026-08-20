-- p0_2g: invoice supplier/amount come from the approved award, never client input.
\set ON_ERROR_STOP on
SET client_min_messages = notice;

\ir ../portal-migrations/p0_2g-invoice-award-authority.sql

DO $t$
DECLARE v_offer bigint; v_result jsonb; v_blocked boolean := false;
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_supplier_invoices WHERE request_id='P2G-INV-1';
  DELETE FROM portal_award WHERE request_id='P2G-INV-1';
  DELETE FROM portal_offers WHERE request_id='P2G-INV-1';
  DELETE FROM portal_requests WHERE id='P2G-INV-1';
  DELETE FROM portal_users WHERE username='p2g_fin';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id,active)
    VALUES('p2g_fin','p2g_fin@aldeyabi.com','مالية اختبار الفاتورة','user','{"can_see_finance":true}'::jsonb,'OPS',true);
  INSERT INTO portal_requests(id,title,requester,department_id,status,phase,est_total)
    VALUES('P2G-INV-1','اختبار مرجعية الفاتورة','p2g_fin','OPS','awarded','payment',1000);
  INSERT INTO portal_offers(request_id,supplier_name,total,entered_by)
    VALUES('P2G-INV-1','المورد المعتمد',1000,'p2g_fin') RETURNING id INTO v_offer;
  INSERT INTO portal_award(request_id,winner_offer_id,winner_total,status,awarded_by)
    VALUES('P2G-INV-1',v_offer,1000,'approved','p2g_fin');
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM set_config('request.jwt.claims','{"email":"p2g_fin@aldeyabi.com","role":"authenticated"}',true);

  -- Client sends a forged supplier and amount; the RPC must persist 1,150 SAR and the approved supplier.
  v_result := portal_invoice_record('P2G-INV-1','INV-P2G-1',1,'مورد مزوّر',current_date,NULL,NULL);
  IF (SELECT supplier_name FROM portal_supplier_invoices WHERE request_id='P2G-INV-1') <> 'المورد المعتمد'
    THEN RAISE EXCEPTION 'P2G1 FAIL supplier was not derived from award'; END IF;
  IF (SELECT amount FROM portal_supplier_invoices WHERE request_id='P2G-INV-1') <> 1150
    THEN RAISE EXCEPTION 'P2G1 FAIL amount was not derived from award'; END IF;
  IF v_result->>'amount_source' <> 'approved_award'
    THEN RAISE EXCEPTION 'P2G1 FAIL source marker missing'; END IF;
  RAISE NOTICE 'PASS P2G1 supplier and amount are authoritative';

  BEGIN
    PERFORM portal_invoice_record('P2G-INV-1','INV-P2G-2',999999,'المورد المعتمد',current_date,NULL,NULL);
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'P2G2 FAIL over-invoicing was accepted'; END IF;
  RAISE NOTICE 'PASS P2G2 no invoice can exceed the remaining award';

  IF has_function_privilege('anon','portal_invoice_record(text,text,numeric,text,date,text,text)','EXECUTE')
    OR NOT has_function_privilege('authenticated','portal_invoice_record(text,text,numeric,text,date,text,text)','EXECUTE')
    THEN RAISE EXCEPTION 'P2G3 FAIL RPC grants'; END IF;
  RAISE NOTICE 'PASS P2G3 RPC grants remain fail-closed';

  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_supplier_invoices WHERE request_id='P2G-INV-1';
  DELETE FROM portal_award WHERE request_id='P2G-INV-1';
  DELETE FROM portal_offers WHERE request_id='P2G-INV-1';
  DELETE FROM portal_requests WHERE id='P2G-INV-1';
  DELETE FROM portal_users WHERE username='p2g_fin';
  PERFORM set_config('app.portal_transition','0',true);
END $t$;

SELECT 'INVOICE AWARD AUTHORITY (p0_2g): 3/3 PASS' AS result;

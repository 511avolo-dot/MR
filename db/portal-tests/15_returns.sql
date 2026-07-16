-- ════════════════════════════════════════════════════════════════════════════
--  اختبار المرتجعات + إشعار مدين + صافي المطابقة الثلاثية (الهجرة 034) — تأكيدات.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_dept text; v_ret numeric; v_award numeric; v_net numeric; v_blocked boolean;
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  SELECT id INTO v_dept FROM portal_departments LIMIT 1;

  DELETE FROM portal_payments WHERE request_id LIKE 'REQ-RET-%';
  DELETE FROM portal_returns WHERE request_id LIKE 'REQ-RET-%';
  DELETE FROM portal_supplier_invoices WHERE request_id LIKE 'REQ-RET-%';
  DELETE FROM portal_receipts WHERE request_id LIKE 'REQ-RET-%';
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-RET-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-RET-%';
  DELETE FROM portal_users WHERE username='ret_u';
  UPDATE portal_settings SET value = value - 'three_way_enforce' WHERE key='portal_settings';
  INSERT INTO portal_users(username,email,display_name,role,active) VALUES('ret_u','ret@aldeyabi.com','x','user',true);
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,status,phase,created_at)
    VALUES ('REQ-RET-1','بند','ret_u',v_dept,100000,'awarded','payment',now());
  INSERT INTO portal_award(request_id,winner_total,status,awarded_by) VALUES('REQ-RET-1',100000,'approved','ret_u');

  -- R1: مجموع المرتجعات = قيمة الخصم المسجّلة
  INSERT INTO portal_returns(request_id,supplier_name,reason,lines,debit_amount,debit_note_no,created_by)
    VALUES('REQ-RET-1','مورد أ','تالف عند الاستلام','[{"seq":1,"qty":3,"unit_price":5000,"line_total":15000}]'::jsonb,15000,'DN-RET-1-01','ret_u');
  v_ret := portal_returns_total('REQ-RET-1');
  IF round(v_ret) <> 15000 THEN RAISE EXCEPTION 'R1 fail: returns_total=%', v_ret; END IF;
  RAISE NOTICE 'PASS R1 مجموع المرتجعات = %', round(v_ret);

  -- R2: صافي المستحق = أمر الشراء (115000) − المرتجعات (15000) = 100000
  v_award := portal_award_total('REQ-RET-1');
  v_net := v_award - v_ret;
  IF round(v_award) <> 115000 OR round(v_net) <> 100000 THEN RAISE EXCEPTION 'R2 fail: award=% net=%', v_award, v_net; END IF;
  RAISE NOTICE 'PASS R2 صافي المستحق = أمر الشراء % − المرتجعات % = %', round(v_award), round(v_ret), round(v_net);

  -- R3: المُشغِّل يحترم الصافي — فاتورة 110000 تمرّ ضد أمر الشراء لكن تتجاوز الصافي ⇒ ممنوعة
  UPDATE portal_settings SET value = jsonb_set(coalesce(value,'{}'::jsonb),'{three_way_enforce}','1') WHERE key='portal_settings';
  INSERT INTO portal_receipts(request_id,received_by,lines) VALUES('REQ-RET-1','ret_u','[]'::jsonb);
  INSERT INTO portal_supplier_invoices(request_id,supplier_name,invoice_no,amount,recorded_by)
    VALUES('REQ-RET-1','مورد أ','INV-RET-1',110000,'ret_u');
  v_blocked := false;
  BEGIN INSERT INTO portal_payments(request_id,kind,amount) VALUES('REQ-RET-1','credit',50000);
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'R3 fail: فاتورة تتجاوز صافي المستحق لم تُمنَع'; END IF;
  RAISE NOTICE 'PASS R3 المُشغِّل يحترم صافي المستحق (فاتورة > الصافي = ممنوعة)';

  -- R4: بإزالة المرتجع يعود الصافي = أمر الشراء (115000) ⇒ فاتورة 110000 تمرّ
  DELETE FROM portal_returns WHERE request_id='REQ-RET-1';
  INSERT INTO portal_payments(request_id,kind,amount) VALUES('REQ-RET-1','credit',50000);
  RAISE NOTICE 'PASS R4 بلا مرتجع = الصافي كامل، الفاتورة نفسها تمرّ';

  DELETE FROM portal_payments WHERE request_id LIKE 'REQ-RET-%';
  DELETE FROM portal_supplier_invoices WHERE request_id LIKE 'REQ-RET-%';
  DELETE FROM portal_receipts WHERE request_id LIKE 'REQ-RET-%';
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-RET-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-RET-%';
  DELETE FROM portal_users WHERE username='ret_u';
  UPDATE portal_settings SET value = value - 'three_way_enforce' WHERE key='portal_settings';
  RAISE NOTICE '════ RETURNS: 4/4 PASS ════';
END $t$;

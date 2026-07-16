-- ════════════════════════════════════════════════════════════════════════════
--  اختبار المطابقة الثلاثية + فاتورة المورد (الهجرة 033) — تأكيدات.
--  يختبر مُشغِّل الإنفاذ على portal_payments (الآجل فقط) + احترام شرط الدفع + كشف التكرار.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_dept text; v_blocked boolean;
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  SELECT id INTO v_dept FROM portal_departments LIMIT 1;

  -- تنظيف + طلب + تعميد (100000 ⇒ أمر الشراء 115000 شامل الضريبة)
  DELETE FROM portal_payments WHERE request_id LIKE 'REQ-3W-%';
  DELETE FROM portal_supplier_invoices WHERE request_id LIKE 'REQ-3W-%';
  DELETE FROM portal_receipts WHERE request_id LIKE 'REQ-3W-%';
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-3W-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-3W-%';
  DELETE FROM portal_users WHERE username='tw_u';
  UPDATE portal_settings SET value = value - 'three_way_enforce' WHERE key='portal_settings';
  INSERT INTO portal_users(username,email,display_name,role,active) VALUES('tw_u','tw@aldeyabi.com','x','user',true);
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,status,phase,created_at)
    VALUES ('REQ-3W-1','بند','tw_u',v_dept,100000,'awarded','payment',now());
  INSERT INTO portal_award(request_id,winner_total,status,awarded_by) VALUES('REQ-3W-1',100000,'approved','tw_u');

  -- TW1: الإنفاذ مُطفأ ⇒ صرف آجل يمرّ بلا فاتورة/استلام (لا كسر للسلوك الحالي)
  INSERT INTO portal_payments(request_id,kind,amount) VALUES('REQ-3W-1','credit',50000);
  RAISE NOTICE 'PASS TW1 الإنفاذ مُطفأ = لا مطابقة (لا كسر)';
  DELETE FROM portal_payments WHERE request_id='REQ-3W-1';

  -- فعّل الإنفاذ
  UPDATE portal_settings SET value = jsonb_set(coalesce(value,'{}'::jsonb),'{three_way_enforce}','1') WHERE key='portal_settings';

  -- TW2: آجل + لا استلام ⇒ ممنوع
  v_blocked := false;
  BEGIN INSERT INTO portal_payments(request_id,kind,amount) VALUES('REQ-3W-1','credit',50000);
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TW2 fail: صرف آجل بلا استلام لم يُمنَع'; END IF;
  RAISE NOTICE 'PASS TW2 آجل بلا استلام = ممنوع';

  -- TW3: استلام موجود لكن بلا فاتورة ⇒ ممنوع
  INSERT INTO portal_receipts(request_id,received_by,lines) VALUES('REQ-3W-1','tw_u','[]'::jsonb);
  v_blocked := false;
  BEGIN INSERT INTO portal_payments(request_id,kind,amount) VALUES('REQ-3W-1','credit',50000);
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TW3 fail: صرف آجل بلا فاتورة لم يُمنَع'; END IF;
  RAISE NOTICE 'PASS TW3 استلام بلا فاتورة = ممنوع';

  -- TW4: استلام + فاتورة ضمن أمر الشراء (100000 ≤ 115000) ⇒ مسموح
  INSERT INTO portal_supplier_invoices(request_id,supplier_name,invoice_no,amount,recorded_by)
    VALUES('REQ-3W-1','مورد أ','INV-100',100000,'tw_u');
  INSERT INTO portal_payments(request_id,kind,amount) VALUES('REQ-3W-1','credit',50000);
  RAISE NOTICE 'PASS TW4 استلام + فاتورة مطابقة = مسموح';
  DELETE FROM portal_payments WHERE request_id='REQ-3W-1';

  -- TW5: فاتورة تتجاوز أمر الشراء (إضافة 20000 ⇒ 120000 > 115000) ⇒ ممنوع
  INSERT INTO portal_supplier_invoices(request_id,supplier_name,invoice_no,amount,recorded_by)
    VALUES('REQ-3W-1','مورد أ','INV-101',20000,'tw_u');
  v_blocked := false;
  BEGIN INSERT INTO portal_payments(request_id,kind,amount) VALUES('REQ-3W-1','credit',50000);
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TW5 fail: فاتورة تتجاوز أمر الشراء لم تُمنَع'; END IF;
  RAISE NOTICE 'PASS TW5 فاتورة تتجاوز أمر الشراء = ممنوع';

  -- TW6: صرف كاش (bank) ⇒ مسموح حتى بلا فاتورة (احترام شرط الدفع — لا يُفرض على المقدَّم)
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,status,phase,created_at)
    VALUES ('REQ-3W-2','بند','tw_u',v_dept,100000,'awarded','payment',now());
  INSERT INTO portal_award(request_id,winner_total,status,awarded_by) VALUES('REQ-3W-2',100000,'approved','tw_u');
  INSERT INTO portal_payments(request_id,kind,amount) VALUES('REQ-3W-2','bank',50000);
  RAISE NOTICE 'PASS TW6 صرف كاش (bank) لا يُفرض عليه (شرط الدفع محترم)';

  -- TW7: منع فاتورة مكرّرة بنفس الرقم على نفس الطلب (UNIQUE)
  v_blocked := false;
  BEGIN INSERT INTO portal_supplier_invoices(request_id,supplier_name,invoice_no,amount,recorded_by)
    VALUES('REQ-3W-1','مورد أ','INV-100',5000,'tw_u');
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TW7 fail: فاتورة مكرّرة (نفس الرقم/الطلب) لم تُمنَع'; END IF;
  RAISE NOTICE 'PASS TW7 كشف الفاتورة المكرّرة (UNIQUE)';

  -- تنظيف
  DELETE FROM portal_payments WHERE request_id LIKE 'REQ-3W-%';
  DELETE FROM portal_supplier_invoices WHERE request_id LIKE 'REQ-3W-%';
  DELETE FROM portal_receipts WHERE request_id LIKE 'REQ-3W-%';
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-3W-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-3W-%';
  DELETE FROM portal_users WHERE username='tw_u';
  UPDATE portal_settings SET value = value - 'three_way_enforce' WHERE key='portal_settings';
  RAISE NOTICE '════ THREE-WAY: 7/7 PASS ════';
END $t$;

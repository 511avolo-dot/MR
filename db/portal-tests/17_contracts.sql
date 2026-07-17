-- ════════════════════════════════════════════════════════════════════════════
--  اختبار العقود الإطارية / أوامر الشراء الممتدّة (الهجرة 037) — تأكيدات.
--  يختبر المُستهلَك التراكمي + مُشغِّل الإنفاذ المؤجَّل (السقف + الانتهاء).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_dept text; v_cid bigint; v_used numeric; v_blocked boolean;
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  SELECT id INTO v_dept FROM portal_departments LIMIT 1;

  DELETE FROM portal_award WHERE request_id LIKE 'REQ-CTR-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-CTR-%';
  DELETE FROM portal_contracts WHERE title='عقد-اختبار';
  DELETE FROM portal_users WHERE username='ctr_u';
  UPDATE portal_settings SET value = value - 'contract_enforce' WHERE key='portal_settings';
  INSERT INTO portal_users(username,email,display_name,role,active) VALUES('ctr_u','ctr@aldeyabi.com','x','user',true);

  -- عقد إطاري بسقف 200000 (بعملة الأساس)
  INSERT INTO portal_contracts(title,supplier_name,ceiling,currency,status,start_date,end_date,created_by)
    VALUES('عقد-اختبار','مورد أ',200000,'SAR','active',current_date-10,current_date+300,'ctr_u') RETURNING id INTO v_cid;

  -- أمر سحب 1: تعميد 100000 (=115000 شامل الضريبة) — ضمن السقف
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,status,phase,created_at,contract_id)
    VALUES('REQ-CTR-1','سحب1','ctr_u',v_dept,100000,'awarded','payment',now(),v_cid);
  INSERT INTO portal_award(request_id,winner_total,status,awarded_by) VALUES('REQ-CTR-1',100000,'approved','ctr_u');

  -- K1: المُستهلَك = 115000
  v_used := portal_contract_consumed(v_cid);
  IF round(v_used) <> 115000 THEN RAISE EXCEPTION 'K1 fail: consumed=%', v_used; END IF;
  RAISE NOTICE 'PASS K1 المُستهلَك (أمر سحب واحد) = %', round(v_used);

  -- أمر سحب 2: تعميد 100000 آخر ⇒ الإجمالي 230000 > السقف 200000
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,status,phase,created_at,contract_id)
    VALUES('REQ-CTR-2','سحب2','ctr_u',v_dept,100000,'awarded','payment',now(),v_cid);

  -- K2: الإنفاذ مُفعَّل ⇒ التعميد الذي يتجاوز السقف يُمنَع
  UPDATE portal_settings SET value = jsonb_set(coalesce(value,'{}'::jsonb),'{contract_enforce}','1') WHERE key='portal_settings';
  v_blocked := false;
  BEGIN
    INSERT INTO portal_award(request_id,winner_total,status,awarded_by) VALUES('REQ-CTR-2',100000,'approved','ctr_u');
    SET CONSTRAINTS trg_portal_contract_enforce IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'K2 fail: تجاوز السقف لم يُمنَع'; END IF;
  RAISE NOTICE 'PASS K2 الإنفاذ يمنع تجاوز سقف العقد';

  -- K3: الوضع التحذيري (contract_enforce=0) ⇒ لا يمنع
  UPDATE portal_settings SET value = jsonb_set(value,'{contract_enforce}','0') WHERE key='portal_settings';
  v_blocked := false;
  BEGIN
    INSERT INTO portal_award(request_id,winner_total,status,awarded_by) VALUES('REQ-CTR-2',100000,'approved','ctr_u')
      ON CONFLICT (request_id) DO UPDATE SET winner_total=100000, status='approved';
    SET CONSTRAINTS trg_portal_contract_enforce IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF v_blocked THEN RAISE EXCEPTION 'K3 fail: الوضع التحذيري منع'; END IF;
  RAISE NOTICE 'PASS K3 الوضع التحذيري لا يمنع (أمر سحب مسجّل)';

  -- K4: عقد منتهٍ ⇒ يُمنَع عند الإنفاذ
  UPDATE portal_settings SET value = jsonb_set(value,'{contract_enforce}','1') WHERE key='portal_settings';
  UPDATE portal_contracts SET end_date = current_date - 1 WHERE id = v_cid;
  v_blocked := false;
  BEGIN
    UPDATE portal_award SET winner_total = winner_total WHERE request_id = 'REQ-CTR-1';
    SET CONSTRAINTS trg_portal_contract_enforce IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'K4 fail: العقد المنتهي لم يُمنَع'; END IF;
  RAISE NOTICE 'PASS K4 العقد المنتهي يُمنَع عند الإنفاذ';

  -- K5: طلب بلا عقد ⇒ لا إنفاذ عقود
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,status,phase,created_at)
    VALUES('REQ-CTR-3','بلا عقد','ctr_u',v_dept,500000,'awarded','payment',now());
  v_blocked := false;
  BEGIN
    INSERT INTO portal_award(request_id,winner_total,status,awarded_by) VALUES('REQ-CTR-3',500000,'approved','ctr_u');
    SET CONSTRAINTS trg_portal_contract_enforce IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN v_blocked := true; END;
  IF v_blocked THEN RAISE EXCEPTION 'K5 fail: طلب بلا عقد مُنع'; END IF;
  RAISE NOTICE 'PASS K5 طلب بلا عقد = لا إنفاذ';

  -- تنظيف
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-CTR-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-CTR-%';
  DELETE FROM portal_contracts WHERE id = v_cid;
  DELETE FROM portal_users WHERE username='ctr_u';
  UPDATE portal_settings SET value = value - 'contract_enforce' WHERE key='portal_settings';
  RAISE NOTICE '════ CONTRACTS: 5/5 PASS ════';
END $t$;

-- ════════════════════════════════════════════════════════════════════════════
--  اختبار أساس تعدّد العملات (الهجرة 035) — تأكيدات.
--  يختبر سعر التحويل + وعي دوال القيمة بالعملة (لعملة الأساس).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_dept text; v_sar numeric; v_usd numeric; v_comm numeric; v_yr int := EXTRACT(YEAR FROM now())::int;
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  SELECT id INTO v_dept FROM portal_departments LIMIT 1;

  DELETE FROM portal_award WHERE request_id LIKE 'REQ-CUR-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-CUR-%';
  DELETE FROM portal_users WHERE username='cur_u';
  DELETE FROM portal_currencies WHERE code='USD';
  INSERT INTO portal_users(username,email,display_name,role,active) VALUES('cur_u','cur@aldeyabi.com','x','user',true);
  INSERT INTO portal_currencies(code,name,rate_to_base,active) VALUES('USD','دولار',3.75,true)
    ON CONFLICT (code) DO UPDATE SET rate_to_base=3.75, active=true;

  -- C1: سعر التحويل (الأساس=1، USD=3.75، المفقود=1)
  IF portal_currency_rate('SAR') <> 1 THEN RAISE EXCEPTION 'C1 fail: SAR<>1'; END IF;
  IF portal_currency_rate('USD') <> 3.75 THEN RAISE EXCEPTION 'C1 fail: USD<>3.75'; END IF;
  IF portal_currency_rate('XXX') <> 1 THEN RAISE EXCEPTION 'C1 fail: المفقود يجب أن يكون 1'; END IF;
  IF portal_currency_rate(NULL) <> 1 THEN RAISE EXCEPTION 'C1 fail: NULL يجب أن يكون 1'; END IF;
  RAISE NOTICE 'PASS C1 سعر التحويل (SAR=1 · USD=3.75 · مفقود/NULL=1)';

  -- C2: أمر شراء بعملة SAR = 100×1.15×1 = 115
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,status,phase,created_at,currency)
    VALUES('REQ-CUR-1','بند','cur_u',v_dept,100,'awarded','payment',now(),'SAR');
  INSERT INTO portal_award(request_id,winner_total,status,awarded_by) VALUES('REQ-CUR-1',100,'approved','cur_u');
  v_sar := portal_award_total('REQ-CUR-1');
  IF round(v_sar) <> 115 THEN RAISE EXCEPTION 'C2 fail: SAR award=%', v_sar; END IF;
  RAISE NOTICE 'PASS C2 أمر الشراء بالريال = %', round(v_sar);

  -- C3: أمر شراء بعملة USD = 100×1.15×3.75 = 431.25 (محوَّل لعملة الأساس)
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,status,phase,created_at,currency)
    VALUES('REQ-CUR-2','بند','cur_u',v_dept,100,'awarded','payment',now(),'USD');
  INSERT INTO portal_award(request_id,winner_total,status,awarded_by) VALUES('REQ-CUR-2',100,'approved','cur_u');
  v_usd := portal_award_total('REQ-CUR-2');
  IF round(v_usd) <> 431 THEN RAISE EXCEPTION 'C3 fail: USD award=% (متوقّع 431.25)', v_usd; END IF;
  RAISE NOTICE 'PASS C3 أمر الشراء بالدولار محوَّل لعملة الأساس = %', round(v_usd*100)/100;

  -- C4: المرتبط (الميزانية) يجمع القيم المحوَّلة لعملة الأساس
  v_comm := portal_budget_committed(v_dept, v_yr);
  IF round(v_comm) <> round(v_sar + v_usd) THEN RAISE EXCEPTION 'C4 fail: committed=% متوقّع=%', v_comm, v_sar+v_usd; END IF;
  RAISE NOTICE 'PASS C4 المرتبط يجمع بعملة الأساس = %', round(v_comm*100)/100;

  -- تنظيف
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-CUR-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-CUR-%';
  DELETE FROM portal_users WHERE username='cur_u';
  DELETE FROM portal_currencies WHERE code='USD';
  RAISE NOTICE '════ CURRENCY: 4/4 PASS ════';
END $t$;

-- ════════════════════════════════════════════════════════════════════════════
--  اختبار ضبط الميزانية (الهجرة 031) — تأكيدات.
--  يختبر منطق «المرتبط» ومُشغِّل الإنفاذ المؤجَّل (كلاهما بلا استدعاء هوية).
--  إعداد الصفوف بإدراج مباشر + علم الانتقال (كـpostgres).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_dept text; v_committed numeric; v_blocked boolean; v_off_a bigint; v_off_b bigint;
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  SELECT id INTO v_dept FROM portal_departments LIMIT 1;
  IF v_dept IS NULL THEN RAISE EXCEPTION 'setup: لا أقسام مبذورة'; END IF;

  -- تنظيف
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-BUD-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-BUD-%';
  DELETE FROM portal_budgets WHERE fiscal_year = 2099;
  DELETE FROM portal_users WHERE username = 'bud_u';
  UPDATE portal_settings SET value = value - 'budget_enforce' WHERE key='portal_settings';

  -- مستخدم + طلب + تعميد (سنة 2099، قيمة 100000)
  INSERT INTO portal_users(username,email,display_name,role,active)
    VALUES ('bud_u','bud_u@aldeyabi.com','م. الميزانية','user',true);
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,project,status,phase,created_at)
    VALUES ('REQ-BUD-1','بند','bud_u',v_dept,100000,'مشروع','awarded','payment','2099-01-01');
  INSERT INTO portal_award(request_id,winner_total,status,awarded_by)
    VALUES ('REQ-BUD-1',100000,'approved','bud_u');

  -- B1: المرتبط = 100000 × 1.15 = 115000
  v_committed := portal_budget_committed(v_dept, 2099);
  IF round(v_committed) <> 115000 THEN RAISE EXCEPTION 'B1 fail: committed=%', v_committed; END IF;
  RAISE NOTICE 'PASS B1 المرتبط شامل الضريبة = %', round(v_committed);

  -- B2: ميزانية 50000 + إنفاذ مُفعَّل ⇒ يمنع (تجاوز)
  INSERT INTO portal_budgets(department_id,fiscal_year,amount,active) VALUES (v_dept,2099,50000,true);
  UPDATE portal_settings SET value = jsonb_set(coalesce(value,'{}'::jsonb),'{budget_enforce}','1') WHERE key='portal_settings';
  v_blocked := false;
  BEGIN
    UPDATE portal_award SET winner_total = winner_total WHERE request_id = 'REQ-BUD-1';
    SET CONSTRAINTS trg_portal_budget_enforce IMMEDIATE;   -- يفرض الفحص المؤجَّل الآن
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'B2 fail: التجاوز لم يُمنَع رغم الإنفاذ'; END IF;
  RAISE NOTICE 'PASS B2 الإنفاذ يمنع التجاوز';

  -- B3: وضع تحذيري (budget_enforce=0) ⇒ لا يمنع
  UPDATE portal_settings SET value = jsonb_set(value,'{budget_enforce}','0') WHERE key='portal_settings';
  v_blocked := false;
  BEGIN
    UPDATE portal_award SET winner_total = winner_total WHERE request_id = 'REQ-BUD-1';
    SET CONSTRAINTS trg_portal_budget_enforce IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;
  IF v_blocked THEN RAISE EXCEPTION 'B3 fail: الوضع التحذيري منع (يجب ألا يمنع)'; END IF;
  RAISE NOTICE 'PASS B3 الوضع التحذيري لا يمنع';

  -- B4: بلا ميزانية معرّفة ⇒ لا إنفاذ حتى مع budget_enforce=1
  DELETE FROM portal_budgets WHERE fiscal_year = 2099;
  UPDATE portal_settings SET value = jsonb_set(value,'{budget_enforce}','1') WHERE key='portal_settings';
  v_blocked := false;
  BEGIN
    UPDATE portal_award SET winner_total = winner_total WHERE request_id = 'REQ-BUD-1';
    SET CONSTRAINTS trg_portal_budget_enforce IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
  END;
  IF v_blocked THEN RAISE EXCEPTION 'B4 fail: مُنع رغم عدم وجود ميزانية معرّفة'; END IF;
  RAISE NOTICE 'PASS B4 بلا ميزانية = لا إنفاذ';

  -- B5: ترسية مجزّأة تُحسب بمجموع بنودها لا winner_total وحده
  INSERT INTO portal_requests(id,title,requester,department_id,est_total,project,status,phase,created_at)
    VALUES ('REQ-BUD-2','بند','bud_u',v_dept,0,'مشروع','awarded','payment','2099-06-01');
  INSERT INTO portal_award(request_id,winner_total,status,awarded_by)
    VALUES ('REQ-BUD-2',30000,'approved','bud_u');  -- المهيمن 30000 فقط
  INSERT INTO portal_offers(request_id,supplier_name,total) VALUES ('REQ-BUD-2','مورد أ',30000) RETURNING id INTO v_off_a;
  INSERT INTO portal_offers(request_id,supplier_name,total) VALUES ('REQ-BUD-2','مورد ب',20000) RETURNING id INTO v_off_b;
  INSERT INTO portal_award_lines(request_id,item_seq,offer_id,supplier_name,qty,unit_price,line_total)
    VALUES ('REQ-BUD-2',1,v_off_a,'مورد أ',1,30000,30000),
           ('REQ-BUD-2',2,v_off_b,'مورد ب',1,20000,20000); -- إجمالي حقيقي 50000
  -- committed للطلب المجزّأ = 50000×1.15 = 57500 (لا 30000×1.15)
  v_committed := portal_budget_committed(v_dept, 2099);
  -- المجموع الكلي = REQ-BUD-1 (115000) + REQ-BUD-2 (57500) = 172500
  IF round(v_committed) <> 172500 THEN RAISE EXCEPTION 'B5 fail: المجزّأ حُسب خطأ، committed=%', v_committed; END IF;
  RAISE NOTICE 'PASS B5 المجزّأ يُحسب بمجموع البنود (=%)', round(v_committed);

  -- تنظيف
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-BUD-%';
  DELETE FROM portal_award_lines WHERE request_id LIKE 'REQ-BUD-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-BUD-%';
  DELETE FROM portal_budgets WHERE fiscal_year = 2099;
  DELETE FROM portal_users WHERE username = 'bud_u';
  UPDATE portal_settings SET value = value - 'budget_enforce' WHERE key='portal_settings';
  RAISE NOTICE '════ BUDGET: 5/5 PASS ════';
END $t$;

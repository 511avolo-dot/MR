-- 56 — p0_2d: توسيع صلاحية إلغاء الطلب لمدير القسم/القطاع ضمن نافذة ما قبل الالتزام.
--   يثبت: مدير القسم/القطاع يُلغي (صرف مباشر/شراء) قبل الالتزام؛ غير المدير يُمنَع؛
--   لا إلغاء بعد صرف منفَّذ؛ لا إلغاء لطلب شراء بعد التعميد؛ صلاحية المُقدّم محفوظة.
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_payments WHERE request_id LIKE 'C2-%';
  DELETE FROM portal_requests WHERE id LIKE 'C2-%';
  DELETE FROM portal_users WHERE username LIKE 'c2\_%';
  DELETE FROM portal_departments WHERE id LIKE 'C2%';
  INSERT INTO portal_departments(id,name_ar,sector,manager_user,active) VALUES
    ('C2D','قسم اختبار الإلغاء','C2SEC',NULL,true),
    ('C2D2','قسم آخر بنفس القطاع','C2SEC',NULL,true);
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id,active) VALUES
    ('c2_req','c2_req@aldeyabi.com','مقدّم','user','{"can_create":true}','C2D',true),
    ('c2_mgr','c2_mgr@aldeyabi.com','مدير القسم','user','{"can_approve_stage":true}','C2D',true),
    ('c2_secmgr','c2_secmgr@aldeyabi.com','مدير القطاع','user','{"can_approve_stage":true}','C2D2',true),
    ('c2_other','c2_other@aldeyabi.com','مستخدم آخر','user','{"can_create":true}','OPS',true);
  UPDATE portal_departments SET manager_user='c2_mgr'    WHERE id='C2D';
  UPDATE portal_departments SET manager_user='c2_secmgr' WHERE id='C2D2';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

CREATE OR REPLACE FUNCTION _c2_mkreq(p_id text, p_type text, p_status text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_payments WHERE request_id=p_id;
  DELETE FROM portal_requests WHERE id=p_id;
  INSERT INTO portal_requests(id,title,requester,department_id,req_type,status,est_total)
    VALUES (p_id,'طلب اختبار الإلغاء','c2_req','C2D',p_type,p_status,1000);
  PERFORM set_config('app.portal_transition','0',true);
END $$;

-- C1: غير المدير (قسم آخر) يُمنَع من إلغاء طلب صرف قيد المراجعة.
DO $t$
BEGIN
  PERFORM _c2_mkreq('C2-EXP1','direct_expense','in_review');
  PERFORM set_config('request.jwt.claims','{"email":"c2_other@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_cancel_request('C2-EXP1','لا صلاحية'); RAISE EXCEPTION 'C1 FAIL non-manager cancelled';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'C1 FAIL%' THEN RAISE; END IF; END;
  IF (SELECT status FROM portal_requests WHERE id='C2-EXP1') <> 'in_review' THEN RAISE EXCEPTION 'C1 FAIL status changed'; END IF;
  RAISE NOTICE 'PASS C1 non-manager denied cancel';
END $t$;

-- C2: مدير القسم يُلغي طلب الصرف قيد المراجعة.
DO $t$
BEGIN
  PERFORM _c2_mkreq('C2-EXP2','direct_expense','in_review');
  PERFORM set_config('request.jwt.claims','{"email":"c2_mgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_cancel_request('C2-EXP2','قرار مدير القسم');
  IF (SELECT status FROM portal_requests WHERE id='C2-EXP2') <> 'cancelled' THEN RAISE EXCEPTION 'C2 FAIL not cancelled'; END IF;
  RAISE NOTICE 'PASS C2 dept manager cancels direct-expense in_review';
END $t$;

-- C3: مدير القطاع (مدير قسم آخر بنفس القطاع) يُلغي طلب الصرف.
DO $t$
BEGIN
  PERFORM _c2_mkreq('C2-EXP3','direct_expense','in_review');
  PERFORM set_config('request.jwt.claims','{"email":"c2_secmgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_cancel_request('C2-EXP3','قرار مدير القطاع');
  IF (SELECT status FROM portal_requests WHERE id='C2-EXP3') <> 'cancelled' THEN RAISE EXCEPTION 'C3 FAIL not cancelled'; END IF;
  RAISE NOTICE 'PASS C3 sector manager cancels direct-expense';
END $t$;

-- C4: بعد صرف منفَّذ (disbursed) لا يُلغي مدير القسم طلب الصرف.
DO $t$
BEGIN
  PERFORM _c2_mkreq('C2-EXP4','direct_expense','payment_pending');
  -- بناء حالة «صرف منفَّذ» للاختبار فقط: تجاوز مُشغِّل قواعد الصرف المباشر (session_replication_role)
  -- كي نُثبت أنّ حارس الإلغاء يرفض بعد disbursed — بلا حاجة لبناء سلسلة اعتماد+مستند كاملة.
  PERFORM set_config('app.portal_transition','1',true);
  SET session_replication_role = replica;
  INSERT INTO portal_payments(request_id,kind,amount,status) VALUES ('C2-EXP4','direct',1000,'disbursed');
  SET session_replication_role = origin;
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM set_config('request.jwt.claims','{"email":"c2_mgr@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_cancel_request('C2-EXP4','بعد الصرف'); RAISE EXCEPTION 'C4 FAIL cancel after disbursed';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'C4 FAIL%' THEN RAISE; END IF; END;
  IF (SELECT status FROM portal_requests WHERE id='C2-EXP4') <> 'payment_pending' THEN RAISE EXCEPTION 'C4 FAIL status changed'; END IF;
  RAISE NOTICE 'PASS C4 manager denied cancel after disbursed';
END $t$;

-- C5: الشراء — مدير القسم يُلغي قبل التعميد (in_review) لكن يُمنَع بعده (awarded).
DO $t$
BEGIN
  PERFORM _c2_mkreq('C2-PUR1','purchase','awarded');
  PERFORM set_config('request.jwt.claims','{"email":"c2_mgr@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_cancel_request('C2-PUR1','بعد التعميد'); RAISE EXCEPTION 'C5 FAIL cancel after award';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'C5 FAIL%' THEN RAISE; END IF; END;
  IF (SELECT status FROM portal_requests WHERE id='C2-PUR1') <> 'awarded' THEN RAISE EXCEPTION 'C5 FAIL status changed'; END IF;
  PERFORM _c2_mkreq('C2-PUR2','purchase','in_review');
  PERFORM portal_cancel_request('C2-PUR2','قبل التعميد');
  IF (SELECT status FROM portal_requests WHERE id='C2-PUR2') <> 'cancelled' THEN RAISE EXCEPTION 'C5 FAIL pre-award not cancelled'; END IF;
  RAISE NOTICE 'PASS C5 purchase: manager cancels pre-award, denied post-award';
END $t$;

-- C6: صلاحية المُقدّم محفوظة (in_review) — عدم الانحدار.
DO $t$
BEGIN
  PERFORM _c2_mkreq('C2-EXP6','direct_expense','in_review');
  PERFORM set_config('request.jwt.claims','{"email":"c2_req@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_cancel_request('C2-EXP6','المُقدّم ألغى');
  IF (SELECT status FROM portal_requests WHERE id='C2-EXP6') <> 'cancelled' THEN RAISE EXCEPTION 'C6 FAIL requester cancel'; END IF;
  RAISE NOTICE 'PASS C6 requester cancel preserved (no regression)';
END $t$;

DROP FUNCTION _c2_mkreq(text,text,text);
SELECT 'CANCEL BY MANAGERS (p0_2d): C1..C6 = 6/6 PASS' AS result;

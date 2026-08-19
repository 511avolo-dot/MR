-- 59 — p0_2f: every active employee can create, and an expense requester may cancel
-- at payment_pending only while no disbursement exists.
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_payments WHERE request_id LIKE 'P2F-%';
  DELETE FROM portal_requests WHERE id LIKE 'P2F-%';
  DELETE FROM portal_users WHERE username = 'p2f_req';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id,job_key,active)
  VALUES ('p2f_req','p2f_req@aldeyabi.com','مقدّم بلا وظيفة','user','{}','OPS',NULL,true);
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

\ir ../../supabase/migrations/20260819084945_p0_2f_portal_consistency_hotfix.sql

CREATE OR REPLACE FUNCTION _p2f_mkreq(p_id text, p_type text, p_status text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_payments WHERE request_id=p_id;
  DELETE FROM portal_requests WHERE id=p_id;
  INSERT INTO portal_requests(id,title,requester,department_id,req_type,status,est_total)
  VALUES (p_id,'طلب اختبار اتساق البوابة','p2f_req','OPS',p_type,p_status,1000);
  PERFORM set_config('app.portal_transition','0',true);
END $$;

-- P2F1: an active non-admin without a job receives can_create directly.
DO $t$
BEGIN
  IF coalesce((SELECT (permissions->>'can_create')::boolean FROM portal_users WHERE username='p2f_req'),false) = false
    THEN RAISE EXCEPTION 'P2F1 FAIL active no-job user lacks can_create'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"p2f_req@aldeyabi.com","role":"authenticated"}',true);
  IF NOT portal_has_perm('can_create') THEN RAISE EXCEPTION 'P2F1 FAIL effective can_create denied'; END IF;
  RAISE NOTICE 'PASS P2F1 active no-job user can create';
END $t$;

-- P2F2: the requester may cancel a direct expense awaiting payment.
DO $t$
BEGIN
  PERFORM _p2f_mkreq('P2F-EXP1','direct_expense','payment_pending');
  PERFORM set_config('request.jwt.claims','{"email":"p2f_req@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_cancel_request('P2F-EXP1','إلغاء قبل الصرف');
  IF (SELECT status FROM portal_requests WHERE id='P2F-EXP1') <> 'cancelled'
    THEN RAISE EXCEPTION 'P2F2 FAIL request not cancelled'; END IF;
  RAISE NOTICE 'PASS P2F2 requester cancels direct expense before disbursement';
END $t$;

-- P2F3: the same requester is denied after a disbursement was recorded.
DO $t$
BEGIN
  PERFORM _p2f_mkreq('P2F-EXP2','direct_expense','payment_pending');
  PERFORM set_config('app.portal_transition','1',true);
  SET session_replication_role = replica;
  INSERT INTO portal_payments(request_id,kind,amount,status) VALUES ('P2F-EXP2','direct',1000,'disbursed');
  SET session_replication_role = origin;
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM set_config('request.jwt.claims','{"email":"p2f_req@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_cancel_request('P2F-EXP2','محاولة بعد الصرف');
    RAISE EXCEPTION 'P2F3 FAIL disbursed request cancelled';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'P2F3 FAIL%' THEN RAISE; END IF; END;
  IF (SELECT status FROM portal_requests WHERE id='P2F-EXP2') <> 'payment_pending'
    THEN RAISE EXCEPTION 'P2F3 FAIL status changed'; END IF;
  RAISE NOTICE 'PASS P2F3 requester denied after disbursement';
END $t$;

-- P2F4: purchase cancellation is not expanded past award.
DO $t$
BEGIN
  PERFORM _p2f_mkreq('P2F-PUR1','purchase','awarded');
  PERFORM set_config('request.jwt.claims','{"email":"p2f_req@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_cancel_request('P2F-PUR1','محاولة بعد التعميد');
    RAISE EXCEPTION 'P2F4 FAIL awarded purchase cancelled';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'P2F4 FAIL%' THEN RAISE; END IF; END;
  IF (SELECT status FROM portal_requests WHERE id='P2F-PUR1') <> 'awarded'
    THEN RAISE EXCEPTION 'P2F4 FAIL status changed'; END IF;
  RAISE NOTICE 'PASS P2F4 requester still denied after purchase award';
END $t$;

DROP FUNCTION _p2f_mkreq(text,text,text);
SELECT 'PORTAL CONSISTENCY HOTFIX (p0_2f): P2F1..P2F4 = 4/4 PASS' AS result;

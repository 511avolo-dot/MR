-- ════════════════════════════════════════════════════════════════════════════
--  23 — الإعادة الذكية للتصحيح (الهجرة 043): تعديل الطلب المُعاد عبر الـRPC الفعلية.
--  يثبت أنّ حلقة «إرجاع → تعديل فعلي → إعادة تقديم → إعادة اعتماد» تعمل كاملةً، وأنّ
--  الحوكمة لا تُخترق. انتحال هوية JWT (كعب auth.jwt مطابق لدلالات Supabase).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 'rw_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('rw_req','rw_req@aldeyabi.com','مقدّم','user','{"can_create":true}','OPS'),
    ('rw_ops','rw_ops@aldeyabi.com','مدير','user','{"can_approve_stage":true}','OPS'),
    ('rw_fin','rw_fin@aldeyabi.com','مالية','user','{"can_approve_finance":true,"can_approve_stage":true,"can_see_finance":true}','GA'),
    ('rw_pm','rw_pm@aldeyabi.com','مشتريات','user','{"can_manage_procurement":true,"can_edit":true,"can_approve_award":true,"can_create":true}','GA'),
    ('rw_wh','rw_wh@aldeyabi.com','مستودع','user','{"can_verify_stock":true}','OPS');
  UPDATE portal_departments SET manager_user='rw_ops' WHERE id='OPS';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- ═══ R1 — إرجاع للمقدّم → تعديل فعلي (كميّة/إجمالي) → إعادة تقديم → اعتماد ═══
DO $r1$
DECLARE v_id text; v_r jsonb; v_est0 numeric; v_est1 numeric; v_rev int; v_status text; v_pending int; v_it int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"rw_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب للتصحيح','OPS','متوسط','[{"desc":"بند","unit":"عدد","qty":10,"price":1000}]','مشروع',(now()+interval '10 day')::date,'single','ج');
  v_id := v_r->>'id';
  SELECT est_total INTO v_est0 FROM portal_requests WHERE id=v_id;  -- 10000
  -- مرحلة 1: المالية ترجع للمقدّم للتعديل (p_return_to_seq=0)
  PERFORM set_config('request.jwt.claims','{"email":"rw_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"rw_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'return','عدّل الكمية للبند',NULL,0);
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'returned' THEN RAISE EXCEPTION 'R1a fail: توقّعت returned حصلت %', v_status; END IF;
  RAISE NOTICE 'PASS R1a إرجاع للمقدّم → returned';
  -- المقدّم يعدّل فعلاً: كميّة 10→25، سعر 1000→1200، بند إضافي
  PERFORM set_config('request.jwt.claims','{"email":"rw_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_update_request(v_id,'طلب مُعدَّل',
    '[{"desc":"بند مُعدَّل","unit":"عدد","qty":25,"price":1200},{"desc":"بند جديد","unit":"عدد","qty":2,"price":500}]',
    'مشروع مُعدَّل','عالٍ',(now()+interval '12 day')::date,'single','مبرّر مُحدَّث');
  v_est1 := (v_r->>'est_total')::numeric;  -- 25*1200 + 2*500 = 31000
  v_rev := (v_r->>'revision')::int;
  IF v_est1 <> 31000 THEN RAISE EXCEPTION 'R1b fail: الإجمالي لم يُحدَّث (توقّعت 31000 حصلت %)', v_est1; END IF;
  IF v_rev <> 1 THEN RAISE EXCEPTION 'R1b fail: عدّاد المراجعة خطأ %', v_rev; END IF;
  -- تأكيد البنود فعلاً تغيّرت في القاعدة
  SELECT count(*) INTO v_it FROM portal_request_items WHERE request_id=v_id;
  IF v_it <> 2 THEN RAISE EXCEPTION 'R1b fail: عدد البنود لم يتغيّر (%)', v_it; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_request_items WHERE request_id=v_id AND description='بند مُعدَّل' AND qty=25 AND unit_price=1200) THEN
    RAISE EXCEPTION 'R1b fail: التعديل لم يُحفَظ في البنود';
  END IF;
  RAISE NOTICE 'PASS R1b تعديل فعلي: الإجمالي 10000→31000 · بنود مُستبدَلة · revision=1';
  -- كل الاعتمادات صُفّرت (المرحلة 1 المعتمَدة عادت pending)
  SELECT count(*) INTO v_pending FROM portal_approvals WHERE request_id=v_id AND decision='pending';
  IF v_pending <> (SELECT count(*) FROM portal_approvals WHERE request_id=v_id) THEN
    RAISE EXCEPTION 'R1c fail: لم تُصفَّر كل الاعتمادات بعد التعديل';
  END IF;
  RAISE NOTICE 'PASS R1c التعديل صفّر كل اعتمادات الحاجة (إعادة اعتماد كاملة)';
  -- إعادة تقديم → in_review، ثم اعتماد كامل حتى pricing على المحتوى الجديد
  v_r := portal_resubmit_request(v_id);
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'in_review' THEN RAISE EXCEPTION 'R1d fail: إعادة التقديم لم تُرجِع in_review'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"rw_ops@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"rw_fin@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"rw_pm@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_pr_transition(v_id,'approve','تسعير');
  SELECT phase INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'pricing' THEN RAISE EXCEPTION 'R1d fail: لم يصل pricing بعد إعادة الاعتماد (%)', v_status; END IF;
  RAISE NOTICE 'PASS R1d إعادة تقديم → إعادة اعتماد كاملة على المحتوى الجديد → pricing';
END $r1$;

-- ═══ R2 — الحُرّاس (زيرو أخطاء) ═══
DO $r2$
DECLARE v_id text; v_r jsonb; v_blk boolean;
BEGIN
  -- تجهيز طلب في حالة returned
  PERFORM set_config('request.jwt.claims','{"email":"rw_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب حراس','OPS','متوسط','[{"desc":"x","unit":"عدد","qty":1,"price":500}]','مشروع',(now()+interval '5 day')::date,'single','ج');
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"rw_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'return','أعِد النظر',NULL,0);

  -- G1: غير المقدّم وغير can_edit وغير أدمن لا يُعدّل (المستودع)
  PERFORM set_config('request.jwt.claims','{"email":"rw_wh@aldeyabi.com","role":"authenticated"}',true);
  v_blk := false;
  BEGIN PERFORM portal_update_request(v_id,'اختراق','[{"desc":"x","unit":"عدد","qty":1,"price":9}]','م','متوسط',(now()+interval '5 day')::date,'single','ج');
  EXCEPTION WHEN OTHERS THEN v_blk := true; END;
  IF NOT v_blk THEN RAISE EXCEPTION 'G1 fail: غير المخوَّل عدّل الطلب'; END IF;
  RAISE NOTICE 'PASS G1 التعديل مقيَّد بالمقدّم/can_edit/أدمن';

  -- G2: can_edit (المشتريات) يستطيع التعديل نيابةً
  PERFORM set_config('request.jwt.claims','{"email":"rw_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_update_request(v_id,'تعديل مشتريات','[{"desc":"مُصحَّح","unit":"عدد","qty":3,"price":400}]','م','متوسط',(now()+interval '6 day')::date,'single','ج');
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'G2 fail: can_edit لم يستطع التعديل'; END IF;
  RAISE NOTICE 'PASS G2 حامل can_edit يعدّل نيابةً عن المقدّم';

  -- G3: لا تعديل لطلب ليس returned (نُعيد تقديمه ثم نحاول)
  PERFORM set_config('request.jwt.claims','{"email":"rw_req@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_resubmit_request(v_id);   -- الآن in_review
  v_blk := false;
  BEGIN PERFORM portal_update_request(v_id,'بعد الإرسال','[{"desc":"x","unit":"عدد","qty":1,"price":1}]','م','متوسط',(now()+interval '5 day')::date,'single','ج');
  EXCEPTION WHEN OTHERS THEN v_blk := true; END;
  IF NOT v_blk THEN RAISE EXCEPTION 'G3 fail: عُدِّل طلب ليس في حالة returned'; END IF;
  RAISE NOTICE 'PASS G3 لا تعديل إلا لطلب مُعاد (returned) — يمنع التعديل بعد الإرسال/التعميد';
END $r2$;

SELECT '════ REWORK/EDIT (043): كل التأكيدات نجحت ════' AS result;

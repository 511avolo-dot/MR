-- ════════════════════════════════════════════════════════════════════════════
--  24 — إعادة فتح التعميد من طور الصرف (الهجرة 044): تصحيح العروض/الأسعار قبل التنفيذ.
--  يثبت أنّ خيار «إعادة فتح التعميد» (p_return_to='award') يعيد الطلب للتسعير فعلاً
--  (يُبطِل التعميد/الصرف/سلاسل الاعتماد، يُبقي العروض)، ويمنعه بعد تنفيذ أي صرف.
--  انتحال هوية JWT (كعب auth.jwt مطابق لدلالات Supabase).
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
  DELETE FROM portal_users WHERE username LIKE 'rp_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('rp_req','rp_req@aldeyabi.com','مقدّم','user','{"can_create":true}','OPS'),
    ('rp_ops','rp_ops@aldeyabi.com','مدير','user','{"can_approve_stage":true}','OPS'),
    ('rp_fin','rp_fin@aldeyabi.com','مالية','user','{"can_approve_finance":true,"can_approve_stage":true,"can_see_finance":true,"can_disburse":true}','GA'),
    ('rp_pm','rp_pm@aldeyabi.com','مشتريات','user','{"can_manage_procurement":true,"can_approve_award":true,"can_issue_po":true,"can_create":true}','GA'),
    ('rp_aw2','rp_aw2@aldeyabi.com','معتمِد تعميد','user','{"can_approve_award":true}','GA'),
    ('rp_acc','rp_acc@aldeyabi.com','محاسب','user','{"can_disburse":true,"can_see_finance":true}','GA');
  UPDATE portal_departments SET manager_user='rp_ops' WHERE id='OPS';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- ═══ RP1 — دورة كاملة: تعميد A → صرف → إعادة فتح التعميد → تسعير → إعادة تعميد B → صرف ═══
DO $rp1$
DECLARE v_id text; v_r jsonb; v_oA bigint; v_oB bigint; v_pay bigint; v_status text; v_phase text; v_noff int; v_nlines int; v_award text;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"rp_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب إعادة فتح','OPS','متوسط','[{"desc":"بند","unit":"عدد","qty":10,"price":1500}]','مشروع',(now()+interval '10 day')::date);
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"rp_ops@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"rp_fin@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"rp_pm@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_pr_transition(v_id,'approve','تسعير');
  -- عرضان (المطلوب عرض واحد للشريحة ≤25K)
  v_r := portal_submit_offer(v_id,'مورد-A',15000,7,90,30,'A',NULL,'[{"seq":1,"price":1500}]'); v_oA:=(v_r->>'id')::bigint;
  v_r := portal_submit_offer(v_id,'مورد-B',16000,7,90,30,'B',NULL,'[{"seq":1,"price":1600}]'); v_oB:=(v_r->>'id')::bigint;
  v_r := portal_award(v_id,v_oA,NULL);
  PERFORM set_config('request.jwt.claims','{"email":"rp_aw2@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_award_transition(v_id,'approve','معتمَد');
  SELECT phase INTO v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase<>'payment' THEN RAISE EXCEPTION 'RP1a fail: توقّعت payment حصلت %', v_phase; END IF;
  -- المشتريات تُصدر الصرف
  PERFORM set_config('request.jwt.claims','{"email":"rp_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_payment_request(v_id,'custody',17250,'rp_acc','{}'::jsonb,NULL); v_pay:=(v_r->>'id')::bigint;
  RAISE NOTICE 'PASS RP1a دورة حتى إصدار الصرف (تعميد A)';
  -- المالية تكتشف خطأ سعر/عرض → «إعادة فتح التعميد»
  PERFORM set_config('request.jwt.claims','{"email":"rp_fin@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_payment_transition(v_pay,'return','سعر البند خاطئ — أعيدوا التسعير','award',NULL);
  IF (v_r->>'status')<>'pricing' THEN RAISE EXCEPTION 'RP1b fail: توقّعت pricing حصلت %', v_r->>'status'; END IF;
  SELECT status,phase INTO v_status,v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase<>'pricing' THEN RAISE EXCEPTION 'RP1b fail: الطلب لم يعُد للتسعير (%)', v_phase; END IF;
  SELECT status INTO v_award FROM portal_award WHERE request_id=v_id;
  IF v_award<>'rejected' THEN RAISE EXCEPTION 'RP1b fail: التعميد لم يُبطَل (%)', v_award; END IF;
  IF (SELECT status FROM portal_payments WHERE id=v_pay)<>'returned' THEN RAISE EXCEPTION 'RP1b fail: الصرف لم يُبطَل'; END IF;
  RAISE NOTICE 'PASS RP1b إعادة فتح التعميد → pricing + إبطال التعميد + إبطال الصرف';
  -- العروض تبقى (للتصحيح/إعادة الاختيار)
  SELECT count(*) INTO v_noff FROM portal_offers WHERE request_id=v_id AND NOT superseded;
  IF v_noff<>2 THEN RAISE EXCEPTION 'RP1c fail: العروض لم تبقَ (%)', v_noff; END IF;
  RAISE NOTICE 'PASS RP1c العروض تبقى ظاهرة للتصحيح/إعادة الاختيار (%)', v_noff;
  -- المشتريات تُرسي المورد الآخر B (تصحيح الاختيار) → إعادة اعتماد → صرف
  PERFORM set_config('request.jwt.claims','{"email":"rp_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_award(v_id,v_oB,'تصحيح: المورد A اعتذر');
  PERFORM set_config('request.jwt.claims','{"email":"rp_aw2@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_award_transition(v_id,'approve','معتمَد ثانية');
  SELECT phase INTO v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase<>'payment' THEN RAISE EXCEPTION 'RP1d fail: إعادة التعميد لم تصل payment (%)', v_phase; END IF;
  IF (SELECT winner_offer_id FROM portal_award WHERE request_id=v_id)<>v_oB THEN RAISE EXCEPTION 'RP1d fail: الفائز لم يتغيّر للمورد B'; END IF;
  RAISE NOTICE 'PASS RP1d إعادة تعميد المورد B → إعادة اعتماد كاملة → payment (التصحيح نجح)';
END $rp1$;

-- ═══ RP2 — الحارس: يُمنَع إعادة فتح التعميد بعد تنفيذ أي صرف (مجزّأ: A مصروف، B معلّق) ═══
DO $rp2$
DECLARE v_id text; v_r jsonb; v_oA bigint; v_oB bigint; v_pA bigint; v_pB bigint; v_blk boolean;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"rp_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب مجزّأ حارس','OPS','متوسط',
    '[{"desc":"أ","unit":"عدد","qty":10,"price":100},{"desc":"ب","unit":"عدد","qty":5,"price":200}]','مشروع',(now()+interval '14 day')::date,'single','ج');
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"rp_ops@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"rp_fin@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"rp_pm@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_pr_transition(v_id,'approve','تسعير');
  v_r := portal_submit_offer(v_id,'مورد-A',0,7,90,30,'A',NULL,'[{"seq":1,"price":90},{"seq":2,"price":210}]'); v_oA:=(v_r->>'id')::bigint;
  v_r := portal_submit_offer(v_id,'مورد-B',0,7,90,30,'B',NULL,'[{"seq":1,"price":110},{"seq":2,"price":190}]'); v_oB:=(v_r->>'id')::bigint;
  v_r := portal_award_split(v_id, ('[{"seq":1,"offer_id":'||v_oA||'},{"seq":2,"offer_id":'||v_oB||'}]')::jsonb, NULL);
  PERFORM set_config('request.jwt.claims','{"email":"rp_aw2@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_award_transition(v_id,'approve','ok');
  -- صرف A (منفَّذ) + إصدار B (معلّق)
  PERFORM set_config('request.jwt.claims','{"email":"rp_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_payment_request(v_id,'bank',1035,NULL,'{"iban":"SA0380000000608010167519","account_name":"A"}'::jsonb,v_oA); v_pA:=(v_r->>'id')::bigint;
  v_r := portal_payment_request(v_id,'bank',1092.5,NULL,'{"iban":"SA4420000001234567891234","account_name":"B"}'::jsonb,v_oB); v_pB:=(v_r->>'id')::bigint;
  PERFORM set_config('request.jwt.claims','{"email":"rp_fin@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_payment_transition(v_pA,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"rp_acc@aldeyabi.com","role":"authenticated"}',true); PERFORM portal_payment_transition(v_pA,'disburse','تنفيذ A','{}','{}'::jsonb);
  -- محاولة إعادة فتح التعميد عبر إرجاع صرف B → يجب أن تُمنَع (A منفَّذ)
  PERFORM set_config('request.jwt.claims','{"email":"rp_fin@aldeyabi.com","role":"authenticated"}',true);
  v_blk:=false;
  BEGIN PERFORM portal_payment_transition(v_pB,'return','محاولة إعادة فتح','award',NULL);
  EXCEPTION WHEN OTHERS THEN v_blk:=true; END;
  IF NOT v_blk THEN RAISE EXCEPTION 'RP2 fail: أُعيد فتح التعميد رغم وجود صرف منفَّذ'; END IF;
  RAISE NOTICE 'PASS RP2 مُنِع إعادة فتح التعميد بعد تنفيذ صرف (المال خرج)';
END $rp2$;

SELECT '════ REOPEN-AWARD (044): كل التأكيدات نجحت ════' AS result;

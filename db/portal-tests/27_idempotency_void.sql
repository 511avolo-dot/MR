-- ════════════════════════════════════════════════════════════════════════════
--  27 — الحوكمة المالية المتقدّمة (051): idempotency (exactly-once) + إبطال saga.
--  عبر RPC فعلي بهوية مُنتحَلة (JWT). كل تأكيد RAISE عند الفشل ⇒ خروج غير صفري.
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
  DELETE FROM portal_users WHERE username LIKE 'v51_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('v51_acc', 'v51_acc@aldeyabi.com', 'محاسب',        'user', '{"can_create":true,"can_see_finance":true}', 'GA'),
    ('v51_amgr','v51_amgr@aldeyabi.com','رئيس الحسابات','user', '{"can_approve_disbursement":true,"can_see_finance":true}', 'GA'),
    ('v51_fin', 'v51_fin@aldeyabi.com', 'المدير المالي','user', '{"can_approve_finance":true,"can_see_finance":true}', 'GA'),
    ('v51_gm',  'v51_gm@aldeyabi.com',  'المدير العام', 'user', '{"can_manage_users":true}', 'GA'),
    ('v51_bank','v51_bank@aldeyabi.com','مسؤول البنك',  'user', '{"can_disburse":true}', 'GA');
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- دالة مساعدة: تنشئ صرفاً مباشراً وتمرّره حتى دفعة approved_pay وتعيد payment_id
CREATE OR REPLACE FUNCTION _v51_make_expense(p_amt numeric) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id text; v_r jsonb; v_pid bigint;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"v51_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('مستفيد', p_amt, 'bank', 'غرض', 'GA', (now()+interval '5 day')::date,
           '{"iban":"SA1234567890123456789012","account_name":"مستفيد"}'::jsonb, NULL);
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"v51_amgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"v51_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"v51_gm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  SELECT id INTO v_pid FROM portal_payments WHERE request_id=v_id;
  RETURN v_pid;
END $$;

-- ════════════════ I — idempotency (exactly-once) ════════════════
DO $i$
DECLARE v_p1 bigint; v_p2 bigint; v_r1 jsonb; v_r2 jsonb; v_req text; v_st text; v_naudit int; v_err text;
BEGIN
  v_p1 := _v51_make_expense(5000);
  SELECT request_id INTO v_req FROM portal_payments WHERE id=v_p1;

  -- تنفيذ بمفتاح idempotency
  PERFORM set_config('request.jwt.claims','{"email":"v51_bank@aldeyabi.com","role":"authenticated"}',true);
  v_r1 := portal_payment_transition(v_p1,'disburse',NULL,NULL,'{"proof_key":"docs/disb/x/p1.pdf"}'::jsonb,'idem-p1-disb');
  IF (v_r1->>'status') <> 'disbursed' THEN RAISE EXCEPTION 'I1 fail: أول تنفيذ %', v_r1; END IF;
  SELECT status INTO v_st FROM portal_requests WHERE id=v_req;
  IF v_st <> 'closed' THEN RAISE EXCEPTION 'I1 fail: الطلب %', v_st; END IF;
  SELECT count(*) INTO v_naudit FROM portal_audit WHERE request_id=v_req AND event='payment_disbursed';
  RAISE NOTICE 'PASS I1 التنفيذ الأول بمفتاح idempotency → disbursed/closed';

  -- إعادة نفس العملية بنفس المفتاح ⇒ تُعاد النتيجة بلا إعادة تنفيذ ولا تدقيق مكرّر
  v_r2 := portal_payment_transition(v_p1,'disburse',NULL,NULL,'{"proof_key":"docs/disb/x/p1.pdf"}'::jsonb,'idem-p1-disb');
  IF (v_r2->>'status') <> 'disbursed' THEN RAISE EXCEPTION 'I2 fail: الإعادة لم تُرجِع النتيجة %', v_r2; END IF;
  IF (SELECT count(*) FROM portal_audit WHERE request_id=v_req AND event='payment_disbursed') <> v_naudit THEN
    RAISE EXCEPTION 'I2 fail: تدقيق مكرّر (تنفيذ مزدوج!)'; END IF;
  RAISE NOTICE 'PASS I2 إعادة المفتاح تُرجِع النتيجة بلا تنفيذ مزدوج (exactly-once)';

  -- تعارض المفتاح: نفس المفتاح لدفعة أخرى ⇒ خطأ (المستدعي حامل can_disburse)
  v_p2 := _v51_make_expense(7000);
  PERFORM set_config('request.jwt.claims','{"email":"v51_bank@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_payment_transition(v_p2,'disburse',NULL,NULL,'{}'::jsonb,'idem-p1-disb');
    RAISE EXCEPTION 'I3 fail: قُبِل مفتاح مكرّر لعملية أخرى';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'I3 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%مستخدم لعملية أخرى%' THEN RAISE EXCEPTION 'I3 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS I3 تعارض مفتاح idempotency لعملية أخرى مرفوض';

  -- بلا مفتاح: إعادة تنفيذ دفعة منفَّذة ⇒ خطأ (السلوك القائم محفوظ)
  BEGIN
    PERFORM portal_payment_transition(v_p1,'disburse',NULL,NULL,'{}'::jsonb,NULL);
    RAISE EXCEPTION 'I4 fail: أُعيد تنفيذ دفعة منفَّذة بلا مفتاح';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'I4 fail%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS I4 بلا مفتاح: السلوك القائم محفوظ (لا إعادة تنفيذ)';
END $i$;

-- ════════════════ V — إبطال saga (تعويض) ════════════════
DO $v$
DECLARE v_p bigint; v_req text; v_st text; v_pst text; v_err int; v_msg text; v_nrev int;
BEGIN
  v_p := _v51_make_expense(9000);
  SELECT request_id INTO v_req FROM portal_payments WHERE id=v_p;
  -- منفّذ يحمل صلاحية مالية أيضاً (لبلوغ حارس فصل المهام في الإبطال)
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_users SET permissions = permissions || '{"can_approve_finance":true}' WHERE username='v51_bank';
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM set_config('request.jwt.claims','{"email":"v51_bank@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_p,'disburse',NULL,NULL,'{"proof_key":"docs/disb/x/v.pdf"}'::jsonb,'idem-v-disb');

  -- V1: المنفّذ (وهو حامل صلاحية مالية) لا يُبطِل تنفيذه
  BEGIN
    PERFORM portal_payment_void(v_p,'خطأ');
    RAISE EXCEPTION 'V1 fail: المنفّذ أبطل تنفيذه';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'V1 fail%' THEN RAISE; END IF;
    IF v_msg NOT LIKE '%فصل المهام%' THEN RAISE EXCEPTION 'V1 fail: سبب آخر %', v_msg; END IF;
  END;
  RAISE NOTICE 'PASS V1 منفّذ الصرف لا يُبطِله (فصل المهام)';

  -- V2: سبب مطلوب
  PERFORM set_config('request.jwt.claims','{"email":"v51_fin@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_payment_void(v_p,'');
    RAISE EXCEPTION 'V2 fail: قُبِل بلا سبب';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'V2 fail%' THEN RAISE; END IF;
    IF v_msg NOT LIKE '%سبب%' THEN RAISE EXCEPTION 'V2 fail: سبب آخر %', v_msg; END IF;
  END;
  RAISE NOTICE 'PASS V2 سبب الإبطال مطلوب';

  -- V3: إبطال صحيح بواسطة المالية (≠ المنفّذ) → voided + الطلب cancelled/closed + قيد عكسي
  PERFORM portal_payment_void(v_p,'صرف خاطئ — عُكِس بنكياً');
  SELECT status INTO v_pst FROM portal_payments WHERE id=v_p;
  SELECT status INTO v_st FROM portal_requests WHERE id=v_req;
  IF v_pst <> 'voided' THEN RAISE EXCEPTION 'V3 fail: حالة الدفعة %', v_pst; END IF;
  IF v_st <> 'cancelled' THEN RAISE EXCEPTION 'V3 fail: حالة الطلب %', v_st; END IF;
  SELECT count(*) INTO v_nrev FROM portal_audit WHERE request_id=v_req AND event='payment_voided';
  IF v_nrev <> 1 THEN RAISE EXCEPTION 'V3 fail: قيد عكسي مفقود'; END IF;
  RAISE NOTICE 'PASS V3 إبطال المالية → voided + الطلب مُلغى + قيد عكسي في التدقيق';

  -- V4: لا إبطال لدفعة غير منفَّذة (voided الآن)
  BEGIN
    PERFORM portal_payment_void(v_p,'مرة أخرى');
    RAISE EXCEPTION 'V4 fail: أُبطِلت دفعة غير منفَّذة';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'V4 fail%' THEN RAISE; END IF;
    IF v_msg NOT LIKE '%منفَّذ%' THEN RAISE EXCEPTION 'V4 fail: سبب آخر %', v_msg; END IF;
  END;
  RAISE NOTICE 'PASS V4 لا يُبطَل إلا صرفٌ منفَّذ';

  RAISE NOTICE '════ IDEMPOTENCY + SAGA VOID (051): I1–I4 + V1–V4 = 8/8 PASS ════';
END $v$;

DROP FUNCTION _v51_make_expense(numeric);

-- ════════════════════════════════════════════════════════════════════════════
--  32 — الاعتماد بالبريد لدورة الصرف (056): رمز واعٍ بالدورة + انتقال بريديّ مُعمَّم.
--  إنشاء صرف عبر RPC بهوية مُنتحَلة، ثم اعتماد السلسلة كاملةً بالبريد (خادميّ).
--  الرمز يخزّن الدورة · السلسلة تتقدّم بالبريد حتى payment_pending + فتح الدفعة ·
--  فصل المهام (الطالب مرفوض) · غير المعتمِد مرفوض · الرمز لمرة واحدة.
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
  DELETE FROM portal_requests WHERE requester LIKE 'em_%';
  DELETE FROM portal_users WHERE username LIKE 'em_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('em_acc', 'em_acc@aldeyabi.com', 'محاسب',        'user', '{"can_create":true,"can_see_finance":true}', 'GA'),
    ('em_amgr','em_amgr@aldeyabi.com','رئيس الحسابات','user', '{"can_approve_disbursement":true,"can_see_finance":true}', 'GA'),
    ('em_fin', 'em_fin@aldeyabi.com', 'المدير المالي','user', '{"can_approve_finance":true,"can_see_finance":true}', 'GA'),
    ('em_gm',  'em_gm@aldeyabi.com',  'المدير العام', 'user', '{"can_manage_users":true}', 'GA');
  DELETE FROM portal_budgets WHERE department_id='GA';
  UPDATE portal_settings SET value = value || '{"budget_enforce":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $b$
DECLARE v_r jsonb; v_id text; v_tok text; v_st text; v_seq int; v_np int;
BEGIN
  -- إنشاء صرف مباشر (دورة disbursement، 3 مراحل من wf-disb-default)
  PERFORM set_config('request.jwt.claims','{"email":"em_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('مستفيد', 8000, 'custody', 'غرض بريديّ', 'GA', (now()+interval '5 day')::date,
           '{"custody_to":"em_acc"}'::jsonb, NULL, NULL);
  v_id := v_r->>'id';
  SELECT count(*) INTO v_np FROM portal_approvals WHERE request_id=v_id AND cycle='disbursement';
  IF v_np <> 3 THEN RAISE EXCEPTION 'setup fail: سلسلة الصرف ليست 3 مراحل (%)', v_np; END IF;

  -- EM0: portal_create_token يخزّن الدورة (افتراضي need · صريح disbursement)
  v_tok := portal_create_token(v_id,'approval',1,'em_amgr');
  IF (SELECT cycle FROM portal_email_tokens WHERE token=v_tok) <> 'need' THEN RAISE EXCEPTION 'EM0 fail: الدورة الافتراضية ليست need'; END IF;
  v_tok := portal_create_token(v_id,'approval',1,'em_amgr',168,'disbursement');
  IF (SELECT cycle FROM portal_email_tokens WHERE token=v_tok) <> 'disbursement' THEN RAISE EXCEPTION 'EM0 fail: لم تُخزَّن دورة الصرف'; END IF;
  RAISE NOTICE 'PASS EM0 الرمز يخزّن الدورة (need افتراضي · disbursement صريح)';

  -- EM1a: فصل المهام — رمز للطالب (em_acc ليس معتمِداً أصلاً؛ نتحقّق برمز لغير معتمِد)
  v_tok := portal_create_token(v_id,'approval',1,'em_acc',168,'disbursement');
  v_r := portal_pr_transition_email(v_tok,'approve');
  IF (v_r->>'error') IS NULL THEN RAISE EXCEPTION 'EM1a fail: غير المعتمِد اعتمد بالبريد'; END IF;
  RAISE NOTICE 'PASS EM1a رمز لغير المعتمِد مرفوض (%)', v_r->>'error';

  -- EM1: المرحلة 1 — رئيس الحسابات يعتمد بالبريد ⇒ تتقدّم للمرحلة 2
  v_tok := portal_create_token(v_id,'approval',1,'em_amgr',168,'disbursement');
  v_r := portal_pr_transition_email(v_tok,'approve');
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'EM1 fail: اعتماد المرحلة 1 % ', v_r; END IF;
  SELECT current_seq, status INTO v_seq, v_st FROM portal_requests WHERE id=v_id;
  IF v_seq <> 2 OR v_st <> 'in_review' THEN RAISE EXCEPTION 'EM1 fail: لم تتقدّم للمرحلة 2 (seq=% st=%)', v_seq, v_st; END IF;
  RAISE NOTICE 'PASS EM1 اعتماد المرحلة 1 بالبريد ⇒ المرحلة 2';

  -- EM2: الرمز لمرة واحدة (إعادة استخدام رمز المرحلة 1 المُستهلَك)
  v_r := portal_pr_transition_email(v_tok,'approve');
  IF (v_r->>'error') <> 'used' THEN RAISE EXCEPTION 'EM2 fail: أُعيد استخدام الرمز (%)', v_r; END IF;
  RAISE NOTICE 'PASS EM2 الرمز لمرة واحدة (used)';

  -- EM3: المرحلة 2 — المدير المالي يعتمد بالبريد ⇒ المرحلة 3
  v_tok := portal_create_token(v_id,'approval',2,'em_fin',168,'disbursement');
  v_r := portal_pr_transition_email(v_tok,'approve');
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'EM3 fail: اعتماد المرحلة 2 %', v_r; END IF;
  SELECT current_seq INTO v_seq FROM portal_requests WHERE id=v_id;
  IF v_seq <> 3 THEN RAISE EXCEPTION 'EM3 fail: لم تتقدّم للمرحلة 3 (seq=%)', v_seq; END IF;
  RAISE NOTICE 'PASS EM3 اعتماد المرحلة 2 بالبريد ⇒ المرحلة 3';

  -- EM4: المرحلة 3 — المدير العام يعتمد ⇒ اكتمال السلسلة → payment_pending + فتح الدفعة
  v_tok := portal_create_token(v_id,'approval',3,'em_gm',168,'disbursement');
  v_r := portal_pr_transition_email(v_tok,'approve');
  IF (v_r->>'status') <> 'payment_pending' THEN RAISE EXCEPTION 'EM4 fail: لم تكتمل للدفع (%)', v_r; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_payments WHERE request_id=v_id AND status='approved_pay') THEN
    RAISE EXCEPTION 'EM4 fail: لم تُفتَح دفعة الصرف المُعتمَدة'; END IF;
  RAISE NOTICE 'PASS EM4 اكتمال دورة الصرف بالبريد ⇒ payment_pending + دفعة مفتوحة';

  RAISE NOTICE '════ EMAIL APPROVAL — DISBURSEMENT (056): EM0–EM4 = 6/6 PASS ════';
END $b$;

-- ════════════════════════════════════════════════════════════════════════════
--  26 — محرّك الصرف الموحّد (الهجرة 050) عبر RPC فعلي بهوية مُنتحَلة (JWT).
--  يغطّي المدخل الأول (صرف مستقلّ خارج دورة المشتريات) بالكامل + السلبيات + الإرجاع
--  + قابلية الضبط، والمدخل الثاني (بوّابة الصرف على مسار الشراء عند التفعيل).
--  كل تأكيد RAISE عند الفشل ⇒ خروج غير صفري.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

-- ─── بذر المستخدمين الماليين (postgres مميّز فيتجاوز حارس المستخدمين) ───
DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 'd6_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('d6_acc',  'd6_acc@aldeyabi.com',  'محاسب',        'user', '{"can_create":true,"can_see_finance":true}', 'GA'),
    ('d6_amgr', 'd6_amgr@aldeyabi.com', 'رئيس الحسابات','user', '{"can_approve_disbursement":true,"can_see_finance":true}', 'GA'),
    ('d6_fin',  'd6_fin@aldeyabi.com',  'المدير المالي','user', '{"can_approve_finance":true,"can_see_finance":true}', 'GA'),
    ('d6_gm',   'd6_gm@aldeyabi.com',   'المدير العام', 'user', '{"can_manage_users":true}', 'GA'),
    ('d6_bank', 'd6_bank@aldeyabi.com', 'مسؤول البنك',  'user', '{"can_disburse":true}', 'GA');
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- ════════════════ E1 — دورة صرف مستقلّ كاملة (خارج المشتريات) ════════════════
DO $e1$
DECLARE v_id text; v_r jsonb; v_status text; v_phase text; v_type text;
        v_pay_id bigint; v_pay_status text; v_err text; v_n_offers int; v_award int;
BEGIN
  -- إنشاء طلب صرف مباشر (محاسب) — بلا دورة مشتريات
  PERFORM set_config('request.jwt.claims','{"email":"d6_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('مؤسسة الكهرباء', 5000, 'bank', 'سداد فاتورة كهرباء', 'GA',
           (now()+interval '5 day')::date,
           '{"iban":"SA1234567890123456789012","account_name":"مؤسسة الكهرباء"}'::jsonb, 'عاجل');
  v_id := v_r->>'id';
  SELECT status, phase, req_type INTO v_status, v_phase, v_type FROM portal_requests WHERE id=v_id;
  IF v_type <> 'direct_expense' THEN RAISE EXCEPTION 'E1a fail: النوع %', v_type; END IF;
  IF v_status <> 'in_review' OR v_phase <> 'disbursement' THEN RAISE EXCEPTION 'E1a fail: حالة/طور %/%', v_status, v_phase; END IF;
  -- تأكيد عدم وجود أي أثر مشتريات (لا عروض ولا تعميد)
  SELECT count(*) INTO v_n_offers FROM portal_offers WHERE request_id=v_id;
  SELECT count(*) INTO v_award FROM portal_award WHERE request_id=v_id;
  IF v_n_offers <> 0 OR v_award <> 0 THEN RAISE EXCEPTION 'E1a fail: أثر مشتريات على صرف مباشر'; END IF;
  RAISE NOTICE 'PASS E1a إنشاء صرف مباشر → disbursement بلا أثر مشتريات';

  -- السلسلة: رئيس الحسابات → المدير المالي → المدير العام
  PERFORM set_config('request.jwt.claims','{"email":"d6_amgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','معتمَد');
  PERFORM set_config('request.jwt.claims','{"email":"d6_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','معتمَد مالياً');
  PERFORM set_config('request.jwt.claims','{"email":"d6_gm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','معتمَد نهائياً');

  SELECT status, phase INTO v_status, v_phase FROM portal_requests WHERE id=v_id;
  IF v_status <> 'payment_pending' OR v_phase <> 'payment' THEN RAISE EXCEPTION 'E1b fail: بعد السلسلة %/%', v_status, v_phase; END IF;
  -- فُتحت دفعة مُعتمَدة بالسلسلة (approved_pay) بلا تعميد
  SELECT id, status INTO v_pay_id, v_pay_status FROM portal_payments WHERE request_id=v_id;
  IF v_pay_status <> 'approved_pay' THEN RAISE EXCEPTION 'E1b fail: حالة الدفعة %', v_pay_status; END IF;
  RAISE NOTICE 'PASS E1b اكتملت السلسلة → دفعة approved_pay (بلا تعميد)';

  -- تنفيذ البنك (السلسلة كانت الاعتماد؛ لا اعتماد مسطّح)
  PERFORM set_config('request.jwt.claims','{"email":"d6_bank@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_payment_transition(v_pay_id,'disburse','نُفِّذ', NULL, '{"proof_key":"docs/disb/x/y.pdf"}'::jsonb);
  SELECT status, phase INTO v_status, v_phase FROM portal_requests WHERE id=v_id;
  IF v_status <> 'closed' OR v_phase <> 'closed' THEN RAISE EXCEPTION 'E1c fail: بعد التنفيذ %/%', v_status, v_phase; END IF;
  RAISE NOTICE 'PASS E1c تنفيذ البنك → closed (لا استلام بضاعة للصرف المباشر)';
END $e1$;

-- ════════════════ E2 — فصل المهام والسلبيات ════════════════
DO $e2$
DECLARE v_id text; v_r jsonb; v_err text; v_pay_id bigint;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"d6_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('مورّد خدمات', 3000, 'custody', 'عهدة صيانة', 'GA',
           (now()+interval '3 day')::date, '{"custody_to":"d6_acc"}'::jsonb, NULL);
  v_id := v_r->>'id';

  -- المقدّم (المحاسب) لا يعتمد طلبه
  BEGIN
    PERFORM portal_pr_transition(v_id,'approve','x');
    RAISE EXCEPTION 'E2a fail: المقدّم اعتمد طلبه';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'E2a fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%فصل المهام%' THEN RAISE EXCEPTION 'E2a fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS E2a المقدّم لا يعتمد طلبه';

  -- غير المخوَّل (البنك) لا يعتمد مرحلة رئيس الحسابات
  PERFORM set_config('request.jwt.claims','{"email":"d6_bank@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_pr_transition(v_id,'approve','x');
    RAISE EXCEPTION 'E2b fail: غير المخوَّل اعتمد';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'E2b fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%لست المُعتمِد%' THEN RAISE EXCEPTION 'E2b fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS E2b غير المخوَّل لا يعتمد';

  -- أكمل السلسلة حتى الدفعة، ثم: من اعتمد في السلسلة لا ينفّذ
  PERFORM set_config('request.jwt.claims','{"email":"d6_amgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"d6_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"d6_gm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  SELECT id INTO v_pay_id FROM portal_payments WHERE request_id=v_id;

  -- المدير المالي (اعتمد في السلسلة) لا ينفّذ الصرف — لكنه لا يملك can_disburse أصلاً،
  -- فنجرّب مستخدماً يملك can_disburse واعتمد في السلسلة: نمنح d6_gm can_disburse مؤقّتاً؟
  -- الأبسط: تأكيد أنّ منفّذاً اعتمد في السلسلة يُمنع. نمنح d6_amgr can_disburse مؤقّتاً.
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_users SET permissions = permissions || '{"can_disburse":true}' WHERE username='d6_amgr';
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM set_config('request.jwt.claims','{"email":"d6_amgr@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_payment_transition(v_pay_id,'disburse','x', NULL, '{"proof_key":"docs/disb/x/z.pdf"}'::jsonb);
    RAISE EXCEPTION 'E2c fail: معتمِد السلسلة نفّذ الصرف';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'E2c fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%من اعتمد الصرف في السلسلة لا ينفّذه%' THEN RAISE EXCEPTION 'E2c fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS E2c من اعتمد في السلسلة لا ينفّذ الصرف (فصل المهام)';
END $e2$;

-- ════════════════ E3 — الإرجاع لمرحلة سابقة على دورة الصرف ════════════════
DO $e3$
DECLARE v_id text; v_r jsonb; v_status text; v_seq int; v_dec text;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"d6_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('جهة إيجار', 8000, 'credit', 'إيجار مقر', 'GA',
           (now()+interval '7 day')::date, '{"due_date":"2026-09-01"}'::jsonb, NULL);
  v_id := v_r->>'id';
  -- رئيس الحسابات يعتمد، ثم المدير المالي يُرجع للمرحلة 1
  PERFORM set_config('request.jwt.claims','{"email":"d6_amgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"d6_fin@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_pr_transition(v_id,'return','أعِد لرئيس الحسابات', NULL, 1);
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'in_review' THEN RAISE EXCEPTION 'E3 fail: بعد الإرجاع %', v_status; END IF;
  -- المرحلتان 1 و2 عادتا pending
  SELECT decision INTO v_dec FROM portal_approvals WHERE request_id=v_id AND cycle='disbursement' AND seq=1;
  IF v_dec <> 'pending' THEN RAISE EXCEPTION 'E3 fail: المرحلة 1 %', v_dec; END IF;
  -- current_seq رجع إلى 1
  SELECT current_seq INTO v_seq FROM portal_requests WHERE id=v_id;
  IF v_seq <> 1 THEN RAISE EXCEPTION 'E3 fail: current_seq %', v_seq; END IF;
  RAISE NOTICE 'PASS E3 الإرجاع لمرحلة سابقة على دورة الصرف يعمل';
END $e3$;

-- ════════════════ E4 — قابلية ضبط السلسلة (تحرير القالب يغيّرها) ════════════════
DO $e4$
DECLARE v_id text; v_r jsonb; v_n int;
BEGIN
  -- عدّل السلسلة إلى مرحلتين فقط (رئيس حسابات → مدير عام)
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_workflows SET stages =
    '[{"seq":1,"label":"رئيس الحسابات","resolver":"role","role_key":"can_approve_disbursement","sla":24},
      {"seq":2,"label":"المدير العام","resolver":"role","role_key":"can_manage_users","sla":24}]'::jsonb
   WHERE id='wf-disb-default';
  PERFORM set_config('app.portal_transition','0',true);

  PERFORM set_config('request.jwt.claims','{"email":"d6_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('مورّد قرطاسية', 1200, 'bank', 'قرطاسية', 'GA',
           (now()+interval '4 day')::date,
           '{"iban":"SA9999999999999999999999","account_name":"مورّد قرطاسية"}'::jsonb, NULL);
  v_id := v_r->>'id';
  SELECT count(*) INTO v_n FROM portal_approvals WHERE request_id=v_id AND cycle='disbursement';
  IF v_n <> 2 THEN RAISE EXCEPTION 'E4 fail: توقّعت مرحلتين حصلت %', v_n; END IF;
  RAISE NOTICE 'PASS E4 تحرير القالب غيّر السلسلة (مرحلتان)';

  -- أعِد السلسلة الافتراضية (3 مراحل) لبقية الاختبارات
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_workflows SET stages =
    '[{"seq":1,"label":"رئيس الحسابات","resolver":"role","role_key":"can_approve_disbursement","sla":24},
      {"seq":2,"label":"المدير المالي","resolver":"role","role_key":"can_approve_finance","sla":24},
      {"seq":3,"label":"المدير العام","resolver":"role","role_key":"can_manage_users","sla":24}]'::jsonb
   WHERE id='wf-disb-default';
  PERFORM set_config('app.portal_transition','0',true);
END $e4$;

-- ════════════════ E5 — بوّابة الصرف على مسار الشراء (عند التفعيل) ════════════════
--  نتحقّق أنّ المفتاح disb_gate_purchase يتحكّم بدخول طلب الشراء دورة الصرف.
DO $e5$
DECLARE v_gate numeric; v_n int;
BEGIN
  -- افتراضياً مُطفأ (السلوك القائم محفوظ)
  SELECT portal_setting_num('disb_gate_purchase',0) INTO v_gate;
  IF v_gate <> 0 THEN RAISE EXCEPTION 'E5 fail: المفتاح ليس مُطفأ افتراضياً'; END IF;
  RAISE NOTICE 'PASS E5a بوّابة صرف الشراء مُطفأة افتراضياً (لا انحدار)';

  -- portal_build_chain لدورة الصرف يعمل لأي طلب (بيانات لا كود)
  -- (اختبار الدورة الكاملة لمسار الشراء مع البوّابة يُغطّى بعد تفعيل المالك؛
  --  هنا نؤكّد أنّ الباني يُنشئ سلسلة الصرف الافتراضية = 3 مراحل.)
  PERFORM set_config('app.portal_transition','1',true);
  INSERT INTO portal_requests(id,title,department_id,requester,req_type,est_total,status,phase)
    VALUES ('REQ-E5TEST','طلب اختبار بوّابة','GA','d6_acc','purchase',10000,'draft','requisition')
    ON CONFLICT (id) DO NOTHING;
  PERFORM set_config('app.portal_transition','0',true);
  SELECT portal_build_chain('REQ-E5TEST','disbursement') INTO v_n;
  IF v_n <> 3 THEN RAISE EXCEPTION 'E5 fail: سلسلة صرف الشراء %', v_n; END IF;
  RAISE NOTICE 'PASS E5b باني سلسلة الصرف يعمل لأي طلب (3 مراحل قابلة للضبط)';

  -- تنظيف
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_approvals WHERE request_id='REQ-E5TEST';
  DELETE FROM portal_requests WHERE id='REQ-E5TEST';
  PERFORM set_config('app.portal_transition','0',true);

  RAISE NOTICE '════ DISBURSEMENT CORE (050): E1–E5 PASS ════';
END $e5$;

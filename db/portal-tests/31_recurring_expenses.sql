-- ════════════════════════════════════════════════════════════════════════════
--  31 — الصرف المتكرّر/المجدوَل (055) عبر RPC فعلي بهوية مُنتحَلة + مولّد خادميّ.
--  حفظ/صلاحية · رفض طريقة غير مدعومة · توليد طلب مستحقّ (بهوية صاحب القالب، دورة
--  صرف مبنيّة) · عدم التكرار في نفس اليوم · القالب المعطَّل لا يُولِّد · حماية الفيضان
--  للمواعيد الفائتة (طلب واحد). كل تأكيد RAISE عند الفشل ⇒ خروج غير صفري.
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
  DELETE FROM portal_requests WHERE note LIKE 'مولَّد آلياً من قالب%';
  DELETE FROM portal_recurring_expenses WHERE title LIKE 'اختبار-متكرّر%';
  DELETE FROM portal_users WHERE username LIKE 'rec_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('rec_fin','rec_fin@aldeyabi.com','مالية','user', '{"can_see_finance":true}', 'GA'),
    ('rec_emp','rec_emp@aldeyabi.com','موظف','user', '{"can_create":true}', 'GA');
  DELETE FROM portal_budgets WHERE department_id='GA';
  UPDATE portal_settings SET value = value || '{"budget_enforce":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $b$
DECLARE v_r jsonb; v_tid bigint; v_err text; v_created int; v_n int; v_next date;
        v_req record; v_runs int;
BEGIN
  -- RC1: حفظ قالب شهري بنكيّ مستحقّ اليوم (بهوية المالية)
  PERFORM set_config('request.jwt.claims','{"email":"rec_fin@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_recurring_save(NULL,'اختبار-متكرّر إيجار','GA', 12000, 'bank',
           '{"beneficiary":"مؤجر المبنى","iban":"SA1200000000000000000012","account_name":"مؤجر"}'::jsonb,
           'monthly', current_date, NULL);
  v_tid := (v_r->>'id')::bigint;
  IF v_tid IS NULL THEN RAISE EXCEPTION 'RC1 fail: لم يُنشأ القالب'; END IF;
  RAISE NOTICE 'PASS RC1 حفظ قالب متكرّر (id=%)', v_tid;

  -- RC2: صلاحية — موظف بلا مالية/مشتريات/أدمن لا يحفظ
  PERFORM set_config('request.jwt.claims','{"email":"rec_emp@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_recurring_save(NULL,'اختبار-متكرّر ب','GA',100,'bank','{"beneficiary":"x","iban":"SA1200000000000000000012","account_name":"y"}'::jsonb,'monthly',current_date,NULL);
    RAISE EXCEPTION 'RC2 fail: موظف غير مخوَّل حفظ قالباً';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'RC2 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%غير مصرّح%' THEN RAISE EXCEPTION 'RC2 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS RC2 حفظ القالب صلاحية مالية/مشتريات/أدمن فقط';

  -- RC3: طريقة غير مدعومة للتكرار (credit) مرفوضة
  PERFORM set_config('request.jwt.claims','{"email":"rec_fin@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_recurring_save(NULL,'اختبار-متكرّر ج','GA',100,'credit','{"beneficiary":"x"}'::jsonb,'monthly',current_date,NULL);
    RAISE EXCEPTION 'RC3 fail: قُبِلت طريقة credit';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'RC3 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%غير مدعومة%' THEN RAISE EXCEPTION 'RC3 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS RC3 طريقة غير مدعومة للتكرار مرفوضة';

  -- RC4: المولّد (خادميّ) يُنشئ طلباً مستحقّاً بهوية صاحب القالب + دورة صرف
  v_r := portal_recurring_run();
  v_created := (v_r->>'created')::int;
  IF v_created < 1 THEN RAISE EXCEPTION 'RC4 fail: لم يُولَّد طلب (created=%)', v_created; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE note = 'مولَّد آلياً من قالب #' || v_tid ORDER BY created_at DESC LIMIT 1;
  IF v_req.req_type <> 'direct_expense' THEN RAISE EXCEPTION 'RC4 fail: نوع الطلب %', v_req.req_type; END IF;
  IF v_req.requester <> 'rec_fin' THEN RAISE EXCEPTION 'RC4 fail: الطلب لم يُنسَب لصاحب القالب (%)', v_req.requester; END IF;
  IF v_req.status <> 'in_review' THEN RAISE EXCEPTION 'RC4 fail: حالة الطلب %', v_req.status; END IF;
  IF (v_req.expense_details->>'iban') <> 'SA1200000000000000000012' THEN RAISE EXCEPTION 'RC4 fail: الآيبان مفقود'; END IF;
  SELECT count(*) INTO v_n FROM portal_approvals WHERE request_id = v_req.id AND cycle='disbursement';
  IF v_n < 1 THEN RAISE EXCEPTION 'RC4 fail: لم تُبنَ دورة الصرف'; END IF;
  SELECT next_run, runs_count INTO v_next, v_runs FROM portal_recurring_expenses WHERE id = v_tid;
  IF v_next <= current_date THEN RAISE EXCEPTION 'RC4 fail: next_run لم يتقدّم (%)', v_next; END IF;
  IF v_runs <> 1 THEN RAISE EXCEPTION 'RC4 fail: runs_count=%', v_runs; END IF;
  RAISE NOTICE 'PASS RC4 توليد طلب صرف بهوية صاحب القالب + دورة صرف + تقدّم الموعد';

  -- RC5: تشغيل ثانٍ نفس اليوم ⇒ لا توليد للقالب (غير مستحقّ)
  v_r := portal_recurring_run();
  SELECT count(*) INTO v_n FROM portal_requests WHERE note = 'مولَّد آلياً من قالب #' || v_tid;
  IF v_n <> 1 THEN RAISE EXCEPTION 'RC5 fail: تكرار التوليد في نفس اليوم (% طلبات)', v_n; END IF;
  RAISE NOTICE 'PASS RC5 لا تكرار توليد في نفس اليوم';

  -- RC6: القالب المعطَّل لا يُولِّد
  PERFORM set_config('request.jwt.claims','{"email":"rec_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_recurring_set_active(v_tid, false);
  -- نُعيد استحقاقه لكنه معطَّل
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_recurring_expenses SET next_run = current_date WHERE id = v_tid;
  PERFORM set_config('app.portal_transition','0',true);
  v_r := portal_recurring_run();
  SELECT count(*) INTO v_n FROM portal_requests WHERE note = 'مولَّد آلياً من قالب #' || v_tid;
  IF v_n <> 1 THEN RAISE EXCEPTION 'RC6 fail: قالب معطَّل وَلَّد طلباً'; END IF;
  RAISE NOTICE 'PASS RC6 القالب المعطَّل لا يُولِّد';

  -- RC7: حماية الفيضان — قالب متأخّر شهرين ⇒ طلب واحد فقط + next_run مستقبلي
  PERFORM set_config('request.jwt.claims','{"email":"rec_fin@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_recurring_save(NULL,'اختبار-متكرّر متأخّر','GA', 5000, 'custody',
           '{"beneficiary":"عهدة","custody_to":"rec_emp"}'::jsonb, 'monthly', (current_date - interval '2 month')::date, NULL);
  v_tid := (v_r->>'id')::bigint;
  v_r := portal_recurring_run();
  SELECT count(*) INTO v_n FROM portal_requests WHERE note = 'مولَّد آلياً من قالب #' || v_tid;
  IF v_n <> 1 THEN RAISE EXCEPTION 'RC7 fail: قالب متأخّر وَلَّد % طلبات (المتوقّع 1)', v_n; END IF;
  SELECT next_run INTO v_next FROM portal_recurring_expenses WHERE id = v_tid;
  IF v_next <= current_date THEN RAISE EXCEPTION 'RC7 fail: next_run ما زال في الماضي (%)', v_next; END IF;
  RAISE NOTICE 'PASS RC7 حماية الفيضان: طلب واحد للمواعيد الفائتة + الموعد التالي مستقبلي';

  RAISE NOTICE '════ RECURRING EXPENSES (055): RC1–RC7 = 7/7 PASS ════';
END $b$;

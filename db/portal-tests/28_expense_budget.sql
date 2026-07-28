-- ════════════════════════════════════════════════════════════════════════════
--  28 — ضبط ميزانية الصرف المستقلّ (052) عبر RPC فعلي بهوية مُنتحَلة.
--  المرتبط يشمل الصرف المباشر · المنع عند التجاوز (enforce=1) · التحذير (enforce=0) ·
--  بلا ميزانية = لا إنفاذ. كل تأكيد RAISE عند الفشل ⇒ خروج غير صفري.
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
  DELETE FROM portal_users WHERE username LIKE 'b8_%';
  DELETE FROM portal_budgets WHERE department_id IN ('GA','OPS') AND fiscal_year = EXTRACT(YEAR FROM now())::int;
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('b8_acc','b8_acc@aldeyabi.com','محاسب','user','{"can_create":true,"can_see_finance":true}','GA'),
    ('b8_fin','b8_fin@aldeyabi.com','مالية','user','{"can_see_finance":true}','GA'),
    -- b8_ops في OPS: لاختبار «بلا ميزانية» ضمن قسمه (بعد AUTHZ-01: الصرف مقيَّد بقسم المُنشئ)
    ('b8_ops','b8_ops@aldeyabi.com','محاسب OPS','user','{"can_create":true}','OPS');
  -- صفّ الإعدادات موجود؛ نضبط vat=15 (افتراضي) ونُطفئ الإنفاذ ابتداءً
  UPDATE portal_settings SET value = value || '{"budget_enforce":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $b$
DECLARE v_r jsonb; v_committed numeric; v_err text; v_year int := EXTRACT(YEAR FROM now())::int;
BEGIN
  -- ميزانية GA = 12000 (يكفي ~10434 شاملاً الضريبة لمبلغ 9000، ويمنع الثاني)
  PERFORM set_config('request.jwt.claims','{"email":"b8_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_budget_set('GA', v_year, 12000, 'اختبار');

  -- صرف مباشر 9000 → المرتبط يشمله (9000*1.15=10350)
  PERFORM set_config('request.jwt.claims','{"email":"b8_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('جهة أ', 9000, 'custody', 'غرض أ', 'GA', (now()+interval '5 day')::date, '{"custody_to":"b8_acc"}'::jsonb, NULL);
  SELECT portal_budget_committed('GA', v_year) INTO v_committed;
  IF v_committed < 10000 THEN RAISE EXCEPTION 'B1 fail: المرتبط لا يشمل الصرف المباشر (%)', v_committed; END IF;
  RAISE NOTICE 'PASS B1 المرتبط يشمل الصرف المباشر (%)', round(v_committed);

  -- الوضع التحذيري (enforce=0): صرف ثانٍ يتجاوز الميزانية لكن يُقبَل
  v_r := portal_create_expense('جهة ب', 8000, 'custody', 'غرض ب', 'GA', (now()+interval '5 day')::date, '{"custody_to":"b8_acc"}'::jsonb, NULL);
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'B2 fail: مُنِع في الوضع التحذيري'; END IF;
  RAISE NOTICE 'PASS B2 تحذيري (enforce=0): التجاوز يُقبَل';

  -- فعّل الإنفاذ: صرف ثالث يتجاوز ⇒ مُنِع
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_settings SET value = value || '{"budget_enforce":1}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM set_config('request.jwt.claims','{"email":"b8_acc@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    v_r := portal_create_expense('جهة ج', 5000, 'custody', 'غرض ج', 'GA', (now()+interval '5 day')::date, '{"custody_to":"b8_acc"}'::jsonb, NULL);
    RAISE EXCEPTION 'B3 fail: قُبِل صرف يتجاوز الميزانية مع الإنفاذ';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'B3 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%تجاوز ميزانية%' THEN RAISE EXCEPTION 'B3 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS B3 إنفاذ (enforce=1): التجاوز مُنِع';

  -- بلا ميزانية معرّفة: لا إنفاذ (قسم OPS بلا ميزانية، بهوية موظّف OPS — يحترم AUTHZ-01)
  PERFORM set_config('request.jwt.claims','{"email":"b8_ops@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('جهة د', 999999, 'custody', 'غرض د', 'OPS', (now()+interval '5 day')::date, '{"custody_to":"b8_ops"}'::jsonb, NULL);
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'B4 fail: مُنِع قسم بلا ميزانية'; END IF;
  RAISE NOTICE 'PASS B4 بلا ميزانية معرّفة ⇒ لا إنفاذ';

  RAISE NOTICE '════ EXPENSE BUDGET CONTROL (052): B1–B4 = 4/4 PASS ════';
END $b$;

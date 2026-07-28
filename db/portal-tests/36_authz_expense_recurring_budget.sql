-- ════════════════════════════════════════════════════════════════════════════
--  36 — إصلاحات مراجعة Codex (060): AUTHZ-01 ربط قسم الصرف بالمُنشئ + GOV-01
--  ميزانية الصرف المتكرّر. عبر RPC فعلي بهوية مُنتحَلة. RAISE عند الفشل ⇒ خروج ≠ 0.
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
  DELETE FROM portal_recurring_expenses WHERE title LIKE 'az_%';
  DELETE FROM portal_users WHERE username LIKE 'az_%';
  DELETE FROM portal_budgets WHERE department_id IN ('GA','OPS') AND fiscal_year = EXTRACT(YEAR FROM now())::int;
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('az_ga','az_ga@aldeyabi.com','موظّف GA','user','{"can_create":true}','GA'),
    ('az_adm','az_adm@aldeyabi.com','أدمن','admin','{}','GA');
  UPDATE portal_settings SET value = value || '{"budget_enforce":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- ── AUTHZ-01 ────────────────────────────────────────────────────────────────
DO $az$
DECLARE v_r jsonb; v_err text;
BEGIN
  -- AZ1: موظّف GA يحاول صرفاً على قسم آخر (OPS) ⇒ يُرفض
  PERFORM set_config('request.jwt.claims','{"email":"az_ga@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    v_r := portal_create_expense('جهة', 5000, 'custody', 'غرض', 'OPS', (now()+interval '5 day')::date, '{"custody_to":"az_ga"}'::jsonb, NULL);
    RAISE EXCEPTION 'AZ1 fail: قُبِل صرف عبر قسم آخر (تجاوز AUTHZ-01)';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'AZ1 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%القسم يُحدَّد تلقائياً%' THEN RAISE EXCEPTION 'AZ1 fail: سبب آخر: %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS AZ1 غير الأدمن مُنِع من الصرف على قسم غير قسمه';

  -- AZ2: نفس الموظّف على قسمه (GA) ⇒ يُقبَل
  v_r := portal_create_expense('جهة', 5000, 'custody', 'غرض', 'GA', (now()+interval '5 day')::date, '{"custody_to":"az_ga"}'::jsonb, NULL);
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'AZ2 fail: مُنِع الصرف على قسمه'; END IF;
  RAISE NOTICE 'PASS AZ2 الصرف على قسم المُنشئ يُقبَل';

  -- AZ3: الأدمن (superuser، قرار المالك) يصرف على أي قسم ⇒ يُقبَل
  PERFORM set_config('request.jwt.claims','{"email":"az_adm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('جهة', 5000, 'custody', 'غرض', 'OPS', (now()+interval '5 day')::date, '{"custody_to":"az_ga"}'::jsonb, NULL);
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'AZ3 fail: مُنِع الأدمن من قسم آخر'; END IF;
  RAISE NOTICE 'PASS AZ3 الأدمن يصرف على أي قسم (superuser)';

  RAISE NOTICE '════ AUTHZ-01 (060): AZ1–AZ3 = 3/3 PASS ════';
END $az$;

-- ── GOV-01: ميزانية الصرف المتكرّر ──────────────────────────────────────────
DO $gov$
DECLARE v_before int; v_after int; v_year int := EXTRACT(YEAR FROM now())::int;
BEGIN
  -- قالب متكرّر يومي الاستحقاق لقسم GA بمبلغ كبير، وميزانية GA صغيرة
  PERFORM set_config('app.portal_transition','1',true);
  INSERT INTO portal_recurring_expenses(title, department_id, beneficiary, amount, kind, details, frequency, next_run, owner, active, created_by)
    VALUES ('az_rent', 'GA', 'مؤجّر', 100000, 'custody', '{"custody_to":"az_ga"}'::jsonb, 'monthly', current_date, 'az_ga', true, 'az_ga');
  PERFORM set_config('app.portal_transition','0',true);

  PERFORM set_config('request.jwt.claims','{"email":"az_adm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_budget_set('GA', v_year, 10000, 'اختبار GOV-01');   -- سقف صغير

  -- الإنفاذ مُفعَّل ⇒ التوليد يجب أن يتخطّى القالب (لا طلب فوق السقف)
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_settings SET value = value || '{"budget_enforce":1}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);

  SELECT count(*) INTO v_before FROM portal_requests WHERE note LIKE '%قالب #%' AND department_id='GA';
  PERFORM portal_recurring_run();
  SELECT count(*) INTO v_after FROM portal_requests WHERE note LIKE '%قالب #%' AND department_id='GA';
  IF v_after <> v_before THEN RAISE EXCEPTION 'GOV1 fail: أُنشئ صرف متكرّر فوق الميزانية مع الإنفاذ (before=% after=%)', v_before, v_after; END IF;
  RAISE NOTICE 'PASS GOV1 الصرف المتكرّر فوق الميزانية مُتخطّى عند الإنفاذ';

  -- أطفئ الإنفاذ ⇒ التوليد يُنشئ (تحذيري)
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_settings SET value = value || '{"budget_enforce":0}'::jsonb WHERE key='portal_settings';
  UPDATE portal_recurring_expenses SET next_run = current_date WHERE title='az_rent';
  PERFORM set_config('app.portal_transition','0',true);
  SELECT count(*) INTO v_before FROM portal_requests WHERE note LIKE '%قالب #%' AND department_id='GA';
  PERFORM portal_recurring_run();
  SELECT count(*) INTO v_after FROM portal_requests WHERE note LIKE '%قالب #%' AND department_id='GA';
  IF v_after <= v_before THEN RAISE EXCEPTION 'GOV2 fail: لم يُنشأ صرف متكرّر في الوضع التحذيري'; END IF;
  RAISE NOTICE 'PASS GOV2 الوضع التحذيري (enforce=0) يُنشئ الصرف المتكرّر';

  RAISE NOTICE '════ RECURRING BUDGET (060 GOV-01): GOV1–GOV2 = 2/2 PASS ════';
END $gov$;

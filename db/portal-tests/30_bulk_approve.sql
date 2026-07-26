-- ════════════════════════════════════════════════════════════════════════════
--  30 — الاعتماد الجماعي (054) عبر RPC فعلي بهوية مُنتحَلة.
--  اعتماد دفعة على دورة الصرف · فصل المهام محفوظ لكل عنصر (الطالب لا يعتمد) ·
--  سبب مطلوب للرفض الجماعي · مصفوفة فارغة مرفوضة. كل تأكيد RAISE عند الفشل ⇒ خروج غير صفري.
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
  DELETE FROM portal_requests WHERE requester LIKE 'bk_%';
  DELETE FROM portal_users WHERE username LIKE 'bk_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('bk_acc', 'bk_acc@aldeyabi.com', 'محاسب',        'user', '{"can_create":true,"can_see_finance":true}', 'GA'),
    ('bk_amgr','bk_amgr@aldeyabi.com','رئيس الحسابات','user', '{"can_approve_disbursement":true,"can_create":true,"can_see_finance":true}', 'GA');
  -- تحييد أي أثر ميزانية سابق على GA
  DELETE FROM portal_budgets WHERE department_id='GA';
  UPDATE portal_settings SET value = value || '{"budget_enforce":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- مساعد: ينشئ صرفاً مباشراً (عهدة) ويعيد id — بهوية المُنشئ الحالية.
CREATE OR REPLACE FUNCTION _v54_mk(p_who text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('email', p_who||'@aldeyabi.com','role','authenticated')::text, true);
  v_r := portal_create_expense('مستفيد', 4000, 'custody', 'غرض جماعي', 'GA', (now()+interval '5 day')::date,
           '{"custody_to":"bk_acc"}'::jsonb, NULL);
  RETURN v_r->>'id';
END $$;

DO $b$
DECLARE a text; b text; c text; d text; v_r jsonb; v_err text; v_seq int; v_ok int; v_fail int;
BEGIN
  -- ثلاثة طلبات من المحاسب (المرحلة 1 role_key=can_approve_disbursement)
  a := _v54_mk('bk_acc'); b := _v54_mk('bk_acc'); c := _v54_mk('bk_acc');

  -- BK1: رئيس الحسابات يعتمد الثلاثة دفعةً على دورة الصرف
  PERFORM set_config('request.jwt.claims','{"email":"bk_amgr@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_bulk_transition(ARRAY[a,b,c], 'approve', NULL, 'disbursement');
  v_ok := (v_r->>'approved')::int; v_fail := (v_r->>'failed')::int;
  IF v_ok <> 3 OR v_fail <> 0 THEN RAISE EXCEPTION 'BK1 fail: approved=% failed=% (المتوقّع 3/0) %', v_ok, v_fail, v_r; END IF;
  SELECT current_seq INTO v_seq FROM portal_requests WHERE id = a;
  IF v_seq <= 1 THEN RAISE EXCEPTION 'BK1 fail: الطلب لم يتقدّم لمرحلة تالية (seq=%)', v_seq; END IF;
  RAISE NOTICE 'PASS BK1 اعتماد جماعي لثلاثة طلبات على دورة الصرف (تقدّمت كلها)';

  -- BK2: فصل المهام لكل عنصر — طلب أنشأه المعتمِد نفسه (الطالب=المعتمِد) يفشل، وآخر ينجح
  d := _v54_mk('bk_amgr');  -- requester = bk_amgr
  a := _v54_mk('bk_acc');   -- requester = bk_acc (سينجح)
  PERFORM set_config('request.jwt.claims','{"email":"bk_amgr@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_bulk_transition(ARRAY[d,a], 'approve', NULL, 'disbursement');
  v_ok := (v_r->>'approved')::int; v_fail := (v_r->>'failed')::int;
  IF v_ok <> 1 OR v_fail <> 1 THEN RAISE EXCEPTION 'BK2 fail: approved=% failed=% (المتوقّع 1/1) %', v_ok, v_fail, v_r; END IF;
  -- تأكيد أنّ طلب المعتمِد نفسه لم يُعتمَد (ما زال بالمرحلة 1)
  SELECT current_seq INTO v_seq FROM portal_requests WHERE id = d;
  IF v_seq <> 1 THEN RAISE EXCEPTION 'BK2 fail: طلب المعتمِد تقدّم رغم فصل المهام (seq=%)', v_seq; END IF;
  RAISE NOTICE 'PASS BK2 فصل المهام محفوظ لكل عنصر (الطالب=المعتمِد فشل، الآخر نجح)';

  -- BK3: رفض جماعي بلا سبب ⇒ خطأ
  BEGIN
    PERFORM portal_bulk_transition(ARRAY[a], 'reject', NULL, 'disbursement');
    RAISE EXCEPTION 'BK3 fail: قُبِل رفض جماعي بلا سبب';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'BK3 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%سبب مطلوب%' THEN RAISE EXCEPTION 'BK3 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS BK3 سبب مطلوب للرفض الجماعي';

  -- BK4: مصفوفة فارغة ⇒ خطأ
  BEGIN
    PERFORM portal_bulk_transition(ARRAY[]::text[], 'approve', NULL, 'disbursement');
    RAISE EXCEPTION 'BK4 fail: قُبِلت مصفوفة فارغة';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'BK4 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%لا طلبات%' THEN RAISE EXCEPTION 'BK4 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS BK4 مصفوفة فارغة مرفوضة';

  RAISE NOTICE '════ BULK APPROVE (054): BK1–BK4 = 4/4 PASS ════';
END $b$;

DROP FUNCTION _v54_mk(text);

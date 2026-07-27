-- ════════════════════════════════════════════════════════════════════════════
--  34 — إشعارات معامَلاتية للاعتماد (058): مُشغِّل يلتقط معتمِد المرحلة داخل المعاملة
--  فيُسلّمه الصادر (029). خامل عند المفتاح=0 · يُدرِج عند =1 · يستثني المُقدّم ·
--  الصادر يلتقط. كل تأكيد RAISE عند الفشل ⇒ خروج غير صفري.
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
  DELETE FROM portal_requests WHERE requester LIKE 'tn_%';
  DELETE FROM portal_users WHERE username LIKE 'tn_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('tn_acc', 'tn_acc@aldeyabi.com', 'محاسب',        'user', '{"can_create":true,"can_see_finance":true}', 'GA'),
    ('tn_amgr','tn_amgr@aldeyabi.com','رئيس الحسابات','user', '{"can_approve_disbursement":true,"can_see_finance":true}', 'GA');
  DELETE FROM portal_budgets WHERE department_id='GA';
  UPDATE portal_settings SET value = value || '{"budget_enforce":0,"txn_notifications":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $b$
DECLARE v_r jsonb; v_id text; v_n_off int; v_n int; v_ob int; v_reqn int;
BEGIN
  -- TN1: المفتاح مُطفأ (افتراضي) ⇒ لا إشعار عند الإنشاء
  PERFORM set_config('request.jwt.claims','{"email":"tn_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('مستفيد', 3000, 'custody', 'غرض مطفأ', 'GA', (now()+interval '5 day')::date, '{"custody_to":"tn_acc"}'::jsonb, NULL, NULL);
  v_id := v_r->>'id';
  SELECT count(*) INTO v_n_off FROM portal_notifications WHERE recipient='tn_amgr' AND body='غرض مطفأ';
  IF v_n_off <> 0 THEN RAISE EXCEPTION 'TN1 fail: أُدرِج إشعار والمفتاح مطفأ (%)', v_n_off; END IF;
  RAISE NOTICE 'PASS TN1 المفتاح مطفأ ⇒ لا إشعار معامَلاتي (لا سلوك جديد)';

  -- فعّل المفتاح
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_settings SET value = value || '{"txn_notifications":1}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
  SELECT count(*) INTO v_ob FROM portal_outbox;   -- خطّ الأساس

  -- TN2: المفتاح مُفعَّل ⇒ إنشاء صرف يُدرِج إشعاراً لمعتمِد المرحلة (can_approve_disbursement)
  PERFORM set_config('request.jwt.claims','{"email":"tn_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('مستفيد', 4000, 'custody', 'غرض مُفعَّل', 'GA', (now()+interval '5 day')::date, '{"custody_to":"tn_acc"}'::jsonb, NULL, NULL);
  v_id := v_r->>'id';
  SELECT count(*) INTO v_n FROM portal_notifications WHERE recipient='tn_amgr' AND body='غرض مُفعَّل' AND type='approval';
  IF v_n < 1 THEN RAISE EXCEPTION 'TN2 fail: لم يُدرَج إشعار لمعتمِد المرحلة (%)', v_n; END IF;
  RAISE NOTICE 'PASS TN2 المفتاح مُفعَّل ⇒ إشعار معامَلاتي لمعتمِد المرحلة';

  -- TN3: المُقدّم مُستثنى (فصل مهام) — لا إشعار للمُقدّم نفسه
  SELECT count(*) INTO v_reqn FROM portal_notifications WHERE recipient='tn_acc' AND body='غرض مُفعَّل';
  IF v_reqn <> 0 THEN RAISE EXCEPTION 'TN3 fail: أُشعِر المُقدّم بطلبه (%)', v_reqn; END IF;
  RAISE NOTICE 'PASS TN3 المُقدّم مُستثنى من إشعار مرحلته (فصل مهام)';

  -- TN4: الصادر (029) التقط الإشعار داخل نفس المعاملة (تسليم دائم)
  IF (SELECT count(*) FROM portal_outbox) <= v_ob THEN RAISE EXCEPTION 'TN4 fail: الصادر لم يلتقط الإشعار'; END IF;
  RAISE NOTICE 'PASS TN4 الصادر المعامَلاتي التقط الإشعار (تسليم دائم exactly-once)';

  RAISE NOTICE '════ TXN NOTIFICATIONS (058): TN1–TN4 = 4/4 PASS ════';
END $b$;

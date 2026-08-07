-- ════════════════════════════════════════════════════════════════════════════
--  51 — ضبط مفاتيح الحوكمة من الإعدادات (P0-1t، تكليف المالك C5 + مبدأ هـ.2)
--  الأدمن يفعّل/يقفل كل ضابط إنفاذ من الإعدادات (يُحفَظ في portal_settings)؛
--  غير الأدمن مرفوض · مفتاح غير معروف مرفوض · قيمة ثنائية/نطاق مفروضة.
--  الهويّة عبر request.jwt.claims (auth.jwt()). يُشغَّل بعد p0_1b (رفع تجاوز session_user).
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
  DELETE FROM portal_users WHERE username LIKE 't51_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('t51_admin','t51_admin@aldeyabi.com','أدمن','admin','{}','GA'),
    ('t51_mgr','t51_mgr@aldeyabi.com','مدير مستخدمين (غير أدمن)','user','{"can_manage_users":true}','GA');
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $t$
DECLARE v_val numeric;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"t51_admin@aldeyabi.com","role":"authenticated"}',true);

  -- GF1 الأدمن يفعّل ضابطاً (يُحفَظ في portal_settings)
  PERFORM portal_set_governance_flag('budget_enforce', 1);
  SELECT (value->>'budget_enforce')::numeric INTO v_val FROM portal_settings WHERE key='portal_settings';
  IF v_val IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'GF1 FAIL: budget_enforce not persisted (=%)', v_val; END IF;
  RAISE NOTICE 'PASS GF1 admin enables an enforcement flag (persisted)';

  -- GF2 نسبة التسامح (مفتاح غير ثنائي يقبل 0..100)
  PERFORM portal_set_governance_flag('three_way_tolerance_pct', 5);
  SELECT (value->>'three_way_tolerance_pct')::numeric INTO v_val FROM portal_settings WHERE key='portal_settings';
  IF v_val IS DISTINCT FROM 5 THEN RAISE EXCEPTION 'GF2 FAIL: tolerance not persisted (=%)', v_val; END IF;
  RAISE NOTICE 'PASS GF2 numeric tolerance flag persisted';

  -- GF3 الإطفاء يُحفَظ أيضاً (تبديل قابل للعكس)
  PERFORM portal_set_governance_flag('budget_enforce', 0);
  SELECT (value->>'budget_enforce')::numeric INTO v_val FROM portal_settings WHERE key='portal_settings';
  IF v_val IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'GF3 FAIL: disable not persisted (=%)', v_val; END IF;
  RAISE NOTICE 'PASS GF3 flag can be toggled off (reversible)';

  -- GF4 قيمة ثنائية مفروضة على المفاتيح الثنائية
  BEGIN
    PERFORM portal_set_governance_flag('budget_enforce', 5);
    RAISE EXCEPTION 'GF4 FAIL: non-binary value accepted for a boolean flag';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'GF4 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS GF4 boolean flag rejects non-0/1 value';
  END;

  -- GF5 النطاق مفروض (0..100)
  BEGIN
    PERFORM portal_set_governance_flag('three_way_tolerance_pct', 200);
    RAISE EXCEPTION 'GF5 FAIL: out-of-range value accepted';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'GF5 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS GF5 out-of-range value rejected';
  END;

  -- GF6 مفتاح غير معروف مرفوض (لا حقن إعداد عشوائي)
  BEGIN
    PERFORM portal_set_governance_flag('is_super_admin', 1);
    RAISE EXCEPTION 'GF6 FAIL: unknown setting key accepted';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'GF6 FAIL%' THEN RAISE; END IF;
    IF sqlerrm NOT LIKE '%غير معروف%' THEN RAISE EXCEPTION 'GF6 FAIL: wrong reason: %', sqlerrm; END IF;
    RAISE NOTICE 'PASS GF6 unknown setting key rejected';
  END;

  -- GF7 غير الأدمن (حامل can_manage_users) مرفوض
  PERFORM set_config('request.jwt.claims','{"email":"t51_mgr@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_set_governance_flag('budget_enforce', 1);
    RAISE EXCEPTION 'GF7 FAIL: non-admin set a governance flag';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'GF7 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS GF7 non-admin blocked from governance flags (%.50)', left(sqlerrm,50);
  END;
END $t$;

DO $c$ BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 't51_%';
  -- إعادة الإعدادات لحالتها الأصلية (لا تلوّث بقيّة الاختبارات)
  UPDATE portal_settings SET value = (value - 'budget_enforce' - 'three_way_tolerance_pct') WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $c$;

SELECT '════ GOVERNANCE FLAGS (P0-1t): GF1..GF7 = 7/7 PASS ════' AS result;

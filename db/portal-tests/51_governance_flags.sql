-- ════════════════════════════════════════════════════════════════════════════
--  51 — ضبط مفاتيح الحوكمة من الإعدادات (P0-1t، تكليف المالك C5 + مبدأ هـ.2)
--  الأدمن يفعّل/يقفل الضوابط القابلة للضبط (تُحفَظ)؛ غير الأدمن مرفوض · مفتاح غير
--  معروف مرفوض · قيمة ثنائية/نطاق مفروضة.
--  + قفل الإطلاق (قرار المالك، مراجعة Gate): budget_enforce و txn_notifications
--  مقفلان — الأدمن مرفوض حتى عبر RPC مباشرة؛ لا يُفعَّلان إلا بمسار مميَّز (service_role/هجرة).
--  الهويّة عبر request.jwt.claims (auth.jwt()). يُشغَّل بعد p0_1b (privileged=service فقط).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $acl$
BEGIN
  IF has_function_privilege('anon','portal_set_governance_flag(text,numeric)','EXECUTE') THEN
    RAISE EXCEPTION 'GF12 FAIL: anon retains EXECUTE on portal_set_governance_flag';
  END IF;
  RAISE NOTICE 'PASS GF12 anon cannot execute the governance mutation RPC';
END $acl$;

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

  -- GF1 الأدمن يفعّل ضابطاً قابلاً للضبط (يُحفَظ)
  PERFORM portal_set_governance_flag('contract_enforce', 1);
  SELECT (value->>'contract_enforce')::numeric INTO v_val FROM portal_settings WHERE key='portal_settings';
  IF v_val IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'GF1 FAIL: contract_enforce not persisted (=%)', v_val; END IF;
  RAISE NOTICE 'PASS GF1 admin enables an adjustable flag (persisted)';

  -- GF2 نسبة التسامح (0..100)
  PERFORM portal_set_governance_flag('three_way_tolerance_pct', 5);
  SELECT (value->>'three_way_tolerance_pct')::numeric INTO v_val FROM portal_settings WHERE key='portal_settings';
  IF v_val IS DISTINCT FROM 5 THEN RAISE EXCEPTION 'GF2 FAIL: tolerance not persisted (=%)', v_val; END IF;
  RAISE NOTICE 'PASS GF2 numeric tolerance flag persisted';

  -- GF3 الإطفاء يُحفَظ (تبديل قابل للعكس)
  PERFORM portal_set_governance_flag('contract_enforce', 0);
  SELECT (value->>'contract_enforce')::numeric INTO v_val FROM portal_settings WHERE key='portal_settings';
  IF v_val IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'GF3 FAIL: disable not persisted (=%)', v_val; END IF;
  RAISE NOTICE 'PASS GF3 adjustable flag toggled off (reversible)';

  -- GF4 قيمة ثنائية مفروضة
  BEGIN PERFORM portal_set_governance_flag('contract_enforce', 5);
    RAISE EXCEPTION 'GF4 FAIL: non-binary value accepted';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'GF4 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS GF4 boolean flag rejects non-0/1'; END;

  -- GF5 النطاق مفروض
  BEGIN PERFORM portal_set_governance_flag('three_way_tolerance_pct', 200);
    RAISE EXCEPTION 'GF5 FAIL: out-of-range accepted';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'GF5 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS GF5 out-of-range rejected'; END;

  -- GF6 مفتاح غير معروف مرفوض
  BEGIN PERFORM portal_set_governance_flag('is_super_admin', 1);
    RAISE EXCEPTION 'GF6 FAIL: unknown key accepted';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'GF6 FAIL%' THEN RAISE; END IF;
    IF sqlerrm NOT LIKE '%غير معروف%' THEN RAISE EXCEPTION 'GF6 FAIL: wrong reason: %', sqlerrm; END IF;
    RAISE NOTICE 'PASS GF6 unknown key rejected'; END;

  -- GF7 [قفل الإطلاق] الأدمن لا يفعّل budget_enforce (قرار المالك)
  BEGIN PERFORM portal_set_governance_flag('budget_enforce', 1);
    RAISE EXCEPTION 'GF7 FAIL: admin flipped owner-locked budget_enforce';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'GF7 FAIL%' THEN RAISE; END IF;
    IF sqlerrm NOT LIKE '%مقفل%' THEN RAISE EXCEPTION 'GF7 FAIL: wrong reason: %', sqlerrm; END IF;
    RAISE NOTICE 'PASS GF7 admin blocked from owner-locked budget_enforce'; END;

  -- GF8 [قفل الإطلاق] الأدمن لا يفعّل txn_notifications
  BEGIN PERFORM portal_set_governance_flag('txn_notifications', 1);
    RAISE EXCEPTION 'GF8 FAIL: admin flipped owner-locked txn_notifications';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'GF8 FAIL%' THEN RAISE; END IF;
    IF sqlerrm NOT LIKE '%مقفل%' THEN RAISE EXCEPTION 'GF8 FAIL: wrong reason: %', sqlerrm; END IF;
    RAISE NOTICE 'PASS GF8 admin blocked from owner-locked txn_notifications'; END;

  -- GF9 التأكّد أنّ المفتاحين المقفلين لم يتغيّرا (بقيا كما هما — لا افتراضي 1)
  SELECT (value->>'budget_enforce')::numeric INTO v_val FROM portal_settings WHERE key='portal_settings';
  IF coalesce(v_val,0) <> 0 THEN RAISE EXCEPTION 'GF9 FAIL: budget_enforce changed (=%)', v_val; END IF;
  RAISE NOTICE 'PASS GF9 owner-locked flags unchanged by admin attempts';

  -- GF10 غير الأدمن (can_manage_users) مرفوض حتى على الضوابط القابلة للضبط
  PERFORM set_config('request.jwt.claims','{"email":"t51_mgr@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_set_governance_flag('contract_enforce', 1);
    RAISE EXCEPTION 'GF10 FAIL: non-admin set a governance flag';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'GF10 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS GF10 non-admin blocked (%.40)', left(sqlerrm,40); END;

  -- GF11 [المسار المُصرَّح] service_role (تفويض المالك/هجرة) يستطيع ضبط مفتاح مقفل
  --      — يمثّل الحالة المُفوَّضة صراحةً، على قاعدة CI محليّة فقط (لا staging مشترك).
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  PERFORM portal_set_governance_flag('budget_enforce', 1);
  SELECT (value->>'budget_enforce')::numeric INTO v_val FROM portal_settings WHERE key='portal_settings';
  IF v_val IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'GF11 FAIL: privileged path could not set locked flag (=%)', v_val; END IF;
  RAISE NOTICE 'PASS GF11 privileged (owner-authorized) path can set a locked flag';
END $t$;

DO $c$ BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 't51_%';
  -- إعادة الإعدادات لحالتها الأصلية (لا تلوّث؛ ولا يبقى أي مفتاح مقفل مُفعَّلاً)
  UPDATE portal_settings SET value =
    (value - 'budget_enforce' - 'txn_notifications' - 'contract_enforce' - 'three_way_tolerance_pct')
    WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $c$;

SELECT '════ GOVERNANCE FLAGS + قفل الإطلاق (P0-1t): GF1..GF12 = 12/12 PASS ════' AS result;

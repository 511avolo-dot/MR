-- ════════════════════════════════════════════════════════════════════════════
-- 40 — سياسة اللجنة المرنة P0-1f
-- يثبت أن اللجنة إعداد منشور وليست حداً ثابتاً في الكود، وأن السلسلة تحفظ
-- snapshot/version، وأن التعديل إداري فقط.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

SELECT set_config(
  'app.p0f_original_policy',
  coalesce((SELECT value::text FROM portal_settings WHERE key='committee_policy'), 'null'),
  false
);

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);

  INSERT INTO portal_departments(id,name_ar,sector,active)
  VALUES ('QA-P0F','QA Flexible Committee','QA',true)
  ON CONFLICT (id) DO UPDATE SET name_ar=excluded.name_ar, sector=excluded.sector, active=true;

  INSERT INTO portal_users(username,email,display_name,department_id,role,job_key,permissions,active)
  VALUES
    ('p0f_admin','p0f_admin@aldeyabi.com','P0F Admin','QA-P0F','admin','employee','{}'::jsonb,true),
    ('p0f_user','p0f_user@aldeyabi.com','P0F User','QA-P0F','user','employee','{}'::jsonb,true)
  ON CONFLICT (username) DO UPDATE SET
    email=excluded.email, display_name=excluded.display_name, department_id=excluded.department_id,
    role=excluded.role, job_key=excluded.job_key, permissions=excluded.permissions, active=true;

  DELETE FROM portal_po_approvals WHERE request_id LIKE 'REQ-P0F-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-P0F-%';

  INSERT INTO portal_requests(id,title,department_id,requester,requester_name,req_type,status,phase,created_by)
  VALUES
    ('REQ-P0F-A','P0F boundary A','QA-P0F','p0f_user','P0F User','purchase','award_review','award','p0f_user'),
    ('REQ-P0F-B','P0F boundary B','QA-P0F','p0f_user','P0F User','purchase','award_review','award','p0f_user'),
    ('REQ-P0F-C','P0F configurable range','QA-P0F','p0f_user','P0F User','purchase','award_review','award','p0f_user'),
    ('REQ-P0F-SNAPSHOT','P0F snapshot','QA-P0F','p0f_user','P0F User','purchase','award_review','award','p0f_user')
  ON CONFLICT (id) DO UPDATE SET title=excluded.title, requester=excluded.requester, status=excluded.status, phase=excluded.phase;

  PERFORM set_config('app.portal_transition', '0', true);
END $seed$;

-- FC1: الحد حصري؛ 25,000 لا لجنة و25,001 تدخل اللجنة.
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0f_admin@aldeyabi.com","role":"authenticated"}',true);
  SELECT portal_set_committee_policy(jsonb_build_object(
    'enabled',true,'min_amount_exclusive',25000,'max_amount_inclusive',null,'fallback_role_key',null
  ));
COMMIT;

DO $fc1$
DECLARE v_at int; v_above int;
BEGIN
  PERFORM portal_build_po_chain('REQ-P0F-A',25000);
  SELECT count(*) INTO v_at FROM portal_po_approvals
   WHERE request_id='REQ-P0F-A' AND kind='committee';
  PERFORM portal_build_po_chain('REQ-P0F-B',25001);
  SELECT count(*) INTO v_above FROM portal_po_approvals
   WHERE request_id='REQ-P0F-B' AND kind='committee';
  IF v_at <> 0 OR v_above <> 1 THEN
    RAISE EXCEPTION 'FC1 fail: at=% above=%',v_at,v_above;
  END IF;
  RAISE NOTICE 'PASS FC1 حد اللجنة حصري وقابل للضبط: 25,000 خارجها و25,001 داخلها';
END $fc1$;

-- FC2: تعطيل اللجنة بلا مسار بديل يلغي مرحلة اللجنة للطلبات الجديدة.
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0f_admin@aldeyabi.com","role":"authenticated"}',true);
  SELECT portal_set_committee_policy(jsonb_build_object('enabled',false,'fallback_role_key',null));
COMMIT;

DO $fc2$
DECLARE v_count int;
BEGIN
  PERFORM portal_build_po_chain('REQ-P0F-A',50000);
  SELECT count(*) INTO v_count FROM portal_po_approvals
   WHERE request_id='REQ-P0F-A' AND kind IN ('committee','committee_fallback');
  IF v_count <> 0 THEN RAISE EXCEPTION 'FC2 fail: count=%',v_count; END IF;
  RAISE NOTICE 'PASS FC2 يمكن تعطيل اللجنة بلا مرحلة وهمية';
END $fc2$;

-- FC3: عند تعطيل اللجنة يمكن نشر مسار بديل واضح.
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0f_admin@aldeyabi.com","role":"authenticated"}',true);
  SELECT portal_set_committee_policy(jsonb_build_object(
    'enabled',false,'fallback_role_key','can_approve_finance'
  ));
COMMIT;

DO $fc3$
DECLARE v_count int; v_role text;
BEGIN
  PERFORM portal_build_po_chain('REQ-P0F-A',50000);
  SELECT count(*),max(role_key) INTO v_count,v_role FROM portal_po_approvals
   WHERE request_id='REQ-P0F-A' AND kind='committee_fallback';
  IF v_count <> 1 OR v_role <> 'can_approve_finance' THEN
    RAISE EXCEPTION 'FC3 fail: count=% role=%',v_count,v_role;
  END IF;
  IF (SELECT count(*) FROM portal_po_approvals
      WHERE request_id='REQ-P0F-A' AND role_key='can_approve_finance') <> 1 THEN
    RAISE EXCEPTION 'FC3 fail: duplicate fallback/finance stage';
  END IF;
  RAISE NOTICE 'PASS FC3 المسار البديل منشور بلا تكرار مرحلة مالية';
END $fc3$;

-- FC4: النطاق الأدنى/الأعلى قابلان للتغيير دون تعديل الكود.
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0f_admin@aldeyabi.com","role":"authenticated"}',true);
  SELECT portal_set_committee_policy(jsonb_build_object(
    'enabled',true,'min_amount_exclusive',100000,'max_amount_inclusive',125000,'fallback_role_key',null
  ));
COMMIT;

DO $fc4$
DECLARE v_low int; v_mid int; v_high int;
BEGIN
  PERFORM portal_build_po_chain('REQ-P0F-A',50000);
  SELECT count(*) INTO v_low FROM portal_po_approvals WHERE request_id='REQ-P0F-A' AND kind='committee';
  PERFORM portal_build_po_chain('REQ-P0F-B',100001);
  SELECT count(*) INTO v_mid FROM portal_po_approvals WHERE request_id='REQ-P0F-B' AND kind='committee';
  PERFORM portal_build_po_chain('REQ-P0F-C',125001);
  SELECT count(*) INTO v_high FROM portal_po_approvals WHERE request_id='REQ-P0F-C' AND kind='committee';
  IF v_low <> 0 OR v_mid <> 1 OR v_high <> 0 THEN
    RAISE EXCEPTION 'FC4 fail: low=% mid=% high=%',v_low,v_mid,v_high;
  END IF;
  RAISE NOTICE 'PASS FC4 نطاق اللجنة يتغير من الإعدادات لا من الكود';
END $fc4$;

-- FC5: سلسلة قائمة تحتفظ بنسخة السياسة بعد نشر نسخة جديدة.
DO $fc5a$
BEGIN
  PERFORM portal_build_po_chain('REQ-P0F-SNAPSHOT',110000);
END $fc5a$;

BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0f_admin@aldeyabi.com","role":"authenticated"}',true);
  SELECT portal_set_committee_policy(jsonb_build_object('min_amount_exclusive',200000,'max_amount_inclusive',null));
COMMIT;

DO $fc5b$
DECLARE v_row_ver int; v_live_ver int; v_min numeric;
BEGIN
  SELECT policy_version,(policy_snapshot->>'min_amount_exclusive')::numeric
    INTO v_row_ver,v_min
  FROM portal_po_approvals
  WHERE request_id='REQ-P0F-SNAPSHOT' AND kind='committee';
  SELECT (portal_get_committee_policy()->>'version')::int INTO v_live_ver;
  IF v_row_ver IS NULL OR v_row_ver >= v_live_ver OR v_min <> 100000 THEN
    RAISE EXCEPTION 'FC5 fail: row_ver=% live_ver=% snapshot_min=%',v_row_ver,v_live_ver,v_min;
  END IF;
  RAISE NOTICE 'PASS FC5 المعاملة تحتفظ بنسخة السياسة ولا تتغير بأثر رجعي';
END $fc5b$;

-- FC6: المستخدم العادي لا يستطيع نشر سياسة اللجنة.
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0f_user@aldeyabi.com","role":"authenticated"}',true);
  DO $fc6$
  DECLARE v_denied boolean := false;
  BEGIN
    BEGIN
      PERFORM portal_set_committee_policy(jsonb_build_object('enabled',false));
    EXCEPTION WHEN OTHERS THEN
      v_denied := SQLERRM LIKE '%الأدمن فقط%';
    END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FC6 fail: ordinary user changed policy'; END IF;
    RAISE NOTICE 'PASS FC6 نشر السياسة إداري فقط';
  END $fc6$;
ROLLBACK;

-- FC7: السياسة غير المنطقية تُرفض.
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0f_admin@aldeyabi.com","role":"authenticated"}',true);
  DO $fc7$
  DECLARE v_denied boolean := false;
  BEGIN
    BEGIN
      PERFORM portal_set_committee_policy(jsonb_build_object(
        'min_amount_exclusive',125000,'max_amount_inclusive',25000
      ));
    EXCEPTION WHEN OTHERS THEN
      v_denied := SQLERRM LIKE '%أكبر من الحد الأدنى%';
    END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FC7 fail: invalid bounds accepted'; END IF;
    RAISE NOTICE 'PASS FC7 الحدود غير المنطقية مرفوضة';
  END $fc7$;
ROLLBACK;

-- FC8: كل مرحلة تحمل اسم السياسة والنسخة واللقطة.
DO $fc8$
DECLARE v_bad int;
BEGIN
  SELECT count(*) INTO v_bad FROM portal_po_approvals
   WHERE request_id LIKE 'REQ-P0F-%'
     AND (policy_key IS DISTINCT FROM 'committee_policy'
          OR policy_version IS NULL
          OR policy_snapshot = '{}'::jsonb);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'FC8 fail: rows without policy evidence=%',v_bad; END IF;
  RAISE NOTICE 'PASS FC8 مراحل أمر الشراء قابلة للتتبع إلى سياسة منشورة';
END $fc8$;

DO $cleanup$
DECLARE v_original jsonb;
BEGIN
  v_original := nullif(current_setting('app.p0f_original_policy',true),'null')::jsonb;
  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_po_approvals WHERE request_id LIKE 'REQ-P0F-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-P0F-%';
  DELETE FROM portal_users WHERE username IN ('p0f_admin','p0f_user');
  DELETE FROM portal_user_directory WHERE username IN ('p0f_admin','p0f_user');
  DELETE FROM portal_departments WHERE id='QA-P0F';
  IF v_original IS NULL THEN
    DELETE FROM portal_settings WHERE key='committee_policy';
  ELSE
    INSERT INTO portal_settings(key,value) VALUES ('committee_policy',v_original)
    ON CONFLICT (key) DO UPDATE SET value=excluded.value;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);
END $cleanup$;

DO $done$ BEGIN
  RAISE NOTICE '════ FLEXIBLE COMMITTEE POLICY: FC1–FC8 = 8/8 PASS ════';
END $done$;

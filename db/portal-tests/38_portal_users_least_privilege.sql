-- ════════════════════════════════════════════════════════════════════════════
--  38 — أقلّ امتياز على portal_users + إغلاق P0-1c
--  يؤكد فعلياً بدور authenticated أن:
--    • الطالب يقرأ صفّه فقط من portal_users ولا يرى email/role/permissions لغيره
--    • دليل المستخدمين الآمن ليس SECURITY DEFINER view، بل جدول RLS بأعمدة آمنة
--    • الأدمن يحتفظ بقراءة إدارة المستخدمين
--    • تصعيد الدور المباشر محجوب حتى في بيئة اختبار PGUSER=postgres
--    • سياسات الكتابة المباشرة الواسعة على الجداول الحساسة أُغلقت
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

-- كعب auth.jwt() كما يوفّره Supabase: يقرأ request.jwt.claims.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

-- بذر ثلاثة مستخدمين. يتم كمالك قاعدة الاختبار قبل SET ROLE.
DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);

  INSERT INTO portal_users (username,email,display_name,role,permissions,department_id,active)
  VALUES ('plp_admin','plp_admin@aldeyabi.com','بيلاء أدمن','admin','{}'::jsonb,'GA',true)
  ON CONFLICT (username) DO UPDATE SET role='admin', permissions='{}'::jsonb, department_id='GA', active=true;

  INSERT INTO portal_users (username,email,display_name,role,permissions,department_id,active)
  VALUES ('plp_req','plp_req@aldeyabi.com','طالب عادي','user','{"can_create":true}'::jsonb,'OPS',true)
  ON CONFLICT (username) DO UPDATE SET role='user', permissions='{"can_create":true}'::jsonb, department_id='OPS', active=true;

  INSERT INTO portal_users (username,email,display_name,role,permissions,department_id,active)
  VALUES ('plp_other','plp_other@aldeyabi.com','مستخدم آخر','user','{"can_disburse":true}'::jsonb,'CON',true)
  ON CONFLICT (username) DO UPDATE SET role='user', permissions='{"can_disburse":true}'::jsonb, department_id='CON', active=true;

  PERFORM set_config('app.portal_transition', '0', true);
END $seed$;

-- ── PU0: الدليل الآمن ليس view ولا Security Definer، وأعمدته آمنة فقط ─────────
DO $struct$
DECLARE v_cols text; v_relkind text; v_bad_writes int;
BEGIN
  SELECT c.relkind INTO v_relkind
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname='public' AND c.relname='portal_user_directory';
  IF v_relkind IS DISTINCT FROM 'r' THEN
    RAISE EXCEPTION 'PU0 fail: portal_user_directory يجب أن يكون جدولاً آمناً لا view (relkind=%)', v_relkind;
  END IF;

  SELECT coalesce(string_agg(column_name, ',' ORDER BY column_name),'')
    INTO v_cols
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='portal_user_directory';
  IF v_cols <> 'active,department_id,display_name,username' THEN
    RAISE EXCEPTION 'PU0 fail: أعمدة الدليل غير آمنة/غير متوقّعة: %', v_cols;
  END IF;

  SELECT count(*) INTO v_bad_writes
  FROM pg_policy pol
  JOIN pg_class c ON c.oid = pol.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname='public'
    AND c.relname IN (
      'portal_settings','portal_departments','portal_jobs','portal_workflows','portal_doa',
      'portal_requests','portal_request_items','portal_approvals','portal_offers',
      'portal_award','portal_award_approvals','portal_po_approvals','portal_payments',
      'portal_receipts','portal_suppliers','portal_users'
    )
    AND pol.polcmd <> 'r'
    AND (pg_get_expr(pol.polqual, pol.polrelid) = 'true'
         OR pg_get_expr(pol.polwithcheck, pol.polrelid) = 'true');
  IF v_bad_writes <> 0 THEN
    RAISE EXCEPTION 'PU0 fail: توجد % سياسة كتابة مباشرة واسعة true', v_bad_writes;
  END IF;

  RAISE NOTICE 'PASS PU0 الدليل جدول RLS آمن ولا توجد سياسات كتابة مباشرة true';
END $struct$;

-- ── PU1: الطالب العادي يقرأ صفّه الكامل فقط ─────────────────────────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_req@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_email text; v_cnt int;
  BEGIN
    SELECT email INTO v_email FROM portal_users WHERE username='plp_req';
    IF v_email IS DISTINCT FROM 'plp_req@aldeyabi.com' THEN
      RAISE EXCEPTION 'PU1 fail: الطالب لا يقرأ بريد صفّه الذاتي (%)', v_email;
    END IF;

    SELECT count(*) INTO v_cnt FROM portal_users;
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION 'PU1 fail: الطالب يرى % صفّاً (المتوقّع 1 = ذاته)', v_cnt;
    END IF;
    RAISE NOTICE 'PASS PU1 البروفايل الذاتي يعمل والطالب يقرأ صفّه فقط';
  END $t$;
ROLLBACK;

-- ── PU2: الطالب العادي لا يقرأ بريد/صلاحيات مستخدم آخر ─────────────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_req@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_cnt int;
  BEGIN
    SELECT count(*) INTO v_cnt FROM portal_users WHERE username IN ('plp_other','plp_admin');
    IF v_cnt <> 0 THEN
      RAISE EXCEPTION 'PU2 fail: الطالب يرى % صفّ مستخدم آخر', v_cnt;
    END IF;

    SELECT count(*) INTO v_cnt
    FROM portal_users
    WHERE email='plp_other@aldeyabi.com' OR (permissions ? 'can_disburse');
    IF v_cnt <> 0 THEN
      RAISE EXCEPTION 'PU2 fail: الطالب يقرأ بريد/صلاحيات غيره';
    END IF;
    RAISE NOTICE 'PASS PU2 لا تسريب لبريد/صلاحيات/صفوف الآخرين';
  END $t$;
ROLLBACK;

-- ── PU3: الدليل الآمن يعرض كل المستخدمين بأعمدة آمنة فقط ────────────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_req@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_cnt int; v_has boolean;
  BEGIN
    SELECT count(*) INTO v_cnt
    FROM portal_user_directory
    WHERE username IN ('plp_admin','plp_req','plp_other');
    IF v_cnt <> 3 THEN
      RAISE EXCEPTION 'PU3 fail: الدليل لا يعرض كل المستخدمين للطالب (% من 3)', v_cnt;
    END IF;

    BEGIN
      EXECUTE 'SELECT email FROM portal_user_directory LIMIT 1';
      v_has := true;
    EXCEPTION WHEN undefined_column THEN
      v_has := false;
    END;
    IF v_has THEN
      RAISE EXCEPTION 'PU3 fail: الدليل يكشف عمود email';
    END IF;
    RAISE NOTICE 'PASS PU3 الدليل يعرض كل المستخدمين بأعمدة آمنة فقط';
  END $t$;
ROLLBACK;

-- ── PU4: الأدمن يحتفظ بقراءة كل الصفوف لإدارة المستخدمين ───────────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_admin@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_cnt int; v_email text;
  BEGIN
    SELECT count(*) INTO v_cnt FROM portal_users WHERE username IN ('plp_admin','plp_req','plp_other');
    IF v_cnt <> 3 THEN
      RAISE EXCEPTION 'PU4 fail: الأدمن يرى % من 3 صفوف', v_cnt;
    END IF;

    SELECT email INTO v_email FROM portal_users WHERE username='plp_other';
    IF v_email IS DISTINCT FROM 'plp_other@aldeyabi.com' THEN
      RAISE EXCEPTION 'PU4 fail: الأدمن لا يقرأ بريد مستخدم آخر';
    END IF;
    RAISE NOTICE 'PASS PU4 الأدمن يحتفظ بقراءة كل الصفوف';
  END $t$;
ROLLBACK;

-- ── PU5: تصعيد الدور المباشر من العميل محجوب بسياسة RLS والحارس ─────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_req@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_rows int; v_role text;
  BEGIN
    UPDATE portal_users SET role='admin' WHERE username='plp_req';
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN
      RAISE EXCEPTION 'PU5 fail: الطالب استطاع تعديل role rows=%', v_rows;
    END IF;

    SELECT role INTO v_role FROM portal_users WHERE username='plp_req';
    IF v_role IS DISTINCT FROM 'user' THEN
      RAISE EXCEPTION 'PU5 fail: role تغيّر فعلياً إلى %', v_role;
    END IF;
    RAISE NOTICE 'PASS PU5 تصعيد الدور المباشر محجوب';
  END $t$;
ROLLBACK;

-- ── PU6: الطالب العادي لا يستطيع الكتابة المباشرة على جداول حساسة ────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_req@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_rows int; v_blocked boolean;
  BEGIN
    UPDATE portal_settings SET value=value; GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN RAISE EXCEPTION 'PU6 fail: portal_settings rows=%', v_rows; END IF;

    UPDATE portal_departments SET active=active; GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN RAISE EXCEPTION 'PU6 fail: portal_departments rows=%', v_rows; END IF;

    UPDATE portal_jobs SET active=active; GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN RAISE EXCEPTION 'PU6 fail: portal_jobs rows=%', v_rows; END IF;

    UPDATE portal_workflows SET active=active; GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN RAISE EXCEPTION 'PU6 fail: portal_workflows rows=%', v_rows; END IF;

    UPDATE portal_doa SET note=note; GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN RAISE EXCEPTION 'PU6 fail: portal_doa rows=%', v_rows; END IF;

    UPDATE portal_requests SET status=status; GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN RAISE EXCEPTION 'PU6 fail: portal_requests rows=%', v_rows; END IF;

    UPDATE portal_approvals SET decision=decision; GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 0 THEN RAISE EXCEPTION 'PU6 fail: portal_approvals rows=%', v_rows; END IF;

    v_blocked := false;
    BEGIN
      INSERT INTO portal_suppliers(name) VALUES ('P0C should be blocked');
    EXCEPTION WHEN OTHERS THEN
      v_blocked := true;
    END;
    IF NOT v_blocked THEN
      RAISE EXCEPTION 'PU6 fail: الطالب أدخل مورداً مباشرة';
    END IF;

    v_blocked := false;
    BEGIN
      INSERT INTO portal_requests(id,title,department_id,requester,requester_name,priority,status)
      VALUES ('P0C-RLS-BLOCK','P0C RLS Block','OPS','plp_req','طالب عادي','normal','draft');
    EXCEPTION WHEN OTHERS THEN
      v_blocked := true;
    END;
    IF NOT v_blocked THEN
      RAISE EXCEPTION 'PU6 fail: الطالب أدخل طلباً مباشرة';
    END IF;

    RAISE NOTICE 'PASS PU6 الكتابة المباشرة الحساسة محجوبة عن الطالب العادي';
  END $t$;
ROLLBACK;

-- تنظيف بذور الاختبار.
DO $cleanup$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_users WHERE username IN ('plp_admin','plp_req','plp_other');
  DELETE FROM portal_user_directory WHERE username IN ('plp_admin','plp_req','plp_other');
  PERFORM set_config('app.portal_transition', '0', true);
END $cleanup$;

DO $done$ BEGIN
  RAISE NOTICE '════ PORTAL_USERS/P0-1c LEAST-PRIVILEGE: PU0–PU6 = 7/7 PASS ════';
END $done$;

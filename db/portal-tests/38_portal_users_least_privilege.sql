-- ════════════════════════════════════════════════════════════════════════════
--  38 — أقلّ امتياز على portal_users (P0-1/P0-1b) — تأكيدات RLS فعلية بدور authenticated.
--  السياق: أثبتت حزمة Auth/PostgREST الحيّة أنّ مستخدماً عادياً كان يقرأ كل صفوف
--  portal_users بحقولها الإدارية (email/role/permissions). ثم أثبت staging أن
--  session_user=postgres كان يفتح تجاوزاً كاذباً لحارس portal_users_guard.
--  هذا الاختبار يُثبِت العلاجين: قراءة العميل مقصورة على «الصفّ نفسه أو الأدمن»،
--  والدليل الآمن لا يكشف حقولاً حساسة، وتصعيد الدور المباشر يُحجب حتى في سياق
--  اختبار محليّ يستخدم PGUSER=postgres مع JWT مستخدم عادي.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

-- كعب auth.jwt() (كما يوفّره Supabase) — يقرأ request.jwt.claims.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

-- بذر ثلاثة مستخدمين. بعد P0-1b لم يعد session_user=postgres يفتح bypass؛
-- لذلك نستخدم app.portal_transition=1 كباب صريح للتهيئة الاختبارية فقط.
DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);

  INSERT INTO portal_users (username,email,display_name,role,permissions,department_id,active)
  VALUES ('plp_admin','plp_admin@aldeyabi.com','بيلاء أدمن','admin','{}'::jsonb,'GA',true)
  ON CONFLICT (username) DO UPDATE SET role='admin', permissions='{}'::jsonb, active=true;

  INSERT INTO portal_users (username,email,display_name,role,permissions,department_id,active)
  VALUES ('plp_req','plp_req@aldeyabi.com','طالب عادي','user','{"can_create":true}'::jsonb,'OPS',true)
  ON CONFLICT (username) DO UPDATE SET role='user', permissions='{"can_create":true}'::jsonb, active=true;

  INSERT INTO portal_users (username,email,display_name,role,permissions,department_id,active)
  VALUES ('plp_other','plp_other@aldeyabi.com','مستخدم آخر','user','{"can_disburse":true}'::jsonb,'CON',true)
  ON CONFLICT (username) DO UPDATE SET role='user', permissions='{"can_disburse":true}'::jsonb, active=true;

  PERFORM set_config('app.portal_transition', '0', true);
END $seed$;

-- ── PU1: الطالب العادي يقرأ صفّه الكامل (البروفايل الذاتي يعمل) ──────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_req@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_email text; v_cnt int;
  BEGIN
    SELECT email INTO v_email FROM portal_users WHERE username='plp_req';
    IF v_email IS DISTINCT FROM 'plp_req@aldeyabi.com' THEN
      RAISE EXCEPTION 'PU1 fail: الطالب لا يقرأ بريد صفّه الذاتي (%)', v_email; END IF;
    SELECT count(*) INTO v_cnt FROM portal_users;   -- RLS: صفّه فقط
    IF v_cnt <> 1 THEN RAISE EXCEPTION 'PU1 fail: الطالب يرى % صفّاً (المتوقّع 1 = ذاته)', v_cnt; END IF;
    RAISE NOTICE 'PASS PU1 البروفايل الذاتي يعمل (الطالب يقرأ صفّه فقط)';
  END $t$;
ROLLBACK;

-- ── PU2: الطالب العادي لا يقرأ بريد/صلاحيات مستخدم آخر ──────────────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_req@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_cnt int;
  BEGIN
    SELECT count(*) INTO v_cnt FROM portal_users WHERE username IN ('plp_other','plp_admin');
    IF v_cnt <> 0 THEN RAISE EXCEPTION 'PU2 fail: الطالب يرى % صفّ مستخدم آخر (تسريب)', v_cnt; END IF;
    SELECT count(*) INTO v_cnt FROM portal_users WHERE email='plp_other@aldeyabi.com' OR (permissions ? 'can_disburse');
    IF v_cnt <> 0 THEN RAISE EXCEPTION 'PU2 fail: الطالب يقرأ بريد/صلاحيات غيره (تسريب)'; END IF;
    RAISE NOTICE 'PASS PU2 الطالب لا يقرأ بريد/صلاحيات/صفوف الآخرين';
  END $t$;
ROLLBACK;

-- ── PU3: «دليل المستخدمين الآمن» أعمدة توجيه/عرض فقط + يعرض كل المستخدمين ─────
DO $struct$
DECLARE v_cols text;
BEGIN
  SELECT coalesce(string_agg(column_name, ',' ORDER BY column_name),'')
    INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='portal_user_directory';
  IF v_cols <> 'active,department_id,display_name,username' THEN
    RAISE EXCEPTION 'PU3 fail: أعمدة الدليل غير آمنة/غير متوقّعة: %', v_cols; END IF;
  RAISE NOTICE 'PASS PU3a أعمدة الدليل = التوجيه/العرض فقط (بلا email/permissions/role/job/delegation)';
END $struct$;

BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_req@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_cnt int; v_has boolean;
  BEGIN
    SELECT count(*) INTO v_cnt FROM portal_user_directory WHERE username IN ('plp_admin','plp_req','plp_other');
    IF v_cnt <> 3 THEN RAISE EXCEPTION 'PU3 fail: الدليل لا يعرض كل المستخدمين للطالب (% من 3)', v_cnt; END IF;
    BEGIN
      EXECUTE 'SELECT email FROM portal_user_directory LIMIT 1';
      v_has := true;
    EXCEPTION WHEN undefined_column THEN v_has := false;
    END;
    IF v_has THEN RAISE EXCEPTION 'PU3 fail: الدليل يكشف عمود email'; END IF;
    RAISE NOTICE 'PASS PU3b الدليل يعرض كل المستخدمين بأعمدة آمنة فقط (لا email)';
  END $t$;
ROLLBACK;

-- ── PU4: الأدمن يحتفظ بقراءة كل الصفوف عبر العميل (إدارة المستخدمين تعمل) ──────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_admin@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_cnt int; v_email text;
  BEGIN
    SELECT count(*) INTO v_cnt FROM portal_users WHERE username IN ('plp_admin','plp_req','plp_other');
    IF v_cnt <> 3 THEN RAISE EXCEPTION 'PU4 fail: الأدمن يرى % من 3 صفوف (إدارة مكسورة)', v_cnt; END IF;
    SELECT email INTO v_email FROM portal_users WHERE username='plp_other';
    IF v_email IS DISTINCT FROM 'plp_other@aldeyabi.com' THEN
      RAISE EXCEPTION 'PU4 fail: الأدمن لا يقرأ بريد مستخدم آخر'; END IF;
    RAISE NOTICE 'PASS PU4 الأدمن يحتفظ بقراءة كل الصفوف (إدارة المستخدمين سليمة)';
  END $t$;
ROLLBACK;

-- ── PU5: تصعيد الدور المباشر من العميل محجوب (حارس portal_users_guard) ────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"plp_req@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_blocked boolean := false;
  BEGIN
    BEGIN
      UPDATE portal_users SET role='admin' WHERE username='plp_req';
    EXCEPTION WHEN OTHERS THEN v_blocked := true;
    END;
    IF NOT v_blocked THEN RAISE EXCEPTION 'PU5 fail: الطالب صعّد دوره إلى admin (حارس مكسور / session_user bypass)'; END IF;
    RAISE NOTICE 'PASS PU5 تصعيد الدور المباشر محجوب بالحارس حتى مع session_user=postgres';
  END $t$;
ROLLBACK;

-- تنظيف بذور الاختبار (لا تلوّث بقيّة الحزمة)
DO $cleanup$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_users WHERE username IN ('plp_admin','plp_req','plp_other');
  PERFORM set_config('app.portal_transition', '0', true);
END $cleanup$;

DO $done$ BEGIN
  RAISE NOTICE '════ PORTAL_USERS LEAST-PRIVILEGE (P0-1/P0-1b): PU1–PU5 = 5/5 PASS ════';
END $done$;

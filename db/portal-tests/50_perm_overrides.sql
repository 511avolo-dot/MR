-- ════════════════════════════════════════════════════════════════════════════
--  50 — بقاء تخصيصات صلاحيات المستخدم عبر تعديل الوظيفة (P0-1s، عيب مراجعة المالك A3)
--  النموذج: perm_overrides دلتا المستخدم مقابل أساس الوظيفة؛ permissions = الأساس ⊕ الدلتا.
--  الجوهر: أسند وظيفة → خصّص صلاحية مستخدم → عدّل الوظيفة → يجب أن تبقى التخصيصات.
--  + منع التصعيد (غير الأدمن مرفوض) + إعادة تعيين الدلتا عند إسناد وظيفة جديدة.
--  الهويّة عبر request.jwt.claims (auth.jwt()). يُشغَّل بعد p0_1b (رفع تجاوز session_user).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $acl$
BEGIN
  IF has_function_privilege('anon','portal_apply_perm_overrides(jsonb,jsonb)','EXECUTE')
     OR has_function_privilege('anon','portal_perm_overrides_delta(jsonb,jsonb)','EXECUTE')
     OR has_function_privilege('anon','portal_set_user_permission(text,text,boolean)','EXECUTE')
     OR has_function_privilege('authenticated','portal_apply_perm_overrides(jsonb,jsonb)','EXECUTE')
     OR has_function_privilege('authenticated','portal_perm_overrides_delta(jsonb,jsonb)','EXECUTE')
     OR NOT has_function_privilege('authenticated','portal_set_user_permission(text,text,boolean)','EXECUTE') THEN
    RAISE EXCEPTION 'OV9 FAIL: P0-1s function ACLs are broader than intended';
  END IF;
  RAISE NOTICE 'PASS OV9 P0-1s ACL exposes only the authenticated admin mutation RPC';
END $acl$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 't50_%';
  DELETE FROM portal_jobs  WHERE key LIKE 't50_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,perm_overrides,department_id) VALUES
    ('t50_admin','t50_admin@aldeyabi.com','أدمن','admin','{}','{}','GA'),
    ('t50_mgr','t50_mgr@aldeyabi.com','مدير مستخدمين (غير أدمن)','user','{"can_manage_users":true}','{}','GA'),
    ('t50_target','t50_target@aldeyabi.com','هدف','user','{}','{}','GA');
  INSERT INTO portal_jobs(key,title,category,scope,permissions,active) VALUES
    ('t50_jobA','وظيفة أ','GA','own','{"can_create":true}'::jsonb,true),
    ('t50_jobB','وظيفة ب','GA','own','{"can_verify_stock":true}'::jsonb,true);
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $t$
DECLARE v_perms jsonb; v_ov jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"t50_admin@aldeyabi.com","role":"authenticated"}',true);

  -- OV1 إسناد الوظيفة أ للهدف: الفعّالة = أساس الوظيفة، الدلتا فارغة
  PERFORM portal_apply_job('t50_target','t50_jobA');
  SELECT permissions,perm_overrides INTO v_perms,v_ov FROM portal_users WHERE username='t50_target';
  IF NOT (coalesce((v_perms->>'can_create')::boolean,false) AND v_ov='{}'::jsonb) THEN
    RAISE EXCEPTION 'OV1 FAIL: apply_job did not set baseline / empty overrides (perms=%, ov=%)', v_perms, v_ov; END IF;
  RAISE NOTICE 'PASS OV1 apply_job sets baseline + empty overrides';

  -- OV2 منح تخصيص فردي (وحدة العرض المالي) — دلتا تُسجَّل، الفعّالة تشمل الأساس + التخصيص
  PERFORM portal_set_user_permission('t50_target','can_see_finance',true);
  SELECT permissions,perm_overrides INTO v_perms,v_ov FROM portal_users WHERE username='t50_target';
  IF NOT (coalesce((v_perms->>'can_see_finance')::boolean,false)
          AND coalesce((v_perms->>'can_create')::boolean,false)
          AND (v_ov->>'can_see_finance')::boolean IS TRUE) THEN
    RAISE EXCEPTION 'OV2 FAIL: override grant not applied (perms=%, ov=%)', v_perms, v_ov; END IF;
  RAISE NOTICE 'PASS OV2 admin per-user grant records delta + effective';

  -- OV3 [الجوهر] تعديل الوظيفة أ (إضافة can_edit) — التخصيص الفردي يبقى، والأساس الجديد يُطبَّق
  PERFORM portal_save_job('t50_jobA','وظيفة أ','GA','own','{"can_create":true,"can_edit":true}'::jsonb,NULL);
  SELECT permissions,perm_overrides INTO v_perms,v_ov FROM portal_users WHERE username='t50_target';
  IF NOT (coalesce((v_perms->>'can_see_finance')::boolean,false)      -- التخصيص نجا ✔
          AND coalesce((v_perms->>'can_edit')::boolean,false)          -- الأساس الجديد طُبِّق ✔
          AND coalesce((v_perms->>'can_create')::boolean,false)
          AND (v_ov->>'can_see_finance')::boolean IS TRUE) THEN
    RAISE EXCEPTION 'OV3 FAIL: job edit destroyed the user override (perms=%, ov=%)', v_perms, v_ov; END IF;
  RAISE NOTICE 'PASS OV3 job edit preserves the per-user override (A3 core fix)';

  -- OV4 سحب صلاحية من الأساس (دلتا=false) — الفعّالة تفقدها
  PERFORM portal_set_user_permission('t50_target','can_create',false);
  SELECT permissions,perm_overrides INTO v_perms,v_ov FROM portal_users WHERE username='t50_target';
  IF coalesce((v_perms->>'can_create')::boolean,false) OR (v_ov->>'can_create')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'OV4 FAIL: baseline revoke not applied (perms=%, ov=%)', v_perms, v_ov; END IF;
  RAISE NOTICE 'PASS OV4 per-user revoke of a baseline key';

  -- OV5 إعادة القيمة لمطابقة الأساس تُسقط الدلتا (لا تراكم دلتا لا لزوم لها)
  PERFORM portal_set_user_permission('t50_target','can_create',true);
  SELECT perm_overrides INTO v_ov FROM portal_users WHERE username='t50_target';
  IF (v_ov ? 'can_create') THEN
    RAISE EXCEPTION 'OV5 FAIL: override equal to baseline was not dropped (ov=%)', v_ov; END IF;
  RAISE NOTICE 'PASS OV5 setting a key back to baseline drops its override';

  -- OV6 إعادة إسناد وظيفة جديدة تُصفّر الدلتا (تغيّر الدور = أساس نظيف)
  PERFORM portal_set_user_permission('t50_target','can_see_finance',true);  -- دلتا موجودة قبل الإسناد
  PERFORM portal_apply_job('t50_target','t50_jobB');
  SELECT permissions,perm_overrides INTO v_perms,v_ov FROM portal_users WHERE username='t50_target';
  IF NOT (v_ov='{}'::jsonb AND coalesce((v_perms->>'can_verify_stock')::boolean,false)
          AND NOT coalesce((v_perms->>'can_see_finance')::boolean,false)) THEN
    RAISE EXCEPTION 'OV6 FAIL: new job assignment did not reset overrides (perms=%, ov=%)', v_perms, v_ov; END IF;
  RAISE NOTICE 'PASS OV6 assigning a new job resets overrides to baseline';

  -- OV7 [منع التصعيد] غير الأدمن (حامل can_manage_users) لا يعدّل صلاحيات مستخدم
  PERFORM set_config('request.jwt.claims','{"email":"t50_mgr@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_set_user_permission('t50_target','can_disburse',true);
    RAISE EXCEPTION 'OV7 FAIL: non-admin edited a user permission';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'OV7 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS OV7 non-admin blocked from editing user permissions (%.50)', left(sqlerrm,50);
  END;

  -- OV8 [انحدار] مفتاح غير معروف مرفوض
  PERFORM set_config('request.jwt.claims','{"email":"t50_admin@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_set_user_permission('t50_target','can_bogus',true);
    RAISE EXCEPTION 'OV8 FAIL: unknown key accepted';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'OV8 FAIL%' THEN RAISE; END IF;
    IF sqlerrm NOT LIKE '%غير معروف%' THEN RAISE EXCEPTION 'OV8 FAIL: wrong reason: %', sqlerrm; END IF;
    RAISE NOTICE 'PASS OV8 unknown key rejected';
  END;
END $t$;

DO $c$ BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 't50_%';
  DELETE FROM portal_jobs  WHERE key LIKE 't50_%';
  PERFORM set_config('app.portal_transition','0',true);
END $c$;

SELECT '════ PER-USER PERMISSION OVERRIDES (P0-1s): OV1..OV9 = 9/9 PASS ════' AS result;

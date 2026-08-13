-- P0-1r -- add can_approve_disbursement to the job permission whitelist
--
-- Gap (owner UX/permissions mandate A2, 2026-08-07): the disbursement engine
-- (migration 050) introduced the permission key `can_approve_disbursement`
-- and seeds a finance job (`fin_accounts_mgr`) that carries it, yet
-- `portal_save_job`'s allow-list (`v_allowed`) never listed the key. As a
-- result a portal admin could NOT create or edit any job that grants
-- disbursement-approval authority through the jobs editor — the RPC rejected
-- it with "مفتاح صلاحية غير معروف". This violates the mandate that every
-- engine permission key be assignable to a job and editable.
--
-- Fix: add `can_approve_disbursement` to the save whitelist, and — because it
-- confers financial approval authority — to BOTH sensitive-key guards
-- (`portal_save_job` and `portal_apply_job`) so that minting/assigning it
-- still requires full admin (anti-escalation preserved; a bare
-- `can_manage_users` holder cannot grant it). No behavior weakens: all other
-- guards (gm-protected, unknown-key rejection, deny-by-default) are unchanged.
--
-- Idempotent: pure CREATE OR REPLACE of the two functions.
BEGIN;

CREATE OR REPLACE FUNCTION portal_save_job(p_key text, p_title text, p_category text,
    p_scope text, p_permissions jsonb, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_holders int; v_k text;
  v_allowed text[] := ARRAY['can_approve_stage','can_approve_award','can_issue_po','can_manage_procurement',
    'can_approve_finance','can_disburse','can_create','can_edit','can_manage_users','can_see_finance',
    'can_verify_stock','can_manage_company','can_approve_committee','can_approve_disbursement'];
  v_sensitive text[] := ARRAY['can_manage_users','can_manage_company','can_disburse','can_approve_award',
    'can_approve_finance','can_approve_stage','can_manage_procurement','can_issue_po','can_approve_committee',
    'can_see_finance','can_approve_disbursement'];
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'تعديل الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  IF coalesce(trim(p_key),'') = '' OR coalesce(trim(p_title),'') = '' THEN
    RAISE EXCEPTION 'مفتاح الوظيفة واسمها مطلوبان';
  END IF;
  IF p_scope NOT IN ('own','sector','all') THEN RAISE EXCEPTION 'نطاق غير صالح (own/sector/all)'; END IF;
  IF p_key = 'gm' AND NOT (p_permissions = '{}'::jsonb OR p_permissions IS NULL) THEN
    RAISE EXCEPTION 'وظيفة المدير العام محمية — صلاحياتها من دور الأدمن مباشرة';
  END IF;
  FOR v_k IN SELECT jsonb_object_keys(coalesce(p_permissions,'{}'::jsonb)) LOOP
    IF NOT (v_k = ANY(v_allowed)) THEN RAISE EXCEPTION 'مفتاح صلاحية غير معروف: %', v_k; END IF;
  END LOOP;
  -- صلاحيات اعتماد/صرف/إدارية لا يصكّها إلا أدمن حقيقي (كان القيد يقتصر على can_manage_users/company).
  IF NOT (portal_is_admin() OR portal_is_privileged())
     AND (coalesce(p_permissions,'{}'::jsonb) ?| v_sensitive) THEN
    RAISE EXCEPTION 'إنشاء/تعديل وظيفة تمنح صلاحيات اعتماد/صرف/إدارية يتطلّب صلاحية أدمن كاملة';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
  VALUES (p_key, trim(p_title), p_category, p_scope, coalesce(p_permissions,'{}'::jsonb), p_description, true)
  ON CONFLICT (key) DO UPDATE SET title = EXCLUDED.title, category = EXCLUDED.category,
    scope = EXCLUDED.scope, permissions = EXCLUDED.permissions, description = EXCLUDED.description;
  UPDATE portal_users SET permissions = coalesce(p_permissions,'{}'::jsonb) WHERE job_key = p_key;
  GET DIAGNOSTICS v_holders = ROW_COUNT;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_saved', v_me, 'portal',
    jsonb_build_object('job', p_key, 'holders_updated', v_holders));
  RETURN jsonb_build_object('ok', true, 'holders_updated', v_holders);
END $fn$;

CREATE OR REPLACE FUNCTION portal_apply_job(p_username text, p_job_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_job portal_jobs%ROWTYPE;
  v_user portal_users%ROWTYPE;
  v_new_role text;
  v_other_admins int;
  v_grants_sensitive boolean;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  SELECT * INTO v_job FROM portal_jobs WHERE key = p_job_key AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'وظيفة غير موجودة أو غير مفعّلة'; END IF;

  v_grants_sensitive := (p_job_key = 'gm')
    OR (coalesce(v_job.permissions,'{}'::jsonb) ?| ARRAY['can_manage_users','can_manage_company','can_disburse',
        'can_approve_award','can_approve_finance','can_approve_stage','can_manage_procurement',
        'can_issue_po','can_approve_committee','can_see_finance','can_approve_disbursement']);
  IF v_grants_sensitive AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد صلاحيات اعتماد/صرف/إدارية يتطلّب صلاحية أدمن كاملة';
  END IF;
  IF p_username = v_me AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'لا يمكنك إسناد وظيفة لنفسك (فصل المهام)';
  END IF;

  SELECT * INTO v_user FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;

  v_new_role := CASE WHEN p_job_key = 'gm' THEN 'admin' ELSE 'user' END;
  IF v_user.role = 'admin' AND v_new_role <> 'admin' THEN
    PERFORM pg_advisory_xact_lock(hashtext('portal_admin_guard'));
    SELECT count(*) INTO v_other_admins FROM portal_users
      WHERE role = 'admin' AND active AND username <> p_username;
    IF v_other_admins = 0 THEN
      RAISE EXCEPTION 'لا يمكن تجريد آخر أدمن نشط من صلاحياته — أسند gm لغيره أولاً';
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET job_key = p_job_key, permissions = v_job.permissions, role = v_new_role
    WHERE username = p_username;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_assigned', v_me, 'portal',
    jsonb_build_object('user', p_username, 'job', p_job_key));
  RETURN jsonb_build_object('ok', true, 'job', p_job_key, 'role', v_new_role);
END $fn$;

COMMIT;

-- P0-1s -- per-user permission overrides survive job edits (mandate A3 precedence model)
--
-- Defect (owner Gate review, 2026-08-07): portal_save_job() cascaded
--   UPDATE portal_users SET permissions = p_permissions WHERE job_key = p_key;
-- which blindly overwrote EVERY assigned user's full permissions object. Once
-- the UI began persisting per-user permission customizations, any later edit of
-- the job silently destroyed those individual grants/revokes — contradicting
-- mandate A3 ("صلاحيات المستخدم قابلة للتعديل حسب الحاجة").
--
-- Precedence model (authoritative):
--   * portal_jobs.permissions          = job baseline (role template).
--   * portal_users.perm_overrides jsonb = per-user delta vs the CURRENT job
--       baseline: {"key":true} grants beyond the job, {"key":false} revokes a
--       job-granted key, absent = follow the baseline. {} = no customization.
--   * portal_users.permissions          = MATERIALIZED effective set
--       = portal_apply_perm_overrides(job_baseline, perm_overrides).
--       This stays the single column read by portal_has_perm (read path
--       unchanged) — only the way it is (re)computed changes.
--   * Invariant: permissions is always recomputed from (baseline ⊕ overrides)
--       whenever either side changes, so overrides survive job edits.
--   * Assigning a NEW job (portal_apply_job) resets overrides to {} (role
--       change = clean baseline) — deterministic and documented.
--
-- Governance: per-user overrides are edited only through the new
-- portal_set_user_permission RPC, gated to full admin/privileged (a bare
-- can_manage_users holder cannot). Admins already hold every permission, so no
-- self-escalation vector is opened. All writes raise the portal_transition flag
-- so portal_users_guard still blocks direct client writes.
--
-- Repo/tests only — NOT applied to any live database by this migration.
BEGIN;

ALTER TABLE portal_users ADD COLUMN IF NOT EXISTS perm_overrides jsonb NOT NULL DEFAULT '{}'::jsonb;

-- effective = baseline with per-user overrides applied (true=grant, false=revoke);
-- returns only the true keys (matches the {key:true} convention of permissions).
CREATE OR REPLACE FUNCTION portal_apply_perm_overrides(p_base jsonb, p_ov jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public AS $fn$
  SELECT coalesce(jsonb_object_agg(k, true) FILTER (WHERE eff), '{}'::jsonb)
  FROM (
    SELECT k, CASE WHEN coalesce(p_ov,'{}'::jsonb) ? k
                   THEN coalesce((p_ov->>k)::boolean, false)
                   ELSE coalesce((p_base->>k)::boolean, false) END AS eff
    FROM (SELECT jsonb_object_keys(coalesce(p_base,'{}'::jsonb)) AS k
          UNION
          SELECT jsonb_object_keys(coalesce(p_ov,'{}'::jsonb))) u
  ) e;
$fn$;

-- delta: keys where an effective set differs from the job baseline — used to
-- backfill legacy per-user customizations that predate the overrides column.
CREATE OR REPLACE FUNCTION portal_perm_overrides_delta(p_eff jsonb, p_base jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = public AS $fn$
  SELECT coalesce(jsonb_object_agg(k, ev) FILTER (WHERE ev IS DISTINCT FROM bv), '{}'::jsonb)
  FROM (
    SELECT k, coalesce((p_eff->>k)::boolean, false) AS ev,
              coalesce((p_base->>k)::boolean, false) AS bv
    FROM (SELECT jsonb_object_keys(coalesce(p_eff,'{}'::jsonb)) AS k
          UNION
          SELECT jsonb_object_keys(coalesce(p_base,'{}'::jsonb))) u
  ) d;
$fn$;

-- ── portal_save_job: preserve each user's overrides across job edits ──
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
  IF NOT (portal_is_admin() OR portal_is_privileged())
     AND (coalesce(p_permissions,'{}'::jsonb) ?| v_sensitive) THEN
    RAISE EXCEPTION 'إنشاء/تعديل وظيفة تمنح صلاحيات اعتماد/صرف/إدارية يتطلّب صلاحية أدمن كاملة';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
  VALUES (p_key, trim(p_title), p_category, p_scope, coalesce(p_permissions,'{}'::jsonb), p_description, true)
  ON CONFLICT (key) DO UPDATE SET title = EXCLUDED.title, category = EXCLUDED.category,
    scope = EXCLUDED.scope, permissions = EXCLUDED.permissions, description = EXCLUDED.description;
  -- recompute each assigned user's EFFECTIVE permissions from the new baseline
  -- while preserving that user's individual overrides (A3 fix).
  UPDATE portal_users u
    SET permissions = portal_apply_perm_overrides(coalesce(p_permissions,'{}'::jsonb),
                                                  coalesce(u.perm_overrides,'{}'::jsonb))
    WHERE u.job_key = p_key;
  GET DIAGNOSTICS v_holders = ROW_COUNT;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_saved', v_me, 'portal',
    jsonb_build_object('job', p_key, 'holders_updated', v_holders));
  RETURN jsonb_build_object('ok', true, 'holders_updated', v_holders);
END $fn$;

-- ── portal_apply_job: assigning a new job resets the user's overrides ──
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
  UPDATE portal_users SET job_key = p_job_key, permissions = v_job.permissions,
      perm_overrides = '{}'::jsonb, role = v_new_role
    WHERE username = p_username;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_assigned', v_me, 'portal',
    jsonb_build_object('user', p_username, 'job', p_job_key));
  RETURN jsonb_build_object('ok', true, 'job', p_job_key, 'role', v_new_role);
END $fn$;

-- ── portal_set_user_permission: admin-only per-user override (grant/revoke) ──
CREATE OR REPLACE FUNCTION portal_set_user_permission(p_username text, p_key text, p_on boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_user portal_users%ROWTYPE;
  v_base jsonb; v_ov jsonb; v_base_has boolean;
  v_allowed text[] := ARRAY['can_approve_stage','can_approve_award','can_issue_po','can_manage_procurement',
    'can_approve_finance','can_disburse','can_create','can_edit','can_manage_users','can_see_finance',
    'can_verify_stock','can_manage_company','can_approve_committee','can_approve_disbursement'];
BEGIN
  -- per-user permission editing is a full-admin action (anti-escalation): a bare
  -- can_manage_users holder cannot mint sensitive capabilities onto users.
  IF NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'تعديل صلاحيات المستخدم يتطلّب صلاحية أدمن كاملة';
  END IF;
  IF NOT (p_key = ANY(v_allowed)) THEN RAISE EXCEPTION 'مفتاح صلاحية غير معروف: %', p_key; END IF;
  SELECT * INTO v_user FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;
  IF v_user.role = 'admin' THEN
    RAISE EXCEPTION 'الأدمن يملك كل الصلاحيات — لا يُعدَّل بشكل فردي';
  END IF;

  v_base := coalesce((SELECT permissions FROM portal_jobs WHERE key = v_user.job_key AND active), '{}'::jsonb);
  v_base_has := coalesce((v_base->>p_key)::boolean, false);
  v_ov := coalesce(v_user.perm_overrides, '{}'::jsonb);
  IF p_on = v_base_has THEN
    v_ov := v_ov - p_key;                                   -- desired equals baseline → drop the override
  ELSE
    v_ov := jsonb_set(v_ov, ARRAY[p_key], to_jsonb(p_on), true);
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET perm_overrides = v_ov,
      permissions = portal_apply_perm_overrides(v_base, v_ov)
    WHERE username = p_username;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'user_perm_set', v_me, 'portal',
    jsonb_build_object('user', p_username, 'key', p_key, 'on', p_on));
  RETURN jsonb_build_object('ok', true, 'key', p_key, 'on', p_on, 'overrides', v_ov);
END $fn$;

-- backfill legacy per-user customizations (permissions diverged from job baseline
-- before this column existed) so the FIRST job edit afterward preserves them.
-- Wrapped with the portal_transition flag so portal_users_guard permits this
-- controlled migration write (direct client writes stay denied).
DO $bf$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users u
    SET perm_overrides = portal_perm_overrides_delta(
          coalesce(u.permissions,'{}'::jsonb),
          coalesce((SELECT permissions FROM portal_jobs j WHERE j.key = u.job_key), '{}'::jsonb))
    WHERE u.role <> 'admin'
      AND coalesce(u.perm_overrides,'{}'::jsonb) = '{}'::jsonb;
  PERFORM set_config('app.portal_transition', '0', true);
END $bf$;

REVOKE ALL ON FUNCTION portal_apply_perm_overrides(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION portal_perm_overrides_delta(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION portal_set_user_permission(text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION portal_set_user_permission(text,text,boolean) TO authenticated, service_role;

COMMIT;

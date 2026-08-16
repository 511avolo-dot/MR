-- ════════════════════════════════════════════════════════════════════════════
--  p0_2a — فكّ ربط «المدير العام» (gm) بدور الأدمن + دالة منح السوبر-يوزر
--  (تكليف المالك 2026-08-13)
--  ---------------------------------------------------------------------------
--  توجيه المالك الصريح: «المدير العام ليس admin؛ إنما مدير في دورة عمل بمزايا رؤية
--  شاملة فقط، ويجب أن يكون قابلاً للإيقاف/الحذف مثل أي مستخدم. السوبر-يوزر هو مدير
--  البوابة (عبدالله)، وميزة السوبر-يوزر أمنحها لمن أريد.»
--
--  المشكلة: portal_apply_job كانت تُسند role='admin' تلقائيّاً لحامل وظيفة gm، فيصير
--  محميّاً بحُرّاس الأدمن (تعذّر حذفه/إيقافه)، ويتلقّى تنبيهات الأدمن.
--
--  الإصلاح (إضافة/تعديل فقط، بلا حذف بيانات):
--   1) apply_job لم تعُد تجعل gm أدمن — تُسند role='user' دائماً (تبقى صلاحيات الوظيفة
--      can_manage_users ونطاقها scope='all' = رؤية شاملة، فيؤدّي المدير العام مرحلته في
--      سلسلة أمر الشراء ويرى كل شيء، لكنه مستخدم عاديّ قابل للحذف).
--   2) portal_set_admin(username, on): يمنح/يسحب صلاحية السوبر-يوزر — للأدمن (مدير
--      البوابة) فقط، بحارس «آخر أدمن نشط»، ورفع علم الانتقال، وتدقيق. هي القناة المقصودة
--      لتعيين السوبر-يوزر بدل الربط الضمنيّ بوظيفة gm.
--   3) مصالحة لمرّة واحدة: حاملو وظيفة gm الذين صاروا أدمن **بسبب الربط القديم فقط**
--      يُعادون إلى role='user' (بشرط بقاء أدمن واحد غير-gm على الأقل — لا يُمَسّ الأدمن
--      الحقيقي عبدالله). بعدها يصير المدير العام قابلاً للحذف/الإيقاف كأي مستخدم.
--
--  idempotent: CREATE OR REPLACE + UPDATE محروس بعلم الانتقال. مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) apply_job: gm لم تعُد تعني admin ──────────────────────────────────────
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

  -- (تكليف المالك 2026-08-13) الوظائف لا تصكّ سوبر-يوزر — بما فيها gm. الأدمن يُدار عبر
  -- portal_set_admin فقط. إسناد أي وظيفة ⇒ role='user'.
  v_new_role := 'user';
  -- حماية آخر أدمن نشط: إن كان المستخدم أدمن وسيُخفَّض بإسناد وظيفة، تأكّد من بقاء غيره.
  IF v_user.role = 'admin' AND v_new_role <> 'admin' THEN
    PERFORM pg_advisory_xact_lock(hashtext('portal_admin_guard'));
    SELECT count(*) INTO v_other_admins FROM portal_users
      WHERE role = 'admin' AND active AND username <> p_username;
    IF v_other_admins = 0 THEN
      RAISE EXCEPTION 'لا يمكن تجريد آخر أدمن نشط من صلاحياته — عيّن سوبر-يوزر لغيره أولاً (portal_set_admin)';
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET job_key = p_job_key, permissions = v_job.permissions,
      perm_overrides = '{}'::jsonb, role = v_new_role
    WHERE username = p_username;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_assigned', v_me, 'portal',
    jsonb_build_object('user', p_username, 'job', p_job_key, 'role', v_new_role));
  RETURN jsonb_build_object('ok', true, 'job', p_job_key, 'role', v_new_role);
END $fn$;

-- ── (2) portal_set_admin: منح/سحب السوبر-يوزر (مدير البوابة فقط) ──────────────
CREATE OR REPLACE FUNCTION portal_set_admin(p_username text, p_on boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_user portal_users%ROWTYPE; v_other int;
BEGIN
  -- صلاحية السوبر-يوزر تُمنَح/تُسحَب من الأدمن (مدير البوابة) فقط — منع تصعيد.
  IF NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'منح/سحب صلاحية السوبر-يوزر متاح لمدير البوابة (الأدمن) فقط';
  END IF;
  SELECT * INTO v_user FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;

  IF p_on THEN
    IF NOT v_user.active THEN RAISE EXCEPTION 'لا يُمنَح السوبر-يوزر لمستخدم غير نشط'; END IF;
    IF v_user.role = 'admin' THEN RETURN jsonb_build_object('ok', true, 'user', p_username, 'admin', true, 'noop', true); END IF;
    PERFORM set_config('app.portal_transition','1',true);
    UPDATE portal_users SET role = 'admin' WHERE username = p_username;
    PERFORM set_config('app.portal_transition','0',true);
  ELSE
    IF v_user.role <> 'admin' THEN RETURN jsonb_build_object('ok', true, 'user', p_username, 'admin', false, 'noop', true); END IF;
    PERFORM pg_advisory_xact_lock(hashtext('portal_admin_guard'));
    SELECT count(*) INTO v_other FROM portal_users WHERE role = 'admin' AND active AND username <> p_username;
    IF v_other = 0 THEN RAISE EXCEPTION 'لا يمكن سحب صلاحية آخر سوبر-يوزر نشط — عيّن غيره أولاً'; END IF;
    PERFORM set_config('app.portal_transition','1',true);
    UPDATE portal_users SET role = 'user' WHERE username = p_username;
    PERFORM set_config('app.portal_transition','0',true);
  END IF;

  PERFORM portal_audit_write(NULL, 'admin_role_set', v_me, 'portal',
    jsonb_build_object('user', p_username, 'admin', p_on));
  RETURN jsonb_build_object('ok', true, 'user', p_username, 'admin', p_on);
END $fn$;
REVOKE ALL ON FUNCTION portal_set_admin(text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_set_admin(text,boolean) TO authenticated, service_role;

-- ── (3) مصالحة لمرّة واحدة: gm-admin (من الربط القديم) ⇒ user ─────────────────
--   لا يُمَسّ الأدمن الحقيقي (بلا وظيفة gm). لا يُنفَّذ إلا مع بقاء أدمن غير-gm واحد على الأقل.
DO $reconcile$
DECLARE v_non_gm_admins int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('portal_admin_guard'));
  SELECT count(*) INTO v_non_gm_admins FROM portal_users
    WHERE role = 'admin' AND active AND coalesce(job_key,'') <> 'gm';
  IF v_non_gm_admins >= 1 THEN
    PERFORM set_config('app.portal_transition','1',true);
    -- role→user + استعادة صلاحيات وظيفة gm (كان permissions فارغاً لأنه أدمن): يحتفظ المدير
    -- العام بصلاحية مرحلته can_manage_users ورؤيته الشاملة (scope='all' عبر job_key='gm')،
    -- لكنه مستخدم عاديّ قابل للحذف. perm_overrides يُصفَّر (أساس نظيف).
    UPDATE portal_users u
       SET role = 'user',
           permissions = coalesce((SELECT permissions FROM portal_jobs j WHERE j.key = u.job_key AND j.active), '{}'::jsonb),
           perm_overrides = '{}'::jsonb
     WHERE u.role = 'admin' AND u.job_key = 'gm';
    PERFORM set_config('app.portal_transition','0',true);
    PERFORM portal_audit_write(NULL, 'gm_admin_decoupled', 'system:p0_2a', 'portal',
      jsonb_build_object('note', 'gm-job holders demoted admin→user (job perms restored) per owner mandate'));
  ELSE
    RAISE WARNING 'p0_2a: لم تُنفَّذ مصالحة gm→user (لا يوجد أدمن غير-gm نشط لحمايته)';
  END IF;
END $reconcile$;

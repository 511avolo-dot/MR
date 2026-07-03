-- ════════════════════════════════════════════════════════════════════════
--  Migration 004 — الموردون + دوال الإدارة المحمية (المرحلة 5)
-- ════════════════════════════════════════════════════════════════════════
--  المصدر: سيناريوهات 6-18..6-21. جداول الإعدادات (DoA/workflows/settings/
--  depts/jobs) محميّة أصلاً بـ portal_config_guard (أدمن/can_manage_users فقط)،
--  فتحريرها المباشر من الواجهة آمن. أما الحمايات المنطقية (حذف مرتبط، إنشاء
--  سلسلة القطاع تلقائياً) فتُنفَّذ بالدالة لا الواجهة.
--  آمن لإعادة التشغيل بالكامل (idempotent).
-- ════════════════════════════════════════════════════════════════════════

-- 1) جدول الموردين (كتالوج مرجعي)
CREATE TABLE IF NOT EXISTS portal_suppliers (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  cr          TEXT,
  vat         TEXT,
  iban        TEXT,
  contact     TEXT,
  active      BOOLEAN NOT NULL DEFAULT true,
  created_by  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE portal_suppliers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON portal_suppliers;
CREATE POLICY "auth_all" ON portal_suppliers FOR ALL TO authenticated USING (true) WITH CHECK (true);
-- الكتابة محكومة بحارس الإعدادات (أدمن/can_manage_users) — نفس نمط الأقسام/الوظائف.
DROP TRIGGER IF EXISTS trg_portal_suppliers_guard ON portal_suppliers;
CREATE TRIGGER trg_portal_suppliers_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_suppliers
  FOR EACH ROW EXECUTE FUNCTION portal_config_guard();

-- 2) حفظ/تعديل قسم + إنشاء سلسلته تلقائياً إن كان قطاعاً جديداً (6-19).
--    القطاعات غير «الإدارة العامة» تُنشأ لها سلسلة 3 مراحل (مدير القطاع ← مالية
--    ← مشتريات)؛ لا يُعاد بناء سلسلة قائمة (حفاظاً على تعديلات المصمّم).
CREATE OR REPLACE FUNCTION portal_save_department(
    p_id text, p_name text, p_sector text, p_manager text DEFAULT NULL, p_active boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_wf_id text; v_sec text;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_has_perm('can_manage_company') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إدارة الأقسام تتطلّب صلاحية إدارية';
  END IF;
  IF coalesce(trim(p_id),'') = '' OR coalesce(trim(p_name),'') = '' THEN RAISE EXCEPTION 'معرّف القسم واسمه مطلوبان'; END IF;
  v_sec := coalesce(nullif(trim(p_sector),''), trim(p_name));

  INSERT INTO portal_departments (id, name_ar, sector, manager_user, active)
    VALUES (trim(p_id), trim(p_name), v_sec, nullif(p_manager,''), coalesce(p_active,true))
  ON CONFLICT (id) DO UPDATE SET name_ar = EXCLUDED.name_ar, sector = EXCLUDED.sector,
    manager_user = EXCLUDED.manager_user, active = EXCLUDED.active;

  -- إنشاء سلسلة القطاع إن لزم (غير الإدارة العامة، ولا سلسلة قائمة لنفس القطاع)
  IF v_sec <> 'الإدارة العامة' THEN
    v_wf_id := 'wf-sec-' || regexp_replace(v_sec, '\s+', '_', 'g');
    IF NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = v_wf_id) THEN
      INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
      VALUES (v_wf_id, 'قطاع: ' || v_sec, 25, v_sec, jsonb_build_array(
        jsonb_build_object('seq',1,'label','اعتماد مدير قطاع '||v_sec,'resolver','dept_manager','sla',24),
        jsonb_build_object('seq',2,'label','التحقق المالي المسبق','resolver','role','role_key','can_approve_finance','sla',24),
        jsonb_build_object('seq',3,'label','الإذن ببدء التسعير — مدير المشتريات','resolver','role','role_key','can_manage_procurement','sla',24)
      ), true);
    END IF;
  END IF;

  PERFORM portal_audit_write(NULL, 'dept_saved', v_me, 'portal', jsonb_build_object('dept', p_id));
  RETURN jsonb_build_object('ok', true, 'id', trim(p_id));
END $fn$;

-- 3) حذف قسم محمي (6-19): يُمنع إن كان له طلبات أو موظفون، أو كان آخر قسم.
CREATE OR REPLACE FUNCTION portal_delete_department(p_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_reqs int; v_users int; v_total int;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_has_perm('can_manage_company') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إدارة الأقسام تتطلّب صلاحية إدارية';
  END IF;
  SELECT count(*) INTO v_reqs FROM portal_requests WHERE department_id = p_id;
  IF v_reqs > 0 THEN RAISE EXCEPTION 'لا يمكن حذف قسم له % طلب — أغلقه بدل الحذف', v_reqs; END IF;
  SELECT count(*) INTO v_users FROM portal_users WHERE department_id = p_id;
  IF v_users > 0 THEN RAISE EXCEPTION 'لا يمكن حذف قسم مرتبط بـ % موظف — انقلهم أولاً', v_users; END IF;
  SELECT count(*) INTO v_total FROM portal_departments;
  IF v_total <= 1 THEN RAISE EXCEPTION 'لا يمكن حذف آخر قسم'; END IF;
  DELETE FROM portal_departments WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'القسم غير موجود'; END IF;
  PERFORM portal_audit_write(NULL, 'dept_deleted', v_me, 'portal', jsonb_build_object('dept', p_id));
  RETURN jsonb_build_object('ok', true);
END $fn$;

-- 4) حذف مورد محمي (6-21): يُمنع إن كان مرتبطاً بعروض/تعميدات (بالاسم).
CREATE OR REPLACE FUNCTION portal_delete_supplier(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_name text; v_linked int;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_has_perm('can_manage_company') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إدارة الموردين تتطلّب صلاحية إدارية';
  END IF;
  SELECT name INTO v_name FROM portal_suppliers WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'المورد غير موجود'; END IF;
  SELECT count(*) INTO v_linked FROM portal_offers WHERE supplier_name = v_name;
  IF v_linked > 0 THEN RAISE EXCEPTION 'لا يمكن حذف مورد مرتبط بـ % عرض/تعميد — عطّله بدل الحذف', v_linked; END IF;
  DELETE FROM portal_suppliers WHERE id = p_id;
  PERFORM portal_audit_write(NULL, 'supplier_deleted', v_me, 'portal', jsonb_build_object('supplier', v_name));
  RETURN jsonb_build_object('ok', true);
END $fn$;


-- ════════════════════════════════════════════════════════════════════════
-- 5) إصلاحات أمنية (من الفحص العدائي متعدد الوكلاء)
-- ════════════════════════════════════════════════════════════════════════

-- (أ) HIGH: منع تصعيد الصلاحية عبر دوال الوظائف — حامل can_manage_users (غير
--     الأدمن) كان يستطيع إسناد gm لنفسه (يصبح أدمن) أو صكّ مفاتيح إدارية عبر
--     وظيفة. الآن: منح دور الأدمن (gm) أو صلاحيات مانحة للإدارة يتطلّب أدمن
--     حقيقياً، والصلاحيات تُقيَّد بقائمة بيضاء معروفة.
CREATE OR REPLACE FUNCTION portal_apply_job(p_username text, p_job_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_job portal_jobs%ROWTYPE;
  v_user portal_users%ROWTYPE;
  v_new_role text;
  v_other_admins int;
  v_grants_admin boolean;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  SELECT * INTO v_job FROM portal_jobs WHERE key = p_job_key AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'وظيفة غير موجودة أو غير مفعّلة'; END IF;

  -- منع تصعيد الصلاحية: إسناد وظيفة تمنح الأدمن (gm) أو مفاتيح إدارية مانحة
  -- (إدارة المستخدمين/المنشأة) يتطلّب أدمن حقيقياً — لا يكفي can_manage_users.
  v_grants_admin := (p_job_key = 'gm')
    OR coalesce((v_job.permissions->>'can_manage_users')::boolean, false)
    OR coalesce((v_job.permissions->>'can_manage_company')::boolean, false);
  IF v_grants_admin AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد صلاحيات إدارية عليا يتطلّب صلاحية أدمن كاملة';
  END IF;

  SELECT * INTO v_user FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;

  v_new_role := CASE WHEN p_job_key = 'gm' THEN 'admin' ELSE 'user' END;
  IF v_user.role = 'admin' AND v_new_role <> 'admin' THEN
    -- قفل استشاري يمنع سباق تجريد آخر أدمن (TOCTOU) بين عمليتين متزامنتين
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

-- (ب) HIGH: portal_save_job — قائمة بيضاء لمفاتيح الصلاحيات، ومنع غير الأدمن من
--     صكّ صلاحيات إدارية مانحة (can_manage_users/can_manage_company).
CREATE OR REPLACE FUNCTION portal_save_job(p_key text, p_title text, p_category text,
    p_scope text, p_permissions jsonb, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_holders int; v_k text;
  v_allowed text[] := ARRAY['can_approve_stage','can_approve_award','can_issue_po','can_manage_procurement',
    'can_approve_finance','can_disburse','can_create','can_edit','can_manage_users','can_see_finance',
    'can_verify_stock','can_manage_company'];
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

  -- قائمة بيضاء: أي مفتاح مجهول يُرفض (يمنع صكّ صلاحيات مخترَعة).
  FOR v_k IN SELECT jsonb_object_keys(coalesce(p_permissions,'{}'::jsonb)) LOOP
    IF NOT (v_k = ANY(v_allowed)) THEN RAISE EXCEPTION 'مفتاح صلاحية غير معروف: %', v_k; END IF;
  END LOOP;
  -- صلاحيات إدارية مانحة لا يصكّها إلا أدمن حقيقي.
  IF (coalesce((p_permissions->>'can_manage_users')::boolean,false)
      OR coalesce((p_permissions->>'can_manage_company')::boolean,false))
     AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إنشاء وظيفة بصلاحيات إدارية عليا يتطلّب صلاحية أدمن كاملة';
  END IF;

  INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
  VALUES (p_key, trim(p_title), p_category, p_scope, coalesce(p_permissions,'{}'::jsonb), p_description, true)
  ON CONFLICT (key) DO UPDATE SET title = EXCLUDED.title, category = EXCLUDED.category,
    scope = EXCLUDED.scope, permissions = EXCLUDED.permissions, description = EXCLUDED.description;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET permissions = coalesce(p_permissions,'{}'::jsonb) WHERE job_key = p_key;
  GET DIAGNOSTICS v_holders = ROW_COUNT;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_saved', v_me, 'portal',
    jsonb_build_object('job', p_key, 'holders_updated', v_holders));
  RETURN jsonb_build_object('ok', true, 'holders_updated', v_holders);
END $fn$;

-- (ج) MEDIUM: portal_create_request — لغير الأدمن، القطاع يُشتق حصراً من الملف؛
--     إن كان بلا قسم يُرفض (لا سقوط على مُدخَل العميل)، وتحقّق نوع البنود الرقمي.
CREATE OR REPLACE FUNCTION portal_create_request(
    p_title text, p_department_id text, p_priority text, p_items jsonb,
    p_project text, p_need_by date, p_proc_type text DEFAULT 'normal',
    p_justification text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_my_dept text; v_dept text; v_id text;
  v_item jsonb; v_seq int := 0; v_est numeric := 0; v_name text;
  v_q numeric; v_p numeric; v_quotes int;
  v_win_days numeric; v_thr numeric; v_cluster_sum numeric; v_peers int; v_all_below boolean;
  v_split boolean := false;
  MAXQ CONSTANT numeric := 1000000;
  MAXP CONSTANT numeric := 100000000;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (portal_has_perm('can_create') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'رفع الطلبات يتطلّب صلاحية «رفع الطلبات» — راجع الإدارة لإسناد وظيفة';
  END IF;
  IF coalesce(trim(p_title), '') = '' THEN RAISE EXCEPTION 'اكتب وصف الطلب'; END IF;
  IF coalesce(trim(p_project), '') = '' THEN RAISE EXCEPTION 'اسم المشروع مطلوب'; END IF;
  IF p_need_by IS NULL THEN RAISE EXCEPTION 'تاريخ التوريد المطلوب مطلوب'; END IF;
  IF coalesce(p_proc_type,'normal') NOT IN ('normal','single','emergency') THEN
    RAISE EXCEPTION 'نوع شراء غير صالح';
  END IF;
  IF coalesce(p_proc_type,'normal') <> 'normal' AND coalesce(trim(p_justification),'') = '' THEN
    RAISE EXCEPTION 'التبرير مطلوب لهذا النوع من الشراء';
  END IF;

  SELECT department_id INTO v_my_dept FROM portal_users WHERE username = v_me;
  IF portal_is_admin() THEN
    v_dept := coalesce(nullif(p_department_id,''), v_my_dept);
  ELSE
    -- غير الأدمن: القطاع من الملف حصراً — لا سقوط على مُدخَل العميل.
    IF coalesce(v_my_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم في ملفك — راجع الإدارة'; END IF;
    IF coalesce(p_department_id,'') <> '' AND p_department_id <> v_my_dept THEN
      RAISE EXCEPTION 'القطاع يُحدَّد تلقائياً من ملفك — لا يمكن اختيار قسم آخر';
    END IF;
    v_dept := v_my_dept;
  END IF;
  IF coalesce(v_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم محدَّد للطلب'; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = v_dept AND active) THEN
    RAISE EXCEPTION 'قطاعك مغلق حالياً لاستقبال الطلبات — راجع الإدارة';
  END IF;

  IF jsonb_array_length(coalesce(p_items, '[]'::jsonb)) < 1 THEN RAISE EXCEPTION 'أضِف بنداً واحداً على الأقل'; END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF coalesce(trim(v_item->>'desc'), '') = '' THEN RAISE EXCEPTION 'وصف كل بند مطلوب'; END IF;
    -- تحقّق النوع الرقمي (رسالة عربية بدل خطأ cast خام)
    IF jsonb_typeof(v_item->'qty') <> 'number' OR jsonb_typeof(coalesce(v_item->'price','0'::jsonb)) <> 'number' THEN
      RAISE EXCEPTION 'كمية/سعر غير رقمي في: %', v_item->>'desc';
    END IF;
    v_q := (v_item->>'qty')::numeric;
    v_p := coalesce((v_item->>'price')::numeric, 0);
    IF v_q <= 0 OR v_q > MAXQ THEN RAISE EXCEPTION 'كمية غير منطقية في: %', v_item->>'desc'; END IF;
    IF v_p < 0 OR v_p > MAXP THEN RAISE EXCEPTION 'سعر غير منطقي في: %', v_item->>'desc'; END IF;
    v_est := v_est + v_q * v_p;
  END LOOP;

  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    v_quotes := 1;
  ELSE
    SELECT quotes_required INTO v_quotes FROM portal_doa
      WHERE max_value IS NULL OR v_est <= max_value
      ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
    v_quotes := coalesce(v_quotes, 3);
  END IF;

  v_id := 'REQ-' || to_char(now(), 'YYYYMMDD') || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
  SELECT display_name INTO v_name FROM portal_users WHERE username = v_me;

  IF portal_setting_bool('split_guard', true) THEN
    v_thr := portal_setting_num('split_threshold', 100000);
    v_win_days := portal_setting_num('split_window_days', 7);
    SELECT count(*), coalesce(sum(est_total),0), coalesce(bool_and(est_total < v_thr), true)
      INTO v_peers, v_cluster_sum, v_all_below
      FROM portal_requests
      WHERE department_id = v_dept AND status <> 'rejected'
        AND created_at >= now() - make_interval(days => v_win_days::int)
        AND created_at <= now() + make_interval(days => v_win_days::int);
    IF v_peers > 0 AND (v_cluster_sum + v_est) >= v_thr AND v_all_below AND v_est < v_thr THEN
      v_split := true;
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_requests (id, title, department_id, requester, requester_name, priority,
                               est_total, created_by, project, need_by, proc_type, justification, note, quotes_required, split_flag)
    VALUES (v_id, trim(p_title), v_dept, v_me, v_name, coalesce(nullif(p_priority, ''), 'متوسط'),
            v_est, v_me, trim(p_project), p_need_by, coalesce(p_proc_type,'normal'),
            nullif(trim(coalesce(p_justification,'')),''), nullif(trim(coalesce(p_note,'')),''), v_quotes, v_split);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_seq := v_seq + 1;
    INSERT INTO portal_request_items (request_id, seq, description, unit, qty, unit_price)
      VALUES (v_id, v_seq, v_item->>'desc', v_item->>'unit', (v_item->>'qty')::numeric, coalesce((v_item->>'price')::numeric, 0));
  END LOOP;
  PERFORM set_config('app.portal_transition', '0', true);

  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    PERFORM portal_audit_write(v_id, 'proc_type', v_me, 'portal',
      jsonb_build_object('type', p_proc_type, 'justification', p_justification));
  END IF;
  IF v_split THEN
    PERFORM portal_audit_write(v_id, 'split_flag', v_me, 'portal',
      jsonb_build_object('cluster_sum', v_cluster_sum + v_est, 'threshold', v_thr, 'window_days', v_win_days, 'peers', v_peers));
  END IF;

  RETURN portal_submit_request(v_id) || jsonb_build_object('id', v_id, 'quotes_required', v_quotes, 'split_flag', v_split);
END $fn$;

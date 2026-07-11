-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 018 — مواءمة قائمة صلاحيات portal_save_job (انجراف من المراجعة النهائية، MEDIUM)
--  المشكلة: standalone يضع can_approve_committee في القائمة البيضاء لـportal_save_job،
--  لكن سلسلة الهجرات (004) لم تُضِفها ولم تُعِد أي هجرة تعريف الدالة بعدها — فقاعدة
--  الإنتاج (المبنية من الهجرات) ترفض إنشاء/تعديل وظيفة تمنح صلاحية اللجنة بخطأ
--  «مفتاح صلاحية غير معروف: can_approve_committee». تعيين اللجنة عبر لوحة اللجنة
--  (portal_set_committee) يعمل، لكن محرّر الوظائف لا. هذه الهجرة تعيد تعريف الدالة
--  مطابقةً لـstandalone (تُضيف can_approve_committee). idempotent (CREATE OR REPLACE).
--  شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 017.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_save_job(p_key text, p_title text, p_category text,
    p_scope text, p_permissions jsonb, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_holders int; v_k text;
  v_allowed text[] := ARRAY['can_approve_stage','can_approve_award','can_issue_po','can_manage_procurement',
    'can_approve_finance','can_disburse','can_create','can_edit','can_manage_users','can_see_finance',
    'can_verify_stock','can_manage_company','can_approve_committee'];
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

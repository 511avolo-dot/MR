-- P0-1u -- persist the workflow designer to the database (mandate C6)
--
-- Gap: the "مصمّم سير العمل" (workflow designer) let an admin add/remove/reorder
-- approval stages by drag-and-drop, but there was NO save RPC — edits mutated
-- only the in-memory WORKFLOWS array and were lost on the next loadAll (which
-- rebuilds from portal_workflows). The designer was effectively a dead demo in
-- the live portal; the owner's "طريقة الإسناد والتصميم غير واضحة" follows directly.
--
-- This adds admin-only, validated persistence so designed chains actually take
-- effect. Governance is NOT weakened: the runtime separation-of-duties and
-- deny-by-default guards in portal_pr_transition are independent of the chain
-- definition — a chain is just data that build_chain expands into portal_approvals,
-- and every transition is still checked (requester≠approver, stage-N≠stage-M, …).
--
-- Repo/tests only — NOT applied to any live database.
BEGIN;

CREATE OR REPLACE FUNCTION portal_save_workflow(
    p_id text, p_name text, p_priority int, p_sector text,
    p_min_total numeric, p_max_total numeric, p_stages jsonb, p_cycle text DEFAULT 'need')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_stage jsonb; v_res text; v_n int := 0;
  v_allowed_roles text[] := ARRAY['can_approve_stage','can_approve_award','can_issue_po',
    'can_manage_procurement','can_approve_finance','can_disburse','can_approve_committee',
    'can_manage_users','can_verify_stock','can_approve_disbursement'];
BEGIN
  IF NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'تعديل مسارات الاعتماد يتطلّب صلاحية أدمن كاملة';
  END IF;
  IF coalesce(trim(p_id),'') = '' OR coalesce(trim(p_name),'') = '' THEN
    RAISE EXCEPTION 'معرّف المسار واسمه مطلوبان';
  END IF;
  IF p_stages IS NULL OR jsonb_typeof(p_stages) <> 'array' THEN
    RAISE EXCEPTION 'المراحل يجب أن تكون مصفوفة';
  END IF;

  FOR v_stage IN SELECT * FROM jsonb_array_elements(p_stages) LOOP
    v_n := v_n + 1;
    v_res := v_stage->>'resolver';
    IF v_res IS NULL OR v_res NOT IN ('dept_manager','role','user') THEN
      RAISE EXCEPTION 'مُحلّل المرحلة % غير صالح (dept_manager/role/user): %', v_n, coalesce(v_res,'(فارغ)');
    END IF;
    IF coalesce(trim(v_stage->>'label'),'') = '' THEN
      RAISE EXCEPTION 'اسم المرحلة % مطلوب', v_n;
    END IF;
    IF v_res = 'role' THEN
      IF NOT ((v_stage->>'role_key') = ANY(v_allowed_roles)) THEN
        RAISE EXCEPTION 'مفتاح الدور غير معروف في المرحلة %: %', v_n, coalesce(v_stage->>'role_key','(فارغ)');
      END IF;
      -- فشل-مغلق (تحقّق تغطية): مرحلة دور بلا أيّ معتمِد ممكن تُرفض قبل النشر.
      IF NOT EXISTS (SELECT 1 FROM portal_users
                     WHERE active AND coalesce((permissions->>(v_stage->>'role_key'))::boolean,false)) THEN
        RAISE EXCEPTION 'المرحلة % بلا معتمِد ممكن: لا مستخدم نشط يملك الصلاحية «%»', v_n, v_stage->>'role_key';
      END IF;
    ELSIF v_res = 'user' THEN
      IF NOT EXISTS (SELECT 1 FROM portal_users WHERE username = (v_stage->>'approver') AND active) THEN
        RAISE EXCEPTION 'المعتمِد المحدَّد في المرحلة % غير موجود أو غير نشط', v_n;
      END IF;
    END IF;
  END LOOP;
  IF v_n = 0 THEN RAISE EXCEPTION 'يجب أن يحتوي المسار على مرحلة واحدة على الأقل'; END IF;
  IF (SELECT count(DISTINCT (e->>'seq')) FROM jsonb_array_elements(p_stages) e) <> v_n THEN
    RAISE EXCEPTION 'أرقام تسلسل المراحل (seq) مكرّرة أو ناقصة';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_workflows(id, name, priority, sector, min_total, max_total, stages, active, cycle)
    VALUES (trim(p_id), trim(p_name), coalesce(p_priority,100),
            nullif(trim(coalesce(p_sector,'')),''), coalesce(p_min_total,0), p_max_total,
            p_stages, true, coalesce(nullif(trim(coalesce(p_cycle,'')),''),'need'))
  ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, priority = EXCLUDED.priority,
    sector = EXCLUDED.sector, min_total = EXCLUDED.min_total, max_total = EXCLUDED.max_total,
    stages = EXCLUDED.stages, cycle = EXCLUDED.cycle, active = true;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'workflow_saved', v_me, 'portal',
    jsonb_build_object('id', trim(p_id), 'stages', v_n));
  RETURN jsonb_build_object('ok', true, 'id', trim(p_id), 'stages', v_n);
END $fn$;

CREATE OR REPLACE FUNCTION portal_delete_workflow(p_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_used boolean; v_mode text;
BEGIN
  IF NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'حذف مسارات الاعتماد يتطلّب صلاحية أدمن كاملة';
  END IF;
  SELECT EXISTS(SELECT 1 FROM portal_requests WHERE workflow_id = p_id) INTO v_used;
  PERFORM set_config('app.portal_transition', '1', true);
  IF v_used THEN
    UPDATE portal_workflows SET active = false WHERE id = p_id;   -- مستخدَم في طلبات: تعطيل لا حذف (سلامة التدقيق)
    v_mode := 'deactivated';
  ELSE
    DELETE FROM portal_workflows WHERE id = p_id;
    v_mode := 'deleted';
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);
  PERFORM portal_audit_write(NULL, 'workflow_deleted', v_me, 'portal',
    jsonb_build_object('id', p_id, 'mode', v_mode));
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'mode', v_mode);
END $fn$;

REVOKE ALL ON FUNCTION portal_save_workflow(text,text,int,text,numeric,numeric,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION portal_delete_workflow(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION portal_save_workflow(text,text,int,text,numeric,numeric,jsonb,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION portal_delete_workflow(text) TO authenticated, service_role;

COMMIT;

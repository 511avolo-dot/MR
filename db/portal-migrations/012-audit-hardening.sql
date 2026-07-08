-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 012 — إصلاحات ما بعد المراجعة الأمنية/الجودة
--  (1) نطاق الرؤية: مدير قطاع بلا قسم (department_id=NULL) كان portal_my_sector()
--      يرجع NULL فيطابق كل الأقسام ذات القطاع NULL → رؤية أوسع من المفترض. نُقيّده
--      بأن يكون قطاع المستخدم غير NULL (وإلا يسقط إلى own عبر بقية شروط الرؤية).
--  (2) حذف المستخدم: portal_requests.requester = NOT NULL FK بلا ON DELETE، فحذف
--      مستخدم له طلبات يفشل بانتهاك FK. الصواب حوكمياً (سلامة التدقيق): منع الحذف
--      الصلب لمن له سجلّ معاملات وتوجيهه إلى «تعطيل الحساب» بدلاً منه.
--  idempotent (CREATE OR REPLACE). شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 011.
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) رؤية الطلب — تقييد فرع القطاع بألّا يكون قطاع المستخدم NULL.
CREATE OR REPLACE FUNCTION portal_can_see_request(p_id text, p_requester text, p_dept text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    portal_is_admin()
    OR portal_my_scope() = 'all'
    OR p_requester = portal_username()
    OR (portal_my_scope() = 'sector' AND portal_my_sector() IS NOT NULL AND EXISTS (
          SELECT 1 FROM portal_departments d
           WHERE d.id = p_dept AND d.sector = portal_my_sector()))
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.approver = portal_username());
$fn$;

-- (2) حذف المستخدم — منع الحذف الصلب لمن له طلبات (سلامة التدقيق) + توجيه للتعطيل.
CREATE OR REPLACE FUNCTION portal_delete_user(p_username text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_role text; v_active boolean; v_admins int;
BEGIN
  IF v_me IS NULL OR NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_username IS NULL OR p_username = v_me THEN RAISE EXCEPTION 'لا يمكنك حذف حسابك'; END IF;
  SELECT role, active INTO v_role, v_active FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;
  IF v_role = 'admin' AND v_active THEN
    PERFORM pg_advisory_xact_lock(hashtext('portal_last_admin'));
    SELECT count(*) INTO v_admins FROM portal_users WHERE role = 'admin' AND active;
    IF v_admins <= 1 THEN RAISE EXCEPTION 'لا يمكن حذف آخر أدمن نشط للبوابة'; END IF;
  END IF;
  -- سلامة التدقيق: لا حذف صلب لمن له سجلّ معاملات (طلبات) — يُعطَّل حسابه بدلاً من ذلك.
  IF EXISTS (SELECT 1 FROM portal_requests WHERE requester = p_username) THEN
    RAISE EXCEPTION 'لا يمكن حذف مستخدم له طلبات مسجّلة (سلامة التدقيق) — عطّل حسابه بدلاً من الحذف';
  END IF;
  UPDATE portal_users       SET delegate_to  = NULL WHERE delegate_to  = p_username;
  UPDATE portal_users       SET manager_user = NULL WHERE manager_user = p_username;
  UPDATE portal_departments SET manager_user = NULL WHERE manager_user = p_username;
  DELETE FROM portal_users WHERE username = p_username;
  PERFORM portal_audit_write(NULL, 'user_deleted', v_me, 'portal',
    jsonb_build_object('deleted_user', p_username, 'role', v_role));
  RETURN jsonb_build_object('ok', true, 'deleted', p_username);
END $fn$;

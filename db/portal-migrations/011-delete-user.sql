-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 011 — حذف المستخدم بأمان (E) — portal_delete_user
--  RPC ذرّية بحمايات على مستوى القاعدة (دفاع في العمق فوق تحقّق الخادم):
--    • أدمن فقط (portal_is_admin).
--    • لا حذف للذات.
--    • لا حذف لآخر أدمن نشط (قفل استشاري لتفادي السباق).
--    • فك الارتباطات (delegate_to/manager_user/مدير القسم) قبل الحذف تفادياً لقيود FK.
--    • تدقيق append-only بحدث user_deleted (request_id = NULL مسموح).
--  idempotent. شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex بعد 005–010.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_delete_user(p_username text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_role text; v_active boolean; v_admins int;
BEGIN
  IF v_me IS NULL OR NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_username IS NULL OR p_username = v_me THEN RAISE EXCEPTION 'لا يمكنك حذف حسابك'; END IF;

  SELECT role, active INTO v_role, v_active FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;

  -- قفل استشاري على «آخر أدمن» ثم فحص العدد (يمنع سباق حذف أدمنين متزامنين).
  -- الحماية تخصّ حذف أدمن **نشط** فقط (حذف أدمن غير نشط لا يُنقص عدد النشطين).
  IF v_role = 'admin' AND v_active THEN
    PERFORM pg_advisory_xact_lock(hashtext('portal_last_admin'));
    SELECT count(*) INTO v_admins FROM portal_users WHERE role = 'admin' AND active;
    IF v_admins <= 1 THEN RAISE EXCEPTION 'لا يمكن حذف آخر أدمن نشط للبوابة'; END IF;
  END IF;

  -- فك الارتباطات كي لا تفشل قيود المفتاح الأجنبي.
  UPDATE portal_users       SET delegate_to  = NULL WHERE delegate_to  = p_username;
  UPDATE portal_users       SET manager_user = NULL WHERE manager_user = p_username;
  UPDATE portal_departments SET manager_user = NULL WHERE manager_user = p_username;

  DELETE FROM portal_users WHERE username = p_username;

  PERFORM portal_audit_write(NULL, 'user_deleted', v_me, 'portal',
    jsonb_build_object('deleted_user', p_username, 'role', v_role));
  RETURN jsonb_build_object('ok', true, 'deleted', p_username);
END $fn$;

REVOKE ALL ON FUNCTION portal_delete_user(text) FROM public;
GRANT EXECUTE ON FUNCTION portal_delete_user(text) TO authenticated;

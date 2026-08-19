-- p0_2f: keep the portal UI, account grants, and cancellation RPC consistent.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $grant_create$
DECLARE
  v_updated integer := 0;
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_users
     SET permissions = coalesce(permissions,'{}'::jsonb) || '{"can_create":true}'::jsonb
   WHERE active
     AND role <> 'admin'
     AND coalesce((permissions->>'can_create')::boolean,false) = false;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  PERFORM set_config('app.portal_transition','0',true);
  RAISE NOTICE 'p0_2f granted can_create to % active non-admin user(s)', v_updated;
END $grant_create$;

CREATE OR REPLACE FUNCTION portal_cancel_request(p_request_id text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_is_mgr boolean := false;
  v_pre_commit boolean := false;
  v_disbursed boolean := false;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status IN ('closed','cancelled') THEN RAISE EXCEPTION 'لا يمكن إلغاء طلب مغلق'; END IF;

  v_is_mgr := EXISTS (SELECT 1 FROM portal_departments d
                        WHERE d.id = v_req.department_id AND d.manager_user = v_me)
           OR EXISTS (SELECT 1 FROM portal_departments d
                        JOIN portal_departments d2 ON d2.sector = d.sector AND d2.sector IS NOT NULL
                        WHERE d.id = v_req.department_id AND d2.manager_user = v_me);

  v_disbursed := EXISTS (SELECT 1 FROM portal_payments p
                           WHERE p.request_id = v_req.id AND p.status = 'disbursed');
  IF v_req.req_type = 'direct_expense' THEN
    v_pre_commit := (v_req.status IN ('draft','in_review','returned','payment_pending') AND NOT v_disbursed);
  ELSE
    v_pre_commit := (v_req.status IN ('draft','in_review','returned','approved','pricing','award_review'));
  END IF;

  IF NOT (
        portal_is_admin()
        OR portal_has_perm('can_manage_procurement')
        OR portal_has_perm('can_approve_award')
        OR portal_has_perm('can_issue_po')
        OR (v_req.requester = v_me AND (
              v_req.status IN ('draft','in_review','returned')
              OR (v_req.req_type = 'direct_expense' AND v_req.status = 'payment_pending' AND NOT v_disbursed)
           ))
        OR (v_is_mgr AND v_pre_commit)
     ) THEN
    RAISE EXCEPTION 'غير مصرّح بإلغاء هذا الطلب في حالته الحالية';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests
     SET status = 'cancelled', cancelled_by = v_me, cancelled_at = now(),
         cancel_reason = p_reason, updated_at = now()
   WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'cancelled', v_me, 'portal',
    jsonb_build_object('reason', p_reason,
      'by_role', CASE WHEN portal_is_admin() OR portal_has_perm('can_manage_procurement')
                        OR portal_has_perm('can_approve_award') OR portal_has_perm('can_issue_po') THEN 'staff'
                      WHEN v_req.requester = v_me THEN 'requester'
                      WHEN v_is_mgr THEN 'manager' ELSE 'actor' END));
  RETURN jsonb_build_object('ok', true, 'status', 'cancelled');
END $fn$;

REVOKE ALL ON FUNCTION portal_cancel_request(text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_cancel_request(text,text) TO authenticated, service_role;

COMMIT;

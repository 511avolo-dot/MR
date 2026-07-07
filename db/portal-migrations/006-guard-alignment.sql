-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 006 — مواءمة حارس الإلغاء مع المواصفات (الباب 7 + سيناريو 6-5)
--  المواصفات: «بصلاحية المشتريات/الأدمن في أي وقت، أو مقدّم الطلب قبل بدء التزويد».
--  كان الخادم يقصر الإلغاء على المُقدّم/الأدمن فقط، فتظهر أزرار الواجهة للمشتريات
--  ثم يرفضها الخادم. هنا نوسّعه ليشمل صلاحيات المشتريات — مع إبقاء منع إلغاء
--  المغلق/الملغى وقيد «المُقدّم قبل التعميد». idempotent.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_cancel_request(p_request_id text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status IN ('closed','cancelled') THEN RAISE EXCEPTION 'لا يمكن إلغاء طلب مُغلق'; END IF;

  -- من يُلغي: الأدمن/المشتريات (أي وقت) — أو المُقدّم قبل بدء التعميد فقط.
  IF NOT (
        portal_is_admin()
        OR portal_has_perm('can_manage_procurement')
        OR portal_has_perm('can_approve_award')
        OR portal_has_perm('can_issue_po')
        OR (v_req.requester = v_me AND v_req.status IN ('draft','in_review','returned'))
     ) THEN
    RAISE EXCEPTION 'غير مصرّح بإلغاء هذا الطلب في حالته الحالية';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET status = 'cancelled', cancelled_by = v_me, cancelled_at = now(), cancel_reason = p_reason, updated_at = now()
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'cancelled', v_me, 'portal', jsonb_build_object('reason', p_reason));
  RETURN jsonb_build_object('ok', true, 'status', 'cancelled');
END $fn$;

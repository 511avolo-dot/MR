-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 005 — إعادة تقديم الطلب المُعاد (returned → in_review)
--  تُصلح المانع B2: كانت الواجهة تنادي portal_submit_request التي ترفض غير
--  المسودّة، فيموت الطلب المُعاد. هذه RPC ذرّية تُعيد بناء سلسلة الاعتماد من
--  البداية وتُعيد الحالة in_review — بحمايات (returned فقط، مُقدّم الطلب/أدمن).
--  idempotent (CREATE OR REPLACE). شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_resubmit_request(p_request_id text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_first int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'returned' THEN RAISE EXCEPTION 'يمكن إعادة تقديم الطلبات المُعادة فقط'; END IF;
  IF v_req.requester <> v_me AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'إعادة التقديم تقتصر على مُقدّم الطلب';
  END IF;

  PERFORM set_config('app.portal_transition','1',true);
  -- إعادة بناء نفس سلسلة الحاجة من البداية (كل المراحل pending) — لا إدراج سلسلة جديدة
  UPDATE portal_approvals
     SET decision='pending', approver=NULL, comment=NULL, acted_at=NULL, channel='portal'
   WHERE request_id = p_request_id;
  SELECT min(seq) INTO v_first FROM portal_approvals WHERE request_id = p_request_id;
  UPDATE portal_requests
     SET status='in_review', phase='requisition', current_seq = coalesce(v_first,1),
         updated_at=now(), updated_by=v_me
   WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition','0',true);

  PERFORM portal_audit_write(p_request_id,'resubmitted',v_me,'portal',jsonb_build_object('comment',p_comment));
  RETURN jsonb_build_object('ok',true,'status','in_review');
END $fn$;

REVOKE ALL ON FUNCTION portal_resubmit_request(text,text) FROM public;
GRANT EXECUTE ON FUNCTION portal_resubmit_request(text,text) TO authenticated;

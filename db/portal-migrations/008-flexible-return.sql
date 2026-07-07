-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 008 — الإرجاع المرن (اختيار مَن يعود له الطلب) — الدورة الأولى
--  المواصفات (توجيه المالك): «الرفض أو الموافقة أو الإعادة، واختيار الشخص أو
--  القسم الذي يعود له الطلب، والذي عاد إليه الطلب يمكنه أن يعيده أيضاً لمن سبقه
--  في أي إجراء في المعاملة.»
--
--  قبل هذه الهجرة كان الإرجاع يعيد الطلب إلى مقدّمه فقط (status='returned').
--  الآن يقبل portal_pr_transition معاملاً جديداً p_return_to_seq:
--    • 0  → إرجاع إلى مقدّم الطلب (السلوك القديم — يعيد التقديم عبر resubmit).
--    • >0 → إعادة فتح مرحلة اعتماد سابقة بعينها: تُصفَّر تلك المرحلة وكل ما بعدها
--          إلى pending، ويعود الطلب إلى in_review على تلك المرحلة. المعتمِد الذي
--          عاد إليه الطلب يستطيع بدوره إرجاعه لمن سبقه (نفس الآلية تعمل تراكمياً).
--
--  التوقيع الجديد 5 معاملات — نسقط القديم (4) ونعيد الإنشاء. نداءات الواجهة
--  بالمعاملات المُسمّاة تبقى تعمل (p_return_to_seq افتراضيّه 0). idempotent.
--  شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex بعد 005/006/007.
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS portal_pr_transition(text, text, text, date);
CREATE OR REPLACE FUNCTION portal_pr_transition(p_request_id text, p_action text,
    p_comment text DEFAULT NULL, p_hold_until date DEFAULT NULL, p_return_to_seq int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_approvals%ROWTYPE;
  v_target portal_approvals%ROWTYPE;
  v_pending int; v_next_seq int; v_decision text; v_status text; v_phase text;
  v_ok boolean := false; v_intended text; v_perm boolean;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','defer') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'in_review' THEN RAISE EXCEPTION 'الطلب ليس قيد المراجعة'; END IF;

  SELECT * INTO v_stage FROM portal_approvals
    WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة معلّقة'; END IF;

  IF portal_setting_bool('sod_requester_cannot_approve', true)
     AND v_req.requester = v_me AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)';
  END IF;
  -- فصل المهام متعدّد المراحل: من اعتمد مرحلة سابقة لا يعتمد مرحلة لاحقة لنفس الطلب
  IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = p_request_id
              AND approver = v_me AND decision = 'approved' AND seq < v_stage.seq)
     AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'اعتمدت مرحلة سابقة لهذا الطلب — لا يجوز اعتماد أكثر من مرحلة (فصل المهام)';
  END IF;

  v_intended := portal_resolve_stage(p_request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    v_ok := (portal_qualified_approver(v_intended, v_req.requester) = v_me);
  ELSIF v_stage.role_key IS NOT NULL THEN
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm
      FROM portal_users WHERE username = v_me;
    v_ok := coalesce(v_perm, false);
  END IF;
  IF NOT v_ok AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action IN ('reject','return','defer') AND coalesce(trim(p_comment),'') = '' THEN
    RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع/التأجيل';
  END IF;

  -- التأجيل المالي (سيناريو 6-4): من بوابة التحقق المالي فقط (أو الأدمن).
  IF p_action = 'defer' THEN
    IF v_stage.role_key IS DISTINCT FROM 'can_approve_finance' AND NOT portal_is_admin() THEN
      RAISE EXCEPTION 'التأجيل المالي متاح في مرحلة التحقق المالي فقط';
    END IF;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_requests SET status = 'on_hold', hold_reason = p_comment, hold_until = p_hold_until,
           held_by = v_me, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'deferred', v_me, 'portal',
      jsonb_build_object('reason', p_comment, 'until', p_hold_until));
    RETURN jsonb_build_object('ok', true, 'action', 'defer', 'status', 'on_hold');
  END IF;

  -- ═══ الإرجاع المرن إلى مرحلة سابقة (p_return_to_seq > 0) ═══
  IF p_action = 'return' AND coalesce(p_return_to_seq, 0) > 0 THEN
    -- يجب أن تكون المرحلة الهدف سابقة للمرحلة الحالية (لا يُعاد للأمام ولا لنفسها).
    IF p_return_to_seq >= v_stage.seq THEN
      RAISE EXCEPTION 'الإرجاع يكون لمرحلة سابقة فقط';
    END IF;
    SELECT * INTO v_target FROM portal_approvals
      WHERE request_id = p_request_id AND seq = p_return_to_seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'المرحلة الهدف غير موجودة'; END IF;

    PERFORM set_config('app.portal_transition', '1', true);
    -- سجّل قرار المرحلة الحالية كـ«معاد» مع سبب ووجهة، ثم أعد فتح الهدف وكل ما بعده.
    UPDATE portal_approvals SET decision = 'returned', approver = v_me, comment = p_comment,
           acted_at = now(), channel = 'portal'
      WHERE request_id = p_request_id AND seq = v_stage.seq;
    UPDATE portal_approvals SET decision = 'pending', approver = NULL, comment = NULL,
           acted_at = NULL, channel = 'portal'
      WHERE request_id = p_request_id AND seq >= p_return_to_seq AND seq <> v_stage.seq;
    -- المرحلة الحالية نفسها تُعاد إلى pending أيضاً (كي تُعتمد مجدداً عند الرجوع للأمام)،
    -- لكن بعد أن سجّلنا حدث الإرجاع عليها؛ نعيد ضبطها الآن.
    UPDATE portal_approvals SET decision = 'pending', approver = NULL, comment = NULL,
           acted_at = NULL, channel = 'portal'
      WHERE request_id = p_request_id AND seq = v_stage.seq;
    UPDATE portal_requests SET status = 'in_review', phase = 'requisition',
           current_seq = p_return_to_seq, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
    PERFORM set_config('app.portal_transition', '0', true);

    PERFORM portal_audit_write(p_request_id, 'stage_returned', v_me, 'portal',
      jsonb_build_object('from_seq', v_stage.seq, 'to_seq', p_return_to_seq,
                         'to_stage', v_target.stage_label, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', 'return', 'decision', 'returned',
      'status', 'in_review', 'finalized', false, 'seq', v_stage.seq, 'return_to_seq', p_return_to_seq);
  END IF;

  -- ═══ الاعتماد / الرفض / الإرجاع إلى المقدّم (return_to_seq=0) ═══
  v_decision := CASE p_action WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' ELSE 'returned' END;

  SELECT count(*) INTO v_pending FROM portal_approvals WHERE request_id = p_request_id AND decision = 'pending';

  IF p_action = 'approve' THEN
    IF v_pending <= 1 THEN
      v_status := 'pricing'; v_phase := 'pricing'; v_next_seq := v_stage.seq;
    ELSE
      SELECT min(seq) INTO v_next_seq FROM portal_approvals WHERE request_id = p_request_id AND decision = 'pending' AND seq > v_stage.seq;
      v_status := 'in_review'; v_phase := 'requisition';
    END IF;
  ELSIF p_action = 'reject' THEN
    v_status := 'rejected'; v_phase := 'requisition'; v_next_seq := 0;
  ELSE
    v_status := 'returned'; v_phase := 'requisition'; v_next_seq := 0;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);

  UPDATE portal_approvals SET decision = v_decision, approver = v_me, comment = p_comment, acted_at = now(), channel = 'portal'
    WHERE request_id = p_request_id AND seq = v_stage.seq;

  UPDATE portal_requests SET status = v_status, current_seq = coalesce(v_next_seq,0), phase = v_phase, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'stage_' || v_decision, v_me, 'portal', jsonb_build_object('stage', v_stage.stage_label, 'comment', p_comment));

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
                             'finalized', v_status <> 'in_review', 'seq', v_stage.seq);
END $fn$;

REVOKE ALL ON FUNCTION portal_pr_transition(text, text, text, date, int) FROM public;
GRANT EXECUTE ON FUNCTION portal_pr_transition(text, text, text, date, int) TO authenticated;


-- ═══ الإرجاع في دورة الصرف: إجراء «return» غير نهائي مع توجيه (M1) ═══
-- كانت الواجهة تُظهر «إلى مَن يعود؟» لكن الخادم يعامل الإرجاع كرفض. الآن نُضيف
-- إجراء return مستقلاً: الطلب يعود إلى awarded (يُعيد المشتريات إصدار الصرف) والوجهة
-- تُحفظ في التدقيق. التوقيع يكتسب p_return_to (نص اختياري). idempotent.
DROP FUNCTION IF EXISTS portal_payment_transition(bigint, text, text);
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text, p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;
    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now() WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal', jsonb_build_object('payment_id', p_payment_id));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;

REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text) TO authenticated;

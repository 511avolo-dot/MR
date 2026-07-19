-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 044 — تفعيل «إعادة فتح التعميد» من طور الصرف (تصحيح العروض/الأسعار) — بعد 043
--  المشروع: mwbjoysuybgbrvfrprex (البوابة، نظام 3). idempotent — مدمجة في standalone.
--
--  الثغرة (من ملاحظة المالك، مؤكَّدة بالكود): نافذة إرجاع الصرف تعرض خيار «إعادة فتح
--  التعميد» وتمرّر p_return_to='award'، لكن `portal_payment_transition` كانت **تتجاهله
--  تماماً** (تُسجّله في التدقيق فقط وتعيد الطلب دائماً إلى awarded = إعادة إصدار الصرف).
--  فالمحاسب/المالية إذا اكتشف خطأً في سعر بند/عرض/اختيار المورد قبل تنفيذ الصرف، لم يكن
--  يملك أي سبيل لإعادته للمشتريات لتصحيح التسعير — فقط إعادة إصدار نفس الصرف الخاطئ.
--
--  الحلّ (قرار المالك — مرن، العروض تبقى): عند p_return_to='award' يعود الطلب إلى
--  `pricing` (يحاكي «رفض التعميد» القائم لكن من طور الصرف): يُبطِل كل صرف غير منفَّذ +
--  التعميد + سلسلتَي اعتماد التعميد وأمر الشراء، **مع إبقاء العروض** كي تُصحّح المشتريات
--  سعر بند، أو تُرسي مورداً آخر، أو تُضيف عرضاً بديلاً (المورد اعتذر) — ثم إعادة اعتماد
--  كاملة (تعميد→أمر شراء→صرف جديد). حارس: يُمنَع إن وُجد أي صرف منفَّذ فعلاً (المال خرج).
--  متوافق مع قرار «منع الإرجاع الجذري للمقدّم بعد التعميد» (هذا إرجاع للمشتريات لا للمقدّم).
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text,
    p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
  v_req_status text; v_req_phase text; v_req_inst boolean; v_split boolean; v_multi boolean;
  v_pending int; v_vat numeric; v_agg_max numeric; v_disb_sum numeric; v_merge jsonb := coalesce(p_details, '{}'::jsonb);
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  SELECT status, phase, pay_installments INTO v_req_status, v_req_phase, v_req_inst FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = v_pay.request_id);
  v_multi := v_split OR (coalesce(v_req_inst,false) AND NOT v_split);
  IF v_multi THEN
    IF v_req_phase <> 'payment' THEN RAISE EXCEPTION 'حالة الطلب لا تسمح بعملية الصرف'; END IF;
  ELSE
    IF v_req_status IS DISTINCT FROM 'payment_pending' THEN
      RAISE EXCEPTION 'حالة الطلب (%) لا تسمح بعملية الصرف', coalesce(v_req_status,'?');
    END IF;
  END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment,
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;

    -- ═══ (044) إعادة فتح التعميد للتسعير: خلل في العروض/الأسعار قبل تنفيذ الصرف ═══
    IF p_action = 'return' AND p_return_to = 'award' THEN
      IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = v_pay.request_id AND status = 'disbursed') THEN
        RAISE EXCEPTION 'تعذّر إعادة فتح التعميد — يوجد صرف منفَّذ بالفعل (المال خرج)';
      END IF;
      PERFORM set_config('app.portal_transition', '1', true);
      -- إبطال كل صرف غير منفَّذ لهذا الطلب (مفرد/مجزّأ/دفعات)
      UPDATE portal_payments SET status = 'returned', comment = p_comment
        WHERE request_id = v_pay.request_id AND status IN ('pending_pay','approved_pay');
      -- إبطال التعميد + سلسلتَي الاعتماد (العروض تبقى للتصحيح/إعادة الاختيار)
      UPDATE portal_award SET status = 'rejected' WHERE request_id = v_pay.request_id;
      DELETE FROM portal_award_lines WHERE request_id = v_pay.request_id;
      DELETE FROM portal_award_approvals WHERE request_id = v_pay.request_id;
      DELETE FROM portal_po_approvals WHERE request_id = v_pay.request_id;
      UPDATE portal_requests SET status = 'pricing', phase = 'pricing', po_issued_by = NULL, po_issued_at = NULL,
             updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      PERFORM set_config('app.portal_transition', '0', true);
      PERFORM portal_audit_write(v_pay.request_id, 'award_reopened', v_me, 'portal',
        jsonb_build_object('from', 'payment', 'reason', p_comment, 'payment_id', p_payment_id));
      RETURN jsonb_build_object('ok', true, 'action', 'reopen', 'status', 'pricing');
    END IF;

    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    IF NOT v_multi THEN
      UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment, 'multi', v_multi));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ طلبته بنفسك (فصل المهام الثلاثي)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now(),
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    IF v_split THEN
      SELECT count(*) INTO v_pending FROM (
        SELECT DISTINCT al.offer_id FROM portal_award_lines al WHERE al.request_id = v_pay.request_id
          AND NOT EXISTS (SELECT 1 FROM portal_payments p WHERE p.request_id = al.request_id
                          AND p.award_offer_id = al.offer_id AND p.status = 'disbursed')
      ) q;
      IF v_pending = 0 THEN
        UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      END IF;
    ELSIF coalesce(v_req_inst,false) THEN
      v_vat := portal_setting_num('vat', 15);
      SELECT round(coalesce(winner_total,0) * (1 + v_vat/100.0)) INTO v_agg_max FROM portal_award WHERE request_id = v_pay.request_id AND status = 'approved';
      SELECT coalesce(sum(amount),0) INTO v_disb_sum FROM portal_payments WHERE request_id = v_pay.request_id AND status = 'disbursed';
      IF v_disb_sum >= v_agg_max THEN
        UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      END IF;
    ELSE
      UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
    jsonb_build_object('payment_id', p_payment_id, 'has_proof', (v_merge ? 'proof_key'), 'multi', v_multi));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) TO authenticated;

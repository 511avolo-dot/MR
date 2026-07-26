-- ═══════════════════════════════════════════════════════════════════════════
--  051 — حوكمة مالية متقدّمة (المرحلة 2-أ): exactly-once + إبطال saga
--  ─────────────────────────────────────────────────────────────────────────
--  معياران من أقوى الأنظمة العالمية لحركة المال، مطبَّقان داخل القاعدة:
--
--   (أ) **Idempotency (exactly-once):** تنفيذ الصرف حسّاس؛ إعادة محاولة الشبكة أو
--       نقرة مزدوجة قد تُكرّر الأثر. مفتاح idempotency **حتميّ لكل دفعة+فعل** يضمن
--       أنّ أي إعادة تُرجِع نتيجة أوّل تنفيذ ولا تُكرّره. مخزَّن معامَلاتياً مع أثر
--       الحالة نفسه (نفس المعاملة) فالضمان صحيح حتى تحت التزامن.
--
--   (ب) **إبطال saga (تعويض):** المال لا يُعكَس صمتاً. إبطال صرف منفَّذ مسار محكوم:
--       صلاحية مالية + فصل مهام (المنفّذ لا يُبطِل تنفيذه) + سبب إلزامي + قيد عكسي
--       في التدقيق الثابت + انتقال حالة مضبوط. لا يُبطَل صرفٌ استُلمت بضاعته (يُستخدم
--       مرتجع بدلاً منه).
--
--  عدم الانحدار مضمون: `p_idem_key` اختياري (NULL = السلوك الحالي حرفياً).
--  ⚠️ تُطبَّق حيّاً بعد 050. مدمجة في db/portal-standalone.sql.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (1) جدول مفاتيح idempotency (خادميّ بحت: RLS مفعّلة بلا سياسة) ──────────
CREATE TABLE IF NOT EXISTS portal_idempotency (
  key        TEXT PRIMARY KEY,
  op         TEXT NOT NULL,               -- مثل 'payment_transition:disburse'
  ref        BIGINT,                       -- المرجع (payment_id) للتحقّق من عدم إعادة استخدام المفتاح لعملية أخرى
  result     JSONB NOT NULL,               -- نتيجة أوّل تنفيذ (تُعاد حرفياً عند التكرار)
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE portal_idempotency ENABLE ROW LEVEL SECURITY;  -- لا سياسة = لا وصول من العميل

-- ── (2) أعمدة الإبطال على portal_payments ──────────────────────────────────
ALTER TABLE portal_payments ADD COLUMN IF NOT EXISTS voided_by   TEXT;
ALTER TABLE portal_payments ADD COLUMN IF NOT EXISTS voided_at   TIMESTAMPTZ;
ALTER TABLE portal_payments ADD COLUMN IF NOT EXISTS void_reason TEXT;

-- ── (3) portal_payment_transition + مفتاح idempotency اختياري ──────────────
--   يُعاد تعريفها بالكامل (نسخة 050) مع معامل سادس p_idem_key:
--   • عند وجوده: يُتحقَّق أولاً من جدول idempotency — تطابق ⇒ تُعاد النتيجة المخزَّنة
--     بلا إعادة تنفيذ؛ تعارض (مفتاح لعملية أخرى) ⇒ خطأ. وعند النجاح تُخزَّن النتيجة.
DROP FUNCTION IF EXISTS portal_payment_transition(bigint, text, text, text, jsonb);
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text,
    p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL, p_details jsonb DEFAULT NULL,
    p_idem_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
  v_req_status text; v_req_phase text; v_req_inst boolean; v_req_type text; v_split boolean; v_multi boolean;
  v_pending int; v_vat numeric; v_agg_max numeric; v_disb_sum numeric; v_merge jsonb := coalesce(p_details, '{}'::jsonb);
  v_has_chain boolean; v_is_direct boolean; v_idem portal_idempotency%ROWTYPE; v_op text; v_res jsonb;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  -- idempotency: إعادة محاولة نفس العملية تُرجِع النتيجة المخزَّنة (exactly-once)
  v_op := 'payment_transition:' || p_action;
  IF p_idem_key IS NOT NULL THEN
    SELECT * INTO v_idem FROM portal_idempotency WHERE key = p_idem_key;
    IF FOUND THEN
      IF v_idem.op <> v_op OR v_idem.ref IS DISTINCT FROM p_payment_id THEN
        RAISE EXCEPTION 'مفتاح idempotency مستخدم لعملية أخرى';
      END IF;
      RETURN v_idem.result;   -- لا إعادة تنفيذ
    END IF;
  END IF;

  SELECT status, phase, pay_installments, req_type INTO v_req_status, v_req_phase, v_req_inst, v_req_type
    FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = v_pay.request_id);
  v_multi := v_split OR (coalesce(v_req_inst,false) AND NOT v_split);
  v_is_direct := (v_req_type = 'direct_expense');
  v_has_chain := EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = v_pay.request_id AND cycle = 'disbursement');

  IF v_multi THEN
    IF v_req_phase <> 'payment' THEN RAISE EXCEPTION 'حالة الطلب لا تسمح بعملية الصرف'; END IF;
  ELSE
    IF v_req_status IS DISTINCT FROM 'payment_pending' THEN
      RAISE EXCEPTION 'حالة الطلب (%) لا تسمح بعملية الصرف', coalesce(v_req_status,'?');
    END IF;
  END IF;

  IF p_action = 'approve' THEN
    IF v_has_chain THEN RAISE EXCEPTION 'الصرف مُعتمَد عبر سلسلة الموافقات المالية — نفّذ الصرف مباشرةً'; END IF;
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment,
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status NOT IN ('pending_pay','approved_pay') THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;

    IF p_action = 'return' AND p_return_to = 'award' AND NOT v_is_direct THEN
      IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = v_pay.request_id AND status = 'disbursed') THEN
        RAISE EXCEPTION 'تعذّر إعادة فتح التعميد — يوجد صرف منفَّذ بالفعل (المال خرج)';
      END IF;
      PERFORM set_config('app.portal_transition', '1', true);
      UPDATE portal_payments SET status = 'returned', comment = p_comment
        WHERE request_id = v_pay.request_id AND status IN ('pending_pay','approved_pay');
      UPDATE portal_award SET status = 'rejected' WHERE request_id = v_pay.request_id;
      DELETE FROM portal_award_lines WHERE request_id = v_pay.request_id;
      DELETE FROM portal_award_approvals WHERE request_id = v_pay.request_id;
      DELETE FROM portal_po_approvals WHERE request_id = v_pay.request_id;
      DELETE FROM portal_approvals WHERE request_id = v_pay.request_id AND cycle = 'disbursement';
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
      UPDATE portal_requests SET status = CASE WHEN v_is_direct THEN 'returned' ELSE 'awarded' END,
             updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
    v_res := jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment, 'multi', v_multi));
    IF p_idem_key IS NOT NULL THEN INSERT INTO portal_idempotency(key,op,ref,result) VALUES (p_idem_key,v_op,p_payment_id,v_res) ON CONFLICT (key) DO NOTHING; END IF;
    RETURN v_res;
  ELSE -- disburse
    IF v_has_chain THEN
      IF v_pay.status NOT IN ('pending_pay','approved_pay') THEN RAISE EXCEPTION 'حالة الصرف غير مطابقة'; END IF;
      IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = v_pay.request_id AND cycle = 'disbursement'
                  AND approver = v_me) AND NOT portal_is_admin() THEN
        RAISE EXCEPTION 'من اعتمد الصرف في السلسلة لا ينفّذه (فصل المهام)';
      END IF;
    ELSE
      IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
      IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ طلبته بنفسك (فصل المهام الثلاثي)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now(),
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    IF v_split THEN
      SELECT count(*) INTO v_pending FROM (
        SELECT DISTINCT al.offer_id FROM portal_award_lines al WHERE al.request_id = v_pay.request_id
          AND NOT EXISTS (SELECT 1 FROM portal_payments p WHERE p.request_id = al.request_id
                          AND p.award_offer_id = al.offer_id AND p.status = 'disbursed')) q;
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
    ELSIF v_is_direct THEN
      UPDATE portal_requests SET status = 'closed', phase = 'closed', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    ELSE
      UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  v_res := jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
    jsonb_build_object('payment_id', p_payment_id, 'has_proof', (v_merge ? 'proof_key'), 'multi', v_multi, 'via_chain', v_has_chain));
  IF p_idem_key IS NOT NULL THEN INSERT INTO portal_idempotency(key,op,ref,result) VALUES (p_idem_key,v_op,p_payment_id,v_res) ON CONFLICT (key) DO NOTHING; END IF;
  RETURN v_res;
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_transition(bigint,text,text,text,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint,text,text,text,jsonb,text) TO authenticated;

-- ── (4) إبطال صرف منفَّذ (تعويض saga) ──────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_payment_void(p_payment_id bigint, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_req portal_requests%ROWTYPE; v_has_receipt boolean;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_approve_finance') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'إبطال الصرف يتطلّب صلاحية مالية';
  END IF;
  IF coalesce(trim(p_reason),'') = '' THEN RAISE EXCEPTION 'سبب الإبطال مطلوب'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الصرف غير موجود'; END IF;
  IF v_pay.status <> 'disbursed' THEN RAISE EXCEPTION 'لا يُبطَل إلا صرفٌ منفَّذ (الحالة: %)', v_pay.status; END IF;

  -- فصل المهام: منفّذ الصرف لا يُبطِل تنفيذه، ولا طالبه.
  IF NOT portal_is_admin() THEN
    IF v_pay.disbursed_by = v_me THEN RAISE EXCEPTION 'من نفّذ الصرف لا يُبطِله بنفسه (فصل المهام)'; END IF;
    IF v_pay.requested_by = v_me THEN RAISE EXCEPTION 'من طلب الصرف لا يُبطِله بنفسه (فصل المهام)'; END IF;
  END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  -- لا إبطال بعد استلام بضاعة (يُستخدم مرتجع) — يخصّ مسار الشراء.
  v_has_receipt := EXISTS (SELECT 1 FROM portal_receipts WHERE request_id = v_pay.request_id);
  IF v_has_receipt THEN RAISE EXCEPTION 'استُلمت بضاعة لهذا الطلب — استخدم مرتجعاً بدل إبطال الصرف'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_payments SET status = 'voided', voided_by = v_me, voided_at = now(), void_reason = p_reason WHERE id = p_payment_id;
  IF v_req.req_type = 'direct_expense' THEN
    -- الصرف المباشر: يُقفَل مُلغىً (تعويض مسجَّل، لا إعادة إصدار).
    UPDATE portal_requests SET status = 'cancelled', phase = 'closed', cancel_reason = p_reason,
           cancelled_by = v_me, cancelled_at = now(), updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
  ELSE
    -- مسار الشراء (بلا استلام): يعود لطور الدفع لإعادة الإصدار الصحيح.
    UPDATE portal_requests SET status = 'awarded', phase = 'payment', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  -- قيد عكسي في التدقيق الثابت (لا يُعدَّل حتى بمفتاح الخدمة)
  PERFORM portal_audit_write(v_pay.request_id, 'payment_voided', v_me, 'portal',
    jsonb_build_object('payment_id', p_payment_id, 'amount', v_pay.amount, 'reason', p_reason,
                       'reverses_disbursed_by', v_pay.disbursed_by, 'req_type', v_req.req_type));
  RETURN jsonb_build_object('ok', true, 'status', 'voided');
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_void(bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_payment_void(bigint,text) TO authenticated;

-- تحقّق:
--   SELECT has_function_privilege('anon','portal_payment_void(bigint,text)','EXECUTE'); ⇒ false
--   SELECT relrowsecurity FROM pg_class WHERE relname='portal_idempotency'; ⇒ t

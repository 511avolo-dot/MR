-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 025 — الصرف لكل مورد في الترسية المجزّأة (النموذج «أ» — قرار المالك)
--  المشروع: mwbjoysuybgbrvfrprex (البوابة، نظام 3)
--  الغرض: عند الترسية المجزّأة، دفعة صرف مستقلة لكل مورد فائز بآيبانه، بسقف نصيبه شاملاً
--         الضريبة، ومجموع الدفعات لا يتجاوز التعميد الإجمالي. الاستلام يبقى بالبنود.
--  الحوكمة: اعتماد التعميد وأمر الشراء يبقيان على القيمة الإجمالية (أقوى، يمنع التفتيت).
--  **يحافظ على الترسية المفردة حرفياً**: كل حماية 019 (سقف، صرف واحد، فصل مهام) سارية عند
--  عدم التجزئة. عند التجزئة: صرف واحد لكل مورد بدل صرف واحد للطلب. idempotent. شغّلها بعد 024.
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) عمود يربط الدفعة بالمورد الفائز (نصيبه). NULL = ترسية مفردة/قديمة.
ALTER TABLE portal_payments ADD COLUMN IF NOT EXISTS award_offer_id BIGINT REFERENCES portal_offers(id);

-- (2) طلب الصرف: واعٍ بالتجزئة. p_offer_id يحدّد المورد عند التجزئة.
DROP FUNCTION IF EXISTS portal_payment_request(text, text, numeric, text, jsonb);
CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric,
    p_custody_to text DEFAULT NULL, p_details jsonb DEFAULT NULL, p_offer_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
  v_iban text; v_details jsonb := coalesce(p_details, '{}'::jsonb);
  v_winner numeric; v_vat numeric; v_agg_max numeric; v_split boolean;
  v_slice numeric; v_slice_max numeric; v_paid_sum numeric;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'نوع صرف غير صالح'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'مبلغ غير صالح'; END IF;

  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
  ELSIF p_kind = 'custody' THEN
    IF coalesce(p_custody_to,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = p_custody_to AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)';
    END IF;
  ELSIF p_kind = 'credit' THEN
    IF (v_details->>'due_date') IS NULL OR (v_details->>'due_date')::date IS NULL THEN
      RAISE EXCEPTION 'تاريخ الاستحقاق مطلوب للصرف الآجل';
    END IF;
  END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;

  SELECT winner_total INTO v_winner FROM portal_award WHERE request_id = p_request_id AND status = 'approved';
  IF v_winner IS NULL OR v_winner <= 0 THEN RAISE EXCEPTION 'لا تعميد مُعتمَد لهذا الطلب'; END IF;
  v_vat := portal_setting_num('vat', 15);
  v_agg_max := round(v_winner * (1 + v_vat/100.0));
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = p_request_id);

  IF v_split THEN
    -- التجزئة: يجب أن يكون الطلب في طور الصرف (يبقى awarded حتى اكتمال كل الموردين).
    IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'الطلب ليس في طور الصرف'; END IF;
    IF p_offer_id IS NULL THEN RAISE EXCEPTION 'حدّد المورد (نصيبه) للصرف المجزّأ'; END IF;
    SELECT sum(line_total) INTO v_slice FROM portal_award_lines WHERE request_id = p_request_id AND offer_id = p_offer_id;
    IF v_slice IS NULL OR v_slice <= 0 THEN RAISE EXCEPTION 'المورد ليس ضمن الفائزين بالترسية'; END IF;
    v_slice_max := round(v_slice * (1 + v_vat/100.0));
    -- لا دفعة قائمة لنفس المورد.
    IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id AND award_offer_id = p_offer_id
               AND status IN ('pending_pay','approved_pay','disbursed')) THEN
      RAISE EXCEPTION 'يوجد صرف قائم لهذا المورد بالفعل';
    END IF;
    IF p_amount > v_slice_max THEN
      RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز نصيب المورد شاملاً الضريبة (%)', p_amount, v_slice_max;
    END IF;
    -- المجموع عبر كل الموردين لا يتجاوز التعميد الإجمالي شاملاً الضريبة.
    SELECT coalesce(sum(amount),0) INTO v_paid_sum FROM portal_payments WHERE request_id = p_request_id
      AND status IN ('pending_pay','approved_pay','disbursed');
    IF v_paid_sum + p_amount > v_agg_max THEN
      RAISE EXCEPTION 'مجموع الصرف (%) يتجاوز إجمالي التعميد شاملاً الضريبة (%)', v_paid_sum + p_amount, v_agg_max;
    END IF;

    PERFORM set_config('app.portal_transition', '1', true);
    INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details, award_offer_id)
      VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb), p_offer_id) RETURNING id INTO v_id;
    -- لا تغيير على حالة الطلب في التجزئة (يبقى awarded حتى اكتمال صرف كل الموردين).
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal',
      jsonb_build_object('kind', p_kind, 'amount', p_amount, 'split', true, 'offer_id', p_offer_id));
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'split', true);
  END IF;

  -- ── الترسية المفردة (سلوك 019 حرفياً) ──
  IF v_req.phase <> 'payment' OR v_req.status <> 'awarded' THEN RAISE EXCEPTION 'الطلب ليس جاهزاً للصرف'; END IF;
  IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id
             AND status IN ('pending_pay','approved_pay','disbursed')) THEN
    RAISE EXCEPTION 'يوجد طلب صرف قائم لهذا الطلب — لا يُسمح بأكثر من صرف واحد';
  END IF;
  IF p_amount > v_agg_max THEN
    RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز قيمة التعميد شاملة الضريبة (%)', p_amount, v_agg_max;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details)
    VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb)) RETURNING id INTO v_id;
  UPDATE portal_requests SET status = 'payment_pending', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);
  PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal', jsonb_build_object('kind', p_kind, 'amount', p_amount));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_request(text, text, numeric, text, jsonb, bigint) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_request(text, text, numeric, text, jsonb, bigint) TO authenticated;

-- (3) انتقال الصرف: واعٍ بالتجزئة — يتقدّم إلى الاستلام فقط بعد صرف كل الموردين.
DROP FUNCTION IF EXISTS portal_payment_transition(bigint, text, text, text, jsonb);
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text,
    p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
  v_req_status text; v_req_phase text; v_split boolean; v_pending int;
  v_merge jsonb := coalesce(p_details, '{}'::jsonb);
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  SELECT status, phase INTO v_req_status, v_req_phase FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = v_pay.request_id);
  -- إعادة فحص حالة الطلب الأب: مفرد=payment_pending، مجزّأ=طور الصرف (awarded محفوظ).
  IF v_split THEN
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
    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    -- المفرد: يعود الطلب awarded ليُعاد إصدار الصرف. المجزّأ: الطلب أصلاً awarded — يُعاد إصدار صرف المورد فقط.
    IF NOT v_split THEN
      UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment, 'split', v_split));
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
      -- يتقدّم للاستلام فقط إذا صُرف لكل مورد فائز.
      SELECT count(*) INTO v_pending FROM (
        SELECT DISTINCT al.offer_id FROM portal_award_lines al WHERE al.request_id = v_pay.request_id
          AND NOT EXISTS (SELECT 1 FROM portal_payments p WHERE p.request_id = al.request_id
                          AND p.award_offer_id = al.offer_id AND p.status = 'disbursed')
      ) q;
      IF v_pending = 0 THEN
        UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      END IF;
    ELSE
      UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
    jsonb_build_object('payment_id', p_payment_id, 'has_proof', (v_merge ? 'proof_key'), 'split', v_split));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) TO authenticated;

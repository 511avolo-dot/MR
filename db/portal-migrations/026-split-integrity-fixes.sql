-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 026 — سلامة الترسية المجزّأة (سدّ سيناريوهات حدّية اكتُشفت بالفحص)
--  المشروع: mwbjoysuybgbrvfrprex (البوابة، نظام 3). شغّلها بعد 025.
--  السيناريوهات المُصلَحة:
--   (1) [حرِج] ترسية مفردة بعد ترسية مجزّأة مرفوضة تُبقي portal_award_lines قديمة →
--       يُعامَل الطلب المفرد كأنه مجزّأ فيُصرف لموردين خاطئين. الحل: portal_award يمسح award_lines.
--   (2) رفض اعتماد التعميد المجزّأ يُبقي award_lines → علم isSplit عالق أثناء التسعير. الحل:
--       portal_award_transition يمسح award_lines عند الرفض.
--   (3) [متوسط] سقف مجموع الصرف المجزّأ كان round(الإجمالي×الضريبة) وقد يقلّ عن مجموع أسقف
--       الأنصبة بسبب التقريب، فتُرفَض دفعة المورد الأخير بفرق ريالات. الحل: السقف = مجموع أسقف الأنصبة.
--  idempotent (CREATE OR REPLACE، لا تغيير تواقيع).
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) portal_award (المفرد): يمسح أي ترسية مجزّأة سابقة كي يبقى المتغيّر «award_lines موجودة ⟺ الترسية النشطة مجزّأة».
CREATE OR REPLACE FUNCTION portal_award(p_request_id text, p_winner_offer_id bigint, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_offer portal_offers%ROWTYPE;
  v_doa portal_doa%ROWTYPE;
  v_lowest numeric; v_offer_count int;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  SELECT * INTO v_offer FROM portal_offers WHERE id = p_winner_offer_id AND request_id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'العرض غير موجود'; END IF;

  SELECT count(*) INTO v_offer_count FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer_count < coalesce(v_req.quotes_required, 1) THEN
    RAISE EXCEPTION 'عدد العروض المُدخَلة (%) أقل من المطلوب (%) — أضِف عروضاً أو استخدم نوع شراء استثنائياً بمبرّر',
      v_offer_count, v_req.quotes_required;
  END IF;

  SELECT min(total) INTO v_lowest FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer.total > v_lowest AND coalesce(trim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'اختيار عرض غير الأقل سعراً يتطلّب مبرّراً موثَّقاً';
  END IF;

  SELECT * INTO v_doa FROM portal_doa WHERE max_value IS NULL OR v_offer.total <= max_value ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'تعذّر تحديد مصفوفة الصلاحيات لهذه القيمة — أضِف قاعدة DoA'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_award_lines WHERE request_id = p_request_id;   -- (026) مسح أي ترسية مجزّأة سابقة
  INSERT INTO portal_award(request_id, winner_offer_id, winner_total, award_reason, doa_id, status, awarded_by)
    VALUES (p_request_id, p_winner_offer_id, v_offer.total, p_reason, v_doa.id, 'pending', v_me)
  ON CONFLICT (request_id) DO UPDATE SET winner_offer_id = EXCLUDED.winner_offer_id, winner_total = EXCLUDED.winner_total,
    award_reason = EXCLUDED.award_reason, doa_id = EXCLUDED.doa_id, status = 'pending', awarded_by = EXCLUDED.awarded_by;
  DELETE FROM portal_award_approvals WHERE request_id = p_request_id;
  INSERT INTO portal_award_approvals(request_id, seq, stage_label, role_key, approver)
    VALUES (p_request_id, 1, 'اعتماد التعميد', v_doa.award_role_key, NULL);
  UPDATE portal_requests SET status = 'award_review', phase = 'award', current_seq = 1, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'awarded', v_me, 'portal', jsonb_build_object('supplier', v_offer.supplier_name, 'total', v_offer.total));
  RETURN jsonb_build_object('ok', true, 'status', 'award_review');
END $fn$;

-- (2) portal_award_transition: عند رفض التعميد يمسح award_lines (لا تبقى ترسية مجزّأة عالقة).
CREATE OR REPLACE FUNCTION portal_award_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_award_approvals%ROWTYPE;
  v_perm boolean; v_decision text; v_status text; v_phase text; v_po_stages int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'award_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار اعتماد التعميد'; END IF;
  IF v_req.requester = v_me THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;
  IF EXISTS (SELECT 1 FROM portal_award WHERE request_id = p_request_id AND awarded_by = v_me)
     AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد تعميد رسّيته بنفسك (فصل المهام)';
  END IF;

  SELECT * INTO v_stage FROM portal_award_approvals
    WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة تعميد معلّقة'; END IF;

  SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm FROM portal_users WHERE username = v_me;
  IF NOT coalesce(v_perm,false) AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action = 'reject' AND coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض'; END IF;

  v_decision := CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END;

  PERFORM set_config('app.portal_transition', '1', true);

  UPDATE portal_award_approvals SET decision = v_decision, approver = v_me, comment = p_comment, acted_at = now()
    WHERE request_id = p_request_id AND seq = v_stage.seq;

  IF p_action = 'approve' THEN
    UPDATE portal_award SET status = 'approved' WHERE request_id = p_request_id;
    v_po_stages := portal_build_po_chain(p_request_id, (SELECT coalesce(winner_total,0) FROM portal_award WHERE request_id = p_request_id));
    IF v_po_stages = 0 THEN
      v_status := 'awarded'; v_phase := 'payment';
      UPDATE portal_requests SET status = v_status, phase = v_phase, po_issued_by = v_me, po_issued_at = now(), updated_at = now(), updated_by = v_me
        WHERE id = p_request_id;
    ELSE
      v_status := 'po_review'; v_phase := 'po_review';
      UPDATE portal_requests SET status = v_status, phase = v_phase, current_seq = 1, updated_at = now(), updated_by = v_me
        WHERE id = p_request_id;
    END IF;
  ELSE
    v_status := 'pricing'; v_phase := 'pricing';
    UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
    DELETE FROM portal_award_lines WHERE request_id = p_request_id;   -- (026) مسح الترسية المجزّأة المرفوضة
    UPDATE portal_requests SET status = v_status, phase = v_phase, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'award_' || v_decision, v_me, 'portal', jsonb_build_object('comment', p_comment));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;

-- (3) portal_payment_request: سقف مجموع الصرف المجزّأ = مجموع أسقف الأنصبة (يمنع رفض المورد الأخير بالتقريب).
CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric,
    p_custody_to text DEFAULT NULL, p_details jsonb DEFAULT NULL, p_offer_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
  v_iban text; v_details jsonb := coalesce(p_details, '{}'::jsonb);
  v_winner numeric; v_vat numeric; v_agg_max numeric; v_split boolean;
  v_slice numeric; v_slice_max numeric; v_paid_sum numeric; v_split_cap numeric;
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
    IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'الطلب ليس في طور الصرف'; END IF;
    IF p_offer_id IS NULL THEN RAISE EXCEPTION 'حدّد المورد (نصيبه) للصرف المجزّأ'; END IF;
    SELECT sum(line_total) INTO v_slice FROM portal_award_lines WHERE request_id = p_request_id AND offer_id = p_offer_id;
    IF v_slice IS NULL OR v_slice <= 0 THEN RAISE EXCEPTION 'المورد ليس ضمن الفائزين بالترسية'; END IF;
    v_slice_max := round(v_slice * (1 + v_vat/100.0));
    IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id AND award_offer_id = p_offer_id
               AND status IN ('pending_pay','approved_pay','disbursed')) THEN
      RAISE EXCEPTION 'يوجد صرف قائم لهذا المورد بالفعل';
    END IF;
    IF p_amount > v_slice_max THEN
      RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز نصيب المورد شاملاً الضريبة (%)', p_amount, v_slice_max;
    END IF;
    -- (026) السقف الكلّي = مجموع أسقف أنصبة كل الموردين (سليم مع التقريب)، لا round(الإجمالي×الضريبة).
    SELECT sum(round(s.slc * (1 + v_vat/100.0))) INTO v_split_cap FROM (
      SELECT sum(line_total) AS slc FROM portal_award_lines WHERE request_id = p_request_id GROUP BY offer_id) s;
    SELECT coalesce(sum(amount),0) INTO v_paid_sum FROM portal_payments WHERE request_id = p_request_id
      AND status IN ('pending_pay','approved_pay','disbursed');
    IF v_paid_sum + p_amount > coalesce(v_split_cap, v_agg_max) THEN
      RAISE EXCEPTION 'مجموع الصرف (%) يتجاوز إجمالي أنصبة الموردين شاملاً الضريبة (%)', v_paid_sum + p_amount, coalesce(v_split_cap, v_agg_max);
    END IF;

    PERFORM set_config('app.portal_transition', '1', true);
    INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details, award_offer_id)
      VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb), p_offer_id) RETURNING id INTO v_id;
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

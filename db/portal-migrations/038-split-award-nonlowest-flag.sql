-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 038 — أثر تدقيق «غير-الأقل» في الترسية المجزّأة (حوكمة، غير مانع)
--  المشروع: mwbjoysuybgbrvfrprex (البوابة، نظام 3). شغّلها بعد 037.
--
--  الفجوة (من فحص الجولة الثانية): portal_award (المفرد) يشترط مبرّراً موثّقاً عند
--  اختيار عرض غير الأقل سعراً، بينما portal_award_split كان يقبل توجيه أي بند لأي
--  مورد دون رصد أنّه ليس أرخص مُسعِّر لذلك البند — فلا أثر تدقيق يبرّر المحاباة.
--
--  الحل (غير مانع، لا يكسر تدفّق الواجهة التي تُمرّر p_reason=null):
--    داخل حلقة البنود، يُحسب أرخص سعر مُسعَّر لكل بند عبر كل عروض الطلب؛ فإن كان
--    السعر المُرسَّى أعلى منه يُعَدّ «غير-أقل». العدد يُسجَّل في التدقيق (non_lowest_items)
--    ويُعاد في الاستجابة — دون منع (كنمط علم التفتيت 020). التشديد لمنعٍ فعليّ يتطلّب
--    حقل مبرّر في واجهة التعميد المجزّأ (متابعة لاحقة) قبل تحويله إلى RAISE.
--
--  idempotent (CREATE OR REPLACE، لا تغيير توقيع) — مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_award_split(p_request_id text, p_lines jsonb, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_doa portal_doa%ROWTYPE;
  v_line jsonb; v_seq int; v_oid bigint; v_up numeric; v_qty numeric;
  v_agg numeric := 0; v_item_count int; v_covered int; v_offer_count int;
  v_dom_offer bigint; v_dom_val numeric := -1; v_sup text;
  v_suppliers int; v_min_up numeric; v_non_lowest int := 0;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  SELECT count(*) INTO v_item_count FROM portal_request_items WHERE request_id = p_request_id;
  IF v_item_count = 0 THEN RAISE EXCEPTION 'لا بنود للطلب — الترسية المجزّأة تتطلّب بنوداً'; END IF;
  SELECT count(DISTINCT (e->>'seq')::int) INTO v_covered FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e;
  IF v_covered <> v_item_count THEN
    RAISE EXCEPTION 'يجب تغطية كل بنود الطلب بالضبط (% بند، وُصِل %)', v_item_count, v_covered;
  END IF;

  SELECT count(*) INTO v_offer_count FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer_count < coalesce(v_req.quotes_required, 1) THEN
    RAISE EXCEPTION 'عدد العروض (%) أقل من المطلوب (%)', v_offer_count, v_req.quotes_required;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_award_lines WHERE request_id = p_request_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_seq := (v_line->>'seq')::int; v_oid := (v_line->>'offer_id')::bigint;
    IF NOT EXISTS (SELECT 1 FROM portal_offers WHERE id = v_oid AND request_id = p_request_id) THEN
      RAISE EXCEPTION 'عرض % لا يخصّ هذا الطلب', v_oid;
    END IF;
    SELECT qty INTO v_qty FROM portal_request_items WHERE request_id = p_request_id AND seq = v_seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'بند % غير موجود في الطلب', v_seq; END IF;
    SELECT unit_price INTO v_up FROM portal_offer_items WHERE offer_id = v_oid AND item_seq = v_seq;
    IF v_up IS NULL THEN RAISE EXCEPTION 'المورد لم يُسعّر البند % — لا يمكن ترسيته إليه', v_seq; END IF;
    -- (038) رصد غير-الأقل لكل بند (غير مانع — أثر تدقيق حوكمي).
    SELECT min(oi.unit_price) INTO v_min_up FROM portal_offer_items oi
      JOIN portal_offers o ON o.id = oi.offer_id
      WHERE o.request_id = p_request_id AND oi.item_seq = v_seq;
    IF v_min_up IS NOT NULL AND v_up > v_min_up THEN v_non_lowest := v_non_lowest + 1; END IF;
    SELECT supplier_name INTO v_sup FROM portal_offers WHERE id = v_oid;
    INSERT INTO portal_award_lines(request_id, item_seq, offer_id, supplier_name, qty, unit_price, line_total)
      VALUES (p_request_id, v_seq, v_oid, v_sup, v_qty, v_up, round(v_qty * v_up));
    v_agg := v_agg + round(v_qty * v_up);
  END LOOP;

  IF v_agg <= 0 THEN RAISE EXCEPTION 'إجمالي الترسية غير صالح'; END IF;

  SELECT offer_id INTO v_dom_offer FROM portal_award_lines WHERE request_id = p_request_id
    GROUP BY offer_id ORDER BY sum(line_total) DESC LIMIT 1;
  SELECT count(DISTINCT offer_id) INTO v_suppliers FROM portal_award_lines WHERE request_id = p_request_id;

  SELECT * INTO v_doa FROM portal_doa WHERE max_value IS NULL OR v_agg <= max_value
    ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'تعذّر تحديد شريحة الصلاحيات — أضِف قاعدة DoA'; END IF;

  INSERT INTO portal_award(request_id, winner_offer_id, winner_total, award_reason, doa_id, status, awarded_by)
    VALUES (p_request_id, v_dom_offer, v_agg, coalesce(p_reason,'ترسية مجزّأة'), v_doa.id, 'pending', v_me)
  ON CONFLICT (request_id) DO UPDATE SET winner_offer_id = EXCLUDED.winner_offer_id, winner_total = EXCLUDED.winner_total,
    award_reason = EXCLUDED.award_reason, doa_id = EXCLUDED.doa_id, status = 'pending', awarded_by = EXCLUDED.awarded_by;
  DELETE FROM portal_award_approvals WHERE request_id = p_request_id;
  INSERT INTO portal_award_approvals(request_id, seq, stage_label, role_key, approver)
    VALUES (p_request_id, 1, 'اعتماد التعميد (مجزّأ)', v_doa.award_role_key, NULL);
  UPDATE portal_requests SET status = 'award_review', phase = 'award', current_seq = 1, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'awarded', v_me, 'portal',
    jsonb_build_object('split', true, 'suppliers', v_suppliers, 'total', v_agg,
                       'non_lowest_items', v_non_lowest, 'reason', nullif(trim(coalesce(p_reason,'')),'')));
  RETURN jsonb_build_object('ok', true, 'status', 'award_review', 'split', true, 'suppliers', v_suppliers,
    'total', v_agg, 'non_lowest_items', v_non_lowest);
END $fn$;
GRANT EXECUTE ON FUNCTION portal_award_split(text, jsonb, text) TO authenticated;

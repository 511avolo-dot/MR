-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 039 — تحقّقات تكامل (من فحص الجولة الثانية) — شغّلها بعد 038
--  المشروع: mwbjoysuybgbrvfrprex (البوابة، نظام 3).
--
--  (R2-2) تسجيل المرتجع كان يقبل كمية المرتجع من العميل دون التأكّد أنّها ≤ المستلَم
--         فعلاً — ناقل لإشعار مدين مضخَّم (خصم زائد على المورد / تشويه صافي المستحق).
--         الآن: كل بند مرتجع يجب أن يكون من بنود الطلب، ومجموع مرتجعاته (شاملاً السابقة)
--         لا يتجاوز received_qty. إرجاع بضاعة غير مستلَمة (received_qty=0) مرفوض.
--
--  (L3)   تسجيل الفاتورة كان يقبل اسم مورد فارغاً، فيُتجاوَز كشف الفاتورة المكرّرة عبر
--         الطلبات (المبنيّ على المورد). الآن اسم المورد إلزامي.
--
--  idempotent (CREATE OR REPLACE، بلا تغيير تواقيع) — مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) تسجيل الفاتورة: اسم المورد إلزامي ────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_invoice_record(
    p_request_id text, p_invoice_no text, p_amount numeric,
    p_supplier_name text DEFAULT NULL, p_invoice_date date DEFAULT NULL,
    p_doc_key text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_no text := trim(coalesce(p_invoice_no,'')); v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بتسجيل الفاتورة';
  END IF;
  IF v_no = '' THEN RAISE EXCEPTION 'رقم الفاتورة مطلوب'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'مبلغ الفاتورة غير صالح'; END IF;
  IF coalesce(trim(p_supplier_name),'') = '' THEN RAISE EXCEPTION 'اسم المورد مطلوب (لكشف الفاتورة المكرّرة)'; END IF;
  IF p_supplier_name IS NOT NULL AND EXISTS (
      SELECT 1 FROM portal_supplier_invoices
      WHERE invoice_no = v_no AND lower(coalesce(supplier_name,'')) = lower(p_supplier_name)
        AND request_id <> p_request_id) THEN
    RAISE EXCEPTION 'فاتورة مكرّرة: رقم % من المورد % مسجَّل على طلب آخر', v_no, p_supplier_name;
  END IF;
  INSERT INTO portal_supplier_invoices(request_id, supplier_name, invoice_no, invoice_date, amount, doc_key, note, recorded_by)
    VALUES (p_request_id, p_supplier_name, v_no, p_invoice_date, p_amount, p_doc_key, p_note, v_me)
    RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'invoice_id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_invoice_record(text, text, numeric, text, date, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_invoice_record(text, text, numeric, text, date, text, text) TO authenticated;

-- ── (2) تسجيل المرتجع: كمية المرتجع ≤ المستلَم (شاملاً المرتجعات السابقة) ─────
CREATE OR REPLACE FUNCTION portal_return_record(
    p_request_id text, p_lines jsonb, p_reason text,
    p_supplier_name text DEFAULT NULL, p_doc_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_ln jsonb; v_amt numeric := 0; v_q numeric; v_p numeric;
        v_lines jsonb := '[]'::jsonb; v_seq int; v_no text; v_n int; v_id bigint; v_recv numeric; v_prior numeric;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_verify_stock')
                          OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بتسجيل مرتجع';
  END IF;
  IF coalesce(trim(p_reason),'') = '' THEN RAISE EXCEPTION 'سبب المرتجع مطلوب'; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'بنود المرتجع مطلوبة';
  END IF;
  FOR v_ln IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_seq := (v_ln->>'seq')::int;
    v_q := coalesce((v_ln->>'qty')::numeric, 0);
    v_p := coalesce((v_ln->>'unit_price')::numeric, 0);
    IF v_q <= 0 THEN RAISE EXCEPTION 'كمية مرتجع غير صالحة (يجب أن تكون موجبة)'; END IF;
    IF v_p < 0 THEN RAISE EXCEPTION 'سعر بند غير صالح'; END IF;
    -- (039) البند من بنود الطلب، ومجموع مرتجعاته (شاملاً السابقة) ≤ المستلَم فعلاً.
    SELECT coalesce(received_qty,0) INTO v_recv FROM portal_request_items
      WHERE request_id = p_request_id AND seq = v_seq;
    IF v_recv IS NULL THEN RAISE EXCEPTION 'بند المرتجع % ليس من بنود الطلب', v_seq; END IF;
    SELECT coalesce(sum((l->>'qty')::numeric),0) INTO v_prior
      FROM portal_returns pr, jsonb_array_elements(coalesce(pr.lines,'[]'::jsonb)) l
      WHERE pr.request_id = p_request_id AND (l->>'seq')::int = v_seq;
    IF v_q + v_prior > v_recv THEN
      RAISE EXCEPTION 'كمية المرتجع للبند % (%+سابقة %) تتجاوز المستلَم (%)', v_seq, v_q, v_prior, v_recv;
    END IF;
    v_amt := v_amt + (v_q * v_p);
    v_lines := v_lines || jsonb_build_object('seq', v_seq, 'qty', v_q, 'unit_price', v_p, 'line_total', v_q * v_p);
  END LOOP;
  SELECT count(*) INTO v_n FROM portal_returns WHERE request_id = p_request_id;
  v_no := 'DN-' || right(p_request_id, 4) || '-' || lpad((v_n + 1)::text, 2, '0');

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_returns(request_id, supplier_name, reason, lines, debit_amount, debit_note_no, doc_key, created_by)
    VALUES (p_request_id, p_supplier_name, p_reason, v_lines, v_amt, v_no, p_doc_key, v_me)
    RETURNING id INTO v_id;
  PERFORM set_config('app.portal_transition', '0', true);

  RETURN jsonb_build_object('ok', true, 'return_id', v_id, 'debit_note_no', v_no, 'debit_amount', round(v_amt, 2));
END $fn$;
REVOKE ALL ON FUNCTION portal_return_record(text, jsonb, text, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_return_record(text, jsonb, text, text, text) TO authenticated;

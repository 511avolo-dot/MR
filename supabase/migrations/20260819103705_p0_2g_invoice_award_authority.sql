-- p0_2g — Invoice supplier and amount are derived from the approved award.
-- Canonical source: db/portal-migrations/p0_2g-invoice-award-authority.sql

CREATE OR REPLACE FUNCTION public.portal_invoice_record(
    p_request_id text, p_invoice_no text, p_amount numeric,
    p_supplier_name text DEFAULT NULL, p_invoice_date date DEFAULT NULL,
    p_doc_key text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_me text := public.portal_username();
  v_no text := trim(coalesce(p_invoice_no,''));
  v_award public.portal_award%ROWTYPE;
  v_supplier text;
  v_award_amount numeric := 0;
  v_invoiced numeric := 0;
  v_vat_factor numeric := 1 + public.portal_setting_num('vat', 15) / 100.0;
  v_split boolean;
  v_supplier_count integer := 0;
  v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (public.portal_is_admin() OR public.portal_has_perm('can_see_finance')
                           OR public.portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بتسجيل الفاتورة';
  END IF;
  IF v_no = '' THEN RAISE EXCEPTION 'رقم الفاتورة مطلوب'; END IF;

  SELECT * INTO v_award
    FROM public.portal_award
   WHERE request_id = p_request_id AND status = 'approved'
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا يوجد تعميد معتمد لهذا الطلب'; END IF;

  v_split := EXISTS (
    SELECT 1 FROM public.portal_award_lines al WHERE al.request_id = p_request_id
  );

  IF v_split THEN
    SELECT count(DISTINCT lower(trim(coalesce(nullif(al.supplier_name,''), o.supplier_name))))
      INTO v_supplier_count
      FROM public.portal_award_lines al
      JOIN public.portal_offers o ON o.id = al.offer_id
     WHERE al.request_id = p_request_id;

    IF coalesce(trim(p_supplier_name),'') = '' AND v_supplier_count = 1 THEN
      SELECT max(trim(coalesce(nullif(al.supplier_name,''), o.supplier_name)))
        INTO v_supplier
        FROM public.portal_award_lines al
        JOIN public.portal_offers o ON o.id = al.offer_id
       WHERE al.request_id = p_request_id;
    ELSIF coalesce(trim(p_supplier_name),'') = '' THEN
      RAISE EXCEPTION 'اختر مورداً من التعميد المجزّأ';
    ELSE
      v_supplier := trim(p_supplier_name);
    END IF;

    SELECT max(trim(coalesce(nullif(al.supplier_name,''), o.supplier_name))),
           round(coalesce(sum(al.line_total),0) * v_vat_factor, 2)
      INTO v_supplier, v_award_amount
      FROM public.portal_award_lines al
      JOIN public.portal_offers o ON o.id = al.offer_id
     WHERE al.request_id = p_request_id
       AND lower(trim(coalesce(nullif(al.supplier_name,''), o.supplier_name))) = lower(v_supplier);
  ELSE
    SELECT trim(o.supplier_name), round(coalesce(v_award.winner_total,0) * v_vat_factor, 2)
      INTO v_supplier, v_award_amount
      FROM public.portal_offers o
     WHERE o.id = v_award.winner_offer_id AND o.request_id = p_request_id;
  END IF;

  IF coalesce(v_supplier,'') = '' OR v_award_amount <= 0 THEN
    RAISE EXCEPTION 'تعذّر اشتقاق المورد والمبلغ من التعميد المعتمد';
  END IF;

  SELECT coalesce(sum(i.amount),0) INTO v_invoiced
    FROM public.portal_supplier_invoices i
   WHERE i.request_id = p_request_id
     AND lower(trim(coalesce(i.supplier_name,''))) = lower(v_supplier);
  v_award_amount := round(v_award_amount - v_invoiced, 2);
  IF v_award_amount <= 0 THEN
    RAISE EXCEPTION 'لا توجد قيمة متبقية للفوترة للمورد %', v_supplier;
  END IF;

  IF EXISTS (
      SELECT 1 FROM public.portal_supplier_invoices i
       WHERE lower(trim(i.invoice_no)) = lower(v_no)
         AND lower(trim(coalesce(i.supplier_name,''))) = lower(v_supplier)) THEN
    RAISE EXCEPTION 'فاتورة مكرّرة: رقم % من المورد % مسجّل مسبقاً', v_no, v_supplier;
  END IF;

  INSERT INTO public.portal_supplier_invoices(
      request_id, supplier_name, invoice_no, invoice_date, amount, doc_key, note, recorded_by)
    VALUES (p_request_id, v_supplier, v_no, p_invoice_date, v_award_amount, p_doc_key, p_note, v_me)
    RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'invoice_id', v_id,
    'supplier_name', v_supplier,
    'amount', v_award_amount,
    'amount_source', 'approved_award'
  );
END
$fn$;

REVOKE ALL ON FUNCTION public.portal_invoice_record(text, text, numeric, text, date, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_invoice_record(text, text, numeric, text, date, text, text)
  TO authenticated;

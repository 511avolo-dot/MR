-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 021 — إرفاق عرض سعر PDF لكل عرض مورد (البوابة، نظام 3)
--  المشروع: mwbjoysuybgbrvfrprex  ·  الجدول المقفل: portal_offers
--  يُخزَّن مفتاح ملف R2 (quote_pdf_key) في صفّ العرض عبر RPC (يرفع علم الانتقال)،
--  ويُرفع الملف نفسه إلى Cloudflare R2 (حاوية QUOTES_BUCKET) عبر functions/api/portal-quote.js.
--  آمن للتكرار. شغّلها في Supabase (الجديد) بعد 020.
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) عمود مفتاح ملف العرض. ALTER لا يمسّه قفل الصفوف (portal_locked_guard يحرس الكتابة على الصفوف لا المخطّط).
ALTER TABLE portal_offers ADD COLUMN IF NOT EXISTS quote_pdf_key TEXT;

-- (2) توسيع portal_submit_offer بمعامل مفتاح الـPDF (يُحذف التوقيع القديم أولاً).
DROP FUNCTION IF EXISTS portal_submit_offer(text, text, numeric, int, int, int, text);

CREATE OR REPLACE FUNCTION portal_submit_offer(p_request_id text, p_supplier text, p_total numeric,
    p_delivery_days int DEFAULT NULL, p_quality int DEFAULT NULL, p_payment_days int DEFAULT NULL,
    p_note text DEFAULT NULL, p_quote_pdf_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_phase text; v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT phase INTO v_phase FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_phase IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;
  IF coalesce(p_supplier,'') = '' OR coalesce(p_total,0) <= 0 THEN RAISE EXCEPTION 'بيانات العرض غير مكتملة'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_offers(request_id, supplier_name, total, delivery_days, quality, payment_days, note, entered_by, quote_pdf_key)
    VALUES (p_request_id, p_supplier, p_total, p_delivery_days, p_quality, p_payment_days, p_note, v_me,
            nullif(trim(coalesce(p_quote_pdf_key,'')),''))
    RETURNING id INTO v_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'offer_added', v_me, 'portal',
    jsonb_build_object('supplier', p_supplier, 'total', p_total, 'has_pdf', (nullif(trim(coalesce(p_quote_pdf_key,'')),'') IS NOT NULL)));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

GRANT EXECUTE ON FUNCTION portal_submit_offer(text, text, numeric, int, int, int, text, text) TO authenticated;

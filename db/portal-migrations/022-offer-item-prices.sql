-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 022 — أسعار البنود لكل مورد (المرحلة أ من المقارنة/الترسية بالبنود)
--  المشروع: mwbjoysuybgbrvfrprex (البوابة، نظام 3)
--  المشكلة: portal_offers يخزّن الإجمالي فقط. المطلوب: سعر وحدة كل بند لكل مورد
--  ليتسنّى المقارنة بالبنود وإبراز الأرخص لكل بند (والترسية المجزّأة لاحقاً — الهجرة 023).
--  الحل: جدول portal_offer_items (مقفل كالأدلّة) + توسيع portal_submit_offer ليقبل p_items
--  (سعر كل بند) فيحسب الإجمالي = مجموع (كمية البند × سعر الوحدة) اتساقاً. idempotent.
--  شغّلها في Supabase بعد 021.
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) جدول أسعار بنود العرض.
CREATE TABLE IF NOT EXISTS portal_offer_items (
  id          BIGSERIAL PRIMARY KEY,
  offer_id    BIGINT NOT NULL REFERENCES portal_offers(id) ON DELETE CASCADE,
  item_seq    INT NOT NULL,
  unit_price  NUMERIC NOT NULL DEFAULT 0,
  UNIQUE (offer_id, item_seq)
);
CREATE INDEX IF NOT EXISTS idx_portal_offer_items ON portal_offer_items(offer_id);

-- (2) قفله كالأدلّة (نفس portal_locked_guard): الكتابة عبر RPC (علم app.portal_transition) فقط.
ALTER TABLE portal_offer_items ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS trg_portal_offer_items_lock ON portal_offer_items;
CREATE TRIGGER trg_portal_offer_items_lock
  BEFORE INSERT OR UPDATE OR DELETE ON portal_offer_items
  FOR EACH ROW EXECUTE FUNCTION portal_locked_guard();
-- قراءة مقيّدة برؤية الطلب الأب (كبقية جداول العرض) — سياسة SELECT.
DROP POLICY IF EXISTS offer_items_read ON portal_offer_items;
CREATE POLICY offer_items_read ON portal_offer_items FOR SELECT USING (
  EXISTS (SELECT 1 FROM portal_offers o WHERE o.id = portal_offer_items.offer_id
          AND portal_can_see_request(o.request_id))
);
GRANT SELECT ON portal_offer_items TO authenticated;
GRANT SELECT ON portal_offer_items TO anon;

-- (3) توسيع portal_submit_offer: يقبل p_items = [{"seq":int,"price":numeric}] لكل بند.
--     إن مُرِّرت: يُحسب الإجمالي من (كمية بند الطلب × سعر الوحدة) وتُخزَّن الأسعار البندية.
--     وإلا: يُستخدم p_total (توافق خلفي).
DROP FUNCTION IF EXISTS portal_submit_offer(text, text, numeric, int, int, int, text, text);
CREATE OR REPLACE FUNCTION portal_submit_offer(p_request_id text, p_supplier text, p_total numeric,
    p_delivery_days int DEFAULT NULL, p_quality int DEFAULT NULL, p_payment_days int DEFAULT NULL,
    p_note text DEFAULT NULL, p_quote_pdf_key text DEFAULT NULL, p_items jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_phase text; v_id bigint; v_total numeric := p_total;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT phase INTO v_phase FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_phase IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
    SELECT coalesce(sum(ri.qty * nullif((it->>'price'),'')::numeric), 0)
      INTO v_total
      FROM jsonb_array_elements(p_items) it
      JOIN portal_request_items ri ON ri.request_id = p_request_id AND ri.seq = (it->>'seq')::int;
  END IF;
  IF coalesce(p_supplier,'') = '' OR coalesce(v_total,0) <= 0 THEN RAISE EXCEPTION 'بيانات العرض غير مكتملة'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_offers(request_id, supplier_name, total, delivery_days, quality, payment_days, note, entered_by, quote_pdf_key)
    VALUES (p_request_id, p_supplier, v_total, p_delivery_days, p_quality, p_payment_days, p_note, v_me,
            nullif(trim(coalesce(p_quote_pdf_key,'')),''))
    RETURNING id INTO v_id;
  IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
    INSERT INTO portal_offer_items(offer_id, item_seq, unit_price)
      SELECT v_id, (it->>'seq')::int, coalesce(nullif((it->>'price'),'')::numeric, 0)
      FROM jsonb_array_elements(p_items) it
      WHERE (it->>'seq') IS NOT NULL;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'offer_added', v_me, 'portal',
    jsonb_build_object('supplier', p_supplier, 'total', v_total, 'has_pdf', (nullif(trim(coalesce(p_quote_pdf_key,'')),'') IS NOT NULL),
                       'by_item', (p_items IS NOT NULL)));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

GRANT EXECUTE ON FUNCTION portal_submit_offer(text, text, numeric, int, int, int, text, text, jsonb) TO authenticated;

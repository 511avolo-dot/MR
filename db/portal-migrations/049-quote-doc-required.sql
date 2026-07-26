-- ═══════════════════════════════════════════════════════════════════════════
--  049 — إلزام إرفاق مستند عرض المورد + تمكين المورّد من رفع عرضه بنفسه
--  ─────────────────────────────────────────────────────────────────────────
--  توجيه المالك: «عندما تضع عرض سعر يجب أن ترفق المستند تبع عرض المورد،
--  لذلك أيضاً يجب أن تتيح للمورد أن يرفع عرضه كذلك».
--
--  الحالة قبل هذه الهجرة:
--    • portal_submit_offer يقبل p_quote_pdf_key **اختيارياً** — فيمكن تسجيل
--      عرض بلا أي مستند يُثبته (فجوة تدقيق: رقم بلا سند).
--    • portal_supplier_submit (047) لا يقبل مستنداً إطلاقاً — فالمورّد الذي
--      يسعّر ذاتياً لا يستطيع إرفاق عرضه الرسمي، وهو المسار الذي يُفترض أن
--      يكون **أقوى** إثباتاً (المستند من المورّد مباشرة لا من الموظّف).
--
--  ما تفعله هذه الهجرة:
--   (1) مفتاح إعداد `quote_doc_required` في portal_settings — **افتراضي 1
--       (مُفعَّل)** خلافاً لبقية مفاتيح الإنفاذ الخاملة، لأنّ المالك طلبه صراحةً.
--       قابل للإطفاء (=0) من شاشة الإعدادات إن استدعى ظرف تشغيلي ذلك.
--   (2) portal_submit_offer: يرفض العرض بلا مفتاح مستند عند تفعيل المفتاح.
--   (3) portal_supplier_submit: توقيع جديد بمعامل سادس p_quote_pdf_key،
--       بنفس الإلزام، مع **ترحيل مستند المراجعة السابقة** عند التنقيح بلا
--       إعادة رفع (فلا يُعاقَب المورّد على تصحيح سعر).
--   (4) portal_supplier_token_request: دالة **خادمية بحتة** (service_role فقط)
--       تتحقّق من رمز المورّد وتعيد رقم الطلب — تستخدمها نقطة الرفع
--       /api/portal-supplier-doc كي لا يُشتقّ رقم الطلب من مُدخَل العميل.
--
--  ⚠️ تُطبَّق حيّاً بعد 048. مدمجة في db/portal-standalone.sql (تنصيب نظيف).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (1) مفتاح الإعداد (لا يطمس اختيار المالك إن سبق ضبطه) ──────────────────
UPDATE portal_settings
   SET value = value || jsonb_build_object('quote_doc_required', 1)
 WHERE key = 'portal_settings'
   AND NOT (value ? 'quote_doc_required');

-- ── (2) إلزام المستند في إدخال المشتريات ───────────────────────────────────
CREATE OR REPLACE FUNCTION portal_submit_offer(p_request_id text, p_supplier text, p_total numeric,
    p_delivery_days int DEFAULT NULL, p_quality int DEFAULT NULL, p_payment_days int DEFAULT NULL,
    p_note text DEFAULT NULL, p_quote_pdf_key text DEFAULT NULL, p_items jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_phase text; v_id bigint; v_total numeric := p_total;
        v_key text := nullif(trim(coalesce(p_quote_pdf_key,'')),'');
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT phase INTO v_phase FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_phase IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  -- مستند عرض المورد إلزامي (سند العرض) ما لم يُطفَأ المفتاح تشغيلياً
  IF v_key IS NULL AND portal_setting_num('quote_doc_required', 1) >= 1 THEN
    RAISE EXCEPTION 'إرفاق مستند عرض المورد إلزامي (PDF أو صورة) — لا يُسجَّل عرض بلا سند';
  END IF;

  IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
    SELECT coalesce(sum(ri.qty * nullif((it->>'price'),'')::numeric), 0)
      INTO v_total
      FROM jsonb_array_elements(p_items) it
      JOIN portal_request_items ri ON ri.request_id = p_request_id AND ri.seq = (it->>'seq')::int;
  END IF;
  IF coalesce(p_supplier,'') = '' OR coalesce(v_total,0) <= 0 THEN RAISE EXCEPTION 'بيانات العرض غير مكتملة'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_offers(request_id, supplier_name, total, delivery_days, quality, payment_days, note, entered_by, quote_pdf_key)
    VALUES (p_request_id, p_supplier, v_total, p_delivery_days, p_quality, p_payment_days, p_note, v_me, v_key)
    RETURNING id INTO v_id;
  IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
    INSERT INTO portal_offer_items(offer_id, item_seq, unit_price)
      SELECT v_id, (it->>'seq')::int, coalesce(nullif((it->>'price'),'')::numeric, 0)
      FROM jsonb_array_elements(p_items) it
      WHERE (it->>'seq') IS NOT NULL;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'offer_added', v_me, 'portal',
    jsonb_build_object('supplier', p_supplier, 'total', v_total, 'has_pdf', (v_key IS NOT NULL),
                       'by_item', (p_items IS NOT NULL)));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

GRANT EXECUTE ON FUNCTION portal_submit_offer(text, text, numeric, int, int, int, text, text, jsonb) TO authenticated;

-- ── (3) رفع المورّد لمستند عرضه (توقيع جديد بمعامل سادس) ───────────────────
DROP FUNCTION IF EXISTS portal_supplier_submit(text, jsonb, int, int, text);
CREATE OR REPLACE FUNCTION portal_supplier_submit(
  p_token text, p_items jsonb, p_delivery_days int DEFAULT NULL,
  p_payment_days int DEFAULT NULL, p_note text DEFAULT NULL,
  p_quote_pdf_key text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE t portal_supplier_tokens%ROWTYPE; v_phase text; v_total numeric; v_id bigint; v_n int;
        v_key text := nullif(trim(coalesce(p_quote_pdf_key,'')),'');
BEGIN
  SELECT * INTO t FROM portal_supplier_tokens WHERE token = p_token FOR UPDATE;
  IF NOT FOUND OR t.revoked THEN RAISE EXCEPTION 'رابط غير صالح'; END IF;
  IF t.expires_at < now() THEN RAISE EXCEPTION 'انتهت صلاحية الرابط'; END IF;

  SELECT phase INTO v_phase FROM portal_requests WHERE id = t.request_id FOR UPDATE;
  IF v_phase IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'أُقفل باب التسعير لهذا الطلب'; END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'أدخل أسعار البنود'; END IF;

  -- تنقيح بلا إعادة رفع: يُرحَّل مستند المراجعة السابقة (العرض نفسه لم يتغيّر مصدره)
  IF v_key IS NULL AND t.offer_id IS NOT NULL THEN
    SELECT nullif(trim(coalesce(o.quote_pdf_key,'')),'') INTO v_key
      FROM portal_offers o WHERE o.id = t.offer_id;
  END IF;
  IF v_key IS NULL AND portal_setting_num('quote_doc_required', 1) >= 1 THEN
    RAISE EXCEPTION 'إرفاق عرض السعر الرسمي إلزامي (PDF أو صورة)';
  END IF;
  -- المستند يجب أن يخصّ طلب هذا الرمز (لا إسناد مفتاح طلب آخر)
  IF v_key IS NOT NULL AND v_key NOT LIKE ('quotes/' || t.request_id || '/%') THEN
    RAISE EXCEPTION 'مفتاح المستند لا يخصّ هذا الطلب';
  END IF;

  -- كل بند مُسعَّر يجب أن يكون من بنود الطلب فعلاً، وبسعر موجب
  SELECT count(*) INTO v_n FROM jsonb_array_elements(p_items) it
   WHERE NOT EXISTS (SELECT 1 FROM portal_request_items ri
                     WHERE ri.request_id = t.request_id AND ri.seq = (it->>'seq')::int);
  IF v_n > 0 THEN RAISE EXCEPTION 'بند غير موجود في الطلب'; END IF;

  SELECT coalesce(sum(ri.qty * nullif((it->>'price'),'')::numeric), 0) INTO v_total
    FROM jsonb_array_elements(p_items) it
    JOIN portal_request_items ri ON ri.request_id = t.request_id AND ri.seq = (it->>'seq')::int;
  IF coalesce(v_total,0) <= 0 THEN RAISE EXCEPTION 'الإجمالي غير صالح'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  IF t.offer_id IS NOT NULL THEN
    -- تنقيح: نستبدل العرض السابق لنفس المورّد (لا تتكدّس عروض مكرّرة)
    DELETE FROM portal_offer_items WHERE offer_id = t.offer_id;
    DELETE FROM portal_offers WHERE id = t.offer_id;
  END IF;
  INSERT INTO portal_offers(request_id, supplier_name, total, delivery_days, payment_days, note, entered_by, quote_pdf_key)
    VALUES (t.request_id, t.supplier_name, v_total, p_delivery_days, p_payment_days,
            nullif(trim(coalesce(p_note,'')),''), 'supplier:self', v_key)
    RETURNING id INTO v_id;
  INSERT INTO portal_offer_items(offer_id, item_seq, unit_price)
    SELECT v_id, (it->>'seq')::int, coalesce(nullif((it->>'price'),'')::numeric, 0)
      FROM jsonb_array_elements(p_items) it WHERE (it->>'seq') IS NOT NULL;
  PERFORM set_config('app.portal_transition', '0', true);

  UPDATE portal_supplier_tokens
     SET offer_id = v_id, submit_count = submit_count + 1, last_submit_at = now()
   WHERE token = p_token;

  PERFORM portal_audit_write(t.request_id, 'offer_added', 'supplier:'||t.supplier_name, 'supplier_portal',
    jsonb_build_object('supplier', t.supplier_name, 'total', v_total, 'has_pdf', (v_key IS NOT NULL),
                       'self_service', true, 'revision', t.submit_count + 1));
  RETURN jsonb_build_object('ok', true, 'total', v_total, 'revision', t.submit_count + 1);
END $fn$;

REVOKE ALL ON FUNCTION portal_supplier_submit(text,jsonb,int,int,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION portal_supplier_submit(text,jsonb,int,int,text,text) TO anon, authenticated;

-- ── (4) حجز فتحة رفع بالرمز (خادمية بحتة) ──────────────────────────────────
--   لا تكشف شيئاً عن الطلب سوى رقمه واسم المورّد — وتُستدعى بمفتاح الخدمة فقط.
--   غايتان:
--     (أ) أن تشتقّ نقطة الرفع مسار التخزين من **القاعدة** لا من مُدخَل العميل،
--         فلا يستطيع حاملُ رمزٍ رفعَ ملف تحت مجلّد طلب آخر.
--     (ب) **سقف رفع لكل رمز** (مضاد إساءة الاستخدام): الرمز طرف خارجي بلا حساب،
--         فبلا سقف يمكن إغراق التخزين. 20 محاولة تكفي أي مورّد جادّ.
ALTER TABLE portal_supplier_tokens ADD COLUMN IF NOT EXISTS upload_count int NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION portal_supplier_token_request(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE t portal_supplier_tokens%ROWTYPE; v_phase text;
        MAXUP CONSTANT int := 20;
BEGIN
  SELECT * INTO t FROM portal_supplier_tokens WHERE token = p_token FOR UPDATE;
  IF NOT FOUND OR t.revoked THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid'); END IF;
  IF t.expires_at < now() THEN RETURN jsonb_build_object('ok', false, 'reason', 'expired'); END IF;
  SELECT phase INTO v_phase FROM portal_requests WHERE id = t.request_id;
  IF v_phase IS DISTINCT FROM 'pricing' THEN RETURN jsonb_build_object('ok', false, 'reason', 'closed'); END IF;
  IF t.upload_count >= MAXUP THEN RETURN jsonb_build_object('ok', false, 'reason', 'too_many'); END IF;

  UPDATE portal_supplier_tokens SET upload_count = upload_count + 1 WHERE token = p_token;
  RETURN jsonb_build_object('ok', true, 'request_id', t.request_id, 'supplier', t.supplier_name);
END $fn$;

REVOKE ALL ON FUNCTION portal_supplier_token_request(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION portal_supplier_token_request(text) FROM anon;
REVOKE ALL ON FUNCTION portal_supplier_token_request(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION portal_supplier_token_request(text) TO service_role;

-- ── (5) إبلاغ الواجهة بحالة الإلزام + وجود مستند سابق ──────────────────────
--   الواجهة لا تخمّن السياسة: doc_required تأتي من القاعدة، و previous.has_doc
--   يخبر المورّد أنّ مستنده السابق مُرحَّل فلا يُطالَب برفعه ثانيةً عند التنقيح.
CREATE OR REPLACE FUNCTION portal_supplier_rfq(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE t portal_supplier_tokens%ROWTYPE; r portal_requests%ROWTYPE; v_items jsonb; v_prev jsonb;
BEGIN
  SELECT * INTO t FROM portal_supplier_tokens WHERE token = p_token;
  IF NOT FOUND OR t.revoked THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid'); END IF;
  IF t.expires_at < now() THEN RETURN jsonb_build_object('ok', false, 'reason', 'expired'); END IF;

  SELECT * INTO r FROM portal_requests WHERE id = t.request_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid'); END IF;
  IF r.phase <> 'pricing' THEN RETURN jsonb_build_object('ok', false, 'reason', 'closed'); END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('seq', ri.seq, 'name', ri.description,
           'qty', ri.qty, 'unit', ri.unit) ORDER BY ri.seq), '[]'::jsonb)
    INTO v_items FROM portal_request_items ri WHERE ri.request_id = t.request_id;

  -- إن سبق للمورّد التقديم: نُعيد أسعاره كي يُنقّحها (لا أسعار غيره)
  v_prev := NULL;
  IF t.offer_id IS NOT NULL THEN
    SELECT jsonb_build_object(
             'total', o.total, 'delivery_days', o.delivery_days,
             'payment_days', o.payment_days, 'note', o.note,
             'has_doc', (nullif(trim(coalesce(o.quote_pdf_key,'')),'') IS NOT NULL),
             'items', coalesce((SELECT jsonb_agg(jsonb_build_object('seq', oi.item_seq, 'price', oi.unit_price))
                                FROM portal_offer_items oi WHERE oi.offer_id = o.id), '[]'::jsonb))
      INTO v_prev FROM portal_offers o WHERE o.id = t.offer_id;
  END IF;

  RETURN jsonb_build_object('ok', true,
    'request_id', r.id, 'title', r.title, 'need_by', r.need_by,
    'supplier', t.supplier_name, 'expires_at', t.expires_at,
    'submitted', (t.offer_id IS NOT NULL), 'submit_count', t.submit_count,
    'doc_required', (portal_setting_num('quote_doc_required', 1) >= 1),
    'items', v_items, 'previous', v_prev);
END $fn$;

REVOKE ALL ON FUNCTION portal_supplier_rfq(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION portal_supplier_rfq(text) TO anon, authenticated;

-- تحقّق:
--   SELECT (value->>'quote_doc_required') FROM portal_settings WHERE key='portal_settings';  ⇒ 1
--   SELECT has_function_privilege('anon','portal_supplier_token_request(text)','EXECUTE');   ⇒ false
--   SELECT has_function_privilege('anon','portal_supplier_submit(text,jsonb,int,int,text,text)','EXECUTE'); ⇒ true

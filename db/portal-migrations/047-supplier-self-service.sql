-- ═══════════════════════════════════════════════════════════════════════════
--  047 — بوابة المورّد الذاتية (Supplier Self-Service)
--  ─────────────────────────────────────────────────────────────────────────
--  الغرض: يقدّم المورّد عرضه بنفسه عبر رابط آمن بدل أن تُدخِله المشتريات يدوياً.
--
--  المرجع السلبي: بوابة RFQ في النظام 2 (rfq.html، 321 سطراً، 8 حقول) كانت
--  بدائية: بلا تسعير بالبنود · بلا حفظ مسودّة · بلا رفع ملف · بلا تحقّق ·
--  بلا تتبّع — المورّد يرسل رقماً في الفراغ. هذه النسخة تعالج ذلك كلّه.
--
--  ⚠️ ملاحظة أمنية جوهرية: دالتا المورّد **مكشوفتان لـanon عمداً** — فالمورّد
--  ليس له حساب، والرمز وحده هو هويّته. لذلك:
--    • الرمز 43 محرفاً عشوائياً (gen_random_bytes) — نفس قوة رموز البريد.
--    • جدول الرموز خادميّ بحت (RLS مفعّلة بلا سياسة) فلا يُقرأ من العميل إطلاقاً.
--    • الدالتان SECURITY DEFINER ولا تكشفان إلا ما يخصّ طلب ذلك الرمز:
--      لا عروض المنافسين · لا ميزانية · لا معتمِدين · لا ملاحظات داخلية.
--    • مقيّدتان بصلاحية الرمز وبمرحلة التسعير حصراً.
--  وهذا استثناء مقصود من تأكيد S8 (لا دالة portal_ مكشوفة لـanon) — أُضيفتا
--  إلى قائمة بيضاء صريحة في db/portal-tests/11_security.sql مع تعليل.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS portal_supplier_tokens(
  token           text PRIMARY KEY,
  request_id      text NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  supplier_name   text NOT NULL,
  supplier_email  text,
  expires_at      timestamptz NOT NULL,
  revoked         boolean NOT NULL DEFAULT false,
  offer_id        bigint,                       -- العرض المُقدَّم (يُحدَّث عند التنقيح)
  submit_count    int NOT NULL DEFAULT 0,
  last_submit_at  timestamptz,
  created_by      text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sup_tok_req ON portal_supplier_tokens(request_id);
-- RLS مفعّلة **بلا أي سياسة** = لا وصول من anon/authenticated إطلاقاً (خادم فقط).
ALTER TABLE portal_supplier_tokens ENABLE ROW LEVEL SECURITY;

-- ── (1) إنشاء دعوة مورّد: المشتريات/الأدمن فقط ─────────────────────────────
CREATE OR REPLACE FUNCTION portal_supplier_invite(
  p_request_id text, p_supplier text, p_email text DEFAULT NULL, p_ttl_days int DEFAULT 14
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $fn$
DECLARE v_me text := portal_username(); v_phase text; v_tok text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN
    RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF coalesce(trim(p_supplier),'') = '' THEN RAISE EXCEPTION 'اسم المورّد مطلوب'; END IF;

  SELECT phase INTO v_phase FROM portal_requests WHERE id = p_request_id;
  IF v_phase IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  -- إبطال أي دعوة سابقة لنفس المورّد على نفس الطلب (رابط واحد فعّال لكل مورّد)
  UPDATE portal_supplier_tokens SET revoked = true
    WHERE request_id = p_request_id AND supplier_name = p_supplier AND revoked = false;

  v_tok := portal_gen_token();
  INSERT INTO portal_supplier_tokens(token, request_id, supplier_name, supplier_email, expires_at, created_by)
    VALUES (v_tok, p_request_id, trim(p_supplier), nullif(trim(coalesce(p_email,'')),''),
            now() + make_interval(days => greatest(1, least(60, p_ttl_days))), v_me);

  PERFORM portal_audit_write(p_request_id, 'supplier_invited', v_me, 'portal',
    jsonb_build_object('supplier', p_supplier, 'ttl_days', p_ttl_days));
  RETURN jsonb_build_object('ok', true, 'token', v_tok);
END $fn$;

-- ── (2) قراءة طلب التسعير بالرمز (المورّد، بلا حساب) ───────────────────────
--   يعيد ما يحتاجه المورّد فقط. لا عروض منافسين ولا أي بيانات داخلية.
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
             'items', coalesce((SELECT jsonb_agg(jsonb_build_object('seq', oi.item_seq, 'price', oi.unit_price))
                                FROM portal_offer_items oi WHERE oi.offer_id = o.id), '[]'::jsonb))
      INTO v_prev FROM portal_offers o WHERE o.id = t.offer_id;
  END IF;

  RETURN jsonb_build_object('ok', true,
    'request_id', r.id, 'title', r.title, 'need_by', r.need_by,
    'supplier', t.supplier_name, 'expires_at', t.expires_at,
    'submitted', (t.offer_id IS NOT NULL), 'submit_count', t.submit_count,
    'items', v_items, 'previous', v_prev);
END $fn$;

-- ── (3) تقديم/تنقيح العرض بالرمز ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_supplier_submit(
  p_token text, p_items jsonb, p_delivery_days int DEFAULT NULL,
  p_payment_days int DEFAULT NULL, p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE t portal_supplier_tokens%ROWTYPE; v_phase text; v_total numeric; v_id bigint; v_n int;
BEGIN
  SELECT * INTO t FROM portal_supplier_tokens WHERE token = p_token FOR UPDATE;
  IF NOT FOUND OR t.revoked THEN RAISE EXCEPTION 'رابط غير صالح'; END IF;
  IF t.expires_at < now() THEN RAISE EXCEPTION 'انتهت صلاحية الرابط'; END IF;

  SELECT phase INTO v_phase FROM portal_requests WHERE id = t.request_id FOR UPDATE;
  IF v_phase IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'أُقفل باب التسعير لهذا الطلب'; END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'أدخل أسعار البنود'; END IF;

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
  INSERT INTO portal_offers(request_id, supplier_name, total, delivery_days, payment_days, note, entered_by)
    VALUES (t.request_id, t.supplier_name, v_total, p_delivery_days, p_payment_days,
            nullif(trim(coalesce(p_note,'')),''), 'supplier:self')
    RETURNING id INTO v_id;
  INSERT INTO portal_offer_items(offer_id, item_seq, unit_price)
    SELECT v_id, (it->>'seq')::int, coalesce(nullif((it->>'price'),'')::numeric, 0)
      FROM jsonb_array_elements(p_items) it WHERE (it->>'seq') IS NOT NULL;
  PERFORM set_config('app.portal_transition', '0', true);

  UPDATE portal_supplier_tokens
     SET offer_id = v_id, submit_count = submit_count + 1, last_submit_at = now()
   WHERE token = p_token;

  PERFORM portal_audit_write(t.request_id, 'offer_added', 'supplier:'||t.supplier_name, 'supplier_portal',
    jsonb_build_object('supplier', t.supplier_name, 'total', v_total,
                       'self_service', true, 'revision', t.submit_count + 1));
  RETURN jsonb_build_object('ok', true, 'total', v_total, 'revision', t.submit_count + 1);
END $fn$;

-- ── الصلاحيات ──────────────────────────────────────────────────────────────
-- الدعوة: للمستخدم المسجَّل فقط (محروسة داخلياً بصلاحية المشتريات).
REVOKE ALL ON FUNCTION portal_supplier_invite(text,text,text,int) FROM PUBLIC;
REVOKE ALL ON FUNCTION portal_supplier_invite(text,text,text,int) FROM anon;
GRANT EXECUTE ON FUNCTION portal_supplier_invite(text,text,text,int) TO authenticated;

-- دالتا المورّد: مكشوفتان لـanon **عمداً** (المورّد بلا حساب؛ الرمز هويّته).
REVOKE ALL ON FUNCTION portal_supplier_rfq(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION portal_supplier_submit(text,jsonb,int,int,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION portal_supplier_rfq(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_supplier_submit(text,jsonb,int,int,text) TO anon, authenticated;

-- تحقّق:
--   SELECT portal_supplier_rfq('bad');  ⇒ {"ok":false,"reason":"invalid"}

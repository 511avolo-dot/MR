-- ════════════════════════════════════════════════════════════════════════
--  بوابة المورّد لتقديم عروض الأسعار (RFQ Supplier Portal)
--  يقدّم المورّد عرضه عبر رابط برمز سرّي (token) — بلا حساب — كنمط secure-resume.
-- ════════════════════════════════════════════════════════════════════════
--  تُنفَّذ في Supabase → SQL Editor بعد db/rfq.sql.
-- ════════════════════════════════════════════════════════════════════════

-- توسعة جدول العروض: رمز الدعوة + حالة الاستجابة + طوابع زمنية
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS token        TEXT;
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS status       TEXT DEFAULT 'invited'; -- invited | opened | submitted
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS opened_at    TIMESTAMPTZ;
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS submitted_at TIMESTAMPTZ;
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS no_bid       JSONB DEFAULT '{}'::jsonb; -- {lineId:true} بنود لا يعرضها المورد
CREATE INDEX IF NOT EXISTS idx_rfqq_token ON proc_rfq_quotes(token);

-- 1) جلب RFQ للمورّد عبر الرمز (يكشف فقط ما يحتاجه المورّد، ويسجّل الفتح)
CREATE OR REPLACE FUNCTION get_rfq_for_supplier(p_rfq text, p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rfq proc_rfqs; v_q proc_rfq_quotes;
BEGIN
  IF p_rfq IS NULL OR p_token IS NULL OR length(p_token) < 8 THEN RETURN NULL; END IF;
  SELECT * INTO v_q FROM proc_rfq_quotes WHERE rfq_id = p_rfq AND token = p_token;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_rfq FROM proc_rfqs WHERE id = p_rfq;
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- سجّل أول فتح (دون تغيير حالة "مُقدَّم")
  UPDATE proc_rfq_quotes
     SET status = CASE WHEN status = 'submitted' THEN 'submitted' ELSE 'opened' END,
         opened_at = COALESCE(opened_at, now())
   WHERE id = v_q.id;
  RETURN jsonb_build_object(
    'rfq', jsonb_build_object('id',v_rfq.id,'title',v_rfq.title,'status',v_rfq.status,
                              'deadline',v_rfq.deadline,'lines',v_rfq.lines,'notes',v_rfq.notes),
    'supplier', v_q.supplier,
    'my_quote', jsonb_build_object('prices',v_q.prices,'attrs',v_q.attrs,'note',v_q.note,
                                   'no_bid',v_q.no_bid,'status',v_q.status)
  );
END; $$;

-- 2) تقديم/تحديث عرض المورّد (يتحقق من الرمز والحالة والموعد)
CREATE OR REPLACE FUNCTION submit_supplier_quote(p_rfq text, p_token text, p_prices jsonb, p_attrs jsonb, p_no_bid jsonb, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rfq proc_rfqs; v_q proc_rfq_quotes;
BEGIN
  SELECT * INTO v_q FROM proc_rfq_quotes WHERE rfq_id = p_rfq AND token = p_token;
  IF NOT FOUND THEN RAISE EXCEPTION 'رمز غير صالح'; END IF;
  SELECT * INTO v_rfq FROM proc_rfqs WHERE id = p_rfq;
  IF v_rfq.status IN ('awarded','cancelled') THEN RAISE EXCEPTION 'الطلب مغلق'; END IF;
  IF v_rfq.deadline IS NOT NULL AND v_rfq.deadline < CURRENT_DATE THEN RAISE EXCEPTION 'انتهى الموعد'; END IF;
  UPDATE proc_rfq_quotes SET
     prices = COALESCE(p_prices,'{}'::jsonb),
     attrs  = COALESCE(p_attrs,'{}'::jsonb),
     no_bid = COALESCE(p_no_bid,'{}'::jsonb),
     note   = p_note,
     status = 'submitted', submitted_at = now(), updated_at = now()
   WHERE id = v_q.id;
  RETURN jsonb_build_object('ok', true);
END; $$;

REVOKE ALL ON FUNCTION get_rfq_for_supplier(text,text) FROM public;
REVOKE ALL ON FUNCTION submit_supplier_quote(text,text,jsonb,jsonb,jsonb,text) FROM public;
GRANT EXECUTE ON FUNCTION get_rfq_for_supplier(text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION submit_supplier_quote(text,text,jsonb,jsonb,jsonb,text) TO anon, authenticated;

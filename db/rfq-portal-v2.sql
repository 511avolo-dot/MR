-- ════════════════════════════════════════════════════════════════════════
--  ترقية بوابة المورّد (RFQ v2): روابط قصيرة + مرفق عرض السعر الإلزامي
--  تُنفَّذ في Supabase → SQL Editor بعد db/rfq.sql و db/rfq-portal.sql.
--  متوافقة خلفياً: الدوال والروابط القديمة تبقى تعمل.
-- ════════════════════════════════════════════════════════════════════════

-- مرفق عرض السعر (مسار الملف في مخزن supplier-docs تحت بادئة rfq/)
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS quote_file TEXT;

-- الرمز فريد عالمياً → يسمح بالبحث بالرمز وحده (رابط قصير /q/<token>)
CREATE UNIQUE INDEX IF NOT EXISTS idx_rfqq_token_uniq ON proc_rfq_quotes(token) WHERE token IS NOT NULL;

-- 1) جلب RFQ بالرمز وحده (للرابط القصير)
CREATE OR REPLACE FUNCTION get_rfq_by_token(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rfq proc_rfqs; v_q proc_rfq_quotes;
BEGIN
  IF p_token IS NULL OR length(p_token) < 12 THEN RETURN NULL; END IF;
  SELECT * INTO v_q FROM proc_rfq_quotes WHERE token = p_token;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_rfq FROM proc_rfqs WHERE id = v_q.rfq_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE proc_rfq_quotes
     SET status = CASE WHEN status = 'submitted' THEN 'submitted' ELSE 'opened' END,
         opened_at = COALESCE(opened_at, now())
   WHERE id = v_q.id;
  RETURN jsonb_build_object(
    'rfq', jsonb_build_object('id',v_rfq.id,'title',v_rfq.title,'status',v_rfq.status,
                              'deadline',v_rfq.deadline,'lines',v_rfq.lines,'notes',v_rfq.notes),
    'supplier', v_q.supplier,
    'my_quote', jsonb_build_object('prices',v_q.prices,'attrs',v_q.attrs,'note',v_q.note,
                                   'no_bid',v_q.no_bid,'status',v_q.status,'quote_file',v_q.quote_file)
  );
END; $$;

-- 2) تقديم العرض بالرمز وحده + حفظ مرفق عرض السعر (إلزامي عند الإرسال النهائي)
CREATE OR REPLACE FUNCTION submit_supplier_quote_v2(p_token text, p_prices jsonb, p_attrs jsonb, p_no_bid jsonb, p_note text, p_quote_file text, p_final boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rfq proc_rfqs; v_q proc_rfq_quotes;
BEGIN
  IF p_token IS NULL OR length(p_token) < 12 THEN RAISE EXCEPTION 'رمز غير صالح'; END IF;
  SELECT * INTO v_q FROM proc_rfq_quotes WHERE token = p_token;
  IF NOT FOUND THEN RAISE EXCEPTION 'رمز غير صالح'; END IF;
  SELECT * INTO v_rfq FROM proc_rfqs WHERE id = v_q.rfq_id;
  IF v_rfq.status IN ('awarded','cancelled') THEN RAISE EXCEPTION 'الطلب مغلق'; END IF;
  IF v_rfq.deadline IS NOT NULL AND v_rfq.deadline < CURRENT_DATE THEN RAISE EXCEPTION 'انتهى الموعد'; END IF;
  IF p_final AND COALESCE(p_quote_file, v_q.quote_file) IS NULL THEN RAISE EXCEPTION 'مرفق عرض السعر مطلوب'; END IF;
  UPDATE proc_rfq_quotes SET
     prices    = COALESCE(p_prices,'{}'::jsonb),
     attrs     = COALESCE(p_attrs,'{}'::jsonb),
     no_bid    = COALESCE(p_no_bid,'{}'::jsonb),
     note      = p_note,
     quote_file= COALESCE(p_quote_file, quote_file),
     status    = CASE WHEN p_final THEN 'submitted' WHEN status = 'submitted' THEN 'submitted' ELSE 'opened' END,
     submitted_at = CASE WHEN p_final THEN now() ELSE submitted_at END,
     updated_at = now()
   WHERE id = v_q.id;
  RETURN jsonb_build_object('ok', true);
END; $$;

REVOKE ALL ON FUNCTION get_rfq_by_token(text) FROM public;
REVOKE ALL ON FUNCTION submit_supplier_quote_v2(text,jsonb,jsonb,jsonb,text,text,boolean) FROM public;
GRANT EXECUTE ON FUNCTION get_rfq_by_token(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION submit_supplier_quote_v2(text,jsonb,jsonb,jsonb,text,text,boolean) TO anon, authenticated;

-- ملاحظة: مرفقات عروض الأسعار تُخزَّن في مخزن supplier-docs الموجود (المُحصَّن
-- مسبقاً بحجم ونوع وRLS) تحت بادئة المسار rfq/ — فلا حاجة لإعداد مخزن أو سياسات جديدة.

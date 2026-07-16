-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 033 — فاتورة المورد + المطابقة الثلاثية (3-Way Match) — P1 من التدقيق
--  الفجوة: لا كيان «فاتورة مورد» ولا مطابقة أمر الشراء ↔ الاستلام ↔ الفاتورة قبل
--  الصرف الآجل. أكبر الشركات تشترط المطابقة الثلاثية للصرف الآجل (منع دفع زائد/مكرّر).
--
--  التصميم (يحترم شرط الدفع — تصحيح المالك المثبَّت):
--    • جدول `portal_supplier_invoices` + كشف الفاتورة المكرّرة (UNIQUE + فحص عبر الطلبات).
--    • `portal_three_way_status(request_id)`: يقارن إجمالي أمر الشراء ↔ المستلَم ↔ الفواتير.
--    • الإنفاذ عبر **مُشغِّل على portal_payments** — يُفرض على **الصرف الآجل (credit) فقط**؛
--      الكاش/العهدة (مقدَّم) مستثنى (توقيت الصرف يتبع شرط الدفع لا قاعدة «استلام ثم صرف»).
--
--  قابلة للتفعيل وخاملة افتراضياً: `three_way_enforce` (حقل JSON portal_settings) = 0
--  (لا مطابقة، السلوك الحالي) أو = 1 (تُفرض على الآجل). التفاوت: `three_way_tolerance_pct`.
--  idempotent — مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) جدول فواتير المورد ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_supplier_invoices (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  supplier_name TEXT,
  invoice_no    TEXT NOT NULL,
  invoice_date  DATE,
  amount        NUMERIC NOT NULL CHECK (amount > 0),
  doc_key       TEXT,
  note          TEXT,
  recorded_by   TEXT,
  recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (request_id, invoice_no)
);
CREATE INDEX IF NOT EXISTS idx_portal_invoices_req ON portal_supplier_invoices(request_id);

ALTER TABLE portal_supplier_invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_invoices_read ON portal_supplier_invoices;
CREATE POLICY portal_invoices_read ON portal_supplier_invoices FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
  OR portal_can_see_request(request_id));
REVOKE ALL ON portal_supplier_invoices FROM anon, PUBLIC;
GRANT  SELECT ON portal_supplier_invoices TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_supplier_invoices TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_supplier_invoices_id_seq TO service_role;

-- ── (2) دوال حساب (خادمية) ──────────────────────────────────────────────────
-- إجمالي أمر الشراء (التعميد) للطلب شاملاً الضريبة — المجزّأ بمجموع بنوده.
CREATE OR REPLACE FUNCTION portal_award_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(
    COALESCE((SELECT sum(line_total) FROM portal_award_lines WHERE request_id = p_request_id),
             (SELECT winner_total FROM portal_award WHERE request_id = p_request_id AND status IN ('pending','approved'))),
    0) * (1 + portal_setting_num('vat', 15) / 100.0);
$fn$;
REVOKE ALL ON FUNCTION portal_award_total(text) FROM anon, authenticated, PUBLIC;

CREATE OR REPLACE FUNCTION portal_invoiced_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(amount), 0) FROM portal_supplier_invoices WHERE request_id = p_request_id;
$fn$;
REVOKE ALL ON FUNCTION portal_invoiced_total(text) FROM anon, authenticated, PUBLIC;

-- ── (3) حالة المطابقة الثلاثية (للمالية/المشتريات/الأدمن أو صاحب الطلب) ──────
CREATE OR REPLACE FUNCTION portal_three_way_status(p_request_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_award numeric; v_inv numeric; v_recv boolean; v_tol numeric;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
          OR portal_can_see_request(p_request_id)) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  v_award := portal_award_total(p_request_id);
  v_inv   := portal_invoiced_total(p_request_id);
  v_recv  := EXISTS (SELECT 1 FROM portal_receipts WHERE request_id = p_request_id);
  v_tol   := portal_setting_num('three_way_tolerance_pct', 0);
  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'award_total', round(v_award, 2),
    'invoiced_total', round(v_inv, 2),
    'received', v_recv,
    'variance', round(v_inv - v_award, 2),
    'within_tolerance', v_inv <= v_award * (1 + v_tol/100.0),
    'matched', v_recv AND v_inv > 0 AND v_inv <= v_award * (1 + v_tol/100.0),
    'enforced', portal_setting_num('three_way_enforce', 0) >= 1
  );
END $fn$;
REVOKE ALL ON FUNCTION portal_three_way_status(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_three_way_status(text) TO authenticated;

-- ── (4) تسجيل فاتورة مورد + كشف التكرار ─────────────────────────────────────
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
  -- كشف الفاتورة المكرّرة: نفس رقم الفاتورة لنفس المورد على طلب آخر (منع ازدواج الصرف)
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

-- ── (5) الإنفاذ: مُشغِّل على portal_payments (الصرف الآجل فقط) ────────────────
CREATE OR REPLACE FUNCTION portal_three_way_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_award numeric; v_inv numeric; v_tol numeric;
BEGIN
  IF portal_setting_num('three_way_enforce', 0) < 1 THEN RETURN NEW; END IF;
  IF NEW.kind <> 'credit' THEN RETURN NEW; END IF;   -- الكاش/العهدة (مقدَّم) مستثنى — يتبع شرط الدفع
  IF NOT EXISTS (SELECT 1 FROM portal_receipts WHERE request_id = NEW.request_id) THEN
    RAISE EXCEPTION 'المطابقة الثلاثية: لا يوجد استلام مسجّل — الصرف الآجل يتطلّب استلام البضاعة';
  END IF;
  v_inv := portal_invoiced_total(NEW.request_id);
  IF v_inv <= 0 THEN RAISE EXCEPTION 'المطابقة الثلاثية: لا توجد فاتورة مورد مسجّلة للصرف الآجل'; END IF;
  v_award := portal_award_total(NEW.request_id);
  v_tol := portal_setting_num('three_way_tolerance_pct', 0);
  IF v_inv > v_award * (1 + v_tol/100.0) THEN
    RAISE EXCEPTION 'المطابقة الثلاثية: إجمالي الفواتير % يتجاوز أمر الشراء % (خارج التفاوت)',
      round(v_inv), round(v_award);
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_portal_three_way_guard ON portal_payments;
CREATE TRIGGER trg_portal_three_way_guard
  BEFORE INSERT ON portal_payments
  FOR EACH ROW EXECUTE FUNCTION portal_three_way_guard();

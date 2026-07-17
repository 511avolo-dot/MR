-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 034 — المرتجعات/التالف + إشعار مدين (Returns & Debit Note) — P1 من التدقيق
--  الفجوة: الاستلام كان كمية فقط — لا مسار لرفض البضاعة المعيبة/التالفة ولا إشعار
--  مدين للمورد يخصم قيمة المرتجع من المستحق. مكتب الاستلام لا يستطيع توثيق
--  «وصل 100، منها 12 تالف مرتجَع».
--
--  الحل:
--    • جدول `portal_returns` (بنود المرتجع + قيمة الخصم + رقم إشعار مدين + مرفق محضر).
--    • `portal_return_record` (صلاحية استلام/جودة أو مشتريات/أدمن) — يحسب قيمة الخصم
--      ويولّد رقم إشعار مدين، ويسجّل أثراً دائماً.
--    • دمج في المطابقة الثلاثية: `portal_three_way_status` يكشف صافي المستحق (أمر
--      الشراء − المرتجعات) — فتبقى الرؤية دقيقة قبل الصرف.
--
--  idempotent — مدمجة في portal-standalone.sql. لا إنفاذ جديد مانع (توثيق + رؤية).
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) جدول المرتجعات + إشعار مدين ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_returns (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  supplier_name TEXT,
  reason        TEXT NOT NULL,
  lines         JSONB,                                 -- [{seq, qty, unit_price, line_total}]
  debit_amount  NUMERIC NOT NULL DEFAULT 0 CHECK (debit_amount >= 0),
  debit_note_no TEXT,
  doc_key       TEXT,                                  -- محضر المرتجع (PDF/صورة، R2 kind=ret)
  status        TEXT NOT NULL DEFAULT 'issued',        -- issued | settled
  created_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_returns_req ON portal_returns(request_id);

ALTER TABLE portal_returns ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_returns_read ON portal_returns;
CREATE POLICY portal_returns_read ON portal_returns FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
  OR portal_has_perm('can_verify_stock') OR portal_can_see_request(request_id));
REVOKE ALL ON portal_returns FROM anon, PUBLIC;
GRANT  SELECT ON portal_returns TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_returns TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_returns_id_seq TO service_role;

-- ── (2) مجموع المرتجعات (خادمية) ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_returns_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(debit_amount), 0) FROM portal_returns WHERE request_id = p_request_id;
$fn$;
REVOKE ALL ON FUNCTION portal_returns_total(text) FROM anon, authenticated, PUBLIC;

-- ── (3) تسجيل مرتجع + إشعار مدين (استلام/جودة أو مشتريات/أدمن) ────────────────
CREATE OR REPLACE FUNCTION portal_return_record(
    p_request_id text, p_lines jsonb, p_reason text,
    p_supplier_name text DEFAULT NULL, p_doc_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_ln jsonb; v_amt numeric := 0; v_q numeric; v_p numeric;
        v_lines jsonb := '[]'::jsonb; v_seq int; v_no text; v_n int; v_id bigint;
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
    v_amt := v_amt + (v_q * v_p);
    v_lines := v_lines || jsonb_build_object('seq', v_seq, 'qty', v_q, 'unit_price', v_p, 'line_total', v_q * v_p);
  END LOOP;
  -- رقم إشعار مدين تسلسلي للطلب
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

-- ── (4) حالة المرتجعات (للعرض) ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_return_status(p_request_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
          OR portal_has_perm('can_verify_stock') OR portal_can_see_request(p_request_id)) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'returns_total', round(portal_returns_total(p_request_id), 2),
    'count', (SELECT count(*) FROM portal_returns WHERE request_id = p_request_id));
END $fn$;
REVOKE ALL ON FUNCTION portal_return_status(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_return_status(text) TO authenticated;

-- ── (5) دمج في المطابقة الثلاثية: صافي المستحق = أمر الشراء − المرتجعات ──────
CREATE OR REPLACE FUNCTION portal_three_way_status(p_request_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_award numeric; v_inv numeric; v_ret numeric; v_recv boolean; v_tol numeric; v_net numeric;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
          OR portal_can_see_request(p_request_id)) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  v_award := portal_award_total(p_request_id);
  v_inv   := portal_invoiced_total(p_request_id);
  v_ret   := portal_returns_total(p_request_id);
  v_recv  := EXISTS (SELECT 1 FROM portal_receipts WHERE request_id = p_request_id);
  v_tol   := portal_setting_num('three_way_tolerance_pct', 0);
  v_net   := v_award - v_ret;
  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'award_total', round(v_award, 2),
    'returns_total', round(v_ret, 2),
    'net_payable', round(v_net, 2),
    'invoiced_total', round(v_inv, 2),
    'received', v_recv,
    'variance', round(v_inv - v_net, 2),
    'within_tolerance', v_inv <= v_net * (1 + v_tol/100.0),
    'matched', v_recv AND v_inv > 0 AND v_inv <= v_net * (1 + v_tol/100.0),
    'enforced', portal_setting_num('three_way_enforce', 0) >= 1);
END $fn$;
REVOKE ALL ON FUNCTION portal_three_way_status(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_three_way_status(text) TO authenticated;

-- ── (6) مُشغِّل الإنفاذ يحترم صافي المستحق (أمر الشراء − المرتجعات) ───────────
CREATE OR REPLACE FUNCTION portal_three_way_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_net numeric; v_inv numeric; v_tol numeric;
BEGIN
  IF portal_setting_num('three_way_enforce', 0) < 1 THEN RETURN NEW; END IF;
  IF NEW.kind <> 'credit' THEN RETURN NEW; END IF;   -- الكاش/العهدة (مقدَّم) مستثنى
  IF NOT EXISTS (SELECT 1 FROM portal_receipts WHERE request_id = NEW.request_id) THEN
    RAISE EXCEPTION 'المطابقة الثلاثية: لا يوجد استلام مسجّل — الصرف الآجل يتطلّب استلام البضاعة';
  END IF;
  v_inv := portal_invoiced_total(NEW.request_id);
  IF v_inv <= 0 THEN RAISE EXCEPTION 'المطابقة الثلاثية: لا توجد فاتورة مورد مسجّلة للصرف الآجل'; END IF;
  v_net := portal_award_total(NEW.request_id) - portal_returns_total(NEW.request_id);  -- صافي المستحق
  v_tol := portal_setting_num('three_way_tolerance_pct', 0);
  IF v_inv > v_net * (1 + v_tol/100.0) THEN
    RAISE EXCEPTION 'المطابقة الثلاثية: إجمالي الفواتير % يتجاوز صافي المستحق % (أمر الشراء − المرتجعات، خارج التفاوت)',
      round(v_inv), round(v_net);
  END IF;
  RETURN NEW;
END $fn$;
-- المُشغِّل نفسه معرّف في 033؛ إعادة تعريف الدالة تكفي (CREATE OR REPLACE).

-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 037 — العقود الإطارية / أوامر الشراء الممتدّة (Framework / Blanket PO)
--  الفجوة: كل طلب من الصفر — لا استفادة من اتفاق إطاري بأسعار/سقف متفَّق عليه مع
--  مورد لفترة. أكبر الشركات تُصدر «طلبات سحب» (call-off) مقابل عقد إطاري دون
--  إعادة مناقصة، بسقف إجمالي.
--
--  التصميم (بنمط الميزانية 031 — سقف + مُستهلَك + إنفاذ مؤجَّل، خامل وآمن):
--    • جدول `portal_contracts` (مورد + سقف + مدة + حالة + عملة).
--    • عمود `portal_requests.contract_id` (طلب سحب مقابل عقد).
--    • «المُستهلَك» = مجموع قيم التعميدات النشطة للطلبات المرتبطة (بعملة الأساس، 035).
--    • الإنفاذ عبر مُشغِّل قيد مؤجَّل على portal_award — يمنع تجاوز السقف/العقد
--      المنتهي عند التفعيل (`contract_enforce=1`)، وإلا تحذير غير مانع.
--
--  idempotent — مدمجة في portal-standalone.sql. تطبَّق بعد 036.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) جدول العقود الإطارية ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_contracts (
  id            BIGSERIAL PRIMARY KEY,
  contract_no   TEXT,
  title         TEXT NOT NULL,
  supplier_name TEXT,
  start_date    DATE,
  end_date      DATE,
  ceiling       NUMERIC NOT NULL DEFAULT 0 CHECK (ceiling >= 0),  -- بعملة الأساس
  currency      TEXT NOT NULL DEFAULT 'SAR',
  status        TEXT NOT NULL DEFAULT 'active',                   -- active | closed
  note          TEXT,
  created_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_contracts_status ON portal_contracts(status);

ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS contract_id BIGINT REFERENCES portal_contracts(id);

ALTER TABLE portal_contracts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_contracts_read ON portal_contracts;
CREATE POLICY portal_contracts_read ON portal_contracts FOR SELECT TO authenticated USING (true);  -- مرجع للمشتريات/الكل
REVOKE ALL ON portal_contracts FROM anon, PUBLIC;
GRANT  SELECT ON portal_contracts TO authenticated, anon;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_contracts TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_contracts_id_seq TO service_role;

-- ── (2) المُستهلَك من العقد (بعملة الأساس) ──────────────────────────────────
CREATE OR REPLACE FUNCTION portal_contract_consumed(p_contract_id bigint)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(portal_award_total(r.id)), 0)
  FROM portal_requests r
  WHERE r.contract_id = p_contract_id
    AND coalesce(r.status,'') <> 'cancelled'
    AND EXISTS (SELECT 1 FROM portal_award a WHERE a.request_id = r.id AND a.status IN ('pending','approved'));
$fn$;
REVOKE ALL ON FUNCTION portal_contract_consumed(bigint) FROM anon, authenticated, PUBLIC;

-- ── (3) حالة العقد ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_contract_status(p_contract_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_c portal_contracts%ROWTYPE; v_used numeric;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement') OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  SELECT * INTO v_c FROM portal_contracts WHERE id = p_contract_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'العقد غير موجود'; END IF;
  v_used := portal_contract_consumed(p_contract_id);
  RETURN jsonb_build_object('id', p_contract_id, 'ceiling', round(v_c.ceiling,2), 'consumed', round(v_used,2),
    'available', round(v_c.ceiling - v_used, 2), 'status', v_c.status,
    'releases', (SELECT count(*) FROM portal_requests WHERE contract_id = p_contract_id AND coalesce(status,'') <> 'cancelled'),
    'expired', (v_c.end_date IS NOT NULL AND v_c.end_date < current_date),
    'enforced', portal_setting_num('contract_enforce', 0) >= 1);
END $fn$;
REVOKE ALL ON FUNCTION portal_contract_status(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_contract_status(bigint) TO authenticated;

-- ── (4) إدارة العقود (مشتريات/أدمن) ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_contract_set(p_id bigint, p_title text, p_supplier text, p_ceiling numeric,
    p_start date, p_end date, p_no text DEFAULT NULL, p_currency text DEFAULT 'SAR', p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'إدارة العقود صلاحية مشتريات/أدمن';
  END IF;
  IF coalesce(trim(p_title),'') = '' THEN RAISE EXCEPTION 'عنوان العقد مطلوب'; END IF;
  IF p_ceiling IS NULL OR p_ceiling < 0 THEN RAISE EXCEPTION 'سقف غير صالح'; END IF;
  IF p_end IS NOT NULL AND p_start IS NOT NULL AND p_end < p_start THEN RAISE EXCEPTION 'تاريخ النهاية قبل البداية'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO portal_contracts(contract_no, title, supplier_name, ceiling, currency, start_date, end_date, note, created_by)
      VALUES (p_no, p_title, p_supplier, p_ceiling, upper(coalesce(nullif(p_currency,''),'SAR')), p_start, p_end, p_note, v_me)
      RETURNING id INTO v_id;
  ELSE
    UPDATE portal_contracts SET contract_no=p_no, title=p_title, supplier_name=p_supplier, ceiling=p_ceiling,
      currency=upper(coalesce(nullif(p_currency,''),'SAR')), start_date=p_start, end_date=p_end, note=p_note
      WHERE id=p_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'العقد غير موجود'; END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'contract_id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_contract_set(bigint, text, text, numeric, date, date, text, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_contract_set(bigint, text, text, numeric, date, date, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION portal_contract_close(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username();
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'إدارة العقود صلاحية مشتريات/أدمن';
  END IF;
  UPDATE portal_contracts SET status='closed' WHERE id=p_id;
  RETURN jsonb_build_object('ok', true);
END $fn$;
REVOKE ALL ON FUNCTION portal_contract_close(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_contract_close(bigint) TO authenticated;

-- ── (5) ربط طلب بعقد (طلب سحب) — قبل التعميد ────────────────────────────────
CREATE OR REPLACE FUNCTION portal_link_request_contract(p_request_id text, p_contract_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_c portal_contracts%ROWTYPE;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'ربط الطلب بعقد صلاحية مشتريات/أدمن';
  END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase NOT IN ('requisition','pricing') THEN RAISE EXCEPTION 'الربط قبل التعميد فقط'; END IF;
  IF p_contract_id IS NOT NULL THEN
    SELECT * INTO v_c FROM portal_contracts WHERE id = p_contract_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'العقد غير موجود'; END IF;
    IF v_c.status <> 'active' THEN RAISE EXCEPTION 'العقد غير نشط'; END IF;
    IF v_c.end_date IS NOT NULL AND v_c.end_date < current_date THEN RAISE EXCEPTION 'العقد منتهٍ'; END IF;
  END IF;
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET contract_id = p_contract_id, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);
  RETURN jsonb_build_object('ok', true, 'contract_id', p_contract_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_link_request_contract(text, bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_link_request_contract(text, bigint) TO authenticated;

-- ── (6) الإنفاذ: مُشغِّل قيد مؤجَّل على portal_award ─────────────────────────
CREATE OR REPLACE FUNCTION portal_contract_enforce() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_cid bigint; v_c portal_contracts%ROWTYPE; v_used numeric; v_enforce numeric;
BEGIN
  SELECT contract_id INTO v_cid FROM portal_requests WHERE id = NEW.request_id;
  IF v_cid IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_c FROM portal_contracts WHERE id = v_cid;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_enforce := portal_setting_num('contract_enforce', 0);
  IF v_c.end_date IS NOT NULL AND v_c.end_date < current_date THEN
    IF v_enforce >= 1 THEN RAISE EXCEPTION 'العقد الإطاري % منتهٍ — لا سحب جديد', v_cid;
    ELSE RAISE WARNING 'تحذير: تعميد على عقد إطاري منتهٍ (%)', v_cid; END IF;
  END IF;
  v_used := portal_contract_consumed(v_cid);
  IF v_used > v_c.ceiling THEN
    IF v_enforce >= 1 THEN
      RAISE EXCEPTION 'تجاوز سقف العقد الإطاري %: المُستهلَك % يتجاوز السقف %', v_cid, round(v_used), round(v_c.ceiling);
    ELSE
      RAISE WARNING 'تحذير: تجاوز سقف العقد الإطاري % (% > %)', v_cid, round(v_used), round(v_c.ceiling);
    END IF;
  END IF;
  RETURN NULL;
END $fn$;
DROP TRIGGER IF EXISTS trg_portal_contract_enforce ON portal_award;
CREATE CONSTRAINT TRIGGER trg_portal_contract_enforce
  AFTER INSERT OR UPDATE ON portal_award
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION portal_contract_enforce();

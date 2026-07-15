-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 032 — ضبط تغيير آيبان المورد (Bank-detail Change Control) — P1 وقاية احتيال
--  المشكلة (من التدقيق): تغيير آيبان مورد قائم كان تعديلاً صامتاً مباشراً — ناقل
--  احتيال كلاسيكي (تحويل مدفوعات المورد لحساب مهاجم). أكبر الشركات تشترط لتغيير
--  البيانات البنكية: إعادة تحقّق + **اعتماد مزدوج (فصل مهام)** + أثر تدقيق.
--
--  الحل:
--    • حارس مخصّص على portal_suppliers يمنع تغيير الآيبان مباشرةً (عند التفعيل).
--    • سلسلة طلب/اعتماد: طالب التغيير ≠ معتمِده؛ الاعتماد صلاحية مالية؛ يُطبَّق
--      التغيير فقط عبر الاعتماد (علم مخصّص). جدول التغييرات = أثر تدقيق دائم.
--
--  قابلة للتفعيل وخاملة افتراضياً (كنمط budget_enforce): المفتاح
--  `iban_change_control` (حقل في JSON portal_settings) = 0 (لا ضبط، السلوك الحالي)
--  أو = 1 (يُفرض المسار). لا كسر للواجهة حتى يفعّلها المالك ويجهّز شاشة الطلب.
--  idempotent — مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) جدول طلبات تغيير الآيبان (أثر تدقيق دائم) ───────────────────────────
CREATE TABLE IF NOT EXISTS portal_supplier_iban_changes (
  id            BIGSERIAL PRIMARY KEY,
  supplier_id   BIGINT NOT NULL REFERENCES portal_suppliers(id) ON DELETE CASCADE,
  old_iban      TEXT,
  new_iban      TEXT NOT NULL,
  reason        TEXT,
  status        TEXT NOT NULL DEFAULT 'pending',      -- pending | approved | rejected
  requested_by  TEXT,
  requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_by    TEXT,
  decided_at    TIMESTAMPTZ,
  decision_note TEXT
);
CREATE INDEX IF NOT EXISTS idx_portal_iban_chg_supplier ON portal_supplier_iban_changes(supplier_id, status);

ALTER TABLE portal_supplier_iban_changes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_iban_chg_read ON portal_supplier_iban_changes;
CREATE POLICY portal_iban_chg_read ON portal_supplier_iban_changes FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement'));
REVOKE ALL ON portal_supplier_iban_changes FROM anon, PUBLIC;
GRANT  SELECT ON portal_supplier_iban_changes TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_supplier_iban_changes TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_supplier_iban_changes_id_seq TO service_role;

-- ── (2) حارس الآيبان: يمنع التغيير المباشر عند التفعيل (إلا عبر علم الاعتماد) ──
CREATE OR REPLACE FUNCTION portal_supplier_iban_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NEW.iban IS DISTINCT FROM OLD.iban
     AND portal_setting_num('iban_change_control', 0) >= 1
     AND coalesce(current_setting('app.iban_change_approved', true), '') <> '1'
  THEN
    RAISE EXCEPTION 'تغيير آيبان المورد يتطلّب طلب اعتماد مزدوج (فصل مهام) — عبر دوال البوابة';
  END IF;
  RETURN NEW;
END $fn$;

-- يعمل قبل portal_config_guard منطقياً (كلاهما BEFORE؛ كلاهما يجب أن يمرّ).
DROP TRIGGER IF EXISTS trg_portal_supplier_iban_guard ON portal_suppliers;
CREATE TRIGGER trg_portal_supplier_iban_guard
  BEFORE UPDATE ON portal_suppliers
  FOR EACH ROW EXECUTE FUNCTION portal_supplier_iban_guard();

-- ── (3) طلب تغيير الآيبان (مشتريات/مالية/أدمن) — لا يُطبَّق فوراً ─────────────
CREATE OR REPLACE FUNCTION portal_supplier_iban_request(p_supplier_id bigint, p_new_iban text, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_old text; v_new text; v_cid bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بطلب تغيير الآيبان';
  END IF;
  v_new := upper(regexp_replace(coalesce(p_new_iban,''), '\s+', '', 'g'));
  IF v_new !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
  SELECT iban INTO v_old FROM portal_suppliers WHERE id = p_supplier_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'المورد غير موجود'; END IF;
  IF v_old IS NOT NULL AND upper(regexp_replace(v_old,'\s+','','g')) = v_new THEN
    RAISE EXCEPTION 'الآيبان الجديد مطابق للحالي — لا تغيير';
  END IF;
  IF EXISTS (SELECT 1 FROM portal_supplier_iban_changes WHERE supplier_id = p_supplier_id AND status = 'pending') THEN
    RAISE EXCEPTION 'يوجد طلب تغيير معلّق لهذا المورد — يُبتّ فيه أولاً';
  END IF;
  INSERT INTO portal_supplier_iban_changes(supplier_id, old_iban, new_iban, reason, requested_by)
    VALUES (p_supplier_id, v_old, v_new, p_reason, v_me) RETURNING id INTO v_cid;
  RETURN jsonb_build_object('ok', true, 'change_id', v_cid, 'status', 'pending');
END $fn$;
REVOKE ALL ON FUNCTION portal_supplier_iban_request(bigint, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_supplier_iban_request(bigint, text, text) TO authenticated;

-- ── (4) اعتماد التغيير (مالية/أدمن) — فصل مهام: المعتمِد ≠ الطالب ─────────────
CREATE OR REPLACE FUNCTION portal_supplier_iban_approve(p_change_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_chg portal_supplier_iban_changes%ROWTYPE;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'اعتماد تغيير الآيبان صلاحية مالية/أدمن';
  END IF;
  SELECT * INTO v_chg FROM portal_supplier_iban_changes WHERE id = p_change_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب التغيير غير موجود'; END IF;
  IF v_chg.status <> 'pending' THEN RAISE EXCEPTION 'الطلب ليس معلّقاً (%).', v_chg.status; END IF;
  IF v_chg.requested_by IS NOT NULL AND v_chg.requested_by = v_me THEN
    RAISE EXCEPTION 'فصل المهام: طالب التغيير لا يعتمده';
  END IF;
  -- تطبيق التغيير عبر العلمين (يتجاوز حارس الآيبان + config_guard بأمان)
  PERFORM set_config('app.iban_change_approved', '1', true);
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_suppliers SET iban = v_chg.new_iban WHERE id = v_chg.supplier_id;
  PERFORM set_config('app.iban_change_approved', '0', true);
  PERFORM set_config('app.portal_transition', '0', true);
  UPDATE portal_supplier_iban_changes
    SET status = 'approved', decided_by = v_me, decided_at = now() WHERE id = p_change_id;
  RETURN jsonb_build_object('ok', true, 'status', 'approved', 'supplier_id', v_chg.supplier_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_supplier_iban_approve(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_supplier_iban_approve(bigint) TO authenticated;

-- ── (5) رفض التغيير (مالية/أدمن) ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_supplier_iban_reject(p_change_id bigint, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_st text;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'رفض تغيير الآيبان صلاحية مالية/أدمن';
  END IF;
  SELECT status INTO v_st FROM portal_supplier_iban_changes WHERE id = p_change_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب التغيير غير موجود'; END IF;
  IF v_st <> 'pending' THEN RAISE EXCEPTION 'الطلب ليس معلّقاً'; END IF;
  UPDATE portal_supplier_iban_changes
    SET status = 'rejected', decided_by = v_me, decided_at = now(), decision_note = p_note WHERE id = p_change_id;
  RETURN jsonb_build_object('ok', true, 'status', 'rejected');
END $fn$;
REVOKE ALL ON FUNCTION portal_supplier_iban_reject(bigint, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_supplier_iban_reject(bigint, text) TO authenticated;

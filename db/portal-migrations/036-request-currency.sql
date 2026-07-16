-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 036 — تعيين عملة الطلب (إكمال تعدّد العملات end-to-end)
--  يكمل 035: يتيح تعيين عملة غير الأساس لطلب قبل التعميد، دون لمس دالة
--  portal_create_request الكبيرة (9 معاملات) — عبر RPC مستقلّة محروسة.
--
--  القيود: صاحب الطلب أو المشتريات/الأدمن؛ قبل التعميد فقط (لا توجد ترسية)؛
--  العملة يجب أن تكون معرّفة ومفعّلة. idempotent — مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION portal_set_request_currency(p_request_id text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_code text := upper(trim(coalesce(p_code,'')));
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF NOT (v_req.requester = v_me OR portal_has_perm('can_manage_procurement') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'تعيين العملة: صاحب الطلب أو المشتريات فقط';
  END IF;
  IF v_req.phase NOT IN ('requisition','pricing') THEN
    RAISE EXCEPTION 'تُحدَّد العملة قبل التعميد فقط (الطور الحالي: %)', v_req.phase;
  END IF;
  IF EXISTS (SELECT 1 FROM portal_award WHERE request_id = p_request_id AND status IN ('pending','approved')) THEN
    RAISE EXCEPTION 'لا يمكن تغيير العملة بعد الترسية';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_currencies WHERE code = v_code AND active) THEN
    RAISE EXCEPTION 'عملة غير معرّفة أو غير مفعّلة: %', v_code;
  END IF;
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET currency = v_code, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);
  RETURN jsonb_build_object('ok', true, 'currency', v_code);
END $fn$;
REVOKE ALL ON FUNCTION portal_set_request_currency(text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_set_request_currency(text, text) TO authenticated;

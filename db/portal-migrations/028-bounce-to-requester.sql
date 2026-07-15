-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 028 — إرجاع المشتريات الطلبَ للمقدّم من مرحلة التسعير (تغيير المواصفات)
--  المشروع: mwbjoysuybgbrvfrprex (البوابة، نظام 3). شغّلها بعد 027.
--  الغرض: عند اكتشاف المشتريات خطأً في المواصفات أثناء التسعير، تُعيد الطلب للمقدّم لتعديله،
--         فتبدأ جولة تسعير جديدة بعد إعادة الاعتماد. **سلامة التدقيق: لا تُحذف العروض (أدلّة
--         مقفلة) — تُعلَّم superseded فتُستبعد من المقارنة النشطة وتبقى في السجلّ.**
--  آمن ومعزول. idempotent.
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) علم «جولة سابقة» على العروض (لا حذف — حفاظاً على الأثر).
ALTER TABLE portal_offers ADD COLUMN IF NOT EXISTS superseded boolean NOT NULL DEFAULT false;

-- (2) إرجاع للمقدّم: يُعلّم عروض الجولة، يُلغي التعميد المشتق، ويعيد الطلب لدورة الحاجة.
CREATE OR REPLACE FUNCTION portal_bounce_to_requester(p_request_id text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_discarded jsonb; v_n int;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_is_admin()) THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF coalesce(trim(p_reason),'') = '' THEN RAISE EXCEPTION 'سبب الإرجاع وما المطلوب تعديله مطلوب'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'pricing' THEN RAISE EXCEPTION 'الإرجاع للمقدّم من المشتريات يكون في مرحلة التسعير فقط'; END IF;

  -- سجّل عروض الجولة (سلامة الأثر) قبل تعليمها.
  SELECT coalesce(jsonb_agg(jsonb_build_object('supplier', supplier_name, 'total', total) ORDER BY id), '[]'::jsonb), count(*)
    INTO v_discarded, v_n FROM portal_offers WHERE request_id = p_request_id AND superseded = false;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_offers SET superseded = true WHERE request_id = p_request_id AND superseded = false;
  UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
  DELETE FROM portal_award_lines WHERE request_id = p_request_id;
  DELETE FROM portal_award_approvals WHERE request_id = p_request_id;
  DELETE FROM portal_po_approvals WHERE request_id = p_request_id;
  -- يعود الطلب للمقدّم كإرجاع دورة الحاجة (المقدّم يعدّل ثم يعيد التقديم فتُبنى السلسلة من جديد).
  UPDATE portal_requests SET status = 'returned', phase = 'requisition', current_seq = 0,
         po_issued_at = NULL, po_issued_by = NULL, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'stage_returned', v_me, 'portal',
    jsonb_build_object('from', 'procurement', 'to', 'requester', 'comment', p_reason, 'superseded_offers', v_discarded));
  RETURN jsonb_build_object('ok', true, 'status', 'returned', 'superseded', v_n);
END $fn$;
REVOKE ALL ON FUNCTION portal_bounce_to_requester(text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_bounce_to_requester(text, text) TO authenticated;

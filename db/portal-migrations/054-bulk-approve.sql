-- ═══════════════════════════════════════════════════════════════════════════
--  054 — الاعتماد الجماعي (Bulk Approve/Reject) — المرحلة 3-أ (الإنتاجية)
--  ─────────────────────────────────────────────────────────────────────────
--  معتمِد لديه عدّة طلبات معلّقة على مرحلته كان يفتح كلّ طلب على حدة. هذه الدالة
--  تعتمد/ترفض/تُرجِع مجموعة طلبات دفعةً واحدة — **مع الحفاظ الكامل على ذكاء المحرّك
--  وحوكمته**: كل طلب يمرّ عبر `portal_pr_transition` نفسها (فصل المهام، المعتمِد
--  المؤهَّل، التفويض، الإرجاع لمرحلة) داخل معاملة فرعية مستقلّة — فطلبٌ يفشل حارسه
--  (مثلاً الطالب نفسه، أو ليس معتمِد المرحلة) يُسجَّل فاشلاً في نتيجته دون إجهاض الباقي.
--  واعية بالدورة (`p_cycle`): تخدم دورتَي `need` و`disbursement` معاً.
--
--  بلا تغيير مخطّط — دالة إنتاجية بحتة تعيد استخدام المحرّك المُختبَر (صفر انحدار).
--  ⚠️ تُطبَّق حيّاً بعد 053. idempotent — مدمجة في portal-standalone.sql.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_bulk_transition(
    p_request_ids text[], p_action text, p_comment text DEFAULT NULL, p_cycle text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_id text; v_res jsonb; v_out jsonb := '[]'::jsonb;
        v_ok int := 0; v_fail int := 0; v_err text; v_n int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return') THEN RAISE EXCEPTION 'إجراء غير صالح للاعتماد الجماعي'; END IF;
  v_n := coalesce(array_length(p_request_ids, 1), 0);
  IF v_n = 0 THEN RAISE EXCEPTION 'لا طلبات محدَّدة'; END IF;
  IF v_n > 100 THEN RAISE EXCEPTION 'الحد الأقصى 100 طلب في الدفعة الواحدة'; END IF;
  IF p_action IN ('reject','return') AND coalesce(trim(p_comment),'') = '' THEN
    RAISE EXCEPTION 'سبب مطلوب للرفض/الإرجاع الجماعي';
  END IF;

  FOREACH v_id IN ARRAY p_request_ids LOOP
    BEGIN
      -- كل طلب عبر المحرّك نفسه (الحوكمة كاملة) داخل معاملة فرعية معزولة.
      v_res := portal_pr_transition(v_id, p_action, p_comment, NULL, 0, p_cycle);
      v_ok := v_ok + 1;
      v_out := v_out || jsonb_build_array(jsonb_build_object('id', v_id, 'ok', true, 'status', v_res->>'status'));
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
      v_fail := v_fail + 1;
      v_out := v_out || jsonb_build_array(jsonb_build_object('id', v_id, 'ok', false, 'error', v_err));
    END;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'total', v_n,
    'approved', v_ok, 'failed', v_fail, 'results', v_out);
END $fn$;
REVOKE ALL ON FUNCTION portal_bulk_transition(text[], text, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_bulk_transition(text[], text, text, text) TO authenticated;

-- تحقّق:
--   SELECT portal_bulk_transition(ARRAY['REQ-..','REQ-..'], 'approve', NULL, 'disbursement');

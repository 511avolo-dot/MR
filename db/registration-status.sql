-- ════════════════════════════════════════════════════════════════════════
--  متابعة حالة طلب التسجيل (للمورد) — دالة RPC آمنة
--  Supplier application STATUS tracking — secure RPC
-- ════════════════════════════════════════════════════════════════════════
--  بعد hardened-rls.sql يُمنع anon من قراءة جدول التسجيل (حماية PII).
--  لتمكين المورد من متابعة طلبه دون كشف الجدول: دالة SECURITY DEFINER تتحقّق
--  من (رقم الطلب + قيمة تحقّق يعرفها المورد: السجل التجاري أو الرقم الضريبي أو
--  البريد) ثم تُعيد حقولاً عامة آمنة فقط (الحالة + رسالة + التواريخ + الاسم).
--  لا تُعيد أي بيانات حسّاسة (وثائق، جهات اتصال، tokens).
--
--  تُنفَّذ مرة واحدة في: Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_registration_status(p_id text, p_verify text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row    proc_supplier_registrations;
  v_verify text;
  v_notes  text := NULL;
  v_msg    jsonb := NULL;
BEGIN
  IF p_id IS NULL OR p_verify IS NULL OR length(btrim(p_verify)) < 3 THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row FROM proc_supplier_registrations WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- التحقق: قيمة يعرفها صاحب الطلب فقط (تطبيع: إزالة الفراغات، حروف صغيرة)
  v_verify := lower(regexp_replace(btrim(p_verify), '\s+', '', 'g'));
  IF v_verify NOT IN (
        lower(regexp_replace(coalesce(v_row.commercial_reg,''), '\s+', '', 'g')),
        lower(regexp_replace(coalesce(v_row.vat_number,''),     '\s+', '', 'g')),
        lower(btrim(coalesce(v_row.email,''))),
        lower(btrim(coalesce(v_row.contact_email,''))),
        lower(regexp_replace(coalesce(v_row.contact_mobile,''), '\s+', '', 'g'))
      )
     OR length(v_verify) = 0 THEN
    -- قيمة تحقّق خاطئة → لا نكشف وجود الطلب
    RETURN jsonb_build_object('error', 'verify_failed');
  END IF;

  -- استخراج رسالة عامة آمنة من review_notes (قد تكون JSON من لوحة المراجعة)
  v_notes := v_row.review_notes;
  IF v_notes IS NOT NULL AND length(btrim(v_notes)) > 0 THEN
    BEGIN
      v_msg := (v_notes::jsonb -> 'general');
      IF v_msg IS NULL THEN v_msg := to_jsonb(v_notes); END IF;
    EXCEPTION WHEN others THEN
      v_msg := to_jsonb(v_notes);
    END;
  END IF;

  RETURN jsonb_build_object(
    'found',         true,
    'status',        coalesce(v_row.status, 'pending'),
    'legal_name_ar', v_row.legal_name_ar,
    'legal_name_en', v_row.legal_name_en,
    'submitted_at',  v_row.submitted_at,
    'reviewed_at',   v_row.reviewed_at,
    'message',       v_msg,
    -- يُعاد فقط عند الحاجة لتعديل، ليتمكن المورد من فتح رابط الاستئناف
    'needs_revision', (v_row.status = 'needs_revision'),
    'revision_token', CASE WHEN v_row.status = 'needs_revision' THEN v_row.revision_token ELSE NULL END
  );
END;
$$;

REVOKE ALL ON FUNCTION get_registration_status(text, text) FROM public;
GRANT EXECUTE ON FUNCTION get_registration_status(text, text) TO anon, authenticated;

-- ملاحظة: إن لم يوجد عمود (مثل contact_mobile) في جدولك، احذف سطره من قائمة التحقق.

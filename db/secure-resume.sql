-- ════════════════════════════════════════════════════════════════════════
--  استئناف طلب التسجيل بأمان — دالتا RPC (بديلتان عن قراءة/تعديل anon المباشر)
-- ════════════════════════════════════════════════════════════════════════
--  بعد المرحلة 1 من hardened-rls.sql، يُمنع anon من قراءة/تعديل جدول التسجيل
--  (حماية PII). لكن صفحة التسجيل العامة تحتاج — في «وضع الاستئناف» — إلى قراءة
--  سجل المورد وتحديثه عبر (id + revision_token) السرّي الذي يرسله فريق المشتريات.
--
--  الحل: دالتان SECURITY DEFINER تتحقّقان من الـ token على الخادم وتعملان فقط
--  على السجل المطابق — دون فتح الجدول كاملاً لأحد.
--
--  تُنفَّذ في Supabase → SQL Editor (بعد إنشاء الجدول).
-- ════════════════════════════════════════════════════════════════════════

-- 1) قراءة سجل واحد للاستئناف — يُعيد الصف فقط إذا طابق الـ token (وإلا NULL)
CREATE OR REPLACE FUNCTION get_registration_for_resume(p_id text, p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row proc_supplier_registrations;
BEGIN
  IF p_id IS NULL OR p_token IS NULL OR length(p_token) < 8 THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_row FROM proc_supplier_registrations WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  -- لا يُكشف الصف إلا بمطابقة الـ token السرّي
  IF v_row.revision_token IS NULL OR v_row.revision_token <> p_token THEN
    RETURN NULL;
  END IF;
  RETURN to_jsonb(v_row);
END;
$$;

-- 2) إعادة إرسال الطلب — يُحدّث السجل المطابق للـ token فقط، ويعيد الحالة pending.
--    يُحدّث فقط أعمدة البيانات المسموح بها؛ لا يستطيع المتصدّل تغيير الحالة/الـ token.
CREATE OR REPLACE FUNCTION resubmit_registration(p_id text, p_token text, p_data jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing proc_supplier_registrations;
  v_merged   proc_supplier_registrations;
BEGIN
  SELECT * INTO v_existing FROM proc_supplier_registrations WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'registration not found';
  END IF;
  IF v_existing.revision_token IS NULL
     OR v_existing.revision_token <> p_token
     OR v_existing.status <> 'needs_revision' THEN
    RAISE EXCEPTION 'invalid token or state';
  END IF;

  -- ادمج بيانات المستخدم فوق الصف الحالي (المفاتيح المفقودة تبقى كما هي)
  v_merged := jsonb_populate_record(v_existing, p_data);

  UPDATE proc_supplier_registrations SET
    legal_name_ar        = v_merged.legal_name_ar,
    legal_name_en        = v_merged.legal_name_en,
    trade_name           = v_merged.trade_name,
    entity_type          = v_merged.entity_type,
    country              = v_merged.country,
    city                 = v_merged.city,
    established_date     = v_merged.established_date,
    established_hijri    = v_merged.established_hijri,
    commercial_reg       = v_merged.commercial_reg,
    cr_issue_date        = v_merged.cr_issue_date,
    cr_expiry_date       = v_merged.cr_expiry_date,
    chamber              = v_merged.chamber,
    chamber_membership   = v_merged.chamber_membership,
    chamber_expiry       = v_merged.chamber_expiry,
    vat_number           = v_merged.vat_number,
    zakat_number         = v_merged.zakat_number,
    gosi_number          = v_merged.gosi_number,
    address              = v_merged.address,
    po_box               = v_merged.po_box,
    postal_code          = v_merged.postal_code,
    phone                = v_merged.phone,
    fax                  = v_merged.fax,
    website              = v_merged.website,
    email                = v_merged.email,
    contact_name         = v_merged.contact_name,
    contact_title        = v_merged.contact_title,
    contact_mobile       = v_merged.contact_mobile,
    contact_phone        = v_merged.contact_phone,
    contact_email        = v_merged.contact_email,
    sales_name           = v_merged.sales_name,
    sales_mobile         = v_merged.sales_mobile,
    sales_email          = v_merged.sales_email,
    finance_name         = v_merged.finance_name,
    finance_mobile       = v_merged.finance_mobile,
    finance_email        = v_merged.finance_email,
    business_description = v_merged.business_description,
    activity_start_year  = v_merged.activity_start_year,
    paid_capital         = v_merged.paid_capital,
    employees_total      = v_merged.employees_total,
    employees_saudi      = v_merged.employees_saudi,
    contractor_grade     = v_merged.contractor_grade,
    business_scope       = v_merged.business_scope,
    sectors              = v_merged.sectors,
    products_services    = v_merged.products_services,
    rep_name             = v_merged.rep_name,
    rep_title            = v_merged.rep_title,
    rep_id_number        = v_merged.rep_id_number,
    doc_paths            = v_merged.doc_paths,
    -- أعمدة التحكم تُفرَض هنا (لا تُؤخذ من إدخال المستخدم)
    status               = 'pending',
    review_notes         = NULL,
    reviewed_by          = NULL,
    reviewed_at          = NULL,
    revision_token       = NULL,
    resubmitted_at       = now(),
    submitted_at         = now()
  WHERE id = p_id;
END;
$$;

-- منح التنفيذ للزوّار (anon) — الأمان داخل الدالة عبر التحقق من الـ token
REVOKE ALL ON FUNCTION get_registration_for_resume(text, text) FROM public;
REVOKE ALL ON FUNCTION resubmit_registration(text, text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION get_registration_for_resume(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION resubmit_registration(text, text, jsonb) TO anon, authenticated;

-- ملاحظة: إن كان أي عمود أعلاه غير موجود في جدولك، احذف سطره. الأعمدة مأخوذة
-- من الحقول التي ترسلها صفحة التسجيل (register.html).

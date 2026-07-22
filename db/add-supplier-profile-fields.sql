-- ═══════════════════════════════════════════════════════════════════════════
--  إضافة حقول ملف المورد (المدينة/نوع المنشأة/نطاق العمل/وصف النشاط) — النظام 1/2
--  المشروع: yofcaxvstjcrmbgciwym  ·  الجدول: proc_suppliers
--  تُملأ تلقائياً عند الموافقة على طلب التسجيل (نسخ من proc_supplier_registrations)،
--  وقابلة للتحرير من نموذج المورد. آمن للتكرار (IF NOT EXISTS).
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE proc_suppliers ADD COLUMN IF NOT EXISTS city                 TEXT;
ALTER TABLE proc_suppliers ADD COLUMN IF NOT EXISTS entity_type          TEXT;
ALTER TABLE proc_suppliers ADD COLUMN IF NOT EXISTS business_scope       TEXT;
ALTER TABLE proc_suppliers ADD COLUMN IF NOT EXISTS business_description  TEXT;

-- ملء الموردين المعتمَدين حالياً من تسجيلاتهم (مطابقة بالسجل التجاري، بلا مسح لتعديل يدوي):
WITH r AS (
  SELECT DISTINCT ON (commercial_reg) commercial_reg, city, entity_type, business_description,
         nullif(array_to_string(ARRAY(SELECT jsonb_array_elements_text(coalesce(business_scope,'[]'::jsonb))), '، '),'') AS scope_txt
  FROM proc_supplier_registrations
  WHERE coalesce(commercial_reg,'') <> ''
  ORDER BY commercial_reg, submitted_at DESC
)
UPDATE proc_suppliers s
SET city                 = coalesce(nullif(s.city,''), r.city),
    entity_type          = coalesce(nullif(s.entity_type,''), r.entity_type),
    business_scope       = coalesce(nullif(s.business_scope,''), r.scope_txt),
    business_description = coalesce(nullif(s.business_description,''), r.business_description)
FROM r
WHERE s.commercial_reg = r.commercial_reg;

NOTIFY pgrst, 'reload schema';

-- تحقّق:
-- SELECT count(*) FROM proc_suppliers WHERE coalesce(business_description,'')<>'' OR coalesce(city,'')<>'';

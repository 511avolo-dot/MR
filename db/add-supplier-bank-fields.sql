-- ═══════════════════════════════════════════════════════════════════════════
--  إضافة الحقول البنكية إلى تسجيل الموردين — النظام 1/2 (المشروع القديم)
--  المشروع: yofcaxvstjcrmbgciwym  ·  الجدول: proc_supplier_registrations
--  آمن للتكرار (IF NOT EXISTS). شغّله في: Supabase (القديم) → SQL Editor.
--  ملاحظة: هذه الحقول اختيارية عند التسجيل؛ الآيبان يُخزَّن مُطبَّعاً (SA + 22 رقماً بلا مسافات).
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE proc_supplier_registrations ADD COLUMN IF NOT EXISTS bank_name      TEXT;
ALTER TABLE proc_supplier_registrations ADD COLUMN IF NOT EXISTS account_holder TEXT;
ALTER TABLE proc_supplier_registrations ADD COLUMN IF NOT EXISTS account_number TEXT;
ALTER TABLE proc_supplier_registrations ADD COLUMN IF NOT EXISTS iban           TEXT;

-- تحقّق:
-- SELECT column_name FROM information_schema.columns
--   WHERE table_name='proc_supplier_registrations'
--     AND column_name IN ('bank_name','account_holder','account_number','iban');

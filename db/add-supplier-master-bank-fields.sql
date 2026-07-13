-- ═══════════════════════════════════════════════════════════════════════════
--  إضافة الحقول البنكية إلى سجلّ المورد المعتمَد — النظام 1/2 (المشروع القديم)
--  المشروع: yofcaxvstjcrmbgciwym  ·  الجدول: proc_suppliers
--  تُملأ تلقائياً عند الموافقة على طلب التسجيل (نسخ من proc_supplier_registrations)،
--  وقابلة للتحرير من نموذج المورد. آمن للتكرار (IF NOT EXISTS).
--  شغّله في: Supabase (القديم) → SQL Editor — قبل نشر index.html الجديد.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE proc_suppliers ADD COLUMN IF NOT EXISTS bank_name      TEXT;
ALTER TABLE proc_suppliers ADD COLUMN IF NOT EXISTS account_holder TEXT;
ALTER TABLE proc_suppliers ADD COLUMN IF NOT EXISTS account_number TEXT;
ALTER TABLE proc_suppliers ADD COLUMN IF NOT EXISTS iban           TEXT;

-- تحقّق:
-- SELECT column_name FROM information_schema.columns
--   WHERE table_name='proc_suppliers'
--     AND column_name IN ('bank_name','account_holder','account_number','iban');

-- ════════════════════════════════════════════════════════════════════════
--  وحدة إدارة وتتبع أوامر الشراء — سجل أوامر الشراء الموحّد
--  (بديل رقمي كامل لملف الإكسل — مبنية بالكامل داخل Supabase، بلا مورّد خارجي)
-- ════════════════════════════════════════════════════════════════════════
--  تُنفَّذ مرة واحدة في Supabase → SQL Editor بعد إعداد Supabase Auth.
--  وحدة مستقلة: ترتبط بالمورّد بالاسم (soft link) دون مفاتيح أجنبية، فلا تكسر
--  أي جدول قائم. الحقول المحسوبة (الضريبة/الإجمالي/أيام التأخير/زمن التوريد)
--  تُحسب في التطبيق وتُخزَّن هنا نسخة للتقارير فقط (التطبيق هو مصدر الحساب).
-- ════════════════════════════════════════════════════════════════════════

-- 1) سجل أوامر الشراء
CREATE TABLE IF NOT EXISTS proc_purchase_orders (
  po_number          TEXT PRIMARY KEY,                       -- رقم الأمر (فريد) P.O-DG2026-3101
  issue_date         DATE,                                   -- تاريخ الإصدار
  sector             TEXT,                                   -- القطاع
  project            TEXT,                                   -- المشروع / الموقع
  supplier           TEXT,                                   -- اسم المورد (soft link)
  subtotal           NUMERIC NOT NULL DEFAULT 0,             -- إجمالي قبل الضريبة (يدوي/مجموع البنود)
  vat                NUMERIC,                                -- ضريبة 15% (محسوب)
  total              NUMERIC,                                -- الإجمالي شامل الضريبة (محسوب)
  officer            TEXT,                                   -- مسؤول المشتريات
  payment_method     TEXT,                                   -- طريقة الدفع
  priority           TEXT,                                   -- الأولوية
  expected_delivery  DATE,                                   -- تاريخ التسليم المتوقع
  actual_delivery    DATE,                                   -- تاريخ التسليم الفعلي
  status             TEXT NOT NULL DEFAULT 'قيد المراجعة',   -- الحالة
  days_delayed       INT,                                    -- أيام التأخير (محسوب)
  delay_reason       TEXT,                                   -- سبب التأخير
  notes              TEXT,                                   -- ملاحظات
  category           TEXT,                                   -- فئة المشتريات
  lead_time_days     INT,                                    -- زمن التوريد (يوم) (محسوب)
  items              JSONB DEFAULT '[]'::jsonb,              -- بنود الأمر (اختيارية): [{desc,qty,unit,price}]
  status_history     JSONB DEFAULT '[]'::jsonb,             -- سجل انتقالات الحالة: [{from,to,by,at}]
  created_by         TEXT,
  created_at         TIMESTAMPTZ DEFAULT now(),
  updated_by         TEXT,
  updated_at         TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_po_status    ON proc_purchase_orders(status);
CREATE INDEX IF NOT EXISTS idx_po_sector    ON proc_purchase_orders(sector);
CREATE INDEX IF NOT EXISTS idx_po_supplier  ON proc_purchase_orders(supplier);
CREATE INDEX IF NOT EXISTS idx_po_issue     ON proc_purchase_orders(issue_date DESC);
CREATE INDEX IF NOT EXISTS idx_po_expected  ON proc_purchase_orders(expected_delivery);
CREATE INDEX IF NOT EXISTS idx_po_priority  ON proc_purchase_orders(priority);

ALTER TABLE proc_purchase_orders ENABLE ROW LEVEL SECURITY;
-- النموذج متّسق مع بقية النظام: المصادَق عليهم فقط، والتحكّم التفصيلي في التطبيق
-- (الإنشاء/التعديل/الاعتماد/الحذف يُضبط عبر صلاحيات can_create_po / can_edit_po /
--  can_approve_po / can_delete_po).
DROP POLICY IF EXISTS "auth_all" ON proc_purchase_orders;
CREATE POLICY "auth_all" ON proc_purchase_orders
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ════════════════════════════════════════════════════════════════════════
--  ملاحظة: لإتاحة التحديث اللحظي (Realtime) لهذا الجدول، فعّل النشر:
--    ALTER PUBLICATION supabase_realtime ADD TABLE proc_purchase_orders;
-- ════════════════════════════════════════════════════════════════════════

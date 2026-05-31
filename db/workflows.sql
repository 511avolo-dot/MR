-- ════════════════════════════════════════════════════════════════════════
--  وحدة سير العمل — اعتمادات الشراء + الإشعارات داخل النظام
--  (مبنية بالكامل داخل Supabase — بلا مورّد خارجي)
-- ════════════════════════════════════════════════════════════════════════
--  تُنفَّذ في Supabase → SQL Editor بعد إعداد Supabase Auth.
--  سياسة الاعتماد: مستوى 1 = مدير المشتريات، مستوى 2 = المدير العام.
--  المستوى يُحدَّد تلقائياً من مبلغ الطلب مقابل حدٍّ قابل للضبط
--  (proc_settings.key = 'approval_threshold').
-- ════════════════════════════════════════════════════════════════════════

-- 1) طلبات اعتماد الشراء
CREATE TABLE IF NOT EXISTS proc_purchase_requests (
  id               TEXT PRIMARY KEY,
  title            TEXT NOT NULL,
  supplier         TEXT,
  amount           NUMERIC NOT NULL DEFAULT 0,
  currency         TEXT DEFAULT 'SAR',
  details          JSONB DEFAULT '{}'::jsonb,
  requested_by     TEXT NOT NULL,                 -- username
  requested_by_name TEXT,
  status           TEXT NOT NULL DEFAULT 'pending', -- pending | approved | rejected
  required_level   INT  NOT NULL DEFAULT 1,        -- 1 = مدير المشتريات، 2 = المدير العام
  decided_by       TEXT,
  decided_at       TIMESTAMPTZ,
  decision_note    TEXT,
  created_at       TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pr_status   ON proc_purchase_requests(status);
CREATE INDEX IF NOT EXISTS idx_pr_reqby    ON proc_purchase_requests(requested_by);
CREATE INDEX IF NOT EXISTS idx_pr_created  ON proc_purchase_requests(created_at DESC);

ALTER TABLE proc_purchase_requests ENABLE ROW LEVEL SECURITY;
-- النموذج متّسق مع بقية النظام: المصادَق عليهم فقط، والتحكّم التفصيلي في التطبيق
-- (من يعتمد كل مستوى يُضبط عبر صلاحيات can_approve_l1 / can_approve_l2).
DROP POLICY IF EXISTS "auth_all" ON proc_purchase_requests;
CREATE POLICY "auth_all" ON proc_purchase_requests
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 2) الإشعارات داخل النظام
CREATE TABLE IF NOT EXISTS proc_notifications (
  id          TEXT PRIMARY KEY,
  recipient   TEXT NOT NULL,        -- username للمستلم
  type        TEXT,                 -- approval | decision | reminder | system
  title       TEXT NOT NULL,
  body        TEXT,
  link        TEXT,                 -- وجهة داخل التطبيق (مثل 'approvals')
  read        BOOLEAN DEFAULT false,
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ntf_recipient ON proc_notifications(recipient, read);
CREATE INDEX IF NOT EXISTS idx_ntf_created   ON proc_notifications(created_at DESC);

ALTER TABLE proc_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON proc_notifications;
CREATE POLICY "auth_all" ON proc_notifications
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 3) حدّ الاعتماد (قابل للتعديل) — فوقه يتطلب الطلب اعتماد المدير العام
INSERT INTO proc_settings (key, value, description)
VALUES ('approval_threshold', '{"amount":50000}'::jsonb, 'حد اعتماد مدير المشتريات (ر.س)')
ON CONFLICT (key) DO NOTHING;

-- ملاحظة: لتعيين المعتمدين، امنح المستخدمين الصلاحيات من واجهة إدارة المستخدمين:
--   • مدير المشتريات → can_approve_l1
--   • المدير العام    → can_approve_l2  (يعتمد كل المستويات)

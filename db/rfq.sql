-- ════════════════════════════════════════════════════════════════════════
--  وحدة طلب عروض الأسعار (RFQ) ومقارنتها — داخل النظام
-- ════════════════════════════════════════════════════════════════════════
--  تُنفَّذ في Supabase → SQL Editor بعد إعداد Supabase Auth.
-- ════════════════════════════════════════════════════════════════════════

-- 1) طلبات عروض الأسعار
CREATE TABLE IF NOT EXISTS proc_rfqs (
  id              TEXT PRIMARY KEY,
  title           TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'open',   -- open | closed | awarded | cancelled
  deadline        DATE,
  lines           JSONB DEFAULT '[]'::jsonb,       -- [{id, code, desc, qty, unit, baseline}]
  suppliers       JSONB DEFAULT '[]'::jsonb,       -- أسماء الموردين المدعوّين
  weights         JSONB DEFAULT '{"price":100,"delivery":0,"quality":0,"payment":0}'::jsonb, -- أوزان التقييم
  awards          JSONB DEFAULT '{}'::jsonb,       -- ترسية على مستوى البند {lineId: supplier}
  budget          NUMERIC DEFAULT 0,               -- إجمالي الأسعار المرجعية
  notes           TEXT,
  created_by      TEXT,
  created_by_name TEXT,
  awarded_to      TEXT,
  awarded_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rfq_status  ON proc_rfqs(status);
CREATE INDEX IF NOT EXISTS idx_rfq_created ON proc_rfqs(created_at DESC);

ALTER TABLE proc_rfqs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON proc_rfqs;
CREATE POLICY "auth_all" ON proc_rfqs FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 2) عروض الموردين (سطر واحد لكل مورد في كل RFQ، الأسعار حسب البند)
CREATE TABLE IF NOT EXISTS proc_rfq_quotes (
  id          TEXT PRIMARY KEY,        -- = rfq_id || '__' || supplier-slug
  rfq_id      TEXT NOT NULL,
  supplier    TEXT NOT NULL,
  prices      JSONB DEFAULT '{}'::jsonb, -- { lineId: unitPrice }
  attrs       JSONB DEFAULT '{}'::jsonb, -- { delivery_days, quality(1-5), payment_days }
  note        TEXT,
  updated_by  TEXT,
  updated_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rfqq_rfq ON proc_rfq_quotes(rfq_id);

ALTER TABLE proc_rfq_quotes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON proc_rfq_quotes;
CREATE POLICY "auth_all" ON proc_rfq_quotes FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- إنشاء/تشغيل RFQ يُضبط بصلاحية can_manage_rfq في واجهة إدارة المستخدمين.

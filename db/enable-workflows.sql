-- ════════════════════════════════════════════════════════════════════
--  تفعيل وحدات سير العمل (اعتمادات + RFQ + بوابة المورّد + الإشعارات)
--  سكربت واحد مُجمّع — شغّله في Supabase SQL Editor (آمن لإعادة التشغيل)
--  المتطلّب: أن تكون proc_settings موجودة (من سكربت الأساس).
-- ════════════════════════════════════════════════════════════════════

-- ========== [1/3] الاعتمادات + الإشعارات ==========
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

-- ========== [2/3] طلبات عروض الأسعار (RFQ) ==========
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

-- ========== [3/3] بوابة المورّد + توسعة العروض ==========
-- ════════════════════════════════════════════════════════════════════════
--  بوابة المورّد لتقديم عروض الأسعار (RFQ Supplier Portal)
--  يقدّم المورّد عرضه عبر رابط برمز سرّي (token) — بلا حساب — كنمط secure-resume.
-- ════════════════════════════════════════════════════════════════════════
--  تُنفَّذ في Supabase → SQL Editor بعد db/rfq.sql.
-- ════════════════════════════════════════════════════════════════════════

-- توسعة جدول العروض: رمز الدعوة + حالة الاستجابة + طوابع زمنية
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS token        TEXT;
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS status       TEXT DEFAULT 'invited'; -- invited | opened | submitted
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS opened_at    TIMESTAMPTZ;
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS submitted_at TIMESTAMPTZ;
ALTER TABLE proc_rfq_quotes ADD COLUMN IF NOT EXISTS no_bid       JSONB DEFAULT '{}'::jsonb; -- {lineId:true} بنود لا يعرضها المورد
CREATE INDEX IF NOT EXISTS idx_rfqq_token ON proc_rfq_quotes(token);

-- 1) جلب RFQ للمورّد عبر الرمز (يكشف فقط ما يحتاجه المورّد، ويسجّل الفتح)
CREATE OR REPLACE FUNCTION get_rfq_for_supplier(p_rfq text, p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rfq proc_rfqs; v_q proc_rfq_quotes;
BEGIN
  IF p_rfq IS NULL OR p_token IS NULL OR length(p_token) < 8 THEN RETURN NULL; END IF;
  SELECT * INTO v_q FROM proc_rfq_quotes WHERE rfq_id = p_rfq AND token = p_token;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_rfq FROM proc_rfqs WHERE id = p_rfq;
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- سجّل أول فتح (دون تغيير حالة "مُقدَّم")
  UPDATE proc_rfq_quotes
     SET status = CASE WHEN status = 'submitted' THEN 'submitted' ELSE 'opened' END,
         opened_at = COALESCE(opened_at, now())
   WHERE id = v_q.id;
  RETURN jsonb_build_object(
    'rfq', jsonb_build_object('id',v_rfq.id,'title',v_rfq.title,'status',v_rfq.status,
                              'deadline',v_rfq.deadline,'lines',v_rfq.lines,'notes',v_rfq.notes),
    'supplier', v_q.supplier,
    'my_quote', jsonb_build_object('prices',v_q.prices,'attrs',v_q.attrs,'note',v_q.note,
                                   'no_bid',v_q.no_bid,'status',v_q.status)
  );
END; $$;

-- 2) تقديم/تحديث عرض المورّد (يتحقق من الرمز والحالة والموعد)
CREATE OR REPLACE FUNCTION submit_supplier_quote(p_rfq text, p_token text, p_prices jsonb, p_attrs jsonb, p_no_bid jsonb, p_note text, p_final boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rfq proc_rfqs; v_q proc_rfq_quotes;
BEGIN
  SELECT * INTO v_q FROM proc_rfq_quotes WHERE rfq_id = p_rfq AND token = p_token;
  IF NOT FOUND THEN RAISE EXCEPTION 'رمز غير صالح'; END IF;
  SELECT * INTO v_rfq FROM proc_rfqs WHERE id = p_rfq;
  IF v_rfq.status IN ('awarded','cancelled') THEN RAISE EXCEPTION 'الطلب مغلق'; END IF;
  IF v_rfq.deadline IS NOT NULL AND v_rfq.deadline < CURRENT_DATE THEN RAISE EXCEPTION 'انتهى الموعد'; END IF;
  UPDATE proc_rfq_quotes SET
     prices = COALESCE(p_prices,'{}'::jsonb),
     attrs  = COALESCE(p_attrs,'{}'::jsonb),
     no_bid = COALESCE(p_no_bid,'{}'::jsonb),
     note   = p_note,
     -- المسودة لا تُعلَّم «مُقدَّم» (تبقى opened) — فقط الإرسال النهائي
     status = CASE WHEN p_final THEN 'submitted'
                   WHEN status = 'submitted' THEN 'submitted' ELSE 'opened' END,
     submitted_at = CASE WHEN p_final THEN now() ELSE submitted_at END,
     updated_at = now()
   WHERE id = v_q.id;
  RETURN jsonb_build_object('ok', true);
END; $$;

REVOKE ALL ON FUNCTION get_rfq_for_supplier(text,text) FROM public;
REVOKE ALL ON FUNCTION submit_supplier_quote(text,text,jsonb,jsonb,jsonb,text,boolean) FROM public;
GRANT EXECUTE ON FUNCTION get_rfq_for_supplier(text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION submit_supplier_quote(text,text,jsonb,jsonb,jsonb,text,boolean) TO anon, authenticated;

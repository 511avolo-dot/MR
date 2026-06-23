-- ════════════════════════════════════════════════════════════════════════
--  بوابة طلبات الشراء (Purchase Request Portal) — P0: الأساس (المخطط)
--  بديل رقمي كامل لنموذج «طلب شراء مواد» الورقي/الإكسل — داخل Supabase.
-- ────────────────────────────────────────────────────────────────────────
--  تُنفَّذ مرة واحدة في Supabase → SQL Editor بعد إعداد Supabase Auth.
--  متّسقة مع بقية النظام: RLS «المصادَق عليهم» + التحكّم التفصيلي في التطبيق
--  عبر الصلاحيات (can_verify_stock / can_approve_l1 / can_manage_rfq /
--  can_approve_l2). محرّك سلسلة الاعتماد يعمل في التطبيق (مرحلة P2) قراءةً من
--  proc_approval_rules — فتعديل السلسلة = تعديل بيانات لا كود.
--  مبنية على حقول النموذج الفعلية: رأس الطلب + أعمدة البنود (الوحدة/كمية العقد/
--  رصيد مستودعي/الكمية المطلوبة/سعر الوحدة/الإجمالي/أخر تأمين) + سلسلة التواقيع
--  (الطالب ← أمين المستودع ← مدير المشروع/القطاع ← مسؤول المشتريات ← الاعتماد).
-- ════════════════════════════════════════════════════════════════════════

-- ════════════════ 1) الأقسام والهيكل التنظيمي (إدارة داخلية) ════════════════
CREATE TABLE IF NOT EXISTS proc_departments (
  id            TEXT PRIMARY KEY,              -- 'DEP-OPS' / 'DEP-MAINT'
  name_ar       TEXT NOT NULL,                 -- الإدارة / الإدارة العامة
  sector        TEXT,                          -- القطاع المرتبط (من PO_ENUMS.sector)
  cost_center   TEXT,                          -- مركز التكلفة (لربط مالي مستقبلي)
  manager_user  TEXT,                          -- مدير القسم/المشروع (المعتمِد L1) — soft link لـ proc_users.username
  active        BOOLEAN DEFAULT true,
  created_at    TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE proc_departments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON proc_departments;
CREATE POLICY "auth_all" ON proc_departments FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- توسيع المستخدمين ببيانات تنظيمية (متوافق مع الجداول القائمة)
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS department_id TEXT;   -- القسم
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS manager_user  TEXT;   -- مديره المباشر (resolver: user_manager)
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS delegate_to   TEXT;   -- نائب الاعتماد عند الغياب/الإجازة
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS job_title     TEXT;   -- المسمّى الوظيفي

-- ════════════════ 2) رأس طلب الشراء (مطابق لرأس النموذج) ════════════════
CREATE TABLE IF NOT EXISTS proc_purchase_requests (
  id              TEXT PRIMARY KEY,            -- 'PR-DG2026-0001'
  request_no      TEXT,                        -- رقم الطلب (كما في النموذج، إن خالف id)
  title           TEXT NOT NULL,               -- نوع/فئة المواد: «البوفية» «أغراض معيشة» ...
  addressee       TEXT,                        -- المخاطَب: «المدير العام» / «مدير إدارة سلاسل الإمداد»
  department_id   TEXT,                        -- soft link لـ proc_departments.id
  department      TEXT,                        -- الإدارة (نص حر كما في النموذج)
  sector          TEXT,                        -- القطاع
  project         TEXT,                        -- المشروع / الموقع (مثل «برج الابتكار»)
  requester       TEXT,                        -- الطالب (username)
  request_date    DATE,                        -- تاريخ الطلب
  needed_by       DATE,                        -- تاريخ التوريد المطلوب
  period_from     DATE,                        -- عن الفترة من (للتوريدات الدورية)
  period_to       DATE,                        -- إلى
  priority        TEXT DEFAULT 'متوسط',         -- عاجل/عالي/متوسط/منخفض
  justification   TEXT,                        -- مبرّر الحاجة/ملاحظات
  est_total       NUMERIC DEFAULT 0,           -- الإجمالي (مجموع البنود)
  total_in_words  TEXT,                        -- التفقيط (يُحسب في التطبيق: tafqitSAR)
  currency        TEXT DEFAULT 'SAR',
  status          TEXT NOT NULL DEFAULT 'draft',-- draft|in_review|returned|approved|rejected|rfq_issued|converted_to_po|cancelled
  current_seq     INT DEFAULT 0,               -- مؤشر المرحلة الحالية في السلسلة
  approval_rule_id BIGINT,                      -- القاعدة التي بنت السلسلة
  source          JSONB,                       -- {parsed_from:'doc', file:'storage/path', confidence:{...}}
  rfq_id          TEXT,                        -- يُملأ عند التحويل التلقائي (soft link لـ proc_rfqs.id)
  po_number       TEXT,                        -- يُملأ بعد الترسية (soft link لـ proc_purchase_orders.po_number)
  created_by      TEXT,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_by      TEXT,
  updated_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pr_status     ON proc_purchase_requests(status);
CREATE INDEX IF NOT EXISTS idx_pr_requester  ON proc_purchase_requests(requester);
CREATE INDEX IF NOT EXISTS idx_pr_dept       ON proc_purchase_requests(department_id);
CREATE INDEX IF NOT EXISTS idx_pr_created    ON proc_purchase_requests(created_at DESC);
-- بيانات مُقدّم الطلب من البوابة الخارجية (الدخول بحساب مخصّص)
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS requester_name   TEXT;  -- الاسم المُدخَل
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS requester_mobile TEXT;  -- الجوال للتواصل
ALTER TABLE proc_purchase_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON proc_purchase_requests;
CREATE POLICY "auth_all" ON proc_purchase_requests FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ════════════════ 3) بنود الطلب (مطابقة لأعمدة جدول النموذج) ════════════════
CREATE TABLE IF NOT EXISTS proc_pr_items (
  id            BIGSERIAL PRIMARY KEY,
  pr_id         TEXT NOT NULL REFERENCES proc_purchase_requests(id) ON DELETE CASCADE,
  seq           INT,                           -- م
  item_code     TEXT,                          -- ربط بالكتالوج proc_items (اختياري)
  description   TEXT NOT NULL,                 -- إسم الصنف
  -- تُعبّأ من طرف الموقع/الطالب:
  unit          TEXT,                          -- الوحدة
  contract_qty  NUMERIC,                       -- كمية العقد
  stock_balance NUMERIC,                       -- رصيد مستودعي
  requested_qty NUMERIC NOT NULL DEFAULT 0,    -- الكمية المطلوبة
  -- تُعبّأ من طرف إدارة المشتريات:
  unit_price    NUMERIC,                       -- سعر الوحدة
  line_total    NUMERIC,                       -- إجمالي السعر (الكمية × سعر الوحدة) — يُحسب في التطبيق
  -- أخر تأمين (مرجعي):
  last_supply   JSONB,                         -- {unit, qty, date}
  category      TEXT,
  notes         TEXT
);
CREATE INDEX IF NOT EXISTS idx_pritems_pr ON proc_pr_items(pr_id);
ALTER TABLE proc_pr_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON proc_pr_items;
CREATE POLICY "auth_all" ON proc_pr_items FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ════════════════ 4) سجل الاعتمادات (مسار التدقيق خطوة بخطوة) ════════════════
CREATE TABLE IF NOT EXISTS proc_pr_approvals (
  id          BIGSERIAL PRIMARY KEY,
  pr_id       TEXT NOT NULL REFERENCES proc_purchase_requests(id) ON DELETE CASCADE,
  seq         INT NOT NULL,                    -- ترتيب المرحلة (1..N)
  stage_label TEXT,                            -- «أمين المستودع» «مدير المشروع/القطاع» «مسؤول المشتريات» «الاعتماد»
  resolver    TEXT,                            -- dept_manager | user_manager | role
  role_key    TEXT,                            -- can_verify_stock | can_approve_l1 | can_manage_rfq | can_approve_l2
  approver    TEXT,                            -- المعتمِد المُحلّ/الفعلي (username)
  decision    TEXT DEFAULT 'pending',          -- pending|approved|rejected|returned
  comment     TEXT,
  acted_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_prappr_pr ON proc_pr_approvals(pr_id);
ALTER TABLE proc_pr_approvals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON proc_pr_approvals;
CREATE POLICY "auth_all" ON proc_pr_approvals FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ════════════════ 5) مرفقات الطلب (النموذج الأصلي + ناتج OCR) ════════════════
CREATE TABLE IF NOT EXISTS proc_pr_attachments (
  id           BIGSERIAL PRIMARY KEY,
  pr_id        TEXT NOT NULL REFERENCES proc_purchase_requests(id) ON DELETE CASCADE,
  storage_path TEXT,                           -- Supabase Storage
  kind         TEXT,                           -- source_form | quote | support
  ocr_json     JSONB,                          -- ناتج الاستخراج الخام
  created_at   TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_prattach_pr ON proc_pr_attachments(pr_id);
ALTER TABLE proc_pr_attachments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON proc_pr_attachments;
CREATE POLICY "auth_all" ON proc_pr_attachments FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ════════════════ 6) محرّك قواعد الاعتماد القابل للتهيئة ════════════════
-- كل قاعدة تُطابَق بـ(القسم/الفئة/نطاق القيمة) وتُنتج سلسلة مراحل مرتّبة.
-- المحرّك في التطبيق يختار أعلى قاعدة أولوية مطابِقة ويبني صفوف proc_pr_approvals.
CREATE TABLE IF NOT EXISTS proc_approval_rules (
  id            BIGSERIAL PRIMARY KEY,
  name          TEXT,
  active        BOOLEAN DEFAULT true,
  priority      INT DEFAULT 100,               -- الأدنى يُطابَق أولاً
  department_id TEXT,                          -- NULL = أي قسم
  category      TEXT,                          -- NULL = أي فئة
  min_total     NUMERIC DEFAULT 0,
  max_total     NUMERIC,                       -- NULL = بلا حد أعلى
  stages        JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at    TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE proc_approval_rules ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON proc_approval_rules;
CREATE POLICY "auth_all" ON proc_approval_rules FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- بذور القواعد — مستمدّة من سلسلة تواقيع النموذج الفعلي:
--   الطالب (ضمني) ← أمين المستودع ← مدير المشروع/القطاع ← مسؤول المشتريات ← الاعتماد (المدير العام)
INSERT INTO proc_approval_rules (name, priority, min_total, max_total, stages)
SELECT 'السلسلة القياسية (كل الطلبات)', 100, 0, NULL,
  '[
    {"seq":1,"label":"أمين المستودع","resolver":"role","role_key":"can_verify_stock"},
    {"seq":2,"label":"مدير المشروع/القطاع","resolver":"dept_manager","role_key":"can_approve_l1"},
    {"seq":3,"label":"مسؤول المشتريات","resolver":"role","role_key":"can_manage_rfq"},
    {"seq":4,"label":"الاعتماد (المدير العام)","resolver":"role","role_key":"can_approve_l2"}
  ]'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM proc_approval_rules WHERE name='السلسلة القياسية (كل الطلبات)');

-- قاعدة المشتريات الصغيرة (≤ 1000 ر.س): تخطّي المستودع والمدير العام لتسريع الدورة
INSERT INTO proc_approval_rules (name, priority, min_total, max_total, stages)
SELECT 'مشتريات صغيرة (≤ 1000)', 10, 0, 1000,
  '[
    {"seq":1,"label":"مدير المشروع/القطاع","resolver":"dept_manager","role_key":"can_approve_l1"},
    {"seq":2,"label":"مسؤول المشتريات","resolver":"role","role_key":"can_manage_rfq"}
  ]'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM proc_approval_rules WHERE name='مشتريات صغيرة (≤ 1000)');

-- ════════════════ 7) رموز الاعتماد من داخل البريد (lحظة واحدة، موقّعة) ════════════════
--  تحصين أمني: هذا الجدول يُمكّن الاعتماد بنقرة من داخل البريد دون فتح البوابة.
--  • RLS مُفعّل بلا أي سياسة ⇒ لا وصول إطلاقاً من العميل (anon/authenticated).
--    الخادم فقط (service-role، يتجاوز RLS) يقرأ/يكتب الرموز. حتى لو سُرّب رمز،
--    لا يمكن للمهاجم قراءة الجدول أو تزويره؛ والرمز عشوائي 256-بت لمرة واحدة وبصلاحية زمنية.
--  • نطاق الضرر محصور: الرمز يخصّ (طلب + مرحلة + معتمِد) واحد فقط، يُبطَل فور الاستخدام،
--    ولا يمنح أي صلاحية على القاعدة أو النظام الأساسي.
CREATE TABLE IF NOT EXISTS proc_email_tokens (
  token       TEXT PRIMARY KEY,                 -- عشوائي 256-بت (base62)
  pr_id       TEXT NOT NULL REFERENCES proc_purchase_requests(id) ON DELETE CASCADE,
  seq         INT  NOT NULL,                     -- مرحلة الاعتماد المستهدفة
  approver    TEXT NOT NULL,                     -- اسم المستخدم المخوّل لهذا الرمز
  used        BOOLEAN DEFAULT false,
  used_at     TIMESTAMPTZ,
  expires_at  TIMESTAMPTZ NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_prtok_pr ON proc_email_tokens(pr_id);
ALTER TABLE proc_email_tokens ENABLE ROW LEVEL SECURITY;
-- لا CREATE POLICY هنا عمداً: RLS مفعّل بلا سياسة = رفض كل وصول من العميل.

-- قناة الاعتماد لكل صفّ (portal | email) — لأغراض التدقيق والعرض.
ALTER TABLE proc_pr_approvals ADD COLUMN IF NOT EXISTS channel TEXT;

-- ════════════════════════════════════════════════════════════════════════
--  التحديث اللحظي (Realtime) — يُفعَّل تلقائياً وبأمان (idempotent) بعد إنشاء الجداول.
--  ملاحظة: لا تُشغّل أوامر ALTER PUBLICATION منفصلةً قبل إنشاء الجداول — هذا الملف
--  يتكفّل بالترتيب الصحيح، وآمن لإعادة التشغيل أكثر من مرة.
-- ════════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname='supabase_realtime') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='proc_purchase_requests') THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE proc_purchase_requests;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='proc_pr_approvals') THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE proc_pr_approvals;
    END IF;
  END IF;
END $$;
-- ════════════════════════════════════════════════════════════════════════
--  ملاحظة أمنية (مرحلة لاحقة اختيارية): يمكن تحصين انتقالات الاعتماد بدوال
--  Postgres RPC (SECURITY DEFINER) تفرض «المعتمِد الصحيح + فصل المهام» على
--  الخادم، تماماً كطبقة hardened-rls.sql الاختيارية. حالياً يُفرض ذلك في التطبيق
--  اتساقاً مع نمط النظام القائم (PO/RFQ).
-- ════════════════════════════════════════════════════════════════════════

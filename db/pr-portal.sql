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
--  8) آلة الحالة على الخادم — تحصين سلسلة الاعتماد (Phase 2)
-- ════════════════════════════════════════════════════════════════════════
--  الفكرة (تحصين متوازن لا يكسر شيئاً):
--   • القرار (اعتماد/رفض/إرجاع) لا يُكتب مباشرةً من العميل بعد الآن؛ يمرّ حصراً
--     عبر الدالة pr_transition (SECURITY DEFINER) التي تتحقّق على الخادم من:
--       - هوية المُعتمِد (من JWT) = المُعتمِد المُحلّ لهذه المرحلة، أو أدمن،
--       - فصل المهام (الطالب ≠ المُعتمِد)،
--       - أن الطلب قيد المراجعة وأن المرحلة هي المعلّقة الحالية.
--   • محرّسان (triggers) يمنعان أي عميل من:
--       - قلب proc_pr_approvals.decision إلى قرار مباشرةً،
--       - أو دفع proc_purchase_requests.status إلى approved/rejected/returned مباشرةً،
--     إلا عبر الدالة الموثوقة (التي تضبط علامة الجلسة) أو دور الخادم service_role
--     (مسار البريد) أو أدمن. بقية الحقول/الحالات (مسودة/مراجعة/تسعير…) تبقى كما هي.
--   ⇒ حتى لو سُرّبت بيانات دخول بوابة (مستخدم عادي) لا يمكن اعتماد أي طلب أو
--     تجاوز السلسلة؛ نطاق الضرر محصور تماماً.
--  آمن لإعادة التشغيل (CREATE OR REPLACE / DROP TRIGGER IF EXISTS).

-- اسم المستخدم الحالي من JWT (يطابق خريطة البريد في التطبيق) — يؤكّد وجود مستخدم نشط.
CREATE OR REPLACE FUNCTION pr_username() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_email text := lower(coalesce(auth.jwt() ->> 'email','')); v_uname text;
BEGIN
  IF v_email = '' THEN RETURN NULL; END IF;
  v_uname := CASE v_email
    WHEN 'supply@aldeyabi.com'   THEN 'mostafa'
    WHEN 'abdullah@aldeyabi.com' THEN 'abdullah'
    WHEN 'mahmoud@aldeyabi.com'  THEN 'mahmoud'
    ELSE split_part(v_email,'@',1) END;
  RETURN (SELECT username FROM proc_users
            WHERE lower(username)=lower(v_uname) AND coalesce(active,true) LIMIT 1);
END $fn$;

CREATE OR REPLACE FUNCTION pr_is_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS(SELECT 1 FROM proc_users
                WHERE lower(username)=lower(pr_username()) AND role='admin' AND coalesce(active,true));
$fn$;

-- هل الطلب صادر من دور الخادم (service_role)؟ مسار البريد يعتمد عليه ويُسمح له.
CREATE OR REPLACE FUNCTION pr_is_service() RETURNS boolean
LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role','') = 'service_role';
$fn$;

-- محرس صفوف الاعتماد: يمنع كتابة قرار مباشرةً (إلا الدالة الموثوقة/الخادم/أدمن).
CREATE OR REPLACE FUNCTION pr_guard_approval() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF pr_is_service() THEN RETURN NEW; END IF;
  IF current_setting('app.pr_transition', true) = '1' THEN RETURN NEW; END IF;
  IF NEW.decision IS NOT NULL AND NEW.decision <> 'pending' THEN
    IF NOT pr_is_admin() THEN
      RAISE EXCEPTION 'تُتخذ قرارات الاعتماد عبر سلسلة الموافقات فقط';
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

-- محرس رأس الطلب: يمنع بلوغ حالات القرار (approved/rejected/returned) مباشرةً.
CREATE OR REPLACE FUNCTION pr_guard_status() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF pr_is_service() THEN RETURN NEW; END IF;
  IF current_setting('app.pr_transition', true) = '1' THEN RETURN NEW; END IF;
  IF NEW.status IN ('approved','rejected','returned')
     AND (TG_OP='INSERT' OR NEW.status IS DISTINCT FROM OLD.status) THEN
    IF NOT pr_is_admin() THEN
      RAISE EXCEPTION 'حالة الاعتماد تُحدَّث عبر سلسلة الموافقات فقط';
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_pr_guard_approval ON proc_pr_approvals;
CREATE TRIGGER trg_pr_guard_approval BEFORE INSERT OR UPDATE ON proc_pr_approvals
  FOR EACH ROW EXECUTE FUNCTION pr_guard_approval();
DROP TRIGGER IF EXISTS trg_pr_guard_status ON proc_purchase_requests;
CREATE TRIGGER trg_pr_guard_status BEFORE INSERT OR UPDATE ON proc_purchase_requests
  FOR EACH ROW EXECUTE FUNCTION pr_guard_status();

-- الدالة الموثوقة: تنفيذ قرار على المرحلة المعلّقة الحالية (تحقّق كامل على الخادم).
CREATE OR REPLACE FUNCTION pr_transition(p_pr_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := pr_username();
  v_pr proc_purchase_requests%ROWTYPE;
  v_stage proc_pr_approvals%ROWTYPE;
  v_pending int; v_next int; v_decision text; v_status text; v_seq int;
  v_ok boolean := false; v_intended text; v_perm boolean;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id = p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_pr.status <> 'in_review' THEN RAISE EXCEPTION 'الطلب ليس قيد المراجعة'; END IF;

  SELECT * INTO v_stage FROM proc_pr_approvals
    WHERE pr_id = p_pr_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة معلّقة'; END IF;

  IF v_pr.requester = v_me THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;

  -- تخويل: المُعتمِد المُحلّ لهذه المرحلة، أو مفوَّضه عند الغياب، أو أدمن.
  v_intended := NULL;
  IF v_stage.approver IS NOT NULL THEN
    v_intended := v_stage.approver; v_ok := (v_intended = v_me);
  ELSIF v_stage.resolver = 'dept_manager' THEN
    SELECT manager_user INTO v_intended FROM proc_departments WHERE id = v_pr.department_id;
    v_ok := (v_intended = v_me);
  ELSIF v_stage.role_key IS NOT NULL THEN
    SELECT coalesce((permissions->>v_stage.role_key)::boolean,false) INTO v_perm
      FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
    v_ok := coalesce(v_perm,false);
  END IF;
  -- التفويض: يعتمد المفوَّض بالنيابة عن مُعتمِد مُحدَّد في إجازة.
  IF NOT v_ok AND v_intended IS NOT NULL THEN
    SELECT (coalesce(is_away,false) AND lower(coalesce(delegate_to,''))=lower(v_me))
      INTO v_ok FROM proc_users WHERE lower(username)=lower(v_intended) LIMIT 1;
    v_ok := coalesce(v_ok,false);
  END IF;
  IF NOT v_ok AND NOT pr_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action IN ('reject','return') AND coalesce(btrim(p_comment),'') = '' THEN
    RAISE EXCEPTION 'السبب مطلوب';
  END IF;

  v_decision := CASE p_action WHEN 'approve' THEN 'approved'
                              WHEN 'reject'  THEN 'rejected' ELSE 'returned' END;
  SELECT count(*) INTO v_pending FROM proc_pr_approvals WHERE pr_id=p_pr_id AND decision='pending';
  v_status := v_pr.status; v_seq := v_pr.current_seq;
  IF p_action='approve' THEN
    IF v_pending <= 1 THEN v_status := 'approved';
    ELSE
      SELECT seq INTO v_next FROM proc_pr_approvals
        WHERE pr_id=p_pr_id AND decision='pending' AND seq > v_stage.seq ORDER BY seq ASC LIMIT 1;
      v_seq := coalesce(v_next, v_pr.current_seq);
    END IF;
  ELSIF p_action='reject' THEN v_status := 'rejected';
  ELSE v_status := 'returned'; v_seq := 0; END IF;

  PERFORM set_config('app.pr_transition','1', true);  -- علامة جلسة محلية للمعاملة (تسمح للمحرّسين)

  UPDATE proc_pr_approvals
     SET decision=v_decision, approver=v_me, comment=p_comment, acted_at=now(), channel='portal'
     WHERE pr_id=p_pr_id AND seq=v_stage.seq;
  UPDATE proc_purchase_requests
     SET status=v_status, current_seq=v_seq, updated_at=now(), updated_by=v_me
     WHERE id=p_pr_id;

  RETURN jsonb_build_object('ok',true,'action',p_action,'decision',v_decision,
           'status',v_status,'finalized', v_status <> 'in_review','seq', v_stage.seq);
END $fn$;

GRANT EXECUTE ON FUNCTION pr_username()                       TO authenticated;
GRANT EXECUTE ON FUNCTION pr_is_admin()                       TO authenticated;
GRANT EXECUTE ON FUNCTION pr_is_service()                     TO authenticated;
GRANT EXECUTE ON FUNCTION pr_transition(text, text, text)     TO authenticated;

-- ════════════════════════════════════════════════════════════════════════
--  9) مهلة الاعتماد (SLA) + التصعيد التلقائي + التفويض (Phase 3)
-- ════════════════════════════════════════════════════════════════════════
--  • كل مرحلة لها مهلة (افتراضي من إعدادات البوابة sla_days، أو 3 أيام) تُحفظ في
--    stage_due_at؛ يُعاد ضبطها تلقائياً عند دخول المراجعة أو الانتقال لمرحلة تالية.
--  • مهمة دورية (pg_cron) تستدعي pr_run_sla() التي تُنشئ تنبيهات داخلية للمُعتمِد
--    المتأخّر (ومفوَّضه عند الغياب) وللأدمن، وتزيد عدّاد التصعيد — دون لمس الحالة.
--  • التفويض: عند ضبط المستخدم is_away مع delegate_to، يَعتمد المفوَّض بالنيابة
--    (مفروضٌ على الخادم في pr_transition، ويُوجَّه إليه البريد/التنبيه).
--  آمن لإعادة التشغيل.

ALTER TABLE proc_users            ADD COLUMN IF NOT EXISTS is_away            BOOLEAN DEFAULT false;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS stage_due_at      TIMESTAMPTZ;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS escalations       INT DEFAULT 0;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS escalated_at      TIMESTAMPTZ;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS last_escalation_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_pr_due ON proc_purchase_requests(stage_due_at) WHERE status='in_review';

-- مهلة المرحلة بالساعات (من إعدادات البوابة، أو 72 ساعة).
CREATE OR REPLACE FUNCTION pr_sla_hours() RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce(
    nullif((SELECT value->>'sla_days' FROM proc_settings WHERE key='portal_settings'),'')::numeric * 24,
    72);
$fn$;

-- يضبط موعد استحقاق المرحلة عند الدخول للمراجعة أو الانتقال؛ ويُفرغه عند الخروج.
CREATE OR REPLACE FUNCTION pr_set_due() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE v_h numeric := pr_sla_hours();
BEGIN
  IF NEW.status = 'in_review' THEN
    IF TG_OP='INSERT'
       OR OLD.status IS DISTINCT FROM 'in_review'
       OR NEW.current_seq IS DISTINCT FROM OLD.current_seq THEN
      NEW.stage_due_at := now() + make_interval(hours => v_h);
    END IF;
  ELSE
    NEW.stage_due_at := NULL;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_pr_set_due ON proc_purchase_requests;
CREATE TRIGGER trg_pr_set_due BEFORE INSERT OR UPDATE ON proc_purchase_requests
  FOR EACH ROW EXECUTE FUNCTION pr_set_due();

-- التصعيد الدوري: تنبيهات للمُعتمِد المتأخّر (+ مفوَّضه) وللأدمن. لا يُغيّر الحالة.
CREATE OR REPLACE FUNCTION pr_run_sla() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_sla numeric := pr_sla_hours();
  v_pr record; v_stage record; v_intended text; v_away boolean; v_deleg text;
  v_admin text; v_n int := 0; v_body text;
  fn_nid text;
BEGIN
  FOR v_pr IN
    SELECT * FROM proc_purchase_requests
     WHERE status='in_review' AND stage_due_at IS NOT NULL AND stage_due_at < now()
       AND (last_escalation_at IS NULL OR last_escalation_at < now() - make_interval(hours => v_sla))
  LOOP
    SELECT * INTO v_stage FROM proc_pr_approvals
      WHERE pr_id=v_pr.id AND decision='pending' ORDER BY seq ASC LIMIT 1;
    CONTINUE WHEN NOT FOUND;
    v_body := v_pr.id || ' — ' || coalesce(v_pr.title,'طلب شراء') || ' (تجاوز المهلة)';

    v_intended := NULL;
    IF v_stage.approver IS NOT NULL THEN v_intended := v_stage.approver;
    ELSIF v_stage.resolver='dept_manager' THEN
      SELECT manager_user INTO v_intended FROM proc_departments WHERE id=v_pr.department_id;
    END IF;

    IF v_intended IS NOT NULL THEN
      fn_nid := 'ntf_'||floor(extract(epoch from clock_timestamp()))||'_'||substr(md5(random()::text),1,6)||'_'||v_intended;
      INSERT INTO proc_notifications(id,recipient,type,title,body,link,read)
        VALUES(fn_nid, v_intended,'system','تذكير: طلب متأخّر بانتظار اعتمادك', v_body, 'inbox', false)
        ON CONFLICT DO NOTHING;
      SELECT coalesce(is_away,false), delegate_to INTO v_away, v_deleg
        FROM proc_users WHERE lower(username)=lower(v_intended) LIMIT 1;
      IF v_away AND v_deleg IS NOT NULL THEN
        fn_nid := 'ntf_'||floor(extract(epoch from clock_timestamp()))||'_'||substr(md5(random()::text),1,6)||'_'||v_deleg;
        INSERT INTO proc_notifications(id,recipient,type,title,body,link,read)
          VALUES(fn_nid, v_deleg,'system','تفويض: طلب متأخّر بانتظار اعتمادك (بالنيابة)', v_body, 'inbox', false)
          ON CONFLICT DO NOTHING;
      END IF;
    END IF;

    FOR v_admin IN SELECT username FROM proc_users WHERE role='admin' AND coalesce(active,true) LOOP
      fn_nid := 'ntf_'||floor(extract(epoch from clock_timestamp()))||'_'||substr(md5(random()::text),1,6)||'_'||v_admin;
      INSERT INTO proc_notifications(id,recipient,type,title,body,link,read)
        VALUES(fn_nid, v_admin,'system','تصعيد SLA: طلب متأخّر', v_body, 'inbox', false)
        ON CONFLICT DO NOTHING;
    END LOOP;

    UPDATE proc_purchase_requests
       SET escalations = coalesce(escalations,0)+1,
           escalated_at = coalesce(escalated_at, now()),
           last_escalation_at = now()
       WHERE id = v_pr.id;
    INSERT INTO proc_pr_audit(pr_id, seq, event, actor, channel, detail)
      VALUES(v_pr.id, v_stage.seq, 'escalated', NULL, 'system',
             jsonb_build_object('intended', v_intended, 'stage_label', v_stage.stage_label));
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $fn$;

GRANT EXECUTE ON FUNCTION pr_sla_hours() TO authenticated;

-- جدولة دورية كل 30 دقيقة عبر pg_cron (إن كان مفعّلاً في المشروع) — آمن لإعادة التشغيل.
-- إن لم يكن pg_cron مفعّلاً: فعّله من Supabase ▸ Database ▸ Extensions ثم أعد تشغيل هذا الملف،
-- أو استدعِ pr_run_sla() يدوياً/عبر مجدول خارجي.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname='pr-sla') THEN
      PERFORM cron.unschedule('pr-sla');
    END IF;
    PERFORM cron.schedule('pr-sla', '*/30 * * * *', 'SELECT pr_run_sla();');
  END IF;
END $$;

-- ════════════════════════════════════════════════════════════════════════
--  10) سجلّ التدقيق + الخط الزمني الموحّد للطلب (Phase 4)
-- ════════════════════════════════════════════════════════════════════════
--  سجلّ «لا يُعدَّل» يلتقط كل حدث في دورة حياة الطلب (إنشاء/إرسال/اعتماد كل
--  مرحلة/رفض/إرجاع/تصعيد/اعتماد نهائي…) آلياً عبر المحرّسات — مهما كان المصدر
--  (بوابة/بريد/نظام أساسي). نطاق النظام = ضبط الطلبات؛ أحداث ما بعد الاعتماد
--  (عروض الأسعار/الترسية/أمر الشراء) تُسجَّل كمراجع اختيارية فقط إن تمّت داخل النظام.
--  • RLS: القراءة متاحة للمصادَق عليهم؛ لا سياسات كتابة للعميل ⇒ يُكتب حصراً عبر
--    المحرّسات (SECURITY DEFINER) ولا يُعدَّل/يُحذف من أي عميل (سجلّ تدقيق نزيه).
CREATE TABLE IF NOT EXISTS proc_pr_audit (
  id         BIGSERIAL PRIMARY KEY,
  pr_id      TEXT NOT NULL REFERENCES proc_purchase_requests(id) ON DELETE CASCADE,
  seq        INT,
  event      TEXT NOT NULL,                  -- created|submitted|stage_approved|stage_rejected|stage_returned|approved|rejected|returned|escalated|rfq_issued|converted_to_po|cancelled
  actor      TEXT,                            -- منفّذ الحدث (username)
  channel    TEXT,                            -- portal|email|system
  detail     JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_praudit_pr ON proc_pr_audit(pr_id, created_at);
ALTER TABLE proc_pr_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "audit_read" ON proc_pr_audit;
CREATE POLICY "audit_read" ON proc_pr_audit FOR SELECT TO authenticated USING (true);
-- لا سياسات INSERT/UPDATE/DELETE عمداً: الكتابة عبر المحرّسات فقط، والسجل غير قابل للتعديل/الحذف من العميل.

-- محرس رأس الطلب: يسجّل الإنشاء/الإرسال وكل تغيّر حالة.
CREATE OR REPLACE FUNCTION pr_audit_status() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF TG_OP='INSERT' THEN
    INSERT INTO proc_pr_audit(pr_id, seq, event, actor, channel, detail)
      VALUES(NEW.id, NEW.current_seq,
             CASE WHEN NEW.status='in_review' THEN 'submitted' ELSE 'created' END,
             coalesce(NEW.created_by, NEW.requester), 'portal',
             jsonb_build_object('status', NEW.status, 'title', NEW.title));
    RETURN NEW;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO proc_pr_audit(pr_id, seq, event, actor, channel, detail)
      VALUES(NEW.id, NEW.current_seq, NEW.status, coalesce(NEW.updated_by, OLD.updated_by), NULL,
             jsonb_build_object('from', OLD.status, 'to', NEW.status));
  END IF;
  -- مراحل معالجة المشتريات (بدء العمل / إتمام جمع العروض) — تُسجَّل في الخط الزمني.
  IF NEW.proc_status IS DISTINCT FROM OLD.proc_status AND NEW.proc_status IS NOT NULL THEN
    INSERT INTO proc_pr_audit(pr_id, seq, event, actor, channel, detail)
      VALUES(NEW.id, NEW.current_seq, 'proc_'||NEW.proc_status, coalesce(NEW.updated_by, OLD.updated_by), 'procurement',
             jsonb_build_object('proc_status', NEW.proc_status));
  END IF;
  RETURN NEW;
END $fn$;

-- محرس صفوف الاعتماد: يسجّل قرار كل مرحلة (اعتماد/رفض/إرجاع) مع الملاحظة والقناة.
CREATE OR REPLACE FUNCTION pr_audit_approval() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NEW.decision IS DISTINCT FROM OLD.decision AND NEW.decision <> 'pending' THEN
    INSERT INTO proc_pr_audit(pr_id, seq, event, actor, channel, detail)
      VALUES(NEW.pr_id, NEW.seq, 'stage_'||NEW.decision, NEW.approver, NEW.channel,
             jsonb_build_object('stage_label', NEW.stage_label, 'comment', NEW.comment));
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_pr_audit_status ON proc_purchase_requests;
CREATE TRIGGER trg_pr_audit_status AFTER INSERT OR UPDATE ON proc_purchase_requests
  FOR EACH ROW EXECUTE FUNCTION pr_audit_status();
DROP TRIGGER IF EXISTS trg_pr_audit_approval ON proc_pr_approvals;
CREATE TRIGGER trg_pr_audit_approval AFTER UPDATE ON proc_pr_approvals
  FOR EACH ROW EXECUTE FUNCTION pr_audit_approval();

-- ════════════════════════════════════════════════════════════════════════
--  11) معالجة المشتريات بعد الاعتماد (استلام / بدء العمل / جمع العروض)
-- ════════════════════════════════════════════════════════════════════════
--  نطاق خفيف: النظام يستلم الطلب المعتمد ويتتبّع تنفيذه دون فرض آلية شراء.
--  proc_status: (فارغ=وارد) → in_progress (بدأ العمل) → quotes_collected (تم جمع العروض).
--  تُسجَّل التحوّلات آلياً في الخط الزمني عبر محرس pr_audit_status (أعلاه).
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS proc_status         TEXT;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS proc_started_by     TEXT;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS proc_started_at     TIMESTAMPTZ;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS quotes_collected_by TEXT;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS quotes_collected_at TIMESTAMPTZ;
-- ════════════════════════════════════════════════════════════════════════

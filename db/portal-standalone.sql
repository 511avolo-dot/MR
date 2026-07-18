-- ════════════════════════════════════════════════════════════════════════
--  بوابة طلبات الشراء والموافقات — نظام مستقل تماماً (كل الكائنات portal_*)
-- ════════════════════════════════════════════════════════════════════════
--  معزول بالكامل عن الجداول والدوال proc_* التي يستخدمها index.html:
--    • لا مفتاح خارجي لأي جدول proc_*.
--    • لا استدعاء لأي دالة proc_*/pr_* قائمة.
--    • كل الجداول/الدوال/المحارس بأسماء portal_* فريدة (لا تصادم أسماء).
--  index.html لا يعرف بوجود هذه الكائنات ولا يتأثر بها إطلاقاً.
--
--  المعمارية (بنفس مستوى الأمان المُثبَت في db/pr-portal.sql):
--    • RPC واحدة ذرّية SECURITY DEFINER لكل انتقال حالة (قفل صفوف FOR UPDATE،
--      تحقّق صلاحية على الخادم، تحديث ذرّي، تدقيق).
--    • محارس (Triggers) تمنع أي كتابة مباشرة لحقول القرار من غير RPC/الخادم.
--    • سجل تدقيق append-only حقيقي (محرّس صريح يمنع UPDATE/DELETE حتى من
--      service_role — تحصين أقوى من الجدول المشابه القائم).
--    • رموز اعتماد من البريد لمرة واحدة (RLS بلا سياسة — خادم فقط).
--
--  التشغيل: Supabase → SQL Editor، مرة واحدة (آمن لإعادة التشغيل بالكامل).
--  التراجع الفوري: انظر كتلة ROLLBACK في نهاية الملف.
-- ════════════════════════════════════════════════════════════════════════

-- pgcrypto لتوليد رموز البريد العشوائية (مُفعَّلة افتراضياً في Supabase غالباً؛
-- التصريح هنا يضمن عملها بغضّ النظر عن حالة المشروع).
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ═══════════════════════ 1) الجداول ═══════════════════════

-- المستخدمون (منفصل تماماً عن proc_users) — الدخول عبر Supabase Auth (نفس
-- المشروع)، لكن الملف التعريفي/الصلاحيات هنا حصراً.
CREATE TABLE IF NOT EXISTS portal_users (
  username        TEXT PRIMARY KEY,
  email           TEXT UNIQUE NOT NULL,
  display_name    TEXT NOT NULL,
  role            TEXT NOT NULL DEFAULT 'user',           -- admin | user
  permissions     JSONB NOT NULL DEFAULT '{}'::jsonb,      -- can_manage_users/can_manage_procurement/can_disburse/can_verify_stock/can_manage_company
  department_id   TEXT,
  job_key         TEXT,
  manager_user    TEXT REFERENCES portal_users(username),
  delegate_to     TEXT REFERENCES portal_users(username),
  is_away         BOOLEAN NOT NULL DEFAULT false,
  active          BOOLEAN NOT NULL DEFAULT true,
  created_by      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_users_email ON portal_users(lower(email));

CREATE TABLE IF NOT EXISTS portal_departments (
  id            TEXT PRIMARY KEY,
  name_ar       TEXT NOT NULL,
  sector        TEXT,
  manager_user  TEXT REFERENCES portal_users(username),
  cost_center   TEXT,
  active        BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'portal_users_dept_fk') THEN
    ALTER TABLE portal_users ADD CONSTRAINT portal_users_dept_fk
      FOREIGN KEY (department_id) REFERENCES portal_departments(id) DEFERRABLE INITIALLY DEFERRED;
  END IF;
END $$;

-- كتالوج الوظائف (نموذج مبسّط وقابل للتعديل من لوحة الإدارة — بديل خفيف
-- لمصمّم السحب والإفلات؛ الصلاحية الفعلية دائماً من portal_users.permissions).
CREATE TABLE IF NOT EXISTS portal_jobs (
  key           TEXT PRIMARY KEY,
  title         TEXT NOT NULL,
  category      TEXT,
  scope         TEXT NOT NULL DEFAULT 'own',               -- own | sector | all (وصفي للواجهة فقط)
  permissions   JSONB NOT NULL DEFAULT '{}'::jsonb,         -- قالب صلاحيات مقترح يطبّقه الأدمن عند الإسناد
  description   TEXT,
  active        BOOLEAN NOT NULL DEFAULT true
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'portal_users_job_fk') THEN
    ALTER TABLE portal_users ADD CONSTRAINT portal_users_job_fk
      FOREIGN KEY (job_key) REFERENCES portal_jobs(key) DEFERRABLE INITIALLY DEFERRED;
  END IF;
END $$;

-- مصفوفة صلاحيات التعميد (DoA) — الدورة الثانية، حسب قيمة العرض الفائز.
CREATE TABLE IF NOT EXISTS portal_doa (
  id                  BIGSERIAL PRIMARY KEY,
  max_value           NUMERIC,                              -- NULL = بلا حدّ أعلى
  quotes_required     INT NOT NULL DEFAULT 3,
  committee_required  BOOLEAN NOT NULL DEFAULT false,
  award_role_key      TEXT NOT NULL,                        -- مفتاح صلاحية معتمِد التعميد لهذه الشريحة
  po_role_key         TEXT NOT NULL DEFAULT 'can_manage_procurement',
  po_committee        BOOLEAN NOT NULL DEFAULT false,       -- سلسلة أمر الشراء تشمل اللجنة المصغّرة
  po_finance          BOOLEAN NOT NULL DEFAULT false,       -- ... والمدير المالي
  po_gm               BOOLEAN NOT NULL DEFAULT false,       -- ... والمدير العام
  label               TEXT,
  note                TEXT,
  priority            INT NOT NULL DEFAULT 100
);

-- قوالب سلسلة الموافقة الديناميكية (الدورة الأولى — الحاجة).
CREATE TABLE IF NOT EXISTS portal_workflows (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  priority      INT NOT NULL DEFAULT 100,
  department_id TEXT REFERENCES portal_departments(id),
  sector        TEXT,
  min_total     NUMERIC NOT NULL DEFAULT 0,
  max_total     NUMERIC,
  stages        JSONB NOT NULL DEFAULT '[]'::jsonb,          -- [{seq,label,resolver,role_key,approver}]
  active        BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- رأس الطلب.
CREATE TABLE IF NOT EXISTS portal_requests (
  id              TEXT PRIMARY KEY,
  title           TEXT NOT NULL,
  department_id   TEXT REFERENCES portal_departments(id),
  requester       TEXT NOT NULL REFERENCES portal_users(username),
  requester_name  TEXT,
  priority        TEXT NOT NULL DEFAULT 'متوسط',
  est_total       NUMERIC NOT NULL DEFAULT 0,
  currency        TEXT NOT NULL DEFAULT 'SAR',
  status          TEXT NOT NULL DEFAULT 'draft',
    -- draft|in_review|returned|approved|rejected|pricing|award_review|awarded|
    -- payment_pending|receipt_pending|closed|cancelled
  current_seq     INT NOT NULL DEFAULT 0,
  phase           TEXT NOT NULL DEFAULT 'requisition',       -- requisition|pricing|award|payment|receipt|closed
  workflow_id     TEXT REFERENCES portal_workflows(id),
  proc_type       TEXT NOT NULL DEFAULT 'normal',             -- normal|single|emergency (استثناء المصدر الوحيد/الطارئ)
  project         TEXT,                                        -- اسم المشروع (إلزامي عند الرفع — سيناريو 6-1)
  need_by         DATE,                                        -- تاريخ التوريد المطلوب (إلزامي)
  justification   TEXT,                                        -- تبرير الشراء الاستثنائي (إلزامي لغير normal)
  note            TEXT,                                        -- ملاحظات الطالب
  split_flag      BOOLEAN NOT NULL DEFAULT false,              -- علم منع التجزئة (المرحلة 4)
  quotes_required INT,                                         -- عدد العروض المطلوب (DoA أو 1 للاستثنائي)
  hold_reason     TEXT,                                        -- سبب التأجيل المالي (on_hold)
  hold_until      DATE,                                        -- تاريخ استئناف متوقّع
  held_by         TEXT,                                        -- من أجّل مالياً
  po_issued_by    TEXT,
  po_issued_at    TIMESTAMPTZ,
  stage_due_at    TIMESTAMPTZ,
  escalations     INT NOT NULL DEFAULT 0,
  escalated_at    TIMESTAMPTZ,
  last_escalation_at TIMESTAMPTZ,
  created_by      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by      TEXT,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  cancelled_by    TEXT,
  cancelled_at    TIMESTAMPTZ,
  cancel_reason   TEXT
);
CREATE INDEX IF NOT EXISTS idx_portal_req_status     ON portal_requests(status);
CREATE INDEX IF NOT EXISTS idx_portal_req_requester   ON portal_requests(requester);
CREATE INDEX IF NOT EXISTS idx_portal_req_dept        ON portal_requests(department_id);
CREATE INDEX IF NOT EXISTS idx_portal_req_due         ON portal_requests(stage_due_at) WHERE status='in_review';

CREATE TABLE IF NOT EXISTS portal_request_items (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  seq           INT,
  description   TEXT NOT NULL,
  unit          TEXT,
  qty           NUMERIC NOT NULL DEFAULT 0,
  unit_price    NUMERIC,
  line_total    NUMERIC GENERATED ALWAYS AS (coalesce(qty,0)*coalesce(unit_price,0)) STORED,
  received_qty  NUMERIC NOT NULL DEFAULT 0,
  category      TEXT,
  notes         TEXT
);
CREATE INDEX IF NOT EXISTS idx_portal_items_req ON portal_request_items(request_id);

-- الدورة الأولى: سلسلة اعتماد الحاجة.
CREATE TABLE IF NOT EXISTS portal_approvals (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  seq           INT NOT NULL,
  stage_label   TEXT,
  resolver      TEXT,                                        -- dept_manager | role | user
  role_key      TEXT,
  approver      TEXT,
  decision      TEXT NOT NULL DEFAULT 'pending',              -- pending|approved|rejected|returned|skipped
  comment       TEXT,
  acted_at      TIMESTAMPTZ,
  channel       TEXT NOT NULL DEFAULT 'portal'                -- portal|email
);
CREATE INDEX IF NOT EXISTS idx_portal_appr_req ON portal_approvals(request_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_portal_appr_req_seq ON portal_approvals(request_id, seq);

-- عروض المقارنة (تُدخَل داخلياً من فريق المشتريات).
CREATE TABLE IF NOT EXISTS portal_offers (
  id              BIGSERIAL PRIMARY KEY,
  request_id      TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  supplier_name   TEXT NOT NULL,
  total           NUMERIC NOT NULL DEFAULT 0,
  delivery_days   INT,
  quality         INT,                                        -- 1..5
  payment_days    INT,
  note            TEXT,
  entered_by      TEXT,
  quote_pdf_key   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_offers_req ON portal_offers(request_id);

-- رأس قرار التعميد (الدورة الثانية).
CREATE TABLE IF NOT EXISTS portal_award (
  request_id      TEXT PRIMARY KEY REFERENCES portal_requests(id) ON DELETE CASCADE,
  winner_offer_id BIGINT REFERENCES portal_offers(id),
  winner_total    NUMERIC,
  award_reason    TEXT,                                       -- مبرّر عدم اختيار الأقل سعراً
  doa_id          BIGINT REFERENCES portal_doa(id),
  status          TEXT NOT NULL DEFAULT 'pending',             -- pending|approved|rejected
  awarded_by      TEXT,                                       -- من رسا العرض (لفصل المهام: لا يعتمد تعميده)
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE portal_award ADD COLUMN IF NOT EXISTS awarded_by TEXT;

CREATE TABLE IF NOT EXISTS portal_award_approvals (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  seq           INT NOT NULL,
  stage_label   TEXT,
  role_key      TEXT,
  approver      TEXT,
  decision      TEXT NOT NULL DEFAULT 'pending',
  comment       TEXT,
  acted_at      TIMESTAMPTZ,
  channel       TEXT NOT NULL DEFAULT 'portal'
);
CREATE INDEX IF NOT EXISTS idx_portal_award_appr_req ON portal_award_approvals(request_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_portal_award_appr_req_seq ON portal_award_approvals(request_id, seq);

-- الصرف.
CREATE TABLE IF NOT EXISTS portal_payments (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL,                                -- bank|custody|credit
  amount        NUMERIC NOT NULL,
  custody_to    TEXT,
  status        TEXT NOT NULL DEFAULT 'pending_pay',           -- pending_pay|approved_pay|rejected|disbursed
  requested_by  TEXT,
  approved_by   TEXT,
  approved_at   TIMESTAMPTZ,
  disbursed_by  TEXT,
  disbursed_at  TIMESTAMPTZ,
  comment       TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  details       JSONB
);
CREATE INDEX IF NOT EXISTS idx_portal_pay_req ON portal_payments(request_id);

-- الاستلام (GRN).
CREATE TABLE IF NOT EXISTS portal_receipts (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  received_by   TEXT,
  received_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  note          TEXT,
  lines         JSONB                                          -- [{item_id, qty}]
);
CREATE INDEX IF NOT EXISTS idx_portal_receipts_req ON portal_receipts(request_id);

-- سجل تدقيق — append-only حقيقي (محرّس صريح أدناه يمنع UPDATE/DELETE للجميع).
CREATE TABLE IF NOT EXISTS portal_audit (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT REFERENCES portal_requests(id) ON DELETE SET NULL,
  event         TEXT NOT NULL,
  actor         TEXT,
  channel       TEXT NOT NULL DEFAULT 'portal',
  detail        JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_audit_req ON portal_audit(request_id, created_at);

-- رموز اعتماد من البريد (لمرة واحدة) — بنفس تحصين proc_email_tokens تماماً:
-- RLS مُفعَّلة بلا أي سياسة = مقفلة كلياً على العميل، الخادم فقط (service_role).
CREATE TABLE IF NOT EXISTS portal_email_tokens (
  token         TEXT PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL,                                 -- approval | award | payment
  seq           INT,
  approver      TEXT NOT NULL,
  used          BOOLEAN NOT NULL DEFAULT false,
  used_at       TIMESTAMPTZ,
  expires_at    TIMESTAMPTZ NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_tok_req ON portal_email_tokens(request_id);

CREATE TABLE IF NOT EXISTS portal_notifications (
  id            TEXT PRIMARY KEY,
  recipient     TEXT NOT NULL,
  type          TEXT,
  title         TEXT NOT NULL,
  body          TEXT,
  link          TEXT,
  read          BOOLEAN NOT NULL DEFAULT false,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_ntf_recipient ON portal_notifications(recipient, read);
CREATE INDEX IF NOT EXISTS idx_portal_ntf_created   ON portal_notifications(created_at DESC);

CREATE TABLE IF NOT EXISTS portal_settings (
  key     TEXT PRIMARY KEY,
  value   JSONB
);


-- ═══════════════════════ 2) دوال مساعدة (هوية/صلاحية) ═══════════════════════

-- اسم المستخدم الحالي من JWT، بمطابقة بريد مباشرة (لا خرائط بريد صلبة —
-- كل مستخدم بريده الحقيقي مخزَّن في portal_users.email من البداية).
CREATE OR REPLACE FUNCTION portal_username() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_email text := lower(coalesce(auth.jwt() ->> 'email',''));
BEGIN
  IF v_email = '' THEN RETURN NULL; END IF;
  RETURN (SELECT username FROM portal_users
            WHERE lower(email) = v_email AND active = true LIMIT 1);
END $fn$;

CREATE OR REPLACE FUNCTION portal_is_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS(SELECT 1 FROM portal_users
                WHERE username = portal_username() AND role = 'admin' AND active = true);
$fn$;

-- هل الاستدعاء بصلاحية الخادم (service_role)؟ يُسمح له بتجاوز كل المحارس.
CREATE OR REPLACE FUNCTION portal_is_service() RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $fn$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role','') = 'service_role';
$fn$;

-- امتياز كامل: الخادم (service_role عبر PostgREST) أو تشغيل مباشر من SQL Editor
-- بحساب مالك المشروع (postgres/supabase_admin — دور Postgres الحقيقي، لا JWT).
-- ضروري لتفادي مشكلة «بيضة ودجاجة» عند البذر الأوّلي (لا صف أدمن بعد في
-- portal_users)، وآمن: من يملك هذا الدور أصلاً يتجاوز أي محرس بتعطيله مباشرةً.
--
-- تحذير حرِج (مُتحقَّق منه باختبار فعلي): الفحص هنا على session_user لا
-- current_user. داخل أي دالة SECURITY DEFINER يتحوّل current_user تلقائياً
-- إلى *مالك الدالة* (postgres عادةً) بغضّ النظر عن المستدعي الفعلي — فلو فُحص
-- current_user هنا لتجاوز أي مستخدم عادي كل المحارس فور استدعائه من دالة
-- SECURITY DEFINER (وهي حال portal_users_guard/portal_config_guard أدناه).
-- session_user لا يتأثر بتبديل SECURITY DEFINER إطلاقاً — يبقى هوية تسجيل
-- الدخول الفعلية للجلسة (في Supabase: PostgREST يتصل دائماً بدور authenticator
-- ثابت ويُبدّل current_user بـ SET ROLE لكل طلب — فلن يكون session_user مساوياً
-- لـpostgres أبداً في أي طلب عبر الواجهة، فقط عند اتصال مباشر بحساب المالك).
CREATE OR REPLACE FUNCTION portal_is_privileged() RETURNS boolean
LANGUAGE sql STABLE AS $fn$
  SELECT portal_is_service() OR session_user IN ('postgres','supabase_admin');
$fn$;

CREATE OR REPLACE FUNCTION portal_has_perm(p_key text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS(
    SELECT 1 FROM portal_users
    WHERE username = portal_username() AND active = true
      AND (role = 'admin' OR coalesce((permissions ->> p_key)::boolean, false))
  );
$fn$;

-- التفويض عند الغياب (نفس نمط proc_users.delegate_to/is_away).
CREATE OR REPLACE FUNCTION portal_effective_approver(p_user text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_cur text := p_user; v_next text; v_hops int := 0;
BEGIN
  IF v_cur IS NULL THEN RETURN NULL; END IF;
  LOOP
    SELECT (CASE WHEN is_away AND delegate_to IS NOT NULL THEN delegate_to ELSE NULL END)
      INTO v_next FROM portal_users WHERE username = v_cur;
    EXIT WHEN v_next IS NULL OR v_next = v_cur OR v_hops > 5;
    v_cur := v_next; v_hops := v_hops + 1;
  END LOOP;
  RETURN v_cur;
END $fn$;


-- ═══════════════════════ 3) محارس (منع الكتابة المباشرة لحقول القرار) ═══════════════════════

-- المحارس أدناه «رفض افتراضي» (deny-by-default): كل كتابة على هذه الجداول الحسّاسة
-- مرفوضة من العميل ما لم تأتِ عبر دالة RPC (ترفع علم app.portal_transition) أو من
-- الخادم (service_role) أو أدمن. أقوى من نمط «قائمة الحالات الممنوعة» الذي يترك أي
-- حالة غير مُدرَجة (مثل pricing/award_review/cancelled) مكشوفة لكتابة مباشرة تتجاوز
-- آلة الحالة — ثغرة أُغلقت بهذا التحويل.
CREATE OR REPLACE FUNCTION portal_approvals_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تُدار سلسلة الموافقات عبر دوال البوابة فقط (لا كتابة مباشرة)';
END $fn$;

CREATE OR REPLACE FUNCTION portal_request_status_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  -- لا إدراج/حذف/تعديل مباشر من العميل إطلاقاً؛ الإنشاء عبر portal_create_request
  -- (التي ترفع العلم) وكل انتقال حالة عبر آلة الحالة.
  RAISE EXCEPTION 'الطلبات وحالاتها تُدار عبر دوال البوابة فقط (لا كتابة مباشرة)';
END $fn$;

CREATE OR REPLACE FUNCTION portal_award_approvals_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تُدار سلسلة اعتماد التعميد عبر دوال البوابة فقط (لا كتابة مباشرة)';
END $fn$;

CREATE OR REPLACE FUNCTION portal_award_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'قرار التعميد يُدار عبر دوال البوابة فقط (لا كتابة مباشرة)';
END $fn$;

CREATE OR REPLACE FUNCTION portal_payments_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'الصرف يُدار عبر دوال البوابة فقط (لا كتابة مباشرة)';
END $fn$;

-- حارس المستخدمين: كل كتابة على portal_users (أي عمود) تتطلّب صلاحية إدارية
-- أو الخادم — بلا استثناء «تحديث حميد». (قرار متعمَّد أشدّ تحفّظاً من
-- proc_users_guard القائم: اختبار فعلي أثبت أن أي استثناء جزئي هنا قد يفتح
-- ثغرة غير مقصودة — مثل السماح بتعديل department_id/job_key/manager_user
-- التي تؤثّر مباشرة على توجيه الموافقات. لا حاجة لخدمة ذاتية هنا أصلاً؛ أي
-- تحديث ذاتي مستقبلي (مثل «ضعني في إجازة») يُبنى كدالة RPC ضيّقة النطاق
-- تُقيَّد صراحةً بـ WHERE username = portal_username() لا بتحديث عام.)
CREATE OR REPLACE FUNCTION portal_users_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_has_perm('can_manage_users') THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل المستخدمين أو صلاحياتهم يتطلّب صلاحية «إدارة المستخدمين»';
END $fn$;

-- حارس إعدادات الضبط (الأقسام/الوظائف/DoA/سير العمل/الإعدادات العامة).
CREATE OR REPLACE FUNCTION portal_config_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() OR portal_has_perm('can_manage_users') OR portal_has_perm('can_manage_company')
  THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل إعدادات البوابة يتطلّب صلاحية إدارية';
END $fn$;

-- تدقيق فعلاً غير قابل للتعديل — حتى service_role لا يستطيع UPDATE/DELETE.
CREATE OR REPLACE FUNCTION portal_audit_immutable() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  RAISE EXCEPTION 'سجل التدقيق للإضافة فقط (append-only) — لا يمكن تعديله أو حذفه';
END $fn$;

-- حارس «الجداول المقفلة»: جداول أدلّة/مالية (العروض، بنود الطلب، سندات الاستلام)
-- تُكتب حصراً عبر دوال البوابة SECURITY DEFINER (التي ترفع علم app.portal_transition).
-- بدون هذا الحارس تسمح سياسة auth_all بكتابة مباشرة من العميل — فيستطيع أي مستخدم
-- حذف/تلفيق عرض مورد (يفسد منطق «أقل سعر» وشريحة DoA) أو تعديل الكميات المستلمة
-- (يغلق الطلب مبكراً) متجاوزاً صلاحيتَي can_manage_procurement/can_verify_stock.
CREATE OR REPLACE FUNCTION portal_locked_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'هذا الجدول يُكتب عبر دوال البوابة فقط (لا كتابة مباشرة من العميل)';
END $fn$;

DROP TRIGGER IF EXISTS trg_portal_approvals_guard ON portal_approvals;
CREATE TRIGGER trg_portal_approvals_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_approvals
  FOR EACH ROW EXECUTE FUNCTION portal_approvals_guard();

DROP TRIGGER IF EXISTS trg_portal_req_status_guard ON portal_requests;
CREATE TRIGGER trg_portal_req_status_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_requests
  FOR EACH ROW EXECUTE FUNCTION portal_request_status_guard();

DROP TRIGGER IF EXISTS trg_portal_award_appr_guard ON portal_award_approvals;
CREATE TRIGGER trg_portal_award_appr_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_award_approvals
  FOR EACH ROW EXECUTE FUNCTION portal_award_approvals_guard();

DROP TRIGGER IF EXISTS trg_portal_award_guard ON portal_award;
CREATE TRIGGER trg_portal_award_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_award
  FOR EACH ROW EXECUTE FUNCTION portal_award_guard();

DROP TRIGGER IF EXISTS trg_portal_payments_guard ON portal_payments;
CREATE TRIGGER trg_portal_payments_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_payments
  FOR EACH ROW EXECUTE FUNCTION portal_payments_guard();

DROP TRIGGER IF EXISTS trg_portal_users_guard ON portal_users;
CREATE TRIGGER trg_portal_users_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_users
  FOR EACH ROW EXECUTE FUNCTION portal_users_guard();

DROP TRIGGER IF EXISTS trg_portal_depts_guard ON portal_departments;
CREATE TRIGGER trg_portal_depts_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_departments
  FOR EACH ROW EXECUTE FUNCTION portal_config_guard();

DROP TRIGGER IF EXISTS trg_portal_jobs_guard ON portal_jobs;
CREATE TRIGGER trg_portal_jobs_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_jobs
  FOR EACH ROW EXECUTE FUNCTION portal_config_guard();

DROP TRIGGER IF EXISTS trg_portal_doa_guard ON portal_doa;
CREATE TRIGGER trg_portal_doa_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_doa
  FOR EACH ROW EXECUTE FUNCTION portal_config_guard();

DROP TRIGGER IF EXISTS trg_portal_wf_guard ON portal_workflows;
CREATE TRIGGER trg_portal_wf_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_workflows
  FOR EACH ROW EXECUTE FUNCTION portal_config_guard();

DROP TRIGGER IF EXISTS trg_portal_settings_guard ON portal_settings;
CREATE TRIGGER trg_portal_settings_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_settings
  FOR EACH ROW EXECUTE FUNCTION portal_config_guard();

DROP TRIGGER IF EXISTS trg_portal_audit_immutable ON portal_audit;
CREATE TRIGGER trg_portal_audit_immutable BEFORE UPDATE OR DELETE ON portal_audit
  FOR EACH ROW EXECUTE FUNCTION portal_audit_immutable();

-- الجداول المقفلة (كتابة عبر دوال البوابة فقط): العروض، بنود الطلب، سندات الاستلام.
DROP TRIGGER IF EXISTS trg_portal_offers_guard ON portal_offers;
CREATE TRIGGER trg_portal_offers_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_offers
  FOR EACH ROW EXECUTE FUNCTION portal_locked_guard();

DROP TRIGGER IF EXISTS trg_portal_items_guard ON portal_request_items;
CREATE TRIGGER trg_portal_items_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_request_items
  FOR EACH ROW EXECUTE FUNCTION portal_locked_guard();

DROP TRIGGER IF EXISTS trg_portal_receipts_guard ON portal_receipts;
CREATE TRIGGER trg_portal_receipts_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_receipts
  FOR EACH ROW EXECUTE FUNCTION portal_locked_guard();


-- ═══════════════════════ 4) دوال تدقيق (INSERT فقط، تلقائية) ═══════════════════════

CREATE OR REPLACE FUNCTION portal_audit_write(p_request_id text, p_event text, p_actor text, p_channel text, p_detail jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $fn$
  INSERT INTO portal_audit(request_id, event, actor, channel, detail) VALUES (p_request_id, p_event, p_actor, p_channel, p_detail);
$fn$;


-- ═══════════════════════ 5) دورة الحاجة (الدورة الأولى) ═══════════════════════

-- تحل معتمِد مرحلة واحدة (مطابق pr_transition منطقياً)، تُستخدَم داخلياً فقط.
CREATE OR REPLACE FUNCTION portal_resolve_stage(p_request_id text, p_stage portal_approvals)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_dept_id text; v_mgr text;
BEGIN
  IF p_stage.approver IS NOT NULL THEN RETURN p_stage.approver; END IF;
  IF p_stage.resolver = 'dept_manager' THEN
    SELECT department_id INTO v_dept_id FROM portal_requests WHERE id = p_request_id;
    SELECT manager_user INTO v_mgr FROM portal_departments WHERE id = v_dept_id;
    RETURN v_mgr;
  END IF;
  RETURN NULL; -- role-based: يُحلّ بالصلاحية وقت التنفيذ لا باسم واحد
END $fn$;

-- إنشاء طلب كامل (رأس + بنود) وإرساله ذرّياً بهوية الخادم — العميل لا يمرّر
-- اسم الطالب أبداً (يُشتقّ من الجلسة حصراً)، فيُغلَق مسار انتحال «requester»
-- المحتمل عبر إدراج مباشر من المتصفح. تُنشئ المعرّف وتحسب الإجمالي، ثم تستدعي
-- portal_submit_request أدناه (نفس منطق بناء السلسلة المُختبَر، بلا تكرار).
-- إسقاط أي توقيع قديم (4 معاملات) قبل تعريف الكامل — يمنع بقاء overload
-- بلا الحقول الإلزامية على قواعد رُقّيت من إصدار سابق.
DROP FUNCTION IF EXISTS portal_create_request(text, text, text, jsonb);
CREATE OR REPLACE FUNCTION portal_create_request(
    p_title text, p_department_id text, p_priority text, p_items jsonb,
    p_project text, p_need_by date, p_proc_type text DEFAULT 'normal',
    p_justification text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_my_dept text; v_dept text; v_id text;
  v_item jsonb; v_seq int := 0; v_est numeric := 0; v_name text;
  v_q numeric; v_p numeric; v_quotes int;
  v_win_days numeric; v_thr numeric; v_cluster_sum numeric; v_peers int; v_all_below boolean;
  v_split boolean := false;
  MAXQ CONSTANT numeric := 1000000;
  MAXP CONSTANT numeric := 100000000;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (portal_has_perm('can_create') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'رفع الطلبات يتطلّب صلاحية «رفع الطلبات» — راجع الإدارة لإسناد وظيفة';
  END IF;
  IF coalesce(trim(p_title), '') = '' THEN RAISE EXCEPTION 'اكتب وصف الطلب'; END IF;
  IF coalesce(trim(p_project), '') = '' THEN RAISE EXCEPTION 'اسم المشروع مطلوب'; END IF;
  IF p_need_by IS NULL THEN RAISE EXCEPTION 'تاريخ التوريد المطلوب مطلوب'; END IF;
  IF coalesce(p_proc_type,'normal') NOT IN ('normal','single','emergency') THEN
    RAISE EXCEPTION 'نوع شراء غير صالح';
  END IF;
  IF coalesce(p_proc_type,'normal') <> 'normal' AND coalesce(trim(p_justification),'') = '' THEN
    RAISE EXCEPTION 'التبرير مطلوب لهذا النوع من الشراء';
  END IF;

  SELECT department_id INTO v_my_dept FROM portal_users WHERE username = v_me;
  IF portal_is_admin() THEN
    v_dept := coalesce(nullif(p_department_id,''), v_my_dept);
  ELSE
    -- غير الأدمن: القطاع من الملف حصراً — لا سقوط على مُدخَل العميل.
    IF coalesce(v_my_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم في ملفك — راجع الإدارة'; END IF;
    IF coalesce(p_department_id,'') <> '' AND p_department_id <> v_my_dept THEN
      RAISE EXCEPTION 'القطاع يُحدَّد تلقائياً من ملفك — لا يمكن اختيار قسم آخر';
    END IF;
    v_dept := v_my_dept;
  END IF;
  IF coalesce(v_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم محدَّد للطلب'; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = v_dept AND active) THEN
    RAISE EXCEPTION 'قطاعك مغلق حالياً لاستقبال الطلبات — راجع الإدارة';
  END IF;

  IF jsonb_array_length(coalesce(p_items, '[]'::jsonb)) < 1 THEN RAISE EXCEPTION 'أضِف بنداً واحداً على الأقل'; END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF coalesce(trim(v_item->>'desc'), '') = '' THEN RAISE EXCEPTION 'وصف كل بند مطلوب'; END IF;
    -- تحقّق النوع الرقمي (رسالة عربية بدل خطأ cast خام)
    IF jsonb_typeof(v_item->'qty') <> 'number' OR jsonb_typeof(coalesce(v_item->'price','0'::jsonb)) <> 'number' THEN
      RAISE EXCEPTION 'كمية/سعر غير رقمي في: %', v_item->>'desc';
    END IF;
    v_q := (v_item->>'qty')::numeric;
    v_p := coalesce((v_item->>'price')::numeric, 0);
    IF v_q <= 0 OR v_q > MAXQ THEN RAISE EXCEPTION 'كمية غير منطقية في: %', v_item->>'desc'; END IF;
    IF v_p < 0 OR v_p > MAXP THEN RAISE EXCEPTION 'سعر غير منطقي في: %', v_item->>'desc'; END IF;
    v_est := v_est + v_q * v_p;
  END LOOP;

  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    v_quotes := 1;
  ELSE
    SELECT quotes_required INTO v_quotes FROM portal_doa
      WHERE max_value IS NULL OR v_est <= max_value
      ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
    v_quotes := coalesce(v_quotes, 3);
  END IF;

  v_id := 'REQ-' || to_char(now(), 'YYYYMMDD') || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
  SELECT display_name INTO v_name FROM portal_users WHERE username = v_me;

  IF portal_setting_bool('split_guard', true) THEN
    v_thr := portal_setting_num('split_threshold', 100000);
    v_win_days := portal_setting_num('split_window_days', 7);
    SELECT count(*), coalesce(sum(est_total),0), coalesce(bool_and(est_total < v_thr), true)
      INTO v_peers, v_cluster_sum, v_all_below
      FROM portal_requests
      WHERE department_id = v_dept AND status <> 'rejected'
        AND created_at >= now() - make_interval(days => v_win_days::int)
        AND created_at <= now() + make_interval(days => v_win_days::int);
    IF v_peers > 0 AND (v_cluster_sum + v_est) >= v_thr AND v_all_below AND v_est < v_thr THEN
      v_split := true;
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_requests (id, title, department_id, requester, requester_name, priority,
                               est_total, created_by, project, need_by, proc_type, justification, note, quotes_required, split_flag)
    VALUES (v_id, trim(p_title), v_dept, v_me, v_name, coalesce(nullif(p_priority, ''), 'متوسط'),
            v_est, v_me, trim(p_project), p_need_by, coalesce(p_proc_type,'normal'),
            nullif(trim(coalesce(p_justification,'')),''), nullif(trim(coalesce(p_note,'')),''), v_quotes, v_split);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_seq := v_seq + 1;
    INSERT INTO portal_request_items (request_id, seq, description, unit, qty, unit_price)
      VALUES (v_id, v_seq, v_item->>'desc', v_item->>'unit', (v_item->>'qty')::numeric, coalesce((v_item->>'price')::numeric, 0));
  END LOOP;
  PERFORM set_config('app.portal_transition', '0', true);

  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    PERFORM portal_audit_write(v_id, 'proc_type', v_me, 'portal',
      jsonb_build_object('type', p_proc_type, 'justification', p_justification));
  END IF;
  IF v_split THEN
    PERFORM portal_audit_write(v_id, 'split_flag', v_me, 'portal',
      jsonb_build_object('cluster_sum', v_cluster_sum + v_est, 'threshold', v_thr, 'window_days', v_win_days, 'peers', v_peers));
  END IF;

  RETURN portal_submit_request(v_id) || jsonb_build_object('id', v_id, 'quotes_required', v_quotes, 'split_flag', v_split);
END $fn$;

-- بناء سلسلة الاعتماد عند الإرسال: يطابق portal_workflows بالقسم/القطاع/القيمة،
-- وإلا سلسلة احتياطية أحادية المرحلة (مدير القسم). SECURITY DEFINER: العميل لا
-- يستطيع تلفيق سلسلته الخاصة.
CREATE OR REPLACE FUNCTION portal_submit_request(p_request_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_wf  portal_workflows%ROWTYPE;
  v_sector text;
  v_stage jsonb;
  v_seq int := 0;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'draft' THEN RAISE EXCEPTION 'الطلب أُرسل مسبقاً'; END IF;
  IF v_req.requester <> v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح'; END IF;

  SELECT sector INTO v_sector FROM portal_departments WHERE id = v_req.department_id;

  SELECT * INTO v_wf FROM portal_workflows
    WHERE active AND (department_id IS NULL OR department_id = v_req.department_id)
      AND (sector IS NULL OR sector = v_sector)
      AND v_req.est_total >= min_total
      AND (max_total IS NULL OR v_req.est_total <= max_total)
    ORDER BY priority ASC LIMIT 1;

  PERFORM set_config('app.portal_transition', '1', true);

  IF NOT FOUND THEN
    -- سلسلة احتياطية: مرحلة واحدة (مدير القسم).
    INSERT INTO portal_approvals(request_id, seq, stage_label, resolver, role_key, approver)
      VALUES (p_request_id, 1, 'مدير القسم', 'dept_manager', NULL, NULL);
    v_seq := 1;
  ELSE
    FOR v_stage IN SELECT * FROM jsonb_array_elements(v_wf.stages) LOOP
      INSERT INTO portal_approvals(request_id, seq, stage_label, resolver, role_key, approver)
        VALUES (
          p_request_id,
          (v_stage->>'seq')::int,
          v_stage->>'label',
          v_stage->>'resolver',
          v_stage->>'role_key',
          v_stage->>'approver'
        );
    END LOOP;
    v_seq := 1;
    UPDATE portal_requests SET workflow_id = v_wf.id WHERE id = p_request_id;
  END IF;

  UPDATE portal_requests SET status = 'in_review', current_seq = v_seq, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'submitted', v_me, 'portal', '{}'::jsonb);
  RETURN jsonb_build_object('ok', true, 'status', 'in_review');
END $fn$;

-- قرار مرحلة (اعتماد/رفض/إرجاع) — الدورة الأولى. مطابق تماماً لمنطق pr_transition
-- المُثبَت أمنياً (فصل مهام، تفويض، قفل صفوف، تحديث ذرّي).
DROP FUNCTION IF EXISTS portal_pr_transition(text, text, text);
DROP FUNCTION IF EXISTS portal_pr_transition(text, text, text, date);
CREATE OR REPLACE FUNCTION portal_pr_transition(p_request_id text, p_action text,
    p_comment text DEFAULT NULL, p_hold_until date DEFAULT NULL, p_return_to_seq int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_approvals%ROWTYPE;
  v_target portal_approvals%ROWTYPE;
  v_pending int; v_next_seq int; v_decision text; v_status text; v_phase text;
  v_ok boolean := false; v_intended text; v_perm boolean;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','defer') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'in_review' THEN RAISE EXCEPTION 'الطلب ليس قيد المراجعة'; END IF;

  SELECT * INTO v_stage FROM portal_approvals
    WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة معلّقة'; END IF;

  IF portal_setting_bool('sod_requester_cannot_approve', true)
     AND v_req.requester = v_me AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)';
  END IF;
  -- فصل المهام متعدّد المراحل: من اعتمد مرحلة سابقة لا يعتمد مرحلة لاحقة لنفس الطلب
  IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = p_request_id
              AND approver = v_me AND decision = 'approved' AND seq < v_stage.seq)
     AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'اعتمدت مرحلة سابقة لهذا الطلب — لا يجوز اعتماد أكثر من مرحلة (فصل المهام)';
  END IF;

  v_intended := portal_resolve_stage(p_request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    -- تصعيد تعارض فصل المهام: إن كان المعتمِد المقصود هو الطالب نفسه، يُحوَّل
    -- الاستحقاق تلقائياً لبديل مؤهَّل (باب 5-2) — فلا يعلق الطلب ولا يُعتمد ذاتياً.
    v_ok := (portal_qualified_approver(v_intended, v_req.requester) = v_me);
  ELSIF v_stage.role_key IS NOT NULL THEN
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm
      FROM portal_users WHERE username = v_me;
    v_ok := coalesce(v_perm, false);
  END IF;
  IF NOT v_ok AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action IN ('reject','return','defer') AND coalesce(trim(p_comment),'') = '' THEN
    RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع/التأجيل';
  END IF;

  -- التأجيل المالي (سيناريو 6-4): من بوابة التحقق المالي فقط (أو الأدمن).
  -- لا يمسّ سلسلة الموافقات — الطلب يتجمّد على مرحلته ويُستثنى من SLA.
  IF p_action = 'defer' THEN
    IF v_stage.role_key IS DISTINCT FROM 'can_approve_finance' AND NOT portal_is_admin() THEN
      RAISE EXCEPTION 'التأجيل المالي متاح في مرحلة التحقق المالي فقط';
    END IF;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_requests SET status = 'on_hold', hold_reason = p_comment, hold_until = p_hold_until,
           held_by = v_me, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'deferred', v_me, 'portal',
      jsonb_build_object('reason', p_comment, 'until', p_hold_until));
    RETURN jsonb_build_object('ok', true, 'action', 'defer', 'status', 'on_hold');
  END IF;

  -- ═══ الإرجاع المرن إلى مرحلة سابقة (p_return_to_seq > 0) — الباب: توجيه المالك ═══
  -- المعتمِد يختار مرحلة سابقة يعود إليها الطلب؛ تُصفَّر تلك المرحلة وكل ما بعدها إلى
  -- pending فيعود in_review على المرحلة الهدف. من عاد إليه الطلب يستطيع بدوره إرجاعه
  -- لمن سبقه (الآلية نفسها تعمل تراكمياً عبر النداءات).
  IF p_action = 'return' AND coalesce(p_return_to_seq, 0) > 0 THEN
    IF p_return_to_seq >= v_stage.seq THEN
      RAISE EXCEPTION 'الإرجاع يكون لمرحلة سابقة فقط';
    END IF;
    SELECT * INTO v_target FROM portal_approvals
      WHERE request_id = p_request_id AND seq = p_return_to_seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'المرحلة الهدف غير موجودة'; END IF;

    PERFORM set_config('app.portal_transition', '1', true);
    -- أعد فتح المرحلة الهدف وكل ما بعدها (بما فيها المرحلة الحالية) إلى pending.
    UPDATE portal_approvals SET decision = 'pending', approver = NULL, comment = NULL,
           acted_at = NULL, channel = 'portal'
      WHERE request_id = p_request_id AND seq >= p_return_to_seq;
    UPDATE portal_requests SET status = 'in_review', phase = 'requisition',
           current_seq = p_return_to_seq, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
    PERFORM set_config('app.portal_transition', '0', true);

    PERFORM portal_audit_write(p_request_id, 'stage_returned', v_me, 'portal',
      jsonb_build_object('from_seq', v_stage.seq, 'from_stage', v_stage.stage_label,
                         'to_seq', p_return_to_seq, 'to_stage', v_target.stage_label, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', 'return', 'decision', 'returned',
      'status', 'in_review', 'finalized', false, 'seq', v_stage.seq, 'return_to_seq', p_return_to_seq);
  END IF;

  v_decision := CASE p_action WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' ELSE 'returned' END;

  SELECT count(*) INTO v_pending FROM portal_approvals WHERE request_id = p_request_id AND decision = 'pending';

  IF p_action = 'approve' THEN
    IF v_pending <= 1 THEN
      v_status := 'pricing'; v_phase := 'pricing'; v_next_seq := v_stage.seq;
    ELSE
      SELECT min(seq) INTO v_next_seq FROM portal_approvals WHERE request_id = p_request_id AND decision = 'pending' AND seq > v_stage.seq;
      v_status := 'in_review'; v_phase := 'requisition';
    END IF;
  ELSIF p_action = 'reject' THEN
    v_status := 'rejected'; v_phase := 'requisition'; v_next_seq := 0;
  ELSE
    v_status := 'returned'; v_phase := 'requisition'; v_next_seq := 0;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);

  UPDATE portal_approvals SET decision = v_decision, approver = v_me, comment = p_comment, acted_at = now(), channel = 'portal'
    WHERE request_id = p_request_id AND seq = v_stage.seq;

  UPDATE portal_requests SET status = v_status, current_seq = coalesce(v_next_seq,0), phase = v_phase, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'stage_' || v_decision, v_me, 'portal', jsonb_build_object('stage', v_stage.stage_label, 'comment', p_comment));

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
                             'finalized', v_status <> 'in_review', 'seq', v_stage.seq);
END $fn$;

REVOKE ALL ON FUNCTION portal_pr_transition(text, text, text, date, int) FROM public;
GRANT EXECUTE ON FUNCTION portal_pr_transition(text, text, text, date, int) TO authenticated;


-- ═══════════════════════ 6) التسعير + التعميد (الدورة الثانية) ═══════════════════════

CREATE OR REPLACE FUNCTION portal_submit_offer(p_request_id text, p_supplier text, p_total numeric,
    p_delivery_days int DEFAULT NULL, p_quality int DEFAULT NULL, p_payment_days int DEFAULT NULL,
    p_note text DEFAULT NULL, p_quote_pdf_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_phase text; v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT phase INTO v_phase FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_phase IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;
  IF coalesce(p_supplier,'') = '' OR coalesce(p_total,0) <= 0 THEN RAISE EXCEPTION 'بيانات العرض غير مكتملة'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_offers(request_id, supplier_name, total, delivery_days, quality, payment_days, note, entered_by, quote_pdf_key)
    VALUES (p_request_id, p_supplier, p_total, p_delivery_days, p_quality, p_payment_days, p_note, v_me,
            nullif(trim(coalesce(p_quote_pdf_key,'')),''))
    RETURNING id INTO v_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'offer_added', v_me, 'portal',
    jsonb_build_object('supplier', p_supplier, 'total', p_total, 'has_pdf', (nullif(trim(coalesce(p_quote_pdf_key,'')),'') IS NOT NULL)));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;
GRANT EXECUTE ON FUNCTION portal_submit_offer(text, text, numeric, int, int, int, text, text) TO authenticated;

-- ترسية: يختار عرضاً فائزاً، يطابق مصفوفة DoA بالقيمة، ويبني سلسلة اعتماد التعميد.
-- ═══ سلسلة اعتماد أمر الشراء: جدول + حارس + بنّاء (انظر db/portal-migrations/007-doa-po-chain.sql) ═══
CREATE TABLE IF NOT EXISTS portal_po_approvals (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  seq           INT NOT NULL,
  stage_label   TEXT,
  kind          TEXT,
  role_key      TEXT,
  approver      TEXT,
  decision      TEXT NOT NULL DEFAULT 'pending',
  comment       TEXT,
  acted_at      TIMESTAMPTZ,
  channel       TEXT NOT NULL DEFAULT 'portal',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (request_id, seq)
);
CREATE OR REPLACE FUNCTION portal_po_approvals_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'سلسلة أمر الشراء تُدار عبر دوال البوابة فقط';
END $fn$;
DROP TRIGGER IF EXISTS trg_portal_po_appr_guard ON portal_po_approvals;
CREATE TRIGGER trg_portal_po_appr_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_po_approvals
  FOR EACH ROW EXECUTE FUNCTION portal_po_approvals_guard();
ALTER TABLE portal_po_approvals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON portal_po_approvals;
CREATE POLICY "auth_all" ON portal_po_approvals FOR ALL TO authenticated USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON portal_po_approvals TO authenticated;
GRANT ALL ON portal_po_approvals TO service_role;

CREATE OR REPLACE FUNCTION portal_build_po_chain(p_request_id text, p_total numeric) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE d portal_doa%ROWTYPE; v_seq int := 0;
BEGIN
  SELECT * INTO d FROM portal_doa WHERE max_value IS NULL OR p_total <= max_value ORDER BY priority ASC LIMIT 1;
  DELETE FROM portal_po_approvals WHERE request_id = p_request_id;
  IF d.po_committee THEN v_seq := v_seq + 1;
    INSERT INTO portal_po_approvals(request_id,seq,stage_label,kind,role_key) VALUES (p_request_id,v_seq,'اعتماد اللجنة المصغّرة','committee','can_approve_committee'); END IF;
  IF d.po_finance THEN v_seq := v_seq + 1;
    INSERT INTO portal_po_approvals(request_id,seq,stage_label,kind,role_key) VALUES (p_request_id,v_seq,'اعتماد المدير المالي','finance','can_approve_finance'); END IF;
  IF d.po_gm THEN v_seq := v_seq + 1;
    INSERT INTO portal_po_approvals(request_id,seq,stage_label,kind,role_key) VALUES (p_request_id,v_seq,'اعتماد المدير العام','gm','can_manage_users'); END IF;
  RETURN v_seq;
END $fn$;
REVOKE ALL ON FUNCTION portal_build_po_chain(text,numeric) FROM public;
GRANT EXECUTE ON FUNCTION portal_build_po_chain(text,numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION portal_award(p_request_id text, p_winner_offer_id bigint, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_offer portal_offers%ROWTYPE;
  v_doa portal_doa%ROWTYPE;
  v_lowest numeric;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  SELECT * INTO v_offer FROM portal_offers WHERE id = p_winner_offer_id AND request_id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'العرض غير موجود'; END IF;

  SELECT min(total) INTO v_lowest FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer.total > v_lowest AND coalesce(trim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'اختيار عرض غير الأقل سعراً يتطلّب مبرّراً موثَّقاً';
  END IF;

  SELECT * INTO v_doa FROM portal_doa WHERE max_value IS NULL OR v_offer.total <= max_value ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'تعذّر تحديد مصفوفة الصلاحيات لهذه القيمة — أضِف قاعدة DoA'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);

  INSERT INTO portal_award(request_id, winner_offer_id, winner_total, award_reason, doa_id, status, awarded_by)
    VALUES (p_request_id, p_winner_offer_id, v_offer.total, p_reason, v_doa.id, 'pending', v_me)
  ON CONFLICT (request_id) DO UPDATE SET winner_offer_id = EXCLUDED.winner_offer_id, winner_total = EXCLUDED.winner_total,
    award_reason = EXCLUDED.award_reason, doa_id = EXCLUDED.doa_id, status = 'pending', awarded_by = EXCLUDED.awarded_by;

  -- إعادة الترسية بعد رفض سابق: احذف سلسلة اعتماد التعميد القديمة كي لا يصطدم
  -- الإدراج الجديد (seq=1) بفهرس التفرّد uq_portal_award_appr_req_seq.
  DELETE FROM portal_award_approvals WHERE request_id = p_request_id;
  INSERT INTO portal_award_approvals(request_id, seq, stage_label, role_key, approver)
    VALUES (p_request_id, 1, 'اعتماد التعميد', v_doa.award_role_key, NULL);

  UPDATE portal_requests SET status = 'award_review', phase = 'award', current_seq = 1, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'awarded', v_me, 'portal', jsonb_build_object('supplier', v_offer.supplier_name, 'total', v_offer.total));
  RETURN jsonb_build_object('ok', true, 'status', 'award_review');
END $fn$;

-- قرار اعتماد التعميد (الدورة الثانية) — نفس منطق pr_transition، على portal_award_approvals.
CREATE OR REPLACE FUNCTION portal_award_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_award_approvals%ROWTYPE;
  v_perm boolean; v_decision text; v_status text; v_phase text; v_po_stages int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'award_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار اعتماد التعميد'; END IF;
  IF v_req.requester = v_me THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;
  -- فصل المهام: من رسا العرض لا يعتمد تعميده (يمنع موظف مشتريات من ترسية العرض
  -- واعتماده بنفسه في الشرائح التي مفتاح اعتمادها can_manage_procurement).
  IF EXISTS (SELECT 1 FROM portal_award WHERE request_id = p_request_id AND awarded_by = v_me)
     AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد تعميد رسّيته بنفسك (فصل المهام)';
  END IF;

  SELECT * INTO v_stage FROM portal_award_approvals
    WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة تعميد معلّقة'; END IF;

  SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm FROM portal_users WHERE username = v_me;
  IF NOT coalesce(v_perm,false) AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action = 'reject' AND coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض'; END IF;

  v_decision := CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END;

  PERFORM set_config('app.portal_transition', '1', true);

  UPDATE portal_award_approvals SET decision = v_decision, approver = v_me, comment = p_comment, acted_at = now()
    WHERE request_id = p_request_id AND seq = v_stage.seq;

  IF p_action = 'approve' THEN
    UPDATE portal_award SET status = 'approved' WHERE request_id = p_request_id;
    -- بناء سلسلة اعتماد أمر الشراء حسب شريحة القيمة (0–25K = 0 مراحل → إصدار مباشر)
    v_po_stages := portal_build_po_chain(p_request_id, (SELECT coalesce(winner_total,0) FROM portal_award WHERE request_id = p_request_id));
    IF v_po_stages = 0 THEN
      v_status := 'awarded'; v_phase := 'payment';
      UPDATE portal_requests SET status = v_status, phase = v_phase, po_issued_by = v_me, po_issued_at = now(), updated_at = now(), updated_by = v_me
        WHERE id = p_request_id;
    ELSE
      v_status := 'po_review'; v_phase := 'po_review';
      UPDATE portal_requests SET status = v_status, phase = v_phase, current_seq = 1, updated_at = now(), updated_by = v_me
        WHERE id = p_request_id;
    END IF;
  ELSE
    v_status := 'pricing'; v_phase := 'pricing'; -- يعود للتسعير لاختيار عرض آخر
    UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
    UPDATE portal_requests SET status = v_status, phase = v_phase, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'award_' || v_decision, v_me, 'portal', jsonb_build_object('comment', p_comment));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;


-- ═══ سلسلة اعتماد أمر الشراء (portal_po_transition) — انظر db/portal-migrations/007-doa-po-chain.sql ═══
CREATE OR REPLACE FUNCTION portal_po_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_stage portal_po_approvals%ROWTYPE;
        v_perm boolean; v_remaining int; v_committee jsonb;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'po_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار اعتماد أمر الشراء'; END IF;
  IF v_req.requester = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;

  SELECT * INTO v_stage FROM portal_po_approvals WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة أمر شراء معلّقة'; END IF;

  IF v_stage.kind = 'committee' THEN
    SELECT value INTO v_committee FROM portal_settings WHERE key = 'committee_members';
    IF NOT ( portal_is_admin()
             OR coalesce((SELECT (permissions ->> 'can_approve_committee')::boolean FROM portal_users WHERE username = v_me), false)
             OR (v_committee IS NOT NULL AND v_committee ? v_me) ) THEN
      RAISE EXCEPTION 'لست عضواً في اللجنة المصغّرة';
    END IF;
  ELSE
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm FROM portal_users WHERE username = v_me;
    IF NOT coalesce(v_perm,false) AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;
  END IF;

  IF NOT portal_is_admin() THEN
    IF EXISTS (SELECT 1 FROM portal_po_approvals WHERE request_id = p_request_id AND approver = v_me AND decision = 'approved') THEN
      RAISE EXCEPTION 'لا تعتمد أكثر من مرحلة في أمر الشراء نفسه (فصل المهام)';
    END IF;
    IF EXISTS (SELECT 1 FROM portal_award WHERE request_id = p_request_id AND awarded_by = v_me) THEN
      RAISE EXCEPTION 'من رسا التعميد لا يعتمد أمر شرائه (فصل المهام)';
    END IF;
  END IF;

  IF p_action IN ('reject','return') AND coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  IF p_action = 'approve' THEN
    UPDATE portal_po_approvals SET decision = 'approved', approver = v_me, comment = p_comment, acted_at = now()
      WHERE request_id = p_request_id AND seq = v_stage.seq;
    SELECT count(*) INTO v_remaining FROM portal_po_approvals WHERE request_id = p_request_id AND decision = 'pending';
    IF v_remaining = 0 THEN
      UPDATE portal_requests SET status = 'awarded', phase = 'payment', po_issued_by = v_me, po_issued_at = now(),
             current_seq = 0, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    ELSE
      UPDATE portal_requests SET current_seq = v_stage.seq + 1, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    END IF;
  ELSE
    UPDATE portal_po_approvals SET decision = CASE p_action WHEN 'reject' THEN 'rejected' ELSE 'returned' END,
           approver = v_me, comment = p_comment, acted_at = now() WHERE request_id = p_request_id AND seq = v_stage.seq;
    UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
    UPDATE portal_requests SET status = 'pricing', phase = 'pricing', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'po_' || p_action, v_me, 'portal', jsonb_build_object('comment', p_comment, 'stage', v_stage.stage_label));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', (SELECT status FROM portal_requests WHERE id = p_request_id));
END $fn$;
REVOKE ALL ON FUNCTION portal_po_transition(text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_po_transition(text, text, text) TO authenticated;


-- ═══════════════════════ 7) الصرف ═══════════════════════

DROP FUNCTION IF EXISTS portal_payment_request(text, text, numeric, text);
CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric,
    p_custody_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
  v_iban text; v_details jsonb := coalesce(p_details, '{}'::jsonb);
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'نوع صرف غير صالح'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'مبلغ غير صالح'; END IF;

  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
  ELSIF p_kind = 'custody' THEN
    IF coalesce(p_custody_to,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = p_custody_to AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)';
    END IF;
  ELSIF p_kind = 'credit' THEN
    IF (v_details->>'due_date') IS NULL OR (v_details->>'due_date')::date IS NULL THEN
      RAISE EXCEPTION 'تاريخ الاستحقاق مطلوب للصرف الآجل';
    END IF;
  END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'الطلب ليس جاهزاً للصرف'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details)
    VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb)) RETURNING id INTO v_id;
  UPDATE portal_requests SET status = 'payment_pending', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal', jsonb_build_object('kind', p_kind, 'amount', p_amount));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

DROP FUNCTION IF EXISTS portal_payment_transition(bigint, text, text);
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text, p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    -- فصل المهام: طالب الصرف لا يعتمده بنفسه.
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;
    -- الإرجاع = رفض غير نهائي مع توجيه: يعود الطلب إلى awarded فيُعيد المشتريات إصدار
    -- طلب الصرف (بعد معالجة ملاحظة المالية). الوجهة تُحفظ في التدقيق للإشعار/التتبّع.
    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    -- فصل المهام الثلاثي (maker-checker على تحرير المال): لا المعتمِد ولا الطالب ينفّذه.
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ طلبته بنفسك (فصل المهام الثلاثي)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now() WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal', jsonb_build_object('payment_id', p_payment_id));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;

REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text) TO authenticated;


-- ═══════════════════════ 8) الاستلام (GRN) ═══════════════════════

CREATE OR REPLACE FUNCTION portal_record_receipt(p_request_id text, p_lines jsonb, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_line jsonb;
  v_remaining numeric;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_verify_stock') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'receipt' THEN RAISE EXCEPTION 'الطلب ليس بانتظار استلام'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  FOR v_line IN SELECT * FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) LOOP
    UPDATE portal_request_items
      SET received_qty = LEAST(qty, received_qty + coalesce((v_line->>'qty')::numeric,0))
      WHERE id = (v_line->>'item_id')::bigint AND request_id = p_request_id;
  END LOOP;

  INSERT INTO portal_receipts(request_id, received_by, note, lines) VALUES (p_request_id, v_me, p_note, p_lines);

  SELECT sum(GREATEST(qty - received_qty, 0)) INTO v_remaining FROM portal_request_items WHERE request_id = p_request_id;

  IF coalesce(v_remaining, 0) <= 0 THEN
    UPDATE portal_requests SET status = 'closed', phase = 'closed', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    PERFORM portal_audit_write(p_request_id, 'closed', v_me, 'portal', '{}'::jsonb);
  ELSE
    UPDATE portal_requests SET updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'receipt_recorded', v_me, 'portal', jsonb_build_object('note', p_note, 'remaining', v_remaining));
  RETURN jsonb_build_object('ok', true, 'remaining', coalesce(v_remaining,0));
END $fn$;

-- إلغاء الطلب (الطالب قبل الاعتماد النهائي، أو الأدمن في أي وقت قبل الإغلاق).
CREATE OR REPLACE FUNCTION portal_cancel_request(p_request_id text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status IN ('closed','cancelled') THEN RAISE EXCEPTION 'لا يمكن إلغاء طلب مُغلق'; END IF;
  -- من يُلغي: الأدمن/المشتريات (أي وقت) — أو المُقدّم قبل بدء التعميد فقط. (الباب 7 + سيناريو 6-5)
  IF NOT (
        portal_is_admin()
        OR portal_has_perm('can_manage_procurement')
        OR portal_has_perm('can_approve_award')
        OR portal_has_perm('can_issue_po')
        OR (v_req.requester = v_me AND v_req.status IN ('draft','in_review','returned'))
     ) THEN
    RAISE EXCEPTION 'غير مصرّح بإلغاء هذا الطلب في حالته الحالية';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET status = 'cancelled', cancelled_by = v_me, cancelled_at = now(), cancel_reason = p_reason, updated_at = now()
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'cancelled', v_me, 'portal', jsonb_build_object('reason', p_reason));
  RETURN jsonb_build_object('ok', true, 'status', 'cancelled');
END $fn$;


-- ═══════════════════════ 9) الرموز من البريد (اعتماد بضغطة واحدة) ═══════════════════════

CREATE OR REPLACE FUNCTION portal_gen_token() RETURNS text
LANGUAGE sql VOLATILE AS $fn$
  SELECT string_agg(substr('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
           (get_byte(gen_random_bytes(1),0) % 62) + 1, 1), '')
  FROM generate_series(1,43);
$fn$;

CREATE OR REPLACE FUNCTION portal_create_token(p_request_id text, p_kind text, p_seq int, p_approver text, p_ttl_hours numeric DEFAULT 168)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_token text := portal_gen_token();
BEGIN
  UPDATE portal_email_tokens SET used = true, used_at = now()
    WHERE request_id = p_request_id AND kind = p_kind AND seq IS NOT DISTINCT FROM p_seq AND approver = p_approver AND used = false;
  INSERT INTO portal_email_tokens(token, request_id, kind, seq, approver, expires_at)
    VALUES (v_token, p_request_id, p_kind, p_seq, p_approver, now() + make_interval(hours => p_ttl_hours::int));
  RETURN v_token;
END $fn$;

-- تنفيذ قرار عبر رمز البريد (الدورة الأولى) — معاملة ذرّية واحدة: استهلاك
-- الرمز + إعادة التحقّق من المعتمِد + تنفيذ الانتقال، بنفس أمان pr_transition_email.
CREATE OR REPLACE FUNCTION portal_pr_transition_email(p_token text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_tok portal_email_tokens%ROWTYPE;
  v_req portal_requests%ROWTYPE;
  v_stage portal_approvals%ROWTYPE;
  v_intended text; v_perm boolean; v_ok boolean := false;
  v_pending int; v_next_seq int; v_decision text; v_status text; v_phase text;
BEGIN
  IF p_action NOT IN ('approve','reject','return') THEN RETURN jsonb_build_object('error','invalid_action','code',400); END IF;
  IF NOT p_token ~ '^[0-9A-Za-z]{16,128}$' THEN RETURN jsonb_build_object('error','unknown_token','code',400); END IF;

  SELECT * INTO v_tok FROM portal_email_tokens WHERE token = p_token FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','unknown_token','code',404); END IF;
  IF v_tok.used THEN RETURN jsonb_build_object('error','used','code',410); END IF;
  IF v_tok.expires_at < now() THEN RETURN jsonb_build_object('error','expired','code',410); END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = v_tok.request_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','pr_not_found','code',404); END IF;
  IF v_req.status <> 'in_review' THEN RETURN jsonb_build_object('error','not_in_review','code',409); END IF;

  SELECT * INTO v_stage FROM portal_approvals WHERE request_id = v_tok.request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','no_pending','code',409); END IF;
  IF v_stage.seq <> v_tok.seq THEN RETURN jsonb_build_object('error','stage_changed','code',409); END IF;

  IF portal_setting_bool('sod_requester_cannot_approve', true)
     AND v_req.requester = v_tok.approver THEN RETURN jsonb_build_object('error','sod','code',403); END IF;
  -- فصل المهام متعدّد المراحل (نفس منطق portal_pr_transition): من اعتمد مرحلة سابقة لا يعتمد لاحقة.
  IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = v_tok.request_id
              AND approver = v_tok.approver AND decision = 'approved' AND seq < v_stage.seq) THEN
    RETURN jsonb_build_object('error','sod','code',403);
  END IF;

  v_intended := portal_resolve_stage(v_tok.request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    v_ok := (portal_qualified_approver(v_intended, v_req.requester) = v_tok.approver);
  ELSIF v_stage.role_key IS NOT NULL THEN
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm FROM portal_users WHERE username = v_tok.approver;
    v_ok := coalesce(v_perm, false);
  END IF;
  IF NOT v_ok THEN RETURN jsonb_build_object('error','not_approver','code',403); END IF;

  IF p_action IN ('reject','return') AND coalesce(trim(p_comment),'') = '' THEN
    RETURN jsonb_build_object('error','comment_required','code',400);
  END IF;

  UPDATE portal_email_tokens SET used = true, used_at = now() WHERE token = p_token;

  v_decision := CASE p_action WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' ELSE 'returned' END;
  SELECT count(*) INTO v_pending FROM portal_approvals WHERE request_id = v_tok.request_id AND decision = 'pending';

  IF p_action = 'approve' THEN
    IF v_pending <= 1 THEN v_status := 'pricing'; v_phase := 'pricing'; v_next_seq := v_stage.seq;
    ELSE
      SELECT min(seq) INTO v_next_seq FROM portal_approvals WHERE request_id = v_tok.request_id AND decision = 'pending' AND seq > v_stage.seq;
      v_status := 'in_review'; v_phase := 'requisition';
    END IF;
  ELSIF p_action = 'reject' THEN v_status := 'rejected'; v_phase := 'requisition'; v_next_seq := 0;
  ELSE v_status := 'returned'; v_phase := 'requisition'; v_next_seq := 0;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_approvals SET decision = v_decision, approver = v_tok.approver, comment = p_comment, acted_at = now(), channel = 'email'
    WHERE request_id = v_tok.request_id AND seq = v_stage.seq;
  UPDATE portal_requests SET status = v_status, current_seq = coalesce(v_next_seq,0), phase = v_phase, updated_at = now(), updated_by = v_tok.approver
    WHERE id = v_tok.request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(v_tok.request_id, 'stage_' || v_decision, v_tok.approver, 'email', jsonb_build_object('stage', v_stage.stage_label, 'comment', p_comment));

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
    'finalized', v_status <> 'in_review', 'seq', v_stage.seq,
    'request', jsonb_build_object('id', v_req.id, 'title', v_req.title, 'department_id', v_req.department_id,
                                   'requester', v_req.requester, 'requester_name', v_req.requester_name));
END $fn$;


-- ═══ إعادة تقديم الطلب المُعاد (returned → in_review) — انظر db/portal-migrations/005-resubmit.sql ═══
CREATE OR REPLACE FUNCTION portal_resubmit_request(p_request_id text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_first int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'returned' THEN RAISE EXCEPTION 'يمكن إعادة تقديم الطلبات المُعادة فقط'; END IF;
  IF v_req.requester <> v_me AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'إعادة التقديم تقتصر على مُقدّم الطلب';
  END IF;
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_approvals
     SET decision='pending', approver=NULL, comment=NULL, acted_at=NULL, channel='portal'
   WHERE request_id = p_request_id;
  SELECT min(seq) INTO v_first FROM portal_approvals WHERE request_id = p_request_id;
  UPDATE portal_requests
     SET status='in_review', phase='requisition', current_seq = coalesce(v_first,1),
         updated_at=now(), updated_by=v_me
   WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM portal_audit_write(p_request_id,'resubmitted',v_me,'portal',jsonb_build_object('comment',p_comment));
  RETURN jsonb_build_object('ok',true,'status','in_review');
END $fn$;
REVOKE ALL ON FUNCTION portal_resubmit_request(text,text) FROM public;
GRANT EXECUTE ON FUNCTION portal_resubmit_request(text,text) TO authenticated;


-- ═══════════════════════ 10) SLA/تصعيد (اختياري — pg_cron إن توفّر) ═══════════════════════

-- ═══ دوال الحوكمة (المرحلة 4): إعدادات + تصعيد تعارض + استئناف ═══
CREATE OR REPLACE FUNCTION portal_setting_bool(p_key text, p_default boolean)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce((SELECT (value->>p_key)::boolean FROM portal_settings WHERE key='portal_settings'), p_default);
$fn$;
CREATE OR REPLACE FUNCTION portal_setting_num(p_key text, p_default numeric)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce((SELECT (value->>p_key)::numeric FROM portal_settings WHERE key='portal_settings'), p_default);
$fn$;

-- 4) المعتمِد المؤهَّل (باب 5-2): تفويض ← عند تعارض (المعتمِد هو الطالب) تصعيدٌ
--    عبر سلسلة المدراء (manager_user) لأول نشط مؤهَّل بلا تعارض، وإلا أي مؤهَّل
--    نشط. حارس دورات في كلا المسارين.
CREATE OR REPLACE FUNCTION portal_qualified_approver(p_base text, p_requester text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_u text := portal_effective_approver(p_base);
  v_cur text; v_cand text; v_seen text[] := ARRAY[]::text[];
BEGIN
  IF v_u IS NULL THEN RETURN NULL; END IF;
  IF NOT portal_setting_bool('sod_auto_escalation', true) THEN RETURN v_u; END IF;
  IF v_u IS DISTINCT FROM p_requester THEN RETURN v_u; END IF;   -- لا تعارض

  -- (أ) سلسلة المدراء
  v_cur := v_u;
  WHILE v_cur IS NOT NULL AND NOT (v_cur = ANY(v_seen)) LOOP
    v_seen := v_seen || v_cur;
    SELECT manager_user INTO v_cur FROM portal_users WHERE username = v_cur;
    IF v_cur IS NOT NULL THEN
      v_cand := portal_effective_approver(v_cur);
      IF v_cand IS DISTINCT FROM p_requester AND EXISTS (
           SELECT 1 FROM portal_users WHERE username = v_cand AND active
             AND (role='admin' OR coalesce((permissions->>'can_approve_stage')::boolean,false))
         ) THEN
        RETURN v_cand;
      END IF;
    END IF;
  END LOOP;

  -- (ب) أي معتمِد نشط مؤهَّل بلا تعارض (الأدمن أولاً — يكافئ ROOT المرجعي)
  SELECT username INTO v_cand FROM portal_users
    WHERE active AND username IS DISTINCT FROM p_requester
      AND (role='admin' OR coalesce((permissions->>'can_approve_stage')::boolean,false))
    ORDER BY (role='admin') DESC, username ASC LIMIT 1;
  IF v_cand IS NOT NULL THEN RETURN portal_effective_approver(v_cand); END IF;
  RETURN v_u;
END $fn$;
CREATE OR REPLACE FUNCTION portal_setting_num(p_key text, p_default numeric)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce((SELECT (value->>p_key)::numeric FROM portal_settings WHERE key='portal_settings'), p_default);
$fn$;

-- 4) المعتمِد المؤهَّل (باب 5-2): تفويض ← عند تعارض (المعتمِد هو الطالب) تصعيدٌ
--    عبر سلسلة المدراء (manager_user) لأول نشط مؤهَّل بلا تعارض، وإلا أي مؤهَّل
--    نشط. حارس دورات في كلا المسارين.
CREATE OR REPLACE FUNCTION portal_qualified_approver(p_base text, p_requester text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_u text := portal_effective_approver(p_base);
  v_cur text; v_cand text; v_seen text[] := ARRAY[]::text[];
BEGIN
  IF v_u IS NULL THEN RETURN NULL; END IF;
  IF NOT portal_setting_bool('sod_auto_escalation', true) THEN RETURN v_u; END IF;
  IF v_u IS DISTINCT FROM p_requester THEN RETURN v_u; END IF;   -- لا تعارض

  -- (أ) سلسلة المدراء
  v_cur := v_u;
  WHILE v_cur IS NOT NULL AND NOT (v_cur = ANY(v_seen)) LOOP
    v_seen := v_seen || v_cur;
    SELECT manager_user INTO v_cur FROM portal_users WHERE username = v_cur;
    IF v_cur IS NOT NULL THEN
      v_cand := portal_effective_approver(v_cur);
      IF v_cand IS DISTINCT FROM p_requester AND EXISTS (
           SELECT 1 FROM portal_users WHERE username = v_cand AND active
             AND (role='admin' OR coalesce((permissions->>'can_approve_stage')::boolean,false))
         ) THEN
        RETURN v_cand;
      END IF;
    END IF;
  END LOOP;

  -- (ب) أي معتمِد نشط مؤهَّل بلا تعارض (الأدمن أولاً — يكافئ ROOT المرجعي)
  SELECT username INTO v_cand FROM portal_users
    WHERE active AND username IS DISTINCT FROM p_requester
      AND (role='admin' OR coalesce((permissions->>'can_approve_stage')::boolean,false))
    ORDER BY (role='admin') DESC, username ASC LIMIT 1;
  IF v_cand IS NOT NULL THEN RETURN portal_effective_approver(v_cand); END IF;
  RETURN v_u;
END $fn$;
CREATE OR REPLACE FUNCTION portal_qualified_approver(p_base text, p_requester text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_u text := portal_effective_approver(p_base);
  v_cur text; v_cand text; v_seen text[] := ARRAY[]::text[];
BEGIN
  IF v_u IS NULL THEN RETURN NULL; END IF;
  IF NOT portal_setting_bool('sod_auto_escalation', true) THEN RETURN v_u; END IF;
  IF v_u IS DISTINCT FROM p_requester THEN RETURN v_u; END IF;   -- لا تعارض

  -- (أ) سلسلة المدراء
  v_cur := v_u;
  WHILE v_cur IS NOT NULL AND NOT (v_cur = ANY(v_seen)) LOOP
    v_seen := v_seen || v_cur;
    SELECT manager_user INTO v_cur FROM portal_users WHERE username = v_cur;
    IF v_cur IS NOT NULL THEN
      v_cand := portal_effective_approver(v_cur);
      IF v_cand IS DISTINCT FROM p_requester AND EXISTS (
           SELECT 1 FROM portal_users WHERE username = v_cand AND active
             AND (role='admin' OR coalesce((permissions->>'can_approve_stage')::boolean,false))
         ) THEN
        RETURN v_cand;
      END IF;
    END IF;
  END LOOP;

  -- (ب) أي معتمِد نشط مؤهَّل بلا تعارض (الأدمن أولاً — يكافئ ROOT المرجعي)
  SELECT username INTO v_cand FROM portal_users
    WHERE active AND username IS DISTINCT FROM p_requester
      AND (role='admin' OR coalesce((permissions->>'can_approve_stage')::boolean,false))
    ORDER BY (role='admin') DESC, username ASC LIMIT 1;
  IF v_cand IS NOT NULL THEN RETURN portal_effective_approver(v_cand); END IF;
  RETURN v_u;
END $fn$;
CREATE OR REPLACE FUNCTION portal_resume_hold(p_request_id text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (portal_has_perm('can_disburse') OR portal_has_perm('can_approve_finance') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'استئناف المؤجَّل مالياً متاح للمالية فقط';
  END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'on_hold' THEN RAISE EXCEPTION 'الطلب ليس مؤجَّلاً'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET status = 'in_review', hold_reason = NULL, hold_until = NULL, held_by = NULL,
         updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'resumed', v_me, 'portal',
    jsonb_build_object('comment', coalesce(p_comment, 'تأكيد توفّر السيولة — استئناف')));
  RETURN jsonb_build_object('ok', true, 'status', 'in_review');
END $fn$;

CREATE OR REPLACE FUNCTION portal_sla_hours() RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce(nullif((SELECT value->>'sla_days' FROM portal_settings WHERE key='portal_settings'),'')::numeric * 24, 72);
$fn$;

CREATE OR REPLACE FUNCTION portal_set_due() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE v_h numeric := portal_sla_hours();
BEGIN
  IF NEW.status = 'in_review' THEN
    IF TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'in_review' OR NEW.current_seq IS DISTINCT FROM OLD.current_seq THEN
      NEW.stage_due_at := now() + make_interval(hours => v_h::int);
    END IF;
  ELSE
    NEW.stage_due_at := NULL;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_portal_set_due ON portal_requests;
CREATE TRIGGER trg_portal_set_due BEFORE INSERT OR UPDATE ON portal_requests
  FOR EACH ROW EXECUTE FUNCTION portal_set_due();

CREATE OR REPLACE FUNCTION portal_run_sla() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_req RECORD; v_stage portal_approvals%ROWTYPE; v_intended text; v_deleg text; v_cnt int := 0; v_h numeric := portal_sla_hours();
BEGIN
  FOR v_req IN SELECT * FROM portal_requests
      WHERE status = 'in_review' AND stage_due_at < now()
        AND (last_escalation_at IS NULL OR last_escalation_at < now() - make_interval(hours => v_h::int))
  LOOP
    SELECT * INTO v_stage FROM portal_approvals WHERE request_id = v_req.id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
    CONTINUE WHEN NOT FOUND;
    v_intended := portal_resolve_stage(v_req.id, v_stage);
    v_deleg := NULL;
    IF v_intended IS NOT NULL THEN
      SELECT delegate_to INTO v_deleg FROM portal_users WHERE username = v_intended AND is_away = true;
    END IF;

    IF v_intended IS NOT NULL THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        VALUES ('ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||v_intended,
                v_intended, 'system', 'تذكير: طلب متأخّر بانتظار اعتمادك', v_req.title, 'inbox')
        ON CONFLICT (id) DO NOTHING;
    ELSIF v_stage.role_key IS NOT NULL THEN
      -- (014) مرحلة دور: أخطر كل حاملي الصلاحية النشطين + مفوَّضي الغائبين منهم.
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||u.username,
               u.username, 'system', 'تذكير: طلب متأخّر بانتظار اعتماد مرحلتك ('||coalesce(v_stage.stage_label,'')||')', v_req.title, 'inbox'
        FROM portal_users u
        WHERE u.active AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
        ON CONFLICT (id) DO NOTHING;
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||u.delegate_to,
               u.delegate_to, 'system', 'تفويض: طلب متأخّر بانتظار اعتماد مرحلة ('||coalesce(v_stage.stage_label,'')||') بالنيابة', v_req.title, 'inbox'
        FROM portal_users u
        WHERE u.active AND u.is_away AND u.delegate_to IS NOT NULL
          AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
        ON CONFLICT (id) DO NOTHING;
    END IF;
    IF v_deleg IS NOT NULL THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        VALUES ('ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||v_deleg,
                v_deleg, 'system', 'تفويض: طلب متأخّر بانتظار اعتمادك (بالنيابة)', v_req.title, 'inbox')
        ON CONFLICT (id) DO NOTHING;
    END IF;
    INSERT INTO portal_notifications(id, recipient, type, title, body, link)
      SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||username,
             username, 'system', 'تصعيد SLA: طلب متأخّر', v_req.title, 'inbox'
      FROM portal_users WHERE role = 'admin' AND active = true
      ON CONFLICT (id) DO NOTHING;

    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_requests SET escalations = escalations + 1,
      escalated_at = coalesce(escalated_at, now()), last_escalation_at = now() WHERE id = v_req.id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_req.id, 'escalated', NULL, 'system', jsonb_build_object('intended', v_intended, 'stage_label', v_stage.stage_label));
    v_cnt := v_cnt + 1;
  END LOOP;
  RETURN v_cnt;
END $fn$;

-- (014) الاستدعاء الكسول من الواجهة (مشتريات/مالية/أدمن) — الخانق الداخلي يمنع التكرار.
CREATE OR REPLACE FUNCTION portal_sla_tick() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RETURN 0;
  END IF;
  RETURN portal_run_sla();
END $fn$;
REVOKE ALL ON FUNCTION portal_sla_tick() FROM public;
GRANT EXECUTE ON FUNCTION portal_sla_tick() TO authenticated;
-- (017) portal_run_sla تُستدعى داخلياً فقط عبر portal_sla_tick/pg_cron — تُسحب من PUBLIC.
REVOKE ALL ON FUNCTION portal_run_sla() FROM PUBLIC;
REVOKE ALL ON FUNCTION portal_run_sla() FROM anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'portal-sla';
    PERFORM cron.schedule('portal-sla', '*/30 * * * *', 'SELECT portal_run_sla();');
  END IF;
END $$;


-- ═══════════════════════ 11) RLS ═══════════════════════

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'portal_users','portal_departments','portal_jobs','portal_doa','portal_workflows',
    'portal_requests','portal_request_items','portal_approvals','portal_offers','portal_award',
    'portal_award_approvals','portal_payments','portal_receipts','portal_audit','portal_notifications',
    'portal_settings','portal_email_tokens'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- كل الجداول: قراءة/كتابة عامة للمصادَق عليهم، محكومة بالمحارس أعلاه لحقول
-- القرار الحسّاسة. الاستثناء الوحيد: portal_email_tokens (بلا أي سياسة =
-- مقفلة كلياً على العميل، خادم فقط) — بنفس تحصين proc_email_tokens المُثبَت.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'portal_users','portal_departments','portal_jobs','portal_doa','portal_workflows',
    'portal_requests','portal_request_items','portal_approvals','portal_offers','portal_award',
    'portal_award_approvals','portal_payments','portal_receipts','portal_settings'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS "auth_all" ON %I', t);
    EXECUTE format('CREATE POLICY "auth_all" ON %I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;

-- الإشعارات: كل مستخدم يرى ويعدّل إشعاراته فقط (لا يقرأ/يزوّر/يحذف إشعارات غيره).
-- (سياسة مُقيَّدة بالمستلِم بدل auth_all العامة — أُخرج الجدول من الحلقة أعلاه لهذا.)
DROP POLICY IF EXISTS "auth_all" ON portal_notifications;
DROP POLICY IF EXISTS "own_notifications" ON portal_notifications;
CREATE POLICY "own_notifications" ON portal_notifications FOR ALL TO authenticated
  USING (recipient = portal_username()) WITH CHECK (recipient = portal_username());

-- ═══ فرض نطاق الرؤية (H1 — الهجرة 009): السياسات المُنطاقة تستبدل auth_all ═══
-- الجداول المعامَلاتية تُقرأ حسب نطاق المستخدم (own/sector/all) + رؤية المعتمِد
-- للطلبات المعنيّة به. الكتابة عبر RPC (SECURITY DEFINER يتجاوز RLS) والمحارس.
-- الدوال SECURITY DEFINER لتتجاوز استعلاماتها RLS (تمنع التكرار اللانهائي).
CREATE OR REPLACE FUNCTION portal_my_scope() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT CASE WHEN portal_is_admin() THEN 'all'
              ELSE coalesce((SELECT j.scope FROM portal_users u
                             LEFT JOIN portal_jobs j ON j.key = u.job_key
                             WHERE u.username = portal_username()), 'own') END;
$fn$;
CREATE OR REPLACE FUNCTION portal_my_sector() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT d.sector FROM portal_users u
    JOIN portal_departments d ON d.id = u.department_id
   WHERE u.username = portal_username();
$fn$;
CREATE OR REPLACE FUNCTION portal_can_see_request(p_id text, p_requester text, p_dept text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    portal_is_admin()
    OR portal_my_scope() = 'all'
    OR p_requester = portal_username()
    OR (portal_my_scope() = 'sector' AND portal_my_sector() IS NOT NULL AND EXISTS (
          SELECT 1 FROM portal_departments d
           WHERE d.id = p_dept AND d.sector = portal_my_sector()))
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.approver = portal_username())
    -- (015) المعتمِد المقصود لمرحلة معلّقة في سلسلة الحاجة (مباشرة)
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND ( a.approver = portal_username()
                        OR (a.role_key IS NOT NULL AND portal_has_perm(a.role_key))
                        OR (a.resolver = 'dept_manager' AND EXISTS (
                              SELECT 1 FROM portal_departments d
                               WHERE d.id = p_dept AND d.manager_user = portal_username())) ))
    -- (015) المفوَّض عن معتمِد غائب لمرحلة معلّقة
    OR EXISTS (SELECT 1
                 FROM portal_approvals a
                 JOIN portal_users u ON u.is_away AND u.delegate_to = portal_username()
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND ( a.approver = u.username
                        OR (a.role_key IS NOT NULL AND coalesce((u.permissions ->> a.role_key)::boolean, false))
                        OR (a.resolver = 'dept_manager' AND EXISTS (
                              SELECT 1 FROM portal_departments d
                               WHERE d.id = p_dept AND d.manager_user = u.username)) ))
    -- (015) معتمِد معلّق في سلسلة اعتماد التعميد
    OR EXISTS (SELECT 1 FROM portal_award_approvals a
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND a.role_key IS NOT NULL AND portal_has_perm(a.role_key))
    -- (015) معتمِد معلّق في سلسلة أمر الشراء (صلاحية أو عضوية اللجنة المصغّرة)
    OR EXISTS (SELECT 1 FROM portal_po_approvals a
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND ( (a.role_key IS NOT NULL AND portal_has_perm(a.role_key))
                        OR (a.kind = 'committee' AND EXISTS (
                              SELECT 1 FROM portal_settings s
                               WHERE s.key = 'committee_members' AND s.value ? portal_username())) ));
$fn$;
CREATE OR REPLACE FUNCTION portal_can_see_request(p_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT portal_can_see_request(r.id, r.requester, r.department_id)
    FROM portal_requests r WHERE r.id = p_id;
$fn$;
REVOKE ALL ON FUNCTION portal_my_scope() FROM public;
REVOKE ALL ON FUNCTION portal_my_sector() FROM public;
REVOKE ALL ON FUNCTION portal_can_see_request(text, text, text) FROM public;
REVOKE ALL ON FUNCTION portal_can_see_request(text) FROM public;
GRANT EXECUTE ON FUNCTION portal_my_scope() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION portal_my_sector() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION portal_can_see_request(text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION portal_can_see_request(text) TO authenticated, service_role;

-- SELECT مُنطاق + INSERT/UPDATE/DELETE عام (تبقى المحارس deny-by-default هي مدافع
-- الكتابة كما كانت؛ لا نضعف شيئاً — فقط نُقيّد القراءة). سياسات لكل أمر لأن FOR ALL
-- عامة تُلغي تقييد SELECT (السياسات المسموحة تُدمج بـOR).
DROP POLICY IF EXISTS "auth_all"   ON portal_requests;
DROP POLICY IF EXISTS "see_scoped" ON portal_requests;
DROP POLICY IF EXISTS "wr_ins" ON portal_requests;
DROP POLICY IF EXISTS "wr_upd" ON portal_requests;
DROP POLICY IF EXISTS "wr_del" ON portal_requests;
CREATE POLICY "see_scoped" ON portal_requests FOR SELECT TO authenticated
  USING (portal_can_see_request(id, requester, department_id));
CREATE POLICY "wr_ins" ON portal_requests FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "wr_upd" ON portal_requests FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "wr_del" ON portal_requests FOR DELETE TO authenticated USING (true);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'portal_request_items','portal_approvals','portal_offers','portal_award',
    'portal_award_approvals','portal_po_approvals','portal_payments','portal_receipts'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS "auth_all" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "see_by_request" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "wr_ins" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "wr_upd" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "wr_del" ON %I', t);
    EXECUTE format('CREATE POLICY "see_by_request" ON %I FOR SELECT TO authenticated USING (portal_can_see_request(request_id))', t);
    EXECUTE format('CREATE POLICY "wr_ins" ON %I FOR INSERT TO authenticated WITH CHECK (true)', t);
    EXECUTE format('CREATE POLICY "wr_upd" ON %I FOR UPDATE TO authenticated USING (true) WITH CHECK (true)', t);
    EXECUTE format('CREATE POLICY "wr_del" ON %I FOR DELETE TO authenticated USING (true)', t);
  END LOOP;
END $$;

-- التدقيق: الأدمن يرى الكل؛ غيره يرى تدقيق الطلبات المرئية له فقط.
DROP POLICY IF EXISTS "audit_read" ON portal_audit;
CREATE POLICY "audit_read" ON portal_audit FOR SELECT TO authenticated
  USING (portal_is_admin() OR (request_id IS NOT NULL AND portal_can_see_request(request_id)));


-- ═══════════════════════ 12) بيانات أوّلية (DoA افتراضية — قابلة للتعديل من الإدارة) ═══════════════════════

-- مصفوفة DoA (المواصفات الجديدة): التعميد دائماً مدير المشتريات؛ اعتماد أمر الشراء يكبر بالقيمة.
INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key, po_committee, po_finance, po_gm, label, note, priority)
SELECT 25000, 1, false, 'can_approve_award', 'can_manage_procurement', false, false, false, '0 – 25,000', 'اعتماد مدير المشتريات (تعميد + أمر شراء)', 10
WHERE NOT EXISTS (SELECT 1 FROM portal_doa WHERE label = '0 – 25,000');

INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key, po_committee, po_finance, po_gm, label, note, priority)
SELECT 150000, 3, true, 'can_approve_award', 'can_manage_procurement', true, false, false, '25,001 – 150,000', 'أمر الشراء: مدير المشتريات + اللجنة', 20
WHERE NOT EXISTS (SELECT 1 FROM portal_doa WHERE label = '25,001 – 150,000');

INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key, po_committee, po_finance, po_gm, label, note, priority)
SELECT 250000, 3, true, 'can_approve_award', 'can_manage_procurement', true, true, false, '150,001 – 250,000', 'أمر الشراء: + المدير المالي', 30
WHERE NOT EXISTS (SELECT 1 FROM portal_doa WHERE label = '150,001 – 250,000');

INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key, po_committee, po_finance, po_gm, label, note, priority)
SELECT 500000, 3, true, 'can_approve_award', 'can_manage_procurement', true, true, true, '250,001 – 500,000', 'أمر الشراء: + المدير العام', 40
WHERE NOT EXISTS (SELECT 1 FROM portal_doa WHERE label = '250,001 – 500,000');

INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key, po_committee, po_finance, po_gm, label, note, priority)
SELECT NULL, 3, true, 'can_approve_award', 'can_manage_procurement', true, true, true, 'أكثر من 500,000', 'مناقصة رسمية — كل الاعتمادات + المدير العام', 50
WHERE NOT EXISTS (SELECT 1 FROM portal_doa WHERE label = 'أكثر من 500,000');

-- أعضاء اللجنة المصغّرة (يحدّدهم الأدمن لاحقاً من المستخدمين المسجّلين)
INSERT INTO portal_settings (key, value)
SELECT 'committee_members', '[]'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM portal_settings WHERE key = 'committee_members');

-- ملاحظة: التعميد = can_approve_award (مدير المشتريات). اعتماد أمر الشراء يُبنى تلقائياً
-- حسب الشريحة عبر portal_build_po_chain (لجنة/مالية/عام). can_approve_committee يُمنح لأعضاء اللجنة.

-- ═══ بوابة الدعوات + تقييد النطاق البريدي (الهجرة 010) ═══
CREATE TABLE IF NOT EXISTS portal_invitations (
  id            BIGSERIAL PRIMARY KEY,
  token         TEXT UNIQUE NOT NULL,
  email         TEXT NOT NULL,
  display_name  TEXT,
  job_key       TEXT REFERENCES portal_jobs(key),
  department_id TEXT REFERENCES portal_departments(id),
  role          TEXT NOT NULL DEFAULT 'user',
  status        TEXT NOT NULL DEFAULT 'pending',
  invited_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days'),
  accepted_at   TIMESTAMPTZ,
  accepted_user TEXT
);
CREATE INDEX IF NOT EXISTS idx_portal_inv_email  ON portal_invitations(lower(email));
CREATE INDEX IF NOT EXISTS idx_portal_inv_status ON portal_invitations(status);
ALTER TABLE portal_invitations ENABLE ROW LEVEL SECURITY;    -- بلا سياسة = خادم فقط
REVOKE ALL ON portal_invitations FROM authenticated, anon;
GRANT ALL ON portal_invitations TO service_role;
GRANT USAGE, SELECT ON SEQUENCE portal_invitations_id_seq TO service_role;

INSERT INTO portal_settings(key, value) VALUES ('portal_settings', '{}'::jsonb)
  ON CONFLICT (key) DO NOTHING;
UPDATE portal_settings SET value = value || jsonb_build_object('allowed_email_domain','aldeyabi.com')
  WHERE key='portal_settings' AND NOT (value ? 'allowed_email_domain');
UPDATE portal_settings SET value = value || jsonb_build_object('email_whitelist','[]'::jsonb)
  WHERE key='portal_settings' AND NOT (value ? 'email_whitelist');

CREATE OR REPLACE FUNCTION portal_email_allowed(p_email text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH s AS (SELECT value FROM portal_settings WHERE key='portal_settings')
  SELECT
    lower(trim(coalesce(p_email,''))) <> ''
    AND (
      lower(trim(p_email)) LIKE ('%@' || lower(coalesce((SELECT value->>'allowed_email_domain' FROM s), 'aldeyabi.com')))
      OR EXISTS (
        SELECT 1 FROM s, jsonb_array_elements_text(coalesce((SELECT value->'email_whitelist' FROM s), '[]'::jsonb)) w
        WHERE lower(trim(w)) = lower(trim(p_email))
      )
    );
$fn$;
REVOKE ALL ON FUNCTION portal_email_allowed(text) FROM public;
GRANT EXECUTE ON FUNCTION portal_email_allowed(text) TO authenticated, service_role;

-- ═══ تخصيص اللجنة المصغّرة (الهجرة 013): الأدمن يضبط committee_members بأمان ═══
CREATE OR REPLACE FUNCTION portal_set_committee(p_members jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_valid jsonb;
BEGIN
  IF v_me IS NULL OR NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح — إدارة اللجنة للأدمن فقط'; END IF;
  IF p_members IS NULL OR jsonb_typeof(p_members) <> 'array' THEN RAISE EXCEPTION 'صيغة القائمة غير صالحة'; END IF;
  SELECT coalesce(jsonb_agg(DISTINCT u.username), '[]'::jsonb) INTO v_valid
    FROM jsonb_array_elements_text(p_members) m
    JOIN portal_users u ON u.username = m AND u.active;
  INSERT INTO portal_settings(key, value) VALUES ('committee_members', v_valid)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  PERFORM portal_audit_write(NULL, 'committee_set', v_me, 'portal', jsonb_build_object('members', v_valid));
  RETURN jsonb_build_object('ok', true, 'members', v_valid);
END $fn$;
REVOKE ALL ON FUNCTION portal_set_committee(jsonb) FROM public;
GRANT EXECUTE ON FUNCTION portal_set_committee(jsonb) TO authenticated;

-- ═══ حذف المستخدم بأمان (الهجرة 011): أدمن فقط + لا حذف للذات/آخر أدمن + فك FK ═══
CREATE OR REPLACE FUNCTION portal_delete_user(p_username text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_role text; v_active boolean; v_admins int;
BEGIN
  IF v_me IS NULL OR NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_username IS NULL OR p_username = v_me THEN RAISE EXCEPTION 'لا يمكنك حذف حسابك'; END IF;
  SELECT role, active INTO v_role, v_active FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;
  IF v_role = 'admin' AND v_active THEN
    PERFORM pg_advisory_xact_lock(hashtext('portal_last_admin'));
    SELECT count(*) INTO v_admins FROM portal_users WHERE role = 'admin' AND active;
    IF v_admins <= 1 THEN RAISE EXCEPTION 'لا يمكن حذف آخر أدمن نشط للبوابة'; END IF;
  END IF;
  -- سلامة التدقيق: لا حذف صلب لمن له طلبات مسجّلة — يُعطَّل حسابه بدلاً من ذلك.
  IF EXISTS (SELECT 1 FROM portal_requests WHERE requester = p_username) THEN
    RAISE EXCEPTION 'لا يمكن حذف مستخدم له طلبات مسجّلة (سلامة التدقيق) — عطّل حسابه بدلاً من الحذف';
  END IF;
  UPDATE portal_users       SET delegate_to  = NULL WHERE delegate_to  = p_username;
  UPDATE portal_users       SET manager_user = NULL WHERE manager_user = p_username;
  UPDATE portal_departments SET manager_user = NULL WHERE manager_user = p_username;
  DELETE FROM portal_users WHERE username = p_username;
  PERFORM portal_audit_write(NULL, 'user_deleted', v_me, 'portal',
    jsonb_build_object('deleted_user', p_username, 'role', v_role));
  RETURN jsonb_build_object('ok', true, 'deleted', p_username);
END $fn$;
REVOKE ALL ON FUNCTION portal_delete_user(text) FROM public;
GRANT EXECUTE ON FUNCTION portal_delete_user(text) TO authenticated;


-- ═══════════════════════ 13) بذور المرجع + نموذج الوظائف (المرحلة 1) ═══════════════════════
-- (مطابق لـ db/portal-migrations/001-seeds-jobs-model.sql — انظر جدول ترجمة المفاتيح هناك)

-- ═══════════════ 1) الأقسام/القطاعات الأربعة (باب 6 المرجعي) ═══════════════
-- بلا مدراء — يُسندون من شاشة الإدارة بعد إنشاء الحسابات الفعلية
-- (مستخدمو النموذج التجريبيون khalid/faisal... لا يُبذرون عمداً).

INSERT INTO portal_departments (id, name_ar, sector, active)
SELECT 'OPS', 'الصيانة والتشغيل', 'الصيانة والتشغيل', true
WHERE NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = 'OPS');

INSERT INTO portal_departments (id, name_ar, sector, active)
SELECT 'CON', 'الإنشاءات', 'الإنشاءات', true
WHERE NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = 'CON');

INSERT INTO portal_departments (id, name_ar, sector, active)
SELECT 'GA', 'الإدارة العامة', 'الإدارة العامة', true
WHERE NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = 'GA');

INSERT INTO portal_departments (id, name_ar, sector, active)
SELECT 'LOG', 'النقليات', 'النقليات', true
WHERE NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = 'LOG');


-- ═══════════════ 2) كتالوج الوظائف الـ18 (الباب 4 حرفياً) ═══════════════

-- الإدارة العليا
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'gm', 'المدير العام', 'الإدارة العليا', 'all', '{}'::jsonb,
       'صلاحية كاملة على النظام: اعتماد أعلى الشرائح، إدارة المستخدمين والإعدادات.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'gm');

-- المشتريات
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'proc_mgr', 'مدير المشتريات', 'المشتريات', 'all',
       '{"can_manage_procurement":true,"can_approve_award":true,"can_issue_po":true,"can_edit":true,"can_create":true,"can_see_finance":true}'::jsonb,
       'إدارة التسعير والمقارنة والتعميد وإصدار أوامر الشراء وطلبات الصرف.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'proc_mgr');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'proc_officer', 'مسؤول مشتريات', 'المشتريات', 'all',
       '{"can_manage_procurement":true,"can_edit":true,"can_create":true}'::jsonb,
       'تنفيذ التسعير وطلب العروض والمقارنة ومتابعة الموردين — دون اعتماد التعميد.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'proc_officer');

-- المالية
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'fin_mgr', 'المدير المالي', 'المالية', 'all',
       '{"can_approve_finance":true,"can_approve_stage":true,"can_disburse":true,"can_see_finance":true}'::jsonb,
       'التحقق المالي المسبق، واعتماد وتنفيذ الصرف (تم الصرف).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'fin_mgr');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'accountant', 'محاسب / رئيس حسابات', 'المالية', 'all',
       '{"can_disburse":true,"can_see_finance":true}'::jsonb,
       'اعتماد وتنفيذ الصرف (تم الصرف) — دون التحقق المالي المسبق للحاجة.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'accountant');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'fin_officer', 'موظف مالية', 'المالية', 'all',
       '{"can_see_finance":true}'::jsonb,
       'اطّلاع كامل على العمليات المالية والمشتريات دون صلاحية قرار.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'fin_officer');

-- الإدارة العامة
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'services_mgr', 'مدير الخدمات المساندة', 'الإدارة العامة', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات الإدارة العامة (المرحلة الأولى) ضمن نطاقه.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'services_mgr');

-- مدراء القطاعات
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'sector_mgr_ops', 'مدير قطاع الصيانة والتشغيل', 'مدراء القطاعات', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات قطاع الصيانة والتشغيل (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'sector_mgr_ops');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'sector_mgr_con', 'مدير قطاع الإنشاءات', 'مدراء القطاعات', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات قطاع الإنشاءات (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'sector_mgr_con');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'sector_mgr_log', 'مدير قطاع النقليات', 'مدراء القطاعات', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات قطاع النقليات (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'sector_mgr_log');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'sector_mgr_infra', 'مدير قطاع البنية التحتية والطرق', 'مدراء القطاعات', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات قطاع البنية التحتية والطرق (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'sector_mgr_infra');

-- المشاريع والعمليات
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'proj_mgr', 'مدير مشاريع القطاعات', 'المشاريع', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد ومتابعة طلبات مشاريع قطاعه (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'proj_mgr');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'proj_coord', 'منسّق مشاريع', 'المشاريع', 'sector',
       '{"can_create":true}'::jsonb,
       'رفع الطلبات ومتابعتها ضمن مشاريع قطاعه.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'proj_coord');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'ops_coord', 'منسّق عمليات', 'العمليات', 'sector',
       '{"can_create":true}'::jsonb,
       'رفع الطلبات ومتابعتها ضمن قطاعه.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'ops_coord');

-- الإشراف والعام
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'supervisor', 'مشرف قطاع', 'الإشراف', 'sector',
       '{"can_create":true}'::jsonb,
       'رفع الطلبات ومتابعتها ضمن قطاعه — دون اعتماد.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'supervisor');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'employee', 'موظّف', 'عام', 'own',
       '{"can_create":true}'::jsonb,
       'رفع الطلبات ومتابعة طلباته الخاصة.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'employee');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'warehouse', 'أمين مستودع', 'المستودع', 'all',
       '{"can_verify_stock":true}'::jsonb,
       'اطّلاع ومتابعة الاستلام والمخزون (تسجيل الاستلام).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'warehouse');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'qc', 'مراقب جودة', 'الجودة', 'all', '{}'::jsonb,
       'اطّلاع ومتابعة مطابقة المواصفات.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'qc');


-- ═══════════════ 3) سلاسل اعتماد القطاعات (buildSectorWorkflows بالأدوار) ═══════════════
-- كل سلسلة أولى ثابتة الشكل: مدير القطاع ← التحقق المالي المسبق ← إذن التسعير.
-- المرحلتان 2 و3 بالأدوار (can_approve_finance / can_manage_procurement) لا
-- بأسماء النموذج التجريبية — قرار المالك الموثّق. SLA لكل مرحلة 24 ساعة.

INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
SELECT 'wf-admin', 'طلبات الإدارة العامة / الموظفين', 10, 'الإدارة العامة', '[
  {"seq":1,"label":"اعتماد مدير الخدمات المساندة","resolver":"dept_manager","sla":24},
  {"seq":2,"label":"التحقق المالي المسبق","resolver":"role","role_key":"can_approve_finance","sla":24},
  {"seq":3,"label":"الإذن ببدء التسعير — مدير المشتريات","resolver":"role","role_key":"can_manage_procurement","sla":24}
]'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = 'wf-admin');

INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
SELECT 'wf-sec-ops', 'قطاع: الصيانة والتشغيل', 20, 'الصيانة والتشغيل', '[
  {"seq":1,"label":"اعتماد مدير قطاع الصيانة والتشغيل","resolver":"dept_manager","sla":24},
  {"seq":2,"label":"التحقق المالي المسبق","resolver":"role","role_key":"can_approve_finance","sla":24},
  {"seq":3,"label":"الإذن ببدء التسعير — مدير المشتريات","resolver":"role","role_key":"can_manage_procurement","sla":24}
]'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = 'wf-sec-ops');

INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
SELECT 'wf-sec-con', 'قطاع: الإنشاءات', 21, 'الإنشاءات', '[
  {"seq":1,"label":"اعتماد مدير قطاع الإنشاءات","resolver":"dept_manager","sla":24},
  {"seq":2,"label":"التحقق المالي المسبق","resolver":"role","role_key":"can_approve_finance","sla":24},
  {"seq":3,"label":"الإذن ببدء التسعير — مدير المشتريات","resolver":"role","role_key":"can_manage_procurement","sla":24}
]'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = 'wf-sec-con');

INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
SELECT 'wf-sec-log', 'قطاع: النقليات', 22, 'النقليات', '[
  {"seq":1,"label":"اعتماد مدير قطاع النقليات","resolver":"dept_manager","sla":24},
  {"seq":2,"label":"التحقق المالي المسبق","resolver":"role","role_key":"can_approve_finance","sla":24},
  {"seq":3,"label":"الإذن ببدء التسعير — مدير المشتريات","resolver":"role","role_key":"can_manage_procurement","sla":24}
]'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = 'wf-sec-log');


-- ═══════════════ 4) DoA: فصل «اعتماد التعميد» عن «إدارة التسعير» ═══════════════
-- في النموذج approveAward صلاحية مستقلة عن manageRfq (مسؤول المشتريات يسعّر
-- ولا يعتمد). الشريحتان الدنيتان كانتا can_manage_procurement — تُحدَّثان إلى
-- can_approve_award (يحملها مدير المشتريات لا مسؤول المشتريات). تحديث موثّق
-- ومتعمّد؛ الشريحتان العليتان (can_manage_users = المدير العام) بلا تغيير.

UPDATE portal_doa SET award_role_key = 'can_approve_award'
WHERE award_role_key = 'can_manage_procurement'
  AND label IN ('أقل من 500', '500 – 100,000');


-- ═══════════════ 5) RPCs نموذج الوظائف ═══════════════

-- إسناد وظيفة لمستخدم: ينسخ صلاحيات الوظيفة (الإرث) ويضبط الدور.
-- gm = أدمن (كما النموذج: admin=(job==='gm')). حماية «آخر أدمن»: لا يُسمح
-- بإسناد وظيفة غير gm لأدمن إن كان الأدمن النشط الوحيد.
CREATE OR REPLACE FUNCTION portal_apply_job(p_username text, p_job_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_job portal_jobs%ROWTYPE;
  v_user portal_users%ROWTYPE;
  v_new_role text;
  v_other_admins int;
  v_grants_admin boolean;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  SELECT * INTO v_job FROM portal_jobs WHERE key = p_job_key AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'وظيفة غير موجودة أو غير مفعّلة'; END IF;

  -- منع تصعيد الصلاحية: إسناد وظيفة تمنح الأدمن (gm) أو مفاتيح إدارية مانحة
  -- (إدارة المستخدمين/المنشأة) يتطلّب أدمن حقيقياً — لا يكفي can_manage_users.
  v_grants_admin := (p_job_key = 'gm')
    OR coalesce((v_job.permissions->>'can_manage_users')::boolean, false)
    OR coalesce((v_job.permissions->>'can_manage_company')::boolean, false);
  IF v_grants_admin AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد صلاحيات إدارية عليا يتطلّب صلاحية أدمن كاملة';
  END IF;

  SELECT * INTO v_user FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;

  v_new_role := CASE WHEN p_job_key = 'gm' THEN 'admin' ELSE 'user' END;
  IF v_user.role = 'admin' AND v_new_role <> 'admin' THEN
    -- قفل استشاري يمنع سباق تجريد آخر أدمن (TOCTOU) بين عمليتين متزامنتين
    PERFORM pg_advisory_xact_lock(hashtext('portal_admin_guard'));
    SELECT count(*) INTO v_other_admins FROM portal_users
      WHERE role = 'admin' AND active AND username <> p_username;
    IF v_other_admins = 0 THEN
      RAISE EXCEPTION 'لا يمكن تجريد آخر أدمن نشط من صلاحياته — أسند gm لغيره أولاً';
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET job_key = p_job_key, permissions = v_job.permissions, role = v_new_role
    WHERE username = p_username;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_assigned', v_me, 'portal',
    jsonb_build_object('user', p_username, 'job', p_job_key));
  RETURN jsonb_build_object('ok', true, 'job', p_job_key, 'role', v_new_role);
END $fn$;

-- حفظ/تعديل وظيفة: التعديل يسري فوراً على كل حامليها (سيناريو 6-20).
CREATE OR REPLACE FUNCTION portal_save_job(p_key text, p_title text, p_category text,
    p_scope text, p_permissions jsonb, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_holders int; v_k text;
  v_allowed text[] := ARRAY['can_approve_stage','can_approve_award','can_issue_po','can_manage_procurement',
    'can_approve_finance','can_disburse','can_create','can_edit','can_manage_users','can_see_finance',
    'can_verify_stock','can_manage_company','can_approve_committee'];
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'تعديل الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  IF coalesce(trim(p_key),'') = '' OR coalesce(trim(p_title),'') = '' THEN
    RAISE EXCEPTION 'مفتاح الوظيفة واسمها مطلوبان';
  END IF;
  IF p_scope NOT IN ('own','sector','all') THEN RAISE EXCEPTION 'نطاق غير صالح (own/sector/all)'; END IF;
  IF p_key = 'gm' AND NOT (p_permissions = '{}'::jsonb OR p_permissions IS NULL) THEN
    RAISE EXCEPTION 'وظيفة المدير العام محمية — صلاحياتها من دور الأدمن مباشرة';
  END IF;

  -- قائمة بيضاء: أي مفتاح مجهول يُرفض (يمنع صكّ صلاحيات مخترَعة).
  FOR v_k IN SELECT jsonb_object_keys(coalesce(p_permissions,'{}'::jsonb)) LOOP
    IF NOT (v_k = ANY(v_allowed)) THEN RAISE EXCEPTION 'مفتاح صلاحية غير معروف: %', v_k; END IF;
  END LOOP;
  -- صلاحيات إدارية مانحة لا يصكّها إلا أدمن حقيقي.
  IF (coalesce((p_permissions->>'can_manage_users')::boolean,false)
      OR coalesce((p_permissions->>'can_manage_company')::boolean,false))
     AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إنشاء وظيفة بصلاحيات إدارية عليا يتطلّب صلاحية أدمن كاملة';
  END IF;

  INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
  VALUES (p_key, trim(p_title), p_category, p_scope, coalesce(p_permissions,'{}'::jsonb), p_description, true)
  ON CONFLICT (key) DO UPDATE SET title = EXCLUDED.title, category = EXCLUDED.category,
    scope = EXCLUDED.scope, permissions = EXCLUDED.permissions, description = EXCLUDED.description;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET permissions = coalesce(p_permissions,'{}'::jsonb) WHERE job_key = p_key;
  GET DIAGNOSTICS v_holders = ROW_COUNT;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_saved', v_me, 'portal',
    jsonb_build_object('job', p_key, 'holders_updated', v_holders));
  RETURN jsonb_build_object('ok', true, 'holders_updated', v_holders);
END $fn$;

-- حذف وظيفة: محمي بالدالة — لا حذف gm، ولا وظيفة يحملها موظفون.
CREATE OR REPLACE FUNCTION portal_delete_job(p_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_holders int;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'حذف الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  IF p_key = 'gm' THEN RAISE EXCEPTION 'لا تُحذف وظيفة المدير العام'; END IF;
  SELECT count(*) INTO v_holders FROM portal_users WHERE job_key = p_key;
  IF v_holders > 0 THEN RAISE EXCEPTION 'لا يمكن حذف وظيفة يحملها % موظف — انقلهم أولاً', v_holders; END IF;
  DELETE FROM portal_jobs WHERE key = p_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'الوظيفة غير موجودة'; END IF;
  PERFORM portal_audit_write(NULL, 'job_deleted', v_me, 'portal', jsonb_build_object('job', p_key));
  RETURN jsonb_build_object('ok', true);
END $fn$;



-- ═══════════════════════ 14) إدارة الموردين والأقسام (المرحلة 5) ═══════════════════════
-- (مطابق لـ db/portal-migrations/004-admin-suppliers.sql)

-- 1) جدول الموردين (كتالوج مرجعي)
CREATE TABLE IF NOT EXISTS portal_suppliers (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  cr          TEXT,
  vat         TEXT,
  iban        TEXT,
  contact     TEXT,
  active      BOOLEAN NOT NULL DEFAULT true,
  created_by  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE portal_suppliers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON portal_suppliers;
CREATE POLICY "auth_all" ON portal_suppliers FOR ALL TO authenticated USING (true) WITH CHECK (true);
-- الكتابة محكومة بحارس الإعدادات (أدمن/can_manage_users) — نفس نمط الأقسام/الوظائف.
DROP TRIGGER IF EXISTS trg_portal_suppliers_guard ON portal_suppliers;
CREATE TRIGGER trg_portal_suppliers_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_suppliers
  FOR EACH ROW EXECUTE FUNCTION portal_config_guard();

-- 2) حفظ/تعديل قسم + إنشاء سلسلته تلقائياً إن كان قطاعاً جديداً (6-19).
--    القطاعات غير «الإدارة العامة» تُنشأ لها سلسلة 3 مراحل (مدير القطاع ← مالية
--    ← مشتريات)؛ لا يُعاد بناء سلسلة قائمة (حفاظاً على تعديلات المصمّم).
CREATE OR REPLACE FUNCTION portal_save_department(
    p_id text, p_name text, p_sector text, p_manager text DEFAULT NULL, p_active boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_wf_id text; v_sec text;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_has_perm('can_manage_company') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إدارة الأقسام تتطلّب صلاحية إدارية';
  END IF;
  IF coalesce(trim(p_id),'') = '' OR coalesce(trim(p_name),'') = '' THEN RAISE EXCEPTION 'معرّف القسم واسمه مطلوبان'; END IF;
  v_sec := coalesce(nullif(trim(p_sector),''), trim(p_name));

  INSERT INTO portal_departments (id, name_ar, sector, manager_user, active)
    VALUES (trim(p_id), trim(p_name), v_sec, nullif(p_manager,''), coalesce(p_active,true))
  ON CONFLICT (id) DO UPDATE SET name_ar = EXCLUDED.name_ar, sector = EXCLUDED.sector,
    manager_user = EXCLUDED.manager_user, active = EXCLUDED.active;

  -- إنشاء سلسلة القطاع إن لزم (غير الإدارة العامة، ولا سلسلة قائمة لنفس القطاع)
  IF v_sec <> 'الإدارة العامة' THEN
    v_wf_id := 'wf-sec-' || regexp_replace(v_sec, '\s+', '_', 'g');
    IF NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = v_wf_id) THEN
      INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
      VALUES (v_wf_id, 'قطاع: ' || v_sec, 25, v_sec, jsonb_build_array(
        jsonb_build_object('seq',1,'label','اعتماد مدير قطاع '||v_sec,'resolver','dept_manager','sla',24),
        jsonb_build_object('seq',2,'label','التحقق المالي المسبق','resolver','role','role_key','can_approve_finance','sla',24),
        jsonb_build_object('seq',3,'label','الإذن ببدء التسعير — مدير المشتريات','resolver','role','role_key','can_manage_procurement','sla',24)
      ), true);
    END IF;
  END IF;

  PERFORM portal_audit_write(NULL, 'dept_saved', v_me, 'portal', jsonb_build_object('dept', p_id));
  RETURN jsonb_build_object('ok', true, 'id', trim(p_id));
END $fn$;

-- 3) حذف قسم محمي (6-19): يُمنع إن كان له طلبات أو موظفون، أو كان آخر قسم.
CREATE OR REPLACE FUNCTION portal_delete_department(p_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_reqs int; v_users int; v_total int;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_has_perm('can_manage_company') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إدارة الأقسام تتطلّب صلاحية إدارية';
  END IF;
  SELECT count(*) INTO v_reqs FROM portal_requests WHERE department_id = p_id;
  IF v_reqs > 0 THEN RAISE EXCEPTION 'لا يمكن حذف قسم له % طلب — أغلقه بدل الحذف', v_reqs; END IF;
  SELECT count(*) INTO v_users FROM portal_users WHERE department_id = p_id;
  IF v_users > 0 THEN RAISE EXCEPTION 'لا يمكن حذف قسم مرتبط بـ % موظف — انقلهم أولاً', v_users; END IF;
  SELECT count(*) INTO v_total FROM portal_departments;
  IF v_total <= 1 THEN RAISE EXCEPTION 'لا يمكن حذف آخر قسم'; END IF;
  DELETE FROM portal_departments WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'القسم غير موجود'; END IF;
  PERFORM portal_audit_write(NULL, 'dept_deleted', v_me, 'portal', jsonb_build_object('dept', p_id));
  RETURN jsonb_build_object('ok', true);
END $fn$;

-- 4) حذف مورد محمي (6-21): يُمنع إن كان مرتبطاً بعروض/تعميدات (بالاسم).
CREATE OR REPLACE FUNCTION portal_delete_supplier(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_name text; v_linked int;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_has_perm('can_manage_company') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إدارة الموردين تتطلّب صلاحية إدارية';
  END IF;
  SELECT name INTO v_name FROM portal_suppliers WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'المورد غير موجود'; END IF;
  SELECT count(*) INTO v_linked FROM portal_offers WHERE supplier_name = v_name;
  IF v_linked > 0 THEN RAISE EXCEPTION 'لا يمكن حذف مورد مرتبط بـ % عرض/تعميد — عطّله بدل الحذف', v_linked; END IF;
  DELETE FROM portal_suppliers WHERE id = p_id;
  PERFORM portal_audit_write(NULL, 'supplier_deleted', v_me, 'portal', jsonb_build_object('supplier', v_name));
  RETURN jsonb_build_object('ok', true);
END $fn$;


-- ════════════════════════════════════════════════════════════════════════
-- 5) إصلاحات أمنية (من الفحص العدائي متعدد الوكلاء)


-- ════════════════════════════════════════════════════════════════════════
--  للتراجع الفوري الكامل (يحذف كل كائنات البوابة المعزولة — لا يمسّ أي شيء
--  آخر في قاعدة البيانات):
--
--   DROP TABLE IF EXISTS portal_email_tokens, portal_notifications, portal_audit,
--     portal_receipts, portal_payments, portal_award_approvals, portal_award,
--     portal_offers, portal_approvals, portal_request_items, portal_requests,
--     portal_workflows, portal_doa, portal_jobs, portal_departments, portal_users,
--     portal_suppliers, portal_settings CASCADE;
--   DROP FUNCTION IF EXISTS portal_username, portal_is_admin, portal_is_service,
--     portal_is_privileged, portal_has_perm, portal_effective_approver, portal_resolve_stage,
--     portal_create_request, portal_submit_request, portal_pr_transition, portal_pr_transition_email,
--     portal_submit_offer, portal_award, portal_award_transition,
--     portal_payment_request, portal_payment_transition, portal_record_receipt,
--     portal_cancel_request, portal_gen_token, portal_create_token,
--     portal_apply_job, portal_save_job, portal_delete_job,
--     portal_setting_bool, portal_setting_num, portal_qualified_approver, portal_resume_hold,
--     portal_sla_hours, portal_set_due, portal_run_sla, portal_audit_write,
--     portal_approvals_guard, portal_request_status_guard, portal_award_approvals_guard,
--     portal_award_guard, portal_payments_guard, portal_locked_guard, portal_users_guard,
--     portal_config_guard, portal_audit_immutable CASCADE;
--   DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
--     PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname='portal-sla'; END IF; END $$;
-- ════════════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════════════════
-- تصليب أمني (الهجرة 019) — تجاوزات نهائية تُطبَّق بعد كل التعريفات أعلاه
-- (CREATE OR REPLACE / DROP POLICY: النسخة الأخيرة تفوز — الحالة النهائية = standalone+019)
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (ب) سحب الدوال الخادمية من PUBLIC (تُستدعى حصراً بمفتاح service_role) ──
REVOKE ALL ON FUNCTION portal_create_token(text,text,integer,text,numeric) FROM public;
REVOKE ALL ON FUNCTION portal_create_token(text,text,integer,text,numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_create_token(text,text,integer,text,numeric) TO service_role;
REVOKE ALL ON FUNCTION portal_pr_transition_email(text,text,text) FROM public;
REVOKE ALL ON FUNCTION portal_pr_transition_email(text,text,text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_pr_transition_email(text,text,text) TO service_role;
REVOKE ALL ON FUNCTION portal_audit_write(text,text,text,text,jsonb) FROM public;
REVOKE ALL ON FUNCTION portal_audit_write(text,text,text,text,jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_audit_write(text,text,text,text,jsonb) TO service_role;

-- ── (ج) حارس المستخدمين: رفض افتراضي — لا كتابة مباشرة إلا privileged/admin/عبر RPC (علم الانتقال) ──
--  كان يمرّر أي كتابة لحامل can_manage_users → ترقية ذاتية إلى admin ومنح صلاحيات صرف/اعتماد بـPATCH مباشر.
CREATE OR REPLACE FUNCTION portal_users_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  -- حامل can_manage_users (غير أدمن) عبر كتابة مباشرة: يُسمح بغير التصعيد فقط.
  IF portal_has_perm('can_manage_users') THEN
    IF TG_OP <> 'DELETE' THEN
      IF coalesce(NEW.role,'') = 'admin' THEN
        RAISE EXCEPTION 'منح دور الأدمن يتطلّب صلاحية أدمن كاملة';
      END IF;
      IF coalesce(NEW.permissions,'{}'::jsonb) ?| ARRAY['can_manage_users','can_manage_company','can_disburse',
           'can_approve_award','can_approve_finance','can_approve_stage','can_manage_procurement',
           'can_issue_po','can_approve_committee','can_see_finance'] THEN
        RAISE EXCEPTION 'منح صلاحيات اعتماد/صرف/إدارية عبر تعديل المستخدم يتطلّب صلاحية أدمن كاملة';
      END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
  END IF;
  RAISE EXCEPTION 'تعديل المستخدمين أو صلاحياتهم يتطلّب صلاحية «إدارة المستخدمين»';
END $fn$;

-- ── (ج) حارس الضبط: رفض افتراضي — لا كتابة مباشرة إلا privileged/admin/عبر RPC (علم الانتقال) ──
--  كان يمرّر can_manage_users/can_manage_company → تخريب DoA/سلاسل الاعتماد/الإعدادات بـPATCH مباشر متجاوزاً القوائم البيضاء.
CREATE OR REPLACE FUNCTION portal_config_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل إعدادات البوابة يتطلّب صلاحية أدمن (عبر دوال البوابة فقط)';
END $fn$;

-- ── (أ) طلب الصرف: سقف المبلغ + منع التعدّد + فحص الحالة ──
CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric,
    p_custody_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
  v_iban text; v_details jsonb := coalesce(p_details, '{}'::jsonb);
  v_winner numeric; v_vat numeric; v_max numeric;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'نوع صرف غير صالح'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'مبلغ غير صالح'; END IF;

  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
  ELSIF p_kind = 'custody' THEN
    IF coalesce(p_custody_to,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = p_custody_to AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)';
    END IF;
  ELSIF p_kind = 'credit' THEN
    IF (v_details->>'due_date') IS NULL OR (v_details->>'due_date')::date IS NULL THEN
      RAISE EXCEPTION 'تاريخ الاستحقاق مطلوب للصرف الآجل';
    END IF;
  END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'payment' OR v_req.status <> 'awarded' THEN RAISE EXCEPTION 'الطلب ليس جاهزاً للصرف'; END IF;

  -- منع تعدّد الصرف: لا يُسمح بأكثر من طلب صرف قائم واحد لكل طلب (يُقصي المرفوض/المُعاد).
  IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id
             AND status IN ('pending_pay','approved_pay','disbursed')) THEN
    RAISE EXCEPTION 'يوجد طلب صرف قائم لهذا الطلب — لا يُسمح بأكثر من صرف واحد';
  END IF;

  -- سقف المبلغ: لا يتجاوز قيمة التعميد شاملةً الضريبة (يمنع صرف مبلغ أكبر من المُعمَّد).
  SELECT winner_total INTO v_winner FROM portal_award WHERE request_id = p_request_id;
  IF v_winner IS NULL OR v_winner <= 0 THEN RAISE EXCEPTION 'لا تعميد مُعتمَد لهذا الطلب'; END IF;
  v_vat := portal_setting_num('vat', 15);
  v_max := round(v_winner * (1 + v_vat/100.0));
  IF p_amount > v_max THEN
    RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز قيمة التعميد شاملة الضريبة (%)', p_amount, v_max;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details)
    VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb)) RETURNING id INTO v_id;
  UPDATE portal_requests SET status = 'payment_pending', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal', jsonb_build_object('kind', p_kind, 'amount', p_amount));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

-- ── (أ) انتقال الصرف: إعادة فحص حالة الطلب الأب (يمنع الصرف على طلب مُلغى/مُغلق) ──
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text, p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text; v_req_status text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  -- إعادة فحص حالة الطلب الأب (بقفل): كل عمليات الصرف تتطلّب أن يكون الطلب في payment_pending —
  -- يمنع تنفيذ/اعتماد صرف على صف متبقٍّ بعد إلغاء الطلب أو خروجه من طور الصرف.
  SELECT status INTO v_req_status FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  IF v_req_status IS DISTINCT FROM 'payment_pending' THEN
    RAISE EXCEPTION 'حالة الطلب (%) لا تسمح بعملية الصرف', coalesce(v_req_status,'?');
  END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;
    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ طلبته بنفسك (فصل المهام الثلاثي)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now() WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal', jsonb_build_object('payment_id', p_payment_id));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text) TO authenticated;

-- ── (د) التعميد: فرض عدد العروض المطلوب (يمنع مصدراً وحيداً متنكّراً كمنافسة) ──
CREATE OR REPLACE FUNCTION portal_award(p_request_id text, p_winner_offer_id bigint, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_offer portal_offers%ROWTYPE;
  v_doa portal_doa%ROWTYPE;
  v_lowest numeric; v_offer_count int;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  SELECT * INTO v_offer FROM portal_offers WHERE id = p_winner_offer_id AND request_id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'العرض غير موجود'; END IF;

  -- فرض عدد العروض حسب DoA/نوع الشراء (كان يُخزَّن ولا يُفرَض).
  SELECT count(*) INTO v_offer_count FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer_count < coalesce(v_req.quotes_required, 1) THEN
    RAISE EXCEPTION 'عدد العروض المُدخَلة (%) أقل من المطلوب (%) — أضِف عروضاً أو استخدم نوع شراء استثنائياً بمبرّر',
      v_offer_count, v_req.quotes_required;
  END IF;

  SELECT min(total) INTO v_lowest FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer.total > v_lowest AND coalesce(trim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'اختيار عرض غير الأقل سعراً يتطلّب مبرّراً موثَّقاً';
  END IF;

  SELECT * INTO v_doa FROM portal_doa WHERE max_value IS NULL OR v_offer.total <= max_value ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'تعذّر تحديد مصفوفة الصلاحيات لهذه القيمة — أضِف قاعدة DoA'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_award(request_id, winner_offer_id, winner_total, award_reason, doa_id, status, awarded_by)
    VALUES (p_request_id, p_winner_offer_id, v_offer.total, p_reason, v_doa.id, 'pending', v_me)
  ON CONFLICT (request_id) DO UPDATE SET winner_offer_id = EXCLUDED.winner_offer_id, winner_total = EXCLUDED.winner_total,
    award_reason = EXCLUDED.award_reason, doa_id = EXCLUDED.doa_id, status = 'pending', awarded_by = EXCLUDED.awarded_by;
  DELETE FROM portal_award_approvals WHERE request_id = p_request_id;
  INSERT INTO portal_award_approvals(request_id, seq, stage_label, role_key, approver)
    VALUES (p_request_id, 1, 'اعتماد التعميد', v_doa.award_role_key, NULL);
  UPDATE portal_requests SET status = 'award_review', phase = 'award', current_seq = 1, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'awarded', v_me, 'portal', jsonb_build_object('supplier', v_offer.supplier_name, 'total', v_offer.total));
  RETURN jsonb_build_object('ok', true, 'status', 'award_review');
END $fn$;

-- ── (د) الاستلام: رفض كمية سالبة (كان يُنقِص المستلَم — تلاعب بالسجل) ──
CREATE OR REPLACE FUNCTION portal_record_receipt(p_request_id text, p_lines jsonb, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_line jsonb;
  v_remaining numeric;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_verify_stock') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'receipt' THEN RAISE EXCEPTION 'الطلب ليس بانتظار استلام'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  FOR v_line IN SELECT * FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) LOOP
    IF coalesce((v_line->>'qty')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'كمية استلام غير صالحة (يجب أن تكون موجبة)';
    END IF;
    UPDATE portal_request_items
      SET received_qty = LEAST(qty, received_qty + (v_line->>'qty')::numeric)
      WHERE id = (v_line->>'item_id')::bigint AND request_id = p_request_id;
  END LOOP;

  INSERT INTO portal_receipts(request_id, received_by, note, lines) VALUES (p_request_id, v_me, p_note, p_lines);
  SELECT sum(GREATEST(qty - received_qty, 0)) INTO v_remaining FROM portal_request_items WHERE request_id = p_request_id;

  IF coalesce(v_remaining, 0) <= 0 THEN
    UPDATE portal_requests SET status = 'closed', phase = 'closed', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    PERFORM portal_audit_write(p_request_id, 'closed', v_me, 'portal', '{}'::jsonb);
  ELSE
    UPDATE portal_requests SET updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'receipt_recorded', v_me, 'portal', jsonb_build_object('note', p_note, 'remaining', v_remaining));
  RETURN jsonb_build_object('ok', true, 'remaining', coalesce(v_remaining,0));
END $fn$;

-- ── (ج/د) محرّر الوظائف: منع صكّ صلاحيات اعتماد/صرف لغير الأدمن + رفع علم الانتقال حول كتابة الضبط ──
CREATE OR REPLACE FUNCTION portal_save_job(p_key text, p_title text, p_category text,
    p_scope text, p_permissions jsonb, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_holders int; v_k text;
  v_allowed text[] := ARRAY['can_approve_stage','can_approve_award','can_issue_po','can_manage_procurement',
    'can_approve_finance','can_disburse','can_create','can_edit','can_manage_users','can_see_finance',
    'can_verify_stock','can_manage_company','can_approve_committee'];
  v_sensitive text[] := ARRAY['can_manage_users','can_manage_company','can_disburse','can_approve_award',
    'can_approve_finance','can_approve_stage','can_manage_procurement','can_issue_po','can_approve_committee','can_see_finance'];
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'تعديل الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  IF coalesce(trim(p_key),'') = '' OR coalesce(trim(p_title),'') = '' THEN
    RAISE EXCEPTION 'مفتاح الوظيفة واسمها مطلوبان';
  END IF;
  IF p_scope NOT IN ('own','sector','all') THEN RAISE EXCEPTION 'نطاق غير صالح (own/sector/all)'; END IF;
  IF p_key = 'gm' AND NOT (p_permissions = '{}'::jsonb OR p_permissions IS NULL) THEN
    RAISE EXCEPTION 'وظيفة المدير العام محمية — صلاحياتها من دور الأدمن مباشرة';
  END IF;
  FOR v_k IN SELECT jsonb_object_keys(coalesce(p_permissions,'{}'::jsonb)) LOOP
    IF NOT (v_k = ANY(v_allowed)) THEN RAISE EXCEPTION 'مفتاح صلاحية غير معروف: %', v_k; END IF;
  END LOOP;
  -- صلاحيات اعتماد/صرف/إدارية لا يصكّها إلا أدمن حقيقي (كان القيد يقتصر على can_manage_users/company).
  IF NOT (portal_is_admin() OR portal_is_privileged())
     AND (coalesce(p_permissions,'{}'::jsonb) ?| v_sensitive) THEN
    RAISE EXCEPTION 'إنشاء/تعديل وظيفة تمنح صلاحيات اعتماد/صرف/إدارية يتطلّب صلاحية أدمن كاملة';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
  VALUES (p_key, trim(p_title), p_category, p_scope, coalesce(p_permissions,'{}'::jsonb), p_description, true)
  ON CONFLICT (key) DO UPDATE SET title = EXCLUDED.title, category = EXCLUDED.category,
    scope = EXCLUDED.scope, permissions = EXCLUDED.permissions, description = EXCLUDED.description;
  UPDATE portal_users SET permissions = coalesce(p_permissions,'{}'::jsonb) WHERE job_key = p_key;
  GET DIAGNOSTICS v_holders = ROW_COUNT;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_saved', v_me, 'portal',
    jsonb_build_object('job', p_key, 'holders_updated', v_holders));
  RETURN jsonb_build_object('ok', true, 'holders_updated', v_holders);
END $fn$;

-- ── (ج/د) إسناد وظيفة: منع إسناد صلاحيات حسّاسة لغير الأدمن + منع الإسناد الذاتي (فصل المهام) ──
CREATE OR REPLACE FUNCTION portal_apply_job(p_username text, p_job_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_job portal_jobs%ROWTYPE;
  v_user portal_users%ROWTYPE;
  v_new_role text;
  v_other_admins int;
  v_grants_sensitive boolean;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  SELECT * INTO v_job FROM portal_jobs WHERE key = p_job_key AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'وظيفة غير موجودة أو غير مفعّلة'; END IF;

  v_grants_sensitive := (p_job_key = 'gm')
    OR (coalesce(v_job.permissions,'{}'::jsonb) ?| ARRAY['can_manage_users','can_manage_company','can_disburse',
        'can_approve_award','can_approve_finance','can_approve_stage','can_manage_procurement',
        'can_issue_po','can_approve_committee','can_see_finance']);
  IF v_grants_sensitive AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد صلاحيات اعتماد/صرف/إدارية يتطلّب صلاحية أدمن كاملة';
  END IF;
  IF p_username = v_me AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'لا يمكنك إسناد وظيفة لنفسك (فصل المهام)';
  END IF;

  SELECT * INTO v_user FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;

  v_new_role := CASE WHEN p_job_key = 'gm' THEN 'admin' ELSE 'user' END;
  IF v_user.role = 'admin' AND v_new_role <> 'admin' THEN
    PERFORM pg_advisory_xact_lock(hashtext('portal_admin_guard'));
    SELECT count(*) INTO v_other_admins FROM portal_users
      WHERE role = 'admin' AND active AND username <> p_username;
    IF v_other_admins = 0 THEN
      RAISE EXCEPTION 'لا يمكن تجريد آخر أدمن نشط من صلاحياته — أسند gm لغيره أولاً';
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET job_key = p_job_key, permissions = v_job.permissions, role = v_new_role
    WHERE username = p_username;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_assigned', v_me, 'portal',
    jsonb_build_object('user', p_username, 'job', p_job_key));
  RETURN jsonb_build_object('ok', true, 'job', p_job_key, 'role', v_new_role);
END $fn$;

-- ── (هـ) RLS: بوابة مالية على قراءة الصرف (كان أي دور all-scope يرى كل الآيبانات) ──
DROP POLICY IF EXISTS "see_by_request" ON portal_payments;
CREATE POLICY "see_by_request" ON portal_payments FOR SELECT TO authenticated
  USING (portal_can_see_request(request_id)
         AND (portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
              OR portal_has_perm('can_disburse') OR portal_is_admin()
              OR EXISTS (SELECT 1 FROM portal_requests r WHERE r.id = request_id AND r.requester = portal_username())));

-- ── (هـ) RLS: تقييد قراءة الموردين (آيبان/سجل تجاري) على المشتريات/المالية/الأدمن ──
DROP POLICY IF EXISTS "auth_all" ON portal_suppliers;
DROP POLICY IF EXISTS "supp_read" ON portal_suppliers;
DROP POLICY IF EXISTS "supp_ins"  ON portal_suppliers;
DROP POLICY IF EXISTS "supp_upd"  ON portal_suppliers;
DROP POLICY IF EXISTS "supp_del"  ON portal_suppliers;
CREATE POLICY "supp_read" ON portal_suppliers FOR SELECT TO authenticated
  USING (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_see_finance')
         OR portal_has_perm('can_manage_users') OR portal_is_admin());
CREATE POLICY "supp_ins" ON portal_suppliers FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "supp_upd" ON portal_suppliers FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "supp_del" ON portal_suppliers FOR DELETE TO authenticated USING (true);


-- ═══ كشف تفتيت شرائح DoA (الهجرة 020) — إعادة تعريف portal_create_request ═══
CREATE OR REPLACE FUNCTION portal_create_request(
    p_title text, p_department_id text, p_priority text, p_items jsonb,
    p_project text, p_need_by date, p_proc_type text DEFAULT 'normal',
    p_justification text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_my_dept text; v_dept text; v_id text;
  v_item jsonb; v_seq int := 0; v_est numeric := 0; v_name text;
  v_q numeric; v_p numeric; v_quotes int;
  v_win_days numeric; v_thr numeric; v_cluster_sum numeric; v_peers int; v_all_below boolean;
  v_split boolean := false;
  v_tier_indiv int; v_tier_cluster int;
  MAXQ CONSTANT numeric := 1000000;
  MAXP CONSTANT numeric := 100000000;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (portal_has_perm('can_create') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'رفع الطلبات يتطلّب صلاحية «رفع الطلبات» — راجع الإدارة لإسناد وظيفة';
  END IF;
  IF coalesce(trim(p_title), '') = '' THEN RAISE EXCEPTION 'اكتب وصف الطلب'; END IF;
  IF coalesce(trim(p_project), '') = '' THEN RAISE EXCEPTION 'اسم المشروع مطلوب'; END IF;
  IF p_need_by IS NULL THEN RAISE EXCEPTION 'تاريخ التوريد المطلوب مطلوب'; END IF;
  IF coalesce(p_proc_type,'normal') NOT IN ('normal','single','emergency') THEN
    RAISE EXCEPTION 'نوع شراء غير صالح';
  END IF;
  IF coalesce(p_proc_type,'normal') <> 'normal' AND coalesce(trim(p_justification),'') = '' THEN
    RAISE EXCEPTION 'التبرير مطلوب لهذا النوع من الشراء';
  END IF;

  SELECT department_id INTO v_my_dept FROM portal_users WHERE username = v_me;
  IF portal_is_admin() THEN
    v_dept := coalesce(nullif(p_department_id,''), v_my_dept);
  ELSE
    IF coalesce(v_my_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم في ملفك — راجع الإدارة'; END IF;
    IF coalesce(p_department_id,'') <> '' AND p_department_id <> v_my_dept THEN
      RAISE EXCEPTION 'القطاع يُحدَّد تلقائياً من ملفك — لا يمكن اختيار قسم آخر';
    END IF;
    v_dept := v_my_dept;
  END IF;
  IF coalesce(v_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم محدَّد للطلب'; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = v_dept AND active) THEN
    RAISE EXCEPTION 'قطاعك مغلق حالياً لاستقبال الطلبات — راجع الإدارة';
  END IF;

  IF jsonb_array_length(coalesce(p_items, '[]'::jsonb)) < 1 THEN RAISE EXCEPTION 'أضِف بنداً واحداً على الأقل'; END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF coalesce(trim(v_item->>'desc'), '') = '' THEN RAISE EXCEPTION 'وصف كل بند مطلوب'; END IF;
    IF jsonb_typeof(v_item->'qty') <> 'number' OR jsonb_typeof(coalesce(v_item->'price','0'::jsonb)) <> 'number' THEN
      RAISE EXCEPTION 'كمية/سعر غير رقمي في: %', v_item->>'desc';
    END IF;
    v_q := (v_item->>'qty')::numeric;
    v_p := coalesce((v_item->>'price')::numeric, 0);
    IF v_q <= 0 OR v_q > MAXQ THEN RAISE EXCEPTION 'كمية غير منطقية في: %', v_item->>'desc'; END IF;
    IF v_p < 0 OR v_p > MAXP THEN RAISE EXCEPTION 'سعر غير منطقي في: %', v_item->>'desc'; END IF;
    v_est := v_est + v_q * v_p;
  END LOOP;

  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    v_quotes := 1;
  ELSE
    SELECT quotes_required INTO v_quotes FROM portal_doa
      WHERE max_value IS NULL OR v_est <= max_value
      ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
    v_quotes := coalesce(v_quotes, 3);
  END IF;

  v_id := 'REQ-' || to_char(now(), 'YYYYMMDD') || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
  SELECT display_name INTO v_name FROM portal_users WHERE username = v_me;

  IF portal_setting_bool('split_guard', true) THEN
    v_thr := portal_setting_num('split_threshold', 100000);
    v_win_days := portal_setting_num('split_window_days', 7);
    SELECT count(*), coalesce(sum(est_total),0), coalesce(bool_and(est_total < v_thr), true)
      INTO v_peers, v_cluster_sum, v_all_below
      FROM portal_requests
      WHERE department_id = v_dept AND status <> 'rejected'
        AND created_at >= now() - make_interval(days => v_win_days::int)
        AND created_at <= now() + make_interval(days => v_win_days::int);
    -- (1) النمط الكلاسيكي: كلٌّ منفرداً تحت العتبة والمجموع يبلغها.
    IF v_peers > 0 AND (v_cluster_sum + v_est) >= v_thr AND v_all_below AND v_est < v_thr THEN
      v_split := true;
    END IF;
    -- (2) تفتيت شرائح DoA: مجموع العنقود يقع في شريحة اعتماد أعلى من هذا الطلب منفرداً
    --     (تفتيت للتهرّب من اعتماد اللجنة/المالية/المدير العام).
    IF v_peers > 0 THEN
      SELECT priority INTO v_tier_indiv   FROM portal_doa WHERE max_value IS NULL OR v_est <= max_value
        ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
      SELECT priority INTO v_tier_cluster FROM portal_doa WHERE max_value IS NULL OR (v_cluster_sum + v_est) <= max_value
        ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
      IF coalesce(v_tier_cluster,0) > coalesce(v_tier_indiv,0) THEN v_split := true; END IF;
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_requests (id, title, department_id, requester, requester_name, priority,
                               est_total, created_by, project, need_by, proc_type, justification, note, quotes_required, split_flag)
    VALUES (v_id, trim(p_title), v_dept, v_me, v_name, coalesce(nullif(p_priority, ''), 'متوسط'),
            v_est, v_me, trim(p_project), p_need_by, coalesce(p_proc_type,'normal'),
            nullif(trim(coalesce(p_justification,'')),''), nullif(trim(coalesce(p_note,'')),''), v_quotes, v_split);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_seq := v_seq + 1;
    INSERT INTO portal_request_items (request_id, seq, description, unit, qty, unit_price)
      VALUES (v_id, v_seq, v_item->>'desc', v_item->>'unit', (v_item->>'qty')::numeric, coalesce((v_item->>'price')::numeric, 0));
  END LOOP;
  PERFORM set_config('app.portal_transition', '0', true);

  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    PERFORM portal_audit_write(v_id, 'proc_type', v_me, 'portal',
      jsonb_build_object('type', p_proc_type, 'justification', p_justification));
  END IF;
  IF v_split THEN
    PERFORM portal_audit_write(v_id, 'split_flag', v_me, 'portal',
      jsonb_build_object('cluster_sum', v_cluster_sum + v_est, 'threshold', v_thr, 'window_days', v_win_days, 'peers', v_peers,
                         'tier_indiv', v_tier_indiv, 'tier_cluster', v_tier_cluster));
  END IF;

  RETURN portal_submit_request(v_id) || jsonb_build_object('id', v_id, 'quotes_required', v_quotes, 'split_flag', v_split);
END $fn$;

-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 022 (أسعار بنود العرض) — مطابقة لـ db/portal-migrations/022
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) جدول أسعار بنود العرض.
CREATE TABLE IF NOT EXISTS portal_offer_items (
  id          BIGSERIAL PRIMARY KEY,
  offer_id    BIGINT NOT NULL REFERENCES portal_offers(id) ON DELETE CASCADE,
  item_seq    INT NOT NULL,
  unit_price  NUMERIC NOT NULL DEFAULT 0,
  UNIQUE (offer_id, item_seq)
);
CREATE INDEX IF NOT EXISTS idx_portal_offer_items ON portal_offer_items(offer_id);

-- (2) قفله كالأدلّة (نفس portal_locked_guard): الكتابة عبر RPC (علم app.portal_transition) فقط.
ALTER TABLE portal_offer_items ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS trg_portal_offer_items_lock ON portal_offer_items;
CREATE TRIGGER trg_portal_offer_items_lock
  BEFORE INSERT OR UPDATE OR DELETE ON portal_offer_items
  FOR EACH ROW EXECUTE FUNCTION portal_locked_guard();
-- قراءة مقيّدة برؤية الطلب الأب (كبقية جداول العرض) — سياسة SELECT.
DROP POLICY IF EXISTS offer_items_read ON portal_offer_items;
CREATE POLICY offer_items_read ON portal_offer_items FOR SELECT USING (
  EXISTS (SELECT 1 FROM portal_offers o WHERE o.id = portal_offer_items.offer_id
          AND portal_can_see_request(o.request_id))
);
GRANT SELECT ON portal_offer_items TO authenticated;
GRANT SELECT ON portal_offer_items TO anon;

-- (3) توسيع portal_submit_offer: يقبل p_items = [{"seq":int,"price":numeric}] لكل بند.
--     إن مُرِّرت: يُحسب الإجمالي من (كمية بند الطلب × سعر الوحدة) وتُخزَّن الأسعار البندية.
--     وإلا: يُستخدم p_total (توافق خلفي).
DROP FUNCTION IF EXISTS portal_submit_offer(text, text, numeric, int, int, int, text, text);
CREATE OR REPLACE FUNCTION portal_submit_offer(p_request_id text, p_supplier text, p_total numeric,
    p_delivery_days int DEFAULT NULL, p_quality int DEFAULT NULL, p_payment_days int DEFAULT NULL,
    p_note text DEFAULT NULL, p_quote_pdf_key text DEFAULT NULL, p_items jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_phase text; v_id bigint; v_total numeric := p_total;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT phase INTO v_phase FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_phase IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
    SELECT coalesce(sum(ri.qty * nullif((it->>'price'),'')::numeric), 0)
      INTO v_total
      FROM jsonb_array_elements(p_items) it
      JOIN portal_request_items ri ON ri.request_id = p_request_id AND ri.seq = (it->>'seq')::int;
  END IF;
  IF coalesce(p_supplier,'') = '' OR coalesce(v_total,0) <= 0 THEN RAISE EXCEPTION 'بيانات العرض غير مكتملة'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_offers(request_id, supplier_name, total, delivery_days, quality, payment_days, note, entered_by, quote_pdf_key)
    VALUES (p_request_id, p_supplier, v_total, p_delivery_days, p_quality, p_payment_days, p_note, v_me,
            nullif(trim(coalesce(p_quote_pdf_key,'')),''))
    RETURNING id INTO v_id;
  IF p_items IS NOT NULL AND jsonb_array_length(p_items) > 0 THEN
    INSERT INTO portal_offer_items(offer_id, item_seq, unit_price)
      SELECT v_id, (it->>'seq')::int, coalesce(nullif((it->>'price'),'')::numeric, 0)
      FROM jsonb_array_elements(p_items) it
      WHERE (it->>'seq') IS NOT NULL;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'offer_added', v_me, 'portal',
    jsonb_build_object('supplier', p_supplier, 'total', v_total, 'has_pdf', (nullif(trim(coalesce(p_quote_pdf_key,'')),'') IS NOT NULL),
                       'by_item', (p_items IS NOT NULL)));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

GRANT EXECUTE ON FUNCTION portal_submit_offer(text, text, numeric, int, int, int, text, text, jsonb) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 023 (مستندات الصرف والاستلام) — مطابقة لـ db/portal-migrations/023
-- ═══════════════════════════════════════════════════════════════════════════
-- (1) عمود مفتاح مستند الاستلام (مشهد/محضر الاستلام في R2).
ALTER TABLE portal_receipts ADD COLUMN IF NOT EXISTS doc_key TEXT;

-- (2) توسيع انتقال الصرف: معامل p_details jsonb لإرفاق محضر الصرف (proof_key) عند التنفيذ/الاعتماد.
--     يُدمج في portal_payments.details دون مساس ببقية الحقول (آيبان/عهدة/آجل). فصل المهام كما هو.
DROP FUNCTION IF EXISTS portal_payment_transition(bigint, text, text, text);
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text,
    p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text; v_req_status text;
  v_merge jsonb := coalesce(p_details, '{}'::jsonb);
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  -- إعادة فحص حالة الطلب الأب (بقفل): كل عمليات الصرف تتطلّب payment_pending.
  SELECT status INTO v_req_status FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  IF v_req_status IS DISTINCT FROM 'payment_pending' THEN
    RAISE EXCEPTION 'حالة الطلب (%) لا تسمح بعملية الصرف', coalesce(v_req_status,'?');
  END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment,
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;
    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ طلبته بنفسك (فصل المهام الثلاثي)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now(),
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
    jsonb_build_object('payment_id', p_payment_id, 'has_proof', (v_merge ? 'proof_key')));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) TO authenticated;

-- (3) توسيع تسجيل الاستلام: معامل p_doc_key لإرفاق مشهد/محضر الاستلام (R2). رفض الكمية السالبة كما هو.
DROP FUNCTION IF EXISTS portal_record_receipt(text, jsonb, text);
CREATE OR REPLACE FUNCTION portal_record_receipt(p_request_id text, p_lines jsonb, p_note text DEFAULT NULL,
    p_doc_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_line jsonb;
  v_remaining numeric;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_verify_stock') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'receipt' THEN RAISE EXCEPTION 'الطلب ليس بانتظار استلام'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  FOR v_line IN SELECT * FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) LOOP
    IF coalesce((v_line->>'qty')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'كمية استلام غير صالحة (يجب أن تكون موجبة)';
    END IF;
    UPDATE portal_request_items
      SET received_qty = LEAST(qty, received_qty + (v_line->>'qty')::numeric)
      WHERE id = (v_line->>'item_id')::bigint AND request_id = p_request_id;
  END LOOP;

  INSERT INTO portal_receipts(request_id, received_by, note, lines, doc_key)
    VALUES (p_request_id, v_me, p_note, p_lines, nullif(trim(coalesce(p_doc_key,'')),''));
  SELECT sum(GREATEST(qty - received_qty, 0)) INTO v_remaining FROM portal_request_items WHERE request_id = p_request_id;

  IF coalesce(v_remaining, 0) <= 0 THEN
    UPDATE portal_requests SET status = 'closed', phase = 'closed', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    PERFORM portal_audit_write(p_request_id, 'closed', v_me, 'portal', '{}'::jsonb);
  ELSE
    UPDATE portal_requests SET updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'receipt_recorded', v_me, 'portal',
    jsonb_build_object('note', p_note, 'remaining', v_remaining, 'has_doc', (nullif(trim(coalesce(p_doc_key,'')),'') IS NOT NULL)));
  RETURN jsonb_build_object('ok', true, 'remaining', coalesce(v_remaining,0));
END $fn$;
GRANT EXECUTE ON FUNCTION portal_record_receipt(text, jsonb, text, text) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 024 (أساس الترسية المجزّأة) — مطابقة لـ db/portal-migrations/024
-- ═══════════════════════════════════════════════════════════════════════════
-- (1) جدول بنود الترسية: أي مورد يفوز بأي بند (مقفل كالأدلّة).
CREATE TABLE IF NOT EXISTS portal_award_lines (
  id           BIGSERIAL PRIMARY KEY,
  request_id   TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  item_seq     INT NOT NULL,
  offer_id     BIGINT NOT NULL REFERENCES portal_offers(id),
  supplier_name TEXT,
  qty          NUMERIC NOT NULL DEFAULT 0,
  unit_price   NUMERIC NOT NULL DEFAULT 0,
  line_total   NUMERIC NOT NULL DEFAULT 0,
  UNIQUE (request_id, item_seq)
);
CREATE INDEX IF NOT EXISTS idx_portal_award_lines_req ON portal_award_lines(request_id);

ALTER TABLE portal_award_lines ENABLE ROW LEVEL SECURITY;
DROP TRIGGER IF EXISTS trg_portal_award_lines_lock ON portal_award_lines;
CREATE TRIGGER trg_portal_award_lines_lock
  BEFORE INSERT OR UPDATE OR DELETE ON portal_award_lines
  FOR EACH ROW EXECUTE FUNCTION portal_locked_guard();
DROP POLICY IF EXISTS award_lines_read ON portal_award_lines;
CREATE POLICY award_lines_read ON portal_award_lines FOR SELECT USING (portal_can_see_request(request_id));
GRANT SELECT ON portal_award_lines TO authenticated, anon;

-- (2) ترسية مجزّأة: p_lines = [{"seq":int,"offer_id":bigint}] — بند لكل مورد فائز.
--     يتحقّق من تغطية كل البنود، أن كل عرض مُسعّر لبنده، ثم يبني ترسية بالقيمة الإجمالية.
CREATE OR REPLACE FUNCTION portal_award_split(p_request_id text, p_lines jsonb, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_doa portal_doa%ROWTYPE;
  v_line jsonb; v_seq int; v_oid bigint; v_up numeric; v_qty numeric;
  v_agg numeric := 0; v_item_count int; v_covered int; v_offer_count int;
  v_dom_offer bigint; v_dom_val numeric := -1; v_sup text;
  v_suppliers int; v_min_up numeric; v_non_lowest int := 0;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  SELECT count(*) INTO v_item_count FROM portal_request_items WHERE request_id = p_request_id;
  IF v_item_count = 0 THEN RAISE EXCEPTION 'لا بنود للطلب — الترسية المجزّأة تتطلّب بنوداً'; END IF;
  SELECT count(DISTINCT (e->>'seq')::int) INTO v_covered FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e;
  IF v_covered <> v_item_count THEN
    RAISE EXCEPTION 'يجب تغطية كل بنود الطلب بالضبط (% بند، وُصِل %)', v_item_count, v_covered;
  END IF;

  SELECT count(*) INTO v_offer_count FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer_count < coalesce(v_req.quotes_required, 1) THEN
    RAISE EXCEPTION 'عدد العروض (%) أقل من المطلوب (%)', v_offer_count, v_req.quotes_required;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_award_lines WHERE request_id = p_request_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_seq := (v_line->>'seq')::int; v_oid := (v_line->>'offer_id')::bigint;
    -- العرض يخصّ الطلب
    IF NOT EXISTS (SELECT 1 FROM portal_offers WHERE id = v_oid AND request_id = p_request_id) THEN
      RAISE EXCEPTION 'عرض % لا يخصّ هذا الطلب', v_oid;
    END IF;
    -- البند موجود في الطلب
    SELECT qty INTO v_qty FROM portal_request_items WHERE request_id = p_request_id AND seq = v_seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'بند % غير موجود في الطلب', v_seq; END IF;
    -- سعر هذا المورد لهذا البند (يجب أن يكون مُسعّراً)
    SELECT unit_price INTO v_up FROM portal_offer_items WHERE offer_id = v_oid AND item_seq = v_seq;
    IF v_up IS NULL THEN RAISE EXCEPTION 'المورد لم يُسعّر البند % — لا يمكن ترسيته إليه', v_seq; END IF;
    -- (038) رصد غير-الأقل لكل بند (غير مانع — أثر تدقيق حوكمي: كم بنداً رُسِّي لغير أرخص مُسعِّر له).
    SELECT min(oi.unit_price) INTO v_min_up FROM portal_offer_items oi
      JOIN portal_offers o ON o.id = oi.offer_id
      WHERE o.request_id = p_request_id AND oi.item_seq = v_seq;
    IF v_min_up IS NOT NULL AND v_up > v_min_up THEN v_non_lowest := v_non_lowest + 1; END IF;
    SELECT supplier_name INTO v_sup FROM portal_offers WHERE id = v_oid;
    INSERT INTO portal_award_lines(request_id, item_seq, offer_id, supplier_name, qty, unit_price, line_total)
      VALUES (p_request_id, v_seq, v_oid, v_sup, v_qty, v_up, round(v_qty * v_up));
    v_agg := v_agg + round(v_qty * v_up);
  END LOOP;

  IF v_agg <= 0 THEN RAISE EXCEPTION 'إجمالي الترسية غير صالح'; END IF;

  -- المورد المهيمن (أكبر نصيب) — يُستخدم كممثّل winner_offer_id للتوافق الخلفي.
  SELECT offer_id INTO v_dom_offer FROM portal_award_lines WHERE request_id = p_request_id
    GROUP BY offer_id ORDER BY sum(line_total) DESC LIMIT 1;
  SELECT count(DISTINCT offer_id) INTO v_suppliers FROM portal_award_lines WHERE request_id = p_request_id;

  -- شريحة DoA بالقيمة الإجمالية للترسية.
  SELECT * INTO v_doa FROM portal_doa WHERE max_value IS NULL OR v_agg <= max_value
    ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'تعذّر تحديد شريحة الصلاحيات — أضِف قاعدة DoA'; END IF;

  INSERT INTO portal_award(request_id, winner_offer_id, winner_total, award_reason, doa_id, status, awarded_by)
    VALUES (p_request_id, v_dom_offer, v_agg, coalesce(p_reason,'ترسية مجزّأة'), v_doa.id, 'pending', v_me)
  ON CONFLICT (request_id) DO UPDATE SET winner_offer_id = EXCLUDED.winner_offer_id, winner_total = EXCLUDED.winner_total,
    award_reason = EXCLUDED.award_reason, doa_id = EXCLUDED.doa_id, status = 'pending', awarded_by = EXCLUDED.awarded_by;
  DELETE FROM portal_award_approvals WHERE request_id = p_request_id;
  INSERT INTO portal_award_approvals(request_id, seq, stage_label, role_key, approver)
    VALUES (p_request_id, 1, 'اعتماد التعميد (مجزّأ)', v_doa.award_role_key, NULL);
  UPDATE portal_requests SET status = 'award_review', phase = 'award', current_seq = 1, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'awarded', v_me, 'portal',
    jsonb_build_object('split', true, 'suppliers', v_suppliers, 'total', v_agg,
                       'non_lowest_items', v_non_lowest, 'reason', nullif(trim(coalesce(p_reason,'')),'')));
  RETURN jsonb_build_object('ok', true, 'status', 'award_review', 'split', true, 'suppliers', v_suppliers,
    'total', v_agg, 'non_lowest_items', v_non_lowest);
END $fn$;
GRANT EXECUTE ON FUNCTION portal_award_split(text, jsonb, text) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 025 (الصرف لكل مورد — النموذج أ) — مطابقة لـ db/portal-migrations/025
-- ═══════════════════════════════════════════════════════════════════════════
-- (1) عمود يربط الدفعة بالمورد الفائز (نصيبه). NULL = ترسية مفردة/قديمة.
ALTER TABLE portal_payments ADD COLUMN IF NOT EXISTS award_offer_id BIGINT REFERENCES portal_offers(id);

-- (2) طلب الصرف: واعٍ بالتجزئة. p_offer_id يحدّد المورد عند التجزئة.
DROP FUNCTION IF EXISTS portal_payment_request(text, text, numeric, text, jsonb);
CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric,
    p_custody_to text DEFAULT NULL, p_details jsonb DEFAULT NULL, p_offer_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
  v_iban text; v_details jsonb := coalesce(p_details, '{}'::jsonb);
  v_winner numeric; v_vat numeric; v_agg_max numeric; v_split boolean;
  v_slice numeric; v_slice_max numeric; v_paid_sum numeric;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'نوع صرف غير صالح'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'مبلغ غير صالح'; END IF;

  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
  ELSIF p_kind = 'custody' THEN
    IF coalesce(p_custody_to,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = p_custody_to AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)';
    END IF;
  ELSIF p_kind = 'credit' THEN
    IF (v_details->>'due_date') IS NULL OR (v_details->>'due_date')::date IS NULL THEN
      RAISE EXCEPTION 'تاريخ الاستحقاق مطلوب للصرف الآجل';
    END IF;
  END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;

  SELECT winner_total INTO v_winner FROM portal_award WHERE request_id = p_request_id AND status = 'approved';
  IF v_winner IS NULL OR v_winner <= 0 THEN RAISE EXCEPTION 'لا تعميد مُعتمَد لهذا الطلب'; END IF;
  v_vat := portal_setting_num('vat', 15);
  v_agg_max := round(v_winner * (1 + v_vat/100.0));
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = p_request_id);

  IF v_split THEN
    -- التجزئة: يجب أن يكون الطلب في طور الصرف (يبقى awarded حتى اكتمال كل الموردين).
    IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'الطلب ليس في طور الصرف'; END IF;
    IF p_offer_id IS NULL THEN RAISE EXCEPTION 'حدّد المورد (نصيبه) للصرف المجزّأ'; END IF;
    SELECT sum(line_total) INTO v_slice FROM portal_award_lines WHERE request_id = p_request_id AND offer_id = p_offer_id;
    IF v_slice IS NULL OR v_slice <= 0 THEN RAISE EXCEPTION 'المورد ليس ضمن الفائزين بالترسية'; END IF;
    v_slice_max := round(v_slice * (1 + v_vat/100.0));
    -- لا دفعة قائمة لنفس المورد.
    IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id AND award_offer_id = p_offer_id
               AND status IN ('pending_pay','approved_pay','disbursed')) THEN
      RAISE EXCEPTION 'يوجد صرف قائم لهذا المورد بالفعل';
    END IF;
    IF p_amount > v_slice_max THEN
      RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز نصيب المورد شاملاً الضريبة (%)', p_amount, v_slice_max;
    END IF;
    -- المجموع عبر كل الموردين لا يتجاوز التعميد الإجمالي شاملاً الضريبة.
    SELECT coalesce(sum(amount),0) INTO v_paid_sum FROM portal_payments WHERE request_id = p_request_id
      AND status IN ('pending_pay','approved_pay','disbursed');
    IF v_paid_sum + p_amount > v_agg_max THEN
      RAISE EXCEPTION 'مجموع الصرف (%) يتجاوز إجمالي التعميد شاملاً الضريبة (%)', v_paid_sum + p_amount, v_agg_max;
    END IF;

    PERFORM set_config('app.portal_transition', '1', true);
    INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details, award_offer_id)
      VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb), p_offer_id) RETURNING id INTO v_id;
    -- لا تغيير على حالة الطلب في التجزئة (يبقى awarded حتى اكتمال صرف كل الموردين).
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal',
      jsonb_build_object('kind', p_kind, 'amount', p_amount, 'split', true, 'offer_id', p_offer_id));
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'split', true);
  END IF;

  -- ── الترسية المفردة (سلوك 019 حرفياً) ──
  IF v_req.phase <> 'payment' OR v_req.status <> 'awarded' THEN RAISE EXCEPTION 'الطلب ليس جاهزاً للصرف'; END IF;
  IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id
             AND status IN ('pending_pay','approved_pay','disbursed')) THEN
    RAISE EXCEPTION 'يوجد طلب صرف قائم لهذا الطلب — لا يُسمح بأكثر من صرف واحد';
  END IF;
  IF p_amount > v_agg_max THEN
    RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز قيمة التعميد شاملة الضريبة (%)', p_amount, v_agg_max;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details)
    VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb)) RETURNING id INTO v_id;
  UPDATE portal_requests SET status = 'payment_pending', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);
  PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal', jsonb_build_object('kind', p_kind, 'amount', p_amount));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_request(text, text, numeric, text, jsonb, bigint) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_request(text, text, numeric, text, jsonb, bigint) TO authenticated;

-- (3) انتقال الصرف: واعٍ بالتجزئة — يتقدّم إلى الاستلام فقط بعد صرف كل الموردين.
DROP FUNCTION IF EXISTS portal_payment_transition(bigint, text, text, text, jsonb);
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text,
    p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
  v_req_status text; v_req_phase text; v_split boolean; v_pending int;
  v_merge jsonb := coalesce(p_details, '{}'::jsonb);
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  SELECT status, phase INTO v_req_status, v_req_phase FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = v_pay.request_id);
  -- إعادة فحص حالة الطلب الأب: مفرد=payment_pending، مجزّأ=طور الصرف (awarded محفوظ).
  IF v_split THEN
    IF v_req_phase <> 'payment' THEN RAISE EXCEPTION 'حالة الطلب لا تسمح بعملية الصرف'; END IF;
  ELSE
    IF v_req_status IS DISTINCT FROM 'payment_pending' THEN
      RAISE EXCEPTION 'حالة الطلب (%) لا تسمح بعملية الصرف', coalesce(v_req_status,'?');
    END IF;
  END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment,
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;
    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    -- المفرد: يعود الطلب awarded ليُعاد إصدار الصرف. المجزّأ: الطلب أصلاً awarded — يُعاد إصدار صرف المورد فقط.
    IF NOT v_split THEN
      UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment, 'split', v_split));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ طلبته بنفسك (فصل المهام الثلاثي)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now(),
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    IF v_split THEN
      -- يتقدّم للاستلام فقط إذا صُرف لكل مورد فائز.
      SELECT count(*) INTO v_pending FROM (
        SELECT DISTINCT al.offer_id FROM portal_award_lines al WHERE al.request_id = v_pay.request_id
          AND NOT EXISTS (SELECT 1 FROM portal_payments p WHERE p.request_id = al.request_id
                          AND p.award_offer_id = al.offer_id AND p.status = 'disbursed')
      ) q;
      IF v_pending = 0 THEN
        UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      END IF;
    ELSE
      UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
    jsonb_build_object('payment_id', p_payment_id, 'has_proof', (v_merge ? 'proof_key'), 'split', v_split));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 026 (سلامة الترسية المجزّأة) — مطابقة لـ db/portal-migrations/026
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) portal_award (المفرد): يمسح أي ترسية مجزّأة سابقة كي يبقى المتغيّر «award_lines موجودة ⟺ الترسية النشطة مجزّأة».
CREATE OR REPLACE FUNCTION portal_award(p_request_id text, p_winner_offer_id bigint, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_offer portal_offers%ROWTYPE;
  v_doa portal_doa%ROWTYPE;
  v_lowest numeric; v_offer_count int;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  SELECT * INTO v_offer FROM portal_offers WHERE id = p_winner_offer_id AND request_id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'العرض غير موجود'; END IF;

  SELECT count(*) INTO v_offer_count FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer_count < coalesce(v_req.quotes_required, 1) THEN
    RAISE EXCEPTION 'عدد العروض المُدخَلة (%) أقل من المطلوب (%) — أضِف عروضاً أو استخدم نوع شراء استثنائياً بمبرّر',
      v_offer_count, v_req.quotes_required;
  END IF;

  SELECT min(total) INTO v_lowest FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer.total > v_lowest AND coalesce(trim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'اختيار عرض غير الأقل سعراً يتطلّب مبرّراً موثَّقاً';
  END IF;

  SELECT * INTO v_doa FROM portal_doa WHERE max_value IS NULL OR v_offer.total <= max_value ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'تعذّر تحديد مصفوفة الصلاحيات لهذه القيمة — أضِف قاعدة DoA'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_award_lines WHERE request_id = p_request_id;   -- (026) مسح أي ترسية مجزّأة سابقة
  INSERT INTO portal_award(request_id, winner_offer_id, winner_total, award_reason, doa_id, status, awarded_by)
    VALUES (p_request_id, p_winner_offer_id, v_offer.total, p_reason, v_doa.id, 'pending', v_me)
  ON CONFLICT (request_id) DO UPDATE SET winner_offer_id = EXCLUDED.winner_offer_id, winner_total = EXCLUDED.winner_total,
    award_reason = EXCLUDED.award_reason, doa_id = EXCLUDED.doa_id, status = 'pending', awarded_by = EXCLUDED.awarded_by;
  DELETE FROM portal_award_approvals WHERE request_id = p_request_id;
  INSERT INTO portal_award_approvals(request_id, seq, stage_label, role_key, approver)
    VALUES (p_request_id, 1, 'اعتماد التعميد', v_doa.award_role_key, NULL);
  UPDATE portal_requests SET status = 'award_review', phase = 'award', current_seq = 1, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'awarded', v_me, 'portal', jsonb_build_object('supplier', v_offer.supplier_name, 'total', v_offer.total));
  RETURN jsonb_build_object('ok', true, 'status', 'award_review');
END $fn$;

-- (2) portal_award_transition: عند رفض التعميد يمسح award_lines (لا تبقى ترسية مجزّأة عالقة).
CREATE OR REPLACE FUNCTION portal_award_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_award_approvals%ROWTYPE;
  v_perm boolean; v_decision text; v_status text; v_phase text; v_po_stages int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'award_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار اعتماد التعميد'; END IF;
  IF v_req.requester = v_me THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;
  IF EXISTS (SELECT 1 FROM portal_award WHERE request_id = p_request_id AND awarded_by = v_me)
     AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد تعميد رسّيته بنفسك (فصل المهام)';
  END IF;

  SELECT * INTO v_stage FROM portal_award_approvals
    WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة تعميد معلّقة'; END IF;

  SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm FROM portal_users WHERE username = v_me;
  IF NOT coalesce(v_perm,false) AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action = 'reject' AND coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض'; END IF;

  v_decision := CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END;

  PERFORM set_config('app.portal_transition', '1', true);

  UPDATE portal_award_approvals SET decision = v_decision, approver = v_me, comment = p_comment, acted_at = now()
    WHERE request_id = p_request_id AND seq = v_stage.seq;

  IF p_action = 'approve' THEN
    UPDATE portal_award SET status = 'approved' WHERE request_id = p_request_id;
    v_po_stages := portal_build_po_chain(p_request_id, (SELECT coalesce(winner_total,0) FROM portal_award WHERE request_id = p_request_id));
    IF v_po_stages = 0 THEN
      v_status := 'awarded'; v_phase := 'payment';
      UPDATE portal_requests SET status = v_status, phase = v_phase, po_issued_by = v_me, po_issued_at = now(), updated_at = now(), updated_by = v_me
        WHERE id = p_request_id;
    ELSE
      v_status := 'po_review'; v_phase := 'po_review';
      UPDATE portal_requests SET status = v_status, phase = v_phase, current_seq = 1, updated_at = now(), updated_by = v_me
        WHERE id = p_request_id;
    END IF;
  ELSE
    v_status := 'pricing'; v_phase := 'pricing';
    UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
    DELETE FROM portal_award_lines WHERE request_id = p_request_id;   -- (026) مسح الترسية المجزّأة المرفوضة
    UPDATE portal_requests SET status = v_status, phase = v_phase, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'award_' || v_decision, v_me, 'portal', jsonb_build_object('comment', p_comment));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;

-- (3) portal_payment_request: سقف مجموع الصرف المجزّأ = مجموع أسقف الأنصبة (يمنع رفض المورد الأخير بالتقريب).
CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric,
    p_custody_to text DEFAULT NULL, p_details jsonb DEFAULT NULL, p_offer_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
  v_iban text; v_details jsonb := coalesce(p_details, '{}'::jsonb);
  v_winner numeric; v_vat numeric; v_agg_max numeric; v_split boolean;
  v_slice numeric; v_slice_max numeric; v_paid_sum numeric; v_split_cap numeric;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'نوع صرف غير صالح'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'مبلغ غير صالح'; END IF;

  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
  ELSIF p_kind = 'custody' THEN
    IF coalesce(p_custody_to,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = p_custody_to AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)';
    END IF;
  ELSIF p_kind = 'credit' THEN
    IF (v_details->>'due_date') IS NULL OR (v_details->>'due_date')::date IS NULL THEN
      RAISE EXCEPTION 'تاريخ الاستحقاق مطلوب للصرف الآجل';
    END IF;
  END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;

  SELECT winner_total INTO v_winner FROM portal_award WHERE request_id = p_request_id AND status = 'approved';
  IF v_winner IS NULL OR v_winner <= 0 THEN RAISE EXCEPTION 'لا تعميد مُعتمَد لهذا الطلب'; END IF;
  v_vat := portal_setting_num('vat', 15);
  v_agg_max := round(v_winner * (1 + v_vat/100.0));
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = p_request_id);

  IF v_split THEN
    IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'الطلب ليس في طور الصرف'; END IF;
    IF p_offer_id IS NULL THEN RAISE EXCEPTION 'حدّد المورد (نصيبه) للصرف المجزّأ'; END IF;
    SELECT sum(line_total) INTO v_slice FROM portal_award_lines WHERE request_id = p_request_id AND offer_id = p_offer_id;
    IF v_slice IS NULL OR v_slice <= 0 THEN RAISE EXCEPTION 'المورد ليس ضمن الفائزين بالترسية'; END IF;
    v_slice_max := round(v_slice * (1 + v_vat/100.0));
    IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id AND award_offer_id = p_offer_id
               AND status IN ('pending_pay','approved_pay','disbursed')) THEN
      RAISE EXCEPTION 'يوجد صرف قائم لهذا المورد بالفعل';
    END IF;
    IF p_amount > v_slice_max THEN
      RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز نصيب المورد شاملاً الضريبة (%)', p_amount, v_slice_max;
    END IF;
    -- (026) السقف الكلّي = مجموع أسقف أنصبة كل الموردين (سليم مع التقريب)، لا round(الإجمالي×الضريبة).
    SELECT sum(round(s.slc * (1 + v_vat/100.0))) INTO v_split_cap FROM (
      SELECT sum(line_total) AS slc FROM portal_award_lines WHERE request_id = p_request_id GROUP BY offer_id) s;
    SELECT coalesce(sum(amount),0) INTO v_paid_sum FROM portal_payments WHERE request_id = p_request_id
      AND status IN ('pending_pay','approved_pay','disbursed');
    IF v_paid_sum + p_amount > coalesce(v_split_cap, v_agg_max) THEN
      RAISE EXCEPTION 'مجموع الصرف (%) يتجاوز إجمالي أنصبة الموردين شاملاً الضريبة (%)', v_paid_sum + p_amount, coalesce(v_split_cap, v_agg_max);
    END IF;

    PERFORM set_config('app.portal_transition', '1', true);
    INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details, award_offer_id)
      VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb), p_offer_id) RETURNING id INTO v_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal',
      jsonb_build_object('kind', p_kind, 'amount', p_amount, 'split', true, 'offer_id', p_offer_id));
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'split', true);
  END IF;

  -- ── الترسية المفردة (سلوك 019 حرفياً) ──
  IF v_req.phase <> 'payment' OR v_req.status <> 'awarded' THEN RAISE EXCEPTION 'الطلب ليس جاهزاً للصرف'; END IF;
  IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id
             AND status IN ('pending_pay','approved_pay','disbursed')) THEN
    RAISE EXCEPTION 'يوجد طلب صرف قائم لهذا الطلب — لا يُسمح بأكثر من صرف واحد';
  END IF;
  IF p_amount > v_agg_max THEN
    RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز قيمة التعميد شاملة الضريبة (%)', p_amount, v_agg_max;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details)
    VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb)) RETURNING id INTO v_id;
  UPDATE portal_requests SET status = 'payment_pending', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);
  PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal', jsonb_build_object('kind', p_kind, 'amount', p_amount));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_request(text, text, numeric, text, jsonb, bigint) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_request(text, text, numeric, text, jsonb, bigint) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 027 (الدفعات على مراحل) — مطابقة لـ db/portal-migrations/027
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) علم «الدفعات على مراحل» للطلب.
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS pay_installments boolean NOT NULL DEFAULT false;

-- (2) تفعيل/إلغاء وضع الدفعات (المشتريات/الأدمن، في طور الصرف، غير المجزّأ، وقبل وجود أي صرف قائم).
CREATE OR REPLACE FUNCTION portal_set_installments(p_request_id text, p_on boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_is_admin()) THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'وضع الدفعات يُحدَّد في طور الصرف فقط'; END IF;
  IF EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = p_request_id) THEN
    RAISE EXCEPTION 'الترسية المجزّأة لها صرف مستقل لكل مورد (لا يُدمج مع الدفعات على مراحل حالياً)';
  END IF;
  IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id
             AND status IN ('pending_pay','approved_pay','disbursed')) THEN
    RAISE EXCEPTION 'لا يمكن تغيير وضع الدفعات بعد بدء الصرف';
  END IF;
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET pay_installments = coalesce(p_on,false), updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);
  PERFORM portal_audit_write(p_request_id, 'installments_' || CASE WHEN p_on THEN 'on' ELSE 'off' END, v_me, 'portal', '{}'::jsonb);
  RETURN jsonb_build_object('ok', true, 'installments', coalesce(p_on,false));
END $fn$;
REVOKE ALL ON FUNCTION portal_set_installments(text, boolean) FROM public;
GRANT EXECUTE ON FUNCTION portal_set_installments(text, boolean) TO authenticated;

-- (3) طلب الصرف: يضيف وضع «الدفعات» (عدّة دفعات على القيمة الإجمالية) بجانب المفرد والمجزّأ.
CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric,
    p_custody_to text DEFAULT NULL, p_details jsonb DEFAULT NULL, p_offer_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
  v_iban text; v_details jsonb := coalesce(p_details, '{}'::jsonb);
  v_winner numeric; v_vat numeric; v_agg_max numeric; v_split boolean; v_inst boolean;
  v_slice numeric; v_slice_max numeric; v_paid_sum numeric; v_split_cap numeric;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'نوع صرف غير صالح'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'مبلغ غير صالح'; END IF;

  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
  ELSIF p_kind = 'custody' THEN
    IF coalesce(p_custody_to,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = p_custody_to AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)';
    END IF;
  ELSIF p_kind = 'credit' THEN
    IF (v_details->>'due_date') IS NULL OR (v_details->>'due_date')::date IS NULL THEN
      RAISE EXCEPTION 'تاريخ الاستحقاق مطلوب للصرف الآجل';
    END IF;
  END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;

  SELECT winner_total INTO v_winner FROM portal_award WHERE request_id = p_request_id AND status = 'approved';
  IF v_winner IS NULL OR v_winner <= 0 THEN RAISE EXCEPTION 'لا تعميد مُعتمَد لهذا الطلب'; END IF;
  v_vat := portal_setting_num('vat', 15);
  v_agg_max := round(v_winner * (1 + v_vat/100.0));
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = p_request_id);
  v_inst := v_req.pay_installments AND NOT v_split;

  IF v_split THEN
    IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'الطلب ليس في طور الصرف'; END IF;
    IF p_offer_id IS NULL THEN RAISE EXCEPTION 'حدّد المورد (نصيبه) للصرف المجزّأ'; END IF;
    SELECT sum(line_total) INTO v_slice FROM portal_award_lines WHERE request_id = p_request_id AND offer_id = p_offer_id;
    IF v_slice IS NULL OR v_slice <= 0 THEN RAISE EXCEPTION 'المورد ليس ضمن الفائزين بالترسية'; END IF;
    v_slice_max := round(v_slice * (1 + v_vat/100.0));
    IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id AND award_offer_id = p_offer_id
               AND status IN ('pending_pay','approved_pay','disbursed')) THEN
      RAISE EXCEPTION 'يوجد صرف قائم لهذا المورد بالفعل';
    END IF;
    IF p_amount > v_slice_max THEN
      RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز نصيب المورد شاملاً الضريبة (%)', p_amount, v_slice_max;
    END IF;
    SELECT sum(round(s.slc * (1 + v_vat/100.0))) INTO v_split_cap FROM (
      SELECT sum(line_total) AS slc FROM portal_award_lines WHERE request_id = p_request_id GROUP BY offer_id) s;
    SELECT coalesce(sum(amount),0) INTO v_paid_sum FROM portal_payments WHERE request_id = p_request_id
      AND status IN ('pending_pay','approved_pay','disbursed');
    IF v_paid_sum + p_amount > coalesce(v_split_cap, v_agg_max) THEN
      RAISE EXCEPTION 'مجموع الصرف (%) يتجاوز إجمالي أنصبة الموردين شاملاً الضريبة (%)', v_paid_sum + p_amount, coalesce(v_split_cap, v_agg_max);
    END IF;
    PERFORM set_config('app.portal_transition', '1', true);
    INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details, award_offer_id)
      VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb), p_offer_id) RETURNING id INTO v_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal',
      jsonb_build_object('kind', p_kind, 'amount', p_amount, 'split', true, 'offer_id', p_offer_id));
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'split', true);

  ELSIF v_inst THEN
    -- الدفعات على مراحل: عدّة دفعات على الإجمالي؛ الطلب يبقى awarded حتى سداد كامل القيمة.
    IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'الطلب ليس في طور الصرف'; END IF;
    SELECT coalesce(sum(amount),0) INTO v_paid_sum FROM portal_payments WHERE request_id = p_request_id
      AND status IN ('pending_pay','approved_pay','disbursed');
    IF v_paid_sum + p_amount > v_agg_max THEN
      RAISE EXCEPTION 'مجموع الدفعات (%) يتجاوز قيمة التعميد شاملاً الضريبة (%) — المتبقّي %',
        v_paid_sum + p_amount, v_agg_max, (v_agg_max - v_paid_sum);
    END IF;
    PERFORM set_config('app.portal_transition', '1', true);
    INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details)
      VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb)) RETURNING id INTO v_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal',
      jsonb_build_object('kind', p_kind, 'amount', p_amount, 'installment', true, 'paid_after', v_paid_sum + p_amount, 'total', v_agg_max));
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'installment', true, 'remaining', v_agg_max - (v_paid_sum + p_amount));
  END IF;

  -- ── الترسية المفردة (سلوك 019 حرفياً) ──
  IF v_req.phase <> 'payment' OR v_req.status <> 'awarded' THEN RAISE EXCEPTION 'الطلب ليس جاهزاً للصرف'; END IF;
  IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id
             AND status IN ('pending_pay','approved_pay','disbursed')) THEN
    RAISE EXCEPTION 'يوجد طلب صرف قائم لهذا الطلب — لا يُسمح بأكثر من صرف واحد';
  END IF;
  IF p_amount > v_agg_max THEN
    RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز قيمة التعميد شاملة الضريبة (%)', p_amount, v_agg_max;
  END IF;
  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details)
    VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb)) RETURNING id INTO v_id;
  UPDATE portal_requests SET status = 'payment_pending', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);
  PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal', jsonb_build_object('kind', p_kind, 'amount', p_amount));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_request(text, text, numeric, text, jsonb, bigint) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_request(text, text, numeric, text, jsonb, bigint) TO authenticated;

-- (4) انتقال الصرف: واعٍ بالدفعات — يتقدّم للاستلام فقط بعد سداد كامل القيمة.
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text,
    p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
  v_req_status text; v_req_phase text; v_req_inst boolean; v_split boolean; v_multi boolean;
  v_pending int; v_vat numeric; v_agg_max numeric; v_disb_sum numeric; v_merge jsonb := coalesce(p_details, '{}'::jsonb);
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  SELECT status, phase, pay_installments INTO v_req_status, v_req_phase, v_req_inst FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = v_pay.request_id);
  v_multi := v_split OR (coalesce(v_req_inst,false) AND NOT v_split);
  IF v_multi THEN
    IF v_req_phase <> 'payment' THEN RAISE EXCEPTION 'حالة الطلب لا تسمح بعملية الصرف'; END IF;
  ELSE
    IF v_req_status IS DISTINCT FROM 'payment_pending' THEN
      RAISE EXCEPTION 'حالة الطلب (%) لا تسمح بعملية الصرف', coalesce(v_req_status,'?');
    END IF;
  END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment,
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;
    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    IF NOT v_multi THEN
      UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment, 'multi', v_multi));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ طلبته بنفسك (فصل المهام الثلاثي)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now(),
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    IF v_split THEN
      SELECT count(*) INTO v_pending FROM (
        SELECT DISTINCT al.offer_id FROM portal_award_lines al WHERE al.request_id = v_pay.request_id
          AND NOT EXISTS (SELECT 1 FROM portal_payments p WHERE p.request_id = al.request_id
                          AND p.award_offer_id = al.offer_id AND p.status = 'disbursed')
      ) q;
      IF v_pending = 0 THEN
        UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      END IF;
    ELSIF coalesce(v_req_inst,false) THEN
      -- الدفعات: للاستلام فقط بعد سداد كامل القيمة (شاملاً الضريبة).
      v_vat := portal_setting_num('vat', 15);
      SELECT round(coalesce(winner_total,0) * (1 + v_vat/100.0)) INTO v_agg_max FROM portal_award WHERE request_id = v_pay.request_id AND status = 'approved';
      SELECT coalesce(sum(amount),0) INTO v_disb_sum FROM portal_payments WHERE request_id = v_pay.request_id AND status = 'disbursed';
      IF v_disb_sum >= v_agg_max THEN
        UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      END IF;
    ELSE
      UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
    jsonb_build_object('payment_id', p_payment_id, 'has_proof', (v_merge ? 'proof_key'), 'multi', v_multi));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text, jsonb) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 028 (إرجاع المشتريات للمقدّم) — مطابقة لـ db/portal-migrations/028
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) علم «جولة سابقة» على العروض (لا حذف — حفاظاً على الأثر).
ALTER TABLE portal_offers ADD COLUMN IF NOT EXISTS superseded boolean NOT NULL DEFAULT false;

-- (2) إرجاع للمقدّم: يُعلّم عروض الجولة، يُلغي التعميد المشتق، ويعيد الطلب لدورة الحاجة.
CREATE OR REPLACE FUNCTION portal_bounce_to_requester(p_request_id text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_discarded jsonb; v_n int;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_is_admin()) THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF coalesce(trim(p_reason),'') = '' THEN RAISE EXCEPTION 'سبب الإرجاع وما المطلوب تعديله مطلوب'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'pricing' THEN RAISE EXCEPTION 'الإرجاع للمقدّم من المشتريات يكون في مرحلة التسعير فقط'; END IF;

  -- سجّل عروض الجولة (سلامة الأثر) قبل تعليمها.
  SELECT coalesce(jsonb_agg(jsonb_build_object('supplier', supplier_name, 'total', total) ORDER BY id), '[]'::jsonb), count(*)
    INTO v_discarded, v_n FROM portal_offers WHERE request_id = p_request_id AND superseded = false;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_offers SET superseded = true WHERE request_id = p_request_id AND superseded = false;
  UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
  DELETE FROM portal_award_lines WHERE request_id = p_request_id;
  DELETE FROM portal_award_approvals WHERE request_id = p_request_id;
  DELETE FROM portal_po_approvals WHERE request_id = p_request_id;
  -- يعود الطلب للمقدّم كإرجاع دورة الحاجة (المقدّم يعدّل ثم يعيد التقديم فتُبنى السلسلة من جديد).
  UPDATE portal_requests SET status = 'returned', phase = 'requisition', current_seq = 0,
         po_issued_at = NULL, po_issued_by = NULL, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'stage_returned', v_me, 'portal',
    jsonb_build_object('from', 'procurement', 'to', 'requester', 'comment', p_reason, 'superseded_offers', v_discarded));
  RETURN jsonb_build_object('ok', true, 'status', 'returned', 'superseded', v_n);
END $fn$;
REVOKE ALL ON FUNCTION portal_bounce_to_requester(text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_bounce_to_requester(text, text) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 029 (صندوق الصادر المعامَلاتي) — مطابقة لـ db/portal-migrations/029
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS portal_outbox (
  id              BIGSERIAL PRIMARY KEY,
  ntf_id          TEXT UNIQUE,
  recipient       TEXT NOT NULL,
  channel         TEXT NOT NULL DEFAULT 'email',
  type            TEXT,
  title           TEXT NOT NULL,
  body            TEXT,
  link            TEXT,
  status          TEXT NOT NULL DEFAULT 'pending',
  attempts        INT  NOT NULL DEFAULT 0,
  max_attempts    INT  NOT NULL DEFAULT 6,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at         TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_portal_outbox_due
  ON portal_outbox (next_attempt_at) WHERE status = 'pending';
ALTER TABLE portal_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON portal_outbox FROM anon, authenticated, PUBLIC;
GRANT  SELECT, INSERT, UPDATE ON portal_outbox TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_outbox_id_seq TO service_role;

CREATE OR REPLACE FUNCTION portal_outbox_enqueue() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  BEGIN
    INSERT INTO portal_outbox (ntf_id, recipient, channel, type, title, body, link)
    VALUES (NEW.id, NEW.recipient, 'email', NEW.type, NEW.title, NEW.body, NEW.link)
    ON CONFLICT (ntf_id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'portal_outbox_enqueue تعذّر إدراج نيّة الإشعار %: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS trg_portal_outbox_enqueue ON portal_notifications;
CREATE TRIGGER trg_portal_outbox_enqueue
  AFTER INSERT ON portal_notifications
  FOR EACH ROW EXECUTE FUNCTION portal_outbox_enqueue();

CREATE OR REPLACE FUNCTION portal_outbox_claim(p_limit int DEFAULT 20)
RETURNS SETOF portal_outbox
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT (portal_is_service() OR session_user IN ('postgres','supabase_admin')) THEN
    RAISE EXCEPTION 'portal_outbox_claim: صلاحية الخادم مطلوبة';
  END IF;
  RETURN QUERY
  WITH due AS (
    SELECT id FROM portal_outbox
    WHERE status = 'pending' AND next_attempt_at <= now()
    ORDER BY next_attempt_at
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(coalesce(p_limit,20), 100))
  )
  UPDATE portal_outbox o
    SET status = 'processing', attempts = o.attempts + 1, updated_at = now()
  FROM due WHERE o.id = due.id
  RETURNING o.*;
END $fn$;

CREATE OR REPLACE FUNCTION portal_outbox_mark(p_id bigint, p_ok boolean, p_error text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_row portal_outbox%ROWTYPE; v_delay_min int;
BEGIN
  IF NOT (portal_is_service() OR session_user IN ('postgres','supabase_admin')) THEN
    RAISE EXCEPTION 'portal_outbox_mark: صلاحية الخادم مطلوبة';
  END IF;
  SELECT * INTO v_row FROM portal_outbox WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','not_found'); END IF;
  IF p_ok THEN
    UPDATE portal_outbox SET status = 'sent', sent_at = now(), last_error = NULL, updated_at = now() WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'status', 'sent');
  END IF;
  IF v_row.attempts >= v_row.max_attempts THEN
    UPDATE portal_outbox SET status = 'dead', last_error = p_error, updated_at = now() WHERE id = p_id;
    RETURN jsonb_build_object('ok', false, 'status', 'dead', 'attempts', v_row.attempts);
  END IF;
  v_delay_min := LEAST(60, power(2, GREATEST(v_row.attempts,1))::int);
  UPDATE portal_outbox
    SET status = 'pending', next_attempt_at = now() + make_interval(mins => v_delay_min),
        last_error = p_error, updated_at = now() WHERE id = p_id;
  RETURN jsonb_build_object('ok', false, 'status', 'retry', 'retry_in_min', v_delay_min, 'attempts', v_row.attempts);
END $fn$;

REVOKE ALL ON FUNCTION portal_outbox_claim(int)                 FROM anon, authenticated, PUBLIC;
REVOKE ALL ON FUNCTION portal_outbox_mark(bigint, boolean, text) FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_outbox_claim(int)                 TO service_role;
GRANT EXECUTE ON FUNCTION portal_outbox_mark(bigint, boolean, text) TO service_role;

CREATE OR REPLACE FUNCTION portal_outbox_purge(p_days int DEFAULT 30)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_n int;
BEGIN
  IF NOT (portal_is_service() OR session_user IN ('postgres','supabase_admin')) THEN
    RAISE EXCEPTION 'portal_outbox_purge: صلاحية الخادم مطلوبة';
  END IF;
  DELETE FROM portal_outbox
    WHERE status = 'sent' AND sent_at < now() - make_interval(days => GREATEST(1, coalesce(p_days,30)));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION portal_outbox_purge(int) FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_outbox_purge(int) TO service_role;

-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 030 (تصليب صلاحيات التنفيذ + search_path) — مطابقة لـ 030
--  ⚠️ يجب أن تلي كل تعريفات الدوال (توضع آخر الملف عمداً).
-- ═══════════════════════════════════════════════════════════════════════════
DO $mig$
DECLARE r record; v_revoked int := 0;
BEGIN
  FOR r IN
    SELECT (p.oid::regprocedure)::text AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'portal\_%'
      AND p.proacl IS NOT NULL
      AND EXISTS (SELECT 1 FROM aclexplode(p.proacl) a JOIN pg_roles gr ON gr.oid = a.grantee
                  WHERE a.privilege_type = 'EXECUTE' AND gr.rolname IN ('authenticated','service_role'))
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon',   r.sig);
    v_revoked := v_revoked + 1;
  END LOOP;
  RAISE NOTICE '030: سُحب EXECUTE العام عن % دالة portal_.', v_revoked;
END $mig$;

DO $mig$
DECLARE r record; v_fixed int := 0;
BEGIN
  FOR r IN
    SELECT (p.oid::regprocedure)::text AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'portal\_%' AND p.prosecdef = true
      AND (p.proconfig IS NULL OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'))
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public', r.sig);
    v_fixed := v_fixed + 1;
  END LOOP;
  RAISE NOTICE '030: ثُبِّت search_path على % دالة DEFINER.', v_fixed;
END $mig$;

-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 031 (ضبط الميزانية — Commitment Control) — مطابقة لـ 031
--  (تُوضع بعد 030 لأنها تحمل منحها الصريح؛ لا تحتاج إعادة معالجة التصليب.)
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS portal_budgets (
  id            BIGSERIAL PRIMARY KEY,
  department_id TEXT NOT NULL REFERENCES portal_departments(id),
  fiscal_year   INT  NOT NULL,
  amount        NUMERIC NOT NULL DEFAULT 0 CHECK (amount >= 0),
  note          TEXT,
  active        BOOLEAN NOT NULL DEFAULT true,
  updated_by    TEXT,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (department_id, fiscal_year)
);
ALTER TABLE portal_budgets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_budgets_read ON portal_budgets;
CREATE POLICY portal_budgets_read ON portal_budgets FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement'));
REVOKE ALL ON portal_budgets FROM anon, PUBLIC;
GRANT  SELECT ON portal_budgets TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_budgets TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_budgets_id_seq TO service_role;

CREATE OR REPLACE FUNCTION portal_budget_committed(p_dept text, p_year int)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(
    COALESCE((SELECT sum(al.line_total) FROM portal_award_lines al WHERE al.request_id = a.request_id),
             a.winner_total)
    * (1 + portal_setting_num('vat', 15) / 100.0)
  ), 0)
  FROM portal_award a
  JOIN portal_requests r ON r.id = a.request_id
  WHERE a.status IN ('pending','approved')
    AND r.department_id = p_dept
    AND EXTRACT(YEAR FROM r.created_at)::int = p_year
    AND coalesce(r.status,'') <> 'cancelled';
$fn$;
REVOKE ALL ON FUNCTION portal_budget_committed(text, int) FROM anon, authenticated, PUBLIC;

CREATE OR REPLACE FUNCTION portal_budget_status(p_dept text, p_year int)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_amount numeric; v_committed numeric;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بعرض الميزانية';
  END IF;
  SELECT amount INTO v_amount FROM portal_budgets WHERE department_id=p_dept AND fiscal_year=p_year AND active;
  v_committed := portal_budget_committed(p_dept, p_year);
  RETURN jsonb_build_object(
    'department', p_dept, 'fiscal_year', p_year,
    'defined',   v_amount IS NOT NULL,
    'amount',    coalesce(v_amount, 0),
    'committed', v_committed,
    'available', coalesce(v_amount, 0) - v_committed,
    'enforced',  portal_setting_num('budget_enforce', 0) >= 1
  );
END $fn$;
REVOKE ALL ON FUNCTION portal_budget_status(text, int) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_budget_status(text, int) TO authenticated;

CREATE OR REPLACE FUNCTION portal_budget_set(p_dept text, p_year int, p_amount numeric, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username();
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'غير مصرّح بإدارة الميزانية';
  END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN RAISE EXCEPTION 'مبلغ الميزانية غير صالح'; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = p_dept) THEN RAISE EXCEPTION 'قسم غير موجود'; END IF;
  INSERT INTO portal_budgets (department_id, fiscal_year, amount, note, updated_by, updated_at)
    VALUES (p_dept, p_year, p_amount, p_note, v_me, now())
  ON CONFLICT (department_id, fiscal_year)
    DO UPDATE SET amount = EXCLUDED.amount, note = EXCLUDED.note, active = true,
                  updated_by = v_me, updated_at = now();
  RETURN jsonb_build_object('ok', true, 'department', p_dept, 'fiscal_year', p_year, 'amount', p_amount);
END $fn$;
REVOKE ALL ON FUNCTION portal_budget_set(text, int, numeric, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_budget_set(text, int, numeric, text) TO authenticated;

CREATE OR REPLACE FUNCTION portal_budget_delete(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username();
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'غير مصرّح بإدارة الميزانية';
  END IF;
  DELETE FROM portal_budgets WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END $fn$;
REVOKE ALL ON FUNCTION portal_budget_delete(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_budget_delete(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION portal_budget_enforce() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_dept text; v_year int; v_budget numeric; v_committed numeric; v_enforce numeric;
BEGIN
  SELECT department_id, EXTRACT(YEAR FROM created_at)::int INTO v_dept, v_year
    FROM portal_requests WHERE id = NEW.request_id;
  IF v_dept IS NULL THEN RETURN NULL; END IF;
  SELECT amount INTO v_budget FROM portal_budgets WHERE department_id=v_dept AND fiscal_year=v_year AND active;
  IF v_budget IS NULL THEN RETURN NULL; END IF;
  v_committed := portal_budget_committed(v_dept, v_year);
  IF v_committed <= v_budget THEN RETURN NULL; END IF;
  v_enforce := portal_setting_num('budget_enforce', 0);
  IF v_enforce >= 1 THEN
    RAISE EXCEPTION 'تجاوز الميزانية: القسم % سنة % — المرتبط % يتجاوز المعتمد % (المتاح %)',
      v_dept, v_year, round(v_committed), round(v_budget), round(v_budget - v_committed);
  ELSE
    RAISE WARNING 'تحذير ميزانية (غير مانع): القسم % سنة % — المرتبط % يتجاوز المعتمد %',
      v_dept, v_year, round(v_committed), round(v_budget);
  END IF;
  RETURN NULL;
END $fn$;
DROP TRIGGER IF EXISTS trg_portal_budget_enforce ON portal_award;
CREATE CONSTRAINT TRIGGER trg_portal_budget_enforce
  AFTER INSERT OR UPDATE ON portal_award
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION portal_budget_enforce();


-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 032 (ضبط تغيير آيبان المورد) — مطابقة لـ db/portal-migrations/032
-- ═══════════════════════════════════════════════════════════════════════════
-- ── (1) جدول طلبات تغيير الآيبان (أثر تدقيق دائم) ───────────────────────────
CREATE TABLE IF NOT EXISTS portal_supplier_iban_changes (
  id            BIGSERIAL PRIMARY KEY,
  supplier_id   BIGINT NOT NULL REFERENCES portal_suppliers(id) ON DELETE CASCADE,
  old_iban      TEXT,
  new_iban      TEXT NOT NULL,
  reason        TEXT,
  status        TEXT NOT NULL DEFAULT 'pending',      -- pending | approved | rejected
  requested_by  TEXT,
  requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_by    TEXT,
  decided_at    TIMESTAMPTZ,
  decision_note TEXT
);
CREATE INDEX IF NOT EXISTS idx_portal_iban_chg_supplier ON portal_supplier_iban_changes(supplier_id, status);

ALTER TABLE portal_supplier_iban_changes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_iban_chg_read ON portal_supplier_iban_changes;
CREATE POLICY portal_iban_chg_read ON portal_supplier_iban_changes FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement'));
REVOKE ALL ON portal_supplier_iban_changes FROM anon, PUBLIC;
GRANT  SELECT ON portal_supplier_iban_changes TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_supplier_iban_changes TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_supplier_iban_changes_id_seq TO service_role;

-- ── (2) حارس الآيبان: يمنع التغيير المباشر عند التفعيل (إلا عبر علم الاعتماد) ──
CREATE OR REPLACE FUNCTION portal_supplier_iban_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NEW.iban IS DISTINCT FROM OLD.iban
     AND portal_setting_num('iban_change_control', 0) >= 1
     AND coalesce(current_setting('app.iban_change_approved', true), '') <> '1'
  THEN
    RAISE EXCEPTION 'تغيير آيبان المورد يتطلّب طلب اعتماد مزدوج (فصل مهام) — عبر دوال البوابة';
  END IF;
  RETURN NEW;
END $fn$;

-- يعمل قبل portal_config_guard منطقياً (كلاهما BEFORE؛ كلاهما يجب أن يمرّ).
DROP TRIGGER IF EXISTS trg_portal_supplier_iban_guard ON portal_suppliers;
CREATE TRIGGER trg_portal_supplier_iban_guard
  BEFORE UPDATE ON portal_suppliers
  FOR EACH ROW EXECUTE FUNCTION portal_supplier_iban_guard();

-- ── (3) طلب تغيير الآيبان (مشتريات/مالية/أدمن) — لا يُطبَّق فوراً ─────────────
CREATE OR REPLACE FUNCTION portal_supplier_iban_request(p_supplier_id bigint, p_new_iban text, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_old text; v_new text; v_cid bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بطلب تغيير الآيبان';
  END IF;
  v_new := upper(regexp_replace(coalesce(p_new_iban,''), '\s+', '', 'g'));
  IF v_new !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
  SELECT iban INTO v_old FROM portal_suppliers WHERE id = p_supplier_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'المورد غير موجود'; END IF;
  IF v_old IS NOT NULL AND upper(regexp_replace(v_old,'\s+','','g')) = v_new THEN
    RAISE EXCEPTION 'الآيبان الجديد مطابق للحالي — لا تغيير';
  END IF;
  IF EXISTS (SELECT 1 FROM portal_supplier_iban_changes WHERE supplier_id = p_supplier_id AND status = 'pending') THEN
    RAISE EXCEPTION 'يوجد طلب تغيير معلّق لهذا المورد — يُبتّ فيه أولاً';
  END IF;
  INSERT INTO portal_supplier_iban_changes(supplier_id, old_iban, new_iban, reason, requested_by)
    VALUES (p_supplier_id, v_old, v_new, p_reason, v_me) RETURNING id INTO v_cid;
  RETURN jsonb_build_object('ok', true, 'change_id', v_cid, 'status', 'pending');
END $fn$;
REVOKE ALL ON FUNCTION portal_supplier_iban_request(bigint, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_supplier_iban_request(bigint, text, text) TO authenticated;

-- ── (4) اعتماد التغيير (مالية/أدمن) — فصل مهام: المعتمِد ≠ الطالب ─────────────
CREATE OR REPLACE FUNCTION portal_supplier_iban_approve(p_change_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_chg portal_supplier_iban_changes%ROWTYPE;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'اعتماد تغيير الآيبان صلاحية مالية/أدمن';
  END IF;
  SELECT * INTO v_chg FROM portal_supplier_iban_changes WHERE id = p_change_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب التغيير غير موجود'; END IF;
  IF v_chg.status <> 'pending' THEN RAISE EXCEPTION 'الطلب ليس معلّقاً (%).', v_chg.status; END IF;
  IF v_chg.requested_by IS NOT NULL AND v_chg.requested_by = v_me THEN
    RAISE EXCEPTION 'فصل المهام: طالب التغيير لا يعتمده';
  END IF;
  -- تطبيق التغيير عبر العلمين (يتجاوز حارس الآيبان + config_guard بأمان)
  PERFORM set_config('app.iban_change_approved', '1', true);
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_suppliers SET iban = v_chg.new_iban WHERE id = v_chg.supplier_id;
  PERFORM set_config('app.iban_change_approved', '0', true);
  PERFORM set_config('app.portal_transition', '0', true);
  UPDATE portal_supplier_iban_changes
    SET status = 'approved', decided_by = v_me, decided_at = now() WHERE id = p_change_id;
  RETURN jsonb_build_object('ok', true, 'status', 'approved', 'supplier_id', v_chg.supplier_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_supplier_iban_approve(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_supplier_iban_approve(bigint) TO authenticated;

-- ── (5) رفض التغيير (مالية/أدمن) ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_supplier_iban_reject(p_change_id bigint, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_st text;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'رفض تغيير الآيبان صلاحية مالية/أدمن';
  END IF;
  SELECT status INTO v_st FROM portal_supplier_iban_changes WHERE id = p_change_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب التغيير غير موجود'; END IF;
  IF v_st <> 'pending' THEN RAISE EXCEPTION 'الطلب ليس معلّقاً'; END IF;
  UPDATE portal_supplier_iban_changes
    SET status = 'rejected', decided_by = v_me, decided_at = now(), decision_note = p_note WHERE id = p_change_id;
  RETURN jsonb_build_object('ok', true, 'status', 'rejected');
END $fn$;
REVOKE ALL ON FUNCTION portal_supplier_iban_reject(bigint, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_supplier_iban_reject(bigint, text) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 033 (فاتورة المورد + المطابقة الثلاثية) — مطابقة لـ 033
-- ═══════════════════════════════════════════════════════════════════════════
-- ── (1) جدول فواتير المورد ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_supplier_invoices (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  supplier_name TEXT,
  invoice_no    TEXT NOT NULL,
  invoice_date  DATE,
  amount        NUMERIC NOT NULL CHECK (amount > 0),
  doc_key       TEXT,
  note          TEXT,
  recorded_by   TEXT,
  recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (request_id, invoice_no)
);
CREATE INDEX IF NOT EXISTS idx_portal_invoices_req ON portal_supplier_invoices(request_id);

ALTER TABLE portal_supplier_invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_invoices_read ON portal_supplier_invoices;
CREATE POLICY portal_invoices_read ON portal_supplier_invoices FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
  OR portal_can_see_request(request_id));
REVOKE ALL ON portal_supplier_invoices FROM anon, PUBLIC;
GRANT  SELECT ON portal_supplier_invoices TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_supplier_invoices TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_supplier_invoices_id_seq TO service_role;

-- ── (2) دوال حساب (خادمية) ──────────────────────────────────────────────────
-- إجمالي أمر الشراء (التعميد) للطلب شاملاً الضريبة — المجزّأ بمجموع بنوده.
CREATE OR REPLACE FUNCTION portal_award_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(
    COALESCE((SELECT sum(line_total) FROM portal_award_lines WHERE request_id = p_request_id),
             (SELECT winner_total FROM portal_award WHERE request_id = p_request_id AND status IN ('pending','approved'))),
    0) * (1 + portal_setting_num('vat', 15) / 100.0);
$fn$;
REVOKE ALL ON FUNCTION portal_award_total(text) FROM anon, authenticated, PUBLIC;

CREATE OR REPLACE FUNCTION portal_invoiced_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(amount), 0) FROM portal_supplier_invoices WHERE request_id = p_request_id;
$fn$;
REVOKE ALL ON FUNCTION portal_invoiced_total(text) FROM anon, authenticated, PUBLIC;

-- ── (3) حالة المطابقة الثلاثية (للمالية/المشتريات/الأدمن أو صاحب الطلب) ──────
CREATE OR REPLACE FUNCTION portal_three_way_status(p_request_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_award numeric; v_inv numeric; v_recv boolean; v_tol numeric;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
          OR portal_can_see_request(p_request_id)) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  v_award := portal_award_total(p_request_id);
  v_inv   := portal_invoiced_total(p_request_id);
  v_recv  := EXISTS (SELECT 1 FROM portal_receipts WHERE request_id = p_request_id);
  v_tol   := portal_setting_num('three_way_tolerance_pct', 0);
  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'award_total', round(v_award, 2),
    'invoiced_total', round(v_inv, 2),
    'received', v_recv,
    'variance', round(v_inv - v_award, 2),
    'within_tolerance', v_inv <= v_award * (1 + v_tol/100.0),
    'matched', v_recv AND v_inv > 0 AND v_inv <= v_award * (1 + v_tol/100.0),
    'enforced', portal_setting_num('three_way_enforce', 0) >= 1
  );
END $fn$;
REVOKE ALL ON FUNCTION portal_three_way_status(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_three_way_status(text) TO authenticated;

-- ── (4) تسجيل فاتورة مورد + كشف التكرار ─────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_invoice_record(
    p_request_id text, p_invoice_no text, p_amount numeric,
    p_supplier_name text DEFAULT NULL, p_invoice_date date DEFAULT NULL,
    p_doc_key text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_no text := trim(coalesce(p_invoice_no,'')); v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بتسجيل الفاتورة';
  END IF;
  IF v_no = '' THEN RAISE EXCEPTION 'رقم الفاتورة مطلوب'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'مبلغ الفاتورة غير صالح'; END IF;
  -- (039) اسم المورد إلزامي — كي يعمل كشف الفاتورة المكرّرة عبر الطلبات دائماً (لا يُتجاوَز بحذفه).
  IF coalesce(trim(p_supplier_name),'') = '' THEN RAISE EXCEPTION 'اسم المورد مطلوب (لكشف الفاتورة المكرّرة)'; END IF;
  -- كشف الفاتورة المكرّرة: نفس رقم الفاتورة لنفس المورد على طلب آخر (منع ازدواج الصرف)
  IF p_supplier_name IS NOT NULL AND EXISTS (
      SELECT 1 FROM portal_supplier_invoices
      WHERE invoice_no = v_no AND lower(coalesce(supplier_name,'')) = lower(p_supplier_name)
        AND request_id <> p_request_id) THEN
    RAISE EXCEPTION 'فاتورة مكرّرة: رقم % من المورد % مسجَّل على طلب آخر', v_no, p_supplier_name;
  END IF;
  INSERT INTO portal_supplier_invoices(request_id, supplier_name, invoice_no, invoice_date, amount, doc_key, note, recorded_by)
    VALUES (p_request_id, p_supplier_name, v_no, p_invoice_date, p_amount, p_doc_key, p_note, v_me)
    RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'invoice_id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_invoice_record(text, text, numeric, text, date, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_invoice_record(text, text, numeric, text, date, text, text) TO authenticated;

-- ── (5) الإنفاذ: مُشغِّل على portal_payments (الصرف الآجل فقط) ────────────────
CREATE OR REPLACE FUNCTION portal_three_way_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_award numeric; v_inv numeric; v_tol numeric;
BEGIN
  IF portal_setting_num('three_way_enforce', 0) < 1 THEN RETURN NEW; END IF;
  IF NEW.kind <> 'credit' THEN RETURN NEW; END IF;   -- الكاش/العهدة (مقدَّم) مستثنى — يتبع شرط الدفع
  IF NOT EXISTS (SELECT 1 FROM portal_receipts WHERE request_id = NEW.request_id) THEN
    RAISE EXCEPTION 'المطابقة الثلاثية: لا يوجد استلام مسجّل — الصرف الآجل يتطلّب استلام البضاعة';
  END IF;
  v_inv := portal_invoiced_total(NEW.request_id);
  IF v_inv <= 0 THEN RAISE EXCEPTION 'المطابقة الثلاثية: لا توجد فاتورة مورد مسجّلة للصرف الآجل'; END IF;
  v_award := portal_award_total(NEW.request_id);
  v_tol := portal_setting_num('three_way_tolerance_pct', 0);
  IF v_inv > v_award * (1 + v_tol/100.0) THEN
    RAISE EXCEPTION 'المطابقة الثلاثية: إجمالي الفواتير % يتجاوز أمر الشراء % (خارج التفاوت)',
      round(v_inv), round(v_award);
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_portal_three_way_guard ON portal_payments;
CREATE TRIGGER trg_portal_three_way_guard
  BEFORE INSERT ON portal_payments
  FOR EACH ROW EXECUTE FUNCTION portal_three_way_guard();


-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 034 (المرتجعات + إشعار مدين + صافي المطابقة) — مطابقة لـ 034
-- ═══════════════════════════════════════════════════════════════════════════
-- ── (1) جدول المرتجعات + إشعار مدين ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_returns (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  supplier_name TEXT,
  reason        TEXT NOT NULL,
  lines         JSONB,                                 -- [{seq, qty, unit_price, line_total}]
  debit_amount  NUMERIC NOT NULL DEFAULT 0 CHECK (debit_amount >= 0),
  debit_note_no TEXT,
  doc_key       TEXT,                                  -- محضر المرتجع (PDF/صورة، R2 kind=ret)
  status        TEXT NOT NULL DEFAULT 'issued',        -- issued | settled
  created_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_returns_req ON portal_returns(request_id);

ALTER TABLE portal_returns ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_returns_read ON portal_returns;
CREATE POLICY portal_returns_read ON portal_returns FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
  OR portal_has_perm('can_verify_stock') OR portal_can_see_request(request_id));
REVOKE ALL ON portal_returns FROM anon, PUBLIC;
GRANT  SELECT ON portal_returns TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_returns TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_returns_id_seq TO service_role;

-- ── (2) مجموع المرتجعات (خادمية) ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_returns_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(debit_amount), 0) FROM portal_returns WHERE request_id = p_request_id;
$fn$;
REVOKE ALL ON FUNCTION portal_returns_total(text) FROM anon, authenticated, PUBLIC;

-- ── (3) تسجيل مرتجع + إشعار مدين (استلام/جودة أو مشتريات/أدمن) ────────────────
CREATE OR REPLACE FUNCTION portal_return_record(
    p_request_id text, p_lines jsonb, p_reason text,
    p_supplier_name text DEFAULT NULL, p_doc_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_ln jsonb; v_amt numeric := 0; v_q numeric; v_p numeric;
        v_lines jsonb := '[]'::jsonb; v_seq int; v_no text; v_n int; v_id bigint; v_recv numeric; v_prior numeric;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_verify_stock')
                          OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بتسجيل مرتجع';
  END IF;
  IF coalesce(trim(p_reason),'') = '' THEN RAISE EXCEPTION 'سبب المرتجع مطلوب'; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'بنود المرتجع مطلوبة';
  END IF;
  FOR v_ln IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_seq := (v_ln->>'seq')::int;
    v_q := coalesce((v_ln->>'qty')::numeric, 0);
    v_p := coalesce((v_ln->>'unit_price')::numeric, 0);
    IF v_q <= 0 THEN RAISE EXCEPTION 'كمية مرتجع غير صالحة (يجب أن تكون موجبة)'; END IF;
    IF v_p < 0 THEN RAISE EXCEPTION 'سعر بند غير صالح'; END IF;
    -- (039) تحقّق التكامل: البند من بنود الطلب، وكمية المرتجع (شاملةً المرتجعات السابقة لنفس البند)
    -- لا تتجاوز المستلَم فعلاً — يمنع إشعار مدين مضخَّم/إرجاع بضاعة غير مستلَمة.
    SELECT coalesce(received_qty,0) INTO v_recv FROM portal_request_items
      WHERE request_id = p_request_id AND seq = v_seq;
    IF v_recv IS NULL THEN RAISE EXCEPTION 'بند المرتجع % ليس من بنود الطلب', v_seq; END IF;
    SELECT coalesce(sum((l->>'qty')::numeric),0) INTO v_prior
      FROM portal_returns pr, jsonb_array_elements(coalesce(pr.lines,'[]'::jsonb)) l
      WHERE pr.request_id = p_request_id AND (l->>'seq')::int = v_seq;
    IF v_q + v_prior > v_recv THEN
      RAISE EXCEPTION 'كمية المرتجع للبند % (%+سابقة %) تتجاوز المستلَم (%)', v_seq, v_q, v_prior, v_recv;
    END IF;
    v_amt := v_amt + (v_q * v_p);
    v_lines := v_lines || jsonb_build_object('seq', v_seq, 'qty', v_q, 'unit_price', v_p, 'line_total', v_q * v_p);
  END LOOP;
  -- رقم إشعار مدين تسلسلي للطلب
  SELECT count(*) INTO v_n FROM portal_returns WHERE request_id = p_request_id;
  v_no := 'DN-' || right(p_request_id, 4) || '-' || lpad((v_n + 1)::text, 2, '0');

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_returns(request_id, supplier_name, reason, lines, debit_amount, debit_note_no, doc_key, created_by)
    VALUES (p_request_id, p_supplier_name, p_reason, v_lines, v_amt, v_no, p_doc_key, v_me)
    RETURNING id INTO v_id;
  PERFORM set_config('app.portal_transition', '0', true);

  RETURN jsonb_build_object('ok', true, 'return_id', v_id, 'debit_note_no', v_no, 'debit_amount', round(v_amt, 2));
END $fn$;
REVOKE ALL ON FUNCTION portal_return_record(text, jsonb, text, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_return_record(text, jsonb, text, text, text) TO authenticated;

-- ── (4) حالة المرتجعات (للعرض) ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_return_status(p_request_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
          OR portal_has_perm('can_verify_stock') OR portal_can_see_request(p_request_id)) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'returns_total', round(portal_returns_total(p_request_id), 2),
    'count', (SELECT count(*) FROM portal_returns WHERE request_id = p_request_id));
END $fn$;
REVOKE ALL ON FUNCTION portal_return_status(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_return_status(text) TO authenticated;

-- ── (5) دمج في المطابقة الثلاثية: صافي المستحق = أمر الشراء − المرتجعات ──────
CREATE OR REPLACE FUNCTION portal_three_way_status(p_request_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_award numeric; v_inv numeric; v_ret numeric; v_recv boolean; v_tol numeric; v_net numeric;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
          OR portal_can_see_request(p_request_id)) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  v_award := portal_award_total(p_request_id);
  v_inv   := portal_invoiced_total(p_request_id);
  v_ret   := portal_returns_total(p_request_id);
  v_recv  := EXISTS (SELECT 1 FROM portal_receipts WHERE request_id = p_request_id);
  v_tol   := portal_setting_num('three_way_tolerance_pct', 0);
  v_net   := v_award - v_ret;
  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'award_total', round(v_award, 2),
    'returns_total', round(v_ret, 2),
    'net_payable', round(v_net, 2),
    'invoiced_total', round(v_inv, 2),
    'received', v_recv,
    'variance', round(v_inv - v_net, 2),
    'within_tolerance', v_inv <= v_net * (1 + v_tol/100.0),
    'matched', v_recv AND v_inv > 0 AND v_inv <= v_net * (1 + v_tol/100.0),
    'enforced', portal_setting_num('three_way_enforce', 0) >= 1);
END $fn$;
REVOKE ALL ON FUNCTION portal_three_way_status(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_three_way_status(text) TO authenticated;

-- ── (6) مُشغِّل الإنفاذ يحترم صافي المستحق (أمر الشراء − المرتجعات) ───────────
CREATE OR REPLACE FUNCTION portal_three_way_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_net numeric; v_inv numeric; v_tol numeric;
BEGIN
  IF portal_setting_num('three_way_enforce', 0) < 1 THEN RETURN NEW; END IF;
  IF NEW.kind <> 'credit' THEN RETURN NEW; END IF;   -- الكاش/العهدة (مقدَّم) مستثنى
  IF NOT EXISTS (SELECT 1 FROM portal_receipts WHERE request_id = NEW.request_id) THEN
    RAISE EXCEPTION 'المطابقة الثلاثية: لا يوجد استلام مسجّل — الصرف الآجل يتطلّب استلام البضاعة';
  END IF;
  v_inv := portal_invoiced_total(NEW.request_id);
  IF v_inv <= 0 THEN RAISE EXCEPTION 'المطابقة الثلاثية: لا توجد فاتورة مورد مسجّلة للصرف الآجل'; END IF;
  v_net := portal_award_total(NEW.request_id) - portal_returns_total(NEW.request_id);  -- صافي المستحق
  v_tol := portal_setting_num('three_way_tolerance_pct', 0);
  IF v_inv > v_net * (1 + v_tol/100.0) THEN
    RAISE EXCEPTION 'المطابقة الثلاثية: إجمالي الفواتير % يتجاوز صافي المستحق % (أمر الشراء − المرتجعات، خارج التفاوت)',
      round(v_inv), round(v_net);
  END IF;
  RETURN NEW;
END $fn$;
-- المُشغِّل نفسه معرّف في 033؛ إعادة تعريف الدالة تكفي (CREATE OR REPLACE).


-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 035 (أساس تعدّد العملات) — مطابقة لـ db/portal-migrations/035
-- ═══════════════════════════════════════════════════════════════════════════
-- ── (1) جدول العملات + بذرة الأساس ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_currencies (
  code         TEXT PRIMARY KEY,                          -- ISO: SAR, USD, EUR, AED...
  name         TEXT,
  rate_to_base NUMERIC NOT NULL DEFAULT 1 CHECK (rate_to_base > 0),
  active       BOOLEAN NOT NULL DEFAULT true,
  updated_by   TEXT,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO portal_currencies(code, name, rate_to_base, active)
  VALUES ('SAR','ريال سعودي',1,true) ON CONFLICT (code) DO NOTHING;
-- عملة الأساس في الإعدادات (افتراضي SAR)
UPDATE portal_settings SET value = jsonb_set(coalesce(value,'{}'::jsonb),'{base_currency}', to_jsonb('SAR'::text), true)
  WHERE key='portal_settings' AND NOT (coalesce(value,'{}'::jsonb) ? 'base_currency');

-- العملات مرجع عام (قراءة لكل مسجَّل، كتابة عبر RPC فقط)
ALTER TABLE portal_currencies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_currencies_read ON portal_currencies;
CREATE POLICY portal_currencies_read ON portal_currencies FOR SELECT TO authenticated USING (true);
REVOKE ALL ON portal_currencies FROM anon, PUBLIC;
GRANT  SELECT ON portal_currencies TO authenticated, anon;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_currencies TO service_role;

-- ── (2) سعر التحويل لعملة الأساس (1 للأساس أو المفقود) ───────────────────────
CREATE OR REPLACE FUNCTION portal_currency_rate(p_code text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE((SELECT rate_to_base FROM portal_currencies WHERE code = upper(coalesce(nullif(trim(p_code),''),'SAR'))), 1);
$fn$;
REVOKE ALL ON FUNCTION portal_currency_rate(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_currency_rate(text) TO authenticated;

-- ── (3) إدارة العملات (مالية/أدمن) ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_currency_set(p_code text, p_name text, p_rate numeric, p_active boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_code text := upper(trim(coalesce(p_code,'')));
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'إدارة العملات صلاحية مالية/أدمن';
  END IF;
  IF v_code !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'رمز عملة غير صالح (3 أحرف ISO)'; END IF;
  IF p_rate IS NULL OR p_rate <= 0 THEN RAISE EXCEPTION 'سعر الصرف غير صالح'; END IF;
  INSERT INTO portal_currencies(code, name, rate_to_base, active, updated_by, updated_at)
    VALUES (v_code, p_name, p_rate, coalesce(p_active,true), v_me, now())
  ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, rate_to_base = EXCLUDED.rate_to_base,
    active = EXCLUDED.active, updated_by = v_me, updated_at = now();
  RETURN jsonb_build_object('ok', true, 'code', v_code, 'rate', p_rate);
END $fn$;
REVOKE ALL ON FUNCTION portal_currency_set(text, text, numeric, boolean) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_currency_set(text, text, numeric, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION portal_currency_delete(p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_code text := upper(trim(coalesce(p_code,''))); v_base text;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'إدارة العملات صلاحية مالية/أدمن';
  END IF;
  v_base := upper(coalesce((SELECT value->>'base_currency' FROM portal_settings WHERE key='portal_settings'),'SAR'));
  IF v_code = v_base THEN RAISE EXCEPTION 'لا يمكن حذف عملة الأساس (%)', v_base; END IF;
  DELETE FROM portal_currencies WHERE code = v_code;
  RETURN jsonb_build_object('ok', true);
END $fn$;
REVOKE ALL ON FUNCTION portal_currency_delete(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_currency_delete(text) TO authenticated;

-- ── (4) دوال القيمة صارت واعية بالعملة (تحويل لعملة الأساس) ──────────────────
-- إجمالي أمر الشراء بعملة الأساس = (winner_total أو مجموع بنود المجزّأ) × الضريبة × سعر عملة الطلب.
CREATE OR REPLACE FUNCTION portal_award_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(
    COALESCE((SELECT sum(line_total) FROM portal_award_lines WHERE request_id = p_request_id),
             (SELECT winner_total FROM portal_award WHERE request_id = p_request_id AND status IN ('pending','approved'))),
    0)
  * (1 + portal_setting_num('vat', 15) / 100.0)
  * portal_currency_rate((SELECT currency FROM portal_requests WHERE id = p_request_id));
$fn$;
REVOKE ALL ON FUNCTION portal_award_total(text) FROM anon, authenticated, PUBLIC;

-- المرتبط (الميزانية) بعملة الأساس = مجموع التعميدات النشطة × الضريبة × سعر عملة كل طلب.
CREATE OR REPLACE FUNCTION portal_budget_committed(p_dept text, p_year int)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(
    COALESCE((SELECT sum(al.line_total) FROM portal_award_lines al WHERE al.request_id = a.request_id),
             a.winner_total)
    * (1 + portal_setting_num('vat', 15) / 100.0)
    * portal_currency_rate(r.currency)
  ), 0)
  FROM portal_award a
  JOIN portal_requests r ON r.id = a.request_id
  WHERE a.status IN ('pending','approved')
    AND r.department_id = p_dept
    AND EXTRACT(YEAR FROM r.created_at)::int = p_year
    AND coalesce(r.status,'') <> 'cancelled';
$fn$;
REVOKE ALL ON FUNCTION portal_budget_committed(text, int) FROM anon, authenticated, PUBLIC;

-- إجمالي الفواتير والمرتجعات بعملة الأساس (تُدخَل بعملة الطلب) — لاتّساق المطابقة الثلاثية.
CREATE OR REPLACE FUNCTION portal_invoiced_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(amount), 0) * portal_currency_rate((SELECT currency FROM portal_requests WHERE id = p_request_id))
  FROM portal_supplier_invoices WHERE request_id = p_request_id;
$fn$;
REVOKE ALL ON FUNCTION portal_invoiced_total(text) FROM anon, authenticated, PUBLIC;

CREATE OR REPLACE FUNCTION portal_returns_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(debit_amount), 0) * portal_currency_rate((SELECT currency FROM portal_requests WHERE id = p_request_id))
  FROM portal_returns WHERE request_id = p_request_id;
$fn$;
REVOKE ALL ON FUNCTION portal_returns_total(text) FROM anon, authenticated, PUBLIC;


-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 036 (تعيين عملة الطلب) — مطابقة لـ db/portal-migrations/036
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION portal_set_request_currency(p_request_id text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_code text := upper(trim(coalesce(p_code,'')));
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF NOT (v_req.requester = v_me OR portal_has_perm('can_manage_procurement') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'تعيين العملة: صاحب الطلب أو المشتريات فقط';
  END IF;
  IF v_req.phase NOT IN ('requisition','pricing') THEN
    RAISE EXCEPTION 'تُحدَّد العملة قبل التعميد فقط (الطور الحالي: %)', v_req.phase;
  END IF;
  IF EXISTS (SELECT 1 FROM portal_award WHERE request_id = p_request_id AND status IN ('pending','approved')) THEN
    RAISE EXCEPTION 'لا يمكن تغيير العملة بعد الترسية';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_currencies WHERE code = v_code AND active) THEN
    RAISE EXCEPTION 'عملة غير معرّفة أو غير مفعّلة: %', v_code;
  END IF;
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET currency = v_code, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);
  RETURN jsonb_build_object('ok', true, 'currency', v_code);
END $fn$;
REVOKE ALL ON FUNCTION portal_set_request_currency(text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_set_request_currency(text, text) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 037 (العقود الإطارية / أوامر الشراء الممتدّة) — مطابقة لـ 037
-- ═══════════════════════════════════════════════════════════════════════════
-- ── (1) جدول العقود الإطارية ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_contracts (
  id            BIGSERIAL PRIMARY KEY,
  contract_no   TEXT,
  title         TEXT NOT NULL,
  supplier_name TEXT,
  start_date    DATE,
  end_date      DATE,
  ceiling       NUMERIC NOT NULL DEFAULT 0 CHECK (ceiling >= 0),  -- بعملة الأساس
  currency      TEXT NOT NULL DEFAULT 'SAR',
  status        TEXT NOT NULL DEFAULT 'active',                   -- active | closed
  note          TEXT,
  created_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_contracts_status ON portal_contracts(status);

ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS contract_id BIGINT REFERENCES portal_contracts(id);

ALTER TABLE portal_contracts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_contracts_read ON portal_contracts;
CREATE POLICY portal_contracts_read ON portal_contracts FOR SELECT TO authenticated USING (true);  -- مرجع للمشتريات/الكل
REVOKE ALL ON portal_contracts FROM anon, PUBLIC;
GRANT  SELECT ON portal_contracts TO authenticated, anon;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_contracts TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_contracts_id_seq TO service_role;

-- ── (2) المُستهلَك من العقد (بعملة الأساس) ──────────────────────────────────
CREATE OR REPLACE FUNCTION portal_contract_consumed(p_contract_id bigint)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(portal_award_total(r.id)), 0)
  FROM portal_requests r
  WHERE r.contract_id = p_contract_id
    AND coalesce(r.status,'') <> 'cancelled'
    AND EXISTS (SELECT 1 FROM portal_award a WHERE a.request_id = r.id AND a.status IN ('pending','approved'));
$fn$;
REVOKE ALL ON FUNCTION portal_contract_consumed(bigint) FROM anon, authenticated, PUBLIC;

-- ── (3) حالة العقد ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_contract_status(p_contract_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_c portal_contracts%ROWTYPE; v_used numeric;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement') OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  SELECT * INTO v_c FROM portal_contracts WHERE id = p_contract_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'العقد غير موجود'; END IF;
  v_used := portal_contract_consumed(p_contract_id);
  RETURN jsonb_build_object('id', p_contract_id, 'ceiling', round(v_c.ceiling,2), 'consumed', round(v_used,2),
    'available', round(v_c.ceiling - v_used, 2), 'status', v_c.status,
    'releases', (SELECT count(*) FROM portal_requests WHERE contract_id = p_contract_id AND coalesce(status,'') <> 'cancelled'),
    'expired', (v_c.end_date IS NOT NULL AND v_c.end_date < current_date),
    'enforced', portal_setting_num('contract_enforce', 0) >= 1);
END $fn$;
REVOKE ALL ON FUNCTION portal_contract_status(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_contract_status(bigint) TO authenticated;

-- ── (4) إدارة العقود (مشتريات/أدمن) ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_contract_set(p_id bigint, p_title text, p_supplier text, p_ceiling numeric,
    p_start date, p_end date, p_no text DEFAULT NULL, p_currency text DEFAULT 'SAR', p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'إدارة العقود صلاحية مشتريات/أدمن';
  END IF;
  IF coalesce(trim(p_title),'') = '' THEN RAISE EXCEPTION 'عنوان العقد مطلوب'; END IF;
  IF p_ceiling IS NULL OR p_ceiling < 0 THEN RAISE EXCEPTION 'سقف غير صالح'; END IF;
  IF p_end IS NOT NULL AND p_start IS NOT NULL AND p_end < p_start THEN RAISE EXCEPTION 'تاريخ النهاية قبل البداية'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO portal_contracts(contract_no, title, supplier_name, ceiling, currency, start_date, end_date, note, created_by)
      VALUES (p_no, p_title, p_supplier, p_ceiling, upper(coalesce(nullif(p_currency,''),'SAR')), p_start, p_end, p_note, v_me)
      RETURNING id INTO v_id;
  ELSE
    UPDATE portal_contracts SET contract_no=p_no, title=p_title, supplier_name=p_supplier, ceiling=p_ceiling,
      currency=upper(coalesce(nullif(p_currency,''),'SAR')), start_date=p_start, end_date=p_end, note=p_note
      WHERE id=p_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'العقد غير موجود'; END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'contract_id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_contract_set(bigint, text, text, numeric, date, date, text, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_contract_set(bigint, text, text, numeric, date, date, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION portal_contract_close(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username();
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'إدارة العقود صلاحية مشتريات/أدمن';
  END IF;
  UPDATE portal_contracts SET status='closed' WHERE id=p_id;
  RETURN jsonb_build_object('ok', true);
END $fn$;
REVOKE ALL ON FUNCTION portal_contract_close(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_contract_close(bigint) TO authenticated;

-- ── (5) ربط طلب بعقد (طلب سحب) — قبل التعميد ────────────────────────────────
CREATE OR REPLACE FUNCTION portal_link_request_contract(p_request_id text, p_contract_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_c portal_contracts%ROWTYPE;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'ربط الطلب بعقد صلاحية مشتريات/أدمن';
  END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase NOT IN ('requisition','pricing') THEN RAISE EXCEPTION 'الربط قبل التعميد فقط'; END IF;
  IF p_contract_id IS NOT NULL THEN
    SELECT * INTO v_c FROM portal_contracts WHERE id = p_contract_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'العقد غير موجود'; END IF;
    IF v_c.status <> 'active' THEN RAISE EXCEPTION 'العقد غير نشط'; END IF;
    IF v_c.end_date IS NOT NULL AND v_c.end_date < current_date THEN RAISE EXCEPTION 'العقد منتهٍ'; END IF;
  END IF;
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET contract_id = p_contract_id, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);
  RETURN jsonb_build_object('ok', true, 'contract_id', p_contract_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_link_request_contract(text, bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_link_request_contract(text, bigint) TO authenticated;

-- ── (6) الإنفاذ: مُشغِّل قيد مؤجَّل على portal_award ─────────────────────────
CREATE OR REPLACE FUNCTION portal_contract_enforce() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_cid bigint; v_c portal_contracts%ROWTYPE; v_used numeric; v_enforce numeric;
BEGIN
  SELECT contract_id INTO v_cid FROM portal_requests WHERE id = NEW.request_id;
  IF v_cid IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_c FROM portal_contracts WHERE id = v_cid;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_enforce := portal_setting_num('contract_enforce', 0);
  IF v_c.end_date IS NOT NULL AND v_c.end_date < current_date THEN
    IF v_enforce >= 1 THEN RAISE EXCEPTION 'العقد الإطاري % منتهٍ — لا سحب جديد', v_cid;
    ELSE RAISE WARNING 'تحذير: تعميد على عقد إطاري منتهٍ (%)', v_cid; END IF;
  END IF;
  v_used := portal_contract_consumed(v_cid);
  IF v_used > v_c.ceiling THEN
    IF v_enforce >= 1 THEN
      RAISE EXCEPTION 'تجاوز سقف العقد الإطاري %: المُستهلَك % يتجاوز السقف %', v_cid, round(v_used), round(v_c.ceiling);
    ELSE
      RAISE WARNING 'تحذير: تجاوز سقف العقد الإطاري % (% > %)', v_cid, round(v_used), round(v_c.ceiling);
    END IF;
  END IF;
  RETURN NULL;
END $fn$;
DROP TRIGGER IF EXISTS trg_portal_contract_enforce ON portal_award;
CREATE CONSTRAINT TRIGGER trg_portal_contract_enforce
  AFTER INSERT OR UPDATE ON portal_award
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION portal_contract_enforce();

-- ═══════════════════════════════════════════════════════════════════════════
--  دمج الهجرة 040 — تصليب من مدقّق Supabase الحيّ (search_path + سحب anon + فهارس FK)
-- ═══════════════════════════════════════════════════════════════════════════
ALTER FUNCTION public.portal_audit_immutable() SET search_path = public;
ALTER FUNCTION public.portal_gen_token()       SET search_path = public;
ALTER FUNCTION public.portal_is_privileged()   SET search_path = public;
ALTER FUNCTION public.portal_set_due()         SET search_path = public;

DO $$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'portal_budget_enforce()','portal_contract_enforce()',
    'portal_supplier_iban_guard()','portal_three_way_guard()'
  ] LOOP
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.'||fn||' FROM anon';
  END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS idx_portal_award_doa           ON portal_award(doa_id);
CREATE INDEX IF NOT EXISTS idx_portal_award_winner_offer  ON portal_award(winner_offer_id);
CREATE INDEX IF NOT EXISTS idx_portal_award_lines_offer   ON portal_award_lines(offer_id);
CREATE INDEX IF NOT EXISTS idx_portal_depts_manager       ON portal_departments(manager_user);
CREATE INDEX IF NOT EXISTS idx_portal_inv_dept            ON portal_invitations(department_id);
CREATE INDEX IF NOT EXISTS idx_portal_inv_job             ON portal_invitations(job_key);
CREATE INDEX IF NOT EXISTS idx_portal_pay_award_offer     ON portal_payments(award_offer_id);
CREATE INDEX IF NOT EXISTS idx_portal_req_contract        ON portal_requests(contract_id);
CREATE INDEX IF NOT EXISTS idx_portal_req_workflow        ON portal_requests(workflow_id);
CREATE INDEX IF NOT EXISTS idx_portal_users_delegate      ON portal_users(delegate_to);
CREATE INDEX IF NOT EXISTS idx_portal_users_dept          ON portal_users(department_id);
CREATE INDEX IF NOT EXISTS idx_portal_users_job           ON portal_users(job_key);
CREATE INDEX IF NOT EXISTS idx_portal_users_manager       ON portal_users(manager_user);
CREATE INDEX IF NOT EXISTS idx_portal_workflows_dept      ON portal_workflows(department_id);

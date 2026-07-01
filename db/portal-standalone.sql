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
ALTER TABLE portal_users ADD CONSTRAINT portal_users_dept_fk
  FOREIGN KEY (department_id) REFERENCES portal_departments(id) DEFERRABLE INITIALLY DEFERRED;

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
ALTER TABLE portal_users ADD CONSTRAINT portal_users_job_fk
  FOREIGN KEY (job_key) REFERENCES portal_jobs(key) DEFERRABLE INITIALLY DEFERRED;

-- مصفوفة صلاحيات التعميد (DoA) — الدورة الثانية، حسب قيمة العرض الفائز.
CREATE TABLE IF NOT EXISTS portal_doa (
  id                  BIGSERIAL PRIMARY KEY,
  max_value           NUMERIC,                              -- NULL = بلا حدّ أعلى
  quotes_required     INT NOT NULL DEFAULT 3,
  committee_required  BOOLEAN NOT NULL DEFAULT false,
  award_role_key      TEXT NOT NULL,                        -- مفتاح صلاحية معتمِد التعميد لهذه الشريحة
  po_role_key         TEXT NOT NULL DEFAULT 'can_manage_procurement',
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
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

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
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
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

CREATE OR REPLACE FUNCTION portal_approvals_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN NEW; END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN NEW; END IF;
  IF NEW.decision IS NOT NULL AND NEW.decision <> 'pending' THEN
    IF NOT portal_is_admin() THEN
      RAISE EXCEPTION 'تُتخذ قرارات الاعتماد عبر سلسلة الموافقات فقط';
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

CREATE OR REPLACE FUNCTION portal_request_status_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN NEW; END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN NEW; END IF;
  -- يمنع انتحال «الطالب» عبر إدراج مباشر من العميل (بدل المرور بـ portal_create_request)؛
  -- هوية الطالب تُشتقّ من الجلسة دائماً، لا مُدخَل عميل خام.
  IF TG_OP = 'INSERT' AND NEW.requester IS DISTINCT FROM portal_username() AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'requester يجب أن يطابق هويّتك';
  END IF;
  IF NEW.status IN ('approved','rejected','returned','awarded','payment_pending','receipt_pending','closed')
     AND (TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status) THEN
    IF NOT portal_is_admin() THEN
      RAISE EXCEPTION 'حالة الطلب تُحدَّث عبر آلة الحالة فقط';
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

CREATE OR REPLACE FUNCTION portal_award_approvals_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN NEW; END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN NEW; END IF;
  IF NEW.decision IS NOT NULL AND NEW.decision <> 'pending' THEN
    IF NOT portal_is_admin() THEN
      RAISE EXCEPTION 'تُتخذ قرارات التعميد عبر سلسلة الاعتماد فقط';
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

CREATE OR REPLACE FUNCTION portal_award_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN NEW; END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN NEW; END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'حالة التعميد تُحدَّث عبر سلسلة الاعتماد فقط';
  END IF;
  RETURN NEW;
END $fn$;

CREATE OR REPLACE FUNCTION portal_payments_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN NEW; END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN NEW; END IF;
  IF NEW.status IN ('approved_pay','rejected','disbursed')
     AND (TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status) THEN
    IF NOT portal_is_admin() THEN
      RAISE EXCEPTION 'حالة الصرف تُحدَّث عبر دالة الاعتماد فقط';
    END IF;
  END IF;
  RETURN NEW;
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

DROP TRIGGER IF EXISTS trg_portal_approvals_guard ON portal_approvals;
CREATE TRIGGER trg_portal_approvals_guard BEFORE INSERT OR UPDATE ON portal_approvals
  FOR EACH ROW EXECUTE FUNCTION portal_approvals_guard();

DROP TRIGGER IF EXISTS trg_portal_req_status_guard ON portal_requests;
CREATE TRIGGER trg_portal_req_status_guard BEFORE INSERT OR UPDATE ON portal_requests
  FOR EACH ROW EXECUTE FUNCTION portal_request_status_guard();

DROP TRIGGER IF EXISTS trg_portal_award_appr_guard ON portal_award_approvals;
CREATE TRIGGER trg_portal_award_appr_guard BEFORE INSERT OR UPDATE ON portal_award_approvals
  FOR EACH ROW EXECUTE FUNCTION portal_award_approvals_guard();

DROP TRIGGER IF EXISTS trg_portal_award_guard ON portal_award;
CREATE TRIGGER trg_portal_award_guard BEFORE UPDATE ON portal_award
  FOR EACH ROW EXECUTE FUNCTION portal_award_guard();

DROP TRIGGER IF EXISTS trg_portal_payments_guard ON portal_payments;
CREATE TRIGGER trg_portal_payments_guard BEFORE INSERT OR UPDATE ON portal_payments
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
CREATE OR REPLACE FUNCTION portal_create_request(p_title text, p_department_id text, p_priority text, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_id text;
  v_item jsonb;
  v_seq int := 0;
  v_est numeric := 0;
  v_name text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF coalesce(trim(p_title), '') = '' THEN RAISE EXCEPTION 'عنوان الطلب مطلوب'; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = p_department_id AND active) THEN
    RAISE EXCEPTION 'قسم غير صالح';
  END IF;
  IF jsonb_array_length(coalesce(p_items, '[]'::jsonb)) < 1 THEN RAISE EXCEPTION 'أضِف بنداً واحداً على الأقل'; END IF;

  v_id := 'REQ-' || to_char(now(), 'YYYYMMDD') || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
  SELECT display_name INTO v_name FROM portal_users WHERE username = v_me;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF coalesce(trim(v_item->>'desc'), '') = '' THEN RAISE EXCEPTION 'وصف كل بند مطلوب'; END IF;
    IF coalesce((v_item->>'qty')::numeric, 0) <= 0 THEN RAISE EXCEPTION 'كمية كل بند يجب أن تكون أكبر من صفر'; END IF;
    v_est := v_est + coalesce((v_item->>'qty')::numeric, 0) * coalesce((v_item->>'price')::numeric, 0);
  END LOOP;

  INSERT INTO portal_requests (id, title, department_id, requester, requester_name, priority, est_total, created_by)
    VALUES (v_id, trim(p_title), p_department_id, v_me, v_name, coalesce(nullif(p_priority, ''), 'متوسط'), v_est, v_me);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_seq := v_seq + 1;
    INSERT INTO portal_request_items (request_id, seq, description, unit, qty, unit_price)
      VALUES (v_id, v_seq, v_item->>'desc', v_item->>'unit', (v_item->>'qty')::numeric, coalesce((v_item->>'price')::numeric, 0));
  END LOOP;

  RETURN portal_submit_request(v_id) || jsonb_build_object('id', v_id);
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

  PERFORM portal_audit_write(p_request_id, 'submitted', v_me, 'portal', '{}'::jsonb);
  RETURN jsonb_build_object('ok', true, 'status', 'in_review');
END $fn$;

-- قرار مرحلة (اعتماد/رفض/إرجاع) — الدورة الأولى. مطابق تماماً لمنطق pr_transition
-- المُثبَت أمنياً (فصل مهام، تفويض، قفل صفوف، تحديث ذرّي).
CREATE OR REPLACE FUNCTION portal_pr_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_approvals%ROWTYPE;
  v_pending int; v_next_seq int; v_decision text; v_status text; v_phase text;
  v_ok boolean := false; v_intended text; v_perm boolean;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'in_review' THEN RAISE EXCEPTION 'الطلب ليس قيد المراجعة'; END IF;

  SELECT * INTO v_stage FROM portal_approvals
    WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة معلّقة'; END IF;

  IF v_req.requester = v_me THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;

  v_intended := portal_resolve_stage(p_request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    v_ok := (portal_effective_approver(v_intended) = v_me);
  ELSIF v_stage.role_key IS NOT NULL THEN
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm
      FROM portal_users WHERE username = v_me;
    v_ok := coalesce(v_perm, false);
  END IF;
  IF NOT v_ok AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action IN ('reject','return') AND coalesce(trim(p_comment),'') = '' THEN
    RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع';
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

  PERFORM portal_audit_write(p_request_id, 'stage_' || v_decision, v_me, 'portal', jsonb_build_object('stage', v_stage.stage_label, 'comment', p_comment));

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
                             'finalized', v_status <> 'in_review', 'seq', v_stage.seq);
END $fn$;


-- ═══════════════════════ 6) التسعير + التعميد (الدورة الثانية) ═══════════════════════

CREATE OR REPLACE FUNCTION portal_submit_offer(p_request_id text, p_supplier text, p_total numeric,
    p_delivery_days int DEFAULT NULL, p_quality int DEFAULT NULL, p_payment_days int DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_phase text; v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT phase INTO v_phase FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF v_phase IS NULL THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;
  IF coalesce(p_supplier,'') = '' OR coalesce(p_total,0) <= 0 THEN RAISE EXCEPTION 'بيانات العرض غير مكتملة'; END IF;

  INSERT INTO portal_offers(request_id, supplier_name, total, delivery_days, quality, payment_days, note, entered_by)
    VALUES (p_request_id, p_supplier, p_total, p_delivery_days, p_quality, p_payment_days, p_note, v_me)
    RETURNING id INTO v_id;

  PERFORM portal_audit_write(p_request_id, 'offer_added', v_me, 'portal', jsonb_build_object('supplier', p_supplier, 'total', p_total));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

-- ترسية: يختار عرضاً فائزاً، يطابق مصفوفة DoA بالقيمة، ويبني سلسلة اعتماد التعميد.
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

  INSERT INTO portal_award(request_id, winner_offer_id, winner_total, award_reason, doa_id, status)
    VALUES (p_request_id, p_winner_offer_id, v_offer.total, p_reason, v_doa.id, 'pending')
  ON CONFLICT (request_id) DO UPDATE SET winner_offer_id = EXCLUDED.winner_offer_id, winner_total = EXCLUDED.winner_total,
    award_reason = EXCLUDED.award_reason, doa_id = EXCLUDED.doa_id, status = 'pending';

  INSERT INTO portal_award_approvals(request_id, seq, stage_label, role_key, approver)
    VALUES (p_request_id, 1, 'اعتماد التعميد', v_doa.award_role_key, NULL);

  UPDATE portal_requests SET status = 'award_review', phase = 'award', current_seq = 1, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;

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
  v_perm boolean; v_decision text; v_status text; v_phase text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'award_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار اعتماد التعميد'; END IF;
  IF v_req.requester = v_me THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;

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
    v_status := 'awarded'; v_phase := 'payment';
    UPDATE portal_award SET status = 'approved' WHERE request_id = p_request_id;
    UPDATE portal_requests SET status = v_status, phase = v_phase, po_issued_by = v_me, po_issued_at = now(), updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
  ELSE
    v_status := 'pricing'; v_phase := 'pricing'; -- يعود للتسعير لاختيار عرض آخر
    UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
    UPDATE portal_requests SET status = v_status, phase = v_phase, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
  END IF;

  PERFORM portal_audit_write(p_request_id, 'award_' || v_decision, v_me, 'portal', jsonb_build_object('comment', p_comment));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;


-- ═══════════════════════ 7) الصرف ═══════════════════════

CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric, p_custody_to text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'نوع صرف غير صالح'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'مبلغ غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'الطلب ليس جاهزاً للصرف'; END IF;

  INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by)
    VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me) RETURNING id INTO v_id;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET status = 'payment_pending', updated_at = now(), updated_by = v_me WHERE id = p_request_id;

  PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal', jsonb_build_object('kind', p_kind, 'amount', p_amount));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment WHERE id = p_payment_id;
  ELSIF p_action = 'reject' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض'; END IF;
    v_status := 'rejected';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now() WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal', jsonb_build_object('payment_id', p_payment_id));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;


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

  FOR v_line IN SELECT * FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) LOOP
    UPDATE portal_request_items
      SET received_qty = LEAST(qty, received_qty + coalesce((v_line->>'qty')::numeric,0))
      WHERE id = (v_line->>'item_id')::bigint AND request_id = p_request_id;
  END LOOP;

  INSERT INTO portal_receipts(request_id, received_by, note, lines) VALUES (p_request_id, v_me, p_note, p_lines);

  SELECT sum(GREATEST(qty - received_qty, 0)) INTO v_remaining FROM portal_request_items WHERE request_id = p_request_id;

  PERFORM set_config('app.portal_transition', '1', true);
  IF coalesce(v_remaining, 0) <= 0 THEN
    UPDATE portal_requests SET status = 'closed', phase = 'closed', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    PERFORM portal_audit_write(p_request_id, 'closed', v_me, 'portal', '{}'::jsonb);
  ELSE
    UPDATE portal_requests SET updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  END IF;

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
  IF v_req.requester <> v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF v_req.requester = v_me AND v_req.status NOT IN ('draft','in_review','returned') AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك إلغاء الطلب بعد بدء التعميد — تواصل مع الإدارة';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET status = 'cancelled', cancelled_by = v_me, cancelled_at = now(), cancel_reason = p_reason, updated_at = now()
    WHERE id = p_request_id;

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

  IF v_req.requester = v_tok.approver THEN RETURN jsonb_build_object('error','sod','code',403); END IF;

  v_intended := portal_resolve_stage(v_tok.request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    v_ok := (portal_effective_approver(v_intended) = v_tok.approver);
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

  PERFORM portal_audit_write(v_tok.request_id, 'stage_' || v_decision, v_tok.approver, 'email', jsonb_build_object('stage', v_stage.stage_label, 'comment', p_comment));

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
    'finalized', v_status <> 'in_review', 'seq', v_stage.seq,
    'request', jsonb_build_object('id', v_req.id, 'title', v_req.title, 'department_id', v_req.department_id,
                                   'requester', v_req.requester, 'requester_name', v_req.requester_name));
END $fn$;


-- ═══════════════════════ 10) SLA/تصعيد (اختياري — pg_cron إن توفّر) ═══════════════════════

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

    UPDATE portal_requests SET escalations = escalations + 1,
      escalated_at = coalesce(escalated_at, now()), last_escalation_at = now() WHERE id = v_req.id;
    PERFORM portal_audit_write(v_req.id, 'escalated', NULL, 'system', jsonb_build_object('intended', v_intended, 'stage_label', v_stage.stage_label));
    v_cnt := v_cnt + 1;
  END LOOP;
  RETURN v_cnt;
END $fn$;

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
    'portal_award_approvals','portal_payments','portal_receipts','portal_notifications','portal_settings'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS "auth_all" ON %I', t);
    EXECUTE format('CREATE POLICY "auth_all" ON %I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;

-- التدقيق: قراءة فقط للمصادَق عليهم؛ الكتابة عبر الدالة portal_audit_write فقط
-- (SECURITY DEFINER)، والتعديل/الحذف ممنوعان كلياً بالمحرس أعلاه.
DROP POLICY IF EXISTS "audit_read" ON portal_audit;
CREATE POLICY "audit_read" ON portal_audit FOR SELECT TO authenticated USING (true);


-- ═══════════════════════ 12) بيانات أوّلية (DoA افتراضية — قابلة للتعديل من الإدارة) ═══════════════════════

INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key, label, note, priority)
SELECT 500, 1, false, 'can_manage_procurement', 'can_manage_procurement', 'أقل من 500', 'عرض واحد', 10
WHERE NOT EXISTS (SELECT 1 FROM portal_doa WHERE label = 'أقل من 500');

INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key, label, note, priority)
SELECT 100000, 3, false, 'can_manage_procurement', 'can_manage_procurement', '500 – 100,000', '٣ عروض', 20
WHERE NOT EXISTS (SELECT 1 FROM portal_doa WHERE label = '500 – 100,000');

INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key, label, note, priority)
SELECT 500000, 3, true, 'can_manage_users', 'can_manage_procurement', '100,001 – 500,000', '٣ عروض + لجنة (اعتماد المدير العام)', 30
WHERE NOT EXISTS (SELECT 1 FROM portal_doa WHERE label = '100,001 – 500,000');

INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key, label, note, priority)
SELECT NULL, 3, true, 'can_manage_users', 'can_manage_procurement', 'أكثر من 500,000', 'مناقصة رسمية (اعتماد المدير العام)', 40
WHERE NOT EXISTS (SELECT 1 FROM portal_doa WHERE label = 'أكثر من 500,000');

-- ملاحظة: award_role_key='can_manage_users' يعني عملياً «الأدمن/المدير العام» بما أن
-- الأدمن يملك كل الصلاحيات ضمناً عبر portal_has_perm(). يمكن للإدارة إضافة صلاحية
-- مخصّصة (مثلاً can_approve_gm) لاحقاً من لوحة الوظائف دون تعديل الكود.


-- ════════════════════════════════════════════════════════════════════════
--  للتراجع الفوري الكامل (يحذف كل كائنات البوابة المعزولة — لا يمسّ أي شيء
--  آخر في قاعدة البيانات):
--
--   DROP TABLE IF EXISTS portal_email_tokens, portal_notifications, portal_audit,
--     portal_receipts, portal_payments, portal_award_approvals, portal_award,
--     portal_offers, portal_approvals, portal_request_items, portal_requests,
--     portal_workflows, portal_doa, portal_jobs, portal_departments, portal_users,
--     portal_settings CASCADE;
--   DROP FUNCTION IF EXISTS portal_username, portal_is_admin, portal_is_service,
--     portal_is_privileged, portal_has_perm, portal_effective_approver, portal_resolve_stage,
--     portal_create_request, portal_submit_request, portal_pr_transition, portal_pr_transition_email,
--     portal_submit_offer, portal_award, portal_award_transition,
--     portal_payment_request, portal_payment_transition, portal_record_receipt,
--     portal_cancel_request, portal_gen_token, portal_create_token,
--     portal_sla_hours, portal_set_due, portal_run_sla, portal_audit_write,
--     portal_approvals_guard, portal_request_status_guard, portal_award_approvals_guard,
--     portal_award_guard, portal_payments_guard, portal_users_guard,
--     portal_config_guard, portal_audit_immutable CASCADE;
--   DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
--     PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname='portal-sla'; END IF; END $$;
-- ════════════════════════════════════════════════════════════════════════

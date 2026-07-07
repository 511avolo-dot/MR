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
CREATE OR REPLACE FUNCTION portal_pr_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL, p_hold_until date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_approvals%ROWTYPE;
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

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_offers(request_id, supplier_name, total, delivery_days, quality, payment_days, note, entered_by)
    VALUES (p_request_id, p_supplier, p_total, p_delivery_days, p_quality, p_payment_days, p_note, v_me)
    RETURNING id INTO v_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'offer_added', v_me, 'portal', jsonb_build_object('supplier', p_supplier, 'total', p_total));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

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
    -- فصل المهام: طالب الصرف لا يعتمده بنفسه.
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action = 'reject' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض'; END IF;
    v_status := 'rejected';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    -- فصل المهام (maker-checker على تحرير المال): من اعتمد الصرف لا ينفّذه بنفسه.
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now() WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
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

-- التدقيق: قراءة فقط للمصادَق عليهم؛ الكتابة عبر الدالة portal_audit_write فقط
-- (SECURITY DEFINER)، والتعديل/الحذف ممنوعان كلياً بالمحرس أعلاه.
DROP POLICY IF EXISTS "audit_read" ON portal_audit;
CREATE POLICY "audit_read" ON portal_audit FOR SELECT TO authenticated USING (true);


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

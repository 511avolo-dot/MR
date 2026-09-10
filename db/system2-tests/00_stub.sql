-- ════════════════════════════════════════════════════════════════════════════
--  كعب Supabase للنظام 2 — يحاكي ما يعتمد عليه db/system2-staff-scope.sql
-- ----------------------------------------------------------------------------
--  الغرض: تشغيل الهجرة وتأكيداتها على PostgreSQL محلّي بنفس دلالات Supabase:
--  دور `authenticated` + `auth.jwt()` تقرأ `request.jwt.claims` + الجداول
--  والدوال القائمة التي تبني عليها الهجرة (pr_username / pr_has_perm / …).
--  ⚠️ هذا كعب اختبار فقط — ليس مصدر حقيقة لمخطّط الإنتاج.
-- ════════════════════════════════════════════════════════════════════════════

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO authenticated, anon, service_role;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$;
GRANT USAGE ON SCHEMA auth TO authenticated, anon, service_role;

-- ── الجداول (الأعمدة التي تلمسها الهجرة أو تأكيداتها فقط) ──
CREATE TABLE IF NOT EXISTS proc_users (
  username TEXT PRIMARY KEY, display_name TEXT, email TEXT, password_hash TEXT NOT NULL DEFAULT 'x',
  role TEXT DEFAULT 'user', permissions JSONB DEFAULT '{}'::jsonb, active BOOLEAN DEFAULT true,
  department_id TEXT, manager_user TEXT, delegate_to TEXT, is_away BOOLEAN DEFAULT false,
  job_title TEXT, created_by TEXT, created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(), last_login TIMESTAMPTZ, notes TEXT
);
-- ⚠️ الأنواع **مطابقة للإنتاج حرفيّاً** (information_schema.columns على
--    yofcaxvstjcrmbgciwym). كتبتُها أوّل مرّة من منظور العميل (التواريخ نصوص
--    في JS) فكان `actual_delivery TEXT` بينما الإنتاج `date` — فمرّ عيب
--    حقيقيّ محلّياً وانكشف عند أوّل استدعاء حيّ:
--    «CASE types date and text cannot be matched».
--    كعبٌ لا يطابق أنواع الإنتاج ليس اختباراً.
CREATE TABLE IF NOT EXISTS proc_purchase_orders (
  po_number TEXT PRIMARY KEY, issue_date DATE, sector TEXT, project TEXT, supplier TEXT,
  subtotal NUMERIC, vat NUMERIC, total NUMERIC, officer TEXT, payment_method TEXT,
  priority TEXT, expected_delivery DATE, actual_delivery DATE, status TEXT,
  days_delayed INTEGER, delay_reason TEXT, notes TEXT, category TEXT, lead_time_days INTEGER,
  items JSONB, status_history JSONB, receipts JSONB, source JSONB,
  created_by TEXT, created_at TIMESTAMPTZ DEFAULT now(),
  updated_by TEXT, updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE TABLE IF NOT EXISTS proc_items    (code TEXT PRIMARY KEY, name TEXT, category TEXT, unit TEXT, notes TEXT);
CREATE TABLE IF NOT EXISTS proc_suppliers(id TEXT PRIMARY KEY, name TEXT, phone TEXT, iban TEXT);
CREATE TABLE IF NOT EXISTS proc_history  (num BIGINT PRIMARY KEY, code TEXT, supplier TEXT, price NUMERIC, date TEXT, reference TEXT);
-- ⚠️ أعمدة معالجة المشتريات بأنواع الإنتاج نفسها (db/pr-portal.sql §11):
--    proc_status TEXT · *_by TEXT · *_at TIMESTAMPTZ. كعبٌ لا يطابقها ليس اختباراً.
-- ⚠️ **مطابق لمخطّط الإنتاج عموداً بعمود** (information_schema على
--    yofcaxvstjcrmbgciwym). عمودٌ ناقص هنا يُخفي عيباً حقيقيّاً: غياب
--    `po_number` أخفى ربط الطلب بأمر الشراء حتى أوّل تشغيل. (وسبقه
--    `actual_delivery date` في جدول الأوامر.) كعبٌ لا يطابق الإنتاج ليس اختباراً.
CREATE TABLE IF NOT EXISTS proc_purchase_requests (
  id TEXT PRIMARY KEY, request_no TEXT, title TEXT, addressee TEXT,
  department_id TEXT, department TEXT, sector TEXT, project TEXT, requester TEXT,
  request_date DATE, needed_by DATE, period_from DATE, period_to DATE,
  priority TEXT, justification TEXT, est_total NUMERIC DEFAULT 0,
  total_in_words TEXT, currency TEXT, status TEXT DEFAULT 'draft',
  current_seq INT DEFAULT 0, approval_rule_id BIGINT, source JSONB,
  rfq_id TEXT, po_number TEXT,
  created_by TEXT, created_at TIMESTAMPTZ DEFAULT now(),
  updated_by TEXT, updated_at TIMESTAMPTZ,
  requester_name TEXT, requester_mobile TEXT,
  stage_due_at TIMESTAMPTZ, escalations INT, escalated_at TIMESTAMPTZ,
  last_escalation_at TIMESTAMPTZ,
  proc_status TEXT, proc_started_by TEXT, proc_started_at TIMESTAMPTZ,
  quotes_collected_by TEXT, quotes_collected_at TIMESTAMPTZ
);
CREATE TABLE IF NOT EXISTS proc_pr_items     (id BIGSERIAL PRIMARY KEY, pr_id TEXT, seq INT, name TEXT, qty NUMERIC, price NUMERIC);
CREATE TABLE IF NOT EXISTS proc_pr_approvals (id BIGSERIAL PRIMARY KEY, pr_id TEXT, seq INT, decision TEXT DEFAULT 'pending', approver TEXT, role_key TEXT);
CREATE TABLE IF NOT EXISTS proc_approval_rules (id BIGSERIAL PRIMARY KEY, priority INT, department_id TEXT, category TEXT, min_total NUMERIC, max_total NUMERIC, stages JSONB, active BOOLEAN DEFAULT true);
CREATE TABLE IF NOT EXISTS proc_audit_log (
  id BIGSERIAL PRIMARY KEY, ts TIMESTAMPTZ DEFAULT now(), username TEXT NOT NULL,
  display_name TEXT, user_role TEXT, action TEXT NOT NULL, entity_type TEXT,
  entity_id TEXT, old_value JSONB, new_value JSONB, meta JSONB
);

-- ── الدوال القائمة التي تبني عليها الهجرة (منقولة من db/pr-portal.sql
--    و db/proc-users-hardening.sql بنصّها) ──
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

CREATE OR REPLACE FUNCTION pr_is_service() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce(auth.jwt() ->> 'role','') = 'service_role';
$fn$;

CREATE OR REPLACE FUNCTION pr_has_perm(p_key text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS(
    SELECT 1 FROM proc_users
    WHERE lower(username) = lower(pr_username())
      AND coalesce(active, true)
      AND (role = 'admin' OR coalesce((permissions ->> p_key)::boolean, false)));
$fn$;

CREATE OR REPLACE FUNCTION proc_users_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF pr_is_service() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.permissions   IS NOT DISTINCT FROM OLD.permissions
     AND NEW.role          IS NOT DISTINCT FROM OLD.role
     AND NEW.active        IS NOT DISTINCT FROM OLD.active
     AND NEW.is_away       IS NOT DISTINCT FROM OLD.is_away
     AND NEW.delegate_to   IS NOT DISTINCT FROM OLD.delegate_to
     AND NEW.username      IS NOT DISTINCT FROM OLD.username
     AND NEW.email         IS NOT DISTINCT FROM OLD.email
     AND NEW.password_hash IS NOT DISTINCT FROM OLD.password_hash
  THEN RETURN NEW; END IF;
  IF pr_has_perm('can_manage_users') THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل المستخدمين أو صلاحياتهم يتطلّب صلاحية «إدارة المستخدمين»';
END $fn$;
DROP TRIGGER IF EXISTS trg_proc_users_guard ON proc_users;
CREATE TRIGGER trg_proc_users_guard BEFORE INSERT OR UPDATE OR DELETE ON proc_users
  FOR EACH ROW EXECUTE FUNCTION proc_users_guard();

-- الحالة قبل الهجرة: كل جدول مفتوح للمصادَق عليهم (وهو واقع الإنتاج اليوم).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['proc_users','proc_purchase_orders','proc_items','proc_suppliers',
                           'proc_history','proc_purchase_requests','proc_pr_items',
                           'proc_pr_approvals','proc_audit_log'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS "auth_all" ON %I', t);
    EXECUTE format('CREATE POLICY "auth_all" ON %I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO authenticated', t);
  END LOOP;
END $$;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- ⚠️ قاعدة اعتماد **نشطة** كواقع الإنتاج قبل التصحيح: بدونها يصير تأكيد
-- «سلسلة الاعتماد مُطفأة» فراغيّاً (العدّ صفر بالإطفاء وبدونه معاً).
INSERT INTO proc_approval_rules (priority, min_total, stages, active)
VALUES (10, 0, '[{"seq":1,"label":"مدير القسم","resolver":"dept_manager"}]'::jsonb, true);

-- ⚠️ **الامتيازات الافتراضية لـSupabase — بلا محاكاتها لا يكون هذا اختباراً.**
-- Supabase تضبط `ALTER DEFAULT PRIVILEGES` على `public` تمنح ALL لـanon و
-- authenticated على **كل جدول جديد**. قاعدة محلّية عارية لا تفعل ذلك، فهجرةٌ
-- تنسى `REVOKE` تمرّ محلّياً وتصل الإنتاج بقفل امتياز ناقص (وقع فعلاً في
-- `proc_pr_messages`). محاكاتها هنا تجعل الحزمة تمسك ذلك.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;

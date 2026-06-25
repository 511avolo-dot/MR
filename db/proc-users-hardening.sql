-- ════════════════════════════════════════════════════════════════════════════
--  تحصين كتابة جداول الإدارة — سدّ ثغرة رفع الصلاحيات الذاتي
-- ════════════════════════════════════════════════════════════════════════════
--  المشكلة (من المراجعة الأمنية العميقة):
--    سياسة RLS الحالية على proc_users / proc_approval_rules / proc_departments
--    من نوع `auth_all USING(true) WITH CHECK(true)` تتيح لأي مستخدم *مسجَّل دخوله*
--    أن يكتب في هذه الجداول مباشرةً عبر عميل Supabase في المتصفح — فيستطيع مستخدم
--    عادي منح نفسه صلاحية اعتماد (permissions)، أو رفع نفسه إلى role=admin، أو
--    وضع معتمِدٍ في «إجازة» وتحويل تفويضه إليه (is_away/delegate_to) ثم الاعتماد،
--    أو تعديل مسار الموافقات/الأقسام لإقحام نفسه في السلسلة.
--
--  الحل (نفس نمط المحارس الموجودة pr_guard_status/pr_guard_approval):
--    حارس BEFORE INSERT/UPDATE/DELETE يسمح فقط لـ:
--      • دور الخادم (service_role) — مسارات /api/* المحمية والتسجيل الذاتي،
--      • مديرٍ أو مستخدمٍ يملك صلاحية «إدارة المستخدمين» (can_manage_users) —
--        وهو نفس الشرط الذي تفرضه واجهتا index.html و requests.html أصلاً،
--    ويُبقي تحديثاً حميداً مسموحاً (مثل last_login) لأي مستخدم نشط.
--    ⇒ لا حاجة لتعديل index.html: المدير يجتاز الحارس تلقائياً؛ المستخدم العادي
--      يُمنَع فقط من الحقول الحسّاسة. نطاق الضرر يُغلَق دون كسر النظام الرئيسي.
--
--  المتطلّب المسبق: تطبيق db/pr-portal.sql أولاً (يوفّر pr_username/pr_is_service).
--  آمن لإعادة التشغيل (CREATE OR REPLACE / DROP TRIGGER IF EXISTS).
--
--  ── للتراجع الفوري إن ظهر أي خلل (انسخ هذا الجزء وشغّله) ─────────────────────
--    DROP TRIGGER IF EXISTS trg_proc_users_guard   ON proc_users;
--    DROP TRIGGER IF EXISTS trg_proc_apprules_guard ON proc_approval_rules;
--    DROP TRIGGER IF EXISTS trg_proc_depts_guard    ON proc_departments;
--  ────────────────────────────────────────────────────────────────────────────

-- هل لمستخدم JWT الحالي صلاحيةٌ معيّنة؟ (المدير يملك كل الصلاحيات ضمناً)
CREATE OR REPLACE FUNCTION pr_has_perm(p_key text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS(
    SELECT 1 FROM proc_users
    WHERE lower(username) = lower(pr_username())
      AND coalesce(active, true)
      AND (role = 'admin' OR coalesce((permissions ->> p_key)::boolean, false))
  );
$fn$;

-- ── حارس proc_users: يمنع رفع الصلاحيات/الأدوار/التفويض من غير المخوَّلين ──
CREATE OR REPLACE FUNCTION proc_users_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  -- الخادم (service_role) مسموح دائماً: /api/admin-users و /api/portal-signup.
  IF pr_is_service() THEN RETURN COALESCE(NEW, OLD); END IF;

  -- تحديثٌ حميد لا يمسّ أيّ حقلٍ حسّاس (مثل last_login) → مسموح لأي مستخدم نشط.
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

  -- إنشاء/حذف، أو تعديل حقلٍ حسّاس → يتطلّب صلاحية إدارة المستخدمين (أو مدير).
  IF pr_has_perm('can_manage_users') THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل المستخدمين أو صلاحياتهم يتطلّب صلاحية «إدارة المستخدمين»';
END $fn$;

-- ── حارس إعدادات المسار والأقسام: تعديلٌ إداريّ فقط (نفس شرط الواجهتين) ──
CREATE OR REPLACE FUNCTION proc_config_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF pr_is_service()
     OR pr_has_perm('can_manage_users')
     OR pr_has_perm('can_manage_company')
  THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل مسار الموافقات أو الأقسام يتطلّب صلاحية إدارية';
END $fn$;

DROP TRIGGER IF EXISTS trg_proc_users_guard ON proc_users;
CREATE TRIGGER trg_proc_users_guard BEFORE INSERT OR UPDATE OR DELETE ON proc_users
  FOR EACH ROW EXECUTE FUNCTION proc_users_guard();

DROP TRIGGER IF EXISTS trg_proc_apprules_guard ON proc_approval_rules;
CREATE TRIGGER trg_proc_apprules_guard BEFORE INSERT OR UPDATE OR DELETE ON proc_approval_rules
  FOR EACH ROW EXECUTE FUNCTION proc_config_guard();

DROP TRIGGER IF EXISTS trg_proc_depts_guard ON proc_departments;
CREATE TRIGGER trg_proc_depts_guard BEFORE INSERT OR UPDATE OR DELETE ON proc_departments
  FOR EACH ROW EXECUTE FUNCTION proc_config_guard();

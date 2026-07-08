-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 009 — فرض نطاق الرؤية على مستوى قاعدة البيانات (RLS) — H1
--  المواصفات (نظام لشركة كبيرة): كل مستخدم يرى فقط ما يخصّه حسب نطاق وظيفته:
--    • all    → كل الطلبات (المشتريات/المالية/المستودع/الجودة/المدير العام/الأدمن).
--    • sector → طلبات قطاعه (قسمه ضمن نفس sector) + طلباته.
--    • own    → طلباته فقط.
--  وفي كل الأحوال: يرى أي طلب هو **معتمِد فيه فعلاً** (شارك في سلسلته) حتى لو خارج نطاقه.
--
--  قبل هذه الهجرة كانت السياسة `auth_all USING(true)` تكشف كل الصفوف لأي مستخدم
--  مصادَق. الآن نستبدل سياسة SELECT على الجداول المعامَلاتية بسياسة مُنطاقة، ونُبقي
--  الكتابة عبر RPC (SECURITY DEFINER يتجاوز RLS) والمحارس (deny-by-default) كما هي.
--  جداول الإعداد (users/departments/jobs/doa/workflows/settings/suppliers) تبقى
--  عامة القراءة (يحتاجها التطبيق لعرض الأسماء/الأقسام) وكتابتها للأدمن بمحارسها.
--
--  الدوال SECURITY DEFINER كي تتجاوز استعلاماتها الداخلية RLS (تمنع التكرار
--  اللانهائي عند قراءة portal_approvals من داخل سياسة portal_approvals). idempotent.
--  شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex بعد 005–008.
-- ═══════════════════════════════════════════════════════════════════════════

-- نطاق المستخدم الحالي (من وظيفته؛ الأدمن دائماً all).
CREATE OR REPLACE FUNCTION portal_my_scope() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT CASE WHEN portal_is_admin() THEN 'all'
              ELSE coalesce((SELECT j.scope FROM portal_users u
                             LEFT JOIN portal_jobs j ON j.key = u.job_key
                             WHERE u.username = portal_username()), 'own') END;
$fn$;

-- قطاع المستخدم الحالي (sector قسمه).
CREATE OR REPLACE FUNCTION portal_my_sector() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT d.sector FROM portal_users u
    JOIN portal_departments d ON d.id = u.department_id
   WHERE u.username = portal_username();
$fn$;

-- هل يرى المستخدم الحالي طلباً بحقوله (id/requester/department)؟
CREATE OR REPLACE FUNCTION portal_can_see_request(p_id text, p_requester text, p_dept text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    portal_is_admin()
    OR portal_my_scope() = 'all'
    OR p_requester = portal_username()
    OR (portal_my_scope() = 'sector' AND EXISTS (
          SELECT 1 FROM portal_departments d
           WHERE d.id = p_dept AND d.sector IS NOT DISTINCT FROM portal_my_sector()))
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.approver = portal_username());
$fn$;

-- نفس الفحص عبر معرّف الطلب فقط (لجداول الأدلّة الفرعية).
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

-- ═══ استبدال سياسة رأس الطلب: SELECT مُنطاق + كتابة عامة (المحارس هي المدافع) ═══
-- سياسات لكل أمر لأن FOR ALL عامة تُلغي تقييد SELECT (السياسات المسموحة تُدمج بـOR).
-- الكتابة تبقى عامة كي تظل محارس deny-by-default تُطلق الاستثناء كما قبل — لا نُضعف.
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

-- ═══ جداول الأدلّة الفرعية: SELECT مُقيَّد برؤية الطلب الأب + كتابة عامة ═══
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

-- ═══ التدقيق: الأدمن يرى الكل؛ غيره يرى تدقيق الطلبات المرئية له فقط ═══
DROP POLICY IF EXISTS "audit_read" ON portal_audit;
CREATE POLICY "audit_read" ON portal_audit FOR SELECT TO authenticated
  USING (portal_is_admin() OR (request_id IS NOT NULL AND portal_can_see_request(request_id)));

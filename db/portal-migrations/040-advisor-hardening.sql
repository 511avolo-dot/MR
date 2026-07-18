-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 040 — تصليب من مدقّق Supabase الحيّ (أمان + أداء) — بعد 039
--  المشروع: mwbjoysuybgbrvfrprex (البوابة، نظام 3). idempotent — مدمجة في standalone.
--
--  من get_advisors(security) + get_advisors(performance) على القاعدة الحيّة:
--   (أ) search_path غير مثبَّت على 4 دوال (0011) — تُثبَّت على public.
--   (ب) دوال المُشغِّلات الأربعة الجديدة (031/032/033/037) قابلة لتنفيذ anon مباشرةً
--       (0028) — يُسحَب anon (تُستدعى عبر المُشغِّل فقط؛ authenticated يبقى كي لا تُكسر S7).
--   (ج) 14 مفتاحاً أجنبياً بلا فهرس تغطية (0001) — تُضاف فهارس (أداء JOIN/DELETE).
--  ملاحظات حميدة تُركت عمداً: rls_enabled_no_policy (جداول خادمية)، authenticated_*
--  (RPCs محميّة داخلياً)، rls_policy_always_true (الكتابة محروسة بالمُشغِّلات)،
--  auth_leaked_password (إعداد Auth بقرار المالك)، rls_auto_enable (event trigger من Supabase).
-- ════════════════════════════════════════════════════════════════════════════

-- (أ) تثبيت search_path
ALTER FUNCTION public.portal_audit_immutable() SET search_path = public;
ALTER FUNCTION public.portal_gen_token()       SET search_path = public;
ALTER FUNCTION public.portal_is_privileged()   SET search_path = public;
ALTER FUNCTION public.portal_set_due()         SET search_path = public;

-- (ب) سحب تنفيذ anon المباشر عن دوال المُشغِّلات (المنح افتراضيّ من Supabase)
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

-- (ج) فهارس تغطية للمفاتيح الأجنبية
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

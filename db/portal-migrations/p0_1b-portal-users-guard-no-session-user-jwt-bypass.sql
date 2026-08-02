-- ═══════════════════════════════════════════════════════════════════════════
--  P0-1b/P0-1c — least-privilege launch hardening
--  P0-1b closes the session_user bypass in portal_users_guard.
--  P0-1c closes final Security Advisor blockers discovered on isolated staging:
--    • replace SECURITY DEFINER portal_user_directory view with a safe RLS table
--    • replace broad authenticated direct-write policies (USING/WITH CHECK true)
--      with role-gated policies while preserving audited SECURITY DEFINER RPC flows.
--  Scope: isolated staging / release-candidate branch only. No production mutation here.
-- ═══════════════════════════════════════════════════════════════════════════

-- P0-1b: service privilege must never be inferred from session_user.
CREATE OR REPLACE FUNCTION portal_is_privileged()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $function$
  SELECT portal_is_service();
$function$;

REVOKE ALL ON FUNCTION portal_is_privileged() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_is_privileged() TO service_role;

-- P0-1c.1: replace SECURITY DEFINER directory view with a safe synchronized table.
-- The directory intentionally exposes only routing/display columns. Sensitive fields
-- such as email, role, permissions, job_key, manager_user, delegate_to and is_away
-- remain on portal_users and are governed by the self/admin RLS policy.
DROP VIEW IF EXISTS public.portal_user_directory;

CREATE TABLE IF NOT EXISTS public.portal_user_directory (
  username text PRIMARY KEY,
  display_name text,
  department_id text,
  active boolean NOT NULL DEFAULT true
);

ALTER TABLE public.portal_user_directory ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.portal_user_directory FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.portal_user_directory TO authenticated;
GRANT ALL ON public.portal_user_directory TO service_role;

DROP POLICY IF EXISTS portal_user_directory_read ON public.portal_user_directory;
CREATE POLICY portal_user_directory_read
  ON public.portal_user_directory
  FOR SELECT
  TO authenticated
  USING (true);

INSERT INTO public.portal_user_directory (username, display_name, department_id, active)
SELECT username, display_name, department_id, coalesce(active, true)
FROM public.portal_users
ON CONFLICT (username) DO UPDATE SET
  display_name = excluded.display_name,
  department_id = excluded.department_id,
  active = excluded.active;

DELETE FROM public.portal_user_directory d
WHERE NOT EXISTS (SELECT 1 FROM public.portal_users u WHERE u.username = d.username);

CREATE OR REPLACE FUNCTION public.portal_sync_user_directory()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.portal_user_directory WHERE username = OLD.username;
    RETURN OLD;
  END IF;

  INSERT INTO public.portal_user_directory (username, display_name, department_id, active)
  VALUES (NEW.username, NEW.display_name, NEW.department_id, coalesce(NEW.active, true))
  ON CONFLICT (username) DO UPDATE SET
    display_name = excluded.display_name,
    department_id = excluded.department_id,
    active = excluded.active;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.portal_sync_user_directory() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_sync_user_directory() TO service_role;

DROP TRIGGER IF EXISTS trg_portal_sync_user_directory ON public.portal_users;
CREATE TRIGGER trg_portal_sync_user_directory
AFTER INSERT OR UPDATE OF username, display_name, department_id, active OR DELETE
ON public.portal_users
FOR EACH ROW EXECUTE FUNCTION public.portal_sync_user_directory();

-- P0-1c.2: remove broad direct-write RLS policies on high-risk tables.
-- Normal users must use audited RPCs. Direct table writes are limited to admin/service
-- or a narrowly relevant privileged permission where the UI/API intentionally supports it.

-- Config/master tables: authenticated read, admin/service write.
DROP POLICY IF EXISTS auth_all ON public.portal_settings;
DROP POLICY IF EXISTS portal_settings_read ON public.portal_settings;
DROP POLICY IF EXISTS portal_settings_write ON public.portal_settings;
CREATE POLICY portal_settings_read ON public.portal_settings FOR SELECT TO authenticated USING (true);
CREATE POLICY portal_settings_write ON public.portal_settings FOR ALL TO authenticated
  USING (portal_is_admin() OR portal_is_service())
  WITH CHECK (portal_is_admin() OR portal_is_service());

DROP POLICY IF EXISTS auth_all ON public.portal_departments;
DROP POLICY IF EXISTS portal_departments_read ON public.portal_departments;
DROP POLICY IF EXISTS portal_departments_write ON public.portal_departments;
CREATE POLICY portal_departments_read ON public.portal_departments FOR SELECT TO authenticated USING (true);
CREATE POLICY portal_departments_write ON public.portal_departments FOR ALL TO authenticated
  USING (portal_is_admin() OR portal_is_service())
  WITH CHECK (portal_is_admin() OR portal_is_service());

DROP POLICY IF EXISTS auth_all ON public.portal_jobs;
DROP POLICY IF EXISTS portal_jobs_read ON public.portal_jobs;
DROP POLICY IF EXISTS portal_jobs_write ON public.portal_jobs;
CREATE POLICY portal_jobs_read ON public.portal_jobs FOR SELECT TO authenticated USING (true);
CREATE POLICY portal_jobs_write ON public.portal_jobs FOR ALL TO authenticated
  USING (portal_is_admin() OR portal_is_service())
  WITH CHECK (portal_is_admin() OR portal_is_service());

DROP POLICY IF EXISTS auth_all ON public.portal_workflows;
DROP POLICY IF EXISTS portal_workflows_read ON public.portal_workflows;
DROP POLICY IF EXISTS portal_workflows_write ON public.portal_workflows;
CREATE POLICY portal_workflows_read ON public.portal_workflows FOR SELECT TO authenticated USING (true);
CREATE POLICY portal_workflows_write ON public.portal_workflows FOR ALL TO authenticated
  USING (portal_is_admin() OR portal_is_service())
  WITH CHECK (portal_is_admin() OR portal_is_service());

DROP POLICY IF EXISTS auth_all ON public.portal_doa;
DROP POLICY IF EXISTS portal_doa_read ON public.portal_doa;
DROP POLICY IF EXISTS portal_doa_write ON public.portal_doa;
CREATE POLICY portal_doa_read ON public.portal_doa FOR SELECT TO authenticated USING (true);
CREATE POLICY portal_doa_write ON public.portal_doa FOR ALL TO authenticated
  USING (portal_is_admin() OR portal_is_service())
  WITH CHECK (portal_is_admin() OR portal_is_service());

-- User master: self/admin read policy remains; direct writes are admin/service only.
DROP POLICY IF EXISTS portal_users_wr_ins ON public.portal_users;
DROP POLICY IF EXISTS portal_users_wr_upd ON public.portal_users;
DROP POLICY IF EXISTS portal_users_wr_del ON public.portal_users;
DROP POLICY IF EXISTS portal_users_write ON public.portal_users;
CREATE POLICY portal_users_write ON public.portal_users FOR ALL TO authenticated
  USING (portal_is_admin() OR portal_is_service())
  WITH CHECK (portal_is_admin() OR portal_is_service());

-- Supplier master: existing restricted read policy remains; direct write is procurement/admin/service.
DROP POLICY IF EXISTS supp_ins ON public.portal_suppliers;
DROP POLICY IF EXISTS supp_upd ON public.portal_suppliers;
DROP POLICY IF EXISTS supp_del ON public.portal_suppliers;
DROP POLICY IF EXISTS portal_suppliers_write ON public.portal_suppliers;
CREATE POLICY portal_suppliers_write ON public.portal_suppliers FOR ALL TO authenticated
  USING (portal_has_perm('can_manage_procurement') OR portal_is_admin() OR portal_is_service())
  WITH CHECK (portal_has_perm('can_manage_procurement') OR portal_is_admin() OR portal_is_service());

-- Request/lifecycle tables: existing scoped SELECT policies remain; direct writes are admin/service only.
DO $rls$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'portal_requests','portal_request_items','portal_approvals','portal_offers',
    'portal_award','portal_award_approvals','portal_po_approvals',
    'portal_payments','portal_receipts'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS wr_ins ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS wr_upd ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS wr_del ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS portal_direct_write ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY portal_direct_write ON public.%I FOR ALL TO authenticated USING (portal_is_admin() OR portal_is_service()) WITH CHECK (portal_is_admin() OR portal_is_service())',
      t
    );
  END LOOP;
END $rls$;

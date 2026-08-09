-- P0-1v -- forward-only ACL repair for P0-1s functions already applied on shared staging.
-- Repository source only until the owner explicitly authorizes a staging apply.
-- This is not migration 063 and does not rewrite the applied P0-1s migration.
BEGIN;

DO $guard$
BEGIN
  IF to_regprocedure('public.portal_apply_perm_overrides(jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.portal_perm_overrides_delta(jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.portal_set_user_permission(text,text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'P0-1v requires P0-1s functions to exist';
  END IF;
END $guard$;

-- Supabase staging has explicit default EXECUTE grants for API roles. Revoking PUBLIC alone
-- does not remove those role-specific grants. Helpers are internal; the mutation RPC is
-- authenticated/service-role only and still enforces its server-side admin check.
REVOKE ALL ON FUNCTION portal_apply_perm_overrides(jsonb,jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION portal_perm_overrides_delta(jsonb,jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION portal_set_user_permission(text,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_set_user_permission(text,text,boolean) TO authenticated, service_role;

COMMIT;

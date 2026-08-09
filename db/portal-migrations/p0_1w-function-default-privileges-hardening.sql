-- P0-1w -- deny-by-default EXECUTE ACL for future application functions.
-- Forward-only staging hardening; this is not migration 063.
BEGIN;

-- Existing functions keep their reviewed ACLs. Future functions owned by the
-- application migration role must opt API roles in explicitly after creation.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;

COMMIT;

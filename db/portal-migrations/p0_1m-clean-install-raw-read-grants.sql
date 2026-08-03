-- P0-1m -- clean-install grants for the P0-1l RLS boundary
--
-- Supabase-managed environments already had these read grants, but the
-- deterministic clean baseline did not.  Granting SELECT makes the new RLS
-- policies authoritative on a fresh install and preserves privileged portal
-- workflows; it does not bypass or weaken any row policy.
BEGIN;

GRANT SELECT ON TABLE
  public.portal_request_items,
  public.portal_approvals,
  public.portal_receipts,
  public.portal_award_approvals,
  public.portal_po_approvals,
  public.portal_audit,
  public.portal_request_documents
TO authenticated;

COMMIT;

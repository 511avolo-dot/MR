-- P0-1j -- remediation for the fresh exact-head review of PR #74.
--
-- Staging-only release candidate.  Do not apply to Production and do not
-- rename this file to migration 063.  The rollback for this migration is
-- deliberately fail-closed: restore the previous database snapshot instead
-- of dropping evidence, verification, or quarantine columns in place.

BEGIN;

-- 1. Quote access needs both a request-scope decision and a quote capability.
CREATE OR REPLACE FUNCTION public.portal_can_view_quotes(p_request_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
  SELECT public.portal_is_service()
    OR (
      public.portal_can_see_request(p_request_id)
      AND (
        public.portal_is_admin()
        OR public.portal_effective_perm('can_view_quotes')
        OR public.portal_effective_perm('can_manage_procurement')
        OR public.portal_effective_perm('can_issue_po')
        OR public.portal_effective_perm('can_approve_award')
      )
    );
$function$;

REVOKE ALL ON FUNCTION public.portal_can_view_quotes(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_can_view_quotes(text)
  TO authenticated, service_role;

-- 2. Preserve the historical accountant role while making the dedicated
-- direct-expense capability explicit.  This guarded backfill is idempotent.
SELECT set_config('app.portal_transition', '1', true);
UPDATE public.portal_jobs
   SET permissions = coalesce(permissions, '{}'::jsonb)
                     || '{"can_create_direct_expense":true}'::jsonb
 WHERE key = 'fin_accountant'
   AND NOT coalesce((permissions->>'can_create_direct_expense')::boolean, false);
SELECT set_config('app.portal_transition', '0', true);

-- 3. A requester must not get raw bank or payment-document metadata from base
-- tables.  Safe SECURITY DEFINER contracts retain operational progress data.
CREATE OR REPLACE FUNCTION public.portal_redact_expense_details(p_details jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO public
AS $function$
  SELECT jsonb_strip_nulls(
    (coalesce(p_details, '{}'::jsonb) - ARRAY[
      'iban', 'account_name', 'bank_name', 'beneficiary_iban',
      'proof_key', 'proof_checksum', 'proof_mime_type', 'proof_size_bytes'
    ]::text[])
    || jsonb_build_object(
      'iban_masked', CASE
        WHEN length(regexp_replace(coalesce(p_details->>'iban', ''), '[^A-Za-z0-9]', '', 'g')) >= 6
        THEN left(regexp_replace(p_details->>'iban', '[^A-Za-z0-9]', '', 'g'), 2)
             || repeat('*', greatest(length(regexp_replace(p_details->>'iban', '[^A-Za-z0-9]', '', 'g')) - 6, 4))
             || right(regexp_replace(p_details->>'iban', '[^A-Za-z0-9]', '', 'g'), 4)
        ELSE NULL
      END,
      'manual_iban_exception', coalesce(p_details->>'iban_source', '') = 'manual'
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.portal_redact_payment_details(p_details jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO public
AS $function$
  SELECT jsonb_strip_nulls(
    coalesce(p_details, '{}'::jsonb) - ARRAY[
      'iban', 'account_name', 'bank_name', 'beneficiary_iban',
      'proof_key', 'proof_checksum', 'proof_mime_type', 'proof_size_bytes',
      'storage_key', 'checksum', 'r2_key'
    ]::text[]
  );
$function$;

REVOKE ALL ON FUNCTION public.portal_redact_expense_details(jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.portal_redact_payment_details(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_redact_expense_details(jsonb),
  public.portal_redact_payment_details(jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.portal_safe_visible_direct_expenses()
RETURNS SETOF public.portal_requests
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
BEGIN
  IF public.portal_username() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  RETURN QUERY
  SELECT (jsonb_populate_record(
    NULL::public.portal_requests,
    to_jsonb(r) || jsonb_build_object(
      'expense_details', public.portal_redact_expense_details(r.expense_details)
    )
  )).* 
  FROM public.portal_requests r
  WHERE r.req_type = 'direct_expense'
    AND public.portal_can_see_request(r.id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.portal_safe_visible_payments()
RETURNS SETOF public.portal_payments
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
BEGIN
  IF public.portal_username() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  RETURN QUERY
  SELECT (jsonb_populate_record(
    NULL::public.portal_payments,
    to_jsonb(p) || jsonb_build_object(
      'details', public.portal_redact_payment_details(p.details)
    )
  )).*
  FROM public.portal_payments p
  WHERE public.portal_can_see_request(p.request_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_safe_visible_direct_expenses()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.portal_safe_visible_payments()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_safe_visible_direct_expenses(),
  public.portal_safe_visible_payments() TO authenticated;

COMMENT ON FUNCTION public.portal_safe_visible_direct_expenses() IS
  'JWT-scoped direct-expense feed with raw bank and proof metadata removed.';
COMMENT ON FUNCTION public.portal_safe_visible_payments() IS
  'JWT-scoped payment-progress feed with raw bank and document metadata removed.';

DROP POLICY IF EXISTS see_scoped ON public.portal_requests;
DROP POLICY IF EXISTS portal_requests_read ON public.portal_requests;
CREATE POLICY see_scoped ON public.portal_requests
  FOR SELECT TO authenticated
  USING (
    public.portal_can_see_request(id)
    AND (
      coalesce(req_type, 'purchase') <> 'direct_expense'
      OR public.portal_is_admin()
      OR public.portal_effective_perm('can_see_finance')
      OR public.portal_effective_perm('can_manage_procurement')
      OR public.portal_effective_perm('can_disburse')
    )
  );

DROP POLICY IF EXISTS see_by_request ON public.portal_payments;
DROP POLICY IF EXISTS portal_payments_read ON public.portal_payments;
CREATE POLICY see_by_request ON public.portal_payments
  FOR SELECT TO authenticated
  USING (
    public.portal_can_see_request(request_id)
    AND (
      public.portal_is_admin()
      OR public.portal_effective_perm('can_see_finance')
      OR public.portal_effective_perm('can_manage_procurement')
      OR public.portal_effective_perm('can_disburse')
    )
  );

DROP POLICY IF EXISTS portal_invoices_read ON public.portal_supplier_invoices;
CREATE POLICY portal_invoices_read ON public.portal_supplier_invoices
  FOR SELECT TO authenticated
  USING (
    public.portal_can_see_request(request_id)
    AND (
      public.portal_is_admin()
      OR public.portal_effective_perm('can_see_finance')
      OR public.portal_effective_perm('can_manage_procurement')
    )
  );

DROP POLICY IF EXISTS portal_returns_read ON public.portal_returns;
CREATE POLICY portal_returns_read ON public.portal_returns
  FOR SELECT TO authenticated
  USING (
    public.portal_can_see_request(request_id)
    AND (
      public.portal_is_admin()
      OR public.portal_effective_perm('can_see_finance')
      OR public.portal_effective_perm('can_manage_procurement')
      OR public.portal_effective_perm('can_verify_stock')
    )
  );

-- 4. Normalize verification state.  Rows without a matching consumed receipt
-- are quarantined, retained for audit, and excluded from evidence gates.
ALTER TABLE public.portal_request_documents
  ADD COLUMN IF NOT EXISTS verification_status text NOT NULL DEFAULT 'unverified',
  ADD COLUMN IF NOT EXISTS verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS verification_receipt_key text;

DO $constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.portal_request_documents'::regclass
       AND conname = 'portal_reqdoc_verification_status_check'
  ) THEN
    ALTER TABLE public.portal_request_documents
      ADD CONSTRAINT portal_reqdoc_verification_status_check
      CHECK (verification_status IN ('unverified', 'verified', 'quarantined'));
  END IF;
END $constraint$;

SELECT set_config('app.portal_transition', '1', true);
UPDATE public.portal_request_documents d
   SET verification_status = 'verified',
       verified_at = coalesce(r.consumed_at, r.created_at),
       verification_receipt_key = r.storage_key
  FROM public.portal_upload_receipts r
 WHERE d.storage_key = r.storage_key
   AND r.consumed_at IS NOT NULL
   AND r.request_id = d.request_id
   AND r.uploaded_by = d.uploaded_by
   AND r.mime_type = d.mime_type
   AND r.size_bytes = d.size_bytes
   AND r.checksum = d.checksum;

UPDATE public.portal_request_documents
   SET verification_status = 'quarantined',
       verified_at = NULL,
       verification_receipt_key = NULL
 WHERE verification_status <> 'verified';
SELECT set_config('app.portal_transition', '0', true);

CREATE OR REPLACE FUNCTION public.portal_request_document_receipt_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_receipt public.portal_upload_receipts%ROWTYPE;
  v_allowed text[];
BEGIN
  IF NEW.payment_id IS NULL THEN
    v_allowed := ARRAY['reqdoc']::text[];
  ELSE
    v_allowed := ARRAY['inst','inv','pay','disb']::text[];
  END IF;

  SELECT * INTO v_receipt
  FROM public.portal_validate_upload_receipt(
    NEW.storage_key, NEW.request_id, NEW.uploaded_by, v_allowed, true
  );

  NEW.mime_type := v_receipt.mime_type;
  NEW.size_bytes := v_receipt.size_bytes;
  NEW.checksum := v_receipt.checksum;
  NEW.uploaded_by := v_receipt.uploaded_by;
  NEW.verification_status := 'verified';
  NEW.verified_at := now();
  NEW.verification_receipt_key := v_receipt.storage_key;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_request_document_receipt_guard()
  FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS portal_reqdoc_read ON public.portal_request_documents;
CREATE POLICY portal_reqdoc_read ON public.portal_request_documents
  FOR SELECT TO authenticated
  USING (
    public.portal_can_see_request(request_id)
    AND (
      payment_id IS NULL
      OR public.portal_is_admin()
      OR public.portal_effective_perm('can_see_finance')
      OR public.portal_effective_perm('can_manage_procurement')
      OR public.portal_effective_perm('can_disburse')
    )
  );

CREATE OR REPLACE FUNCTION public.portal_direct_expense_verified_evidence_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
BEGIN
  IF NEW.req_type = 'direct_expense'
     AND NEW.status = 'in_review'
     AND OLD.status IS DISTINCT FROM 'in_review'
     AND public.portal_setting_num('expense_docs_required', 1) >= 1
     AND NOT EXISTS (
       SELECT 1
       FROM public.portal_request_documents d
       WHERE d.request_id = NEW.id
         AND d.payment_id IS NULL
         AND d.active
         AND d.verification_status = 'verified'
     ) THEN
    RAISE EXCEPTION 'A verified supporting document is required';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_direct_expense_verified_evidence_guard()
  FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_portal_requests_05_verified_evidence
  ON public.portal_requests;
CREATE TRIGGER trg_portal_requests_05_verified_evidence
BEFORE UPDATE OF status ON public.portal_requests
FOR EACH ROW EXECUTE FUNCTION public.portal_direct_expense_verified_evidence_guard();

-- 5. Preserve legacy payment rows, but quarantine transitions until a verified
-- normalized payment-request document is attached.
ALTER TABLE public.portal_payments
  ADD COLUMN IF NOT EXISTS legacy_evidence_quarantined boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS legacy_evidence_reason text,
  ADD COLUMN IF NOT EXISTS legacy_evidence_quarantined_at timestamptz;

-- The existing payment guard correctly rejects direct writes.  Limit the
-- migration-only bypass to this DO statement's transaction; it cannot leak to
-- subsequent application statements even if the UPDATE raises.
DO $legacy_payment_backfill$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE public.portal_payments p
     SET legacy_evidence_quarantined = true,
         legacy_evidence_reason = 'P0-1j: no verified normalized payment_request document',
         legacy_evidence_quarantined_at = now()
   WHERE p.status IN ('pending_pay', 'approved_pay')
     AND NOT EXISTS (
       SELECT 1
         FROM public.portal_request_documents d
        WHERE d.payment_id = p.id
          AND d.request_id = p.request_id
          AND d.active
          AND d.source_stage = 'payment_request'
          AND d.verification_status = 'verified'
     );
END;
$legacy_payment_backfill$;

CREATE OR REPLACE FUNCTION public.portal_payment_legacy_quarantine_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_has_verified boolean;
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.legacy_evidence_quarantined
     AND NEW.status IS DISTINCT FROM OLD.status THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.portal_request_documents d
      WHERE d.payment_id = OLD.id
        AND d.request_id = OLD.request_id
        AND d.active
        AND d.source_stage = 'payment_request'
        AND d.verification_status = 'verified'
    ) INTO v_has_verified;

    IF NOT v_has_verified THEN
      RAISE EXCEPTION 'Legacy payment is quarantined until verified payment-request evidence is attached';
    END IF;

    NEW.legacy_evidence_quarantined := false;
    NEW.legacy_evidence_reason := NULL;
    NEW.legacy_evidence_quarantined_at := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_payment_legacy_quarantine_guard()
  FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_portal_payments_05_legacy_quarantine
  ON public.portal_payments;
CREATE TRIGGER trg_portal_payments_05_legacy_quarantine
BEFORE UPDATE OF status ON public.portal_payments
FOR EACH ROW EXECUTE FUNCTION public.portal_payment_legacy_quarantine_guard();

CREATE INDEX IF NOT EXISTS idx_portal_reqdoc_verification
  ON public.portal_request_documents(request_id, verification_status, active);
CREATE INDEX IF NOT EXISTS idx_portal_payments_legacy_quarantine
  ON public.portal_payments(legacy_evidence_quarantined)
  WHERE legacy_evidence_quarantined;
CREATE INDEX IF NOT EXISTS idx_portal_upload_receipts_request
  ON public.portal_upload_receipts(request_id);

COMMENT ON COLUMN public.portal_request_documents.verification_status IS
  'verified only after an exact, consumed server upload receipt; historical unmatched rows are quarantined.';
COMMENT ON COLUMN public.portal_payments.legacy_evidence_quarantined IS
  'Blocks status transitions for legacy pending/approved payments lacking verified normalized request evidence.';

COMMIT;

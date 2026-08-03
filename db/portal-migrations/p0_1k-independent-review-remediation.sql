-- P0-1k -- independent exact-head review remediation
-- * status-only requester payment feed
-- * distinct, verified payment-request evidence for direct expenses
-- * fail-closed reconciliation of in-flight approvals
-- * controlled recovery of quarantined legacy payments
BEGIN;

-- Requesters need progress, not the financial payment row.  A composite return
-- type is retained for frontend compatibility, but every field except identity
-- and status is deliberately NULL (including amount, kind, actors and dates).
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
    jsonb_build_object(
      'id', p.id,
      'request_id', p.request_id,
      'status', p.status,
      'details', '{}'::jsonb
    )
  )).*
  FROM public.portal_payments p
  WHERE public.portal_can_see_request(p.request_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_safe_visible_payments()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_safe_visible_payments()
  TO authenticated;

COMMENT ON FUNCTION public.portal_safe_visible_payments() IS
  'JWT-scoped status-only payment progress feed; financial values, kinds, custody, actors, timestamps and evidence metadata are NULL.';

-- Every new, receipt-backed request document on a direct expense is explicitly
-- classified as payment-request evidence.  This server-side trigger prevents a
-- client from weakening or omitting the classification.
CREATE OR REPLACE FUNCTION public.portal_direct_expense_document_stage()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
BEGIN
  IF NEW.payment_id IS NULL
     AND NEW.verification_status = 'verified'
     AND EXISTS (
       SELECT 1 FROM public.portal_requests r
       WHERE r.id = NEW.request_id AND r.req_type = 'direct_expense'
     ) THEN
    NEW.source_stage := 'payment_request';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_direct_expense_document_stage()
  FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_portal_reqdoc_z_direct_stage
  ON public.portal_request_documents;
CREATE TRIGGER trg_portal_reqdoc_z_direct_stage
BEFORE INSERT ON public.portal_request_documents
FOR EACH ROW EXECUTE FUNCTION public.portal_direct_expense_document_stage();

-- Receipt reconciliation in P0-1j established which historical rows are
-- actually verified.  Only those rows are eligible for the explicit stage.
SELECT set_config('app.portal_transition', '1', true);
UPDATE public.portal_request_documents d
   SET source_stage = 'payment_request'
  FROM public.portal_requests r
 WHERE r.id = d.request_id
   AND r.req_type = 'direct_expense'
   AND d.payment_id IS NULL
   AND d.active
   AND d.verification_status = 'verified'
   AND d.source_stage IS DISTINCT FROM 'payment_request';
SELECT set_config('app.portal_transition', '0', true);

-- Submission itself now requires the distinct verified evidence class.
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
         AND d.source_stage = 'payment_request'
         AND d.verification_status = 'verified'
     ) THEN
    RAISE EXCEPTION 'A distinct verified payment-request document is required';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_direct_expense_verified_evidence_guard()
  FROM PUBLIC, anon, authenticated;

-- Existing in-flight chains that no longer have admissible evidence must not
-- remain runnable.  Preserve history, return the request, and require the owner
-- to upload verified evidence and resubmit through the normal RPC.
DO $reconcile_in_flight$
DECLARE
  v_req record;
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);
  FOR v_req IN
    SELECT r.id
    FROM public.portal_requests r
    WHERE r.req_type = 'direct_expense'
      AND r.status = 'in_review'
      AND NOT EXISTS (
        SELECT 1
        FROM public.portal_request_documents d
        WHERE d.request_id = r.id
          AND d.payment_id IS NULL
          AND d.active
          AND d.source_stage = 'payment_request'
          AND d.verification_status = 'verified'
      )
    FOR UPDATE
  LOOP
    UPDATE public.portal_approvals
       SET decision = 'returned',
           comment = 'P0-1k: verified payment-request evidence required',
           acted_at = now(),
           channel = 'portal'
     WHERE request_id = v_req.id
       AND cycle = 'disbursement'
       AND decision = 'pending';

    UPDATE public.portal_requests
       SET status = 'returned',
           phase = 'disbursement',
           current_seq = 0,
           updated_at = now(),
           updated_by = 'system:p0_1k'
     WHERE id = v_req.id;

    PERFORM public.portal_audit_write(
      v_req.id,
      'expense_evidence_reconciliation_returned',
      'system:p0_1k',
      'portal',
      jsonb_build_object('reason', 'missing verified payment_request evidence')
    );
  END LOOP;
  PERFORM set_config('app.portal_transition', '0', true);
END;
$reconcile_in_flight$;

-- A direct-expense payment insert must consume a request-scoped, verified,
-- unlinked payment-request document.  The row is locked to serialize concurrent
-- attempts and its trusted metadata is copied into payment details.
CREATE OR REPLACE FUNCTION public.portal_direct_payment_evidence_before()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_req public.portal_requests%ROWTYPE;
  v_doc public.portal_request_documents%ROWTYPE;
BEGIN
  SELECT * INTO v_req
  FROM public.portal_requests
  WHERE id = NEW.request_id;

  IF NOT FOUND OR v_req.req_type <> 'direct_expense' THEN
    RETURN NEW;
  END IF;
  IF current_setting('app.portal_transition', true) IS DISTINCT FROM '1' THEN
    RAISE EXCEPTION 'Direct payment creation is restricted to the internal approval transition';
  END IF;
  IF v_req.status <> 'payment_pending' OR v_req.phase <> 'payment' THEN
    RAISE EXCEPTION 'Direct expense has not completed approval';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.portal_approvals
    WHERE request_id = NEW.request_id
      AND cycle = 'disbursement'
      AND decision <> 'approved'
  ) THEN
    RAISE EXCEPTION 'Direct-expense approval chain is incomplete';
  END IF;

  SELECT d.* INTO v_doc
  FROM public.portal_request_documents d
  WHERE d.request_id = NEW.request_id
    AND d.payment_id IS NULL
    AND d.active
    AND d.source_stage = 'payment_request'
    AND d.verification_status = 'verified'
  ORDER BY d.uploaded_at DESC, d.id DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'A distinct verified payment-request document is required before creating the direct payment';
  END IF;

  NEW.details := coalesce(NEW.details, '{}'::jsonb) || jsonb_build_object(
    'proof_key', v_doc.storage_key,
    'proof_kind', 'reqdoc',
    'proof_mime_type', v_doc.mime_type,
    'proof_size_bytes', v_doc.size_bytes,
    'proof_checksum', v_doc.checksum
  );
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_direct_payment_evidence_before()
  FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_portal_payments_07_direct_evidence
  ON public.portal_payments;
CREATE TRIGGER trg_portal_payments_07_direct_evidence
BEFORE INSERT ON public.portal_payments
FOR EACH ROW EXECUTE FUNCTION public.portal_direct_payment_evidence_before();

-- Link the exact locked evidence row to the newly-created payment.  Once linked,
-- requester RLS no longer exposes its metadata; finance retains the audit trail.
CREATE OR REPLACE FUNCTION public.portal_direct_payment_evidence_after()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_key text;
  v_doc_id bigint;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.portal_requests r
    WHERE r.id = NEW.request_id AND r.req_type = 'direct_expense'
  ) THEN
    RETURN NEW;
  END IF;

  v_key := nullif(NEW.details->>'proof_key', '');
  SELECT d.id INTO v_doc_id
  FROM public.portal_request_documents d
  WHERE d.request_id = NEW.request_id
    AND d.storage_key = v_key
    AND d.payment_id IS NULL
    AND d.active
    AND d.source_stage = 'payment_request'
    AND d.verification_status = 'verified'
  FOR UPDATE;

  IF v_doc_id IS NULL THEN
    RAISE EXCEPTION 'The verified direct-payment evidence could not be linked';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE public.portal_request_documents
     SET payment_id = NEW.id
   WHERE id = v_doc_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM public.portal_audit_write(
    NEW.request_id,
    'payment_evidence_attached',
    coalesce(NEW.requested_by, 'system'),
    'portal',
    jsonb_build_object('payment_id', NEW.id, 'document_id', v_doc_id, 'stage', 'payment_request')
  );
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_direct_payment_evidence_after()
  FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_portal_payments_95_direct_evidence_link
  ON public.portal_payments;
CREATE TRIGGER trg_portal_payments_95_direct_evidence_link
AFTER INSERT ON public.portal_payments
FOR EACH ROW EXECUTE FUNCTION public.portal_direct_payment_evidence_after();

-- Finance/admin recovery for P0-1j legacy quarantines.  It accepts only a fresh
-- server upload receipt; the existing document receipt guard consumes and
-- verifies it before the quarantine can be cleared.
CREATE OR REPLACE FUNCTION public.portal_recover_legacy_payment_evidence(
  p_payment_id bigint,
  p_storage_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_me text := public.portal_username();
  v_pay public.portal_payments%ROWTYPE;
  v_doc_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (
    public.portal_is_admin() OR public.portal_effective_perm('can_disburse')
  ) THEN
    RAISE EXCEPTION 'Recovery requires an effective disbursement role';
  END IF;

  SELECT * INTO v_pay
  FROM public.portal_payments
  WHERE id = p_payment_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF NOT public.portal_can_see_request(v_pay.request_id) THEN
    RAISE EXCEPTION 'Payment is outside your request scope';
  END IF;
  IF NOT v_pay.legacy_evidence_quarantined THEN
    RAISE EXCEPTION 'Payment is not quarantined';
  END IF;
  IF v_pay.status NOT IN ('pending_pay', 'approved_pay') THEN
    RAISE EXCEPTION 'Payment status is not recoverable';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO public.portal_request_documents(
    request_id, payment_id, document_type, title, description,
    storage_key, mime_type, uploaded_by, source_stage
  ) VALUES (
    v_pay.request_id, v_pay.id, 'memo', 'Recovered legacy payment evidence',
    'Receipt-backed evidence attached through the controlled P0-1k recovery path',
    p_storage_key, 'application/pdf', v_me, 'payment_request'
  ) RETURNING id INTO v_doc_id;

  UPDATE public.portal_payments
     SET legacy_evidence_quarantined = false,
         legacy_evidence_reason = NULL,
         legacy_evidence_quarantined_at = NULL
   WHERE id = v_pay.id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM public.portal_audit_write(
    v_pay.request_id,
    'legacy_payment_evidence_recovered',
    v_me,
    'portal',
    jsonb_build_object('payment_id', v_pay.id, 'document_id', v_doc_id)
  );
  RETURN jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'document_id', v_doc_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_recover_legacy_payment_evidence(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_recover_legacy_payment_evidence(bigint, text)
  TO authenticated;

CREATE INDEX IF NOT EXISTS idx_portal_reqdoc_payment_evidence
  ON public.portal_request_documents(
    request_id, payment_id, source_stage, verification_status, active
  );

COMMIT;

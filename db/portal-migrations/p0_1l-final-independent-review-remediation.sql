-- P0-1l -- final independent exact-head review remediation
-- * requester purchase reads use the safe dossier instead of raw financial rows
-- * direct-expense evidence cannot be disabled by a rollback setting
-- * raw child/audit/document policies follow the same privileged-read boundary
BEGIN;

CREATE OR REPLACE FUNCTION public.portal_can_read_raw_request(p_request_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_me text := public.portal_username();
BEGIN
  IF v_me IS NULL OR NOT public.portal_can_see_request(p_request_id) THEN
    RETURN false;
  END IF;

  RETURN public.portal_is_admin()
    OR public.portal_effective_perm('can_approve_stage')
    OR public.portal_effective_perm('can_approve_finance')
    OR public.portal_effective_perm('can_manage_procurement')
    OR public.portal_effective_perm('can_approve_award')
    OR public.portal_effective_perm('can_approve_committee')
    OR public.portal_effective_perm('can_issue_po')
    OR public.portal_effective_perm('can_see_finance')
    OR public.portal_effective_perm('can_disburse')
    OR public.portal_effective_perm('can_approve_disbursement')
    OR public.portal_effective_perm('can_verify_stock')
    OR EXISTS (
      SELECT 1 FROM public.portal_approvals a
      WHERE a.request_id = p_request_id AND a.approver = v_me
    )
    OR EXISTS (
      SELECT 1 FROM public.portal_award_approvals a
      WHERE a.request_id = p_request_id AND a.approver = v_me
    )
    OR EXISTS (
      SELECT 1 FROM public.portal_po_approvals a
      WHERE a.request_id = p_request_id AND a.approver = v_me
    )
    OR EXISTS (
      SELECT 1
      FROM public.portal_requests r
      JOIN public.portal_departments d ON d.id = r.department_id
      WHERE r.id = p_request_id AND d.manager_user = v_me
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_can_read_raw_request(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_can_read_raw_request(text)
  TO authenticated, service_role;

DROP POLICY IF EXISTS see_scoped ON public.portal_requests;
DROP POLICY IF EXISTS portal_requests_read ON public.portal_requests;
CREATE POLICY see_scoped ON public.portal_requests
  FOR SELECT TO authenticated
  USING (public.portal_can_read_raw_request(id));

DO $raw_child_policies$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'portal_request_items', 'portal_approvals', 'portal_receipts',
    'portal_award_approvals', 'portal_po_approvals'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS see_by_request ON public.%I', v_table);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_table || '_read', v_table);
    EXECUTE format(
      'CREATE POLICY see_by_request ON public.%I FOR SELECT TO authenticated USING (public.portal_can_read_raw_request(request_id))',
      v_table
    );
  END LOOP;
END;
$raw_child_policies$;

DROP POLICY IF EXISTS audit_read ON public.portal_audit;
CREATE POLICY audit_read ON public.portal_audit
  FOR SELECT TO authenticated
  USING (
    public.portal_is_admin()
    OR (request_id IS NOT NULL AND public.portal_can_read_raw_request(request_id))
  );

CREATE OR REPLACE FUNCTION public.portal_can_read_raw_document(
  p_request_id text,
  p_payment_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_me text := public.portal_username();
  v_type text;
  v_requester text;
BEGIN
  IF public.portal_can_read_raw_request(p_request_id) THEN
    RETURN true;
  END IF;
  IF v_me IS NULL OR p_payment_id IS NOT NULL THEN
    RETURN false;
  END IF;

  SELECT req_type, requester INTO v_type, v_requester
  FROM public.portal_requests
  WHERE id = p_request_id;
  RETURN v_type = 'direct_expense' AND v_requester = v_me;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_can_read_raw_document(text, bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_can_read_raw_document(text, bigint)
  TO authenticated, service_role;

DROP POLICY IF EXISTS portal_reqdoc_read ON public.portal_request_documents;
CREATE POLICY portal_reqdoc_read ON public.portal_request_documents
  FOR SELECT TO authenticated
  USING (public.portal_can_read_raw_document(request_id, payment_id));

-- Document evidence is a fail-closed integrity requirement.  The historical
-- expense_docs_required=0 rollback state is no longer supported because it can
-- strand an approved request at payment creation or bypass the evidence gate.
SELECT set_config('app.portal_transition', '1', true);
UPDATE public.portal_settings
   SET value = jsonb_set(coalesce(value, '{}'::jsonb), '{expense_docs_required}', '1'::jsonb, true)
 WHERE key = 'portal_settings';
SELECT set_config('app.portal_transition', '0', true);

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

CREATE OR REPLACE FUNCTION public.portal_create_expense(
  p_beneficiary text,
  p_amount numeric,
  p_kind text,
  p_purpose text,
  p_department_id text,
  p_need_by date,
  p_details jsonb DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_beneficiary_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.portal_create_expense_draft(
    p_beneficiary, p_amount, p_kind, p_purpose, p_department_id,
    p_need_by, p_details, p_note, p_beneficiary_id,
    p_details->>'iban_manual_reason'
  );
  RETURN v_result || jsonb_build_object('needs_documents', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_create_expense(
  text,numeric,text,text,text,date,jsonb,text,bigint
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_create_expense(
  text,numeric,text,text,text,date,jsonb,text,bigint
) TO authenticated;

COMMIT;

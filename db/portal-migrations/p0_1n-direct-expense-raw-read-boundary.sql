-- P0-1n -- preserve the finance-only raw boundary for direct expenses
--
-- P0-1l intentionally broadened raw purchase access for operational roles,
-- but direct-expense rows contain bank/account data and must retain the
-- narrower P0-1j finance/procurement/disbursement boundary.
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
  v_req_type text;
BEGIN
  IF v_me IS NULL OR NOT public.portal_can_see_request(p_request_id) THEN
    RETURN false;
  END IF;

  SELECT coalesce(r.req_type, 'purchase')
    INTO v_req_type
  FROM public.portal_requests r
  WHERE r.id = p_request_id;

  IF v_req_type = 'direct_expense' THEN
    RETURN public.portal_is_admin()
      OR public.portal_effective_perm('can_see_finance')
      OR public.portal_effective_perm('can_approve_finance')
      OR public.portal_effective_perm('can_manage_procurement')
      OR public.portal_effective_perm('can_disburse')
      OR public.portal_effective_perm('can_approve_disbursement');
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

COMMIT;

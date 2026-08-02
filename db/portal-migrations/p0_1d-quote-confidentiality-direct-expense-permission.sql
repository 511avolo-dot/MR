-- ═══════════════════════════════════════════════════════════════════════════
--  P0-1d — quote confidentiality + direct-expense permission split
--
--  Owner blocker from staging/preview review:
--    • requesters/employees must not see confidential supplier quotations,
--      comparison totals, offer PDFs, or award-pricing data merely because they
--      can see their own request.
--    • direct expense is an operational module/capability that must be grantable
--      and removable per user/job; it must not ride on generic can_create.
--
--  Scope: isolated staging / release-candidate branch only. No production mutation.
-- ═══════════════════════════════════════════════════════════════════════════

-- Effective permission lookup: user.permissions OR assigned job.permissions.
-- Existing portal_has_perm intentionally reads user.permissions only in the current
-- schema, so this helper is used for capabilities that can be granted by job or by
-- per-user module override.
CREATE OR REPLACE FUNCTION public.portal_effective_perm(p_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.portal_users u
    LEFT JOIN public.portal_jobs j ON j.key = u.job_key
    WHERE u.username = portal_username()
      AND u.active = true
      AND (
        u.role = 'admin'
        OR coalesce((u.permissions ->> p_key)::boolean, false)
        OR coalesce((j.permissions ->> p_key)::boolean, false)
      )
  );
$function$;

REVOKE ALL ON FUNCTION public.portal_effective_perm(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_effective_perm(text) TO authenticated, service_role;

-- Dedicated read gate for confidential supplier quotation / award-pricing info.
-- Request visibility alone must NOT imply quotation visibility.
CREATE OR REPLACE FUNCTION public.portal_can_view_quotes(p_request_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
  SELECT
    portal_is_admin()
    OR portal_is_service()
    OR portal_effective_perm('can_view_quotes')
    OR portal_effective_perm('can_manage_procurement')
    OR portal_effective_perm('can_issue_po')
    OR portal_effective_perm('can_approve_award');
$function$;

REVOKE ALL ON FUNCTION public.portal_can_view_quotes(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_can_view_quotes(text) TO authenticated, service_role;

-- Seed confidential-quote visibility for sector managers/coordinators.
-- Procurement retains visibility through can_manage_procurement/can_issue_po/can_approve_award.
-- portal_jobs is protected by portal_config_guard; use the same guarded transition flag
-- used by sanctioned migrations/seeds, then reset it immediately.
DO $seed_quote_visibility$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);

  UPDATE public.portal_jobs
  SET permissions = coalesce(permissions, '{}'::jsonb) || jsonb_build_object('can_view_quotes', true)
  WHERE key LIKE 'sector_mgr_%'
     OR key IN ('ops_coord', 'proj_coord');

  PERFORM set_config('app.portal_transition', '0', true);
END $seed_quote_visibility$;

-- Confidential offer/award policies. portal_can_see_request was too broad because
-- it includes the original requester.
DROP POLICY IF EXISTS see_by_request ON public.portal_offers;
DROP POLICY IF EXISTS offer_read ON public.portal_offers;
DROP POLICY IF EXISTS portal_offers_read ON public.portal_offers;
DROP POLICY IF EXISTS quote_read_authorized ON public.portal_offers;
CREATE POLICY quote_read_authorized
  ON public.portal_offers
  FOR SELECT
  TO authenticated
  USING (public.portal_can_view_quotes(request_id));

DROP POLICY IF EXISTS offer_items_read ON public.portal_offer_items;
DROP POLICY IF EXISTS oi_read ON public.portal_offer_items;
DROP POLICY IF EXISTS portal_offer_items_read ON public.portal_offer_items;
DROP POLICY IF EXISTS quote_items_read_authorized ON public.portal_offer_items;
CREATE POLICY quote_items_read_authorized
  ON public.portal_offer_items
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.portal_offers o
      WHERE o.id = portal_offer_items.offer_id
        AND public.portal_can_view_quotes(o.request_id)
    )
  );

DROP POLICY IF EXISTS see_by_request ON public.portal_award;
DROP POLICY IF EXISTS aw_read ON public.portal_award;
DROP POLICY IF EXISTS portal_award_read ON public.portal_award;
DROP POLICY IF EXISTS award_read_authorized ON public.portal_award;
CREATE POLICY award_read_authorized
  ON public.portal_award
  FOR SELECT
  TO authenticated
  USING (public.portal_can_view_quotes(request_id));

DROP POLICY IF EXISTS award_lines_read ON public.portal_award_lines;
DROP POLICY IF EXISTS awd_lines_read ON public.portal_award_lines;
DROP POLICY IF EXISTS portal_award_lines_read ON public.portal_award_lines;
DROP POLICY IF EXISTS award_lines_read_authorized ON public.portal_award_lines;
CREATE POLICY award_lines_read_authorized
  ON public.portal_award_lines
  FOR SELECT
  TO authenticated
  USING (public.portal_can_view_quotes(request_id));

-- Direct expense creation is no longer coupled to generic request creation.
CREATE OR REPLACE FUNCTION public.portal_create_expense_draft(
  p_beneficiary text,
  p_amount numeric,
  p_kind text,
  p_purpose text,
  p_department_id text,
  p_need_by date,
  p_details jsonb DEFAULT NULL::jsonb,
  p_note text DEFAULT NULL::text,
  p_beneficiary_id bigint DEFAULT NULL::bigint,
  p_iban_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_me text := portal_username();
  v_id text;
  v_details jsonb := coalesce(p_details,'{}'::jsonb);
  v_iban text;
  v_ben portal_beneficiaries%ROWTYPE;
  v_name text := p_beneficiary;
  v_my_dept text;
  v_dept text;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_is_service() OR portal_effective_perm('can_create_direct_expense')) THEN
    RAISE EXCEPTION 'غير مصرّح بإنشاء طلب صرف مباشر';
  END IF;

  IF p_beneficiary_id IS NOT NULL THEN
    SELECT * INTO v_ben FROM portal_beneficiaries WHERE id = p_beneficiary_id AND active;
    IF NOT FOUND THEN RAISE EXCEPTION 'المستفيد المُحدَّد غير موجود أو غير نشط'; END IF;
    v_name := v_ben.name;
    IF p_kind = 'bank' THEN
      IF v_ben.iban IS NULL THEN RAISE EXCEPTION 'المستفيد المُحدَّد بلا آيبان مُعتمَد'; END IF;
      v_details := v_details || jsonb_build_object('iban', v_ben.iban, 'account_name', coalesce(v_ben.account_name, v_ben.name), 'iban_source', 'master');
    END IF;
  END IF;

  IF coalesce(trim(v_name),'') = '' THEN RAISE EXCEPTION 'اسم الجهة/المستفيد مطلوب'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'المبلغ غير صالح'; END IF;
  IF coalesce(trim(p_purpose),'') = '' THEN RAISE EXCEPTION 'الغرض مطلوب'; END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'طريقة صرف غير صالحة'; END IF;

  SELECT department_id INTO v_my_dept FROM portal_users WHERE username = v_me;
  IF portal_is_admin() THEN
    v_dept := coalesce(nullif(p_department_id,''), v_my_dept);
  ELSE
    IF coalesce(v_my_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم في ملفك — راجع الإدارة'; END IF;
    IF coalesce(p_department_id,'') <> '' AND p_department_id <> v_my_dept THEN
      RAISE EXCEPTION 'القسم يُحدَّد تلقائياً من ملفك — لا يمكن اختيار قسم آخر';
    END IF;
    v_dept := v_my_dept;
  END IF;

  IF coalesce(v_dept,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = v_dept AND active) THEN
    RAISE EXCEPTION 'القسم غير صالح أو مُغلَق';
  END IF;

  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
    IF p_beneficiary_id IS NULL THEN
      IF coalesce(trim(p_iban_reason),'') = '' THEN
        RAISE EXCEPTION 'الآيبان اليدوي (بلا مستفيد معتمَد) يتطلّب سبباً مُوثّقاً';
      END IF;
      v_details := v_details || jsonb_build_object(
        'iban_source','manual','iban_entered_by',v_me,'iban_entered_at',now(),'iban_manual_reason',p_iban_reason);
    END IF;
  ELSIF p_kind = 'custody' THEN
    IF coalesce(v_details->>'custody_to','') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = v_details->>'custody_to' AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)';
    END IF;
  ELSIF p_kind = 'credit' THEN
    IF (v_details->>'due_date') IS NULL OR (v_details->>'due_date')::date IS NULL THEN
      RAISE EXCEPTION 'تاريخ الاستحقاق مطلوب للصرف الآجل';
    END IF;
  END IF;

  v_id := 'REQ-' || to_char(now(),'YYYYMMDD') || '-' || substr(md5(random()::text),1,6);
  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_requests(id, title, department_id, requester, requester_name, req_type, est_total,
      status, phase, beneficiary, beneficiary_id, expense_method, expense_details, project, need_by, note, created_by, created_at)
    VALUES (v_id, left(p_purpose,200), v_dept, v_me,
            (SELECT display_name FROM portal_users WHERE username = v_me), 'direct_expense', p_amount,
            'draft', 'disbursement', v_name, p_beneficiary_id, p_kind, v_details, 'صرف مباشر', p_need_by, p_note, v_me, now());
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(v_id, 'expense_draft_created', v_me, 'portal',
    jsonb_build_object('amount', p_amount, 'kind', p_kind,
      'iban_source', coalesce(v_details->>'iban_source','n/a')));
  IF (v_details->>'iban_source') = 'manual' THEN
    PERFORM portal_audit_write(v_id, 'manual_iban_entered', v_me, 'portal',
      jsonb_build_object('reason', p_iban_reason, 'entered_by', v_me));
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'status', 'draft');
END
$function$;

COMMENT ON FUNCTION public.portal_effective_perm(text) IS 'P0-1d: effective permission from user.permissions or portal_jobs.permissions.';
COMMENT ON FUNCTION public.portal_can_view_quotes(text) IS 'P0-1d: confidential quotation/award-pricing read gate. Request visibility alone must not expose supplier quotes.';
COMMENT ON FUNCTION public.portal_create_expense_draft(text,numeric,text,text,text,date,jsonb,text,bigint,text) IS 'P0-1d: direct expense creation requires can_create_direct_expense/admin/service, not generic can_create.';

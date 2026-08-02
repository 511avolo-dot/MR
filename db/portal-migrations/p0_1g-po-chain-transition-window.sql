-- ═══════════════════════════════════════════════════════════════════════════
-- P0-1g — باني سلسلة أمر الشراء مستقل وآمن تحت حارس الكتابة
--
-- كشف اختبار P0-1f أن portal_build_po_chain كان يعتمد ضمنياً على أن يستدعيه
-- portal_award_transition بعد ضبط app.portal_transition=1. هذا اعتماد هش؛ الدالة
-- نفسها مكشوفة للمستخدم المصادق وتجب أن تدير نافذة الانتقال المصرح بها داخلياً.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.portal_build_po_chain(p_request_id text, p_total numeric)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  d public.portal_doa%ROWTYPE;
  v_seq integer := 0;
  v_route jsonb;
  v_policy jsonb;
  v_version integer;
  v_fallback text;
  v_use_committee boolean;
  v_use_fallback boolean;
BEGIN
  SELECT * INTO d
  FROM public.portal_doa
  WHERE max_value IS NULL OR p_total <= max_value
  ORDER BY priority ASC, max_value ASC NULLS LAST
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد شريحة DoA للقيمة المحددة'; END IF;

  v_route := public.portal_committee_route(p_total);
  v_policy := v_route->'policy';
  v_version := coalesce((v_policy->>'version')::integer, 1);
  v_fallback := nullif(v_route->>'fallback_role_key', '');
  v_use_committee := coalesce((v_route->>'use_committee')::boolean, false);
  v_use_fallback := coalesce((v_route->>'use_fallback')::boolean, false);

  PERFORM set_config('app.portal_transition', '1', true);

  DELETE FROM public.portal_po_approvals WHERE request_id = p_request_id;

  IF v_use_committee THEN
    v_seq := v_seq + 1;
    INSERT INTO public.portal_po_approvals(
      request_id, seq, stage_label, kind, role_key,
      policy_key, policy_version, policy_snapshot
    ) VALUES (
      p_request_id, v_seq, 'اعتماد اللجنة', 'committee', 'can_approve_committee',
      'committee_policy', v_version, v_policy
    );
  ELSIF v_use_fallback THEN
    v_seq := v_seq + 1;
    INSERT INTO public.portal_po_approvals(
      request_id, seq, stage_label, kind, role_key,
      policy_key, policy_version, policy_snapshot
    ) VALUES (
      p_request_id, v_seq, 'المسار البديل للجنة', 'committee_fallback', v_fallback,
      'committee_policy', v_version, v_policy
    );
  END IF;

  IF d.po_finance
     AND NOT (v_use_fallback AND v_fallback = 'can_approve_finance') THEN
    v_seq := v_seq + 1;
    INSERT INTO public.portal_po_approvals(
      request_id, seq, stage_label, kind, role_key,
      policy_key, policy_version, policy_snapshot
    ) VALUES (
      p_request_id, v_seq, 'اعتماد المدير المالي', 'finance', 'can_approve_finance',
      'committee_policy', v_version, v_policy
    );
  END IF;

  IF d.po_gm
     AND NOT (v_use_fallback AND v_fallback = 'can_manage_users') THEN
    v_seq := v_seq + 1;
    INSERT INTO public.portal_po_approvals(
      request_id, seq, stage_label, kind, role_key,
      policy_key, policy_version, policy_snapshot
    ) VALUES (
      p_request_id, v_seq, 'اعتماد المدير العام', 'gm', 'can_manage_users',
      'committee_policy', v_version, v_policy
    );
  END IF;

  PERFORM set_config('app.portal_transition', '0', true);
  RETURN v_seq;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_build_po_chain(text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_build_po_chain(text, numeric) TO authenticated, service_role;

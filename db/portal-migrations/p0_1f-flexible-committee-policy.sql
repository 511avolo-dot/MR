-- ═══════════════════════════════════════════════════════════════════════════
-- P0-1f — سياسة لجنة مرنة، مُصدّرة، وقابلة للتعطيل
--
-- الهدف المؤسسي:
--   • اللجنة ليست شرطاً ثابتاً في الكود أو في شريحة DoA.
--   • يمكن تشغيلها/تعطيلها وتحديد نطاق المبلغ ومسار بديل اختياري.
--   • أي سلسلة أمر شراء تحتفظ بنسخة السياسة التي بُنيت بها؛ تغيير الإعدادات
--     لاحقاً لا يعيد تشكيل المعاملات القائمة.
--   • صلاحيات أعضاء اللجنة/المسار البديل تُقرأ من الصلاحية الفعلية للمستخدم
--     أو وظيفته، مع بقاء عضوية committee_members مدعومة.
--
-- النطاق: فرع Release Candidate وStaging المعزول فقط. لا يغيّر Production.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.portal_po_approvals
  ADD COLUMN IF NOT EXISTS policy_key text,
  ADD COLUMN IF NOT EXISTS policy_version integer,
  ADD COLUMN IF NOT EXISTS policy_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.portal_po_approvals.policy_key IS
  'اسم سياسة سير أمر الشراء التي أنشأت المرحلة.';
COMMENT ON COLUMN public.portal_po_approvals.policy_version IS
  'نسخة السياسة عند إنشاء السلسلة؛ لا تتغير بتعديل الإعدادات لاحقاً.';
COMMENT ON COLUMN public.portal_po_approvals.policy_snapshot IS
  'لقطة غير حساسة من إعداد سياسة اللجنة/المسار البديل لأغراض التتبع.';

-- السياسة الافتراضية تحافظ على السلوك التشغيلي الحالي (>25,000)، لكنها تنقله
-- من منطق ثابت إلى إعداد قابل للنشر والإصدار.
DO $seed_committee_policy$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO public.portal_settings(key, value)
  VALUES (
    'committee_policy',
    jsonb_build_object(
      'enabled', true,
      'min_amount_exclusive', 25000,
      'max_amount_inclusive', null,
      'fallback_role_key', null,
      'version', 1,
      'published_at', to_jsonb(now()),
      'published_by', 'migration:p0_1f'
    )
  )
  ON CONFLICT (key) DO NOTHING;
  PERFORM set_config('app.portal_transition', '0', true);
END $seed_committee_policy$;

CREATE OR REPLACE FUNCTION public.portal_get_committee_policy()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
  SELECT jsonb_build_object(
           'enabled', true,
           'min_amount_exclusive', 25000,
           'max_amount_inclusive', null,
           'fallback_role_key', null,
           'version', 1,
           'published_at', null,
           'published_by', null
         )
         || coalesce(
              (SELECT value FROM public.portal_settings WHERE key = 'committee_policy'),
              '{}'::jsonb
            );
$function$;

REVOKE ALL ON FUNCTION public.portal_get_committee_policy() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_get_committee_policy() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.portal_committee_route(p_total numeric)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_policy jsonb := public.portal_get_committee_policy();
  v_enabled boolean;
  v_min numeric;
  v_max numeric;
  v_fallback text;
  v_in_band boolean;
BEGIN
  IF p_total IS NULL OR p_total < 0 THEN
    RAISE EXCEPTION 'قيمة أمر الشراء غير صالحة';
  END IF;

  v_enabled := coalesce((v_policy->>'enabled')::boolean, true);
  v_min := coalesce((v_policy->>'min_amount_exclusive')::numeric, 25000);
  v_max := nullif(v_policy->>'max_amount_inclusive', '')::numeric;
  v_fallback := nullif(trim(coalesce(v_policy->>'fallback_role_key', '')), '');
  v_in_band := p_total > v_min AND (v_max IS NULL OR p_total <= v_max);

  RETURN jsonb_build_object(
    'policy', v_policy,
    'in_band', v_in_band,
    'use_committee', v_enabled AND v_in_band,
    'use_fallback', (NOT v_enabled) AND v_in_band AND v_fallback IS NOT NULL,
    'fallback_role_key', v_fallback
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_committee_route(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_committee_route(numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.portal_set_committee_policy(p_policy jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_me text := public.portal_username();
  v_current jsonb := public.portal_get_committee_policy();
  v_input jsonb;
  v_enabled boolean;
  v_min numeric;
  v_max numeric;
  v_fallback text;
  v_version integer;
  v_saved jsonb;
BEGIN
  IF v_me IS NULL OR NOT public.portal_is_admin() THEN
    RAISE EXCEPTION 'غير مصرّح — نشر سياسة اللجنة للأدمن فقط';
  END IF;
  IF p_policy IS NULL OR jsonb_typeof(p_policy) <> 'object' THEN
    RAISE EXCEPTION 'سياسة اللجنة يجب أن تكون كائناً';
  END IF;
  IF p_policy ? 'enabled' AND jsonb_typeof(p_policy->'enabled') <> 'boolean' THEN
    RAISE EXCEPTION 'enabled يجب أن تكون true أو false';
  END IF;
  IF p_policy ? 'min_amount_exclusive'
     AND jsonb_typeof(p_policy->'min_amount_exclusive') <> 'number' THEN
    RAISE EXCEPTION 'الحد الأدنى يجب أن يكون رقماً';
  END IF;
  IF p_policy ? 'max_amount_inclusive'
     AND p_policy->'max_amount_inclusive' <> 'null'::jsonb
     AND jsonb_typeof(p_policy->'max_amount_inclusive') <> 'number' THEN
    RAISE EXCEPTION 'الحد الأعلى يجب أن يكون رقماً أو null';
  END IF;
  IF p_policy ? 'fallback_role_key'
     AND p_policy->'fallback_role_key' <> 'null'::jsonb
     AND jsonb_typeof(p_policy->'fallback_role_key') <> 'string' THEN
    RAISE EXCEPTION 'صلاحية المسار البديل يجب أن تكون نصاً أو null';
  END IF;

  v_input := v_current || (p_policy - 'version' - 'published_at' - 'published_by');
  v_enabled := coalesce((v_input->>'enabled')::boolean, true);
  v_min := coalesce((v_input->>'min_amount_exclusive')::numeric, 25000);
  v_max := nullif(v_input->>'max_amount_inclusive', '')::numeric;
  v_fallback := nullif(trim(coalesce(v_input->>'fallback_role_key', '')), '');

  IF v_min < 0 THEN RAISE EXCEPTION 'الحد الأدنى لا يمكن أن يكون سالباً'; END IF;
  IF v_max IS NOT NULL AND v_max <= v_min THEN
    RAISE EXCEPTION 'الحد الأعلى يجب أن يكون أكبر من الحد الأدنى';
  END IF;
  IF v_fallback IS NOT NULL AND v_fallback !~ '^can_[a-z0-9_]+$' THEN
    RAISE EXCEPTION 'اسم صلاحية المسار البديل غير صالح';
  END IF;

  v_version := coalesce((v_current->>'version')::integer, 0) + 1;
  v_saved := jsonb_build_object(
    'enabled', v_enabled,
    'min_amount_exclusive', v_min,
    'max_amount_inclusive', v_max,
    'fallback_role_key', v_fallback,
    'version', v_version,
    'published_at', to_jsonb(now()),
    'published_by', v_me
  );

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO public.portal_settings(key, value)
  VALUES ('committee_policy', v_saved)
  ON CONFLICT (key) DO UPDATE SET value = excluded.value;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM public.portal_audit_write(
    NULL,
    'committee_policy_published',
    v_me,
    'portal',
    jsonb_build_object('previous', v_current, 'current', v_saved)
  );

  RETURN jsonb_build_object('ok', true, 'policy', v_saved);
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_set_committee_policy(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_set_committee_policy(jsonb) TO authenticated, service_role;

-- تبني السلسلة من DoA للمالية/المدير العام، ومن السياسة المنشورة للجنة.
-- لا يعاد بناء السلاسل القائمة عند تغيير السياسة؛ كل صف يحمل snapshot/version.
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

  RETURN v_seq;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_build_po_chain(text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_build_po_chain(text, numeric) TO authenticated, service_role;

-- تحديث فحص الصلاحية ليشمل صلاحيات الوظيفة والـoverride الفردي.
CREATE OR REPLACE FUNCTION public.portal_po_transition(
  p_request_id text,
  p_action text,
  p_comment text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_me text := public.portal_username();
  v_req public.portal_requests%ROWTYPE;
  v_stage public.portal_po_approvals%ROWTYPE;
  v_remaining integer;
  v_committee jsonb;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM public.portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'po_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار اعتماد أمر الشراء'; END IF;
  IF v_req.requester = v_me AND NOT public.portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)';
  END IF;

  SELECT * INTO v_stage
  FROM public.portal_po_approvals
  WHERE request_id = p_request_id AND decision = 'pending'
  ORDER BY seq ASC
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة أمر شراء معلّقة'; END IF;

  IF v_stage.kind = 'committee' THEN
    SELECT value INTO v_committee FROM public.portal_settings WHERE key = 'committee_members';
    IF NOT (
      public.portal_is_admin()
      OR public.portal_effective_perm('can_approve_committee')
      OR (v_committee IS NOT NULL AND v_committee ? v_me)
    ) THEN
      RAISE EXCEPTION 'لست عضواً مخولاً في اللجنة';
    END IF;
  ELSE
    IF NOT public.portal_is_admin()
       AND NOT public.portal_effective_perm(v_stage.role_key) THEN
      RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة';
    END IF;
  END IF;

  IF NOT public.portal_is_admin() THEN
    IF EXISTS (
      SELECT 1 FROM public.portal_po_approvals
      WHERE request_id = p_request_id AND approver = v_me AND decision = 'approved'
    ) THEN
      RAISE EXCEPTION 'لا تعتمد أكثر من مرحلة في أمر الشراء نفسه (فصل المهام)';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.portal_award
      WHERE request_id = p_request_id AND awarded_by = v_me
    ) THEN
      RAISE EXCEPTION 'من رسا التعميد لا يعتمد أمر شرائه (فصل المهام)';
    END IF;
  END IF;

  IF p_action IN ('reject','return') AND coalesce(trim(p_comment),'') = '' THEN
    RAISE EXCEPTION 'السبب مطلوب';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  IF p_action = 'approve' THEN
    UPDATE public.portal_po_approvals
    SET decision = 'approved', approver = v_me, comment = p_comment, acted_at = now()
    WHERE request_id = p_request_id AND seq = v_stage.seq;

    SELECT count(*) INTO v_remaining
    FROM public.portal_po_approvals
    WHERE request_id = p_request_id AND decision = 'pending';

    IF v_remaining = 0 THEN
      UPDATE public.portal_requests
      SET status = 'awarded', phase = 'payment', po_issued_by = v_me, po_issued_at = now(),
          current_seq = 0, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
    ELSE
      UPDATE public.portal_requests
      SET current_seq = v_stage.seq + 1, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
    END IF;
  ELSE
    UPDATE public.portal_po_approvals
    SET decision = CASE p_action WHEN 'reject' THEN 'rejected' ELSE 'returned' END,
        approver = v_me, comment = p_comment, acted_at = now()
    WHERE request_id = p_request_id AND seq = v_stage.seq;

    UPDATE public.portal_award SET status = 'rejected' WHERE request_id = p_request_id;
    UPDATE public.portal_requests
    SET status = 'pricing', phase = 'pricing', updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM public.portal_audit_write(
    p_request_id,
    'po_' || p_action,
    v_me,
    'portal',
    jsonb_build_object(
      'comment', p_comment,
      'stage', v_stage.stage_label,
      'policy_version', v_stage.policy_version
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'action', p_action,
    'status', (SELECT status FROM public.portal_requests WHERE id = p_request_id)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_po_transition(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_po_transition(text, text, text) TO authenticated;

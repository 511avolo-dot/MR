-- ════════════════════════════════════════════════════════════════════════════
--  p0_2d — توسيع صلاحية إلغاء الطلب لمدير القسم/القطاع (تكليف المالك 2026-08-18)
--  ---------------------------------------------------------------------------
--  ملاحظة المالك: «لماذا لا يمكن إلغاء طلب صرف بعد إرساله — سواء من الطالب أو مدير
--  القسم أو مدير القطاع؟ ولا أعلم، على نفس الحالة لطلب الشراء، هل الإلغاء ممكن أم لا.»
--
--  الحالة السابقة (portal_cancel_request): يُلغي الأدمن/المشتريات (أيّ وقت) أو المُقدّم
--  في (draft/in_review/returned) فقط. مدير القسم/القطاع لم يكن يملك الإلغاء إطلاقاً،
--  ولا زرّ إلغاء في تفاصيل الصرف المباشر (فجوة واجهة عولجت في المُحوِّل).
--
--  الإصلاح (إضافة صلاحية محكومة، بلا حذف/إضعاف حارس قائم):
--   • يُضاف **مدير قسم الطلب** (portal_departments.manager_user) و**مدير قطاعه** (مدير
--     أيّ قسم في نفس القطاع) إلى المخوَّلين بالإلغاء — ضمن نافذة «ما قبل الالتزام الماليّ»:
--       – الشراء: قبل التعميد (draft/in_review/returned/approved/pricing/award_review).
--       – الصرف المباشر: قبل تنفيذ الصرف (draft/in_review/returned/payment_pending، وبلا صرف منفَّذ).
--   • لا يُمَسّ أيّ مسار قائم: الأدمن/المشتريات/المُقدّم كما هم. حارس closed/cancelled باقٍ.
--   • لا إلغاء بعد صرف منفَّذ لمدير القسم/القطاع (المال خرج — تُستخدم التسوية/الإبطال المحكوم).
--
--  idempotent: CREATE OR REPLACE. مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_cancel_request(p_request_id text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE;
        v_is_mgr boolean := false; v_pre_commit boolean := false; v_disbursed boolean;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status IN ('closed','cancelled') THEN RAISE EXCEPTION 'لا يمكن إلغاء طلب مُغلق'; END IF;

  -- (p0_2d) مدير قسم الطلب مباشرةً، أو مدير قطاعه (مدير أيّ قسم في نفس القطاع).
  v_is_mgr := EXISTS (SELECT 1 FROM portal_departments d
                        WHERE d.id = v_req.department_id AND d.manager_user = v_me)
           OR EXISTS (SELECT 1 FROM portal_departments d
                        JOIN portal_departments d2 ON d2.sector = d.sector AND d2.sector IS NOT NULL
                        WHERE d.id = v_req.department_id AND d2.manager_user = v_me);

  -- نافذة «ما قبل الالتزام الماليّ» (تختلف بين الشراء والصرف المباشر).
  v_disbursed := EXISTS (SELECT 1 FROM portal_payments p
                           WHERE p.request_id = v_req.id AND p.status = 'disbursed');
  IF v_req.req_type = 'direct_expense' THEN
    v_pre_commit := (v_req.status IN ('draft','in_review','returned','payment_pending') AND NOT v_disbursed);
  ELSE
    v_pre_commit := (v_req.status IN ('draft','in_review','returned','approved','pricing','award_review'));
  END IF;

  -- من يُلغي: الأدمن/المشتريات (أيّ وقت) — المُقدّم قبل بدء التعميد — أو مدير القسم/القطاع
  -- ضمن نافذة ما قبل الالتزام. (الباب 7 + سيناريو 6-5 + تكليف المالك p0_2d)
  IF NOT (
        portal_is_admin()
        OR portal_has_perm('can_manage_procurement')
        OR portal_has_perm('can_approve_award')
        OR portal_has_perm('can_issue_po')
        OR (v_req.requester = v_me AND v_req.status IN ('draft','in_review','returned'))
        OR (v_is_mgr AND v_pre_commit)
     ) THEN
    RAISE EXCEPTION 'غير مصرّح بإلغاء هذا الطلب في حالته الحالية';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET status = 'cancelled', cancelled_by = v_me, cancelled_at = now(),
      cancel_reason = p_reason, updated_at = now()
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'cancelled', v_me, 'portal',
    jsonb_build_object('reason', p_reason,
      'by_role', CASE WHEN portal_is_admin() OR portal_has_perm('can_manage_procurement')
                        OR portal_has_perm('can_approve_award') OR portal_has_perm('can_issue_po') THEN 'staff'
                      WHEN v_req.requester = v_me THEN 'requester'
                      WHEN v_is_mgr THEN 'manager' ELSE 'actor' END));
  RETURN jsonb_build_object('ok', true, 'status', 'cancelled');
END $fn$;

-- ═══════════════════════════════════════════════════════════════════════════
--  056 — الاعتماد بالبريد لدورة الصرف (المرحلة 3-ج، الإنتاجية)
--  ─────────────────────────────────────────────────────────────────────────
--  الاعتماد بضغطة من البريد (portal_pr_transition_email) كان **مُنطاقاً بدورة need
--  فقط** (050). دورة الصرف (disbursement) لم تكن تدعمه — فمعتمِدو الصرف مضطرّون لفتح
--  البوابة. هذه الهجرة تعمّم الاعتماد بالبريد ليكون **واعياً بالدورة** كبقيّة المحرّك:
--
--   (1) عمود `cycle` على portal_email_tokens (افتراضي 'need' — لا انحدار).
--   (2) portal_create_token يكتسب معاملاً سادساً p_cycle (يُخزَّن مع الرمز؛ الإسقاط
--       القديم يمنع الالتباس). التوقيع الجديد 6 معاملات.
--   (3) portal_pr_transition_email يقرأ دورة الرمز ويعمّم كل استعلاماته بها، ويوجّه
--       الاكتمال بالدورة: need→pricing كما هو؛ disbursement→payment_pending/payment
--       (+فتح دفعة الصرف المباشر للـdirect_expense) — بنفس فصل المهام والحوكمة.
--
--  عدم الانحدار مضمون: الرموز القائمة cycle='need'، والاكتمال need بلا تغيير.
--  ⚠️ تُطبَّق حيّاً بعد 055b. مدمجة في db/portal-standalone.sql.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (1) بُعد الدورة على رموز البريد ─────────────────────────────────────────
ALTER TABLE portal_email_tokens ADD COLUMN IF NOT EXISTS cycle TEXT NOT NULL DEFAULT 'need';

-- ── (2) portal_create_token واعياً بالدورة (إسقاط التوقيع القديم أولاً) ──────
DROP FUNCTION IF EXISTS portal_create_token(text, text, int, text, numeric);
CREATE OR REPLACE FUNCTION portal_create_token(p_request_id text, p_kind text, p_seq int, p_approver text,
    p_ttl_hours numeric DEFAULT 168, p_cycle text DEFAULT 'need')
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_token text := portal_gen_token(); v_cycle text := coalesce(nullif(p_cycle,''), 'need');
BEGIN
  UPDATE portal_email_tokens SET used = true, used_at = now()
    WHERE request_id = p_request_id AND kind = p_kind AND seq IS NOT DISTINCT FROM p_seq
      AND approver = p_approver AND cycle = v_cycle AND used = false;
  INSERT INTO portal_email_tokens(token, request_id, kind, seq, approver, cycle, expires_at)
    VALUES (v_token, p_request_id, p_kind, p_seq, p_approver, v_cycle, now() + make_interval(hours => p_ttl_hours::int));
  RETURN v_token;
END $fn$;
-- خادمية بحتة (تُنشئ رموز اعتماد) — تُسحَب من الجميع وتُمنَح لخدمة الخادم فقط (نمط 019/030).
REVOKE ALL ON FUNCTION portal_create_token(text,text,int,text,numeric,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_create_token(text,text,int,text,numeric,text) TO service_role;

-- ── (3) portal_pr_transition_email واعياً بالدورة ──────────────────────────
CREATE OR REPLACE FUNCTION portal_pr_transition_email(p_token text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_tok portal_email_tokens%ROWTYPE; v_req portal_requests%ROWTYPE; v_stage portal_approvals%ROWTYPE;
  v_intended text; v_perm boolean; v_ok boolean := false;
  v_pending int; v_next_seq int; v_decision text; v_status text; v_phase text;
  v_cycle text; v_active_phase text;
BEGIN
  IF p_action NOT IN ('approve','reject','return') THEN RETURN jsonb_build_object('error','invalid_action','code',400); END IF;
  IF NOT p_token ~ '^[0-9A-Za-z]{16,128}$' THEN RETURN jsonb_build_object('error','unknown_token','code',400); END IF;
  SELECT * INTO v_tok FROM portal_email_tokens WHERE token = p_token FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','unknown_token','code',404); END IF;
  IF v_tok.used THEN RETURN jsonb_build_object('error','used','code',410); END IF;
  IF v_tok.expires_at < now() THEN RETURN jsonb_build_object('error','expired','code',410); END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = v_tok.request_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','pr_not_found','code',404); END IF;
  IF v_req.status <> 'in_review' THEN RETURN jsonb_build_object('error','not_in_review','code',409); END IF;

  v_cycle := coalesce(nullif(v_tok.cycle,''), 'need');
  v_active_phase := CASE WHEN v_cycle = 'disbursement' THEN 'disbursement' ELSE 'requisition' END;

  SELECT * INTO v_stage FROM portal_approvals WHERE request_id = v_tok.request_id AND cycle = v_cycle AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','no_pending','code',409); END IF;
  IF v_stage.seq <> v_tok.seq THEN RETURN jsonb_build_object('error','stage_changed','code',409); END IF;

  IF portal_setting_bool('sod_requester_cannot_approve', true)
     AND v_req.requester = v_tok.approver THEN RETURN jsonb_build_object('error','sod','code',403); END IF;
  IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = v_tok.request_id AND cycle = v_cycle
              AND approver = v_tok.approver AND decision = 'approved' AND seq < v_stage.seq) THEN
    RETURN jsonb_build_object('error','sod','code',403);
  END IF;

  v_intended := portal_resolve_stage(v_tok.request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    v_ok := (portal_qualified_approver(v_intended, v_req.requester) = v_tok.approver);
  ELSIF v_stage.role_key IS NOT NULL THEN
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm FROM portal_users WHERE username = v_tok.approver;
    v_ok := coalesce(v_perm, false);
  END IF;
  IF NOT v_ok THEN RETURN jsonb_build_object('error','not_approver','code',403); END IF;
  IF p_action IN ('reject','return') AND coalesce(trim(p_comment),'') = '' THEN
    RETURN jsonb_build_object('error','comment_required','code',400);
  END IF;

  UPDATE portal_email_tokens SET used = true, used_at = now() WHERE token = p_token;
  v_decision := CASE p_action WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' ELSE 'returned' END;
  SELECT count(*) INTO v_pending FROM portal_approvals WHERE request_id = v_tok.request_id AND cycle = v_cycle AND decision = 'pending';

  IF p_action = 'approve' THEN
    IF v_pending <= 1 THEN
      IF v_cycle = 'disbursement' THEN
        v_status := 'payment_pending'; v_phase := 'payment'; v_next_seq := 0;
      ELSE
        v_status := 'pricing'; v_phase := 'pricing'; v_next_seq := v_stage.seq;
      END IF;
    ELSE
      SELECT min(seq) INTO v_next_seq FROM portal_approvals WHERE request_id = v_tok.request_id AND cycle = v_cycle AND decision = 'pending' AND seq > v_stage.seq;
      v_status := 'in_review'; v_phase := v_active_phase;
    END IF;
  ELSIF p_action = 'reject' THEN v_status := 'rejected'; v_phase := v_active_phase; v_next_seq := 0;
  ELSE v_status := 'returned'; v_phase := v_active_phase; v_next_seq := 0;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_approvals SET decision = v_decision, approver = v_tok.approver, comment = p_comment, acted_at = now(), channel = 'email'
    WHERE request_id = v_tok.request_id AND cycle = v_cycle AND seq = v_stage.seq;
  UPDATE portal_requests SET status = v_status, current_seq = coalesce(v_next_seq,0), phase = v_phase, updated_at = now(), updated_by = v_tok.approver
    WHERE id = v_tok.request_id;
  -- اكتمال دورة الصرف لطلب صرف مباشر: افتح الدفعة المُعتمَدة بالسلسلة.
  IF p_action = 'approve' AND v_pending <= 1 AND v_cycle = 'disbursement' AND v_req.req_type = 'direct_expense' THEN
    PERFORM portal_open_direct_payment(v_tok.request_id, v_tok.approver);
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(v_tok.request_id, 'stage_' || v_decision, v_tok.approver, 'email', jsonb_build_object('cycle', v_cycle, 'stage', v_stage.stage_label, 'comment', p_comment));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
    'finalized', v_status <> 'in_review', 'seq', v_stage.seq, 'cycle', v_cycle,
    'request', jsonb_build_object('id', v_req.id, 'title', v_req.title, 'department_id', v_req.department_id,
                                   'requester', v_req.requester, 'requester_name', v_req.requester_name));
END $fn$;
REVOKE ALL ON FUNCTION portal_pr_transition_email(text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_pr_transition_email(text,text,text) TO service_role;

-- تحقّق:
--   SELECT portal_create_token('<req>','approval',1,'<user>',168,'disbursement');
--   SELECT portal_pr_transition_email('<token>','approve');  ⇒ يتقدّم بدورة الصرف

-- ═══════════════════════════════════════════════════════════════════════════
--  050 — محرّك الصرف والموافقات المالية الموحّد (النواة، المرحلة ١)
--  ─────────────────────────────────────────────────────────────────────────
--  دمج نظام طلبات الصرف المالية داخل البوابة كـ«محرّك صرف موحّد» بمدخلين يغذّيان
--  نفس محرّك الوورك فلو الذكيّ القائم (إرجاع لمرحلة · تفويض · تصعيد · معتمِد مؤهَّل ·
--  اعتماد بريد · فصل مهام) — لا استنساخ محرّك أفقر:
--
--    • المدخل الأول: طلب صرف مستقلّ يُنشأ ويكتمل **خارج دورة المشتريات تماماً**.
--    • المدخل الثاني: ذيل دورة الشراء — يمرّ الصرف بالسلسلة المالية الجديدة بدل
--      الاعتماد المسطّح (اختياري بمفتاح، آمن افتراضياً).
--
--  المبدأ: نضيف بُعد «الدورة» (cycle) على portal_approvals/portal_workflows، ونعمّم
--  portal_pr_transition ودوال المحرّك لتعمل لأي دورة. عدم الانحدار مضمون: cycle
--  الافتراضي 'need' فكل القائم يبقى مطابقاً.
--
--  ⚠️ تُطبَّق حيّاً بعد 049. مدمجة في db/portal-standalone.sql (تنصيب نظيف).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (1) بُعد الدورة + نوع الطلب + حقول الصرف ────────────────────────────────
ALTER TABLE portal_approvals ADD COLUMN IF NOT EXISTS cycle TEXT NOT NULL DEFAULT 'need';
DROP INDEX IF EXISTS uq_portal_appr_req_seq;
CREATE UNIQUE INDEX IF NOT EXISTS uq_portal_appr_req_cycle_seq ON portal_approvals(request_id, cycle, seq);

ALTER TABLE portal_workflows ADD COLUMN IF NOT EXISTS cycle TEXT NOT NULL DEFAULT 'need';

ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS req_type        TEXT NOT NULL DEFAULT 'purchase'; -- purchase | direct_expense
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS beneficiary     TEXT;
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS expense_method  TEXT;   -- bank | custody | credit
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS expense_details JSONB; -- بيانات الصرف المباشر (آيبان/عهدة/آجل)

-- مفتاح تفعيل بوّابة الصرف على مسار الشراء (افتراضي 0 = السلوك الحالي المسطّح؛
-- يرفعه المالك إلى 1 بعد ضبط سلسلة صرف الشراء وأدوارها — تفعيل تدريجي آمن).
UPDATE portal_settings SET value = value || jsonb_build_object('disb_gate_purchase', 0)
 WHERE key = 'portal_settings' AND NOT (value ? 'disb_gate_purchase');

-- ── (2) باني السلسلة المعمَّم (يخدم دورتَي need و disbursement) ──────────────
--   يُطابِق قالب portal_workflows حسب cycle/القسم/القطاع/القيمة ويُدرِج مراحل
--   portal_approvals بذلك الـcycle. يعيد عدد المراحل (0 = لا سلسلة مطابِقة).
CREATE OR REPLACE FUNCTION portal_build_chain(p_request_id text, p_cycle text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_req portal_requests%ROWTYPE; v_wf portal_workflows%ROWTYPE; v_sector text; v_stage jsonb; v_n int := 0;
BEGIN
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  SELECT sector INTO v_sector FROM portal_departments WHERE id = v_req.department_id;

  SELECT * INTO v_wf FROM portal_workflows
    WHERE active AND cycle = p_cycle
      AND (department_id IS NULL OR department_id = v_req.department_id)
      AND (sector IS NULL OR sector = v_sector)
      AND v_req.est_total >= min_total
      AND (max_total IS NULL OR v_req.est_total <= max_total)
    ORDER BY priority ASC LIMIT 1;

  -- امسح صفوف هذه الدورة القديمة (إعادة بناء آمنة). ملاحظة: DELETE يعيد ضبط FOUND،
  -- لذا نعتمد على v_wf.id (لا FOUND) لتقرير مطابقة القالب.
  DELETE FROM portal_approvals WHERE request_id = p_request_id AND cycle = p_cycle;

  IF v_wf.id IS NOT NULL THEN
    FOR v_stage IN SELECT * FROM jsonb_array_elements(v_wf.stages) LOOP
      INSERT INTO portal_approvals(request_id, cycle, seq, stage_label, resolver, role_key, approver)
        VALUES (p_request_id, p_cycle, (v_stage->>'seq')::int, v_stage->>'label',
                v_stage->>'resolver', v_stage->>'role_key', v_stage->>'approver');
      v_n := v_n + 1;
    END LOOP;
    IF p_cycle = 'need' THEN UPDATE portal_requests SET workflow_id = v_wf.id WHERE id = p_request_id; END IF;
  ELSIF p_cycle = 'need' THEN
    -- سلسلة الحاجة الاحتياطية: مرحلة واحدة (مدير القسم) — توافق مع السلوك القائم.
    INSERT INTO portal_approvals(request_id, cycle, seq, stage_label, resolver, role_key, approver)
      VALUES (p_request_id, 'need', 1, 'مدير القسم', 'dept_manager', NULL, NULL);
    v_n := 1;
  END IF;
  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION portal_build_chain(text,text) FROM PUBLIC, anon;

-- ── (3) portal_submit_request يعيد استخدام الباني (دورة need) ───────────────
CREATE OR REPLACE FUNCTION portal_submit_request(p_request_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_n int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'draft' THEN RAISE EXCEPTION 'الطلب أُرسل مسبقاً'; END IF;
  IF v_req.requester <> v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  v_n := portal_build_chain(p_request_id, 'need');
  UPDATE portal_requests SET status = 'in_review', current_seq = 1, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'submitted', v_me, 'portal', '{}'::jsonb);
  RETURN jsonb_build_object('ok', true, 'status', 'in_review');
END $fn$;

-- ── (4) portal_pr_transition واعياً بالدورة ────────────────────────────────
--   p_cycle=NULL ⇒ يُشتقّ من الطور: disbursement عند phase='disbursement' وإلا need.
--   كل استعلام portal_approvals مُنطاق بالدورة. فرع الاكتمال يوجَّه بالدورة/النوع.
--   ⚠️ يُسقَط التوقيع القديم (5 معاملات) كي لا يبقى تحميل زائد مبهم؛ كل نداء بـ5
--      معاملات مسمّاة يُحلّ إلى التوقيع الجديد (p_cycle افتراضه NULL).
DROP FUNCTION IF EXISTS portal_pr_transition(text, text, text, date, int);
CREATE OR REPLACE FUNCTION portal_pr_transition(p_request_id text, p_action text,
    p_comment text DEFAULT NULL, p_hold_until date DEFAULT NULL, p_return_to_seq int DEFAULT 0,
    p_cycle text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE; v_stage portal_approvals%ROWTYPE; v_target portal_approvals%ROWTYPE;
  v_pending int; v_next_seq int; v_decision text; v_status text; v_phase text;
  v_ok boolean := false; v_intended text; v_perm boolean; v_cycle text; v_active_phase text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','defer') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'in_review' THEN RAISE EXCEPTION 'الطلب ليس قيد المراجعة'; END IF;

  v_cycle := coalesce(p_cycle, CASE WHEN v_req.phase = 'disbursement' THEN 'disbursement' ELSE 'need' END);
  v_active_phase := CASE WHEN v_cycle = 'disbursement' THEN 'disbursement' ELSE 'requisition' END;

  SELECT * INTO v_stage FROM portal_approvals
    WHERE request_id = p_request_id AND cycle = v_cycle AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة معلّقة'; END IF;

  IF portal_setting_bool('sod_requester_cannot_approve', true)
     AND v_req.requester = v_me AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)';
  END IF;
  IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = p_request_id AND cycle = v_cycle
              AND approver = v_me AND decision = 'approved' AND seq < v_stage.seq)
     AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'اعتمدت مرحلة سابقة لهذا الطلب — لا يجوز اعتماد أكثر من مرحلة (فصل المهام)';
  END IF;

  v_intended := portal_resolve_stage(p_request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    v_ok := (portal_qualified_approver(v_intended, v_req.requester) = v_me);
  ELSIF v_stage.role_key IS NOT NULL THEN
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm
      FROM portal_users WHERE username = v_me;
    v_ok := coalesce(v_perm, false);
  END IF;
  IF NOT v_ok AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action IN ('reject','return','defer') AND coalesce(trim(p_comment),'') = '' THEN
    RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع/التأجيل';
  END IF;

  -- التأجيل المالي: مرحلة التحقق المالي فقط (يعمل في الدورتين).
  IF p_action = 'defer' THEN
    IF v_stage.role_key IS DISTINCT FROM 'can_approve_finance' AND NOT portal_is_admin() THEN
      RAISE EXCEPTION 'التأجيل المالي متاح في مرحلة التحقق المالي فقط';
    END IF;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_requests SET status = 'on_hold', hold_reason = p_comment, hold_until = p_hold_until,
           held_by = v_me, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'deferred', v_me, 'portal',
      jsonb_build_object('reason', p_comment, 'until', p_hold_until, 'cycle', v_cycle));
    RETURN jsonb_build_object('ok', true, 'action', 'defer', 'status', 'on_hold');
  END IF;

  -- الإرجاع المرن إلى مرحلة سابقة (ضمن الدورة نفسها).
  IF p_action = 'return' AND coalesce(p_return_to_seq, 0) > 0 THEN
    IF p_return_to_seq >= v_stage.seq THEN RAISE EXCEPTION 'الإرجاع يكون لمرحلة سابقة فقط'; END IF;
    SELECT * INTO v_target FROM portal_approvals
      WHERE request_id = p_request_id AND cycle = v_cycle AND seq = p_return_to_seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'المرحلة الهدف غير موجودة'; END IF;

    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_approvals SET decision = 'pending', approver = NULL, comment = NULL, acted_at = NULL, channel = 'portal'
      WHERE request_id = p_request_id AND cycle = v_cycle AND seq >= p_return_to_seq;
    UPDATE portal_requests SET status = 'in_review', phase = v_active_phase,
           current_seq = p_return_to_seq, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    PERFORM set_config('app.portal_transition', '0', true);

    PERFORM portal_audit_write(p_request_id, 'stage_returned', v_me, 'portal',
      jsonb_build_object('cycle', v_cycle, 'from_seq', v_stage.seq, 'to_seq', p_return_to_seq, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', 'return', 'decision', 'returned',
      'status', 'in_review', 'finalized', false, 'seq', v_stage.seq, 'return_to_seq', p_return_to_seq);
  END IF;

  v_decision := CASE p_action WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' ELSE 'returned' END;
  SELECT count(*) INTO v_pending FROM portal_approvals
    WHERE request_id = p_request_id AND cycle = v_cycle AND decision = 'pending';

  IF p_action = 'approve' THEN
    IF v_pending <= 1 THEN
      -- اكتملت السلسلة — التوجيه بالدورة والنوع:
      IF v_cycle = 'disbursement' THEN
        v_status := 'payment_pending'; v_phase := 'payment'; v_next_seq := 0;
      ELSIF v_req.req_type = 'direct_expense' THEN
        v_status := 'payment_pending'; v_phase := 'payment'; v_next_seq := 0;   -- احتياط (الصرف المباشر يستخدم دورة disbursement)
      ELSE
        v_status := 'pricing'; v_phase := 'pricing'; v_next_seq := v_stage.seq;  -- مسار الشراء بلا تغيير
      END IF;
    ELSE
      SELECT min(seq) INTO v_next_seq FROM portal_approvals
        WHERE request_id = p_request_id AND cycle = v_cycle AND decision = 'pending' AND seq > v_stage.seq;
      v_status := 'in_review'; v_phase := v_active_phase;
    END IF;
  ELSIF p_action = 'reject' THEN
    v_status := 'rejected'; v_phase := v_active_phase; v_next_seq := 0;
  ELSE
    v_status := 'returned'; v_phase := v_active_phase; v_next_seq := 0;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_approvals SET decision = v_decision, approver = v_me, comment = p_comment, acted_at = now(), channel = 'portal'
    WHERE request_id = p_request_id AND cycle = v_cycle AND seq = v_stage.seq;
  UPDATE portal_requests SET status = v_status, current_seq = coalesce(v_next_seq,0), phase = v_phase,
         updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  -- عند اكتمال دورة الصرف: افتح الدفعة المُعتمَدة بالسلسلة (للصرف المباشر) أو جهّز
  -- بوّابة التنفيذ (لمسار الشراء — الدفعة تُنشأ لاحقاً عبر portal_payment_request).
  IF p_action = 'approve' AND v_pending <= 1 AND v_cycle = 'disbursement' AND v_req.req_type = 'direct_expense' THEN
    PERFORM portal_open_direct_payment(p_request_id, v_me);
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'stage_' || v_decision, v_me, 'portal',
    jsonb_build_object('cycle', v_cycle, 'stage', v_stage.stage_label, 'comment', p_comment));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
    'finalized', v_status <> 'in_review', 'seq', v_stage.seq, 'cycle', v_cycle);
END $fn$;
REVOKE ALL ON FUNCTION portal_pr_transition(text,text,text,date,int,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_pr_transition(text,text,text,date,int,text) TO authenticated;

-- ── (5) portal_pr_transition_email مُنطاق بدورة need (اعتماد بريد الصرف = مرحلة لاحقة) ──
CREATE OR REPLACE FUNCTION portal_pr_transition_email(p_token text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_tok portal_email_tokens%ROWTYPE; v_req portal_requests%ROWTYPE; v_stage portal_approvals%ROWTYPE;
  v_intended text; v_perm boolean; v_ok boolean := false;
  v_pending int; v_next_seq int; v_decision text; v_status text; v_phase text;
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

  -- اعتماد البريد للدورة الأولى (need) فقط في هذه المرحلة.
  SELECT * INTO v_stage FROM portal_approvals WHERE request_id = v_tok.request_id AND cycle = 'need' AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','no_pending','code',409); END IF;
  IF v_stage.seq <> v_tok.seq THEN RETURN jsonb_build_object('error','stage_changed','code',409); END IF;

  IF portal_setting_bool('sod_requester_cannot_approve', true)
     AND v_req.requester = v_tok.approver THEN RETURN jsonb_build_object('error','sod','code',403); END IF;
  IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = v_tok.request_id AND cycle = 'need'
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
  SELECT count(*) INTO v_pending FROM portal_approvals WHERE request_id = v_tok.request_id AND cycle = 'need' AND decision = 'pending';

  IF p_action = 'approve' THEN
    IF v_pending <= 1 THEN v_status := 'pricing'; v_phase := 'pricing'; v_next_seq := v_stage.seq;
    ELSE
      SELECT min(seq) INTO v_next_seq FROM portal_approvals WHERE request_id = v_tok.request_id AND cycle = 'need' AND decision = 'pending' AND seq > v_stage.seq;
      v_status := 'in_review'; v_phase := 'requisition';
    END IF;
  ELSIF p_action = 'reject' THEN v_status := 'rejected'; v_phase := 'requisition'; v_next_seq := 0;
  ELSE v_status := 'returned'; v_phase := 'requisition'; v_next_seq := 0;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_approvals SET decision = v_decision, approver = v_tok.approver, comment = p_comment, acted_at = now(), channel = 'email'
    WHERE request_id = v_tok.request_id AND cycle = 'need' AND seq = v_stage.seq;
  UPDATE portal_requests SET status = v_status, current_seq = coalesce(v_next_seq,0), phase = v_phase, updated_at = now(), updated_by = v_tok.approver
    WHERE id = v_tok.request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(v_tok.request_id, 'stage_' || v_decision, v_tok.approver, 'email', jsonb_build_object('stage', v_stage.stage_label, 'comment', p_comment));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
    'finalized', v_status <> 'in_review', 'seq', v_stage.seq,
    'request', jsonb_build_object('id', v_req.id, 'title', v_req.title, 'department_id', v_req.department_id,
                                   'requester', v_req.requester, 'requester_name', v_req.requester_name));
END $fn$;

-- ── (6) portal_resubmit_request واعياً بالدورة ─────────────────────────────
CREATE OR REPLACE FUNCTION portal_resubmit_request(p_request_id text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_first int; v_cycle text; v_phase text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'returned' THEN RAISE EXCEPTION 'يمكن إعادة تقديم الطلبات المُعادة فقط'; END IF;
  IF v_req.requester <> v_me AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'إعادة التقديم تقتصر على مُقدّم الطلب';
  END IF;
  v_cycle := CASE WHEN v_req.phase = 'disbursement' THEN 'disbursement' ELSE 'need' END;
  v_phase := CASE WHEN v_cycle = 'disbursement' THEN 'disbursement' ELSE 'requisition' END;

  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_approvals SET decision='pending', approver=NULL, comment=NULL, acted_at=NULL, channel='portal'
   WHERE request_id = p_request_id AND cycle = v_cycle;
  SELECT min(seq) INTO v_first FROM portal_approvals WHERE request_id = p_request_id AND cycle = v_cycle;
  UPDATE portal_requests SET status='in_review', phase=v_phase, current_seq = coalesce(v_first,1),
         updated_at=now(), updated_by=v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM portal_audit_write(p_request_id,'resubmitted',v_me,'portal',jsonb_build_object('comment',p_comment,'cycle',v_cycle));
  RETURN jsonb_build_object('ok', true, 'status', 'in_review');
END $fn$;

-- ── (7) portal_run_sla واعياً بالدورة (يصعّد مرحلة الدورة النشطة) ───────────
CREATE OR REPLACE FUNCTION portal_run_sla() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_req RECORD; v_stage portal_approvals%ROWTYPE; v_intended text; v_deleg text; v_cnt int := 0;
        v_h numeric := portal_sla_hours(); v_cycle text;
BEGIN
  FOR v_req IN SELECT * FROM portal_requests
      WHERE status = 'in_review' AND stage_due_at < now()
        AND (last_escalation_at IS NULL OR last_escalation_at < now() - make_interval(hours => v_h::int))
  LOOP
    v_cycle := CASE WHEN v_req.phase = 'disbursement' THEN 'disbursement' ELSE 'need' END;
    SELECT * INTO v_stage FROM portal_approvals WHERE request_id = v_req.id AND cycle = v_cycle AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
    CONTINUE WHEN NOT FOUND;
    v_intended := portal_resolve_stage(v_req.id, v_stage);
    v_deleg := NULL;
    IF v_intended IS NOT NULL THEN
      SELECT delegate_to INTO v_deleg FROM portal_users WHERE username = v_intended AND is_away = true;
    END IF;
    IF v_intended IS NOT NULL THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        VALUES ('ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||v_intended,
                v_intended, 'system', 'تذكير: طلب متأخّر بانتظار اعتمادك', v_req.title, 'inbox')
        ON CONFLICT (id) DO NOTHING;
    ELSIF v_stage.role_key IS NOT NULL THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||u.username,
               u.username, 'system', 'تذكير: طلب متأخّر بانتظار اعتماد مرحلتك ('||coalesce(v_stage.stage_label,'')||')', v_req.title, 'inbox'
        FROM portal_users u WHERE u.active AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
        ON CONFLICT (id) DO NOTHING;
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||u.delegate_to,
               u.delegate_to, 'system', 'تفويض: طلب متأخّر ('||coalesce(v_stage.stage_label,'')||') بالنيابة', v_req.title, 'inbox'
        FROM portal_users u WHERE u.active AND u.is_away AND u.delegate_to IS NOT NULL
          AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
        ON CONFLICT (id) DO NOTHING;
    END IF;
    IF v_deleg IS NOT NULL THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        VALUES ('ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||v_deleg,
                v_deleg, 'system', 'تفويض: طلب متأخّر بانتظار اعتمادك (بالنيابة)', v_req.title, 'inbox')
        ON CONFLICT (id) DO NOTHING;
    END IF;
    INSERT INTO portal_notifications(id, recipient, type, title, body, link)
      SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||username,
             username, 'system', 'تصعيد SLA: طلب متأخّر', v_req.title, 'inbox'
      FROM portal_users WHERE role = 'admin' AND active = true ON CONFLICT (id) DO NOTHING;

    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_requests SET escalations = escalations + 1,
      escalated_at = coalesce(escalated_at, now()), last_escalation_at = now() WHERE id = v_req.id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_req.id, 'escalated', NULL, 'system', jsonb_build_object('intended', v_intended, 'cycle', v_cycle, 'stage_label', v_stage.stage_label));
    v_cnt := v_cnt + 1;
  END LOOP;
  RETURN v_cnt;
END $fn$;

-- ── (8) المدخل الأول: إنشاء طلب صرف مستقلّ (خارج دورة المشتريات تماماً) ──────
CREATE OR REPLACE FUNCTION portal_create_expense(
    p_beneficiary text, p_amount numeric, p_kind text, p_purpose text,
    p_department_id text, p_need_by date, p_details jsonb DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_id text; v_n int; v_details jsonb := coalesce(p_details,'{}'::jsonb); v_iban text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_create') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF coalesce(trim(p_beneficiary),'') = '' THEN RAISE EXCEPTION 'اسم الجهة/المستفيد مطلوب'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'المبلغ غير صالح'; END IF;
  IF coalesce(trim(p_purpose),'') = '' THEN RAISE EXCEPTION 'الغرض مطلوب'; END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'طريقة صرف غير صالحة'; END IF;
  IF p_department_id IS NULL OR NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = p_department_id) THEN
    RAISE EXCEPTION 'القسم غير صالح'; END IF;
  -- تحقّق بيانات الصرف مبكّراً (نفس قواعد portal_payment_request)
  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
  ELSIF p_kind = 'custody' THEN
    IF coalesce(v_details->>'custody_to','') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = v_details->>'custody_to' AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)'; END IF;
  ELSIF p_kind = 'credit' THEN
    IF (v_details->>'due_date') IS NULL OR (v_details->>'due_date')::date IS NULL THEN
      RAISE EXCEPTION 'تاريخ الاستحقاق مطلوب للصرف الآجل'; END IF;
  END IF;

  v_id := 'REQ-' || to_char(now(),'YYYYMMDD') || '-' || substr(md5(random()::text),1,6);
  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_requests(id, title, department_id, requester, requester_name, req_type, est_total,
      status, phase, beneficiary, expense_method, project, need_by, note, created_by, created_at)
    VALUES (v_id, left(p_purpose,200), p_department_id, v_me,
            (SELECT display_name FROM portal_users WHERE username = v_me), 'direct_expense', p_amount,
            'draft', 'disbursement', p_beneficiary, p_kind, 'صرف مباشر', p_need_by, p_note, v_me, now());
  UPDATE portal_requests SET expense_details = v_details WHERE id = v_id;

  v_n := portal_build_chain(v_id, 'disbursement');
  IF v_n = 0 THEN
    -- لا سلسلة صرف مُعرّفة: مرحلة احتياطية واحدة (اعتماد صرف).
    INSERT INTO portal_approvals(request_id, cycle, seq, stage_label, resolver, role_key, approver)
      VALUES (v_id, 'disbursement', 1, 'اعتماد الصرف', NULL, 'can_approve_disbursement', NULL);
    v_n := 1;
  END IF;
  UPDATE portal_requests SET status = 'in_review', current_seq = 1, updated_at = now(), updated_by = v_me WHERE id = v_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(v_id, 'expense_created', v_me, 'portal',
    jsonb_build_object('beneficiary', p_beneficiary, 'amount', p_amount, 'kind', p_kind, 'stages', v_n));
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'status', 'in_review');
END $fn$;
REVOKE ALL ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text) TO authenticated;

-- ── (9) فتح دفعة الصرف المباشر عند اكتمال السلسلة (مُعتمَدة بالسلسلة) ────────
--   تُنشئ portal_payments بحالة approved_pay (السلسلة كانت الاعتماد)، والبنك ينفّذ.
CREATE OR REPLACE FUNCTION portal_open_direct_payment(p_request_id text, p_last_approver text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_req portal_requests%ROWTYPE; v_details jsonb; v_amt numeric; v_vat numeric;
BEGIN
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id;
  IF v_req.req_type <> 'direct_expense' THEN RETURN; END IF;
  v_details := coalesce(v_req.expense_details, '{}'::jsonb);
  v_vat := portal_setting_num('vat', 15);
  v_amt := round(v_req.est_total * (1 + v_vat/100.0));
  INSERT INTO portal_payments(request_id, kind, amount, custody_to, status, requested_by, approved_by, approved_at, details, created_at)
    VALUES (p_request_id, v_req.expense_method, v_amt,
            nullif(v_details->>'custody_to',''), 'approved_pay', v_req.requester, p_last_approver, now(), v_details, now());
END $fn$;
REVOKE ALL ON FUNCTION portal_open_direct_payment(text,text) FROM PUBLIC, anon;

-- ── (10) portal_payment_transition: دورة الصرف تحلّ محلّ الاعتماد المسطّح ─────
--   عند وجود سلسلة صرف مكتملة (cycle='disbursement')، يُسمح بالتنفيذ مباشرةً من
--   pending_pay/approved_pay (السلسلة كانت الاعتماد)، بفصل مهام: المنفّذ ≠ الطالب ≠
--   أي معتمِد في سلسلة الصرف. الصرف المباشر → closed (لا استلام). الباقي بلا تغيير.
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text,
    p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
  v_req_status text; v_req_phase text; v_req_inst boolean; v_req_type text; v_split boolean; v_multi boolean;
  v_pending int; v_vat numeric; v_agg_max numeric; v_disb_sum numeric; v_merge jsonb := coalesce(p_details, '{}'::jsonb);
  v_has_chain boolean; v_is_direct boolean;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  SELECT status, phase, pay_installments, req_type INTO v_req_status, v_req_phase, v_req_inst, v_req_type
    FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  v_split := EXISTS (SELECT 1 FROM portal_award_lines WHERE request_id = v_pay.request_id);
  v_multi := v_split OR (coalesce(v_req_inst,false) AND NOT v_split);
  v_is_direct := (v_req_type = 'direct_expense');
  v_has_chain := EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = v_pay.request_id AND cycle = 'disbursement');

  IF v_multi THEN
    IF v_req_phase <> 'payment' THEN RAISE EXCEPTION 'حالة الطلب لا تسمح بعملية الصرف'; END IF;
  ELSE
    IF v_req_status IS DISTINCT FROM 'payment_pending' THEN
      RAISE EXCEPTION 'حالة الطلب (%) لا تسمح بعملية الصرف', coalesce(v_req_status,'?');
    END IF;
  END IF;

  IF p_action = 'approve' THEN
    -- عند وجود سلسلة صرف، الاعتماد المسطّح غير مطلوب (السلسلة اعتمدت).
    IF v_has_chain THEN RAISE EXCEPTION 'الصرف مُعتمَد عبر سلسلة الموافقات المالية — نفّذ الصرف مباشرةً'; END IF;
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment,
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status NOT IN ('pending_pay','approved_pay') THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;

    -- ═══ (044) إعادة فتح التعميد للتسعير (مسار الشراء): خلل عروض/أسعار قبل التنفيذ ═══
    IF p_action = 'return' AND p_return_to = 'award' AND NOT v_is_direct THEN
      IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = v_pay.request_id AND status = 'disbursed') THEN
        RAISE EXCEPTION 'تعذّر إعادة فتح التعميد — يوجد صرف منفَّذ بالفعل (المال خرج)';
      END IF;
      PERFORM set_config('app.portal_transition', '1', true);
      UPDATE portal_payments SET status = 'returned', comment = p_comment
        WHERE request_id = v_pay.request_id AND status IN ('pending_pay','approved_pay');
      UPDATE portal_award SET status = 'rejected' WHERE request_id = v_pay.request_id;
      DELETE FROM portal_award_lines WHERE request_id = v_pay.request_id;
      DELETE FROM portal_award_approvals WHERE request_id = v_pay.request_id;
      DELETE FROM portal_po_approvals WHERE request_id = v_pay.request_id;
      DELETE FROM portal_approvals WHERE request_id = v_pay.request_id AND cycle = 'disbursement';
      UPDATE portal_requests SET status = 'pricing', phase = 'pricing', po_issued_by = NULL, po_issued_at = NULL,
             updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      PERFORM set_config('app.portal_transition', '0', true);
      PERFORM portal_audit_write(v_pay.request_id, 'award_reopened', v_me, 'portal',
        jsonb_build_object('from', 'payment', 'reason', p_comment, 'payment_id', p_payment_id));
      RETURN jsonb_build_object('ok', true, 'action', 'reopen', 'status', 'pricing');
    END IF;

    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    IF NOT v_multi THEN
      UPDATE portal_requests SET status = CASE WHEN v_is_direct THEN 'returned' ELSE 'awarded' END,
             updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment, 'multi', v_multi));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    -- بوّابة الحالة: بسلسلة صرف يُسمح من pending_pay/approved_pay؛ بلا سلسلة يلزم approved_pay.
    IF v_has_chain THEN
      IF v_pay.status NOT IN ('pending_pay','approved_pay') THEN RAISE EXCEPTION 'حالة الصرف غير مطابقة'; END IF;
      IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = v_pay.request_id AND cycle = 'disbursement'
                  AND approver = v_me) AND NOT portal_is_admin() THEN
        RAISE EXCEPTION 'من اعتمد الصرف في السلسلة لا ينفّذه (فصل المهام)';
      END IF;
    ELSE
      IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
      IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ طلبته بنفسك (فصل المهام الثلاثي)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now(),
      details = coalesce(details,'{}'::jsonb) || v_merge WHERE id = p_payment_id;
    IF v_split THEN
      SELECT count(*) INTO v_pending FROM (
        SELECT DISTINCT al.offer_id FROM portal_award_lines al WHERE al.request_id = v_pay.request_id
          AND NOT EXISTS (SELECT 1 FROM portal_payments p WHERE p.request_id = al.request_id
                          AND p.award_offer_id = al.offer_id AND p.status = 'disbursed')) q;
      IF v_pending = 0 THEN
        UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      END IF;
    ELSIF coalesce(v_req_inst,false) THEN
      v_vat := portal_setting_num('vat', 15);
      SELECT round(coalesce(winner_total,0) * (1 + v_vat/100.0)) INTO v_agg_max FROM portal_award WHERE request_id = v_pay.request_id AND status = 'approved';
      SELECT coalesce(sum(amount),0) INTO v_disb_sum FROM portal_payments WHERE request_id = v_pay.request_id AND status = 'disbursed';
      IF v_disb_sum >= v_agg_max THEN
        UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
      END IF;
    ELSIF v_is_direct THEN
      -- الصرف المباشر: لا استلام بضاعة → إقفال مباشر.
      UPDATE portal_requests SET status = 'closed', phase = 'closed', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    ELSE
      UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    END IF;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
    jsonb_build_object('payment_id', p_payment_id, 'has_proof', (v_merge ? 'proof_key'), 'multi', v_multi, 'via_chain', v_has_chain));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_transition(bigint,text,text,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint,text,text,text,jsonb) TO authenticated;

-- ── (11) المدخل الثاني: بوّابة الصرف على مسار الشراء (اختيارية بمفتاح) ───────
--   بعد اعتماد أمر الشراء: عند disb_gate_purchase=1 ووجود سلسلة صرف مطابِقة، يدخل
--   الطلب دورة disbursement بدل الانتقال المباشر للدفع المسطّح. وإلا السلوك كما هو.
CREATE OR REPLACE FUNCTION portal_po_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_stage portal_po_approvals%ROWTYPE;
        v_perm boolean; v_remaining int; v_committee jsonb; v_disb_n int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'po_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار اعتماد أمر الشراء'; END IF;
  IF v_req.requester = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;

  SELECT * INTO v_stage FROM portal_po_approvals WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة أمر شراء معلّقة'; END IF;

  IF v_stage.kind = 'committee' THEN
    SELECT value INTO v_committee FROM portal_settings WHERE key = 'committee_members';
    IF NOT ( portal_is_admin()
             OR coalesce((SELECT (permissions ->> 'can_approve_committee')::boolean FROM portal_users WHERE username = v_me), false)
             OR (v_committee IS NOT NULL AND v_committee ? v_me) ) THEN
      RAISE EXCEPTION 'لست عضواً في اللجنة المصغّرة';
    END IF;
  ELSE
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm FROM portal_users WHERE username = v_me;
    IF NOT coalesce(v_perm,false) AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;
  END IF;

  IF NOT portal_is_admin() THEN
    IF EXISTS (SELECT 1 FROM portal_po_approvals WHERE request_id = p_request_id AND approver = v_me AND decision = 'approved') THEN
      RAISE EXCEPTION 'لا تعتمد أكثر من مرحلة في أمر الشراء نفسه (فصل المهام)';
    END IF;
    IF EXISTS (SELECT 1 FROM portal_award WHERE request_id = p_request_id AND awarded_by = v_me) THEN
      RAISE EXCEPTION 'من رسا التعميد لا يعتمد أمر شرائه (فصل المهام)';
    END IF;
  END IF;

  IF p_action IN ('reject','return') AND coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  IF p_action = 'approve' THEN
    UPDATE portal_po_approvals SET decision = 'approved', approver = v_me, comment = p_comment, acted_at = now()
      WHERE request_id = p_request_id AND seq = v_stage.seq;
    SELECT count(*) INTO v_remaining FROM portal_po_approvals WHERE request_id = p_request_id AND decision = 'pending';
    IF v_remaining = 0 THEN
      v_disb_n := 0;
      IF portal_setting_num('disb_gate_purchase', 0) >= 1 THEN
        v_disb_n := portal_build_chain(p_request_id, 'disbursement');
      END IF;
      IF v_disb_n > 0 THEN
        -- بوّابة الصرف المتدرّجة: يدخل الطلب دورة disbursement قبل التنفيذ.
        UPDATE portal_requests SET status = 'in_review', phase = 'disbursement', po_issued_by = v_me, po_issued_at = now(),
               current_seq = 1, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
      ELSE
        -- السلوك القائم: انتقال مباشر لطور الدفع (الاعتماد المسطّح).
        UPDATE portal_requests SET status = 'awarded', phase = 'payment', po_issued_by = v_me, po_issued_at = now(),
               current_seq = 0, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
      END IF;
    ELSE
      UPDATE portal_requests SET current_seq = v_stage.seq + 1, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    END IF;
  ELSE
    UPDATE portal_po_approvals SET decision = CASE p_action WHEN 'reject' THEN 'rejected' ELSE 'returned' END,
           approver = v_me, comment = p_comment, acted_at = now() WHERE request_id = p_request_id AND seq = v_stage.seq;
    UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
    UPDATE portal_requests SET status = 'pricing', phase = 'pricing', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'po_' || p_action, v_me, 'portal', jsonb_build_object('comment', p_comment, 'stage', v_stage.stage_label));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', (SELECT status FROM portal_requests WHERE id = p_request_id));
END $fn$;
REVOKE ALL ON FUNCTION portal_po_transition(text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_po_transition(text,text,text) TO authenticated;

-- ── (12) وظائف الأدوار المالية الخمسة + مفتاح can_approve_disbursement ──────
INSERT INTO portal_jobs(key, title, category, scope, permissions, description, active) VALUES
  ('fin_accountant',   'محاسب (صرف)',        'GA', 'all',
     '{"can_create":true,"can_see_finance":true}'::jsonb, 'يقدّم طلبات الصرف المباشر', true),
  ('fin_accounts_mgr', 'رئيس الحسابات',       'GA', 'all',
     '{"can_approve_disbursement":true,"can_see_finance":true}'::jsonb, 'اعتماد أول للصرف', true),
  ('fin_manager',      'المدير المالي (صرف)', 'GA', 'all',
     '{"can_approve_finance":true,"can_see_finance":true}'::jsonb, 'اعتماد مالي للصرف', true),
  ('bank_officer',     'مسؤول البنك',         'GA', 'all',
     '{"can_disburse":true}'::jsonb, 'تنفيذ الصرف البنكي', true)
ON CONFLICT (key) DO UPDATE SET permissions = portal_jobs.permissions || EXCLUDED.permissions, active = true;

-- ── (13) سلسلة صرف افتراضية قابلة للتحرير في المصمّم (cycle='disbursement') ──
INSERT INTO portal_workflows(id, name, priority, department_id, sector, min_total, max_total, stages, active, cycle)
VALUES ('wf-disb-default', 'سلسلة الصرف الافتراضية', 100, NULL, NULL, 0, NULL,
  '[{"seq":1,"label":"رئيس الحسابات","resolver":"role","role_key":"can_approve_disbursement","sla":24},
    {"seq":2,"label":"المدير المالي","resolver":"role","role_key":"can_approve_finance","sla":24},
    {"seq":3,"label":"المدير العام","resolver":"role","role_key":"can_manage_users","sla":24}]'::jsonb,
  true, 'disbursement')
ON CONFLICT (id) DO NOTHING;

-- تحقّق:
--   SELECT portal_build_chain('<req>','disbursement');   ⇒ عدد مراحل السلسلة
--   SELECT has_function_privilege('anon','portal_create_expense(text,numeric,text,text,text,date,jsonb,text)','EXECUTE'); ⇒ false

-- ════════════════════════════════════════════════════════════════════════
--  Migration 003 — الحوكمة المتبقية (المرحلة 4)
-- ════════════════════════════════════════════════════════════════════════
--  المصدر: «الملف الشامل المتكامل»:
--   • سيناريو 6-4: التأجيل المالي on_hold + الاستئناف (مستثنى من SLA).
--   • باب 5-4: منع التجزئة splitRiskFor (عتبة/نافذة قابلتان للضبط — علم لا منع).
--   • باب 5-2: تصعيد تعارض فصل المهام qualifiedApprover (تفويض ← سلسلة المدراء ← أي مؤهّل).
--   • سيناريو 6-8: سلامة الصرف (آيبان SA+22 مطبَّع، اسم حساب، عهدة بمسؤول، آجل بتاريخ).
--  فرق مقصود موثّق: قاعدة «لا يجمع بين الاعتماد والصرف» مطبّقة أصلاً في المحرّك
--  الحيّ كـmaker-checker صارم على مستوى الصرف (طالب≠معتمِد≠منفّذ) ولا تُعرَّض لمفتاح
--  تعطيل — أقوى من النموذج وبقرار سابق مُختبَر. مفتاحا الضبط المكشوفان:
--  sod_requester_cannot_approve و sod_auto_escalation.
--  آمن لإعادة التشغيل بالكامل (idempotent).
-- ════════════════════════════════════════════════════════════════════════

-- 1) أعمدة جديدة
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS hold_reason TEXT;
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS hold_until DATE;
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS held_by TEXT;
ALTER TABLE portal_payments ADD COLUMN IF NOT EXISTS details JSONB;

-- 2) بذرة الإعدادات الحاكمة (تُدمج المفاتيح الناقصة دون المساس بالموجود)
INSERT INTO portal_settings (key, value)
SELECT 'portal_settings', '{}'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM portal_settings WHERE key = 'portal_settings');

UPDATE portal_settings SET value =
  jsonb_build_object(
    'sla_days', 3, 'vat', 15,
    'split_guard', true, 'split_threshold', 100000, 'split_window_days', 7,
    'sod_requester_cannot_approve', true, 'sod_auto_escalation', true
  ) || coalesce(value, '{}'::jsonb)   -- الموجود يطغى على الافتراضي
WHERE key = 'portal_settings';

-- 3) قارئا إعدادات مساعدان
CREATE OR REPLACE FUNCTION portal_setting_bool(p_key text, p_default boolean)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce((SELECT (value->>p_key)::boolean FROM portal_settings WHERE key='portal_settings'), p_default);
$fn$;
CREATE OR REPLACE FUNCTION portal_setting_num(p_key text, p_default numeric)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce((SELECT (value->>p_key)::numeric FROM portal_settings WHERE key='portal_settings'), p_default);
$fn$;

-- 4) المعتمِد المؤهَّل (باب 5-2): تفويض ← عند تعارض (المعتمِد هو الطالب) تصعيدٌ
--    عبر سلسلة المدراء (manager_user) لأول نشط مؤهَّل بلا تعارض، وإلا أي مؤهَّل
--    نشط. حارس دورات في كلا المسارين.
CREATE OR REPLACE FUNCTION portal_qualified_approver(p_base text, p_requester text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_u text := portal_effective_approver(p_base);
  v_cur text; v_cand text; v_seen text[] := ARRAY[]::text[];
BEGIN
  IF v_u IS NULL THEN RETURN NULL; END IF;
  IF NOT portal_setting_bool('sod_auto_escalation', true) THEN RETURN v_u; END IF;
  IF v_u IS DISTINCT FROM p_requester THEN RETURN v_u; END IF;   -- لا تعارض

  -- (أ) سلسلة المدراء
  v_cur := v_u;
  WHILE v_cur IS NOT NULL AND NOT (v_cur = ANY(v_seen)) LOOP
    v_seen := v_seen || v_cur;
    SELECT manager_user INTO v_cur FROM portal_users WHERE username = v_cur;
    IF v_cur IS NOT NULL THEN
      v_cand := portal_effective_approver(v_cur);
      IF v_cand IS DISTINCT FROM p_requester AND EXISTS (
           SELECT 1 FROM portal_users WHERE username = v_cand AND active
             AND (role='admin' OR coalesce((permissions->>'can_approve_stage')::boolean,false))
         ) THEN
        RETURN v_cand;
      END IF;
    END IF;
  END LOOP;

  -- (ب) أي معتمِد نشط مؤهَّل بلا تعارض (الأدمن أولاً — يكافئ ROOT المرجعي)
  SELECT username INTO v_cand FROM portal_users
    WHERE active AND username IS DISTINCT FROM p_requester
      AND (role='admin' OR coalesce((permissions->>'can_approve_stage')::boolean,false))
    ORDER BY (role='admin') DESC, username ASC LIMIT 1;
  IF v_cand IS NOT NULL THEN RETURN portal_effective_approver(v_cand); END IF;
  RETURN v_u;
END $fn$;

-- 5) قرار المرحلة الأولى — يضيف «التأجيل المالي» (defer) وتصعيد التعارض
--    ومفتاح ضبط فصل المهام. مطابق للسابق فيما عدا ذلك.
CREATE OR REPLACE FUNCTION portal_pr_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL, p_hold_until date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_approvals%ROWTYPE;
  v_pending int; v_next_seq int; v_decision text; v_status text; v_phase text;
  v_ok boolean := false; v_intended text; v_perm boolean;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','defer') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'in_review' THEN RAISE EXCEPTION 'الطلب ليس قيد المراجعة'; END IF;

  SELECT * INTO v_stage FROM portal_approvals
    WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة معلّقة'; END IF;

  IF portal_setting_bool('sod_requester_cannot_approve', true)
     AND v_req.requester = v_me AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)';
  END IF;
  -- فصل المهام متعدّد المراحل: من اعتمد مرحلة سابقة لا يعتمد مرحلة لاحقة لنفس الطلب
  IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = p_request_id
              AND approver = v_me AND decision = 'approved' AND seq < v_stage.seq)
     AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'اعتمدت مرحلة سابقة لهذا الطلب — لا يجوز اعتماد أكثر من مرحلة (فصل المهام)';
  END IF;

  v_intended := portal_resolve_stage(p_request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    -- تصعيد تعارض فصل المهام: إن كان المعتمِد المقصود هو الطالب نفسه، يُحوَّل
    -- الاستحقاق تلقائياً لبديل مؤهَّل (باب 5-2) — فلا يعلق الطلب ولا يُعتمد ذاتياً.
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

  -- التأجيل المالي (سيناريو 6-4): من بوابة التحقق المالي فقط (أو الأدمن).
  -- لا يمسّ سلسلة الموافقات — الطلب يتجمّد على مرحلته ويُستثنى من SLA.
  IF p_action = 'defer' THEN
    IF v_stage.role_key IS DISTINCT FROM 'can_approve_finance' AND NOT portal_is_admin() THEN
      RAISE EXCEPTION 'التأجيل المالي متاح في مرحلة التحقق المالي فقط';
    END IF;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_requests SET status = 'on_hold', hold_reason = p_comment, hold_until = p_hold_until,
           held_by = v_me, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'deferred', v_me, 'portal',
      jsonb_build_object('reason', p_comment, 'until', p_hold_until));
    RETURN jsonb_build_object('ok', true, 'action', 'defer', 'status', 'on_hold');
  END IF;

  v_decision := CASE p_action WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' ELSE 'returned' END;

  SELECT count(*) INTO v_pending FROM portal_approvals WHERE request_id = p_request_id AND decision = 'pending';

  IF p_action = 'approve' THEN
    IF v_pending <= 1 THEN
      v_status := 'pricing'; v_phase := 'pricing'; v_next_seq := v_stage.seq;
    ELSE
      SELECT min(seq) INTO v_next_seq FROM portal_approvals WHERE request_id = p_request_id AND decision = 'pending' AND seq > v_stage.seq;
      v_status := 'in_review'; v_phase := 'requisition';
    END IF;
  ELSIF p_action = 'reject' THEN
    v_status := 'rejected'; v_phase := 'requisition'; v_next_seq := 0;
  ELSE
    v_status := 'returned'; v_phase := 'requisition'; v_next_seq := 0;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);

  UPDATE portal_approvals SET decision = v_decision, approver = v_me, comment = p_comment, acted_at = now(), channel = 'portal'
    WHERE request_id = p_request_id AND seq = v_stage.seq;

  UPDATE portal_requests SET status = v_status, current_seq = coalesce(v_next_seq,0), phase = v_phase, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'stage_' || v_decision, v_me, 'portal', jsonb_build_object('stage', v_stage.stage_label, 'comment', p_comment));

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
                             'finalized', v_status <> 'in_review', 'seq', v_stage.seq);
END $fn$;

-- التوقيع القديم (3 معاملات) يُحذف — البديل أعلاه يغطيه بقيمة افتراضية.
DROP FUNCTION IF EXISTS portal_pr_transition(text, text, text);

-- 6) الاستئناف بعد توفّر السيولة (سيناريو 6-4)
CREATE OR REPLACE FUNCTION portal_resume_hold(p_request_id text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (portal_has_perm('can_disburse') OR portal_has_perm('can_approve_finance') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'استئناف المؤجَّل مالياً متاح للمالية فقط';
  END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'on_hold' THEN RAISE EXCEPTION 'الطلب ليس مؤجَّلاً'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET status = 'in_review', hold_reason = NULL, hold_until = NULL, held_by = NULL,
         updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'resumed', v_me, 'portal',
    jsonb_build_object('comment', coalesce(p_comment, 'تأكيد توفّر السيولة — استئناف')));
  RETURN jsonb_build_object('ok', true, 'status', 'in_review');
END $fn$;

-- 7) مسار البريد: نفس تصعيد التعارض (سطر التحقق فقط تغيّر عن السابق)
--    ملاحظة: لا defer من البريد — قرار مالي يتطلب سياق البوابة.
CREATE OR REPLACE FUNCTION portal_pr_transition_email(p_token text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_tok portal_email_tokens%ROWTYPE;
  v_req portal_requests%ROWTYPE;
  v_stage portal_approvals%ROWTYPE;
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

  SELECT * INTO v_stage FROM portal_approvals WHERE request_id = v_tok.request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','no_pending','code',409); END IF;
  IF v_stage.seq <> v_tok.seq THEN RETURN jsonb_build_object('error','stage_changed','code',409); END IF;

  IF portal_setting_bool('sod_requester_cannot_approve', true)
     AND v_req.requester = v_tok.approver THEN RETURN jsonb_build_object('error','sod','code',403); END IF;
  -- فصل المهام متعدّد المراحل (نفس منطق portal_pr_transition): من اعتمد مرحلة سابقة لا يعتمد لاحقة.
  IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = v_tok.request_id
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
  SELECT count(*) INTO v_pending FROM portal_approvals WHERE request_id = v_tok.request_id AND decision = 'pending';

  IF p_action = 'approve' THEN
    IF v_pending <= 1 THEN v_status := 'pricing'; v_phase := 'pricing'; v_next_seq := v_stage.seq;
    ELSE
      SELECT min(seq) INTO v_next_seq FROM portal_approvals WHERE request_id = v_tok.request_id AND decision = 'pending' AND seq > v_stage.seq;
      v_status := 'in_review'; v_phase := 'requisition';
    END IF;
  ELSIF p_action = 'reject' THEN v_status := 'rejected'; v_phase := 'requisition'; v_next_seq := 0;
  ELSE v_status := 'returned'; v_phase := 'requisition'; v_next_seq := 0;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_approvals SET decision = v_decision, approver = v_tok.approver, comment = p_comment, acted_at = now(), channel = 'email'
    WHERE request_id = v_tok.request_id AND seq = v_stage.seq;
  UPDATE portal_requests SET status = v_status, current_seq = coalesce(v_next_seq,0), phase = v_phase, updated_at = now(), updated_by = v_tok.approver
    WHERE id = v_tok.request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(v_tok.request_id, 'stage_' || v_decision, v_tok.approver, 'email', jsonb_build_object('stage', v_stage.stage_label, 'comment', p_comment));

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
    'finalized', v_status <> 'in_review', 'seq', v_stage.seq,
    'request', jsonb_build_object('id', v_req.id, 'title', v_req.title, 'department_id', v_req.department_id,
                                   'requester', v_req.requester, 'requester_name', v_req.requester_name));
END $fn$;

-- 8) منع التجزئة داخل الإنشاء (باب 5-4): عنقود = هذا الطلب + طلبات نفس القسم
--    غير المرفوضة ضمن ±النافذة؛ يُعلَّم الجميع إذا كان المجموع ≥ العتبة وكلٌّ
--    منفرداً دونها. علمٌ للمعتمِدين لا منع (سلوك النموذج حرفياً).
CREATE OR REPLACE FUNCTION portal_create_request(
    p_title text, p_department_id text, p_priority text, p_items jsonb,
    p_project text, p_need_by date, p_proc_type text DEFAULT 'normal',
    p_justification text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_my_dept text;
  v_dept text;
  v_id text;
  v_item jsonb;
  v_seq int := 0;
  v_est numeric := 0;
  v_name text;
  v_q numeric; v_p numeric;
  v_quotes int;
  v_win_days numeric; v_thr numeric; v_cluster_sum numeric; v_peers int; v_all_below boolean;
  v_split boolean := false;
  MAXQ CONSTANT numeric := 1000000;
  MAXP CONSTANT numeric := 100000000;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (portal_has_perm('can_create') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'رفع الطلبات يتطلّب صلاحية «رفع الطلبات» — راجع الإدارة لإسناد وظيفة';
  END IF;
  IF coalesce(trim(p_title), '') = '' THEN RAISE EXCEPTION 'اكتب وصف الطلب'; END IF;
  IF coalesce(trim(p_project), '') = '' THEN RAISE EXCEPTION 'اسم المشروع مطلوب'; END IF;
  IF p_need_by IS NULL THEN RAISE EXCEPTION 'تاريخ التوريد المطلوب مطلوب'; END IF;
  IF coalesce(p_proc_type,'normal') NOT IN ('normal','single','emergency') THEN
    RAISE EXCEPTION 'نوع شراء غير صالح';
  END IF;
  IF coalesce(p_proc_type,'normal') <> 'normal' AND coalesce(trim(p_justification),'') = '' THEN
    RAISE EXCEPTION 'التبرير مطلوب لهذا النوع من الشراء';
  END IF;

  SELECT department_id INTO v_my_dept FROM portal_users WHERE username = v_me;
  v_dept := CASE
    WHEN portal_is_admin() AND coalesce(p_department_id,'') <> '' THEN p_department_id
    ELSE coalesce(v_my_dept, p_department_id)
  END;
  IF coalesce(v_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم في ملفك — راجع الإدارة'; END IF;
  IF NOT portal_is_admin() AND coalesce(p_department_id,'') <> '' AND p_department_id <> v_dept THEN
    RAISE EXCEPTION 'القطاع يُحدَّد تلقائياً من ملفك — لا يمكن اختيار قسم آخر';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = v_dept AND active) THEN
    RAISE EXCEPTION 'قطاعك مغلق حالياً لاستقبال الطلبات — راجع الإدارة';
  END IF;

  IF jsonb_array_length(coalesce(p_items, '[]'::jsonb)) < 1 THEN RAISE EXCEPTION 'أضِف بنداً واحداً على الأقل'; END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF coalesce(trim(v_item->>'desc'), '') = '' THEN RAISE EXCEPTION 'وصف كل بند مطلوب'; END IF;
    v_q := coalesce((v_item->>'qty')::numeric, 0);
    v_p := coalesce((v_item->>'price')::numeric, 0);
    IF v_q <= 0 OR v_q > MAXQ THEN RAISE EXCEPTION 'كمية غير منطقية في: %', v_item->>'desc'; END IF;
    IF v_p < 0 OR v_p > MAXP THEN RAISE EXCEPTION 'سعر غير منطقي في: %', v_item->>'desc'; END IF;
    v_est := v_est + v_q * v_p;
  END LOOP;

  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    v_quotes := 1;
  ELSE
    SELECT quotes_required INTO v_quotes FROM portal_doa
      WHERE max_value IS NULL OR v_est <= max_value
      ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
    v_quotes := coalesce(v_quotes, 3);
  END IF;

  v_id := 'REQ-' || to_char(now(), 'YYYYMMDD') || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
  SELECT display_name INTO v_name FROM portal_users WHERE username = v_me;

  -- منع التجزئة (قبل الإدراج — العنقود = الأقران + هذا الطلب)
  IF portal_setting_bool('split_guard', true) THEN
    v_thr := portal_setting_num('split_threshold', 100000);
    v_win_days := portal_setting_num('split_window_days', 7);
    SELECT count(*), coalesce(sum(est_total),0), coalesce(bool_and(est_total < v_thr), true)
      INTO v_peers, v_cluster_sum, v_all_below
      FROM portal_requests
      WHERE department_id = v_dept AND status <> 'rejected'
        AND created_at >= now() - make_interval(days => v_win_days::int)
        AND created_at <= now() + make_interval(days => v_win_days::int);
    IF v_peers > 0 AND (v_cluster_sum + v_est) >= v_thr AND v_all_below AND v_est < v_thr THEN
      v_split := true;
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_requests (id, title, department_id, requester, requester_name, priority,
                               est_total, created_by, project, need_by, proc_type, justification, note, quotes_required, split_flag)
    VALUES (v_id, trim(p_title), v_dept, v_me, v_name, coalesce(nullif(p_priority, ''), 'متوسط'),
            v_est, v_me, trim(p_project), p_need_by, coalesce(p_proc_type,'normal'),
            nullif(trim(coalesce(p_justification,'')),''), nullif(trim(coalesce(p_note,'')),''), v_quotes, v_split);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_seq := v_seq + 1;
    INSERT INTO portal_request_items (request_id, seq, description, unit, qty, unit_price)
      VALUES (v_id, v_seq, v_item->>'desc', v_item->>'unit', (v_item->>'qty')::numeric, coalesce((v_item->>'price')::numeric, 0));
  END LOOP;
  PERFORM set_config('app.portal_transition', '0', true);

  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    PERFORM portal_audit_write(v_id, 'proc_type', v_me, 'portal',
      jsonb_build_object('type', p_proc_type, 'justification', p_justification));
  END IF;
  IF v_split THEN
    PERFORM portal_audit_write(v_id, 'split_flag', v_me, 'portal',
      jsonb_build_object('cluster_sum', v_cluster_sum + v_est, 'threshold', v_thr, 'window_days', v_win_days, 'peers', v_peers));
  END IF;

  RETURN portal_submit_request(v_id) || jsonb_build_object('id', v_id, 'quotes_required', v_quotes, 'split_flag', v_split);
END $fn$;

-- 9) سلامة الصرف (سيناريو 6-8): تفاصيل لكل طريقة + تحقّق خادمي صارم.
CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric,
    p_custody_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
  v_iban text; v_details jsonb := coalesce(p_details, '{}'::jsonb);
BEGIN
  IF v_me IS NULL OR NOT (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'نوع صرف غير صالح'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'مبلغ غير صالح'; END IF;

  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
  ELSIF p_kind = 'custody' THEN
    IF coalesce(p_custody_to,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = p_custody_to AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)';
    END IF;
  ELSIF p_kind = 'credit' THEN
    IF (v_details->>'due_date') IS NULL OR (v_details->>'due_date')::date IS NULL THEN
      RAISE EXCEPTION 'تاريخ الاستحقاق مطلوب للصرف الآجل';
    END IF;
  END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'payment' THEN RAISE EXCEPTION 'الطلب ليس جاهزاً للصرف'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details)
    VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb)) RETURNING id INTO v_id;
  UPDATE portal_requests SET status = 'payment_pending', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal', jsonb_build_object('kind', p_kind, 'amount', p_amount));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

-- التوقيع القديم (4 معاملات) يُحذف
DROP FUNCTION IF EXISTS portal_payment_request(text, text, numeric, text);

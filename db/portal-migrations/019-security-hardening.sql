-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 019 — تصليب أمني شامل (من تدقيق عدائي بـ8 وكلاء + تحقّق تنفيذي)
--  تُغلق ثغرات حرجة مؤكَّدة بالتنفيذ الفعلي على قاعدة اختبار حيّة:
--   (أ) نظام الصرف: سقف المبلغ = قيمة التعميد+الضريبة · منع تعدّد الصرف · إعادة فحص حالة الطلب.
--   (ب) دوال SECURITY DEFINER خادمية كانت مكشوفة لـPUBLIC (تزوير اعتماد/حقن تدقيق) → سحب.
--   (ج) حارسا المستخدمين/الضبط كانا يمرّران can_manage_users/company (ترقية ذاتية) → رفض افتراضي.
--   (د) فرض عدد العروض عند التعميد · رفض كمية استلام سالبة · كشف تفتيت شرائح DoA.
--   (هـ) RLS: بوابة مالية على الصرف والموردين (منع كشف الآيبان لأدوار غير مالية).
--  idempotent (CREATE OR REPLACE / DROP POLICY IF EXISTS). شغّلها في Supabase بعد 018.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (ب) سحب الدوال الخادمية من PUBLIC (تُستدعى حصراً بمفتاح service_role) ──
REVOKE ALL ON FUNCTION portal_create_token(text,text,integer,text,numeric) FROM public;
REVOKE ALL ON FUNCTION portal_create_token(text,text,integer,text,numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_create_token(text,text,integer,text,numeric) TO service_role;
REVOKE ALL ON FUNCTION portal_pr_transition_email(text,text,text) FROM public;
REVOKE ALL ON FUNCTION portal_pr_transition_email(text,text,text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_pr_transition_email(text,text,text) TO service_role;
REVOKE ALL ON FUNCTION portal_audit_write(text,text,text,text,jsonb) FROM public;
REVOKE ALL ON FUNCTION portal_audit_write(text,text,text,text,jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_audit_write(text,text,text,text,jsonb) TO service_role;

-- ── (ج) حارس المستخدمين: رفض افتراضي — لا كتابة مباشرة إلا privileged/admin/عبر RPC (علم الانتقال) ──
--  كان يمرّر أي كتابة لحامل can_manage_users → ترقية ذاتية إلى admin ومنح صلاحيات صرف/اعتماد بـPATCH مباشر.
CREATE OR REPLACE FUNCTION portal_users_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  -- حامل can_manage_users (غير أدمن) عبر كتابة مباشرة: يُسمح بغير التصعيد فقط.
  IF portal_has_perm('can_manage_users') THEN
    IF TG_OP <> 'DELETE' THEN
      IF coalesce(NEW.role,'') = 'admin' THEN
        RAISE EXCEPTION 'منح دور الأدمن يتطلّب صلاحية أدمن كاملة';
      END IF;
      IF coalesce(NEW.permissions,'{}'::jsonb) ?| ARRAY['can_manage_users','can_manage_company','can_disburse',
           'can_approve_award','can_approve_finance','can_approve_stage','can_manage_procurement',
           'can_issue_po','can_approve_committee','can_see_finance'] THEN
        RAISE EXCEPTION 'منح صلاحيات اعتماد/صرف/إدارية عبر تعديل المستخدم يتطلّب صلاحية أدمن كاملة';
      END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
  END IF;
  RAISE EXCEPTION 'تعديل المستخدمين أو صلاحياتهم يتطلّب صلاحية «إدارة المستخدمين»';
END $fn$;

-- ── (ج) حارس الضبط: رفض افتراضي — لا كتابة مباشرة إلا privileged/admin/عبر RPC (علم الانتقال) ──
--  كان يمرّر can_manage_users/can_manage_company → تخريب DoA/سلاسل الاعتماد/الإعدادات بـPATCH مباشر متجاوزاً القوائم البيضاء.
CREATE OR REPLACE FUNCTION portal_config_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل إعدادات البوابة يتطلّب صلاحية أدمن (عبر دوال البوابة فقط)';
END $fn$;

-- ── (أ) طلب الصرف: سقف المبلغ + منع التعدّد + فحص الحالة ──
CREATE OR REPLACE FUNCTION portal_payment_request(p_request_id text, p_kind text, p_amount numeric,
    p_custody_to text DEFAULT NULL, p_details jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_id bigint;
  v_iban text; v_details jsonb := coalesce(p_details, '{}'::jsonb);
  v_winner numeric; v_vat numeric; v_max numeric;
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
  IF v_req.phase <> 'payment' OR v_req.status <> 'awarded' THEN RAISE EXCEPTION 'الطلب ليس جاهزاً للصرف'; END IF;

  -- منع تعدّد الصرف: لا يُسمح بأكثر من طلب صرف قائم واحد لكل طلب (يُقصي المرفوض/المُعاد).
  IF EXISTS (SELECT 1 FROM portal_payments WHERE request_id = p_request_id
             AND status IN ('pending_pay','approved_pay','disbursed')) THEN
    RAISE EXCEPTION 'يوجد طلب صرف قائم لهذا الطلب — لا يُسمح بأكثر من صرف واحد';
  END IF;

  -- سقف المبلغ: لا يتجاوز قيمة التعميد شاملةً الضريبة (يمنع صرف مبلغ أكبر من المُعمَّد).
  SELECT winner_total INTO v_winner FROM portal_award WHERE request_id = p_request_id;
  IF v_winner IS NULL OR v_winner <= 0 THEN RAISE EXCEPTION 'لا تعميد مُعتمَد لهذا الطلب'; END IF;
  v_vat := portal_setting_num('vat', 15);
  v_max := round(v_winner * (1 + v_vat/100.0));
  IF p_amount > v_max THEN
    RAISE EXCEPTION 'مبلغ الصرف (%) يتجاوز قيمة التعميد شاملة الضريبة (%)', p_amount, v_max;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_payments(request_id, kind, amount, custody_to, requested_by, details)
    VALUES (p_request_id, p_kind, p_amount, p_custody_to, v_me, nullif(v_details, '{}'::jsonb)) RETURNING id INTO v_id;
  UPDATE portal_requests SET status = 'payment_pending', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'payment_requested', v_me, 'portal', jsonb_build_object('kind', p_kind, 'amount', p_amount));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;

-- ── (أ) انتقال الصرف: إعادة فحص حالة الطلب الأب (يمنع الصرف على طلب مُلغى/مُغلق) ──
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text, p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text; v_req_status text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  -- إعادة فحص حالة الطلب الأب (بقفل): كل عمليات الصرف تتطلّب أن يكون الطلب في payment_pending —
  -- يمنع تنفيذ/اعتماد صرف على صف متبقٍّ بعد إلغاء الطلب أو خروجه من طور الصرف.
  SELECT status INTO v_req_status FROM portal_requests WHERE id = v_pay.request_id FOR UPDATE;
  IF v_req_status IS DISTINCT FROM 'payment_pending' THEN
    RAISE EXCEPTION 'حالة الطلب (%) لا تسمح بعملية الصرف', coalesce(v_req_status,'?');
  END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;
    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ طلبته بنفسك (فصل المهام الثلاثي)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now() WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal', jsonb_build_object('payment_id', p_payment_id));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;
REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text) TO authenticated;

-- ── (د) التعميد: فرض عدد العروض المطلوب (يمنع مصدراً وحيداً متنكّراً كمنافسة) ──
CREATE OR REPLACE FUNCTION portal_award(p_request_id text, p_winner_offer_id bigint, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_offer portal_offers%ROWTYPE;
  v_doa portal_doa%ROWTYPE;
  v_lowest numeric; v_offer_count int;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_manage_procurement') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'pricing' THEN RAISE EXCEPTION 'الطلب ليس في مرحلة التسعير'; END IF;

  SELECT * INTO v_offer FROM portal_offers WHERE id = p_winner_offer_id AND request_id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'العرض غير موجود'; END IF;

  -- فرض عدد العروض حسب DoA/نوع الشراء (كان يُخزَّن ولا يُفرَض).
  SELECT count(*) INTO v_offer_count FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer_count < coalesce(v_req.quotes_required, 1) THEN
    RAISE EXCEPTION 'عدد العروض المُدخَلة (%) أقل من المطلوب (%) — أضِف عروضاً أو استخدم نوع شراء استثنائياً بمبرّر',
      v_offer_count, v_req.quotes_required;
  END IF;

  SELECT min(total) INTO v_lowest FROM portal_offers WHERE request_id = p_request_id;
  IF v_offer.total > v_lowest AND coalesce(trim(p_reason),'') = '' THEN
    RAISE EXCEPTION 'اختيار عرض غير الأقل سعراً يتطلّب مبرّراً موثَّقاً';
  END IF;

  SELECT * INTO v_doa FROM portal_doa WHERE max_value IS NULL OR v_offer.total <= max_value ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'تعذّر تحديد مصفوفة الصلاحيات لهذه القيمة — أضِف قاعدة DoA'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_award(request_id, winner_offer_id, winner_total, award_reason, doa_id, status, awarded_by)
    VALUES (p_request_id, p_winner_offer_id, v_offer.total, p_reason, v_doa.id, 'pending', v_me)
  ON CONFLICT (request_id) DO UPDATE SET winner_offer_id = EXCLUDED.winner_offer_id, winner_total = EXCLUDED.winner_total,
    award_reason = EXCLUDED.award_reason, doa_id = EXCLUDED.doa_id, status = 'pending', awarded_by = EXCLUDED.awarded_by;
  DELETE FROM portal_award_approvals WHERE request_id = p_request_id;
  INSERT INTO portal_award_approvals(request_id, seq, stage_label, role_key, approver)
    VALUES (p_request_id, 1, 'اعتماد التعميد', v_doa.award_role_key, NULL);
  UPDATE portal_requests SET status = 'award_review', phase = 'award', current_seq = 1, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'awarded', v_me, 'portal', jsonb_build_object('supplier', v_offer.supplier_name, 'total', v_offer.total));
  RETURN jsonb_build_object('ok', true, 'status', 'award_review');
END $fn$;

-- ── (د) الاستلام: رفض كمية سالبة (كان يُنقِص المستلَم — تلاعب بالسجل) ──
CREATE OR REPLACE FUNCTION portal_record_receipt(p_request_id text, p_lines jsonb, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_line jsonb;
  v_remaining numeric;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_verify_stock') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.phase <> 'receipt' THEN RAISE EXCEPTION 'الطلب ليس بانتظار استلام'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  FOR v_line IN SELECT * FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) LOOP
    IF coalesce((v_line->>'qty')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'كمية استلام غير صالحة (يجب أن تكون موجبة)';
    END IF;
    UPDATE portal_request_items
      SET received_qty = LEAST(qty, received_qty + (v_line->>'qty')::numeric)
      WHERE id = (v_line->>'item_id')::bigint AND request_id = p_request_id;
  END LOOP;

  INSERT INTO portal_receipts(request_id, received_by, note, lines) VALUES (p_request_id, v_me, p_note, p_lines);
  SELECT sum(GREATEST(qty - received_qty, 0)) INTO v_remaining FROM portal_request_items WHERE request_id = p_request_id;

  IF coalesce(v_remaining, 0) <= 0 THEN
    UPDATE portal_requests SET status = 'closed', phase = 'closed', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    PERFORM portal_audit_write(p_request_id, 'closed', v_me, 'portal', '{}'::jsonb);
  ELSE
    UPDATE portal_requests SET updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'receipt_recorded', v_me, 'portal', jsonb_build_object('note', p_note, 'remaining', v_remaining));
  RETURN jsonb_build_object('ok', true, 'remaining', coalesce(v_remaining,0));
END $fn$;

-- ── (ج/د) محرّر الوظائف: منع صكّ صلاحيات اعتماد/صرف لغير الأدمن + رفع علم الانتقال حول كتابة الضبط ──
CREATE OR REPLACE FUNCTION portal_save_job(p_key text, p_title text, p_category text,
    p_scope text, p_permissions jsonb, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username(); v_holders int; v_k text;
  v_allowed text[] := ARRAY['can_approve_stage','can_approve_award','can_issue_po','can_manage_procurement',
    'can_approve_finance','can_disburse','can_create','can_edit','can_manage_users','can_see_finance',
    'can_verify_stock','can_manage_company','can_approve_committee'];
  v_sensitive text[] := ARRAY['can_manage_users','can_manage_company','can_disburse','can_approve_award',
    'can_approve_finance','can_approve_stage','can_manage_procurement','can_issue_po','can_approve_committee','can_see_finance'];
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'تعديل الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  IF coalesce(trim(p_key),'') = '' OR coalesce(trim(p_title),'') = '' THEN
    RAISE EXCEPTION 'مفتاح الوظيفة واسمها مطلوبان';
  END IF;
  IF p_scope NOT IN ('own','sector','all') THEN RAISE EXCEPTION 'نطاق غير صالح (own/sector/all)'; END IF;
  IF p_key = 'gm' AND NOT (p_permissions = '{}'::jsonb OR p_permissions IS NULL) THEN
    RAISE EXCEPTION 'وظيفة المدير العام محمية — صلاحياتها من دور الأدمن مباشرة';
  END IF;
  FOR v_k IN SELECT jsonb_object_keys(coalesce(p_permissions,'{}'::jsonb)) LOOP
    IF NOT (v_k = ANY(v_allowed)) THEN RAISE EXCEPTION 'مفتاح صلاحية غير معروف: %', v_k; END IF;
  END LOOP;
  -- صلاحيات اعتماد/صرف/إدارية لا يصكّها إلا أدمن حقيقي (كان القيد يقتصر على can_manage_users/company).
  IF NOT (portal_is_admin() OR portal_is_privileged())
     AND (coalesce(p_permissions,'{}'::jsonb) ?| v_sensitive) THEN
    RAISE EXCEPTION 'إنشاء/تعديل وظيفة تمنح صلاحيات اعتماد/صرف/إدارية يتطلّب صلاحية أدمن كاملة';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
  VALUES (p_key, trim(p_title), p_category, p_scope, coalesce(p_permissions,'{}'::jsonb), p_description, true)
  ON CONFLICT (key) DO UPDATE SET title = EXCLUDED.title, category = EXCLUDED.category,
    scope = EXCLUDED.scope, permissions = EXCLUDED.permissions, description = EXCLUDED.description;
  UPDATE portal_users SET permissions = coalesce(p_permissions,'{}'::jsonb) WHERE job_key = p_key;
  GET DIAGNOSTICS v_holders = ROW_COUNT;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_saved', v_me, 'portal',
    jsonb_build_object('job', p_key, 'holders_updated', v_holders));
  RETURN jsonb_build_object('ok', true, 'holders_updated', v_holders);
END $fn$;

-- ── (ج/د) إسناد وظيفة: منع إسناد صلاحيات حسّاسة لغير الأدمن + منع الإسناد الذاتي (فصل المهام) ──
CREATE OR REPLACE FUNCTION portal_apply_job(p_username text, p_job_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_job portal_jobs%ROWTYPE;
  v_user portal_users%ROWTYPE;
  v_new_role text;
  v_other_admins int;
  v_grants_sensitive boolean;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  SELECT * INTO v_job FROM portal_jobs WHERE key = p_job_key AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'وظيفة غير موجودة أو غير مفعّلة'; END IF;

  v_grants_sensitive := (p_job_key = 'gm')
    OR (coalesce(v_job.permissions,'{}'::jsonb) ?| ARRAY['can_manage_users','can_manage_company','can_disburse',
        'can_approve_award','can_approve_finance','can_approve_stage','can_manage_procurement',
        'can_issue_po','can_approve_committee','can_see_finance']);
  IF v_grants_sensitive AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد صلاحيات اعتماد/صرف/إدارية يتطلّب صلاحية أدمن كاملة';
  END IF;
  IF p_username = v_me AND NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'لا يمكنك إسناد وظيفة لنفسك (فصل المهام)';
  END IF;

  SELECT * INTO v_user FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;

  v_new_role := CASE WHEN p_job_key = 'gm' THEN 'admin' ELSE 'user' END;
  IF v_user.role = 'admin' AND v_new_role <> 'admin' THEN
    PERFORM pg_advisory_xact_lock(hashtext('portal_admin_guard'));
    SELECT count(*) INTO v_other_admins FROM portal_users
      WHERE role = 'admin' AND active AND username <> p_username;
    IF v_other_admins = 0 THEN
      RAISE EXCEPTION 'لا يمكن تجريد آخر أدمن نشط من صلاحياته — أسند gm لغيره أولاً';
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET job_key = p_job_key, permissions = v_job.permissions, role = v_new_role
    WHERE username = p_username;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_assigned', v_me, 'portal',
    jsonb_build_object('user', p_username, 'job', p_job_key));
  RETURN jsonb_build_object('ok', true, 'job', p_job_key, 'role', v_new_role);
END $fn$;

-- ── (هـ) RLS: بوابة مالية على قراءة الصرف (كان أي دور all-scope يرى كل الآيبانات) ──
DROP POLICY IF EXISTS "see_by_request" ON portal_payments;
CREATE POLICY "see_by_request" ON portal_payments FOR SELECT TO authenticated
  USING (portal_can_see_request(request_id)
         AND (portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
              OR portal_has_perm('can_disburse') OR portal_is_admin()
              OR EXISTS (SELECT 1 FROM portal_requests r WHERE r.id = request_id AND r.requester = portal_username())));

-- ── (هـ) RLS: تقييد قراءة الموردين (آيبان/سجل تجاري) على المشتريات/المالية/الأدمن ──
DROP POLICY IF EXISTS "auth_all" ON portal_suppliers;
DROP POLICY IF EXISTS "supp_read" ON portal_suppliers;
DROP POLICY IF EXISTS "supp_ins"  ON portal_suppliers;
DROP POLICY IF EXISTS "supp_upd"  ON portal_suppliers;
DROP POLICY IF EXISTS "supp_del"  ON portal_suppliers;
CREATE POLICY "supp_read" ON portal_suppliers FOR SELECT TO authenticated
  USING (portal_has_perm('can_manage_procurement') OR portal_has_perm('can_see_finance')
         OR portal_has_perm('can_manage_users') OR portal_is_admin());
CREATE POLICY "supp_ins" ON portal_suppliers FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "supp_upd" ON portal_suppliers FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "supp_del" ON portal_suppliers FOR DELETE TO authenticated USING (true);

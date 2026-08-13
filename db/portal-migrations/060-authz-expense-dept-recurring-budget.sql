-- ═══════════════════════════════════════════════════════════════════════════
--  060 — إصلاحات من مراجعة Codex المستقلّة (2026-07-28). شغّلها حيّاً بعد 059.
--  ─────────────────────────────────────────────────────────────────────────
--  (AUTHZ-01, HIGH) portal_create_expense كان يقبل أي p_department_id موجود دون
--      ربطه بقسم المُنشئ — فأي حامل can_create ينشئ صرفاً على قسم آخر (سلسلته
--      وميزانيته). الآن يُربَط القسم بالمُستخدم تماماً كـportal_create_request:
--      الأدمن يحدّد أي قسم؛ غير الأدمن يُفرَض قسمه من ملفه (لا سقوط على مُدخَل العميل).
--  (GOV-01, MED) portal_recurring_run كان يُدرِج الطلبات ويبني السلسلة مباشرةً دون
--      فحص الميزانية، فالصرف المتكرّر يفلت من budget_enforce. الآن يفحص كل قالب قبل
--      الإنشاء: عند وجود ميزانية و budget_enforce=1 وتجاوزٍ ⇒ يُتخطّى القالب (مع
--      تقديم next_run وتحذير) بدل إنشاء طلب فوق السقف. تحذيري (=0) لا يمنع.
--  قرارات المالك المثبَّتة (لا تغيير كود): SEC-07 الأدمن يبقى superuser (مُوثَّق)؛
--      SEC-03 يبقى الإدخال اليدوي للآيبان متاحاً (مُوثَّق).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (1) AUTHZ-01: ربط قسم الصرف المباشر بالمُنشئ ────────────────────────────
CREATE OR REPLACE FUNCTION portal_create_expense(
    p_beneficiary text, p_amount numeric, p_kind text, p_purpose text,
    p_department_id text, p_need_by date, p_details jsonb DEFAULT NULL, p_note text DEFAULT NULL,
    p_beneficiary_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_id text; v_n int; v_details jsonb := coalesce(p_details,'{}'::jsonb); v_iban text;
        v_year int := EXTRACT(YEAR FROM now())::int; v_budget numeric; v_committed numeric; v_enforce numeric;
        v_ben portal_beneficiaries%ROWTYPE; v_name text := p_beneficiary;
        v_my_dept text; v_dept text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_create') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;

  -- ربط السجلّ (اختياري): يُفرَض المستفيد المُعتمَد وبياناته البنكية.
  IF p_beneficiary_id IS NOT NULL THEN
    SELECT * INTO v_ben FROM portal_beneficiaries WHERE id = p_beneficiary_id AND active;
    IF NOT FOUND THEN RAISE EXCEPTION 'المستفيد المُحدَّد غير موجود أو غير نشط'; END IF;
    v_name := v_ben.name;
    IF p_kind = 'bank' THEN
      IF v_ben.iban IS NULL THEN RAISE EXCEPTION 'المستفيد المُحدَّد بلا آيبان مُعتمَد — أضِفه في السجلّ أولاً'; END IF;
      v_details := v_details || jsonb_build_object('iban', v_ben.iban, 'account_name', coalesce(v_ben.account_name, v_ben.name));
    END IF;
  END IF;

  IF coalesce(trim(v_name),'') = '' THEN RAISE EXCEPTION 'اسم الجهة/المستفيد مطلوب'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'المبلغ غير صالح'; END IF;
  IF coalesce(trim(p_purpose),'') = '' THEN RAISE EXCEPTION 'الغرض مطلوب'; END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'طريقة صرف غير صالحة'; END IF;

  -- AUTHZ-01: القسم يُربَط بالمُنشئ (نفس منطق portal_create_request حرفياً).
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
  IF coalesce(v_dept,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = v_dept) THEN
    RAISE EXCEPTION 'القسم غير صالح'; END IF;

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
      status, phase, beneficiary, beneficiary_id, expense_method, project, need_by, note, created_by, created_at)
    VALUES (v_id, left(p_purpose,200), v_dept, v_me,
            (SELECT display_name FROM portal_users WHERE username = v_me), 'direct_expense', p_amount,
            'draft', 'disbursement', v_name, p_beneficiary_id, p_kind, 'صرف مباشر', p_need_by, p_note, v_me, now());
  UPDATE portal_requests SET expense_details = v_details WHERE id = v_id;

  -- ضبط الميزانية (Commitment Control): المرتبط يشمل هذا الطلب الآن (052).
  v_enforce := portal_setting_num('budget_enforce', 0);
  SELECT amount INTO v_budget FROM portal_budgets WHERE department_id = v_dept AND fiscal_year = v_year AND active;
  IF v_budget IS NOT NULL THEN
    v_committed := portal_budget_committed(v_dept, v_year);
    IF v_committed > v_budget THEN
      IF v_enforce >= 1 THEN
        RAISE EXCEPTION 'تجاوز ميزانية القسم % لسنة %: المرتبط % يتجاوز السقف %',
          v_dept, v_year, round(v_committed), round(v_budget);
      ELSE
        RAISE WARNING 'تحذير: تجاوز ميزانية القسم % (% > %)', v_dept, round(v_committed), round(v_budget);
      END IF;
    END IF;
  END IF;

  v_n := portal_build_chain(v_id, 'disbursement');
  IF v_n = 0 THEN
    INSERT INTO portal_approvals(request_id, cycle, seq, stage_label, resolver, role_key, approver)
      VALUES (v_id, 'disbursement', 1, 'اعتماد الصرف', NULL, 'can_approve_disbursement', NULL);
    v_n := 1;
  END IF;
  UPDATE portal_requests SET status = 'in_review', current_seq = 1, updated_at = now(), updated_by = v_me WHERE id = v_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(v_id, 'expense_created', v_me, 'portal',
    jsonb_build_object('beneficiary', v_name, 'beneficiary_id', p_beneficiary_id, 'amount', p_amount, 'kind', p_kind, 'stages', v_n));
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'status', 'in_review');
END $fn$;
REVOKE ALL ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text,bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text,bigint) TO authenticated;

-- ── (2) GOV-01: فحص الميزانية في مولّد الصرف المتكرّر ───────────────────────
CREATE OR REPLACE FUNCTION portal_recurring_run()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_t portal_recurring_expenses%ROWTYPE; v_id text; v_n int; v_created int := 0; v_skipped int := 0; v_next date;
        v_reqname text; v_year int; v_budget numeric; v_committed numeric; v_vat numeric; v_prospective numeric;
BEGIN
  v_vat := portal_setting_num('vat', 15);
  FOR v_t IN SELECT * FROM portal_recurring_expenses
      WHERE active AND next_run <= current_date ORDER BY next_run ASC FOR UPDATE
  LOOP
    -- تحقّق أنّ صاحب القالب ما زال نشطاً (وإلا يُتخطّى القالب دون إنشاء)
    SELECT display_name INTO v_reqname FROM portal_users WHERE username = v_t.owner AND active;
    IF NOT FOUND THEN
      v_next := v_t.next_run;
      WHILE v_next <= current_date LOOP v_next := portal_recurring_next(v_next, v_t.frequency); END LOOP;
      UPDATE portal_recurring_expenses SET next_run = v_next, updated_at = now() WHERE id = v_t.id;
      CONTINUE;
    END IF;

    -- GOV-01: فحص الميزانية قبل الإنشاء. عند budget_enforce=1 والتجاوز ⇒ تخطٍّ (لا
    -- إنشاء طلب فوق السقف)؛ نُقدّم next_run ونُحذّر ونُكمل بقية القوالب.
    IF portal_setting_num('budget_enforce', 0) >= 1 THEN
      v_year := EXTRACT(YEAR FROM now())::int;
      SELECT amount INTO v_budget FROM portal_budgets WHERE department_id = v_t.department_id AND fiscal_year = v_year AND active;
      IF v_budget IS NOT NULL THEN
        v_committed := portal_budget_committed(v_t.department_id, v_year);
        v_prospective := v_committed + round(v_t.amount * (1 + v_vat/100.0));
        IF v_prospective > v_budget THEN
          RAISE WARNING 'صرف متكرّر مُتخطّى (تجاوز ميزانية): القسم % قالب # % — المتوقّع % يتجاوز السقف %',
            v_t.department_id, v_t.id, round(v_prospective), round(v_budget);
          v_next := portal_recurring_next(v_t.next_run, v_t.frequency);
          WHILE v_next <= current_date LOOP v_next := portal_recurring_next(v_next, v_t.frequency); END LOOP;
          UPDATE portal_recurring_expenses SET next_run = v_next, updated_at = now() WHERE id = v_t.id;
          v_skipped := v_skipped + 1;
          CONTINUE;
        END IF;
      END IF;
    END IF;

    v_id := 'REQ-' || to_char(now(),'YYYYMMDD') || '-' || substr(md5(random()::text),1,6);
    PERFORM set_config('app.portal_transition', '1', true);
    INSERT INTO portal_requests(id, title, department_id, requester, requester_name, req_type, est_total,
        status, phase, beneficiary, beneficiary_id, expense_method, expense_details, project, need_by, note, created_by, created_at)
      VALUES (v_id, left(v_t.title,200), v_t.department_id, v_t.owner, v_reqname, 'direct_expense', v_t.amount,
              'draft', 'disbursement', v_t.beneficiary, v_t.beneficiary_id, v_t.kind, v_t.details,
              'صرف متكرّر', current_date, 'مولَّد آلياً من قالب #' || v_t.id, v_t.owner, now());

    v_n := portal_build_chain(v_id, 'disbursement');
    IF v_n = 0 THEN
      INSERT INTO portal_approvals(request_id, cycle, seq, stage_label, resolver, role_key, approver)
        VALUES (v_id, 'disbursement', 1, 'اعتماد الصرف', NULL, 'can_approve_disbursement', NULL);
    END IF;
    UPDATE portal_requests SET status = 'in_review', current_seq = 1, updated_at = now(), updated_by = v_t.owner WHERE id = v_id;
    PERFORM set_config('app.portal_transition', '0', true);

    PERFORM portal_audit_write(v_id, 'expense_created', v_t.owner, 'system',
      jsonb_build_object('recurring', true, 'template_id', v_t.id, 'amount', v_t.amount, 'kind', v_t.kind));

    v_next := portal_recurring_next(v_t.next_run, v_t.frequency);
    WHILE v_next <= current_date LOOP v_next := portal_recurring_next(v_next, v_t.frequency); END LOOP;
    UPDATE portal_recurring_expenses
      SET next_run = v_next, last_run_at = now(), runs_count = runs_count + 1, updated_at = now()
      WHERE id = v_t.id;
    v_created := v_created + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'created', v_created, 'skipped_over_budget', v_skipped);
END $fn$;
REVOKE ALL ON FUNCTION portal_recurring_run() FROM anon, PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION portal_recurring_run() TO service_role;

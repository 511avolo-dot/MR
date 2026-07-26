-- ═══════════════════════════════════════════════════════════════════════════
--  052 — ضبط ميزانية الصرف المستقلّ (المرحلة 2-ب): Commitment Control للصرف المباشر
--  ─────────────────────────────────────────────────────────────────────────
--  ضبط الميزانية القائم (031) يحسب المرتبط من التعميدات (مسار الشراء) فقط. الصرف
--  المباشر (050) لا تعميد له، فكان يفلت من الضبط. هذه الهجرة تُدرِج التزامات الصرف
--  المباشر في المرتبط، وتفرض السقف عند الإنشاء (نفس دلالة مفتاح `budget_enforce`:
--  0 = تحذير غير مانع افتراضياً، 1 = منع).
--
--  خامل وآمن: بلا ميزانية معرّفة للقسم/السنة ⇒ لا إنفاذ؛ ومع `budget_enforce=0`
--  لا منع. عدم انحدار على مسار الشراء (المرتبط الإضافي = 0 حين لا صرف مباشر).
--  ⚠️ تُطبَّق حيّاً بعد 051. مدمجة في db/portal-standalone.sql.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (1) توسيع المرتبط ليشمل التزامات الصرف المباشر النشطة ───────────────────
--   التزام الصرف المباشر = مبلغه شاملاً الضريبة ما دام الطلب نشطاً (غير ملغى/مرفوض/مُعاد).
CREATE OR REPLACE FUNCTION portal_budget_committed(p_dept text, p_year int)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    -- (أ) المرتبط من التعميدات (مسار الشراء) — بعملة الأساس (035) بلا تغيير
    COALESCE((SELECT SUM(
        COALESCE((SELECT sum(al.line_total) FROM portal_award_lines al WHERE al.request_id = a.request_id),
                 a.winner_total)
        * (1 + portal_setting_num('vat', 15) / 100.0)
        * portal_currency_rate(r.currency))
      FROM portal_award a
      JOIN portal_requests r ON r.id = a.request_id
      WHERE a.status IN ('pending','approved')
        AND r.department_id = p_dept
        AND EXTRACT(YEAR FROM r.created_at)::int = p_year
        AND coalesce(r.status,'') <> 'cancelled'), 0)
    +
    -- (ب) المرتبط من الصرف المباشر النشط (050) — إضافة هذه الهجرة، بعملة الأساس أيضاً
    COALESCE((SELECT SUM(r.est_total * (1 + portal_setting_num('vat', 15) / 100.0) * portal_currency_rate(r.currency))
      FROM portal_requests r
      WHERE r.req_type = 'direct_expense'
        AND r.department_id = p_dept
        AND EXTRACT(YEAR FROM r.created_at)::int = p_year
        AND coalesce(r.status,'') NOT IN ('cancelled','rejected','returned')), 0);
$fn$;
REVOKE ALL ON FUNCTION portal_budget_committed(text, int) FROM anon, authenticated, PUBLIC;

-- ── (2) فرض السقف عند إنشاء الصرف المباشر ──────────────────────────────────
--   يُعاد تعريف portal_create_expense (نسخة 050) بإضافة فحص الميزانية بعد بناء
--   السلسلة: عند budget_enforce=1 ووجود ميزانية معرّفة، يُمنع تجاوز المرتبط (شاملاً
--   هذا الطلب) للسقف — الدالة ذرّية فالمنع يُرجِع الطلب كأنه لم يُنشأ.
CREATE OR REPLACE FUNCTION portal_create_expense(
    p_beneficiary text, p_amount numeric, p_kind text, p_purpose text,
    p_department_id text, p_need_by date, p_details jsonb DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_id text; v_n int; v_details jsonb := coalesce(p_details,'{}'::jsonb); v_iban text;
        v_year int := EXTRACT(YEAR FROM now())::int; v_budget numeric; v_committed numeric; v_enforce numeric;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_create') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF coalesce(trim(p_beneficiary),'') = '' THEN RAISE EXCEPTION 'اسم الجهة/المستفيد مطلوب'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'المبلغ غير صالح'; END IF;
  IF coalesce(trim(p_purpose),'') = '' THEN RAISE EXCEPTION 'الغرض مطلوب'; END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'طريقة صرف غير صالحة'; END IF;
  IF p_department_id IS NULL OR NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = p_department_id) THEN
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
      status, phase, beneficiary, expense_method, project, need_by, note, created_by, created_at)
    VALUES (v_id, left(p_purpose,200), p_department_id, v_me,
            (SELECT display_name FROM portal_users WHERE username = v_me), 'direct_expense', p_amount,
            'draft', 'disbursement', p_beneficiary, p_kind, 'صرف مباشر', p_need_by, p_note, v_me, now());
  UPDATE portal_requests SET expense_details = v_details WHERE id = v_id;

  -- ضبط الميزانية (Commitment Control): المرتبط يشمل هذا الطلب الآن.
  v_enforce := portal_setting_num('budget_enforce', 0);
  SELECT amount INTO v_budget FROM portal_budgets WHERE department_id = p_department_id AND fiscal_year = v_year AND active;
  IF v_budget IS NOT NULL THEN
    v_committed := portal_budget_committed(p_department_id, v_year);
    IF v_committed > v_budget THEN
      IF v_enforce >= 1 THEN
        RAISE EXCEPTION 'تجاوز ميزانية القسم % لسنة %: المرتبط % يتجاوز السقف %',
          p_department_id, v_year, round(v_committed), round(v_budget);
      ELSE
        RAISE WARNING 'تحذير: تجاوز ميزانية القسم % (% > %)', p_department_id, round(v_committed), round(v_budget);
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
    jsonb_build_object('beneficiary', p_beneficiary, 'amount', p_amount, 'kind', p_kind, 'stages', v_n));
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'status', 'in_review');
END $fn$;
REVOKE ALL ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text) TO authenticated;

-- تحقّق:
--   SELECT portal_budget_committed('GA', EXTRACT(YEAR FROM now())::int);  -- يشمل الصرف المباشر الآن

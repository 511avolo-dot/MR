-- ═══════════════════════════════════════════════════════════════════════════
--  055 — الصرف المتكرّر/المجدوَل (Recurring Expenses) — المرحلة 3-ب (الإنتاجية)
--  ─────────────────────────────────────────────────────────────────────────
--  الرواتب/الإيجارات/الاشتراكات صرف دوري ثابت. بدل إنشاء طلب صرف يدوياً كل شهر،
--  يُعرَّف **قالب متكرّر** (مستفيد/قسم/مبلغ/طريقة/تكرار/موعد التالي)، ومولّد مجدوَل
--  يُنشئ طلب صرف مباشراً في كل استحقاق ويمرّره بسلسلة الموافقات المالية القائمة.
--
--  المبدأ: **إعادة استخدام محرّك الصرف (050) لا استنساخه.** القالب يُتحقَّق منه عند
--  الحفظ (نفس دلالات portal_create_expense: bank⇒آيبان+حساب، custody⇒مستخدم نشط،
--  ربط مستفيد يفرض بياناته البنكية)، والمولّد يُدرِج الطلب بهوية **صاحب القالب** ثم
--  يبني دورة `disbursement` عبر portal_build_chain — فترث كل الحوكمة (فصل المهام،
--  المعتمِد المؤهَّل، الميزانية، idempotency الصرف). المولّد خادميّ (service_role)
--  يُستدعى من نفس عامل الكرون (portal-outbox-drain) كـ portal_run_sla.
--
--  حماية الفيضان: عند تأخّر المولّد، يُنشأ **طلب واحد فقط** لكل قالب في كل تشغيل،
--  ويُقدَّم next_run لأوّل موعد مستقبلي (تُتخطّى المواعيد الفائتة بلا تكرار).
--  ⚠️ تُطبَّق حيّاً بعد 054. idempotent — مدمجة في portal-standalone.sql.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (1) جدول القوالب المتكرّرة ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_recurring_expenses (
  id             BIGSERIAL PRIMARY KEY,
  title          TEXT NOT NULL,
  department_id  TEXT NOT NULL REFERENCES portal_departments(id),
  beneficiary    TEXT NOT NULL,
  beneficiary_id BIGINT REFERENCES portal_beneficiaries(id),
  amount         NUMERIC NOT NULL CHECK (amount > 0),
  kind           TEXT NOT NULL CHECK (kind IN ('bank','custody')),
  details        JSONB NOT NULL DEFAULT '{}'::jsonb,
  frequency      TEXT NOT NULL CHECK (frequency IN ('weekly','monthly','quarterly','yearly')),
  next_run       DATE NOT NULL,
  owner          TEXT NOT NULL,       -- هوية صاحب الطلب المُولَّد (requester)
  active         BOOLEAN NOT NULL DEFAULT true,
  last_run_at    TIMESTAMPTZ,
  runs_count     INT NOT NULL DEFAULT 0,
  created_by     TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_portal_recurring_due ON portal_recurring_expenses(active, next_run);

ALTER TABLE portal_recurring_expenses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_recurring_read ON portal_recurring_expenses;
CREATE POLICY portal_recurring_read ON portal_recurring_expenses FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement'));
REVOKE ALL ON portal_recurring_expenses FROM anon, PUBLIC;
GRANT  SELECT ON portal_recurring_expenses TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_recurring_expenses TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_recurring_expenses_id_seq TO service_role;

-- ── (2) حساب الموعد التالي حسب التكرار ──────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_recurring_next(p_from date, p_freq text) RETURNS date
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_freq
    WHEN 'weekly'    THEN p_from + INTERVAL '7 day'
    WHEN 'monthly'   THEN p_from + INTERVAL '1 month'
    WHEN 'quarterly' THEN p_from + INTERVAL '3 month'
    WHEN 'yearly'    THEN p_from + INTERVAL '1 year'
    ELSE p_from + INTERVAL '1 month' END::date;
$$;
REVOKE ALL ON FUNCTION portal_recurring_next(date, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_recurring_next(date, text) TO authenticated;

-- ── (3) حفظ/تحديث قالب (أدمن/مالية/مشتريات) — يتحقّق كـ portal_create_expense ─
CREATE OR REPLACE FUNCTION portal_recurring_save(
    p_id bigint, p_title text, p_department_id text, p_amount numeric, p_kind text,
    p_details jsonb, p_frequency text, p_next_run date, p_beneficiary_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_details jsonb := coalesce(p_details,'{}'::jsonb); v_iban text;
        v_ben portal_beneficiaries%ROWTYPE; v_benef text := nullif(trim(coalesce(p_details->>'beneficiary','')),''); v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بإدارة الصرف المتكرّر';
  END IF;
  IF coalesce(trim(p_title),'') = '' THEN RAISE EXCEPTION 'عنوان القالب مطلوب'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'المبلغ غير صالح'; END IF;
  IF p_kind NOT IN ('bank','custody') THEN RAISE EXCEPTION 'طريقة صرف غير مدعومة للتكرار (bank أو custody)'; END IF;
  IF p_frequency NOT IN ('weekly','monthly','quarterly','yearly') THEN RAISE EXCEPTION 'تكرار غير صالح'; END IF;
  IF p_next_run IS NULL THEN RAISE EXCEPTION 'موعد التشغيل التالي مطلوب'; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = p_department_id) THEN RAISE EXCEPTION 'القسم غير صالح'; END IF;

  -- ربط المستفيد (اختياري): يفرض الاسم وللبنكي الآيبان/الحساب المُعتمَد (نمط 053).
  IF p_beneficiary_id IS NOT NULL THEN
    SELECT * INTO v_ben FROM portal_beneficiaries WHERE id = p_beneficiary_id AND active;
    IF NOT FOUND THEN RAISE EXCEPTION 'المستفيد المُحدَّد غير موجود أو غير نشط'; END IF;
    v_benef := v_ben.name;
    IF p_kind = 'bank' THEN
      IF v_ben.iban IS NULL THEN RAISE EXCEPTION 'المستفيد المُحدَّد بلا آيبان مُعتمَد'; END IF;
      v_details := v_details || jsonb_build_object('iban', v_ben.iban, 'account_name', coalesce(v_ben.account_name, v_ben.name));
    END IF;
  END IF;
  IF coalesce(trim(v_benef),'') = '' THEN RAISE EXCEPTION 'اسم المستفيد مطلوب'; END IF;

  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
  ELSE  -- custody
    IF coalesce(v_details->>'custody_to','') = '' OR NOT EXISTS (SELECT 1 FROM portal_users WHERE username = v_details->>'custody_to' AND active) THEN
      RAISE EXCEPTION 'حدّد مسؤول العهدة (مستخدم نشط)';
    END IF;
  END IF;
  v_details := v_details - 'beneficiary';  -- الاسم يُخزَّن بعموده لا في details

  IF p_id IS NULL THEN
    INSERT INTO portal_recurring_expenses(title, department_id, beneficiary, beneficiary_id, amount, kind, details, frequency, next_run, owner, created_by)
      VALUES (trim(p_title), p_department_id, v_benef, p_beneficiary_id, p_amount, p_kind, v_details, p_frequency, p_next_run, v_me, v_me)
      RETURNING id INTO v_id;
  ELSE
    UPDATE portal_recurring_expenses SET
        title = trim(p_title), department_id = p_department_id, beneficiary = v_benef, beneficiary_id = p_beneficiary_id,
        amount = p_amount, kind = p_kind, details = v_details, frequency = p_frequency, next_run = p_next_run, updated_at = now()
      WHERE id = p_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'القالب غير موجود'; END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_recurring_save(bigint,text,text,numeric,text,jsonb,text,date,bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_recurring_save(bigint,text,text,numeric,text,jsonb,text,date,bigint) TO authenticated;

-- ── (4) تفعيل/تعطيل/حذف قالب (أدمن/مالية) ──────────────────────────────────
CREATE OR REPLACE FUNCTION portal_recurring_set_active(p_id bigint, p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح'; END IF;
  UPDATE portal_recurring_expenses SET active = coalesce(p_active,true), updated_at = now() WHERE id = p_id RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'القالب غير موجود'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'active', p_active);
END $fn$;
REVOKE ALL ON FUNCTION portal_recurring_set_active(bigint, boolean) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_recurring_set_active(bigint, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION portal_recurring_delete(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username();
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'حذف القالب صلاحية مالية/أدمن'; END IF;
  DELETE FROM portal_recurring_expenses WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'deleted', true);
END $fn$;
REVOKE ALL ON FUNCTION portal_recurring_delete(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_recurring_delete(bigint) TO authenticated;

-- ── (5) المولّد المجدوَل (خادميّ فقط) — يُنشئ طلب صرف لكل قالب مستحقّ ─────────
--   يُدرِج بهوية صاحب القالب (requester=owner) ثم يبني دورة الصرف. طلب واحد لكل
--   قالب في كل تشغيل؛ next_run يُقدَّم لأوّل موعد مستقبلي (لا فيضان للمواعيد الفائتة).
CREATE OR REPLACE FUNCTION portal_recurring_run()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_t portal_recurring_expenses%ROWTYPE; v_id text; v_n int; v_created int := 0; v_next date;
        v_reqname text;
BEGIN
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

    -- تقديم next_run لأوّل موعد مستقبلي + تسجيل التشغيل
    v_next := portal_recurring_next(v_t.next_run, v_t.frequency);
    WHILE v_next <= current_date LOOP v_next := portal_recurring_next(v_next, v_t.frequency); END LOOP;
    UPDATE portal_recurring_expenses
      SET next_run = v_next, last_run_at = now(), runs_count = runs_count + 1, updated_at = now()
      WHERE id = v_t.id;
    v_created := v_created + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'created', v_created);
END $fn$;
REVOKE ALL ON FUNCTION portal_recurring_run() FROM anon, PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION portal_recurring_run() TO service_role;

-- تحقّق:
--   SELECT portal_recurring_run();   -- (service_role) ينشئ طلبات للقوالب المستحقّة

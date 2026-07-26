-- ═══════════════════════════════════════════════════════════════════════════
--  053 — سجلّ المستفيدين (Beneficiary Master) + ضبط تغيير آيبان المستفيد
--  ─────────────────────────────────────────────────────────────────────────
--  إقفال المرحلة 2 (الحوكمة المالية المتقدّمة). المدخل الأول (الصرف المباشر، 050)
--  كان يخزّن اسم المستفيد نصّاً حرّاً وآيبانه في expense_details — فلا سجلّ موحَّد
--  للمستفيدين ولا ضبط على بياناتهم البنكية (نفس ناقل الاحتيال الذي عالجناه للموردين
--  في 032). هذه الهجرة تُضيف:
--    (1) جدول `portal_beneficiaries` (سجلّ موحَّد: اسم/نوع/آيبان/حساب/ضريبي/تواصل).
--    (2) ضبط تغيير الآيبان بنمط 032 حرفياً: حارس + سلسلة طلب/اعتماد/رفض بفصل مهام +
--        أثر تدقيق دائم — محكوم بنفس المفتاح `iban_change_control` (ضبط موحَّد لكل
--        البيانات البنكية: موردون ومستفيدون).
--    (3) ربط الصرف المباشر بالسجلّ: عمود `portal_requests.beneficiary_id` +
--        `portal_create_expense` يقبل `p_beneficiary_id` اختيارياً؛ عند تحديده
--        **يُفرَض آيبان السجلّ المُعتمَد** (يتجاوز آيبان العميل) — كسب وقاية الاحتيال.
--
--  خامل وآمن: `p_beneficiary_id` اختياري (NULL = سلوك 050/052 الحرّ بلا انحدار)؛ وضبط
--  الآيبان لا يُفرَض إلا عند `iban_change_control=1`. idempotent — مدمجة في standalone.
--  ⚠️ تُطبَّق حيّاً بعد 052.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (1) جدول سجلّ المستفيدين ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_beneficiaries (
  id            BIGSERIAL PRIMARY KEY,
  name          TEXT NOT NULL,
  btype         TEXT NOT NULL DEFAULT 'company',   -- company | individual | government
  iban          TEXT,                              -- SA + 22 رقماً (يُتحقَّق عبر RPC)
  account_name  TEXT,
  tax_no        TEXT,
  contact       TEXT,
  note          TEXT,
  active        BOOLEAN NOT NULL DEFAULT true,
  created_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_portal_beneficiaries_active ON portal_beneficiaries(active, name);

ALTER TABLE portal_beneficiaries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_beneficiaries_read ON portal_beneficiaries;
CREATE POLICY portal_beneficiaries_read ON portal_beneficiaries FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')
  OR portal_has_perm('can_create'));
REVOKE ALL ON portal_beneficiaries FROM anon, PUBLIC;
GRANT  SELECT ON portal_beneficiaries TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_beneficiaries TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_beneficiaries_id_seq TO service_role;

-- ── (2) عمود ربط الصرف المباشر بالسجلّ (اختياري، لا انحدار) ─────────────────
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS beneficiary_id BIGINT REFERENCES portal_beneficiaries(id);

-- ── (3) جدول طلبات تغيير آيبان المستفيد (أثر تدقيق دائم) — نمط 032 ───────────
CREATE TABLE IF NOT EXISTS portal_beneficiary_iban_changes (
  id             BIGSERIAL PRIMARY KEY,
  beneficiary_id BIGINT NOT NULL REFERENCES portal_beneficiaries(id) ON DELETE CASCADE,
  old_iban       TEXT,
  new_iban       TEXT NOT NULL,
  reason         TEXT,
  status         TEXT NOT NULL DEFAULT 'pending',   -- pending | approved | rejected
  requested_by   TEXT,
  requested_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_by     TEXT,
  decided_at     TIMESTAMPTZ,
  decision_note  TEXT
);
CREATE INDEX IF NOT EXISTS idx_portal_ben_iban_chg ON portal_beneficiary_iban_changes(beneficiary_id, status);

ALTER TABLE portal_beneficiary_iban_changes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_ben_iban_chg_read ON portal_beneficiary_iban_changes;
CREATE POLICY portal_ben_iban_chg_read ON portal_beneficiary_iban_changes FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement'));
REVOKE ALL ON portal_beneficiary_iban_changes FROM anon, PUBLIC;
GRANT  SELECT ON portal_beneficiary_iban_changes TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_beneficiary_iban_changes TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_beneficiary_iban_changes_id_seq TO service_role;

-- ── (4) حارس آيبان المستفيد: يمنع التغيير المباشر عند التفعيل (إلا عبر الاعتماد) ─
CREATE OR REPLACE FUNCTION portal_beneficiary_iban_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NEW.iban IS DISTINCT FROM OLD.iban
     AND portal_setting_num('iban_change_control', 0) >= 1
     AND coalesce(current_setting('app.iban_change_approved', true), '') <> '1'
  THEN
    RAISE EXCEPTION 'تغيير آيبان المستفيد يتطلّب طلب اعتماد مزدوج (فصل مهام) — عبر دوال البوابة';
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_portal_beneficiary_iban_guard ON portal_beneficiaries;
CREATE TRIGGER trg_portal_beneficiary_iban_guard
  BEFORE UPDATE ON portal_beneficiaries
  FOR EACH ROW EXECUTE FUNCTION portal_beneficiary_iban_guard();
-- تُستدعى عبر المُشغِّل فقط — يُسحَب anon/PUBLIC ويبقى authenticated (كي لا تُكسر S7؛ نمط حارس المورد).
REVOKE ALL ON FUNCTION portal_beneficiary_iban_guard() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_beneficiary_iban_guard() TO authenticated;

-- ── (5) حفظ/تحديث مستفيد (أدمن/مالية/مشتريات) ──────────────────────────────
--   الإنشاء: كل الحقول (بما فيها الآيبان) حرّة. التحديث: الحقول غير البنكية حرّة؛
--   تغيير الآيبان يمرّ عبر الحارس (يُمنَع مباشرةً عند التفعيل → استخدم مسار الطلب).
CREATE OR REPLACE FUNCTION portal_beneficiary_save(
    p_id bigint, p_name text, p_type text DEFAULT 'company', p_iban text DEFAULT NULL,
    p_account_name text DEFAULT NULL, p_tax_no text DEFAULT NULL, p_contact text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_iban text; v_id bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بإدارة سجلّ المستفيدين';
  END IF;
  IF coalesce(trim(p_name),'') = '' THEN RAISE EXCEPTION 'اسم المستفيد مطلوب'; END IF;
  IF coalesce(p_type,'company') NOT IN ('company','individual','government') THEN RAISE EXCEPTION 'نوع مستفيد غير صالح'; END IF;
  IF p_iban IS NOT NULL AND trim(p_iban) <> '' THEN
    v_iban := upper(regexp_replace(p_iban, '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO portal_beneficiaries(name, btype, iban, account_name, tax_no, contact, note, created_by)
      VALUES (trim(p_name), coalesce(p_type,'company'), v_iban, nullif(trim(coalesce(p_account_name,'')),''),
              nullif(trim(coalesce(p_tax_no,'')),''), nullif(trim(coalesce(p_contact,'')),''),
              nullif(trim(coalesce(p_note,'')),''), v_me)
      RETURNING id INTO v_id;
  ELSE
    -- التحديث لا يمسّ الآيبان هنا (يمرّ عبر مسار الاعتماد إن تغيّر عند التفعيل).
    UPDATE portal_beneficiaries SET
        name = trim(p_name), btype = coalesce(p_type, btype),
        account_name = nullif(trim(coalesce(p_account_name,'')),''),
        tax_no = nullif(trim(coalesce(p_tax_no,'')),''),
        contact = nullif(trim(coalesce(p_contact,'')),''),
        note = nullif(trim(coalesce(p_note,'')),''),
        iban = coalesce(v_iban, iban),   -- إن مرّ آيبان جديد يفعّل الحارس؛ NULL يُبقي القائم
        updated_at = now()
      WHERE id = p_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'المستفيد غير موجود'; END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_beneficiary_save(bigint,text,text,text,text,text,text,text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_beneficiary_save(bigint,text,text,text,text,text,text,text) TO authenticated;

-- ── (6) حذف/تعطيل مستفيد (أدمن/مالية) — منع الحذف الصلب لمن له طلبات ─────────
CREATE OR REPLACE FUNCTION portal_beneficiary_delete(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_used int;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'حذف المستفيد صلاحية مالية/أدمن';
  END IF;
  SELECT count(*) INTO v_used FROM portal_requests WHERE beneficiary_id = p_id;
  IF v_used > 0 THEN
    -- سلامة التدقيق: لا حذف صلب لمن له طلبات صرف → تعطيل فقط.
    UPDATE portal_beneficiaries SET active = false, updated_at = now() WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'disabled', true, 'reason', 'له طلبات صرف — عُطِّل بدل الحذف');
  END IF;
  DELETE FROM portal_beneficiaries WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'deleted', true);
END $fn$;
REVOKE ALL ON FUNCTION portal_beneficiary_delete(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_beneficiary_delete(bigint) TO authenticated;

-- ── (7) طلب تغيير آيبان المستفيد (لا يُطبَّق فوراً) — نمط 032 ────────────────
CREATE OR REPLACE FUNCTION portal_beneficiary_iban_request(p_beneficiary_id bigint, p_new_iban text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_old text; v_new text; v_cid bigint;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بطلب تغيير الآيبان';
  END IF;
  v_new := upper(regexp_replace(coalesce(p_new_iban,''), '\s+', '', 'g'));
  IF v_new !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
  SELECT iban INTO v_old FROM portal_beneficiaries WHERE id = p_beneficiary_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستفيد غير موجود'; END IF;
  IF v_old IS NOT NULL AND upper(regexp_replace(v_old,'\s+','','g')) = v_new THEN
    RAISE EXCEPTION 'الآيبان الجديد مطابق للحالي — لا تغيير';
  END IF;
  IF EXISTS (SELECT 1 FROM portal_beneficiary_iban_changes WHERE beneficiary_id = p_beneficiary_id AND status = 'pending') THEN
    RAISE EXCEPTION 'يوجد طلب تغيير معلّق لهذا المستفيد — يُبتّ فيه أولاً';
  END IF;
  INSERT INTO portal_beneficiary_iban_changes(beneficiary_id, old_iban, new_iban, reason, requested_by)
    VALUES (p_beneficiary_id, v_old, v_new, p_reason, v_me) RETURNING id INTO v_cid;
  RETURN jsonb_build_object('ok', true, 'change_id', v_cid, 'status', 'pending');
END $fn$;
REVOKE ALL ON FUNCTION portal_beneficiary_iban_request(bigint, text, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_beneficiary_iban_request(bigint, text, text) TO authenticated;

-- ── (8) اعتماد التغيير (مالية/أدمن) — فصل مهام: المعتمِد ≠ الطالب ─────────────
CREATE OR REPLACE FUNCTION portal_beneficiary_iban_approve(p_change_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_chg portal_beneficiary_iban_changes%ROWTYPE;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'اعتماد تغيير الآيبان صلاحية مالية/أدمن';
  END IF;
  SELECT * INTO v_chg FROM portal_beneficiary_iban_changes WHERE id = p_change_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب التغيير غير موجود'; END IF;
  IF v_chg.status <> 'pending' THEN RAISE EXCEPTION 'الطلب ليس معلّقاً (%).', v_chg.status; END IF;
  IF v_chg.requested_by IS NOT NULL AND v_chg.requested_by = v_me THEN
    RAISE EXCEPTION 'فصل المهام: طالب التغيير لا يعتمده';
  END IF;
  PERFORM set_config('app.iban_change_approved', '1', true);
  UPDATE portal_beneficiaries SET iban = v_chg.new_iban, updated_at = now() WHERE id = v_chg.beneficiary_id;
  PERFORM set_config('app.iban_change_approved', '0', true);
  UPDATE portal_beneficiary_iban_changes
    SET status = 'approved', decided_by = v_me, decided_at = now() WHERE id = p_change_id;
  RETURN jsonb_build_object('ok', true, 'status', 'approved', 'beneficiary_id', v_chg.beneficiary_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_beneficiary_iban_approve(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_beneficiary_iban_approve(bigint) TO authenticated;

-- ── (9) رفض التغيير (مالية/أدمن) ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_beneficiary_iban_reject(p_change_id bigint, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_st text;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'رفض تغيير الآيبان صلاحية مالية/أدمن';
  END IF;
  SELECT status INTO v_st FROM portal_beneficiary_iban_changes WHERE id = p_change_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب التغيير غير موجود'; END IF;
  IF v_st <> 'pending' THEN RAISE EXCEPTION 'الطلب ليس معلّقاً'; END IF;
  UPDATE portal_beneficiary_iban_changes
    SET status = 'rejected', decided_by = v_me, decided_at = now(), decision_note = p_note WHERE id = p_change_id;
  RETURN jsonb_build_object('ok', true, 'status', 'rejected');
END $fn$;
REVOKE ALL ON FUNCTION portal_beneficiary_iban_reject(bigint, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_beneficiary_iban_reject(bigint, text) TO authenticated;

-- ── (10) ربط الصرف المباشر بالسجلّ: portal_create_expense يقبل p_beneficiary_id ─
--   يُعاد تعريف نسخة 052 (مع فحص الميزانية محفوظاً حرفياً) بإضافة معامل تاسع اختياري
--   `p_beneficiary_id`: عند تحديده يُفرَض السجلّ المُعتمَد (الاسم، وللبنكي: الآيبان/الحساب
--   يتجاوزان قيم العميل) — كسب وقاية الاحتيال. NULL = السلوك الحرّ القائم (لا انحدار).
DROP FUNCTION IF EXISTS portal_create_expense(text,numeric,text,text,text,date,jsonb,text);
CREATE OR REPLACE FUNCTION portal_create_expense(
    p_beneficiary text, p_amount numeric, p_kind text, p_purpose text,
    p_department_id text, p_need_by date, p_details jsonb DEFAULT NULL, p_note text DEFAULT NULL,
    p_beneficiary_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_id text; v_n int; v_details jsonb := coalesce(p_details,'{}'::jsonb); v_iban text;
        v_year int := EXTRACT(YEAR FROM now())::int; v_budget numeric; v_committed numeric; v_enforce numeric;
        v_ben portal_beneficiaries%ROWTYPE; v_name text := p_beneficiary;
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
      status, phase, beneficiary, beneficiary_id, expense_method, project, need_by, note, created_by, created_at)
    VALUES (v_id, left(p_purpose,200), p_department_id, v_me,
            (SELECT display_name FROM portal_users WHERE username = v_me), 'direct_expense', p_amount,
            'draft', 'disbursement', v_name, p_beneficiary_id, p_kind, 'صرف مباشر', p_need_by, p_note, v_me, now());
  UPDATE portal_requests SET expense_details = v_details WHERE id = v_id;

  -- ضبط الميزانية (Commitment Control): المرتبط يشمل هذا الطلب الآن (052).
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
    jsonb_build_object('beneficiary', v_name, 'beneficiary_id', p_beneficiary_id, 'amount', p_amount, 'kind', p_kind, 'stages', v_n));
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'status', 'in_review');
END $fn$;
REVOKE ALL ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text,bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text,bigint) TO authenticated;

-- تحقّق:
--   SELECT portal_beneficiary_save(NULL,'شركة نور','company','SA0000000000000000000001','حساب نور');
--   SELECT has_function_privilege('anon','portal_create_expense(text,numeric,text,text,text,date,jsonb,text,bigint)','EXECUTE'); ⇒ false

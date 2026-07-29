-- ═══════════════════════════════════════════════════════════════════════════
--  062 — المستندات الداعمة للصرف المباشر: نموذج مستندات مُطبَّع + تدفّق مسودّة→رفع→تقديم
--  (متطلّب المالك الإلزامي 2026-07-28). شغّلها حيّاً بعد 061 — **بعد إذن المالك الصريح فقط**.
--  ─────────────────────────────────────────────────────────────────────────
--  المبدأ: لا يُقدَّم طلب صرف مباشر (خارج دورة المشتريات) إلى سلسلة الاعتماد إلا بعد
--  التحقّق **خادميّاً** من وجود مستند داعم واحد صالح ونشط على الأقل. لا نُنشئ طلباً
--  مُقدَّماً ثم نرفع؛ بل: مسودّة → رفع مستندات على المسودّة → تقديم (يتحقّق) → بناء السلسلة.
--
--  النموذج مُطبَّع وغير قابل للتغيير (immutable) ومُصدَّر (versioned):
--   • جدول portal_request_documents (عدّة مستندات، أنواع، إصدارات، تدقيق، صلاحية).
--   • قبل التقديم: للمُقدِّم إضافة/إزالة. بعد التقديم: لا حذف/استبدال صامت — الإرجاع
--     يسمح بإصدار جديد مع بقاء القديم مرئيّاً في التاريخ.
--   • الملفات المدعومة للمعاينة الآمنة داخليّاً: PDF / JPEG / PNG فقط.
--
--  ضوابط تعويضية (قرار المالك المقبول): الآيبان اليدوي (بلا مستفيد معتمَد) يُوسَم
--  «يدوي — غير مُختار من سجلّ المستفيدين» ويُسجَّل مُدخِله ووقته وسببه.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── (1) الجدول المُطبَّع ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_request_documents (
  id                 BIGSERIAL PRIMARY KEY,
  request_id         TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  payment_id         BIGINT REFERENCES portal_payments(id),        -- عند كونه خاصّاً بدفعة
  document_type      TEXT NOT NULL CHECK (document_type IN (
                       'quotation','supplier_invoice','progress_claim','purchase_order',
                       'contract','advance_payment','receipt','beneficiary_bank','memo','other')),
  title              TEXT,
  description        TEXT,
  storage_key        TEXT NOT NULL,
  original_file_name TEXT,
  mime_type          TEXT NOT NULL CHECK (mime_type IN ('application/pdf','image/jpeg','image/png')),
  size_bytes         BIGINT CHECK (size_bytes IS NULL OR size_bytes >= 0),
  checksum           TEXT,
  uploaded_by        TEXT NOT NULL,
  uploaded_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  source_stage       TEXT,
  version            INT NOT NULL DEFAULT 1,
  supersedes_id      BIGINT REFERENCES portal_request_documents(id),
  active             BOOLEAN NOT NULL DEFAULT true,   -- false = void/مُستبدَل
  voided_by          TEXT,
  voided_at          TIMESTAMPTZ,
  void_reason        TEXT,
  -- «أخرى» تتطلّب وصفاً
  CONSTRAINT reqdoc_other_desc CHECK (document_type <> 'other' OR coalesce(trim(description),'') <> '')
);
CREATE INDEX IF NOT EXISTS ix_reqdoc_request ON portal_request_documents(request_id);
CREATE INDEX IF NOT EXISTS ix_reqdoc_payment ON portal_request_documents(payment_id);
CREATE INDEX IF NOT EXISTS ix_reqdoc_active  ON portal_request_documents(request_id, active);

ALTER TABLE portal_request_documents ENABLE ROW LEVEL SECURITY;
-- قراءة مُنطاقة برؤية الطلب الأب (لا كتابة مباشرة — كلّها عبر RPC ذرّية).
DROP POLICY IF EXISTS portal_reqdoc_read ON portal_request_documents;
CREATE POLICY portal_reqdoc_read ON portal_request_documents FOR SELECT
  USING (portal_can_see_request(request_id));
REVOKE ALL ON portal_request_documents FROM anon, PUBLIC;
GRANT  SELECT ON portal_request_documents TO authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_request_documents TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_request_documents_id_seq TO service_role, authenticated;

-- ── (2) حارس عدم التغيير (immutable إلا عبر RPC ترفع علم الانتقال) ───────────
--  يمنع UPDATE/DELETE المباشر (حتى بامتياز) ما لم يكن ضمن RPC (app.portal_transition=1).
--  الإصدار الجديد = صفّ جديد؛ الإبطال = UPDATE(active=false) عبر RPC فقط. لا حذف بعد التقديم.
CREATE OR REPLACE FUNCTION portal_reqdoc_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $g$
BEGIN
  IF current_setting('app.portal_transition', true) = '1' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  RAISE EXCEPTION 'مستندات الطلب غير قابلة للتعديل المباشر — استخدم دوال RPC (إضافة/إزالة مسودّة/استبدال بإصدار)';
END $g$;
DROP TRIGGER IF EXISTS trg_portal_reqdoc_guard ON portal_request_documents;
CREATE TRIGGER trg_portal_reqdoc_guard BEFORE UPDATE OR DELETE ON portal_request_documents
  FOR EACH ROW EXECUTE FUNCTION portal_reqdoc_guard();
REVOKE ALL ON FUNCTION portal_reqdoc_guard() FROM anon, PUBLIC;

-- ── (3) إعدادات: إلزام مستند الصرف المباشر (افتراضي 1 = مُفعَّل بطلب المالك) ──
--   وحدّ حجم الملف (بايت) = 10MiB مطابقةً لحدّ _file-guard.js (نقطة الرفع الوحيدة) — لا فجوة بين
--   حدّ القاعدة وحدّ الحارس. **ملاحظة (Codex round-3):** أُسقِط مفتاح `payment_docs_required` من هذه
--   الهجرة لأنّه كان إعداداً بلا إنفاذ (لا مسار دفع يقرؤه) — مضلِّل. يُضاف في هجرة لاحقة مع إنفاذه الفعلي
--   على مسار الدفع (القسم H)، لا كإعداد صوريّ.
UPDATE portal_settings
   SET value = value
     || jsonb_build_object('expense_docs_required', coalesce((value->>'expense_docs_required')::int, 1))
     || jsonb_build_object('doc_max_bytes',        coalesce((value->>'doc_max_bytes')::bigint, 10485760))
 WHERE key = 'portal_settings';

-- ── (4) مسودّة صرف مباشر (لا سلسلة، لا تقديم) — نسخة من portal_create_expense بلا بناء سلسلة ─
--   يشمل: ربط القسم بالمُنشئ (نشط) + المستفيد + آيبان + الضابط التعويضي للآيبان اليدوي.
CREATE OR REPLACE FUNCTION portal_create_expense_draft(
    p_beneficiary text, p_amount numeric, p_kind text, p_purpose text,
    p_department_id text, p_need_by date, p_details jsonb DEFAULT NULL, p_note text DEFAULT NULL,
    p_beneficiary_id bigint DEFAULT NULL, p_iban_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_id text; v_details jsonb := coalesce(p_details,'{}'::jsonb); v_iban text;
        v_ben portal_beneficiaries%ROWTYPE; v_name text := p_beneficiary; v_my_dept text; v_dept text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_create') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_beneficiary_id IS NOT NULL THEN
    SELECT * INTO v_ben FROM portal_beneficiaries WHERE id = p_beneficiary_id AND active;
    IF NOT FOUND THEN RAISE EXCEPTION 'المستفيد المُحدَّد غير موجود أو غير نشط'; END IF;
    v_name := v_ben.name;
    IF p_kind = 'bank' THEN
      IF v_ben.iban IS NULL THEN RAISE EXCEPTION 'المستفيد المُحدَّد بلا آيبان مُعتمَد'; END IF;
      v_details := v_details || jsonb_build_object('iban', v_ben.iban, 'account_name', coalesce(v_ben.account_name, v_ben.name), 'iban_source', 'master');
    END IF;
  END IF;
  IF coalesce(trim(v_name),'') = '' THEN RAISE EXCEPTION 'اسم الجهة/المستفيد مطلوب'; END IF;
  IF coalesce(p_amount,0) <= 0 THEN RAISE EXCEPTION 'المبلغ غير صالح'; END IF;
  IF coalesce(trim(p_purpose),'') = '' THEN RAISE EXCEPTION 'الغرض مطلوب'; END IF;
  IF p_kind NOT IN ('bank','custody','credit') THEN RAISE EXCEPTION 'طريقة صرف غير صالحة'; END IF;
  SELECT department_id INTO v_my_dept FROM portal_users WHERE username = v_me;
  IF portal_is_admin() THEN v_dept := coalesce(nullif(p_department_id,''), v_my_dept);
  ELSE
    IF coalesce(v_my_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم في ملفك — راجع الإدارة'; END IF;
    IF coalesce(p_department_id,'') <> '' AND p_department_id <> v_my_dept THEN
      RAISE EXCEPTION 'القسم يُحدَّد تلقائياً من ملفك — لا يمكن اختيار قسم آخر'; END IF;
    v_dept := v_my_dept;
  END IF;
  IF coalesce(v_dept,'') = '' OR NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = v_dept AND active) THEN
    RAISE EXCEPTION 'القسم غير صالح أو مُغلَق'; END IF;
  IF p_kind = 'bank' THEN
    v_iban := upper(regexp_replace(coalesce(v_details->>'iban',''), '\s+', '', 'g'));
    IF v_iban !~ '^SA\d{22}$' THEN RAISE EXCEPTION 'آيبان غير صحيح — الصيغة: SA + 22 رقماً'; END IF;
    IF coalesce(trim(v_details->>'account_name'),'') = '' THEN RAISE EXCEPTION 'اسم الحساب البنكي مطلوب'; END IF;
    v_details := v_details || jsonb_build_object('iban', v_iban);
    -- الضابط التعويضي (SEC-03): آيبان يدوي (بلا سجلّ) = وسم + مُدخِل + وقت + سبب إلزامي.
    IF p_beneficiary_id IS NULL THEN
      IF coalesce(trim(p_iban_reason),'') = '' THEN
        RAISE EXCEPTION 'الآيبان اليدوي (بلا مستفيد معتمَد) يتطلّب سبباً مُوثّقاً'; END IF;
      v_details := v_details || jsonb_build_object(
        'iban_source','manual','iban_entered_by',v_me,'iban_entered_at',now(),'iban_manual_reason',p_iban_reason);
    END IF;
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
      status, phase, beneficiary, beneficiary_id, expense_method, expense_details, project, need_by, note, created_by, created_at)
    VALUES (v_id, left(p_purpose,200), v_dept, v_me,
            (SELECT display_name FROM portal_users WHERE username = v_me), 'direct_expense', p_amount,
            'draft', 'disbursement', v_name, p_beneficiary_id, p_kind, v_details, 'صرف مباشر', p_need_by, p_note, v_me, now());
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(v_id, 'expense_draft_created', v_me, 'portal',
    jsonb_build_object('amount', p_amount, 'kind', p_kind,
      'iban_source', coalesce(v_details->>'iban_source','n/a')));
  IF (v_details->>'iban_source') = 'manual' THEN
    PERFORM portal_audit_write(v_id, 'manual_iban_entered', v_me, 'portal',
      jsonb_build_object('reason', p_iban_reason, 'entered_by', v_me));
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'status', 'draft');
END $fn$;
REVOKE ALL ON FUNCTION portal_create_expense_draft(text,numeric,text,text,text,date,jsonb,text,bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_create_expense_draft(text,numeric,text,text,text,date,jsonb,text,bigint,text) TO authenticated;

-- ── (5) إرفاق مستند بمسودّة (أو مستند خاصّ بدفعة) ───────────────────────────
CREATE OR REPLACE FUNCTION portal_attach_document(
    p_request_id text, p_document_type text, p_storage_key text, p_mime_type text,
    p_title text DEFAULT NULL, p_description text DEFAULT NULL, p_original_file_name text DEFAULT NULL,
    p_size_bytes bigint DEFAULT NULL, p_checksum text DEFAULT NULL,
    p_payment_id bigint DEFAULT NULL, p_source_stage text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_pay portal_payments%ROWTYPE; v_id bigint; v_max bigint;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF NOT portal_can_see_request(p_request_id) THEN RAISE EXCEPTION 'لا صلاحية على هذا الطلب'; END IF;
  IF coalesce(trim(p_storage_key),'') = '' THEN RAISE EXCEPTION 'مفتاح التخزين مطلوب'; END IF;
  IF p_payment_id IS NULL THEN
    -- مستندات الطلب: المُقدّم/can_edit/أدمن + مسودّة/مُعاد فقط + المفتاح ضمن مجال reqdoc لهذا الطلب.
    IF NOT (v_req.requester = v_me OR portal_has_perm('can_edit') OR portal_is_admin()) THEN
      RAISE EXCEPTION 'لا صلاحية لإرفاق مستندات لهذا الطلب'; END IF;
    IF v_req.status NOT IN ('draft','returned') THEN
      RAISE EXCEPTION 'لا يمكن إضافة مستندات إلا في المسودّة أو الطلب المُعاد'; END IF;
    -- (Codex round-3) ربط المفتاح بمجال مستندات هذا الطلب — يمنع تسجيل مفتاح مُلفَّق لطلب آخر.
    IF p_storage_key NOT LIKE 'docs/reqdoc/' || p_request_id || '/%' THEN
      RAISE EXCEPTION 'مفتاح التخزين لا يقع ضمن مجال مستندات هذا الطلب (docs/reqdoc/<request_id>/…)'; END IF;
  ELSE
    -- (Codex round-3) مستندات الدفعة: الدفعة تخصّ هذا الطلب فعلاً + صلاحية مالية/صرف + المفتاح ضمن مجال الطلب.
    SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'الدفعة غير موجودة'; END IF;
    IF v_pay.request_id <> p_request_id THEN RAISE EXCEPTION 'الدفعة لا تخصّ هذا الطلب'; END IF;
    -- (Codex round-4) can_see_finance للقراءة فقط — إرفاق مستند دفعة يتطلّب can_disburse (أو أدمن)، ولا يُعدَّل مستند دفعة مُبطَلة.
    IF NOT (portal_has_perm('can_disburse') OR portal_is_admin()) THEN
      RAISE EXCEPTION 'لا صلاحية لإرفاق مستند دفعة (يتطلّب can_disburse)'; END IF;
    IF coalesce(v_pay.status,'') = 'voided' THEN RAISE EXCEPTION 'لا تُعدَّل مستندات دفعة مُبطَلة'; END IF;
    IF p_storage_key NOT LIKE 'docs/%/' || p_request_id || '/%' THEN
      RAISE EXCEPTION 'مفتاح التخزين لا يقع ضمن مجال هذا الطلب'; END IF;
  END IF;
  IF p_document_type NOT IN ('quotation','supplier_invoice','progress_claim','purchase_order','contract','advance_payment','receipt','beneficiary_bank','memo','other') THEN
    RAISE EXCEPTION 'نوع مستند غير صالح'; END IF;
  IF p_document_type = 'other' AND coalesce(trim(p_description),'') = '' THEN
    RAISE EXCEPTION 'وصف المستند مطلوب عند اختيار «أخرى»'; END IF;
  IF p_mime_type NOT IN ('application/pdf','image/jpeg','image/png') THEN
    RAISE EXCEPTION 'صيغة غير مدعومة للمعاينة — حوّل الملف إلى PDF (المدعوم: PDF/JPEG/PNG)'; END IF;
  v_max := portal_setting_num('doc_max_bytes', 10485760);
  IF p_size_bytes IS NOT NULL AND p_size_bytes > v_max THEN
    RAISE EXCEPTION 'حجم الملف يتجاوز الحدّ (% بايت)', v_max; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_request_documents(request_id, payment_id, document_type, title, description,
      storage_key, original_file_name, mime_type, size_bytes, checksum, uploaded_by, source_stage)
    VALUES (p_request_id, p_payment_id, p_document_type, p_title, p_description,
      p_storage_key, p_original_file_name, p_mime_type, p_size_bytes, p_checksum, v_me,
      coalesce(p_source_stage, v_req.status))
    RETURNING id INTO v_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'document_uploaded', v_me, 'portal',
    jsonb_build_object('doc_id', v_id, 'type', p_document_type, 'mime', p_mime_type, 'payment_id', p_payment_id));
  RETURN jsonb_build_object('ok', true, 'doc_id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION portal_attach_document(text,text,text,text,text,text,text,bigint,text,bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_attach_document(text,text,text,text,text,text,text,bigint,text,bigint,text) TO authenticated;

-- ── (6) إزالة مستند (قبل التقديم فقط — مسودّة) ──────────────────────────────
CREATE OR REPLACE FUNCTION portal_remove_document(p_doc_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_doc portal_request_documents%ROWTYPE; v_req portal_requests%ROWTYPE; v_del bigint;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_doc FROM portal_request_documents WHERE id = p_doc_id FOR UPDATE;   -- قفل يُسلسِل الحذف المتزامن
  IF NOT FOUND THEN RAISE EXCEPTION 'المستند غير موجود'; END IF;
  -- (Codex round-4) مستندات الدفعة تُدار عبر مسار مالي منفصل — لا يحذفها المُقدّم/المحرّر.
  IF v_doc.payment_id IS NOT NULL THEN RAISE EXCEPTION 'مستندات الدفعة تُدار عبر مسار مالي منفصل'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = v_doc.request_id FOR UPDATE;
  -- (Codex round-3) الحذف الصلب في المسودّة فقط — بعد الإرجاع يُستبدَل بإصدار جديد (يبقى القديم مرئيّاً).
  IF v_req.status <> 'draft' THEN
    RAISE EXCEPTION 'لا يُحذف مستند إلا في المسودّة — بعد الإرجاع استخدم الاستبدال بإصدار جديد (يبقى القديم)'; END IF;
  IF NOT (v_doc.uploaded_by = v_me OR v_req.requester = v_me OR portal_is_admin()) THEN
    RAISE EXCEPTION 'لا صلاحية لحذف هذا المستند'; END IF;
  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_request_documents WHERE id = p_doc_id RETURNING id INTO v_del;   -- (Codex round-4) تدقيق واحد لحذف فعليّ واحد
  PERFORM set_config('app.portal_transition', '0', true);
  IF v_del IS NULL THEN RAISE EXCEPTION 'المستند أُزيل بالفعل — أعد التحميل'; END IF;
  PERFORM portal_audit_write(v_doc.request_id, 'document_removed', v_me, 'portal',
    jsonb_build_object('doc_id', p_doc_id, 'type', v_doc.document_type));
  RETURN jsonb_build_object('ok', true);
END $fn$;
REVOKE ALL ON FUNCTION portal_remove_document(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_remove_document(bigint) TO authenticated;

-- ── (7) استبدال مستند بإصدار جديد (للطلب المُعاد) — القديم يبقى مرئيّاً (active=false) ─
CREATE OR REPLACE FUNCTION portal_replace_document(
    p_doc_id bigint, p_storage_key text, p_mime_type text,
    p_title text DEFAULT NULL, p_description text DEFAULT NULL, p_original_file_name text DEFAULT NULL,
    p_size_bytes bigint DEFAULT NULL, p_checksum text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_old portal_request_documents%ROWTYPE; v_req portal_requests%ROWTYPE; v_new bigint; v_max bigint; v_claimed bigint;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_old FROM portal_request_documents WHERE id = p_doc_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستند غير موجود'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = v_old.request_id FOR UPDATE;
  -- (Codex round-3) الاستبدال حصراً على الطلب المُعاد (returned) — لا تغيير للدليل بعد الاعتماد/الدفع/الإقفال.
  IF v_req.status <> 'returned' THEN
    RAISE EXCEPTION 'لا يُستبدَل المستند إلا للطلب المُعاد (returned) — الدليل المُعتمَد ثابت'; END IF;
  -- (Codex round-4) مستندات الدفعة (payment_id) دليل ماليّ — لا يستبدلها المُقدّم/المحرّر عبر هذا المسار.
  IF v_old.payment_id IS NOT NULL THEN RAISE EXCEPTION 'مستندات الدفعة تُدار عبر مسار مالي منفصل'; END IF;
  IF NOT (v_req.requester = v_me OR portal_has_perm('can_edit') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'لا صلاحية لاستبدال هذا المستند'; END IF;
  IF p_mime_type NOT IN ('application/pdf','image/jpeg','image/png') THEN
    RAISE EXCEPTION 'صيغة غير مدعومة — حوّل إلى PDF'; END IF;
  IF p_storage_key NOT LIKE 'docs/reqdoc/' || v_old.request_id || '/%' THEN
    RAISE EXCEPTION 'مفتاح التخزين لا يقع ضمن مجال مستندات هذا الطلب'; END IF;
  v_max := portal_setting_num('doc_max_bytes', 10485760);
  IF p_size_bytes IS NOT NULL AND p_size_bytes > v_max THEN RAISE EXCEPTION 'حجم الملف يتجاوز الحدّ'; END IF;
  PERFORM set_config('app.portal_transition', '1', true);
  -- (Codex round-3) مطالبة ذرّية بالمصدر النشط فقط — يمنع تفرّع النسخ عند النقر المزدوج/إعادة المحاولة.
  UPDATE portal_request_documents SET active = false, voided_by = v_me, voided_at = now(), void_reason = 'مُستبدَل بإصدار أحدث'
    WHERE id = p_doc_id AND active RETURNING id INTO v_claimed;
  IF v_claimed IS NULL THEN
    RAISE EXCEPTION 'المستند غير نشط أو استُبدِل بالفعل — أعد التحميل'; END IF;
  INSERT INTO portal_request_documents(request_id, payment_id, document_type, title, description,
      storage_key, original_file_name, mime_type, size_bytes, checksum, uploaded_by, source_stage, version, supersedes_id)
    VALUES (v_old.request_id, v_old.payment_id, v_old.document_type, coalesce(p_title, v_old.title), coalesce(p_description, v_old.description),
      p_storage_key, p_original_file_name, p_mime_type, p_size_bytes, p_checksum, v_me, v_req.status, v_old.version + 1, v_old.id)
    RETURNING id INTO v_new;
  PERFORM set_config('app.portal_transition', '0', true);
  PERFORM portal_audit_write(v_old.request_id, 'document_replaced', v_me, 'portal',
    jsonb_build_object('old_doc_id', p_doc_id, 'new_doc_id', v_new, 'version', v_old.version + 1));
  RETURN jsonb_build_object('ok', true, 'doc_id', v_new, 'version', v_old.version + 1);
END $fn$;
REVOKE ALL ON FUNCTION portal_replace_document(bigint,text,text,text,text,text,bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_replace_document(bigint,text,text,text,text,text,bigint,text) TO authenticated;

-- ── (8) تقديم مسودّة الصرف — يتحقّق ≥1 مستند نشط ثم يبني السلسلة (كـ portal_create_expense) ─
CREATE OR REPLACE FUNCTION portal_submit_expense(p_request_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_n int; v_docs int;
        v_year int; v_budget numeric; v_committed numeric; v_enforce numeric; v_ben portal_beneficiaries%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.req_type <> 'direct_expense' THEN RAISE EXCEPTION 'هذه الدالة للصرف المباشر فقط'; END IF;
  -- (Codex round-3) مسار مُوحَّد مُبوَّب بالمستندات للتقديم وإعادة التقديم بعد الإرجاع.
  IF v_req.status NOT IN ('draft','returned') THEN RAISE EXCEPTION 'الطلب ليس مسودّة/مُعاداً (الحالة: %)', v_req.status; END IF;
  -- (Codex round-4/R1) سلطة التقديم = المُقدّم أو الأدمن فقط (فصلها عن can_edit الذي يعدّل المحتوى نيابةً).
  IF NOT (v_req.requester = v_me OR portal_is_admin()) THEN
    RAISE EXCEPTION 'التقديم يقتصر على مُقدّم الطلب أو الأدمن'; END IF;
  -- (Codex round-4) السنة المالية من created_at (اتّساق مع portal_budget_committed) لا now() — يمنع اختلاف عبر السنة.
  v_year := EXTRACT(YEAR FROM v_req.created_at)::int;

  -- (Codex round-4) إعادة التحقّق من المستفيد المربوط وقت التقديم (قد يُعطَّل/يتغيّر آيبانه بعد الإنشاء).
  IF v_req.beneficiary_id IS NOT NULL THEN
    SELECT * INTO v_ben FROM portal_beneficiaries WHERE id = v_req.beneficiary_id FOR UPDATE;
    IF NOT FOUND OR NOT v_ben.active THEN RAISE EXCEPTION 'المستفيد المربوط غير نشط — حدِّث الطلب قبل التقديم'; END IF;
    IF v_req.expense_method = 'bank' THEN
      IF v_ben.iban IS NULL THEN RAISE EXCEPTION 'المستفيد المربوط بلا آيبان مُعتمَد'; END IF;
      PERFORM set_config('app.portal_transition','1',true);
      UPDATE portal_requests SET expense_details = coalesce(expense_details,'{}'::jsonb)
        || jsonb_build_object('iban', v_ben.iban, 'account_name', coalesce(v_ben.account_name, v_ben.name), 'iban_source','master')
        WHERE id = p_request_id;
      PERFORM set_config('app.portal_transition','0',true);
    END IF;
  END IF;

  -- (A) التحقّق الإلزامي: ≥1 مستند داعم نشط عند تفعيل الإلزام (افتراضي 1).
  IF portal_setting_num('expense_docs_required', 1) >= 1 THEN
    SELECT count(*) INTO v_docs FROM portal_request_documents
      WHERE request_id = p_request_id AND active AND payment_id IS NULL;
    IF v_docs < 1 THEN
      RAISE EXCEPTION 'لا يمكن تقديم طلب الصرف بلا مستند داعم واحد صالح على الأقل';
    END IF;
  END IF;

  -- (budget) قفل + فحص (نفس 061)
  PERFORM pg_advisory_xact_lock(hashtext('portal_budget:' || v_req.department_id || ':' || v_year));
  v_enforce := portal_setting_num('budget_enforce', 0);
  SELECT amount INTO v_budget FROM portal_budgets WHERE department_id = v_req.department_id AND fiscal_year = v_year AND active;
  IF v_budget IS NOT NULL THEN
    -- (Codex round-3) المسوّدات مُستثناة من المرتبط؛ نضيف هذا الطلب صراحةً عند التقديم (بعملة الأساس شاملاً الضريبة).
    v_committed := portal_budget_committed(v_req.department_id, v_year)
                 + v_req.est_total * (1 + portal_setting_num('vat',15)/100.0) * portal_currency_rate(v_req.currency);
    IF v_committed > v_budget THEN
      IF v_enforce >= 1 THEN RAISE EXCEPTION 'تجاوز ميزانية القسم % لسنة %: المرتبط % يتجاوز السقف %',
        v_req.department_id, v_year, round(v_committed), round(v_budget);
      ELSE RAISE WARNING 'تحذير: تجاوز ميزانية القسم % (% > %)', v_req.department_id, round(v_committed), round(v_budget); END IF;
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  -- (Codex round-4) إبطال رموز الاعتماد بالبريد القديمة قبل إعادة بناء السلسلة (يمنع رابطاً قديماً يعتمد دون مراجعة الأدلّة الجديدة).
  DELETE FROM portal_email_tokens WHERE request_id = p_request_id;
  v_n := portal_build_chain(p_request_id, 'disbursement');
  IF v_n = 0 THEN
    INSERT INTO portal_approvals(request_id, cycle, seq, stage_label, resolver, role_key, approver)
      VALUES (p_request_id, 'disbursement', 1, 'اعتماد الصرف', NULL, 'can_approve_disbursement', NULL);
    v_n := 1;
  END IF;
  -- (Codex round-4) ضبط الطور disbursement صراحةً (المُعاد من الدفع قد يكون phase=payment) كي تستنتج
  -- portal_pr_transition/portal_run_sla الدورة الصحيحة (disbursement) لا need.
  UPDATE portal_requests SET status = 'in_review', phase = 'disbursement', current_seq = 1, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'expense_submitted', v_me, 'portal',
    jsonb_build_object('stages', v_n, 'documents', coalesce(v_docs,0)));
  RETURN jsonb_build_object('ok', true, 'id', p_request_id, 'status', 'in_review', 'stages', v_n);
END $fn$;
REVOKE ALL ON FUNCTION portal_submit_expense(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_submit_expense(text) TO authenticated;

-- ── (9) ملاحظة توافق: portal_create_expense (الذرّي) يبقى، لكن عند إلزام المستندات لا يُقدِّم ─
--   بل يُنشئ مسودّة ويعيد needs_documents=true حتى لا يُقدَّم صرف بلا مستند من مسار قديم.
CREATE OR REPLACE FUNCTION portal_create_expense(
    p_beneficiary text, p_amount numeric, p_kind text, p_purpose text,
    p_department_id text, p_need_by date, p_details jsonb DEFAULT NULL, p_note text DEFAULT NULL,
    p_beneficiary_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_r jsonb;
BEGIN
  -- أنشئ مسودّة دائماً (يحمل كلّ عمليات التحقّق + الضابط التعويضي عبر draft).
  v_r := portal_create_expense_draft(p_beneficiary, p_amount, p_kind, p_purpose, p_department_id, p_need_by, p_details, p_note, p_beneficiary_id, p_details->>'iban_manual_reason');
  IF portal_setting_num('expense_docs_required', 1) >= 1 THEN
    -- مطلوب مستند: لا نُقدِّم — نعيد المسودّة كي تُرفَق المستندات ثم portal_submit_expense.
    RETURN v_r || jsonb_build_object('needs_documents', true);
  END IF;
  -- لا إلزام: قدِّم مباشرةً (سلوك متوافق مع 061 لمن أطفأ الإلزام).
  RETURN portal_submit_expense(v_r->>'id');
END $fn$;
REVOKE ALL ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text,bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_create_expense(text,numeric,text,text,text,date,jsonb,text,bigint) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  (10) تصليب Codex round-3 — تعميم البوّابة على الدوال القائمة (تُطبَّق حيّاً ضمن 062):
--   • portal_budget_committed: استبعاد المسوّدات غير المُقدَّمة من المرتبط (لا حجز ميزانية بلا اعتماد).
--   • portal_resubmit_request: بوّابة مستند نشط للصرف المباشر (يمنع حذف الأدلّة ثم إعادة التقديم).
--   • portal_recurring_run: المُولَّد يبقى مسودّةً بانتظار الأدلّة عند إلزام المستندات (لا اعتماد آلي).
--   هذه الدوال مُعرّفة أصلاً في 050/052/061 (مُطبَّقة حيّاً) فتُعاد هنا بجسمها المُصحَّح.
-- ═══════════════════════════════════════════════════════════════════════════

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
        -- (Codex round-3) استبعاد المسوّدات غير المُقدَّمة كي لا تحجز ميزانيةً بلا اعتماد.
        AND coalesce(r.status,'') NOT IN ('cancelled','rejected','returned','draft')), 0);
$fn$;
REVOKE ALL ON FUNCTION portal_budget_committed(text, int) FROM anon, authenticated, PUBLIC;

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
  -- (Codex round-3) بوّابة المستندات: الصرف المباشر لا يُعاد تقديمه بلا مستند داعم نشط (يمنع
  -- حذف كل الأدلّة على المُعاد ثم إعادة التقديم عبر هذا المسار متجاوزاً portal_submit_expense).
  IF v_req.req_type = 'direct_expense' AND portal_setting_num('expense_docs_required', 1) >= 1
     AND (SELECT count(*) FROM portal_request_documents
            WHERE request_id = p_request_id AND active AND payment_id IS NULL) < 1 THEN
    RAISE EXCEPTION 'لا يمكن إعادة تقديم طلب الصرف بلا مستند داعم واحد صالح على الأقل';
  END IF;
  -- (Codex round-4) الدورة من نوع الطلب (الصرف المباشر=disbursement) لا الطور — المُعاد من الدفع phase=payment.
  v_cycle := CASE WHEN v_req.req_type = 'direct_expense' THEN 'disbursement' ELSE 'need' END;
  v_phase := CASE WHEN v_cycle = 'disbursement' THEN 'disbursement' ELSE 'requisition' END;

  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_email_tokens WHERE request_id = p_request_id;   -- (Codex round-4) إبطال الرموز القديمة قبل إعادة البناء
  UPDATE portal_approvals SET decision='pending', approver=NULL, comment=NULL, acted_at=NULL, channel='portal'
   WHERE request_id = p_request_id AND cycle = v_cycle;
  SELECT min(seq) INTO v_first FROM portal_approvals WHERE request_id = p_request_id AND cycle = v_cycle;
  UPDATE portal_requests SET status='in_review', phase=v_phase, current_seq = coalesce(v_first,1),
         updated_at=now(), updated_by=v_me WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM portal_audit_write(p_request_id,'resubmitted',v_me,'portal',jsonb_build_object('comment',p_comment,'cycle',v_cycle));
  RETURN jsonb_build_object('ok', true, 'status', 'in_review');
END $fn$;
REVOKE ALL ON FUNCTION portal_resubmit_request(text,text) FROM public;
GRANT EXECUTE ON FUNCTION portal_resubmit_request(text,text) TO authenticated;

CREATE OR REPLACE FUNCTION portal_recurring_run()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_t portal_recurring_expenses%ROWTYPE; v_id text; v_n int; v_created int := 0; v_skipped int := 0; v_next date;
        v_reqname text; v_year int; v_budget numeric; v_committed numeric; v_vat numeric; v_prospective numeric;
        v_details jsonb; v_ben portal_beneficiaries%ROWTYPE; v_bname text;
BEGIN
  v_vat := portal_setting_num('vat', 15);
  FOR v_t IN SELECT * FROM portal_recurring_expenses
      WHERE active AND next_run <= current_date ORDER BY next_run ASC FOR UPDATE
  LOOP
    -- صاحب القالب نشط؟
    SELECT display_name INTO v_reqname FROM portal_users WHERE username = v_t.owner AND active;
    IF NOT FOUND THEN
      v_next := v_t.next_run;
      WHILE v_next <= current_date LOOP v_next := portal_recurring_next(v_next, v_t.frequency); END LOOP;
      UPDATE portal_recurring_expenses SET next_run = v_next, updated_at = now() WHERE id = v_t.id;
      CONTINUE;
    END IF;

    -- (أ) القسم نشط؟ (لا توليد على قسم مُغلَق)
    IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = v_t.department_id AND active) THEN
      PERFORM portal_audit_write(NULL, 'recurring_skipped_dept_inactive', 'system', 'system',
        jsonb_build_object('department', v_t.department_id, 'template_id', v_t.id));
      v_next := portal_recurring_next(v_t.next_run, v_t.frequency);
      WHILE v_next <= current_date LOOP v_next := portal_recurring_next(v_next, v_t.frequency); END LOOP;
      UPDATE portal_recurring_expenses SET next_run = v_next, updated_at = now() WHERE id = v_t.id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- (د) تحديث بيانات المستفيد المربوط من السجلّ الحيّ (لا لقطة قديمة)
    v_details := v_t.details;
    v_bname := v_t.beneficiary;
    IF v_t.beneficiary_id IS NOT NULL THEN
      SELECT * INTO v_ben FROM portal_beneficiaries WHERE id = v_t.beneficiary_id;
      IF NOT FOUND OR NOT v_ben.active THEN
        PERFORM portal_audit_write(NULL, 'recurring_skipped_benef_inactive', 'system', 'system',
          jsonb_build_object('department', v_t.department_id, 'template_id', v_t.id, 'beneficiary_id', v_t.beneficiary_id));
        v_next := portal_recurring_next(v_t.next_run, v_t.frequency);
        WHILE v_next <= current_date LOOP v_next := portal_recurring_next(v_next, v_t.frequency); END LOOP;
        UPDATE portal_recurring_expenses SET next_run = v_next, updated_at = now() WHERE id = v_t.id;
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;
      v_bname := v_ben.name;
      IF v_t.kind = 'bank' THEN
        IF v_ben.iban IS NULL THEN
          PERFORM portal_audit_write(NULL, 'recurring_skipped_no_iban', 'system', 'system',
            jsonb_build_object('department', v_t.department_id, 'template_id', v_t.id, 'beneficiary_id', v_t.beneficiary_id));
          v_next := portal_recurring_next(v_t.next_run, v_t.frequency);
          WHILE v_next <= current_date LOOP v_next := portal_recurring_next(v_next, v_t.frequency); END LOOP;
          UPDATE portal_recurring_expenses SET next_run = v_next, updated_at = now() WHERE id = v_t.id;
          v_skipped := v_skipped + 1;
          CONTINUE;
        END IF;
        v_details := coalesce(v_details,'{}'::jsonb) || jsonb_build_object('iban', v_ben.iban, 'account_name', coalesce(v_ben.account_name, v_ben.name));
      END IF;
    END IF;

    -- (ب+ج) قفل الميزانية + دقّة غير مُقرَّبة
    IF portal_setting_num('budget_enforce', 0) >= 1 THEN
      v_year := EXTRACT(YEAR FROM now())::int;
      PERFORM pg_advisory_xact_lock(hashtext('portal_budget:' || v_t.department_id || ':' || v_year));
      SELECT amount INTO v_budget FROM portal_budgets WHERE department_id = v_t.department_id AND fiscal_year = v_year AND active;
      IF v_budget IS NOT NULL THEN
        v_committed := portal_budget_committed(v_t.department_id, v_year);
        v_prospective := v_committed + (v_t.amount * (1 + v_vat/100.0));   -- غير مُقرَّب (يطابق الالتزام)
        IF v_prospective > v_budget THEN
          -- (هـ) أثر تدقيق دائم لكل تخطٍّ (لا فقدان صامت)
          PERFORM portal_audit_write(NULL, 'expense_skipped_over_budget', 'system', 'system',
            jsonb_build_object('department', v_t.department_id, 'template_id', v_t.id, 'prospective', round(v_prospective), 'budget', round(v_budget), 'amount', v_t.amount));
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
              'draft', 'disbursement', v_bname, v_t.beneficiary_id, v_t.kind, v_details,
              'صرف متكرّر', current_date, 'مولَّد آلياً من قالب #' || v_t.id, v_t.owner, now());

    -- (Codex round-3) بوّابة المستندات للصرف المتكرّر: عند إلزام المستندات يبقى المُولَّد مسودّةً
    -- بانتظار إرفاق الأدلّة (لا سلسلة، لا اعتماد آلي) فلا يتجاوز الإلزام المفروض على الصرف اليدوي.
    IF portal_setting_num('expense_docs_required', 1) >= 1 THEN
      PERFORM set_config('app.portal_transition', '0', true);
      PERFORM portal_audit_write(v_id, 'recurring_expense_awaiting_docs', v_t.owner, 'system',
        jsonb_build_object('recurring', true, 'template_id', v_t.id, 'amount', v_t.amount, 'kind', v_t.kind));
    ELSE
      v_n := portal_build_chain(v_id, 'disbursement');
      IF v_n = 0 THEN
        INSERT INTO portal_approvals(request_id, cycle, seq, stage_label, resolver, role_key, approver)
          VALUES (v_id, 'disbursement', 1, 'اعتماد الصرف', NULL, 'can_approve_disbursement', NULL);
      END IF;
      UPDATE portal_requests SET status = 'in_review', current_seq = 1, updated_at = now(), updated_by = v_t.owner WHERE id = v_id;
      PERFORM set_config('app.portal_transition', '0', true);
      PERFORM portal_audit_write(v_id, 'expense_created', v_t.owner, 'system',
        jsonb_build_object('recurring', true, 'template_id', v_t.id, 'amount', v_t.amount, 'kind', v_t.kind));
    END IF;

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

-- ═══════════════════════════════════════════════════════════════════════════
--  إجراء التراجع (Rollback) — 062:
--  التعطيل الآمن (fail-closed) دون فقدان بيانات: أعِد إلزام المستندات إلى 0 لإيقاف
--  الحظر مؤقّتاً، أو اسحب تنفيذ دوال المسودّة/التقديم حتى نشر إصلاح أمامي:
--    UPDATE portal_settings SET value = value || '{"expense_docs_required":0}' WHERE key='portal_settings';
--    -- أو تعطيل كامل لإنشاء الصرف:
--    REVOKE EXECUTE ON FUNCTION portal_create_expense_draft(text,numeric,text,text,text,date,jsonb,text,bigint,text) FROM authenticated;
--    REVOKE EXECUTE ON FUNCTION portal_submit_expense(text) FROM authenticated;
--  ⚠️ لا تُسقِط جدول portal_request_documents إن وُجدت مستندات (فقدان أدلّة مالية).
--  لاستعادة السلوك الذرّي القديم (create+submit) لـ portal_create_expense: أعِد تطبيق 061
--  **بعد** ضبط expense_docs_required=0 (وإلا يبقى الإلزام). الجدول والدوال idempotent.
-- ═══════════════════════════════════════════════════════════════════════════

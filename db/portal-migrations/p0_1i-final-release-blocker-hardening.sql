-- ═══════════════════════════════════════════════════════════════════════════
-- P0-1i — Final release-blocker hardening
-- Scope: isolated staging + PR branch only. Never apply to Production without
-- explicit owner authorization. Migration 063 remains prohibited/absent.
--
-- Closes:
--   AUTHZ-RPC-01  internal SECURITY DEFINER helpers exposed to authenticated
--   DOC-TRUST-01  fabricated request-document metadata accepted without R2 proof
--   PAY-DOC-01    payment request/execution accepted without verified evidence
--   RLS-IBAN-01   ordinary requester could read raw beneficiary IBAN
--   FIN-LEAK-01   requester could retrieve award/invoice/return financial totals
--   DOA-BOUNDARY  committee band capped at owner-approved SAR 125,000
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- 1) Cloudflare records a server upload receipt only after R2 put succeeds.
CREATE TABLE IF NOT EXISTS public.portal_upload_receipts (
  storage_key          text PRIMARY KEY,
  request_id           text NOT NULL REFERENCES public.portal_requests(id) ON DELETE CASCADE,
  kind                 text NOT NULL CHECK (kind IN ('pay','grn','inst','inv','ret','disb','reqdoc')),
  mime_type            text NOT NULL CHECK (mime_type IN ('application/pdf','image/jpeg','image/png')),
  size_bytes           bigint NOT NULL CHECK (size_bytes > 0),
  checksum             text NOT NULL CHECK (checksum ~ '^[a-f0-9]{64}$'),
  uploaded_by          text NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  expires_at           timestamptz NOT NULL DEFAULT (now() + interval '30 minutes'),
  consumed_at          timestamptz,
  metadata             jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT portal_upload_receipt_key_shape CHECK (
    storage_key ~ '^docs/(pay|grn|inst|inv|ret|disb|reqdoc)/[A-Za-z0-9._-]{3,40}/[A-Za-z0-9._-]{6,80}\.(pdf|jpg|jpeg|png)$'
    AND position('..' in storage_key) = 0
  )
);

CREATE INDEX IF NOT EXISTS idx_portal_upload_receipts_expiry
  ON public.portal_upload_receipts(expires_at)
  WHERE consumed_at IS NULL;

ALTER TABLE public.portal_upload_receipts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_upload_receipts_service ON public.portal_upload_receipts;
CREATE POLICY portal_upload_receipts_service
  ON public.portal_upload_receipts
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

REVOKE ALL ON public.portal_upload_receipts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.portal_upload_receipts TO service_role;

CREATE UNIQUE INDEX IF NOT EXISTS ux_portal_request_documents_storage_key
  ON public.portal_request_documents(storage_key);

UPDATE public.portal_settings
SET value = value || jsonb_build_object(
  'payment_docs_required',
  coalesce((value->>'payment_docs_required')::int, 1)
)
WHERE key = 'portal_settings';

CREATE OR REPLACE FUNCTION public.portal_validate_upload_receipt(
  p_storage_key text,
  p_request_id text,
  p_expected_uploader text,
  p_allowed_kinds text[],
  p_consume boolean DEFAULT false
)
RETURNS public.portal_upload_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_receipt public.portal_upload_receipts%ROWTYPE;
BEGIN
  IF coalesce(trim(p_storage_key), '') = '' THEN
    RAISE EXCEPTION 'مفتاح التخزين مطلوب';
  END IF;
  IF p_storage_key !~ '^docs/(pay|grn|inst|inv|ret|disb|reqdoc)/[A-Za-z0-9._-]{3,40}/[A-Za-z0-9._-]{6,80}\.(pdf|jpg|jpeg|png)$'
     OR position('..' in p_storage_key) > 0 THEN
    RAISE EXCEPTION 'مفتاح التخزين غير صالح أو غير قياسي';
  END IF;

  SELECT * INTO v_receipt
  FROM public.portal_upload_receipts
  WHERE storage_key = p_storage_key
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'لا يوجد إيصال رفع خادمي صالح لهذا الملف'; END IF;
  IF v_receipt.request_id IS DISTINCT FROM p_request_id THEN RAISE EXCEPTION 'إيصال الرفع لا يخص هذا الطلب'; END IF;
  IF v_receipt.kind <> ALL(coalesce(p_allowed_kinds, ARRAY[]::text[])) THEN RAISE EXCEPTION 'نوع إيصال الرفع غير مسموح في هذه المرحلة'; END IF;
  IF coalesce(v_receipt.uploaded_by, '') IS DISTINCT FROM coalesce(p_expected_uploader, '') THEN RAISE EXCEPTION 'إيصال الرفع لا يخص المستخدم الحالي'; END IF;
  IF v_receipt.consumed_at IS NOT NULL THEN RAISE EXCEPTION 'إيصال الرفع مستهلك مسبقاً'; END IF;
  IF v_receipt.expires_at <= now() THEN RAISE EXCEPTION 'انتهت صلاحية إيصال الرفع — أعد رفع الملف'; END IF;

  IF p_consume THEN
    UPDATE public.portal_upload_receipts
       SET consumed_at = now()
     WHERE storage_key = p_storage_key
       AND consumed_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'إيصال الرفع استُهلك بالتزامن — أعد المحاولة بملف جديد'; END IF;
    v_receipt.consumed_at := now();
  END IF;

  RETURN v_receipt;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_validate_upload_receipt(text,text,text,text[],boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.portal_validate_upload_receipt(text,text,text,text[],boolean)
  TO service_role;

-- Every normalized document must consume an unexpired receipt exactly once.
CREATE OR REPLACE FUNCTION public.portal_request_document_receipt_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_receipt public.portal_upload_receipts%ROWTYPE;
  v_allowed text[];
BEGIN
  IF NEW.payment_id IS NULL THEN
    v_allowed := ARRAY['reqdoc']::text[];
  ELSE
    v_allowed := ARRAY['inst','inv','pay','disb']::text[];
  END IF;

  SELECT * INTO v_receipt
  FROM public.portal_validate_upload_receipt(
    NEW.storage_key,
    NEW.request_id,
    NEW.uploaded_by,
    v_allowed,
    true
  );

  NEW.mime_type := v_receipt.mime_type;
  NEW.size_bytes := v_receipt.size_bytes;
  NEW.checksum := v_receipt.checksum;
  NEW.uploaded_by := v_receipt.uploaded_by;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_request_document_receipt_guard()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_portal_reqdoc_receipt_guard ON public.portal_request_documents;
CREATE TRIGGER trg_portal_reqdoc_receipt_guard
BEFORE INSERT ON public.portal_request_documents
FOR EACH ROW EXECUTE FUNCTION public.portal_request_document_receipt_guard();

-- 2) Payment evidence gate.
CREATE OR REPLACE FUNCTION public.portal_payment_evidence_before()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_req public.portal_requests%ROWTYPE;
  v_key text;
  v_actor text;
  v_receipt public.portal_upload_receipts%ROWTYPE;
  v_required numeric;
BEGIN
  SELECT * INTO v_req FROM public.portal_requests WHERE id = NEW.request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب المرتبط بالصرف غير موجود'; END IF;
  v_required := public.portal_setting_num('payment_docs_required', 1);

  IF TG_OP = 'INSERT' THEN
    IF v_req.req_type = 'direct_expense' THEN
      IF current_setting('app.portal_transition', true) IS DISTINCT FROM '1' THEN
        RAISE EXCEPTION 'فتح صرف مباشر مسموح فقط من انتقال الاعتماد الداخلي';
      END IF;
      IF v_req.status <> 'payment_pending' OR v_req.phase <> 'payment' THEN
        RAISE EXCEPTION 'طلب الصرف المباشر لم يكمل الاعتمادات';
      END IF;
      IF EXISTS (
        SELECT 1 FROM public.portal_approvals
        WHERE request_id = NEW.request_id AND cycle = 'disbursement' AND decision <> 'approved'
      ) THEN RAISE EXCEPTION 'سلسلة اعتماد الصرف المباشر غير مكتملة'; END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.portal_request_documents
        WHERE request_id = NEW.request_id AND payment_id IS NULL AND active
      ) THEN RAISE EXCEPTION 'لا يمكن فتح الصرف المباشر بلا مستند داعم موثّق'; END IF;
      IF EXISTS (
        SELECT 1 FROM public.portal_payments
        WHERE request_id = NEW.request_id AND status IN ('pending_pay','approved_pay','disbursed')
      ) THEN RAISE EXCEPTION 'يوجد صرف مباشر قائم لهذا الطلب'; END IF;
      RETURN NEW;
    END IF;

    IF v_required >= 1 THEN
      v_key := nullif(NEW.details->>'proof_key', '');
      IF v_key IS NULL THEN RAISE EXCEPTION 'مستند الدفع مطلوب قبل إنشاء طلب الصرف'; END IF;
      v_actor := coalesce(NEW.requested_by, public.portal_username());
      SELECT * INTO v_receipt
      FROM public.portal_validate_upload_receipt(
        v_key, NEW.request_id, v_actor,
        ARRAY['inst','inv','pay','disb']::text[], false
      );
      NEW.details := coalesce(NEW.details, '{}'::jsonb) || jsonb_build_object(
        'proof_key', v_receipt.storage_key,
        'proof_kind', v_receipt.kind,
        'proof_mime_type', v_receipt.mime_type,
        'proof_size_bytes', v_receipt.size_bytes,
        'proof_checksum', v_receipt.checksum
      );
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = 'disbursed' AND OLD.status IS DISTINCT FROM 'disbursed' AND v_required >= 1 THEN
    v_key := nullif(NEW.details->>'proof_key', '');
    IF v_key IS NULL THEN RAISE EXCEPTION 'سند تنفيذ الصرف مطلوب'; END IF;
    v_actor := public.portal_username();
    SELECT * INTO v_receipt
    FROM public.portal_validate_upload_receipt(
      v_key, NEW.request_id, v_actor,
      ARRAY['pay','disb']::text[], false
    );
    NEW.details := coalesce(NEW.details, '{}'::jsonb) || jsonb_build_object(
      'proof_key', v_receipt.storage_key,
      'proof_kind', v_receipt.kind,
      'proof_mime_type', v_receipt.mime_type,
      'proof_size_bytes', v_receipt.size_bytes,
      'proof_checksum', v_receipt.checksum
    );
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_payment_evidence_before()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_portal_payments_10_evidence ON public.portal_payments;
CREATE TRIGGER trg_portal_payments_10_evidence
BEFORE INSERT OR UPDATE OF status, details ON public.portal_payments
FOR EACH ROW EXECUTE FUNCTION public.portal_payment_evidence_before();

CREATE OR REPLACE FUNCTION public.portal_payment_evidence_after()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_key text;
  v_receipt public.portal_upload_receipts%ROWTYPE;
  v_doc_type text;
  v_stage text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_key := nullif(NEW.details->>'proof_key', '');
    v_stage := 'payment_request';
  ELSIF NEW.status = 'disbursed' AND OLD.status IS DISTINCT FROM 'disbursed' THEN
    v_key := nullif(NEW.details->>'proof_key', '');
    v_stage := 'payment_execution';
  ELSE
    RETURN NEW;
  END IF;

  IF v_key IS NULL OR EXISTS (
    SELECT 1 FROM public.portal_request_documents WHERE storage_key = v_key
  ) THEN RETURN NEW; END IF;

  SELECT * INTO v_receipt FROM public.portal_upload_receipts WHERE storage_key = v_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'إيصال مستند الدفع غير موجود'; END IF;

  v_doc_type := CASE v_receipt.kind
    WHEN 'inv' THEN 'supplier_invoice'
    WHEN 'inst' THEN 'advance_payment'
    ELSE 'memo'
  END;

  INSERT INTO public.portal_request_documents(
    request_id, payment_id, document_type, title, description,
    storage_key, original_file_name, mime_type, size_bytes, checksum,
    uploaded_by, source_stage
  ) VALUES (
    NEW.request_id, NEW.id, v_doc_type,
    CASE WHEN v_stage = 'payment_execution' THEN 'سند تنفيذ الصرف' ELSE 'مستند طلب الدفع' END,
    'مستند موثّق تلقائياً من إيصال رفع Cloudflare/R2',
    v_receipt.storage_key, NULL, v_receipt.mime_type, v_receipt.size_bytes,
    v_receipt.checksum, v_receipt.uploaded_by, v_stage
  );

  PERFORM public.portal_audit_write(
    NEW.request_id, 'payment_evidence_attached', v_receipt.uploaded_by, 'portal',
    jsonb_build_object('payment_id', NEW.id, 'kind', v_receipt.kind, 'stage', v_stage)
  );
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_payment_evidence_after()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_portal_payments_90_evidence_document ON public.portal_payments;
CREATE TRIGGER trg_portal_payments_90_evidence_document
AFTER INSERT OR UPDATE OF status, details ON public.portal_payments
FOR EACH ROW EXECUTE FUNCTION public.portal_payment_evidence_after();

-- 3) Internal RPC boundary.
CREATE OR REPLACE FUNCTION public.portal_build_chain(p_request_id text, p_cycle text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $function$
DECLARE
  v_req public.portal_requests%ROWTYPE;
  v_wf public.portal_workflows%ROWTYPE;
  v_sector text; v_stage jsonb; v_n integer := 0;
BEGIN
  IF public.portal_username() IS NOT NULL
     AND current_setting('app.portal_transition', true) IS DISTINCT FROM '1' THEN
    RAISE EXCEPTION 'دالة داخلية — استخدم مسار تقديم/إعادة تقديم الطلب';
  END IF;
  SELECT * INTO v_req FROM public.portal_requests WHERE id = p_request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  SELECT sector INTO v_sector FROM public.portal_departments WHERE id = v_req.department_id;
  SELECT * INTO v_wf FROM public.portal_workflows
   WHERE active AND cycle = p_cycle
     AND (department_id IS NULL OR department_id = v_req.department_id)
     AND (sector IS NULL OR sector = v_sector)
     AND v_req.est_total >= min_total
     AND (max_total IS NULL OR v_req.est_total <= max_total)
   ORDER BY priority ASC LIMIT 1;
  DELETE FROM public.portal_approvals WHERE request_id = p_request_id AND cycle = p_cycle;
  IF v_wf.id IS NOT NULL THEN
    FOR v_stage IN SELECT * FROM jsonb_array_elements(v_wf.stages) LOOP
      INSERT INTO public.portal_approvals(request_id,cycle,seq,stage_label,resolver,role_key,approver)
      VALUES (p_request_id,p_cycle,(v_stage->>'seq')::int,v_stage->>'label',v_stage->>'resolver',v_stage->>'role_key',v_stage->>'approver');
      v_n := v_n + 1;
    END LOOP;
    IF p_cycle = 'need' THEN UPDATE public.portal_requests SET workflow_id = v_wf.id WHERE id = p_request_id; END IF;
  ELSIF p_cycle = 'need' THEN
    INSERT INTO public.portal_approvals(request_id,cycle,seq,stage_label,resolver,role_key,approver)
    VALUES (p_request_id,'need',1,'مدير القسم','dept_manager',NULL,NULL);
    v_n := 1;
  END IF;
  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.portal_build_po_chain(p_request_id text, p_total numeric)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $function$
DECLARE
  d public.portal_doa%ROWTYPE; v_seq integer := 0; v_route jsonb; v_policy jsonb;
  v_version integer; v_fallback text; v_use_committee boolean; v_use_fallback boolean;
BEGIN
  IF public.portal_username() IS NOT NULL
     AND current_setting('app.portal_transition', true) IS DISTINCT FROM '1' THEN
    RAISE EXCEPTION 'دالة داخلية — بناء سلسلة أمر الشراء يتم من انتقال التعميد فقط';
  END IF;
  SELECT * INTO d FROM public.portal_doa
   WHERE max_value IS NULL OR p_total <= max_value
   ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد شريحة DoA للقيمة المحددة'; END IF;
  v_route := public.portal_committee_route(p_total);
  v_policy := v_route->'policy';
  v_version := coalesce((v_policy->>'version')::integer,1);
  v_fallback := nullif(v_route->>'fallback_role_key','');
  v_use_committee := coalesce((v_route->>'use_committee')::boolean,false);
  v_use_fallback := coalesce((v_route->>'use_fallback')::boolean,false);
  DELETE FROM public.portal_po_approvals WHERE request_id = p_request_id;
  IF v_use_committee THEN
    v_seq := v_seq + 1;
    INSERT INTO public.portal_po_approvals(request_id,seq,stage_label,kind,role_key,policy_key,policy_version,policy_snapshot)
    VALUES (p_request_id,v_seq,'اعتماد اللجنة','committee','can_approve_committee','committee_policy',v_version,v_policy);
  ELSIF v_use_fallback THEN
    v_seq := v_seq + 1;
    INSERT INTO public.portal_po_approvals(request_id,seq,stage_label,kind,role_key,policy_key,policy_version,policy_snapshot)
    VALUES (p_request_id,v_seq,'المسار البديل للجنة','committee_fallback',v_fallback,'committee_policy',v_version,v_policy);
  END IF;
  IF d.po_finance AND NOT (v_use_fallback AND v_fallback='can_approve_finance') THEN
    v_seq := v_seq + 1;
    INSERT INTO public.portal_po_approvals(request_id,seq,stage_label,kind,role_key,policy_key,policy_version,policy_snapshot)
    VALUES (p_request_id,v_seq,'اعتماد المدير المالي','finance','can_approve_finance','committee_policy',v_version,v_policy);
  END IF;
  IF d.po_gm AND NOT (v_use_fallback AND v_fallback='can_manage_users') THEN
    v_seq := v_seq + 1;
    INSERT INTO public.portal_po_approvals(request_id,seq,stage_label,kind,role_key,policy_key,policy_version,policy_snapshot)
    VALUES (p_request_id,v_seq,'اعتماد المدير العام','gm','can_manage_users','committee_policy',v_version,v_policy);
  END IF;
  RETURN v_seq;
END;
$function$;

CREATE OR REPLACE FUNCTION public.portal_open_direct_payment(p_request_id text,p_last_approver text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $function$
DECLARE v_req public.portal_requests%ROWTYPE; v_details jsonb; v_amt numeric; v_vat numeric;
BEGIN
  IF current_setting('app.portal_transition',true) IS DISTINCT FROM '1' THEN
    RAISE EXCEPTION 'دالة داخلية — فتح الصرف يتم بعد اكتمال سلسلة الاعتماد فقط';
  END IF;
  SELECT * INTO v_req FROM public.portal_requests WHERE id=p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.req_type <> 'direct_expense' THEN RETURN; END IF;
  IF v_req.status <> 'payment_pending' OR v_req.phase <> 'payment' THEN RAISE EXCEPTION 'طلب الصرف المباشر لم يصل إلى مرحلة الدفع'; END IF;
  IF public.portal_username() IS NOT NULL AND p_last_approver IS DISTINCT FROM public.portal_username() THEN RAISE EXCEPTION 'هوية آخر معتمد غير مطابقة للجلسة'; END IF;
  IF EXISTS (SELECT 1 FROM public.portal_approvals WHERE request_id=p_request_id AND cycle='disbursement' AND decision<>'approved') THEN RAISE EXCEPTION 'سلسلة اعتماد الصرف غير مكتملة'; END IF;
  IF EXISTS (SELECT 1 FROM public.portal_payments WHERE request_id=p_request_id AND status IN ('pending_pay','approved_pay','disbursed')) THEN RETURN; END IF;
  v_details := coalesce(v_req.expense_details,'{}'::jsonb);
  v_vat := public.portal_setting_num('vat',15);
  v_amt := round(v_req.est_total*(1+v_vat/100.0));
  INSERT INTO public.portal_payments(request_id,kind,amount,custody_to,status,requested_by,approved_by,approved_at,details,created_at)
  VALUES (p_request_id,v_req.expense_method,v_amt,nullif(v_details->>'custody_to',''),'approved_pay',v_req.requester,p_last_approver,now(),v_details,now());
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.portal_build_chain(text,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.portal_build_po_chain(text,numeric) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.portal_open_direct_payment(text,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.portal_effective_approver(text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.portal_qualified_approver(text,text) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.portal_resolve_stage(text,public.portal_approvals) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.portal_enqueue_stage_notifications(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.portal_build_chain(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.portal_build_po_chain(text,numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public.portal_open_direct_payment(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.portal_effective_approver(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.portal_qualified_approver(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.portal_resolve_stage(text,public.portal_approvals) TO service_role;
GRANT EXECUTE ON FUNCTION public.portal_enqueue_stage_notifications(text,text) TO service_role;

-- 4) Financial privacy.
DROP POLICY IF EXISTS portal_beneficiaries_read ON public.portal_beneficiaries;
CREATE POLICY portal_beneficiaries_read ON public.portal_beneficiaries
FOR SELECT TO authenticated
USING (public.portal_is_admin() OR public.portal_has_perm('can_see_finance') OR public.portal_has_perm('can_manage_procurement'));
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.portal_beneficiaries FROM authenticated;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.portal_suppliers FROM anon,authenticated;

CREATE OR REPLACE FUNCTION public.portal_three_way_status(p_request_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO public
AS $function$
DECLARE v_award numeric; v_inv numeric; v_ret numeric; v_recv boolean; v_tol numeric; v_net numeric;
BEGIN
  IF NOT (public.portal_is_admin() OR public.portal_has_perm('can_see_finance') OR public.portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بعرض مبالغ المطابقة المالية';
  END IF;
  v_award:=public.portal_award_total(p_request_id); v_inv:=public.portal_invoiced_total(p_request_id);
  v_ret:=public.portal_returns_total(p_request_id); v_recv:=EXISTS(SELECT 1 FROM public.portal_receipts WHERE request_id=p_request_id);
  v_tol:=public.portal_setting_num('three_way_tolerance_pct',0); v_net:=v_award-v_ret;
  RETURN jsonb_build_object('request_id',p_request_id,'award_total',round(v_award,2),'returns_total',round(v_ret,2),
    'net_payable',round(v_net,2),'invoiced_total',round(v_inv,2),'received',v_recv,'variance',round(v_inv-v_net,2),
    'within_tolerance',v_inv<=v_net*(1+v_tol/100.0),'matched',v_recv AND v_inv>0 AND v_inv<=v_net*(1+v_tol/100.0),
    'enforced',public.portal_setting_num('three_way_enforce',0)>=1);
END;
$function$;

CREATE OR REPLACE FUNCTION public.portal_return_status(p_request_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO public
AS $function$
BEGIN
  IF NOT (public.portal_is_admin() OR public.portal_has_perm('can_see_finance') OR public.portal_has_perm('can_manage_procurement') OR public.portal_has_perm('can_verify_stock')) THEN
    RAISE EXCEPTION 'غير مصرّح بعرض القيم المالية للمرتجعات';
  END IF;
  RETURN jsonb_build_object('request_id',p_request_id,'returns_total',round(public.portal_returns_total(p_request_id),2),
    'count',(SELECT count(*) FROM public.portal_returns WHERE request_id=p_request_id));
END;
$function$;

-- 5) Owner-approved committee boundary: 25,001–125,000 inclusive.
DO $committee_125k$
DECLARE v_current jsonb; v_version integer;
BEGIN
  SELECT value INTO v_current FROM public.portal_settings WHERE key='committee_policy' FOR UPDATE;
  v_current:=coalesce(v_current,'{}'::jsonb);
  v_version:=coalesce((v_current->>'version')::integer,0)+1;
  PERFORM set_config('app.portal_transition','1',true);
  INSERT INTO public.portal_settings(key,value)
  VALUES ('committee_policy',jsonb_build_object(
    'enabled',coalesce((v_current->>'enabled')::boolean,true),
    'min_amount_exclusive',25000,'max_amount_inclusive',125000,
    'fallback_role_key',nullif(v_current->>'fallback_role_key',''),
    'version',v_version,'published_at',to_jsonb(now()),'published_by','migration:p0_1i'))
  ON CONFLICT (key) DO UPDATE SET value=excluded.value;
  PERFORM set_config('app.portal_transition','0',true);
END;
$committee_125k$;

CREATE OR REPLACE FUNCTION public.portal_get_committee_policy()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO public
AS $function$
  SELECT jsonb_build_object('enabled',true,'min_amount_exclusive',25000,'max_amount_inclusive',125000,
    'fallback_role_key',null,'version',1,'published_at',null,'published_by',null)
    || coalesce((SELECT value FROM public.portal_settings WHERE key='committee_policy'),'{}'::jsonb);
$function$;
REVOKE ALL ON FUNCTION public.portal_get_committee_policy() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.portal_get_committee_policy() TO authenticated,service_role;

COMMIT;

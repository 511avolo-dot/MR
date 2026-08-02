-- ════════════════════════════════════════════════════════════════════════════
-- 41 — عقد طالب الاحتياج الآمن P0-1h
-- يزرع عمداً أسعاراً وعرضاً وترسية ومفاتيح ملفات ومستندات مالية وطلب صرف،
-- ثم يثبت أن RPC الطالب parameterless/identity-bound لا تُرجع أياً منها.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
DECLARE
  v_item_id bigint;
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);

  INSERT INTO portal_departments(id,name_ar,sector,active)
  VALUES ('QA-P0H','QA Requester Safe UX','QA',true)
  ON CONFLICT (id) DO UPDATE SET name_ar=excluded.name_ar, sector=excluded.sector, active=true;

  INSERT INTO portal_users(username,email,display_name,department_id,role,job_key,permissions,active)
  VALUES
    ('p0h_requester','p0h_requester@aldeyabi.com','P0H Requester','QA-P0H','user','employee','{"can_create":true}'::jsonb,true),
    ('p0h_other','p0h_other@aldeyabi.com','P0H Other','QA-P0H','user','employee','{"can_create":true}'::jsonb,true),
    ('p0h_manager','p0h_manager@aldeyabi.com','P0H Manager','QA-P0H','user','sector_mgr_ops','{}'::jsonb,true)
  ON CONFLICT (username) DO UPDATE SET
    email=excluded.email, display_name=excluded.display_name, department_id=excluded.department_id,
    role=excluded.role, job_key=excluded.job_key, permissions=excluded.permissions, active=true;

  DELETE FROM portal_request_documents WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_receipts WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_po_approvals WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_award_approvals WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_award_lines WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_offer_items WHERE offer_id BETWEEN 99110000 AND 99119999;
  DELETE FROM portal_offers WHERE id BETWEEN 99110000 AND 99119999;
  DELETE FROM portal_approvals WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_request_items WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-P0H-%';

  INSERT INTO portal_requests(
    id,title,department_id,requester,requester_name,priority,est_total,currency,
    status,current_seq,phase,proc_type,project,need_by,justification,note,
    created_by,req_type,expense_method,expense_details,beneficiary
  ) VALUES
    ('REQ-P0H-CLOSED','مضخات اختبار','QA-P0H','p0h_requester','P0H Requester','عالي',98765,'SAR',
     'closed',0,'closed','normal','مشروع QA',current_date+7,'احتياج فني','ملاحظة الطالب',
     'p0h_requester','purchase',null,null,null),
    ('REQ-P0H-PO','معدات انتظار أمر شراء','QA-P0H','p0h_requester','P0H Requester','متوسط',55555,'SAR',
     'po_review',1,'po_review','normal','مشروع QA',current_date+10,'احتياج آخر','ملاحظة آمنة',
     'p0h_requester','purchase',null,null,null),
    ('REQ-P0H-RETURN','طلب معاد للتوضيح','QA-P0H','p0h_requester','P0H Requester','متوسط',44444,'SAR',
     'returned',1,'need','normal','مشروع QA',current_date+4,'وصف غير مكتمل','ملاحظة آمنة',
     'p0h_requester','purchase',null,null,null),
    ('REQ-P0H-EXP','صرف سري لا يظهر','QA-P0H','p0h_requester','P0H Requester','متوسط',33333,'SAR',
     'draft',0,'disbursement','normal','صرف مباشر',current_date+2,null,'لا يظهر',
     'p0h_requester','direct_expense','bank','{"iban":"SA1234567890123456789012","account_name":"SECRET BANK"}'::jsonb,'SECRET BENEFICIARY'),
    ('REQ-P0H-OTHER','طلب مستخدم آخر','QA-P0H','p0h_other','P0H Other','متوسط',22222,'SAR',
     'in_review',1,'need','normal','مشروع آخر',current_date+5,'احتياج آخر','لا يراه الطالب الأول',
     'p0h_other','purchase',null,null,null)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO portal_request_items(request_id,seq,description,unit,qty,unit_price,line_total,received_qty,category,notes)
  VALUES ('REQ-P0H-CLOSED',1,'مضخة صناعية','حبة',2,49382.5,98765,2,'معدات','مواصفة فنية')
  RETURNING id INTO v_item_id;

  INSERT INTO portal_request_items(request_id,seq,description,unit,qty,unit_price,line_total,received_qty)
  VALUES
    ('REQ-P0H-PO',1,'صنف قيد الاعتماد','حبة',5,11111,55555,0),
    ('REQ-P0H-RETURN',1,'صنف يحتاج توضيح','حبة',4,11111,44444,0),
    ('REQ-P0H-EXP',1,'بند صرف','حبة',1,33333,33333,0),
    ('REQ-P0H-OTHER',1,'صنف مستخدم آخر','حبة',2,11111,22222,0);

  INSERT INTO portal_approvals(request_id,seq,stage_label,resolver,approver,decision,comment,acted_at,cycle)
  VALUES
    ('REQ-P0H-CLOSED',1,'اعتماد مدير القطاع','user','p0h_manager','approved','INTERNAL APPROVAL 98765',now()-interval '3 day','need'),
    ('REQ-P0H-PO',1,'اعتماد مدير القطاع','user','p0h_manager','approved','INTERNAL APPROVAL 55555',now()-interval '2 day','need'),
    ('REQ-P0H-RETURN',1,'اعتماد مدير القطاع','user','p0h_manager','returned','يرجى توضيح المواصفات الفنية',now()-interval '1 day','need'),
    ('REQ-P0H-OTHER',1,'اعتماد مدير القطاع','user','p0h_manager','pending',null,null,'need');

  INSERT INTO portal_offers(id,request_id,supplier_name,total,delivery_days,quality,payment_days,note,entered_by,quote_pdf_key)
  VALUES (99110001,'REQ-P0H-CLOSED','QA Winner Supplier',98765,7,95,30,'QA SECRET QUOTE NOTE','p0h_manager','quotes/secret-offer.pdf');

  INSERT INTO portal_award(request_id,winner_offer_id,winner_total,award_reason,status,awarded_by)
  VALUES ('REQ-P0H-CLOSED',99110001,98765,'INTERNAL AWARD REASON 98765','approved','p0h_manager');

  INSERT INTO portal_award_approvals(request_id,seq,stage_label,role_key,approver,decision,comment,acted_at)
  VALUES ('REQ-P0H-CLOSED',1,'اعتماد التعميد','can_approve_award','p0h_manager','approved','INTERNAL AWARD COMMENT 98765',now()-interval '2 day');

  INSERT INTO portal_po_approvals(request_id,seq,stage_label,kind,role_key,approver,decision,comment,policy_key,policy_version,policy_snapshot)
  VALUES ('REQ-P0H-PO',1,'اعتماد اللجنة','committee','can_approve_committee','p0h_manager','pending','PO CONFIDENTIAL 55555','committee_policy',1,'{"enabled":true,"min_amount_exclusive":25000}'::jsonb);

  INSERT INTO portal_receipts(request_id,received_by,received_at,note,lines,doc_key)
  VALUES ('REQ-P0H-CLOSED','p0h_requester',now()-interval '1 day','استلام كامل',
          jsonb_build_array(jsonb_build_object('item_id',v_item_id,'qty',2,'unit_price',49382.5,'secret','DO NOT RETURN')),
          'receipts/secret-grn-key.pdf');

  INSERT INTO portal_request_documents(
    request_id,document_type,title,description,storage_key,original_file_name,mime_type,size_bytes,checksum,uploaded_by,source_stage
  ) VALUES
    ('REQ-P0H-CLOSED','memo','مرفق الطالب',null,'request/safe-but-hidden-key.pdf','request-note.pdf','application/pdf',1200,'SAFE-CHECKSUM-SECRET','p0h_requester','request'),
    ('REQ-P0H-CLOSED','quotation','عرض سعر سري',null,'quotes/secret-document.pdf','supplier-quote.pdf','application/pdf',2200,'QUOTE-CHECKSUM-SECRET','p0h_manager','pricing'),
    ('REQ-P0H-CLOSED','supplier_invoice','فاتورة مورد سرية',null,'invoices/secret-invoice.pdf','supplier-invoice.pdf','application/pdf',3200,'INVOICE-CHECKSUM-SECRET','p0h_manager','payment');

  PERFORM set_config('app.portal_transition', '0', true);
END $seed$;

-- RD1–RD8: هوية الطالب الأولى والعقد الآمن.
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0h_requester@aldeyabi.com","role":"authenticated"}',true);
  DO $requester_tests$
  DECLARE
    v_payload jsonb;
    v_closed jsonb;
    v_po jsonb;
    v_returned jsonb;
    v_count int;
    v_key text;
    v_forbidden text[] := ARRAY[
      'est_total','currency','unit_price','line_total','winner_total','award_reason','doa_id',
      'quote_pdf_key','payment','iban','budget','expense_method','expense_details','beneficiary',
      'storage_key','checksum','doc_key','policy_snapshot','role_key'
    ];
  BEGIN
    v_payload := portal_my_purchase_dossiers();

    SELECT count(*) INTO v_count FROM jsonb_array_elements(v_payload->'requests');
    IF v_count <> 3 THEN RAISE EXCEPTION 'RD1 fail: expected 3 own purchase requests, got % payload=%',v_count,v_payload; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_payload->'requests') r WHERE r->>'id' IN ('REQ-P0H-EXP','REQ-P0H-OTHER')) THEN
      RAISE EXCEPTION 'RD1 fail: direct expense or another user request leaked';
    END IF;
    RAISE NOTICE 'PASS RD1 الهوية مقيّدة بطلبات الشراء الخاصة بالطالب؛ الصرف والمستخدم الآخر غائبان';

    SELECT r INTO v_closed FROM jsonb_array_elements(v_payload->'requests') r WHERE r->>'id'='REQ-P0H-CLOSED';
    SELECT r INTO v_po FROM jsonb_array_elements(v_payload->'requests') r WHERE r->>'id'='REQ-P0H-PO';
    SELECT r INTO v_returned FROM jsonb_array_elements(v_payload->'requests') r WHERE r->>'id'='REQ-P0H-RETURN';

    IF v_closed->>'winner_supplier_name' <> 'QA Winner Supplier' OR v_closed->>'public_phase' <> 'closed_delivered' THEN
      RAISE EXCEPTION 'RD2 fail: safe winner/closed state missing=%',v_closed;
    END IF;
    RAISE NOTICE 'PASS RD2 يظهر اسم المورد الفائز والحالة المغلقة بلا مبلغ';

    IF jsonb_array_length(v_closed->'items') <> 1
       OR (v_closed->'items'->0->>'qty')::numeric <> 2
       OR (v_closed->'items'->0->>'received_qty')::numeric <> 2 THEN
      RAISE EXCEPTION 'RD3 fail: non-financial item quantities missing=%',v_closed->'items';
    END IF;
    RAISE NOTICE 'PASS RD3 البنود تعرض الوصف/الكمية/المستلم فقط';

    IF v_po#>>'{current_stage,group}' <> 'po'
       OR v_po#>>'{current_stage,label}' <> 'اعتماد اللجنة'
       OR v_po#>>'{current_stage,holder}' <> 'P0H Manager' THEN
      RAISE EXCEPTION 'RD4 fail: current holder/stage incorrect=%',v_po->'current_stage';
    END IF;
    RAISE NOTICE 'PASS RD4 الطالب يعرف المرحلة الحالية ومن يقف عليه الطلب';

    IF v_returned#>>'{need_approvals,0,requester_comment}' <> 'يرجى توضيح المواصفات الفنية' THEN
      RAISE EXCEPTION 'RD5 fail: requester-directed return comment missing=%',v_returned->'need_approvals';
    END IF;
    IF v_closed::text LIKE '%INTERNAL APPROVAL 98765%'
       OR v_closed::text LIKE '%INTERNAL AWARD COMMENT 98765%'
       OR v_po::text LIKE '%PO CONFIDENTIAL 55555%' THEN
      RAISE EXCEPTION 'RD5 fail: internal approval comments leaked';
    END IF;
    RAISE NOTICE 'PASS RD5 سبب الإرجاع الموجه للطالب ظاهر والملاحظات الداخلية محجوبة';

    IF jsonb_array_length(v_closed->'receipts') <> 1
       OR jsonb_array_length(v_closed#>'{receipts,0,lines}') <> 1
       OR v_closed#>>'{receipts,0,lines,0,qty}' <> '2' THEN
      RAISE EXCEPTION 'RD6 fail: receipt quantity missing=%',v_closed->'receipts';
    END IF;
    IF v_closed::text LIKE '%DO NOT RETURN%' OR v_closed::text LIKE '%receipts/secret-grn-key.pdf%' THEN
      RAISE EXCEPTION 'RD6 fail: raw receipt secret/doc key leaked';
    END IF;
    RAISE NOTICE 'PASS RD6 الاستلام كمية/حالة فقط بلا JSON خام أو مفتاح ملف';

    IF jsonb_array_length(v_closed->'documents') <> 1
       OR v_closed#>>'{documents,0,document_type}' <> 'memo'
       OR v_closed#>>'{documents,0,original_file_name}' <> 'request-note.pdf' THEN
      RAISE EXCEPTION 'RD7 fail: safe document filtering incorrect=%',v_closed->'documents';
    END IF;
    IF v_closed::text LIKE '%supplier-quote.pdf%'
       OR v_closed::text LIKE '%supplier-invoice.pdf%'
       OR v_closed::text LIKE '%secret-document.pdf%'
       OR v_closed::text LIKE '%secret-invoice.pdf%' THEN
      RAISE EXCEPTION 'RD7 fail: quotation/invoice document leaked';
    END IF;
    RAISE NOTICE 'PASS RD7 مرفق الطالب الآمن ظاهر والعرض/الفاتورة محجوبان';

    FOREACH v_key IN ARRAY v_forbidden LOOP
      IF v_payload::text ~ ('"' || v_key || '"[[:space:]]*:') THEN
        RAISE EXCEPTION 'RD8 fail: forbidden key % exists in payload',v_key;
      END IF;
    END LOOP;
    IF v_payload::text LIKE '%QA SECRET QUOTE NOTE%'
       OR v_payload::text LIKE '%INTERNAL AWARD REASON 98765%'
       OR v_payload::text LIKE '%quotes/secret-offer.pdf%'
       OR v_payload::text LIKE '%SA1234567890123456789012%'
       OR v_payload::text LIKE '%SECRET BANK%'
       OR v_payload::text LIKE '%SECRET BENEFICIARY%' THEN
      RAISE EXCEPTION 'RD8 fail: forbidden financial/secret value leaked';
    END IF;
    RAISE NOTICE 'PASS RD8 لا مفاتيح أو قيم عروض/أسعار/دفع/بنك/تخزين في العقد';
  END $requester_tests$;
ROLLBACK;

-- RD9: مستخدم آخر يرى طلبه فقط؛ لا توجد parameter لاختيار صاحب آخر.
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0h_other@aldeyabi.com","role":"authenticated"}',true);
  DO $other_user$
  DECLARE v_payload jsonb; v_ids text[];
  BEGIN
    v_payload := portal_my_purchase_dossiers();
    SELECT array_agg(r->>'id') INTO v_ids FROM jsonb_array_elements(v_payload->'requests') r;
    IF v_ids IS DISTINCT FROM ARRAY['REQ-P0H-OTHER']::text[] THEN
      RAISE EXCEPTION 'RD9 fail: other user IDs=%',v_ids;
    END IF;
    IF (SELECT pronargs FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname='portal_my_purchase_dossiers') <> 0 THEN
      RAISE EXCEPTION 'RD9 fail: RPC accepts horizontal-selection arguments';
    END IF;
    RAISE NOTICE 'PASS RD9 العقد مربوط بالهوية ولا يقبل معرف مستخدم/طلب';
  END $other_user$;
ROLLBACK;

-- RD10: anon لا يملك EXECUTE.
DO $anon_test$
BEGIN
  IF has_function_privilege('anon','public.portal_my_purchase_dossiers()','EXECUTE') THEN
    RAISE EXCEPTION 'RD10 fail: anon can execute requester dossier RPC';
  END IF;
  RAISE NOTICE 'PASS RD10 anon لا يستطيع استدعاء عقد الطالب';
END $anon_test$;

DO $cleanup$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_request_documents WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_receipts WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_po_approvals WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_award_approvals WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_award_lines WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_award WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_offer_items WHERE offer_id BETWEEN 99110000 AND 99119999;
  DELETE FROM portal_offers WHERE id BETWEEN 99110000 AND 99119999;
  DELETE FROM portal_approvals WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_request_items WHERE request_id LIKE 'REQ-P0H-%';
  DELETE FROM portal_requests WHERE id LIKE 'REQ-P0H-%';
  DELETE FROM portal_users WHERE username IN ('p0h_requester','p0h_other','p0h_manager');
  DELETE FROM portal_user_directory WHERE username IN ('p0h_requester','p0h_other','p0h_manager');
  DELETE FROM portal_departments WHERE id='QA-P0H';
  PERFORM set_config('app.portal_transition', '0', true);
END $cleanup$;

DO $done$ BEGIN
  RAISE NOTICE '════ REQUESTER-SAFE PURCHASE DOSSIER: RD1–RD10 = 10/10 PASS ════';
END $done$;

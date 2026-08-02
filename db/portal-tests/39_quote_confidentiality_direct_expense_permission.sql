-- ════════════════════════════════════════════════════════════════════════════
--  39 — سرية عروض الأسعار + صلاحية الصرف المباشر المستقلة (P0-1d)
--  يؤكد فعلياً بدور authenticated أن:
--    • الطالب يرى طلبه ولا يرى عروض الأسعار/بنودها/بيانات الترسية السرية.
--    • مدير القطاع/المنسق المخول يرى العروض عبر صلاحية الوظيفة.
--    • الصرف المباشر لا يعتمد على can_create العام.
--    • مستخدم يحمل can_create_direct_expense يستطيع إنشاء مسودة صرف.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
BEGIN
  -- portal_departments / portal_users / workflow fixtures are guarded config tables.
  -- The test seeds them through the same sanctioned transition flag used by migrations,
  -- then exercises the actual RLS/RPC behaviour as authenticated users below.
  PERFORM set_config('app.portal_transition', '1', true);

  INSERT INTO portal_departments(id,name_ar,sector,active)
  VALUES ('QA-P0D','QA P0-1d Dept','QA',true)
  ON CONFLICT (id) DO UPDATE SET name_ar=excluded.name_ar, sector=excluded.sector, active=true;

  INSERT INTO portal_users(username,email,display_name,department_id,role,job_key,permissions,active)
  VALUES
    ('p0d_requester','p0d_requester@aldeyabi.com','P0D Requester','QA-P0D','user','employee','{"can_create":true}'::jsonb,true),
    ('p0d_sector_mgr','p0d_sector_mgr@aldeyabi.com','P0D Sector Manager','QA-P0D','user','sector_mgr_ops','{}'::jsonb,true),
    ('p0d_coord','p0d_coord@aldeyabi.com','P0D Coordinator','QA-P0D','user','ops_coord','{}'::jsonb,true),
    ('p0d_direct','p0d_direct@aldeyabi.com','P0D Direct Expense','QA-P0D','user','employee','{"can_create":true,"can_create_direct_expense":true}'::jsonb,true)
  ON CONFLICT (username) DO UPDATE SET
    email=excluded.email,
    display_name=excluded.display_name,
    department_id=excluded.department_id,
    role=excluded.role,
    job_key=excluded.job_key,
    permissions=excluded.permissions,
    active=true;

  DELETE FROM portal_offer_items WHERE offer_id IN (SELECT id FROM portal_offers WHERE request_id='REQ-P0D-QUOTE');
  DELETE FROM portal_offers WHERE request_id='REQ-P0D-QUOTE';
  DELETE FROM portal_award_lines WHERE request_id='REQ-P0D-QUOTE';
  DELETE FROM portal_award WHERE request_id='REQ-P0D-QUOTE';
  DELETE FROM portal_request_items WHERE request_id='REQ-P0D-QUOTE';
  DELETE FROM portal_requests WHERE id='REQ-P0D-QUOTE';

  INSERT INTO portal_requests(id,title,department_id,requester,requester_name,req_type,est_total,status,phase,created_by,created_at)
  VALUES ('REQ-P0D-QUOTE','QA confidential quote test','QA-P0D','p0d_requester','P0D Requester','purchase',2750,'offers_received','procurement','p0d_requester',now());

  INSERT INTO portal_request_items(request_id,item_seq,item,qty,unit,est_price)
  VALUES ('REQ-P0D-QUOTE',1,'QA item',2,'each',1000)
  ON CONFLICT DO NOTHING;

  INSERT INTO portal_offers(id,request_id,supplier_name,total,delivery_days,quality,payment_days,note,entered_by,quote_pdf_key,created_at)
  VALUES (99000001,'REQ-P0D-QUOTE','QA Confidential Supplier',2750,5,80,30,'confidential test','p0d_sector_mgr','qa/test.pdf',now())
  ON CONFLICT (id) DO UPDATE SET request_id=excluded.request_id,supplier_name=excluded.supplier_name,total=excluded.total;

  INSERT INTO portal_offer_items(offer_id,item_seq,unit_price)
  VALUES (99000001,1,500)
  ON CONFLICT DO NOTHING;

  INSERT INTO portal_award(request_id,winner_offer_id,winner_total,award_reason,status,awarded_by,created_at)
  VALUES ('REQ-P0D-QUOTE',99000001,2750,'QA confidential award','pending','p0d_sector_mgr',now())
  ON CONFLICT (request_id) DO UPDATE SET winner_offer_id=excluded.winner_offer_id,winner_total=excluded.winner_total,status=excluded.status;

  INSERT INTO portal_award_lines(request_id,item_seq,offer_id,supplier_name,qty,unit_price,line_total)
  VALUES ('REQ-P0D-QUOTE',1,99000001,'QA Confidential Supplier',2,500,1000)
  ON CONFLICT DO NOTHING;

  PERFORM set_config('app.portal_transition', '0', true);
END $seed$;

-- ── QD1: الطالب يرى طلبه فقط دون العروض/الترسية السرية ──────────────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0d_requester@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_req int; v_offers int; v_items int; v_award int; v_lines int;
  BEGIN
    SELECT count(*) INTO v_req FROM portal_requests WHERE id='REQ-P0D-QUOTE';
    SELECT count(*) INTO v_offers FROM portal_offers WHERE request_id='REQ-P0D-QUOTE';
    SELECT count(*) INTO v_items FROM portal_offer_items WHERE offer_id=99000001;
    SELECT count(*) INTO v_award FROM portal_award WHERE request_id='REQ-P0D-QUOTE';
    SELECT count(*) INTO v_lines FROM portal_award_lines WHERE request_id='REQ-P0D-QUOTE';

    IF v_req <> 1 THEN RAISE EXCEPTION 'QD1 fail: الطالب لا يرى طلبه (%).', v_req; END IF;
    IF v_offers <> 0 OR v_items <> 0 OR v_award <> 0 OR v_lines <> 0 THEN
      RAISE EXCEPTION 'QD1 fail: الطالب يرى بيانات عروض/ترسية سرية offers=% items=% award=% lines=%', v_offers, v_items, v_award, v_lines;
    END IF;
    RAISE NOTICE 'PASS QD1 الطالب يرى طلبه ولا يرى عروض الأسعار/الترسية السرية';
  END $t$;
ROLLBACK;

-- ── QD2: مدير القطاع يرى العروض عبر صلاحية الوظيفة can_view_quotes ───────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0d_sector_mgr@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_offers int; v_perm boolean;
  BEGIN
    SELECT portal_effective_perm('can_view_quotes') INTO v_perm;
    SELECT count(*) INTO v_offers FROM portal_offers WHERE request_id='REQ-P0D-QUOTE';
    IF v_perm IS NOT TRUE OR v_offers <> 1 THEN
      RAISE EXCEPTION 'QD2 fail: مدير القطاع لا يرى العروض perm=% offers=%', v_perm, v_offers;
    END IF;
    RAISE NOTICE 'PASS QD2 مدير القطاع يرى العروض عبر صلاحية الوظيفة';
  END $t$;
ROLLBACK;

-- ── QD3: منسق القطاع يرى العروض عبر صلاحية الوظيفة can_view_quotes ───────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0d_coord@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_offers int; v_perm boolean;
  BEGIN
    SELECT portal_effective_perm('can_view_quotes') INTO v_perm;
    SELECT count(*) INTO v_offers FROM portal_offers WHERE request_id='REQ-P0D-QUOTE';
    IF v_perm IS NOT TRUE OR v_offers <> 1 THEN
      RAISE EXCEPTION 'QD3 fail: منسق القطاع لا يرى العروض perm=% offers=%', v_perm, v_offers;
    END IF;
    RAISE NOTICE 'PASS QD3 منسق القطاع يرى العروض عبر صلاحية الوظيفة';
  END $t$;
ROLLBACK;

-- ── QD4: can_create العام لا يسمح بالصرف المباشر ─────────────────────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0d_requester@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v_ok boolean := false; v_msg text := '';
  BEGIN
    BEGIN
      PERFORM portal_create_expense_draft(
        'QA Beneficiary',100,'bank','QA direct expense denied','QA-P0D',current_date+3,
        jsonb_build_object('iban','SA1234567890123456789012','account_name','QA'),null,null,'QA reason'
      );
      v_ok := true;
    EXCEPTION WHEN OTHERS THEN
      v_msg := SQLERRM;
    END;
    IF v_ok OR v_msg NOT LIKE '%صرف مباشر%' THEN
      RAISE EXCEPTION 'QD4 fail: مستخدم can_create استطاع/أو لم يُرفض بسبب الصرف المباشر ok=% msg=%', v_ok, v_msg;
    END IF;
    RAISE NOTICE 'PASS QD4 الصرف المباشر محجوب عن can_create العام';
  END $t$;
ROLLBACK;

-- ── QD5: صلاحية can_create_direct_expense تنشئ مسودة صرف ─────────────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims','{"email":"p0d_direct@aldeyabi.com","role":"authenticated"}',true);
  DO $t$
  DECLARE v jsonb; v_ok boolean := false; v_id text;
  BEGIN
    v := portal_create_expense_draft(
      'QA Beneficiary',100,'bank','QA direct expense allowed','QA-P0D',current_date+3,
      jsonb_build_object('iban','SA1234567890123456789012','account_name','QA'),null,null,'QA reason'
    );
    v_ok := coalesce((v->>'ok')::boolean,false);
    v_id := v->>'id';
    IF v_ok IS NOT TRUE OR coalesce(v_id,'') = '' THEN
      RAISE EXCEPTION 'QD5 fail: صاحب صلاحية الصرف المباشر لم ينشئ مسودة result=%', v;
    END IF;
    RAISE NOTICE 'PASS QD5 صاحب can_create_direct_expense يستطيع إنشاء مسودة صرف (%)', v_id;
  END $t$;
ROLLBACK;

DO $cleanup$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);
  DELETE FROM portal_offer_items WHERE offer_id IN (SELECT id FROM portal_offers WHERE request_id='REQ-P0D-QUOTE');
  DELETE FROM portal_offers WHERE request_id='REQ-P0D-QUOTE';
  DELETE FROM portal_award_lines WHERE request_id='REQ-P0D-QUOTE';
  DELETE FROM portal_award WHERE request_id='REQ-P0D-QUOTE';
  DELETE FROM portal_request_items WHERE request_id='REQ-P0D-QUOTE';
  DELETE FROM portal_requests WHERE id='REQ-P0D-QUOTE';
  DELETE FROM portal_users WHERE username IN ('p0d_requester','p0d_sector_mgr','p0d_coord','p0d_direct');
  DELETE FROM portal_user_directory WHERE username IN ('p0d_requester','p0d_sector_mgr','p0d_coord','p0d_direct');
  PERFORM set_config('app.portal_transition', '0', true);
END $cleanup$;

DO $done$ BEGIN
  RAISE NOTICE '════ QUOTE CONFIDENTIALITY / DIRECT EXPENSE PERMISSION: QD1–QD5 = 5/5 PASS ════';
END $done$;

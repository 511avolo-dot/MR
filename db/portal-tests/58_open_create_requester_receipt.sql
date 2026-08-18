-- 58 — p0_2e: (أ) رفع الطلب متاح لكل موظّف · (ب) مُقدّم الطلب يؤكّد استلام طلبه.
--   يثبت: كل وظيفة نشطة تمنح can_create · المُقدّم يسجّل استلام طلبه · حامل can_verify_stock
--   يبقى يعمل · الغريب (لا صلاحية ولا مُقدّم) يُمنَع · الإقفال عند اكتمال الاستلام.
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

-- OC1: كل وظيفة نشطة تمنح can_create (تكليف المالك: أيّ موظف يرفع طلباً).
DO $t$
DECLARE n int; missing text;
BEGIN
  -- تُستثنى وظائف تركيبات الاختبار (فئة qa / بادئة m55) — المقصود الوظائف المؤسسية المبذورة.
  SELECT count(*), string_agg(key,', ') INTO n, missing FROM portal_jobs
   WHERE active AND coalesce((permissions->>'can_create')::boolean,false) = false
     AND coalesce(category,'') <> 'qa' AND key NOT LIKE 'm55%';
  IF n > 0 THEN RAISE EXCEPTION 'OC1 FAIL % active job(s) still lack can_create: %', n, missing; END IF;
  RAISE NOTICE 'PASS OC1 every active job grants can_create';
END $t$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_receipts      WHERE request_id LIKE 'OC-%';
  DELETE FROM portal_request_items WHERE request_id LIKE 'OC-%';
  DELETE FROM portal_requests      WHERE id LIKE 'OC-%';
  DELETE FROM portal_users         WHERE username LIKE 'oc\_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id,active) VALUES
    ('oc_req','oc_req@aldeyabi.com','مقدّم الطلب','user','{"can_create":true}','OPS',true),
    ('oc_wh','oc_wh@aldeyabi.com','أمين المستودع','user','{"can_verify_stock":true}','OPS',true),
    ('oc_other','oc_other@aldeyabi.com','مستخدم آخر','user','{"can_create":true}','OPS',true);
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

CREATE OR REPLACE FUNCTION _oc_mk(p_id text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_receipts      WHERE request_id=p_id;
  DELETE FROM portal_request_items WHERE request_id=p_id;
  DELETE FROM portal_requests      WHERE id=p_id;
  INSERT INTO portal_requests(id,title,requester,department_id,status,phase,est_total)
    VALUES (p_id,'طلب اختبار الاستلام','oc_req','OPS','payment_pending','receipt',1000);
  INSERT INTO portal_request_items(request_id,seq,description,unit,qty,unit_price)
    VALUES (p_id,1,'صنف',' حبة',10,100);
  PERFORM set_config('app.portal_transition','0',true);
END $$;

-- OC2: المُقدّم يسجّل استلام طلبه (كان مرفوضاً قبل p0_2e رغم أنّ الواجهة تعرض له المهمّة).
DO $t$
DECLARE iid bigint; res jsonb;
BEGIN
  PERFORM _oc_mk('OC-R1');
  SELECT id INTO iid FROM portal_request_items WHERE request_id='OC-R1' AND seq=1;
  PERFORM set_config('request.jwt.claims','{"email":"oc_req@aldeyabi.com","role":"authenticated"}',true);
  res := portal_record_receipt('OC-R1', jsonb_build_array(jsonb_build_object('item_id',iid,'qty',4)), 'استلام جزئي');
  IF (res->>'remaining')::numeric <> 6 THEN RAISE EXCEPTION 'OC2 FAIL remaining=%', res->>'remaining'; END IF;
  IF (SELECT received_by FROM portal_receipts WHERE request_id='OC-R1' ORDER BY id DESC LIMIT 1) <> 'oc_req'
    THEN RAISE EXCEPTION 'OC2 FAIL receipt not attributed to requester'; END IF;
  RAISE NOTICE 'PASS OC2 requester records receipt of own request (partial)';
END $t$;

-- OC3: غير المُقدّم وبلا can_verify_stock يُمنَع (لم يُفتح الاستلام للجميع).
DO $t$
DECLARE iid bigint;
BEGIN
  PERFORM _oc_mk('OC-R2');
  SELECT id INTO iid FROM portal_request_items WHERE request_id='OC-R2' AND seq=1;
  PERFORM set_config('request.jwt.claims','{"email":"oc_other@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_record_receipt('OC-R2', jsonb_build_array(jsonb_build_object('item_id',iid,'qty',1)), NULL);
    RAISE EXCEPTION 'OC3 FAIL stranger recorded receipt';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'OC3 FAIL%' THEN RAISE; END IF; END;
  IF EXISTS(SELECT 1 FROM portal_receipts WHERE request_id='OC-R2') THEN RAISE EXCEPTION 'OC3 FAIL receipt row written'; END IF;
  RAISE NOTICE 'PASS OC3 non-requester without can_verify_stock denied';
END $t$;

-- OC4: حامل can_verify_stock يبقى يعمل + الاستلام الكامل يُقفل الطلب (لا انحدار).
DO $t$
DECLARE iid bigint; res jsonb;
BEGIN
  PERFORM _oc_mk('OC-R3');
  SELECT id INTO iid FROM portal_request_items WHERE request_id='OC-R3' AND seq=1;
  PERFORM set_config('request.jwt.claims','{"email":"oc_wh@aldeyabi.com","role":"authenticated"}',true);
  res := portal_record_receipt('OC-R3', jsonb_build_array(jsonb_build_object('item_id',iid,'qty',10)), 'استلام كامل');
  IF coalesce((res->>'remaining')::numeric,-1) <> 0 THEN RAISE EXCEPTION 'OC4 FAIL remaining=%', res->>'remaining'; END IF;
  IF (SELECT status FROM portal_requests WHERE id='OC-R3') <> 'closed' THEN RAISE EXCEPTION 'OC4 FAIL not closed'; END IF;
  RAISE NOTICE 'PASS OC4 stock holder still works + full receipt closes request';
END $t$;

DROP FUNCTION _oc_mk(text);
SELECT 'OPEN CREATE + REQUESTER RECEIPT (p0_2e): OC1..OC4 = 4/4 PASS' AS result;

-- ════════════════════════════════════════════════════════════════════════════
--  29 — سجلّ المستفيدين + ضبط تغيير آيبان المستفيد (053) عبر RPC فعلي بهوية مُنتحَلة.
--  حفظ/صلاحية · حارس الآيبان (مطفأ/مفعَّل) · مسار الطلب/الاعتماد بفصل مهام ·
--  فرض آيبان السجلّ في الصرف المباشر · منع الحذف الصلب لمن له طلبات. كل تأكيد RAISE
--  عند الفشل ⇒ خروج غير صفري.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $docsoff$ BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_settings SET value = value || '{"expense_docs_required":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $docsoff$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_beneficiary_iban_changes WHERE new_iban LIKE 'SA77%' OR new_iban LIKE 'SA88%';
  DELETE FROM portal_requests WHERE requester LIKE 'bm_%';
  DELETE FROM portal_beneficiaries WHERE name LIKE 'مستفيد-اختبار%';
  DELETE FROM portal_users WHERE username LIKE 'bm_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('bm_fin', 'bm_fin@aldeyabi.com', 'مالية',   'user', '{"can_see_finance":true,"can_create":true}', 'GA'),
    ('bm_fin2','bm_fin2@aldeyabi.com','مالية2',  'user', '{"can_see_finance":true}', 'GA'),
    ('bm_acc', 'bm_acc@aldeyabi.com', 'موظف',    'user', '{"can_create":true}', 'GA');
  UPDATE portal_settings SET value = value - 'iban_change_control' WHERE key='portal_settings';
  -- تحييد أثر اختبار الميزانية (28): لا سقف على GA + الإنفاذ مطفأ كي لا يُحجَب صرف BM5.
  DELETE FROM portal_budgets WHERE department_id='GA';
  UPDATE portal_settings SET value = value || '{"budget_enforce":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $b$
DECLARE v_r jsonb; v_bid bigint; v_cid bigint; v_iban text; v_blocked boolean; v_err text;
        v_req text; v_used boolean; v_active boolean;
BEGIN
  -- BM1: حفظ مستفيد (مالية) بآيبان صالح
  PERFORM set_config('request.jwt.claims','{"email":"bm_fin@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_beneficiary_save(NULL,'مستفيد-اختبار أ','company','SA1100000000000000000011','حساب أ','300012345','0500000000',NULL);
  v_bid := (v_r->>'id')::bigint;
  IF v_bid IS NULL THEN RAISE EXCEPTION 'BM1 fail: لم يُنشأ المستفيد'; END IF;
  RAISE NOTICE 'PASS BM1 حفظ مستفيد جديد (id=%)', v_bid;

  -- BM2: صلاحية — موظف بلا مالية/مشتريات/أدمن لا يحفظ
  PERFORM set_config('request.jwt.claims','{"email":"bm_acc@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_beneficiary_save(NULL,'مستفيد-اختبار ب','company','SA2200000000000000000022',NULL,NULL,NULL,NULL);
    RAISE EXCEPTION 'BM2 fail: موظف غير مخوَّل حفظ مستفيداً';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'BM2 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%غير مصرّح%' THEN RAISE EXCEPTION 'BM2 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS BM2 حفظ المستفيد صلاحية مالية/مشتريات/أدمن فقط';

  -- BM3: حارس الآيبان — مطفأ ⇒ التحديث المباشر يعمل؛ مفعَّل ⇒ يُمنَع
  UPDATE portal_beneficiaries SET iban = 'SA3300000000000000000033' WHERE id = v_bid;  -- مطفأ افتراضياً
  SELECT iban INTO v_iban FROM portal_beneficiaries WHERE id = v_bid;
  IF v_iban <> 'SA3300000000000000000033' THEN RAISE EXCEPTION 'BM3 fail: الحارس مطفأ ومع ذلك مُنع'; END IF;
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_settings SET value = jsonb_set(coalesce(value,'{}'::jsonb),'{iban_change_control}','1') WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
  v_blocked := false;
  BEGIN
    UPDATE portal_beneficiaries SET iban = 'SA9900000000000000000099' WHERE id = v_bid;
  EXCEPTION WHEN OTHERS THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'BM3 fail: الحارس مفعَّل ولم يمنع التغيير المباشر'; END IF;
  RAISE NOTICE 'PASS BM3 حارس الآيبان: مطفأ يعمل · مفعَّل يمنع المباشر';

  -- BM4: مسار الطلب/الاعتماد + فصل مهام (الطالب لا يعتمد)
  PERFORM set_config('request.jwt.claims','{"email":"bm_fin@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_beneficiary_iban_request(v_bid,'SA7700000000000000000077','تصحيح');
  v_cid := (v_r->>'change_id')::bigint;
  BEGIN
    PERFORM portal_beneficiary_iban_approve(v_cid);   -- الطالب نفسه
    RAISE EXCEPTION 'BM4 fail: الطالب اعتمد طلبه';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'BM4 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%فصل المهام%' THEN RAISE EXCEPTION 'BM4 fail: سبب آخر %', v_err; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"email":"bm_fin2@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_beneficiary_iban_approve(v_cid);      -- معتمِد آخر
  SELECT iban INTO v_iban FROM portal_beneficiaries WHERE id = v_bid;
  IF v_iban <> 'SA7700000000000000000077' THEN RAISE EXCEPTION 'BM4 fail: الآيبان لم يُطبَّق بعد الاعتماد (%)', v_iban; END IF;
  RAISE NOTICE 'PASS BM4 مسار الطلب/الاعتماد يطبّق الآيبان + فصل مهام (الطالب لا يعتمد)';

  -- BM5: الصرف المباشر بربط السجلّ يفرض آيبان المستفيد المُعتمَد (يتجاوز آيبان العميل الخاطئ)
  PERFORM set_config('request.jwt.claims','{"email":"bm_acc@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_expense('اسم مُتجاهَل', 5000, 'bank', 'شراء لوازم', 'GA', (now()+interval '5 day')::date,
           '{"iban":"SA0000000000000000000000","account_name":"خاطئ","iban_manual_reason":"اختبار"}'::jsonb, NULL, v_bid);
  v_req := v_r->>'id';
  SELECT (expense_details->>'iban') INTO v_iban FROM portal_requests WHERE id = v_req;
  IF v_iban <> 'SA7700000000000000000077' THEN RAISE EXCEPTION 'BM5 fail: لم يُفرَض آيبان السجلّ (%)', v_iban; END IF;
  IF (SELECT beneficiary FROM portal_requests WHERE id = v_req) <> 'مستفيد-اختبار أ' THEN
    RAISE EXCEPTION 'BM5 fail: لم يُفرَض اسم السجلّ'; END IF;
  RAISE NOTICE 'PASS BM5 الصرف المباشر بربط السجلّ يفرض الآيبان/الاسم المُعتمَد';

  -- BM6: مستفيد غير نشط/غير موجود ⇒ خطأ
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_beneficiaries SET active = false WHERE id = v_bid;
  PERFORM set_config('app.portal_transition','0',true);
  BEGIN
    PERFORM portal_create_expense('x', 100, 'custody', 'y', 'GA', (now()+interval '5 day')::date, '{"custody_to":"bm_acc"}'::jsonb, NULL, v_bid);
    RAISE EXCEPTION 'BM6 fail: قُبِل مستفيد غير نشط';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'BM6 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%غير نشط%' THEN RAISE EXCEPTION 'BM6 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS BM6 مستفيد غير نشط مرفوض في الصرف';

  -- BM7: الحذف — له طلب صرف (BM5) ⇒ تعطيل لا حذف صلب
  PERFORM set_config('request.jwt.claims','{"email":"bm_fin@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_beneficiary_delete(v_bid);
  IF (v_r->>'disabled') <> 'true' THEN RAISE EXCEPTION 'BM7 fail: حُذف صلباً رغم وجود طلب'; END IF;
  IF EXISTS (SELECT 1 FROM portal_beneficiaries WHERE id = v_bid AND active) THEN
    RAISE EXCEPTION 'BM7 fail: لم يُعطَّل'; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_beneficiaries WHERE id = v_bid) THEN
    RAISE EXCEPTION 'BM7 fail: حُذف الصفّ (سلامة التدقيق مكسورة)'; END IF;
  RAISE NOTICE 'PASS BM7 منع الحذف الصلب لمن له طلبات ⇒ تعطيل';

  RAISE NOTICE '════ BENEFICIARY MASTER (053): BM1–BM7 = 7/7 PASS ════';
END $b$;

-- ════════════════════════════════════════════════════════════════════════════
--  37 — المستندات الداعمة للصرف المباشر (062): نموذج مُطبَّع + مسودّة→رفع→تقديم.
--  عبر RPC فعلي بهوية مُنتحَلة. RAISE عند الفشل ⇒ خروج ≠ 0. (متطلّب المالك)
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb; $$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 'd7_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('d7_req','d7_req@aldeyabi.com','مقدّم','user','{"can_create":true}','GA'),
    ('d7_oth','d7_oth@aldeyabi.com','آخر','user','{"can_create":true}','OPS');
  UPDATE portal_settings SET value = value || '{"expense_docs_required":1,"budget_enforce":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $t$
DECLARE v_r jsonb; v_id text; v_doc bigint; v_doc2 bigint; v_err text; v_cnt int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"d7_req@aldeyabi.com","role":"authenticated"}',true);

  -- DD1: مسودّة ثم تقديم بلا مستندات ⇒ مرفوض
  v_r := portal_create_expense_draft('جهة','1000','custody','إيجار','GA',(now()+interval '5 day')::date,'{"custody_to":"d7_req"}'::jsonb,NULL,NULL);
  v_id := v_r->>'id';
  IF (v_r->>'status') <> 'draft' THEN RAISE EXCEPTION 'DD1 fail: لم تُنشأ مسودّة'; END IF;
  BEGIN
    PERFORM portal_submit_expense(v_id);
    RAISE EXCEPTION 'DD1 fail: قُبِل التقديم بلا مستند';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'DD1 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%بلا مستند%' THEN RAISE EXCEPTION 'DD1 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS DD1 التقديم بلا مستند مرفوض';

  -- DD4: صيغة غير مدعومة عند الإرفاق ⇒ مرفوضة
  BEGIN
    PERFORM portal_attach_document(v_id,'quotation','quotes/x.docx','application/msword','عرض',NULL,'x.docx',1000,NULL,NULL,NULL);
    RAISE EXCEPTION 'DD4 fail: قُبِلت صيغة غير مدعومة';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'DD4 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%غير مدعومة%' THEN RAISE EXCEPTION 'DD4 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS DD4 صيغة غير مدعومة (docx) مرفوضة';

  -- DD5: «أخرى» بلا وصف ⇒ مرفوض
  BEGIN
    PERFORM portal_attach_document(v_id,'other','docs/o.pdf','application/pdf',NULL,NULL,'o.pdf',1000,NULL,NULL,NULL);
    RAISE EXCEPTION 'DD5 fail: قُبِل «أخرى» بلا وصف';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'DD5 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%وصف%' THEN RAISE EXCEPTION 'DD5 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS DD5 «أخرى» بلا وصف مرفوض';

  -- DD2: إرفاق مستند PDF صالح ثم تقديم ⇒ نجاح (in_review + سلسلة)
  v_r := portal_attach_document(v_id,'supplier_invoice','docs/inv1.pdf','application/pdf','فاتورة','فاتورة المورد','inv1.pdf',2048,'abc',NULL,NULL);
  v_doc := (v_r->>'doc_id')::bigint;
  v_r := portal_submit_expense(v_id);
  IF (v_r->>'status') <> 'in_review' THEN RAISE EXCEPTION 'DD2 fail: لم يُقدَّم بعد إرفاق مستند'; END IF;
  RAISE NOTICE 'PASS DD2 مسودّة + مستند صالح ⇒ تقديم ناجح وبناء سلسلة';

  -- DD9: تقديم ثانٍ (ليس مسودّة) ⇒ مرفوض (لا تكرار)
  BEGIN
    PERFORM portal_submit_expense(v_id);
    RAISE EXCEPTION 'DD9 fail: قُبِل تقديم ثانٍ';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'DD9 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%ليس مسودّة%' THEN RAISE EXCEPTION 'DD9 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS DD9 التقديم المكرّر مرفوض (لا ازدواج)';

  -- DD7: بعد التقديم — لا حذف صامت: RPC الحذف يُرفَض + الحذف المباشر يُمنَع بالحارس
  BEGIN
    PERFORM portal_remove_document(v_doc);
    RAISE EXCEPTION 'DD7 fail: حُذف مستند بعد التقديم عبر RPC';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'DD7 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%بعد التقديم%' THEN RAISE EXCEPTION 'DD7 fail: سبب آخر %', v_err; END IF;
  END;
  BEGIN
    DELETE FROM portal_request_documents WHERE id = v_doc;   -- حذف مباشر بلا علم الانتقال
    RAISE EXCEPTION 'DD7 fail: نجح الحذف المباشر (تجاوز الحارس)';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'DD7 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%غير قابلة للتعديل المباشر%' THEN RAISE EXCEPTION 'DD7 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS DD7 لا حذف للمستند بعد التقديم (RPC + حارس مباشر)';

  -- DD10: إرجاع الطلب ثم استبدال المستند بإصدار جديد (القديم يبقى مرئيّاً)
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_requests SET status='returned' WHERE id=v_id;
  PERFORM set_config('app.portal_transition','0',true);
  v_r := portal_replace_document(v_doc,'docs/inv1_v2.pdf','application/pdf','فاتورة مُعدّلة','نسخة أحدث','inv1_v2.pdf',2100,'def');
  v_doc2 := (v_r->>'doc_id')::bigint;
  IF (v_r->>'version')::int <> 2 THEN RAISE EXCEPTION 'DD10 fail: الإصدار ليس 2'; END IF;
  SELECT count(*) INTO v_cnt FROM portal_request_documents WHERE request_id=v_id;   -- القديم + الجديد
  IF v_cnt < 2 THEN RAISE EXCEPTION 'DD10 fail: الإصدار القديم لم يبقَ (count=%)', v_cnt; END IF;
  IF (SELECT active FROM portal_request_documents WHERE id=v_doc) THEN RAISE EXCEPTION 'DD10 fail: القديم ما زال نشطاً'; END IF;
  IF NOT (SELECT active FROM portal_request_documents WHERE id=v_doc2) THEN RAISE EXCEPTION 'DD10 fail: الجديد غير نشط'; END IF;
  RAISE NOTICE 'PASS DD10 الإرجاع يسمح بإصدار جديد والقديم يبقى مرئيّاً في التاريخ';

  -- DD3: تعدّد المستندات مرتبطة وقابلة للقراءة (أضِف ثانياً للمسودّة المُعادة)
  v_r := portal_attach_document(v_id,'memo','docs/memo.pdf','application/pdf','مذكّرة',NULL,'memo.pdf',500,NULL,NULL,NULL);
  SELECT count(*) INTO v_cnt FROM portal_request_documents WHERE request_id=v_id AND active;
  IF v_cnt < 2 THEN RAISE EXCEPTION 'DD3 fail: المستندات النشطة أقل من 2 (%)', v_cnt; END IF;
  RAISE NOTICE 'PASS DD3 تعدّد المستندات مرتبط وقابل للقراءة (% نشط)', v_cnt;

  -- DD6: آيبان يدوي بلا سبب ⇒ مرفوض (الضابط التعويضي SEC-03)
  BEGIN
    PERFORM portal_create_expense_draft('مورد','5000','bank','دفعة','GA',(now()+interval '3 day')::date,
      '{"iban":"SA1234567890123456789012","account_name":"مورد"}'::jsonb,NULL,NULL,NULL);
    RAISE EXCEPTION 'DD6 fail: قُبِل آيبان يدوي بلا سبب';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'DD6 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%سبباً%' THEN RAISE EXCEPTION 'DD6 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS DD6 الآيبان اليدوي بلا سبب مرفوض (ضابط تعويضي)';

  -- DD8: مستخدم من قسم آخر لا يرى مستندات الطلب (predicate الرؤية)
  PERFORM set_config('request.jwt.claims','{"email":"d7_oth@aldeyabi.com","role":"authenticated"}',true);
  IF portal_can_see_request(v_id) THEN RAISE EXCEPTION 'DD8 fail: مستخدم قسم آخر يرى الطلب'; END IF;
  RAISE NOTICE 'PASS DD8 مستخدم قسم آخر لا يرى الطلب/مستنداته (RLS predicate)';

  RAISE NOTICE '════ REQUEST DOCUMENTS (062): DD1–DD10 = 10/10 PASS ════';
END $t$;

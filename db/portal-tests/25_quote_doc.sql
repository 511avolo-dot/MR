-- ════════════════════════════════════════════════════════════════════════════
--  اختبار الهجرة 049 — إلزام مستند عرض المورد + رفع المورّد لعرضه بنفسه.
--  تأكيدات سلوكية عبر الـRPC الفعلية بهوية مُنتحَلة (لا حقن مباشر).
--  يغطّي: منع العرض بلا سند · القبول مع السند · المفتاح التشغيلي (0/1) ·
--  مسار المورّد الذاتي (بلا مستند يُرفض · مع مستند ينجح · مفتاح طلب آخر يُرفض ·
--  التنقيح يُرحِّل المستند) · وإغلاق دالة تحقّق الرمز أمام anon.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

-- ─── بذر المستخدمين (postgres مميّز فيتجاوز حارس المستخدمين) ───
DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 'q9_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('q9_req','q9_req@aldeyabi.com','مقدّم',        'user','{"can_create":true}','OPS'),
    ('q9_ops','q9_ops@aldeyabi.com','مدير OPS',     'user','{"can_approve_stage":true}','OPS'),
    ('q9_fin','q9_fin@aldeyabi.com','المالية',      'user','{"can_approve_finance":true,"can_approve_stage":true,"can_see_finance":true}','GA'),
    ('q9_pm', 'q9_pm@aldeyabi.com', 'مدير المشتريات','user','{"can_manage_procurement":true,"can_approve_award":true,"can_issue_po":true}','GA');
  UPDATE portal_departments SET manager_user='q9_ops' WHERE id='OPS';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- ════════════════ Q1–Q3 — إدخال المشتريات: المستند سند إلزامي ════════════════
DO $q$
DECLARE v_id text; v_r jsonb; v_err text; v_key text; v_n int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"q9_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب سند العرض','OPS','متوسط',
    '[{"desc":"بند س","unit":"عدد","qty":10,"price":100}]','مشروع السند',(now()+interval '14 day')::date);
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"q9_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"q9_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"q9_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','بدء التسعير');

  -- Q1: عرض بلا مستند ⇒ مرفوض
  BEGIN
    PERFORM portal_submit_offer(v_id,'مورد بلا سند',0,7,90,30,'x',NULL,'[{"seq":1,"price":100}]');
    RAISE EXCEPTION 'Q1 fail: قُبِل عرض بلا مستند رغم تفعيل الإلزام';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'Q1 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%إلزامي%' THEN RAISE EXCEPTION 'Q1 fail: رُفض لسبب آخر: %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS Q1 049: عرض بلا مستند مرفوض';

  -- Q2: عرض مع مستند ⇒ يُقبَل ويُخزَّن المفتاح
  v_key := 'quotes/'||v_id||'/proof.pdf';
  v_r := portal_submit_offer(v_id,'مورد بسند',0,7,90,30,'y',v_key,'[{"seq":1,"price":100}]');
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'Q2 fail: رُفض عرض بمستند'; END IF;
  SELECT count(*) INTO v_n FROM portal_offers
   WHERE request_id=v_id AND supplier_name='مورد بسند' AND quote_pdf_key=v_key;
  IF v_n <> 1 THEN RAISE EXCEPTION 'Q2 fail: لم يُخزَّن مفتاح المستند'; END IF;
  RAISE NOTICE 'PASS Q2 049: العرض بمستند يُقبَل ويُخزَّن سنده';

  -- Q3: إطفاء المفتاح تشغيلياً ⇒ يُسمح بلا مستند (ثم يُعاد التفعيل)
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_settings SET value = value || '{"quote_doc_required":0}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
  v_r := portal_submit_offer(v_id,'مورد بلا سند',0,7,90,30,'z',NULL,'[{"seq":1,"price":105}]');
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'Q3 fail: المفتاح مُطفأ ومع ذلك رُفض'; END IF;
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_settings SET value = value || '{"quote_doc_required":1}'::jsonb WHERE key='portal_settings';
  PERFORM set_config('app.portal_transition','0',true);
  RAISE NOTICE 'PASS Q3 049: المفتاح التشغيلي يعمل في الاتجاهين';
END $q$;

-- ════════════════ Q4–Q8 — مسار المورّد الذاتي ════════════════
DO $q$
DECLARE v_id text; v_r jsonb; v_tok text; v_tok2 text; v_id2 text;
        v_err text; v_key text; v_stored text; v_up int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"q9_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب مورّد ذاتي','OPS','متوسط',
    '[{"desc":"بند م","unit":"عدد","qty":4,"price":250}]','مشروع الذاتي',(now()+interval '14 day')::date);
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"q9_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"q9_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"q9_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','بدء التسعير');

  -- طلب ثانٍ في التسعير (لاختبار مفتاح ينتمي لطلب آخر)
  PERFORM set_config('request.jwt.claims','{"email":"q9_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب آخر','OPS','متوسط',
    '[{"desc":"بند ن","unit":"عدد","qty":1,"price":50}]','مشروع آخر',(now()+interval '14 day')::date);
  v_id2 := v_r->>'id';

  -- دعوة المورّد (صلاحية المشتريات)
  PERFORM set_config('request.jwt.claims','{"email":"q9_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_supplier_invite(v_id,'مؤسسة الاختبار','sup@example.com',14);
  v_tok := v_r->>'token';
  IF coalesce(v_tok,'') = '' THEN RAISE EXCEPTION 'Q4 setup fail: لم يُنشأ رمز الدعوة'; END IF;

  -- Q4: المورّد بلا مستند ⇒ مرفوض
  BEGIN
    PERFORM portal_supplier_submit(v_tok,'[{"seq":1,"price":250}]',20,30,'بلا مرفق',NULL);
    RAISE EXCEPTION 'Q4 fail: قُبِل عرض مورّد بلا مستند';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'Q4 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%إلزامي%' THEN RAISE EXCEPTION 'Q4 fail: رُفض لسبب آخر: %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS Q4 049: عرض المورّد بلا مستند مرفوض';

  -- Q5: مفتاح يخصّ طلباً آخر ⇒ مرفوض (منع إسناد مستند طلب لآخر)
  BEGIN
    PERFORM portal_supplier_submit(v_tok,'[{"seq":1,"price":250}]',20,30,'مفتاح غريب',
                                   'quotes/'||v_id2||'/x.pdf');
    RAISE EXCEPTION 'Q5 fail: قُبِل مفتاح مستند لطلب آخر';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'Q5 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%لا يخصّ هذا الطلب%' THEN RAISE EXCEPTION 'Q5 fail: رُفض لسبب آخر: %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS Q5 049: مفتاح مستند من طلب آخر مرفوض';

  -- Q6: مع مستند صحيح ⇒ يُقبَل ويُخزَّن، ومصدره supplier:self
  v_key := 'quotes/'||v_id||'/self.pdf';
  v_r := portal_supplier_submit(v_tok,'[{"seq":1,"price":250}]',20,30,'عرضنا',v_key);
  IF (v_r->>'ok') <> 'true' OR (v_r->>'total')::numeric <> 1000 THEN
    RAISE EXCEPTION 'Q6 fail: نتيجة غير متوقّعة %', v_r; END IF;
  SELECT quote_pdf_key INTO v_stored FROM portal_offers
   WHERE request_id=v_id AND entered_by='supplier:self';
  IF v_stored IS DISTINCT FROM v_key THEN RAISE EXCEPTION 'Q6 fail: لم يُخزَّن مستند المورّد'; END IF;
  RAISE NOTICE 'PASS Q6 049: المورّد يرفع عرضه ويُخزَّن سنده';

  -- Q7: التنقيح بلا إعادة رفع ⇒ يُرحَّل مستند المراجعة السابقة
  v_r := portal_supplier_submit(v_tok,'[{"seq":1,"price":240}]',20,30,'تنقيح',NULL);
  IF (v_r->>'revision')::int <> 2 THEN RAISE EXCEPTION 'Q7 fail: توقّعت مراجعة 2'; END IF;
  SELECT quote_pdf_key INTO v_stored FROM portal_offers
   WHERE request_id=v_id AND entered_by='supplier:self';
  IF v_stored IS DISTINCT FROM v_key THEN
    RAISE EXCEPTION 'Q7 fail: لم يُرحَّل المستند عند التنقيح (%)', coalesce(v_stored,'NULL'); END IF;
  RAISE NOTICE 'PASS Q7 049: التنقيح يُرحِّل المستند السابق';

  -- Q8: سقف الرفع لكل رمز يتزايد ويتوقّف
  v_r := portal_supplier_token_request(v_tok);
  IF (v_r->>'ok') <> 'true' OR (v_r->>'request_id') <> v_id THEN
    RAISE EXCEPTION 'Q8 fail: تحقّق الرمز لم يُعِد الطلب الصحيح'; END IF;
  SELECT upload_count INTO v_up FROM portal_supplier_tokens WHERE token=v_tok;
  IF v_up <> 1 THEN RAISE EXCEPTION 'Q8 fail: عدّاد الرفع لم يتزايد (%)', v_up; END IF;
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_supplier_tokens SET upload_count = 20 WHERE token=v_tok;
  PERFORM set_config('app.portal_transition','0',true);
  v_r := portal_supplier_token_request(v_tok);
  IF (v_r->>'reason') <> 'too_many' THEN RAISE EXCEPTION 'Q8 fail: السقف لم يُنفَّذ (%)', v_r; END IF;
  RAISE NOTICE 'PASS Q8 049: سقف الرفع لكل رمز مُنفَّذ';
END $q$;

-- ════════════════ Q9 — حدود الصلاحيات ════════════════
DO $q$
BEGIN
  -- دالة تحقّق الرمز خادمية بحتة: لا anon ولا authenticated
  IF has_function_privilege('anon','portal_supplier_token_request(text)','EXECUTE')
     OR has_function_privilege('authenticated','portal_supplier_token_request(text)','EXECUTE') THEN
    RAISE EXCEPTION 'Q9 fail: portal_supplier_token_request مكشوفة للعميل';
  END IF;
  -- دالتا المورّد تبقيان متاحتين لـanon (الرمز هو الهوية) بالتوقيع الجديد
  IF NOT has_function_privilege('anon','portal_supplier_submit(text,jsonb,int,int,text,text)','EXECUTE')
     OR NOT has_function_privilege('anon','portal_supplier_rfq(text)','EXECUTE') THEN
    RAISE EXCEPTION 'Q9 fail: دالتا المورّد فقدتا وصول anon';
  END IF;
  -- التوقيع القديم (5 معاملات) حُذف فلا يبقى مسار بلا مستند
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname='portal_supplier_submit'
             AND pg_get_function_identity_arguments(oid)='p_token text, p_items jsonb, p_delivery_days integer, p_payment_days integer, p_note text') THEN
    RAISE EXCEPTION 'Q9 fail: التوقيع القديم لـportal_supplier_submit ما زال قائماً';
  END IF;
  RAISE NOTICE 'PASS Q9 049: حدود الصلاحيات والتواقيع سليمة';

  RAISE NOTICE '════ QUOTE-DOC REQUIRED (049): 9/9 PASS ════';
END $q$;

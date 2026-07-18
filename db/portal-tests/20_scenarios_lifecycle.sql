-- ════════════════════════════════════════════════════════════════════════════
--  20 — سيناريوهات دورة الحياة عبر الـRPC الحقيقية بهوية مُنتحَلة (JWT).
--  اختبار تكامل على مستوى سير العمل (لا محارس منفردة): تأجيل مالي/استئناف، تفويض
--  عند الغياب، ترسية مجزّأة + صرف لكل مورد، استلام جزئي متعدّد، شريحة اللجنة في أمر
--  الشراء، وإرجاع المشتريات للمقدّم. كل مسار يمرّ بالتسلسل الفعلي للدوال (لا حقن مباشر).
--  الهوية تُنتحَل بضبط request.jwt.claims.email (portal_username يطابق البريد) عبر كعب
--  auth.jwt() المطابق لدلالات Supabase. كل تأكيد RAISE عند الفشل ⇒ خروج غير صفري.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

-- كعب auth.jwt() (كما يوفّره Supabase) — يقرأ request.jwt.claims.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

-- ─── بذر المستخدمين (إدراج مباشر — postgres مميّز فيتجاوز حارس المستخدمين) ───
DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 'b3_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('b3_req',  'b3_req@aldeyabi.com',  'مقدّم',        'user', '{"can_create":true}',                                                                'OPS'),
    ('b3_ops',  'b3_ops@aldeyabi.com',  'مدير OPS',      'user', '{"can_approve_stage":true,"can_create":true}',                                       'OPS'),
    ('b3_del',  'b3_del@aldeyabi.com',  'مفوَّض OPS',    'user', '{"can_approve_stage":true}',                                                         'OPS'),
    ('b3_fin',  'b3_fin@aldeyabi.com',  'المالية',      'user', '{"can_approve_finance":true,"can_approve_stage":true,"can_see_finance":true,"can_disburse":true}', 'GA'),
    ('b3_pm',   'b3_pm@aldeyabi.com',   'مدير المشتريات','user','{"can_manage_procurement":true,"can_approve_award":true,"can_issue_po":true,"can_create":true}',  'GA'),
    ('b3_aw2',  'b3_aw2@aldeyabi.com',  'معتمِد تعميد', 'user', '{"can_approve_award":true}',                                                          'GA'),
    ('b3_acc',  'b3_acc@aldeyabi.com',  'محاسب',        'user', '{"can_disburse":true,"can_see_finance":true}',                                       'GA'),
    ('b3_wh',   'b3_wh@aldeyabi.com',   'أمين مستودع',  'user', '{"can_verify_stock":true}',                                                          'OPS'),
    ('b3_comm', 'b3_comm@aldeyabi.com', 'عضو لجنة',     'user', '{"can_approve_committee":true}',                                                      'GA'),
    ('b3_gm',   'b3_gm@aldeyabi.com',   'مدير عام',     'user', '{"can_manage_users":true}',                                                          'GA');
  -- مدير قسم OPS = b3_ops (لحلّ مرحلة dept_manager)
  UPDATE portal_departments SET manager_user='b3_ops' WHERE id='OPS';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- ════════════════════════ S11 — تأجيل مالي (defer) ثم استئناف (resume) ════════════════════════
DO $s11$
DECLARE v_id text; v_r jsonb; v_status text; v_phase text;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"b3_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب تأجيل','OPS','متوسط','[{"desc":"مضخة","unit":"عدد","qty":2,"price":3000}]','مشروع الصيانة', (now()+interval '10 day')::date);
  v_id := v_r->>'id';
  -- مرحلة 1: مدير القسم يعتمد
  PERFORM set_config('request.jwt.claims','{"email":"b3_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  -- مرحلة 2 (المالية): تأجيل بدل اعتماد
  PERFORM set_config('request.jwt.claims','{"email":"b3_fin@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_pr_transition(v_id,'defer','بانتظار الميزانية',(now()+interval '30 day')::date);
  SELECT status,phase INTO v_status,v_phase FROM portal_requests WHERE id=v_id;
  IF v_status <> 'on_hold' THEN RAISE EXCEPTION 'S11a fail: توقّعت on_hold حصلت %', v_status; END IF;
  RAISE NOTICE 'PASS S11a تأجيل مالي → on_hold';
  -- استئناف: يعود in_review على نفس المرحلة المالية
  v_r := portal_resume_hold(v_id,'توفّرت الميزانية');
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'in_review' THEN RAISE EXCEPTION 'S11b fail: توقّعت in_review حصلت %', v_status; END IF;
  -- تأكيد أنّ المالية ما زالت المرحلة المعلّقة (يمكنها الاعتماد الآن)
  PERFORM portal_pr_transition(v_id,'approve','معتمَد بعد الاستئناف');
  -- مرحلة 3 (المشتريات) → تسعير
  PERFORM set_config('request.jwt.claims','{"email":"b3_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','بدء التسعير');
  SELECT phase INTO v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase <> 'pricing' THEN RAISE EXCEPTION 'S11c fail: توقّعت pricing حصلت %', v_phase; END IF;
  RAISE NOTICE 'PASS S11b/c استئناف → in_review → اعتماد كامل → pricing';
  -- سلبي: التأجيل من غير المرحلة المالية مرفوض (نستخدم طلباً جديداً على مرحلة 1)
  PERFORM set_config('request.jwt.claims','{"email":"b3_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب2','OPS','متوسط','[{"desc":"بند","unit":"عدد","qty":1,"price":1000}]','مشروع', (now()+interval '5 day')::date);
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"b3_ops@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_pr_transition(v_id,'defer','محاولة تأجيل بمرحلة القسم',(now()+interval '10 day')::date);
    RAISE EXCEPTION 'S11d fail: التأجيل من مرحلة القسم لم يُمنَع';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%S11d fail%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS S11d التأجيل مقيَّد بالمرحلة المالية فقط';
  END;
END $s11$;

-- ════════════════════════ S12 — التفويض عند الغياب (delegate) ════════════════════════
DO $s12$
DECLARE v_id text; v_r jsonb; v_status text;
BEGIN
  -- b3_ops غائب ويفوّض b3_del
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_users SET is_away=true, delegate_to='b3_del' WHERE username='b3_ops';
  PERFORM set_config('app.portal_transition','0',true);

  PERFORM set_config('request.jwt.claims','{"email":"b3_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب تفويض','OPS','متوسط','[{"desc":"كابل","unit":"متر","qty":100,"price":50}]','مشروع الطاقة', (now()+interval '7 day')::date);
  v_id := v_r->>'id';
  -- المرحلة 1 (مدير القسم=b3_ops الغائب) — المفوَّض b3_del يعتمد
  PERFORM set_config('request.jwt.claims','{"email":"b3_del@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_pr_transition(v_id,'approve','اعتماد بالتفويض');
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'S12a fail: المفوَّض لم يستطع الاعتماد'; END IF;
  RAISE NOTICE 'PASS S12a المفوَّض (b3_del) اعتمد نيابةً عن الغائب (b3_ops)';
  -- سلبي: المدير الأصلي الغائب لا يعود يُقبل اعتماده (السلطة انتقلت للمفوَّض)
  -- نُنشئ طلباً آخر ونحاول الاعتماد بهوية b3_ops الغائب
  PERFORM set_config('request.jwt.claims','{"email":"b3_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب تفويض2','OPS','متوسط','[{"desc":"بند","unit":"عدد","qty":1,"price":800}]','مشروع', (now()+interval '5 day')::date);
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"b3_ops@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_pr_transition(v_id,'approve','محاولة الغائب');
    RAISE EXCEPTION 'S12b fail: الغائب اعتمد رغم انتقال السلطة للمفوَّض';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%S12b fail%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS S12b الغائب لا يعتمد (السلطة لدى المفوَّض)';
  END;
  -- استرجاع الحالة
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_users SET is_away=false, delegate_to=NULL WHERE username='b3_ops';
  PERFORM set_config('app.portal_transition','0',true);
END $s12$;

-- ════════════════════════ S13 — تعميد مجزّأ + صرف لكل مورد بآيبانه ════════════════════════
DO $s13$
DECLARE v_id text; v_r jsonb; v_o1 bigint; v_o2 bigint; v_status text; v_phase text;
  v_pay1 bigint; v_pay2 bigint;
BEGIN
  -- طلب ببندين، يمرّ للتسعير
  PERFORM set_config('request.jwt.claims','{"email":"b3_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب مجزّأ','OPS','متوسط',
    '[{"desc":"بند أ","unit":"عدد","qty":10,"price":100},{"desc":"بند ب","unit":"عدد","qty":5,"price":200}]',
    'مشروع التجزئة', (now()+interval '14 day')::date, 'single', 'مورد وحيد لكل صنف');
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"b3_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b3_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b3_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','بدء التسعير');
  -- عرضان بأسعار بنود (كل مورد أرخص في بند)
  v_r := portal_submit_offer(v_id,'مورد-A',0,7,90,30,'عرض A',NULL,'[{"seq":1,"price":90},{"seq":2,"price":210}]');
  v_o1 := (v_r->>'id')::bigint;
  v_r := portal_submit_offer(v_id,'مورد-B',0,7,90,30,'عرض B',NULL,'[{"seq":1,"price":110},{"seq":2,"price":190}]');
  v_o2 := (v_r->>'id')::bigint;
  -- ترسية مجزّأة: بند1→A (الأرخص 90) بند2→B (الأرخص 190)
  v_r := portal_award_split(v_id,
         ('[{"seq":1,"offer_id":'||v_o1||'},{"seq":2,"offer_id":'||v_o2||'}]')::jsonb, NULL);
  IF (v_r->>'non_lowest_items')::int <> 0 THEN RAISE EXCEPTION 'S13a fail: توقّعت non_lowest=0 حصلت %', v_r->>'non_lowest_items'; END IF;
  IF (v_r->>'suppliers')::int <> 2 THEN RAISE EXCEPTION 'S13a fail: توقّعت موردين حصلت %', v_r->>'suppliers'; END IF;
  RAISE NOTICE 'PASS S13a ترسية مجزّأة: 2 مورد، كلٌّ أرخص لبنده (non_lowest=0)';
  -- اعتماد التعميد المجزّأ (b3_aw2 ≠ المُرسي b3_pm)
  PERFORM set_config('request.jwt.claims','{"email":"b3_aw2@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_award_transition(v_id,'approve','معتمَد');
  SELECT status,phase INTO v_status,v_phase FROM portal_requests WHERE id=v_id;
  -- الإجمالي = 10*90 + 5*190 = 900+950 = 1850 (شريحة 0-25K → لا مراحل PO → مباشرة awarded/payment)
  IF v_phase <> 'payment' THEN RAISE EXCEPTION 'S13b fail: توقّعت payment حصلت %/%', v_status,v_phase; END IF;
  RAISE NOTICE 'PASS S13b اعتماد التعميد المجزّأ → payment (شريحة صغيرة، بلا سلسلة PO)';
  -- صرف لكل مورد بآيبانه (نصيب A = 900+ضريبة، نصيب B = 950+ضريبة)
  PERFORM set_config('request.jwt.claims','{"email":"b3_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_payment_request(v_id,'bank',1035,NULL,
    '{"iban":"SA0380000000608010167519","account_name":"مورد A"}'::jsonb, v_o1);  -- 900*1.15=1035
  v_pay1 := (v_r->>'id')::bigint;
  v_r := portal_payment_request(v_id,'bank',1092.5,NULL,
    '{"iban":"SA4420000001234567891234","account_name":"مورد B"}'::jsonb, v_o2); -- 950*1.15=1092.5
  v_pay2 := (v_r->>'id')::bigint;
  RAISE NOTICE 'PASS S13c صرفان مستقلّان لكل مورد بآيبانه';
  -- سلبي: صرف ثانٍ لنفس المورد A مرفوض
  BEGIN
    PERFORM portal_payment_request(v_id,'bank',100,NULL,'{"iban":"SA0380000000608010167519","account_name":"A"}'::jsonb, v_o1);
    RAISE EXCEPTION 'S13d fail: صرف مكرّر لنفس المورد لم يُمنَع';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%S13d fail%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS S13d منع صرف مكرّر لنفس المورد';
  END;
  -- اعتماد + تنفيذ صرف A (فصل مهام ثلاثي: pm طلب، fin يعتمد، acc ينفّذ)
  PERFORM set_config('request.jwt.claims','{"email":"b3_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_pay1,'approve','اعتماد A');
  PERFORM set_config('request.jwt.claims','{"email":"b3_acc@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_pay1,'disburse','تنفيذ A','{}',('{"proof_key":"docs/pay/a.pdf"}')::jsonb);
  -- بعد صرف A فقط: الطلب يبقى في payment (المورد B لم يُصرف)
  SELECT phase INTO v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase <> 'payment' THEN RAISE EXCEPTION 'S13e fail: الطلب انتقل قبل اكتمال الموردين (%).', v_phase; END IF;
  RAISE NOTICE 'PASS S13e بعد صرف مورد واحد الطلب يبقى في payment';
  -- صرف B → عندها ينتقل للاستلام
  PERFORM set_config('request.jwt.claims','{"email":"b3_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_pay2,'approve','اعتماد B');
  PERFORM set_config('request.jwt.claims','{"email":"b3_acc@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_pay2,'disburse','تنفيذ B','{}',('{"proof_key":"docs/pay/b.pdf"}')::jsonb);
  SELECT status,phase INTO v_status,v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase <> 'receipt' THEN RAISE EXCEPTION 'S13f fail: توقّعت receipt بعد صرف كل الموردين حصلت %', v_phase; END IF;
  RAISE NOTICE 'PASS S13f بعد صرف كل الموردين → receipt';
  -- استلام كامل → closed
  PERFORM set_config('request.jwt.claims','{"email":"b3_wh@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_record_receipt(v_id,
    (SELECT jsonb_agg(jsonb_build_object('item_id',id,'qty',qty)) FROM portal_request_items WHERE request_id=v_id),
    'استلام كامل', 'docs/grn/x.pdf');
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'closed' THEN RAISE EXCEPTION 'S13g fail: توقّعت closed حصلت %', v_status; END IF;
  RAISE NOTICE 'PASS S13g استلام كامل → closed (دورة مجزّأة كاملة)';
END $s13$;

-- ════════════════════════ S14 — استلام جزئي متعدّد (لا يُقفل إلا بالكامل) ════════════════════════
DO $s14$
DECLARE v_id text; v_r jsonb; v_o bigint; v_status text; v_pay bigint;
  v_it1 bigint; v_it2 bigint;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"b3_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب استلام جزئي','OPS','متوسط',
    '[{"desc":"بند س","unit":"عدد","qty":10,"price":100},{"desc":"بند ص","unit":"عدد","qty":6,"price":100}]',
    'مشروع الاستلام', (now()+interval '20 day')::date, 'single', 'مورد وحيد');
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"b3_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b3_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b3_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','تسعير');
  v_r := portal_submit_offer(v_id,'مورد-C',1600,7,90,30,'عرض C',NULL,'[{"seq":1,"price":100},{"seq":2,"price":100}]');
  v_o := (v_r->>'id')::bigint;
  v_r := portal_award(v_id, v_o, NULL);          -- ترسية مفردة
  PERFORM set_config('request.jwt.claims','{"email":"b3_aw2@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_award_transition(v_id,'approve','معتمَد');   -- 1600 → 0-25K → payment مباشر
  -- صرف كامل مفرد
  PERFORM set_config('request.jwt.claims','{"email":"b3_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_payment_request(v_id,'custody',1840,'b3_acc','{}'::jsonb,NULL);  -- 1600*1.15
  v_pay := (v_r->>'id')::bigint;
  PERFORM set_config('request.jwt.claims','{"email":"b3_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_pay,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b3_acc@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_pay,'disburse','تنفيذ','{}','{}'::jsonb);
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'receipt_pending' THEN RAISE EXCEPTION 'S14a fail: توقّعت receipt_pending حصلت %', v_status; END IF;
  RAISE NOTICE 'PASS S14a دورة مفردة حتى receipt_pending';
  SELECT id INTO v_it1 FROM portal_request_items WHERE request_id=v_id AND seq=1;
  SELECT id INTO v_it2 FROM portal_request_items WHERE request_id=v_id AND seq=2;
  -- استلام جزئي 1: بند1 كامل (10) + بند2 جزئي (4 من 6) — يبقى مفتوحاً
  PERFORM set_config('request.jwt.claims','{"email":"b3_wh@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_record_receipt(v_id, ('[{"item_id":'||v_it1||',"qty":10},{"item_id":'||v_it2||',"qty":4}]')::jsonb, 'دفعة أولى', NULL);
  IF (v_r->>'remaining')::numeric <> 2 THEN RAISE EXCEPTION 'S14b fail: توقّعت متبقّي 2 حصلت %', v_r->>'remaining'; END IF;
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'receipt_pending' THEN RAISE EXCEPTION 'S14b fail: أُقفل قبل الاستلام الكامل (%).', v_status; END IF;
  RAISE NOTICE 'PASS S14b استلام جزئي (متبقّي 2) — الطلب يبقى مفتوحاً';
  -- استلام جزئي 2: البند2 المتبقّي (2) — يُقفل
  v_r := portal_record_receipt(v_id, ('[{"item_id":'||v_it2||',"qty":2}]')::jsonb, 'دفعة ثانية', 'docs/grn/final.pdf');
  IF (v_r->>'remaining')::numeric <> 0 THEN RAISE EXCEPTION 'S14c fail: توقّعت متبقّي 0 حصلت %', v_r->>'remaining'; END IF;
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'closed' THEN RAISE EXCEPTION 'S14c fail: لم يُقفل بعد الاستلام الكامل (%).', v_status; END IF;
  RAISE NOTICE 'PASS S14c الاستلام المكمِّل → closed';
  -- تأكيد: كمية الاستلام لا تتجاوز المطلوب (LEAST clamp) — محاولة استلام إضافي على مُقفل تُمنَع
  BEGIN
    PERFORM portal_record_receipt(v_id, ('[{"item_id":'||v_it1||',"qty":5}]')::jsonb, 'زائد', NULL);
    RAISE EXCEPTION 'S14d fail: قُبل استلام على طلب مُقفل';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%S14d fail%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS S14d لا استلام على طلب مُقفل (ليس بطور الاستلام)';
  END;
END $s14$;

-- ════════════════════════ S15 — شريحة اللجنة في أمر الشراء (portal_set_committee) ════════════════════════
DO $s15$
DECLARE v_id text; v_r jsonb; v_o bigint; v_status text; v_phase text; v_stage text;
BEGIN
  -- طلب بقيمة 100,000 (شريحة 25,001–150,000 → PO فيه مرحلة لجنة فقط)
  PERFORM set_config('request.jwt.claims','{"email":"b3_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب لجنة','OPS','عالٍ',
    '[{"desc":"معدّات","unit":"عدد","qty":100,"price":1000}]','مشروع اللجنة', (now()+interval '30 day')::date, 'single','شراء مباشر مبرّر');
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"b3_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b3_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b3_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','تسعير');
  v_r := portal_submit_offer(v_id,'مورد-D',100000,10,90,30,'عرض D',NULL,'[{"seq":1,"price":1000}]');
  v_o := (v_r->>'id')::bigint;
  v_r := portal_award(v_id, v_o, NULL);
  -- ضبط اللجنة (يتطلّب أدمن) — نُنفّذه بهوية أدمن مؤقّتة
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_users SET role='admin' WHERE username='b3_gm';   -- b3_gm كأدمن مؤقّت لضبط اللجنة
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM set_config('request.jwt.claims','{"email":"b3_gm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_set_committee('["b3_comm"]'::jsonb);
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'S15a fail: تعذّر ضبط اللجنة'; END IF;
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_users SET role='user' WHERE username='b3_gm';    -- إعادته مستخدماً عادياً
  PERFORM set_config('app.portal_transition','0',true);
  RAISE NOTICE 'PASS S15a ضبط اللجنة (b3_comm عضواً)';
  -- اعتماد التعميد (b3_aw2) → يبني سلسلة PO فيها مرحلة لجنة → po_review
  PERFORM set_config('request.jwt.claims','{"email":"b3_aw2@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_award_transition(v_id,'approve','معتمَد');
  SELECT status,phase INTO v_status,v_phase FROM portal_requests WHERE id=v_id;
  IF v_status <> 'po_review' THEN RAISE EXCEPTION 'S15b fail: توقّعت po_review حصلت %', v_status; END IF;
  SELECT stage_label INTO v_stage FROM portal_po_approvals WHERE request_id=v_id AND decision='pending' ORDER BY seq LIMIT 1;
  RAISE NOTICE 'PASS S15b شريحة اللجنة → po_review (المرحلة: %)', v_stage;
  -- سلبي: من ليس عضو لجنة ولا أدمن لا يعتمد مرحلة اللجنة
  PERFORM set_config('request.jwt.claims','{"email":"b3_fin@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_po_transition(v_id,'approve','محاولة غير عضو');
    RAISE EXCEPTION 'S15c fail: غير عضو اللجنة اعتمد';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%S15c fail%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS S15c غير عضو اللجنة مُنِع';
  END;
  -- عضو اللجنة b3_comm يعتمد → لا مراحل متبقّية → awarded/payment
  PERFORM set_config('request.jwt.claims','{"email":"b3_comm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_po_transition(v_id,'approve','اعتماد اللجنة');
  SELECT status,phase INTO v_status,v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase <> 'payment' THEN RAISE EXCEPTION 'S15d fail: توقّعت payment بعد اعتماد اللجنة حصلت %/%', v_status,v_phase; END IF;
  RAISE NOTICE 'PASS S15d عضو اللجنة اعتمد أمر الشراء → payment';
END $s15$;

-- ════════════════════════ S16 — إرجاع المشتريات للمقدّم من التسعير ════════════════════════
DO $s16$
DECLARE v_id text; v_r jsonb; v_o bigint; v_status text; v_phase text; v_super int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"b3_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب إرجاع','OPS','متوسط','[{"desc":"بند","unit":"عدد","qty":3,"price":500}]','مشروع الإرجاع', (now()+interval '9 day')::date, 'single','مبرّر');
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"b3_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b3_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b3_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','تسعير');
  -- عرض واحد ثم المشتريات ترجع للمقدّم
  v_r := portal_submit_offer(v_id,'مورد-E',1500,7,90,30,'عرض E',NULL,'[{"seq":1,"price":500}]');
  v_o := (v_r->>'id')::bigint;
  v_r := portal_bounce_to_requester(v_id,'المواصفات ناقصة — أعد التحديد');
  v_super := (v_r->>'superseded')::int;
  IF v_super < 1 THEN RAISE EXCEPTION 'S16a fail: العروض لم تُعلَّم superseded (%).', v_super; END IF;
  SELECT status,phase INTO v_status,v_phase FROM portal_requests WHERE id=v_id;
  IF v_status <> 'returned' THEN RAISE EXCEPTION 'S16a fail: توقّعت returned حصلت %', v_status; END IF;
  -- تأكيد أنّ العرض مُعلَّم superseded
  IF NOT EXISTS (SELECT 1 FROM portal_offers WHERE id=v_o AND superseded) THEN RAISE EXCEPTION 'S16a fail: العرض ليس superseded'; END IF;
  RAISE NOTICE 'PASS S16a إرجاع المشتريات للمقدّم → returned + عرض superseded';
  -- المقدّم يعيد التقديم (resubmit) → in_review من جديد
  PERFORM set_config('request.jwt.claims','{"email":"b3_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_resubmit_request(v_id);
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'in_review' THEN RAISE EXCEPTION 'S16b fail: إعادة التقديم لم تُرجِع in_review (%).', v_status; END IF;
  RAISE NOTICE 'PASS S16b المقدّم أعاد التقديم → in_review (سلسلة جديدة)';
  -- سلبي: الإرجاع للمقدّم من غير مرحلة التسعير مرفوض (الطلب الآن in_review)
  PERFORM set_config('request.jwt.claims','{"email":"b3_pm@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_bounce_to_requester(v_id,'محاولة خارج التسعير');
    RAISE EXCEPTION 'S16c fail: الإرجاع من غير التسعير لم يُمنَع';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%S16c fail%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS S16c الإرجاع للمقدّم مقيَّد بمرحلة التسعير';
  END;
END $s16$;

SELECT '════ BATCH 3: كل السيناريوهات نجحت ════' AS result;

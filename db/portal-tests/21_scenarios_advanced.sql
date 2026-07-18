-- ════════════════════════════════════════════════════════════════════════════
--  21 — سيناريوهات متقدّمة عبر الـRPC الحقيقية بهوية مُنتحَلة (JWT).
--  سلسلة أمر شراء عالية الشريحة (250–500K: لجنة→مالية→مدير عام) مع فصل مهام كامل،
--  الدفعات على مراحل (installments)، والمرتجعات/إشعار مدين بعد الاستلام. كل مسار
--  يمرّ بالتسلسل الفعلي للدوال. كل تأكيد RAISE عند الفشل ⇒ خروج غير صفري.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 'b4_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('b4_req',  'b4_req@aldeyabi.com',  'مقدّم',        'user', '{"can_create":true}',                                                                'OPS'),
    ('b4_ops',  'b4_ops@aldeyabi.com',  'مدير OPS',      'user', '{"can_approve_stage":true}',                                                         'OPS'),
    ('b4_fin',  'b4_fin@aldeyabi.com',  'المالية',      'user', '{"can_approve_finance":true,"can_approve_stage":true,"can_see_finance":true,"can_disburse":true}', 'GA'),
    ('b4_pm',   'b4_pm@aldeyabi.com',   'مدير المشتريات','user','{"can_manage_procurement":true,"can_approve_award":true,"can_issue_po":true,"can_create":true}',  'GA'),
    ('b4_aw2',  'b4_aw2@aldeyabi.com',  'معتمِد تعميد', 'user', '{"can_approve_award":true}',                                                          'GA'),
    ('b4_acc',  'b4_acc@aldeyabi.com',  'محاسب',        'user', '{"can_disburse":true,"can_see_finance":true}',                                       'GA'),
    ('b4_wh',   'b4_wh@aldeyabi.com',   'أمين مستودع',  'user', '{"can_verify_stock":true}',                                                          'OPS'),
    ('b4_comm', 'b4_comm@aldeyabi.com', 'عضو لجنة',     'user', '{"can_approve_committee":true}',                                                      'GA'),
    ('b4_gm',   'b4_gm@aldeyabi.com',   'مدير عام',     'admin','{"can_manage_users":true}',                                                          'GA');
  UPDATE portal_departments SET manager_user='b4_ops' WHERE id='OPS';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- ضبط اللجنة (b4_gm أدمن)
DO $setc$
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"b4_gm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_set_committee('["b4_comm"]'::jsonb);
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_users SET role='user' WHERE username='b4_gm';  -- بعد الضبط: مدير عام عادي (can_manage_users فقط)
  PERFORM set_config('app.portal_transition','0',true);
END $setc$;

-- helper: تمرير طلب من الإنشاء حتى payment (ترسية مفردة) ويُعيد المعرّف عبر جدول مؤقّت
-- (نُكرّر المنطق داخل كل سيناريو لتفادي دوال مساعدة)

-- ════════════════════ S17 — سلسلة PO عالية (شريحة 250–500K: لجنة→مالية→مدير عام) ════════════════════
DO $s17$
DECLARE v_id text; v_r jsonb; v_o bigint; v_status text; v_phase text; v_cnt int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"b4_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب كبير','OPS','عالٍ',
    '[{"desc":"نظام","unit":"عدد","qty":1,"price":300000}]','مشروع البنية', (now()+interval '45 day')::date,'single','توريد استراتيجي مبرّر');
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"b4_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b4_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b4_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','تسعير');
  v_r := portal_submit_offer(v_id,'مورد-K',300000,20,90,45,'عرض K',NULL,'[{"seq":1,"price":300000}]');
  v_o := (v_r->>'id')::bigint;
  v_r := portal_award(v_id, v_o, NULL);
  PERFORM set_config('request.jwt.claims','{"email":"b4_aw2@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_award_transition(v_id,'approve','معتمَد');
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'po_review' THEN RAISE EXCEPTION 'S17a fail: توقّعت po_review حصلت %', v_status; END IF;
  SELECT count(*) INTO v_cnt FROM portal_po_approvals WHERE request_id=v_id;
  IF v_cnt <> 3 THEN RAISE EXCEPTION 'S17a fail: توقّعت 3 مراحل PO (لجنة/مالية/مدير عام) حصلت %', v_cnt; END IF;
  RAISE NOTICE 'PASS S17a شريحة 300K → سلسلة PO ثلاثية (لجنة→مالية→مدير عام)';
  -- المرحلة 1: اللجنة (b4_comm)
  PERFORM set_config('request.jwt.claims','{"email":"b4_comm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_po_transition(v_id,'approve','لجنة');
  -- سلبي: اللجنة نفسها لا تعتمد مرحلة ثانية (فصل مهام PO)
  BEGIN
    PERFORM portal_po_transition(v_id,'approve','محاولة مرحلة ثانية');
    RAISE EXCEPTION 'S17b fail: نفس الشخص اعتمد مرحلتين في PO';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%S17b fail%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS S17b منع اعتماد مرحلتين في أمر الشراء نفسه (فصل مهام)';
  END;
  -- المرحلة 2: المالية (b4_fin)
  PERFORM set_config('request.jwt.claims','{"email":"b4_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_po_transition(v_id,'approve','مالية');
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'po_review' THEN RAISE EXCEPTION 'S17c fail: أُنهيت السلسلة قبل المدير العام (%).', v_status; END IF;
  RAISE NOTICE 'PASS S17c تقدّم عبر المالية، ما زال بانتظار المدير العام';
  -- المرحلة 3: المدير العام (b4_gm, can_manage_users)
  PERFORM set_config('request.jwt.claims','{"email":"b4_gm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_po_transition(v_id,'approve','مدير عام');
  SELECT status,phase INTO v_status,v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase <> 'payment' THEN RAISE EXCEPTION 'S17d fail: توقّعت payment بعد المدير العام حصلت %/%', v_status,v_phase; END IF;
  RAISE NOTICE 'PASS S17d اكتملت سلسلة PO الثلاثية → payment';
END $s17$;

-- ════════════════════ S18 — الدفعات على مراحل (installments) ════════════════════
DO $s18$
DECLARE v_id text; v_r jsonb; v_o bigint; v_status text; v_phase text; v_p1 bigint; v_p2 bigint; v_rem numeric;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"b4_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب دفعات','OPS','متوسط','[{"desc":"خدمة","unit":"دفعة","qty":1,"price":10000}]','مشروع الدفعات', (now()+interval '30 day')::date,'single','عقد خدمة');
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"b4_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b4_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b4_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','تسعير');
  v_r := portal_submit_offer(v_id,'مورد-M',10000,10,90,30,'عرض M',NULL,'[{"seq":1,"price":10000}]');
  v_o := (v_r->>'id')::bigint;
  v_r := portal_award(v_id, v_o, NULL);
  PERFORM set_config('request.jwt.claims','{"email":"b4_aw2@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_award_transition(v_id,'approve','معتمَد');   -- 10000 → payment مباشر
  -- تفعيل وضع الدفعات
  PERFORM set_config('request.jwt.claims','{"email":"b4_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_set_installments(v_id, true);
  IF NOT (v_r->>'installments')::boolean THEN RAISE EXCEPTION 'S18a fail: لم يُفعَّل وضع الدفعات'; END IF;
  RAISE NOTICE 'PASS S18a تفعيل وضع الدفعات في طور الصرف';
  -- الإجمالي شاملاً الضريبة = 10000*1.15 = 11500. دفعة 1 = 6000 (عهدة)
  v_r := portal_payment_request(v_id,'custody',6000,'b4_acc','{}'::jsonb,NULL);
  v_p1 := (v_r->>'id')::bigint;
  v_rem := (v_r->>'remaining')::numeric;
  IF v_rem <> 5500 THEN RAISE EXCEPTION 'S18b fail: توقّعت متبقّي 5500 حصلت %', v_rem; END IF;
  RAISE NOTICE 'PASS S18b دفعة أولى 6000 (متبقّي 5500)';
  -- سلبي: دفعة تتجاوز المتبقّي مرفوضة
  BEGIN
    PERFORM portal_payment_request(v_id,'custody',6000,'b4_acc','{}'::jsonb,NULL);
    RAISE EXCEPTION 'S18c fail: دفعة تتجاوز المتبقّي لم تُمنَع';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%S18c fail%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS S18c دفعة تتجاوز إجمالي التعميد مُنِعت';
  END;
  -- اعتماد + تنفيذ الدفعة الأولى (فصل مهام ثلاثي)
  PERFORM set_config('request.jwt.claims','{"email":"b4_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_p1,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b4_acc@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_p1,'disburse','تنفيذ 1','{}','{}'::jsonb);
  SELECT phase INTO v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase <> 'payment' THEN RAISE EXCEPTION 'S18d fail: انتقل قبل سداد كامل القيمة (%).', v_phase; END IF;
  RAISE NOTICE 'PASS S18d بعد الدفعة الأولى الطلب يبقى في payment';
  -- الدفعة الثانية (المتبقّي 5500) → بعد صرفها ينتقل للاستلام
  PERFORM set_config('request.jwt.claims','{"email":"b4_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_payment_request(v_id,'custody',5500,'b4_acc','{}'::jsonb,NULL);
  v_p2 := (v_r->>'id')::bigint;
  PERFORM set_config('request.jwt.claims','{"email":"b4_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_p2,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b4_acc@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_p2,'disburse','تنفيذ 2','{}','{}'::jsonb);
  SELECT status,phase INTO v_status,v_phase FROM portal_requests WHERE id=v_id;
  IF v_phase <> 'receipt' THEN RAISE EXCEPTION 'S18e fail: توقّعت receipt بعد سداد كامل القيمة حصلت %', v_phase; END IF;
  RAISE NOTICE 'PASS S18e بعد سداد كامل القيمة (دفعتان) → receipt';
END $s18$;

-- ════════════════════ S19 — مرتجع + إشعار مدين بعد الاستلام ════════════════════
DO $s19$
DECLARE v_id text; v_r jsonb; v_o bigint; v_status text; v_pay bigint; v_it1 bigint; v_dn text; v_amt numeric;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"b4_req@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_create_request('طلب مرتجع','OPS','متوسط','[{"desc":"صنف","unit":"عدد","qty":20,"price":100}]','مشروع المرتجع', (now()+interval '15 day')::date,'single','مبرّر');
  v_id := v_r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"b4_ops@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b4_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b4_pm@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_pr_transition(v_id,'approve','تسعير');
  v_r := portal_submit_offer(v_id,'مورد-R',2000,7,90,30,'عرض R',NULL,'[{"seq":1,"price":100}]');
  v_o := (v_r->>'id')::bigint;
  v_r := portal_award(v_id, v_o, NULL);
  PERFORM set_config('request.jwt.claims','{"email":"b4_aw2@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_award_transition(v_id,'approve','معتمَد');
  PERFORM set_config('request.jwt.claims','{"email":"b4_pm@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_payment_request(v_id,'custody',2300,'b4_acc','{}'::jsonb,NULL);
  v_pay := (v_r->>'id')::bigint;
  PERFORM set_config('request.jwt.claims','{"email":"b4_fin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_pay,'approve','ok');
  PERFORM set_config('request.jwt.claims','{"email":"b4_acc@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_payment_transition(v_pay,'disburse','تنفيذ','{}','{}'::jsonb);
  -- استلام كامل (20)
  SELECT id INTO v_it1 FROM portal_request_items WHERE request_id=v_id AND seq=1;
  PERFORM set_config('request.jwt.claims','{"email":"b4_wh@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_record_receipt(v_id, ('[{"item_id":'||v_it1||',"qty":20}]')::jsonb, 'استلام كامل', NULL);
  SELECT status INTO v_status FROM portal_requests WHERE id=v_id;
  IF v_status <> 'closed' THEN RAISE EXCEPTION 'S19a fail: توقّعت closed حصلت %', v_status; END IF;
  RAISE NOTICE 'PASS S19a دورة عهدة كاملة → closed';
  -- تسجيل مرتجع (3 وحدات تالفة) — يولّد إشعار مدين
  v_r := portal_return_record(v_id, '[{"seq":1,"qty":3,"unit_price":100}]'::jsonb, 'تالف عند الفحص', 'مورد-R', 'docs/ret/dn.pdf');
  v_dn := v_r->>'debit_note_no';
  v_amt := (v_r->>'debit_amount')::numeric;
  IF v_amt <> 300 THEN RAISE EXCEPTION 'S19b fail: توقّعت خصم 300 حصلت %', v_amt; END IF;
  IF v_dn IS NULL OR v_dn NOT LIKE 'DN-%' THEN RAISE EXCEPTION 'S19b fail: لم يُولَّد إشعار مدين (%).', v_dn; END IF;
  RAISE NOTICE 'PASS S19b مرتجع 3 وحدات → إشعار مدين % بقيمة %', v_dn, v_amt;
  -- سلبي: مرتجع يتجاوز المستلَم (20) مرفوض
  BEGIN
    PERFORM portal_return_record(v_id, '[{"seq":1,"qty":25,"unit_price":100}]'::jsonb, 'محاولة زائدة', 'مورد-R', NULL);
    RAISE EXCEPTION 'S19c fail: مرتجع يتجاوز المستلَم لم يُمنَع';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%S19c fail%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS S19c مرتجع يتجاوز المستلَم (شاملاً السابق) مُنِع';
  END;
END $s19$;

SELECT '════ BATCH 4: كل السيناريوهات نجحت ════' AS result;

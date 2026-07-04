-- ═══════════════════════════════════════════════════════════════════════════
--  بيانات تجريبية للعرض — بوابة الطلبات والموافقات (النظام 3)
--  شغّله مرّة واحدة في Supabase → SQL Editor (كـ postgres) → Run.
--  للحذف الكامل لاحقاً: شغّل db/portal-demo/demo-teardown.sql
--
--  ما يزرعه: 9 مستخدمين تجريبيين (بريدهم ينتهي بـ @demo.aldeyabi) موزّعين على
--  القطاعات، + 3 موردين، + 5 طلبات في حالات مختلفة عبر الدوال الحقيقية:
--   R1 قيد اعتماد (مرحلة مدير القسم)     R2 قيد اعتماد (مرحلة المالية)
--   R3 قيد التسعير (عرضان مُدخَلان)       R4 مُعمَّد + صرف بانتظار الاعتماد
--   R5 دورة كاملة حتى «مُقفل» (المستندات الأربعة جاهزة)
--  كل الطلبات ينشئها/يحرّكها مستخدمون تجريبيون → يسهل حذفها لاحقاً.
--  آمن ولا يلمس البذور الحقيقية (وظائف/أقسام/DoA/سلاسل/إعدادات/الأدمن).
-- ═══════════════════════════════════════════════════════════════════════════

DO $demo$
DECLARE
  r1 text; r2 text; r3 text; r4 text; r5 text;
  o_id bigint; p_id bigint; v_lines jsonb;
BEGIN
  -- حارس: لا تزرع مرّتين
  IF EXISTS (SELECT 1 FROM portal_users WHERE email LIKE '%@demo.aldeyabi') THEN
    RAISE NOTICE 'البيانات التجريبية موجودة مسبقاً — تجاهُل الزرع. (شغّل demo-teardown.sql أولاً لإعادة الزرع)';
    RETURN;
  END IF;

  -- ── 1) المستخدمون التجريبيون (إدراج مباشر — SQL Editor يعمل كـ postgres) ──
  INSERT INTO portal_users (username,email,display_name,role,permissions,department_id,active) VALUES
   ('demo_ops_mgr','ops_mgr@demo.aldeyabi','عمر — مدير الصيانة والتشغيل','user','{}','OPS',true),
   ('demo_con_mgr','con_mgr@demo.aldeyabi','ياسر — مدير الإنشاءات','user','{}','CON',true),
   ('demo_finance','finance@demo.aldeyabi','سلمى — المالية','user','{"can_approve_finance":true,"can_disburse":true}','GA',true),
   ('demo_procure','procure@demo.aldeyabi','ماجد — المشتريات','user','{"can_manage_procurement":true}','GA',true),
   ('demo_procmgr','procmgr@demo.aldeyabi','هاني — مدير المشتريات','user','{"can_manage_procurement":true,"can_approve_award":true}','GA',true),
   ('demo_cashier','cashier@demo.aldeyabi','فهد — أمين الصندوق','user','{"can_disburse":true}','GA',true),
   ('demo_wh','warehouse@demo.aldeyabi','نواف — المستودع','user','{"can_verify_stock":true}','LOG',true),
   ('demo_emp_ops','emp_ops@demo.aldeyabi','ريم — موظفة الصيانة','user','{"can_create":true}','OPS',true),
   ('demo_emp_con','emp_con@demo.aldeyabi','خالد — موظف الإنشاءات','user','{"can_create":true}','CON',true);

  -- تعيين مديري القسمين (مطلوب لمرحلة dept_manager)
  UPDATE portal_departments SET manager_user='demo_ops_mgr' WHERE id='OPS';
  UPDATE portal_departments SET manager_user='demo_con_mgr' WHERE id='CON';

  -- ── 2) موردون تجريبيون ──
  INSERT INTO portal_suppliers (name,cr,iban,contact,active) VALUES
   ('مؤسسة الرواد للتجهيزات','1010111111','SA0380000000608010167519','أبو محمد 0550000001',true),
   ('شركة الإمداد الفني','1010222222','SA4420000001234567891234','م. سعود 0550000002',true),
   ('مصنع الخليج للمعدّات','1010333333',NULL,'قسم المبيعات 0550000003',true);

  -- ══════════ الطلبات عبر الدوال الحقيقية ══════════
  -- ملاحظة: PERFORM set_config(request.jwt.claims) يحاكي هوية المستخدم (كما Supabase Auth).

  -- ── R1: قيد الاعتماد عند مدير القسم (OPS) ──
  PERFORM set_config('request.jwt.claims','{"email":"emp_ops@demo.aldeyabi","role":"authenticated"}',false);
  SELECT (portal_create_request('توريد قطع غيار مضخّات المياه','OPS','عالي',
    '[{"desc":"منظومة أختام ميكانيكية","unit":"طقم","qty":4,"price":95},
      {"desc":"محامل كروية SKF","unit":"حبة","qty":8,"price":40}]'::jsonb,
    'صيانة محطة الضخّ الرئيسية','2026-08-15')->>'id') INTO r1;

  -- ── R2: قيد الاعتماد عند المالية (مدير القسم اعتمد) ──
  PERFORM set_config('request.jwt.claims','{"email":"emp_ops@demo.aldeyabi","role":"authenticated"}',false);
  SELECT (portal_create_request('صيانة وحدات التكييف المركزي','OPS','متوسط',
    '[{"desc":"غاز تبريد R410a","unit":"أسطوانة","qty":3,"price":120},
      {"desc":"فلاتر هواء","unit":"حبة","qty":20,"price":15}]'::jsonb,
    'الصيانة الدورية للمبنى الإداري','2026-08-20')->>'id') INTO r2;
  PERFORM set_config('request.jwt.claims','{"email":"ops_mgr@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r2,'approve','موافق — ضمن خطة الصيانة');

  -- ── R3: قيد التسعير (كل السلسلة اعتمدت) + عرضان ──
  PERFORM set_config('request.jwt.claims','{"email":"emp_ops@demo.aldeyabi","role":"authenticated"}',false);
  SELECT (portal_create_request('توريد أدوات كهربائية','OPS','متوسط',
    '[{"desc":"كوابل نحاس 4مم","unit":"متر","qty":300,"price":6},
      {"desc":"قواطع كهربائية","unit":"حبة","qty":15,"price":22}]'::jsonb,
    'تحديث لوحات التوزيع','2026-09-01')->>'id') INTO r3;
  PERFORM set_config('request.jwt.claims','{"email":"ops_mgr@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r3,'approve',NULL);
  PERFORM set_config('request.jwt.claims','{"email":"finance@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r3,'approve',NULL);
  PERFORM set_config('request.jwt.claims','{"email":"procure@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r3,'approve',NULL);
  PERFORM portal_submit_offer(r3,'مؤسسة الرواد للتجهيزات',2130,7,90,30,'شامل التوصيل');
  PERFORM portal_submit_offer(r3,'شركة الإمداد الفني',2280,4,95,60,'ضمان سنة');

  -- ── R4: مُعمَّد + طلب صرف بانتظار الاعتماد ──
  PERFORM set_config('request.jwt.claims','{"email":"emp_ops@demo.aldeyabi","role":"authenticated"}',false);
  SELECT (portal_create_request('أجهزة قياس معايرة','OPS','عالي',
    '[{"desc":"مقياس ضغط رقمي","unit":"حبة","qty":2,"price":140}]'::jsonb,
    'معايرة خطوط الإنتاج','2026-08-10')->>'id') INTO r4;
  PERFORM set_config('request.jwt.claims','{"email":"ops_mgr@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r4,'approve',NULL);
  PERFORM set_config('request.jwt.claims','{"email":"finance@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r4,'approve',NULL);
  PERFORM set_config('request.jwt.claims','{"email":"procure@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r4,'approve',NULL);
  SELECT (portal_submit_offer(r4,'مصنع الخليج للمعدّات',280,10,90,30,'الأقل سعراً')->>'id') INTO o_id;
  PERFORM portal_submit_offer(r4,'شركة الإمداد الفني',330,5,95,45,NULL);
  PERFORM portal_award(r4,o_id,'أقل سعر مطابق للمواصفات');
  PERFORM set_config('request.jwt.claims','{"email":"procmgr@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_award_transition(r4,'approve','معتمد');
  PERFORM set_config('request.jwt.claims','{"email":"procure@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_payment_request(r4,'bank',280,NULL,
    '{"iban":"SA0380000000608010167519","account_name":"مصنع الخليج للمعدّات"}'::jsonb);

  -- ── R5: دورة كاملة حتى «مُقفل» (قطاع الإنشاءات CON) ──
  PERFORM set_config('request.jwt.claims','{"email":"emp_con@demo.aldeyabi","role":"authenticated"}',false);
  SELECT (portal_create_request('توريد إطارات لمعدّات الموقع','CON','متوسط',
    '[{"desc":"إطار لودر 20.5-25","unit":"حبة","qty":2,"price":190}]'::jsonb,
    'مشروع الطريق الدائري','2026-08-05')->>'id') INTO r5;
  PERFORM set_config('request.jwt.claims','{"email":"con_mgr@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r5,'approve',NULL);
  PERFORM set_config('request.jwt.claims','{"email":"finance@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r5,'approve',NULL);
  PERFORM set_config('request.jwt.claims','{"email":"procure@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_pr_transition(r5,'approve',NULL);
  SELECT (portal_submit_offer(r5,'مؤسسة الرواد للتجهيزات',380,6,90,30,'الفائز')->>'id') INTO o_id;
  PERFORM portal_submit_offer(r5,'شركة الإمداد الفني',420,4,88,45,NULL);
  PERFORM portal_award(r5,o_id,'أفضل سعر');
  PERFORM set_config('request.jwt.claims','{"email":"procmgr@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_award_transition(r5,'approve','معتمد');
  PERFORM set_config('request.jwt.claims','{"email":"procure@demo.aldeyabi","role":"authenticated"}',false);
  SELECT (portal_payment_request(r5,'bank',380,NULL,
    '{"iban":"SA4420000001234567891234","account_name":"مؤسسة الرواد للتجهيزات"}'::jsonb)->>'id') INTO p_id;
  PERFORM set_config('request.jwt.claims','{"email":"finance@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_payment_transition(p_id,'approve',NULL);
  PERFORM set_config('request.jwt.claims','{"email":"cashier@demo.aldeyabi","role":"authenticated"}',false);
  PERFORM portal_payment_transition(p_id,'disburse',NULL);
  PERFORM set_config('request.jwt.claims','{"email":"warehouse@demo.aldeyabi","role":"authenticated"}',false);
  SELECT jsonb_agg(jsonb_build_object('item_id',id,'qty',qty)) INTO v_lines
    FROM portal_request_items WHERE request_id=r5;
  PERFORM portal_record_receipt(r5,v_lines,'استلام كامل ومطابق');

  -- إعادة الهوية إلى الخدمة
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',false);
  RAISE NOTICE 'تمّ زرع البيانات التجريبية: 9 مستخدمين + 3 موردين + 5 طلبات (R1..R5).';
END $demo$;

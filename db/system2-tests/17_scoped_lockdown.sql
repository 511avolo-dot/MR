-- ════════════════════════════════════════════════════════════════════════════
--  LK1–LK7 — إقفال الجداول التي فاتت هجرة النطاق (سياسات RESTRICTIVE)
--  تُشغَّل بعد db/system2-scoped-table-lockdown.sql
--
--  التأكيدات **سلوكيّة بدور `authenticated` فعليّ** لا فحصاً لنصّ السياسة:
--  الكعب يبدأ من حالة الإنتاج المفتوحة (`USING(true)`)، فنجاح LK2 يعني أنّ
--  الإقفال هو ما أغلقها لا أنّ الجدول كان مغلقاً أصلاً — ولهذا LK1 (الموظّف
--  المكتبيّ يقرأ) شرطٌ لازم: بدونه قد يكون الجدول محجوباً عن الجميع.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);

DO $$
DECLARE v_cnt int; v_bad boolean;
BEGIN
  DELETE FROM proc_supplier_registrations WHERE id LIKE 'LK-%';
  DELETE FROM proc_users WHERE username IN ('lk_office','lk_field','lk_admin');

  INSERT INTO proc_users (username, display_name, email, role, active, permissions, scope_sectors)
  VALUES
    ('lk_office','مكتب','lk_office@aldeyabi.com','user' ,true,'{}'::jsonb, NULL),
    ('lk_field' ,'ميدان','lk_field@aldeyabi.com' ,'user' ,true,'{}'::jsonb,'["الصيانة والتشغيل"]'::jsonb),
    ('lk_admin' ,'أدمن' ,'lk_admin@aldeyabi.com' ,'admin',true,'{}'::jsonb,'["الصيانة والتشغيل"]'::jsonb);

  -- صفّ تسجيل ببيانات حسّاسة (سجل تجاري · ضريبيّ · آيبان)
  INSERT INTO proc_supplier_registrations
    (id, legal_name_ar, commercial_reg, tax_id, iban, contact_email, status)
  VALUES ('LK-1','مورّد اختبار','1010999999','311111111100003',
          'SA0380000000608010167519','lk@example.com','approved');
  INSERT INTO proc_rfqs        (id,title,status) VALUES ('LK-RFQ','طلب تسعير','open');
  INSERT INTO proc_rfq_quotes  (id,rfq_id,supplier,status) VALUES ('LK-Q','LK-RFQ','مورّد','submitted');
  INSERT INTO proc_item_aliases(item_code,alias,normalized_alias) VALUES ('LK-C','اسم بديل','اسم بديل');
  INSERT INTO proc_ai_usage    (date,username,tokens) VALUES ('2026-09-13','lk_office',10);
  INSERT INTO proc_pr_attachments (pr_id,path,uploaded_by) VALUES ('LK-PR','docs/x.pdf','lk_office');
  INSERT INTO proc_pr_audit    (pr_id,action,actor) VALUES ('LK-PR','created','lk_office');

  -- ── LK1: صفر انحدار — موظّف المكتب يقرأ الجداول السبعة كما كان ──
  PERFORM set_config('request.jwt.claims','{"email":"lk_office@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  SELECT (SELECT count(*) FROM proc_supplier_registrations WHERE id='LK-1')
       + (SELECT count(*) FROM proc_rfqs           WHERE id='LK-RFQ')
       + (SELECT count(*) FROM proc_rfq_quotes     WHERE id='LK-Q')
       + (SELECT count(*) FROM proc_item_aliases   WHERE item_code='LK-C')
       + (SELECT count(*) FROM proc_ai_usage       WHERE username='lk_office')
       + (SELECT count(*) FROM proc_pr_attachments WHERE pr_id='LK-PR')
       + (SELECT count(*) FROM proc_pr_audit       WHERE pr_id='LK-PR')
    INTO v_cnt;
  PERFORM set_config('role','postgres',true);
  IF v_cnt <> 7 THEN
    RAISE EXCEPTION 'LK1 فشل (انحدار): موظّف المكتب يقرأ % من 7 جداول', v_cnt;
  END IF;

  -- ── LK2: الموظّف المُنطَّق محجوب عن الجداول السبعة كلّها ──
  PERFORM set_config('request.jwt.claims','{"email":"lk_field@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  SELECT (SELECT count(*) FROM proc_supplier_registrations)
       + (SELECT count(*) FROM proc_rfqs)
       + (SELECT count(*) FROM proc_rfq_quotes)
       + (SELECT count(*) FROM proc_item_aliases)
       + (SELECT count(*) FROM proc_ai_usage)
       + (SELECT count(*) FROM proc_pr_attachments)
       + (SELECT count(*) FROM proc_pr_audit)
    INTO v_cnt;
  PERFORM set_config('role','postgres',true);
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'LK2 فشل: المُنطَّق قرأ % صفّاً من الجداول المُقفَلة', v_cnt;
  END IF;

  RAISE NOTICE 'LK1–LK2 نجحت';
END $$;

-- ── LK3: المُنطَّق لا يعدّل ولا يحذف طلب تسجيل (auth_update/auth_delete كانتا مفتوحتين) ──
DO $$
DECLARE v_n int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"lk_field@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    UPDATE proc_supplier_registrations SET iban='SA0000000000000000000000' WHERE id='LK-1';
    GET DIAGNOSTICS v_n = ROW_COUNT;
  EXCEPTION WHEN insufficient_privilege THEN v_n := 0;
  END;
  IF v_n <> 0 THEN
    PERFORM set_config('role','postgres',true);
    RAISE EXCEPTION 'LK3 فشل: المُنطَّق عدّل آيبان مورّد (% صفّاً)', v_n;
  END IF;
  BEGIN
    DELETE FROM proc_supplier_registrations WHERE id='LK-1';
    GET DIAGNOSTICS v_n = ROW_COUNT;
  EXCEPTION WHEN insufficient_privilege THEN v_n := 0;
  END;
  PERFORM set_config('role','postgres',true);
  IF v_n <> 0 THEN RAISE EXCEPTION 'LK3 فشل: المُنطَّق حذف طلب تسجيل'; END IF;
  RAISE NOTICE 'LK3 نجحت';
END $$;

-- ── LK4: ولا يُدرِج — الإقفال يحكم WITH CHECK كذلك ──
--    (`public_insert` مفتوحة لـauthenticated، وRESTRICTIVE تُجمَع معها بـAND.)
DO $$
DECLARE v_bad boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"lk_field@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    INSERT INTO proc_supplier_registrations (id, legal_name_ar, status)
    VALUES ('LK-FORGED','مزوَّر','pending');
    v_bad := true;
  EXCEPTION WHEN others THEN v_bad := false;
  END;
  PERFORM set_config('role','postgres',true);
  IF v_bad THEN RAISE EXCEPTION 'LK4 فشل: المُنطَّق أدرج طلب تسجيل'; END IF;
  RAISE NOTICE 'LK4 نجحت';
END $$;

-- ── LK5: نموذج التسجيل العامّ (anon) لم يُمَسّ — وهو الشرط الذي فرض RESTRICTIVE ──
DO $$
DECLARE v_bad boolean := false; v_n int;
BEGIN
  PERFORM set_config('request.jwt.claims','',true);
  PERFORM set_config('role','anon',true);
  BEGIN
    INSERT INTO proc_supplier_registrations (id, legal_name_ar, status)
    VALUES ('LK-ANON','تسجيل عامّ','pending');
  EXCEPTION WHEN others THEN v_bad := true;
  END;
  PERFORM set_config('role','postgres',true);
  IF v_bad THEN
    RAISE EXCEPTION 'LK5 فشل: الإقفال كسر نموذج تسجيل الموردين العامّ (anon)';
  END IF;
  SELECT count(*) INTO v_n FROM pg_policies
   WHERE schemaname='public' AND tablename='proc_supplier_registrations'
     AND 'anon' = ANY(roles);
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'LK5 فشل: سياستا anon لم تعودا 2 (وجدت %)', v_n;
  END IF;
  RAISE NOTICE 'LK5 نجحت';
END $$;

-- ── LK6: كل سياسة إقفال RESTRICTIVE فعلاً، وعلى السبعة كلّها ──
--    RESTRICTIVE تُجمَع بـAND؛ ولو أُنشئت متساهلةً لجُمِعت بـOR فوسّعت الوصول
--    بدل أن تُضيّقه — وهو انقلاب صامت لا يُمسَك إلا بفحص نوع السياسة.
DO $$
DECLARE v_n int; v_bad text;
BEGIN
  SELECT count(*) INTO v_n FROM pg_policies
   WHERE schemaname='public' AND policyname='no_scoped_access' AND permissive='RESTRICTIVE';
  IF v_n <> 7 THEN
    RAISE EXCEPTION 'LK6 فشل: سياسات الإقفال RESTRICTIVE عددها % لا 7', v_n;
  END IF;
  SELECT string_agg(tablename, ', ') INTO v_bad FROM pg_policies
   WHERE schemaname='public' AND policyname='no_scoped_access' AND permissive <> 'RESTRICTIVE';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'LK6 فشل: سياسة إقفال متساهلة (تُوسِّع لا تُضيّق) على %', v_bad;
  END IF;
  RAISE NOTICE 'LK6 نجحت';
END $$;

-- ── LK7: الأدمن المُنطَّق محجوب كذلك — الإقفال نطاقٌ لا رتبة ──
--    (توثيق سلوك مقصود: `proc_is_scoped()` لا تستثني الأدمن، فأدمنٌ أُسنِد
--     له قطاع يفقد هذه الجداول. المالك أدمن **بلا** نطاق فلا يمسّه شيء.)
DO $$
DECLARE v_cnt int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"lk_admin@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  SELECT count(*) INTO v_cnt FROM proc_supplier_registrations;
  PERFORM set_config('role','postgres',true);
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'LK7 فشل: أدمن مُنطَّق قرأ % طلب تسجيل', v_cnt;
  END IF;
  RAISE NOTICE 'LK7 نجحت';
END $$;

SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);
DELETE FROM proc_supplier_registrations WHERE id LIKE 'LK-%';
DELETE FROM proc_rfq_quotes  WHERE id='LK-Q';
DELETE FROM proc_rfqs        WHERE id='LK-RFQ';
DELETE FROM proc_item_aliases WHERE item_code='LK-C';
DELETE FROM proc_ai_usage    WHERE username='lk_office';
DELETE FROM proc_pr_attachments WHERE pr_id='LK-PR';
DELETE FROM proc_pr_audit    WHERE pr_id='LK-PR';
DELETE FROM proc_users WHERE username IN ('lk_office','lk_field','lk_admin');
SELECT set_config('request.jwt.claims', '', false);

-- ════════════════════════════════════════════════════════════════════════
--  تحصين أمني شامل — نظام مجموعة الذيابي (التسعير + تسجيل الموردين)
--  يُنفَّذ مرة واحدة في:  Supabase Dashboard → SQL Editor → Run
--  (يُغني عن hardened-rls.sql ويضيف: قفل proc_users، تقييد إدراج التسجيل،
--   حماية التخزين، وتحصين الدوال SECURITY DEFINER).
--
--  ⚠️ متطلّب مسبق: يجب أن تسجّل لوحة الإدارة (index.html) الدخول عبر Supabase
--     Auth قبل التطبيق، وإلا تتوقف قراءة/كتابة البيانات (تعمل بمفتاح anon).
--  المبدأ الذهبي: مفتاح anon العام (المنشور في صفحة التسجيل) يجب ألّا يمنح
--     أي وصول للبيانات إطلاقاً — لا قراءة ولا كتابة — عدا:
--       (1) إرسال طلب تسجيل جديد (INSERT بحالة pending فقط)، و
--       (2) دوال البوابة الآمنة (RPC) التي تتحقق من رمز سرّي على الخادم.
-- ════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 0) إزالة أي سرّ متبقٍّ من جدول الإعدادات (مفتاح Gemini انتقل للخادم)
-- ─────────────────────────────────────────────────────────────────────────
UPDATE proc_settings SET value = value - 'api_key'
 WHERE key = 'ai_config' AND value ? 'api_key';

-- ─────────────────────────────────────────────────────────────────────────
-- 1) جداول البيانات: للمصادَق عليهم فقط (authenticated)، ومنع anon تمامًا
--    تشمل: الأصناف، الموردين، السجل، المرادفات، الإشعارات، طلبات الشراء،
--    طلبات عروض الأسعار وعروضها، واستخدام الذكاء.
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text;
DECLARE p record;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'proc_items','proc_suppliers','proc_history','proc_item_aliases',
    'proc_notifications','proc_purchase_requests','proc_rfqs','proc_rfq_quotes',
    'proc_ai_usage'
  ] LOOP
    -- تجاهل الجدول إن لم يكن موجوداً (حسب الوحدات المفعّلة)
    IF to_regclass('public.'||t) IS NULL THEN CONTINUE; END IF;
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    -- أسقط كل السياسات القديمة على هذا الجدول (تنظيف شامل)
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=t LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p.policyname, t);
    END LOOP;
    EXECUTE format('CREATE POLICY "auth_read"  ON %I FOR SELECT TO authenticated USING (true)', t);
    EXECUTE format('CREATE POLICY "auth_write" ON %I FOR ALL    TO authenticated USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) المستخدمون: قراءة للمصادَق عليهم فقط، والكتابة عبر service_role فقط.
--    هذا يمنع «تصعيد الصلاحية»: لا يستطيع مستخدم عادي تعديل صفّه ليصبح مديراً
--    عبر REST، لأن كل إدارة المستخدمين تمرّ عبر /api/admin-users (service_role).
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE p record;
BEGIN
  IF to_regclass('public.proc_users') IS NOT NULL THEN
    ALTER TABLE proc_users ENABLE ROW LEVEL SECURITY;
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='proc_users' LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON proc_users', p.policyname);
    END LOOP;
    -- قراءة فقط للمصادَق عليهم (التطبيق يحتاجها لجلب الدور والصلاحيات)
    CREATE POLICY "auth_read_only" ON proc_users FOR SELECT TO authenticated USING (true);
    -- لا سياسة كتابة لـ authenticated → الكتابة حصراً عبر service_role (يتجاوز RLS).
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) الإعدادات: قراءة/كتابة للمصادَق عليهم (لم تعد تحوي أسراراً بعد الخطوة 0)
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE p record;
BEGIN
  IF to_regclass('public.proc_settings') IS NOT NULL THEN
    ALTER TABLE proc_settings ENABLE ROW LEVEL SECURITY;
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='proc_settings' LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON proc_settings', p.policyname);
    END LOOP;
    CREATE POLICY "auth_all" ON proc_settings FOR ALL TO authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4) سجل التدقيق: قراءة/إضافة للمصادَق عليهم، لا تعديل ولا حذف (سجل غير قابل للعبث)
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE p record;
BEGIN
  IF to_regclass('public.proc_audit_log') IS NOT NULL THEN
    ALTER TABLE proc_audit_log ENABLE ROW LEVEL SECURITY;
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='proc_audit_log' LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON proc_audit_log', p.policyname);
    END LOOP;
    CREATE POLICY "auth_read"   ON proc_audit_log FOR SELECT TO authenticated USING (true);
    CREATE POLICY "auth_insert" ON proc_audit_log FOR INSERT TO authenticated WITH CHECK (true);
    -- لا UPDATE/DELETE لأحد عبر anon/authenticated (التنظيف عبر service_role/SQL فقط).
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5) تسجيل الموردين (الجدول العام الأهم — معرّض للجميع):
--    • anon: INSERT فقط، وبحالة 'pending' حصراً (يمنع المورد من اعتماد نفسه).
--    • لا قراءة ولا تعديل ولا حذف عبر anon (حماية كاملة لبيانات الموردين PII).
--    • فريق المشتريات (authenticated): قراءة + تعديل (المراجعة/الاعتماد).
--    • الاستئناف/التعديل من المورد يتم عبر دوال RPC آمنة بالـ token (انظر الخطوة 6).
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE p record;
BEGIN
  IF to_regclass('public.proc_supplier_registrations') IS NOT NULL THEN
    ALTER TABLE proc_supplier_registrations ENABLE ROW LEVEL SECURITY;
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='proc_supplier_registrations' LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON proc_supplier_registrations', p.policyname);
    END LOOP;
    -- إرسال طلب جديد فقط، وبحالة pending (يمنع حقن status=approved أو قراءة الغير)
    CREATE POLICY "public_insert_pending" ON proc_supplier_registrations
      FOR INSERT TO anon, authenticated
      WITH CHECK (status = 'pending');
    -- القراءة والتعديل للمصادَق عليهم فقط (فريق المشتريات)
    CREATE POLICY "auth_read"   ON proc_supplier_registrations FOR SELECT TO authenticated USING (true);
    CREATE POLICY "auth_update" ON proc_supplier_registrations FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
    CREATE POLICY "auth_delete" ON proc_supplier_registrations FOR DELETE TO authenticated USING (true);
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6) تحصين دوال البوابة الآمنة (SECURITY DEFINER) — تثبيت search_path
--    يمنع هجمات search_path على الدوال التي تعمل بصلاحيات المالك.
-- ─────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF to_regprocedure('public.get_rfq_for_supplier(text,text)') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION public.get_rfq_for_supplier(text,text) SET search_path = public, pg_temp';
  END IF;
  IF to_regprocedure('public.submit_supplier_quote(text,text,jsonb,jsonb,jsonb,text,boolean)') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION public.submit_supplier_quote(text,text,jsonb,jsonb,jsonb,text,boolean) SET search_path = public, pg_temp';
  END IF;
  IF to_regprocedure('public.get_registration_for_resume(text,text)') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION public.get_registration_for_resume(text,text) SET search_path = public, pg_temp';
  END IF;
  IF to_regprocedure('public.resubmit_registration(text,text,jsonb)') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION public.resubmit_registration(text,text,jsonb) SET search_path = public, pg_temp';
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7) التخزين (Storage) — حاوية مستندات الموردين 'supplier-docs'
--    اجعلها خاصة: Dashboard → Storage → supplier-docs → Make private.
--    ثم طبّق سياسات الكائنات: رفع للجميع (المورد المجهول)، قراءة للمصادَق عليهم فقط.
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE p record;
BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    FOR p IN SELECT policyname FROM pg_policies
             WHERE schemaname='storage' AND tablename='objects'
               AND policyname IN ('supplier_docs_insert','supplier_docs_read','supplier_docs_auth_all') LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', p.policyname);
    END LOOP;
    -- رفع المستندات (المورد المجهول أثناء التسجيل) — للحاوية المحددة فقط
    CREATE POLICY "supplier_docs_insert" ON storage.objects
      FOR INSERT TO anon, authenticated
      WITH CHECK (bucket_id = 'supplier-docs');
    -- قراءة/إدارة المستندات للمصادَق عليهم فقط (فريق المشتريات)
    CREATE POLICY "supplier_docs_auth_all" ON storage.objects
      FOR ALL TO authenticated
      USING (bucket_id = 'supplier-docs')
      WITH CHECK (bucket_id = 'supplier-docs');
  END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 8) تحقّق نهائي — اعرض السياسات الحالية للتأكد أنه لا يوجد وصول anon واسع
--    يجب ألّا ترى 'anon' إلا على: public_insert_pending + supplier_docs_insert
-- ─────────────────────────────────────────────────────────────────────────
SELECT schemaname, tablename, policyname, roles, cmd
  FROM pg_policies
 WHERE schemaname IN ('public','storage')
 ORDER BY schemaname, tablename, policyname;

-- ════════════════════════════════════════════════════════════════════════
--  انتهى. بعد التشغيل: أي شخص يملك مفتاح anon لا يستطيع رؤية أو تعديل أي
--  بيانات شركة. أقصى ما يفعله المورد المجهول: إرسال طلب تسجيل (pending) ورفع
--  مستنداته، واستئناف طلبه برمزه السرّي فقط. وفي حال «اختراق» صفحة التسجيل
--  أو تسريب مفتاح anon، تبقى القاعدة والنظام الرئيسي محميّين بالكامل.
-- ════════════════════════════════════════════════════════════════════════

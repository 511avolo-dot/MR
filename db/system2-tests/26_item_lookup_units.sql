-- ============================================================================
--  IL0–IL9 — كتالوج بلا أسعار + سجلّ الوحدات + سحب anon عن دوال المُشغِّلات
--  (db/system2-item-lookup-and-units.sql) — تُشغَّل بعد تحميل الهجرة في run.sh.
-- ----------------------------------------------------------------------------
--  ⚠️ الدور فعليّ (`SET LOCAL ROLE authenticated`) لا فحص نصّ سياسة.
--  و**IL0 شرط لازم**: يُثبت أنّ العَرَض المُبلَّغ عنه قائمٌ فعلاً قبل الهجرة —
--  وإلّا كان IL1 تأكيداً فراغيّاً يمرّ على قاعدة لا مشكلة فيها أصلاً
--  (درس PA0/WC: أعِد بناء حالة الإنتاج ثمّ أثبت أنّ الهجرة هي التي داوتها).
-- ============================================================================
\set ON_ERROR_STOP on

SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

DO $il$
DECLARE v_n int; v_t text; v_ok boolean;
BEGIN
  -- ── بذرة: موظّف ميدان (مُنطَّق، بلا صلاحية مبالغ) وموظّف مكتب ──
  DELETE FROM proc_users WHERE username IN ('il_field','il_office');
  INSERT INTO proc_users (username, display_name, role, active, email, scope_sectors, permissions)
  VALUES ('il_field','ميدانيّ','user', true,'il_field@aldeyabi.com','["الصيانة والتشغيل"]'::jsonb,
          '{"can_view_amounts":false}'::jsonb),
         ('il_office','مكتب','user', true,'il_office@aldeyabi.com', NULL, '{}'::jsonb);

  DELETE FROM proc_items WHERE code LIKE 'IL-%';
  INSERT INTO proc_items (code,name,category,unit) VALUES
    ('IL-1','صابون سائل اختبار','تنظيف','حبه'),      -- كتابة قاطعة تُصحَّح
    ('IL-2','منظف زجاج اختبار','تنظيف','كرتونة'),    -- كتابة قاطعة تُصحَّح
    ('IL-3','أسمنت اختبار','بناء','شوال'),           -- سليمة
    ('IL-4','لوح اختبار','بناء','بالعدد');           -- دلاليّة: تبقى كما هي

  -- ── IL0 [شرط لازم] العَرَض المُبلَّغ عنه: الميدان يقرأ صفر صنف ──
  PERFORM set_config('request.jwt.claims', json_build_object('email','il_field@aldeyabi.com')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n FROM proc_items WHERE code LIKE 'IL-%';
  RESET ROLE;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'IL0: الشرط اللازم غير متحقّق — الميدان يقرأ % صنفاً من proc_items فلا عَرَض نداوي', v_n;
  END IF;
  RAISE NOTICE '  ✓ IL0 [شرط لازم] موظّف الميدان يقرأ صفر صنف من proc_items (العَرَض قائم)';
END $il$;

-- ⚠️ الهجرة تُشغَّل **بعد** بذر الكتابات المتّسخة، وإلّا كان تنظيفُها قد جرى
-- على قاعدة نظيفة فصار IL6 تأكيداً فراغيّاً. وإعادة تشغيلها هنا تُثبت
-- idempotency أيضاً (درس 23/24: أعِد بناء الحالة ثمّ أثبت أنّ الهجرة داوتها).
\i db/system2-item-lookup-and-units.sql

SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

DO $il2$
DECLARE v_n int; v_t text; v_ok boolean;
BEGIN
  -- ── IL1 والعرض يرفع الحجب: الاسم والوحدة يصلانه ──
  PERFORM set_config('request.jwt.claims', json_build_object('email','il_field@aldeyabi.com')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n FROM proc_items_lookup WHERE name LIKE '%اختبار%';
  RESET ROLE;
  IF v_n <> 4 THEN RAISE EXCEPTION 'IL1: الميدان قرأ % صنفاً من العرض بدل 4', v_n; END IF;
  RAISE NOTICE '  ✓ IL1 والعرض يوصل له الكتالوج (4 أصناف)';

  -- ── IL2 قائمة السماح: أربعة أعمدة بالاسم، ولا عمود خارجها ──
  SELECT string_agg(column_name, ',' ORDER BY column_name) INTO v_t
    FROM information_schema.columns WHERE table_schema='public' AND table_name='proc_items_lookup';
  IF v_t IS DISTINCT FROM 'category,code,name,unit' THEN
    RAISE EXCEPTION 'IL2: أعمدة العرض = % (المتوقَّع category,code,name,unit)', coalesce(v_t,'NULL');
  END IF;
  RAISE NOTICE '  ✓ IL2 العرض قائمة سماح صريحة — notes وcreated_by وغيرها لا تمرّ';

  -- ── IL3 والكتالوج ليس عامّاً ──
  IF has_table_privilege('anon','proc_items_lookup','SELECT') THEN
    RAISE EXCEPTION 'IL3: anon يقرأ كتالوج الأصناف';
  END IF;
  RAISE NOTICE '  ✓ IL3 anon لا يقرأ العرض';

  -- ── IL4 صفر انحدار: موظّف المكتب يقرأ الجدول كما كان ──
  PERFORM set_config('request.jwt.claims', json_build_object('email','il_office@aldeyabi.com')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n FROM proc_items WHERE code LIKE 'IL-%';
  RESET ROLE;
  IF v_n <> 4 THEN RAISE EXCEPTION 'IL4: انحدار — موظّف المكتب قرأ % بدل 4', v_n; END IF;
  RAISE NOTICE '  ✓ IL4 صفر انحدار لموظّف المكتب';

  -- ── IL5 التطبيع: القاطع يُوحَّد والدلاليّ لا يُمَسّ ──
  IF proc_unit_canon('حبه') <> 'حبة' OR proc_unit_canon('ﺣبة') <> 'حبة'
     OR proc_unit_canon('كرتونة') <> 'كرتون' OR proc_unit_canon('M2') <> 'متر مربع'
     OR proc_unit_canon('متر  طولي') <> 'متر طولي' THEN
    RAISE EXCEPTION 'IL5: التطبيع لم يوحّد كتابة قاطعة';
  END IF;
  IF proc_unit_canon('بالعدد') <> 'بالعدد' OR proc_unit_canon('عدد') <> 'عدد'
     OR proc_unit_canon('علبة 300 مل') <> 'علبة 300 مل' THEN
    RAISE EXCEPTION 'IL5: التطبيع أجرى دمجاً دلاليّاً — وهو قرار بشريّ لا آليّ';
  END IF;
  RAISE NOTICE '  ✓ IL5 التطبيع يوحّد القاطع ولا يدمج الدلاليّ';

  -- ── IL6 التنظيف أصاب الكتالوج فعلاً (الهجرة شغّلته) ──
  SELECT count(*) INTO v_n FROM proc_items
   WHERE code LIKE 'IL-%' AND unit IS DISTINCT FROM proc_unit_canon(unit);
  IF v_n <> 0 THEN RAISE EXCEPTION 'IL6: بقيت % وحدة غير مطبَّعة في الكتالوج', v_n; END IF;
  SELECT unit INTO v_t FROM proc_items WHERE code='IL-4';
  IF v_t <> 'بالعدد' THEN RAISE EXCEPTION 'IL6: الوحدة الدلاليّة دُهِست إلى %', v_t; END IF;
  RAISE NOTICE '  ✓ IL6 التنظيف طبَّع الكتالوج وأبقى الدلاليّ كما هو';

  -- ── IL7 العرض يُطبّع حتى لو أُدرج صفٌّ جديد بكتابة قديمة ──
  INSERT INTO proc_items (code,name,category,unit) VALUES ('IL-9','قلم اختبار','قرطاسية','pcs');
  SELECT unit INTO v_t FROM proc_items_lookup WHERE code='IL-9';
  IF v_t <> 'حبة' THEN RAISE EXCEPTION 'IL7: العرض لم يُطبّع وحدة صفّ جديد (%)', coalesce(v_t,'NULL'); END IF;
  RAISE NOTICE '  ✓ IL7 العرض يُطبّع الوحدة وقت القراءة لا وقت التنظيف وحده';

  -- ── IL8 صفٌّ بلا اسم لا يظهر في قائمة الإكمال ──
  INSERT INTO proc_items (code,name,category,unit) VALUES ('IL-0','', 'x','حبة');
  SELECT count(*) INTO v_n FROM proc_items_lookup WHERE code='IL-0';
  IF v_n <> 0 THEN RAISE EXCEPTION 'IL8: صفّ بلا اسم ظهر في قائمة الإكمال'; END IF;
  RAISE NOTICE '  ✓ IL8 الصفّ بلا اسم مستبعَد (لا خيار فارغ في القائمة)';

  -- ── IL9 anon لا ينفّذ دوال المُشغِّلات — **والمُشغِّل ما زال يعمل** ──
  -- ⚠️ سحب EXECUTE عن دالّة مُشغِّل قد يُعطّلها، فالتحقّق بالتشغيل لا بالقراءة.
  SELECT bool_or(has_function_privilege('anon', p.oid, 'EXECUTE')) INTO v_ok
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public'
     AND p.proname IN ('pr_guard_status','pr_set_due','proc_pr_audit_fill_actor_name');
  IF coalesce(v_ok,false) THEN RAISE EXCEPTION 'IL9: anon ما زال ينفّذ دالّة مُشغِّل'; END IF;
  -- والمُشغِّل نفسه: تحديث صفّ الكتالوج ما زال يمرّ (لم نُعطِّل شيئاً).
  UPDATE proc_items SET category='قرطاسية2' WHERE code='IL-9';
  SELECT category INTO v_t FROM proc_items WHERE code='IL-9';
  IF v_t <> 'قرطاسية2' THEN RAISE EXCEPTION 'IL9: الكتابة انكسرت بعد سحب الصلاحيات'; END IF;
  RAISE NOTICE '  ✓ IL9 anon محجوب عن دوال المُشغِّلات والكتابة ما زالت تعمل';

  -- تنظيف
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  DELETE FROM proc_items WHERE code LIKE 'IL-%';
  DELETE FROM proc_users WHERE username IN ('il_field','il_office');
END $il2$;

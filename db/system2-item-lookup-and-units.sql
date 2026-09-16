-- ============================================================================
--  كتالوج بلا أسعار لموظّف الميدان + سجلّ الوحدات المعتمد
--  النظام 2 (proc_*) على مشروع Supabase القديم yofcaxvstjcrmbgciwym
--  تُطبَّق بعد: db/system2-staff-scope.sql (تحتاج proc_is_scoped/proc_can_view_amounts)
-- ----------------------------------------------------------------------------
--  السبب (مقيس على الإنتاج قبل أي كود، لا مُخمَّن):
--
--   (أ) سياسة `cat_select` على `proc_items` هي
--         ((NOT proc_is_scoped()) OR proc_can_view_amounts())
--       فموظّف الميدان الذي حُجبت عنه المبالغ **يقرأ صفر صنف** — وقائمة الإكمال
--       التلقائيّ في نموذج الطلب تُبنى من `STATE.items` فتصله **فارغة**.
--       النتيجة المقيسة: 63 وصفاً مختلفاً في بنود الطلبات، **ولا واحد** منها
--       يطابق كتالوجاً فيه 711 صنفاً. أي أنّ الموظّف يكتب الأسماء من رأسه.
--
--   ⚠️ تصحيحٌ لفرضيّةٍ بدت بدهيّة: **`proc_items` لا يحمل عمود سعر إطلاقاً**
--      (مقيس: code · name · category · unit · notes · created/updated_* = تسعة
--      أعمدة، صفر ماليّ؛ الأسعار في `proc_history` ويشتقّها العميل). فالسياسة
--      تحجبه خلف صلاحية المبالغ **رغم أنّه ليس ماليّاً**.
--      ولماذا لم نُوسِّع `cat_select` إذن وهو الأبسط؟ لأنّ توسيعه يمنح الجدول
--      **كما سيصير** لا كما هو: أي عمود ماليّ يُضاف لاحقاً يتسرّب صامتاً، و`notes`
--      قد تحمل ملاحظة تجارية. فالعرض **قائمة سماح صريحة بالأعمدة** — نفس نمط
--      `proc_po_visible` و`portal_user_directory` وقائمة مفاتيح `proc_settings`.
--
--   (ب) 39 وحدة مختلفة لـ711 صنفاً، وأكثرها كتابات لنفس الوحدة:
--         حبة 475 · حبه 13 · ﺣبة 4 (رموز عرض) · حيه 1 · جبه 1
--         كرتون 66 · كرتونة · BOX      |  قطعة 27 · قطمة
--         وحدة 17 · وحده              |  لفة 10 · لفه
--         درزن 6 · دزينة              |  كيلو 2 · كجم
--         بالة · باالة                |  «متر  طولي» (مسافتان) · «متر طولي»
--       فلا يمكن تجميع كمية ولا مقارنة عرضين على وحدة واحدة.
-- ============================================================================

BEGIN;

-- ============================================================================
--  1) تطبيع الوحدات — دالّة نقيّة تُستعمَل للتنظيف وللمقارنة مستقبلاً
-- ----------------------------------------------------------------------------
--  ⚠️ حدّها المقصود: **الكتابات القاطعة فقط** (خطأ إملائيّ · رموز عرض · مسافة
--  زائدة · نقل حرفيّ لاتينيّ). أمّا الدمج الدلاليّ («عدد» ⇐ «حبة») فلا تفعله
--  هذه الدالّة — درس سجلّ المشاريع: `ok` يُطبَّق و`suggest` لا يُطبَّق بلا قرار بشريّ.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.proc_unit_canon(p_unit text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $$
  WITH n AS (
    SELECT btrim(regexp_replace(
             regexp_replace(
               -- رموز العرض العربية (U+FB50–FEFF) تبدو عربيّة وهي محارف أخرى
               regexp_replace(normalize(coalesce(p_unit,''), NFKC), '[ً-ْـ]', '', 'g'),
             '\s+', ' ', 'g'),
           '[.،,]+$', '', 'g')) u
  )
  SELECT CASE lower(u)
    WHEN 'حبه'  THEN 'حبة'  WHEN 'حيه'   THEN 'حبة'  WHEN 'جبه'  THEN 'حبة'
    WHEN 'pcs'  THEN 'حبة'  WHEN 'pc'    THEN 'حبة'  WHEN 'piece' THEN 'حبة'
    WHEN 'كرتونة' THEN 'كرتون' WHEN 'box' THEN 'كرتون' WHEN 'بوكس' THEN 'كرتون'
    WHEN 'قطمة' THEN 'قطعة'
    WHEN 'وحده' THEN 'وحدة'
    WHEN 'لفه'  THEN 'لفة'
    WHEN 'باالة' THEN 'بالة'
    WHEN 'دزينة' THEN 'درزن' WHEN 'دستة' THEN 'درزن'
    WHEN 'كجم'  THEN 'كيلو' WHEN 'كغم'  THEN 'كيلو' WHEN 'kg' THEN 'كيلو'
    WHEN 'م مربع' THEN 'متر مربع' WHEN 'm2' THEN 'متر مربع' WHEN 'م2' THEN 'متر مربع'
    WHEN 'م طولي' THEN 'متر طولي' WHEN 'م.طولي' THEN 'متر طولي'
    WHEN 'ltr'  THEN 'لتر'  WHEN 'l'    THEN 'لتر'
    ELSE u
  END FROM n;
$$;

COMMENT ON FUNCTION public.proc_unit_canon(text) IS
  'تطبيع كتابة الوحدة: رموز العرض والتشكيل والتطويل والمسافات المكرّرة + خريطة '
  'الكتابات القاطعة (حبه/ﺣبة/pcs ⇐ حبة). لا تُجري دمجاً دلاليّاً (عدد ⇎ حبة).';

REVOKE ALL ON FUNCTION public.proc_unit_canon(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.proc_unit_canon(text) TO authenticated, service_role;

-- ============================================================================
--  2) عرض الكتالوج بلا أسعار
-- ----------------------------------------------------------------------------
--  `security_invoker=false` (امتياز المالك) — نفس نمط `portal_user_directory`
--  المُوثَّق في النظام 3: قائمة سماح صريحة بأربعة أعمدة **مرجعية للإدخال فقط**.
--  وعمود `notes` مستبعَد عمداً (قد يحمل ملاحظة تجارية)، وأي عمود يُضاف للجدول
--  لاحقاً **لا يمرّ من هنا** إلا بتعديل واعٍ لهذا التعريف.
--  ⚠️ لا يُمنَح لـ`anon` إطلاقاً — الكتالوج ليس عامّاً.
-- ============================================================================
DROP VIEW IF EXISTS public.proc_items_lookup;
CREATE VIEW public.proc_items_lookup
WITH (security_invoker = false)
AS SELECT
     i.code,
     i.name,
     i.category,
     public.proc_unit_canon(i.unit) AS unit
   FROM public.proc_items i
   WHERE coalesce(i.name,'') <> '';

COMMENT ON VIEW public.proc_items_lookup IS
  'كتالوج الأصناف للإدخال — الاسم والوحدة والفئة فقط، بلا أي عمود ماليّ. '
  'يقرأه كل مستخدم مسجَّل بما فيهم الموظّف المُنطَّق الذي تحجب عنه سياسة '
  'cat_select جدولَ proc_items لأنّه يحمل الأسعار.';

REVOKE ALL ON public.proc_items_lookup FROM PUBLIC, anon;
GRANT SELECT ON public.proc_items_lookup TO authenticated, service_role;

-- ============================================================================
--  3) سحب تنفيذ anon عن دوال المُشغِّلات (من مدقّق Supabase الحيّ)
-- ----------------------------------------------------------------------------
--  ثلاث دوال DEFINER تُستدعى **عبر المُشغِّل وحده** وكانت مكشوفة لـ`anon`
--  (مُتحقَّق حيّاً: has_function_privilege('anon',…,'EXECUTE') = true للثلاث).
--  ⚠️ سحب EXECUTE لا يُعطّل المُشغِّل — فهو يُنفَّذ ضمن سياق الجملة لا باستدعاء
--  العميل. ومع ذلك يُتحقَّق بالتشغيل لا بالقراءة (سابقة `system2-definer-exposure`).
-- ============================================================================
DO $rev$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('pr_guard_status','pr_set_due','proc_pr_audit_fill_actor_name')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
  END LOOP;
END $rev$;

COMMIT;

-- ============================================================================
--  4) تنظيف كتابات الوحدات في الكتالوج — بيانات لا مخطّط (مرّة واحدة، idempotent)
-- ----------------------------------------------------------------------------
--  ⚠️ يمسّ `proc_items` وحده (بيانات مرجعية). **لا يمسّ `proc_pr_items`**:
--  بند طلبٍ مُرسَل سجلٌّ لقرار، ووحدته كما كتبها صاحبه جزء من ذلك السجلّ.
--  ⚠️ والدمج الدلاليّ متروك عمداً: «عدد/العدد/بالعدد» قد تعني «حبة» وقد تعني
--  غيرها، و«علبة 300 مل» وحدةٌ بحجمها. تُعرَض للمالك ولا تُكتَب.
-- ============================================================================
DO $clean$
DECLARE v_n int := 0;
BEGIN
  IF to_regclass('public.proc_items') IS NULL THEN RETURN; END IF;

  -- حارس الصلاحية: الكتابة على الكتالوج تمرّ بسياسات/حُرّاس، وقناة الهجرة بلا JWT.
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);

  UPDATE public.proc_items
     SET unit = public.proc_unit_canon(unit)
   WHERE coalesce(unit,'') <> ''
     AND unit IS DISTINCT FROM public.proc_unit_canon(unit);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n > 0 AND to_regclass('public.proc_audit_log') IS NOT NULL THEN
    INSERT INTO public.proc_audit_log (username, display_name, user_role, action, entity_type, entity_id, new_value)
    VALUES ('system','تصحيح بيانات','system','items_unit_canon','items','*',
            jsonb_build_object('rows', v_n, 'reason','توحيد كتابة الوحدة (قاطع فقط — لا دمج دلاليّ)'));
  END IF;

  RAISE NOTICE 'unit canon rows: %', v_n;
END $clean$;

-- ============================================================================
--  تحقّق بعد التطبيق:
--    select count(distinct unit) from proc_items where coalesce(unit,'')<>'';
--    select * from proc_items_lookup limit 3;               -- بلا أي عمود سعر
--    select has_function_privilege('anon','pr_set_due()','EXECUTE');  -- false
-- ============================================================================

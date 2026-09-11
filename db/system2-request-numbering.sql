-- ════════════════════════════════════════════════════════════════════════════
--  ترقيم الطلبات خادميّاً + تصحيح حذف بنود الطلب (2026-09-11)
-- ----------------------------------------------------------------------------
--  ⚠️ تُطبَّق بعد `db/system2-staff-scope.sql` و`db/system2-request-flow.sql`
--  و`db/system2-request-tracking.sql`. إضافيّة وidempotent.
--
--  (١) عيب **حرِج** كشفه فحص ما بعد التنفيذ: `prNextNumber()` في الواجهة كانت
--      تأخذ أعلى رقم من `STATE.purchaseRequests` — وهي بعد تطبيق النطاق **ما
--      تسمح به RLS فقط** (طلباتي + طلبات قطاعي). فموظّف قطاع يرى أعلى رقم
--      0003 يقترح 0004 بينما 0004 يخصّ قطاعاً آخر محجوباً عنه:
--        • المُنطَّق: `pr_update` ترفض (requester ≠ me) ⇒ «تعذّر الحفظ»،
--          و**كل إعادة محاولة تنتج الرقم نفسه** فيعلق نهائيّاً بلا مخرج.
--        • غير المُنطَّق: السياسة متساهلة و`upsert` كانت تكتب **فوق طلب قائم**.
--      العلاج هنا: الرقم يُحسب على **كل** الصفوف (SECURITY DEFINER) تحت **قفل
--      استشاريّ** فلا يتسابق اثنان على الرقم نفسه. والواجهة تحوّلت إلى
--      `insert` صريح فالتعارض يُكشف بـ23505 بدل أن يُبتلَع.
--
--  (٢) عيب كامن: سياسة حذف بنود الطلب كانت `USING (NOT proc_is_scoped())`،
--      فالموظّف المُنطَّق **لا يستطيع حذف بنود طلبه**. و`prSaveCloud` تحذف ثمّ
--      تُدرِج ⇒ أوّل إعادة حفظ لمسودّته كانت **تضاعف البنود** بصمت. تُصحَّح
--      إلى `proc_can_see_pr(pr_id)` كبقيّة سياسات الجدول (والرؤية نفسها هي
--      حارس النطاق).
-- ════════════════════════════════════════════════════════════════════════════

-- ═══════════════ 1) الرقم التالي — خادميّاً وتحت قفل ═══════════════
CREATE OR REPLACE FUNCTION pr_next_number()
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_year text := to_char(now(), 'YYYY');
  v_pfx  text;
  v_max  int;
BEGIN
  IF proc_me() IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  -- قفل استشاريّ على مستوى المعاملة: طلبان متزامنان لا يأخذان الرقم نفسه.
  PERFORM pg_advisory_xact_lock(hashtext('pr_next_number'));
  v_pfx := 'PR-DG' || v_year || '-';
  -- ⚠️ المقارنة على **كل** الصفوف (الدالّة DEFINER فتتجاوز RLS للقراءة) —
  -- وهذا بالضبط ما لا يستطيعه العميل، وهو أصل العيب.
  SELECT coalesce(max((regexp_replace(id, '^.*?(\d+)\s*$', '\1'))::int), 0)
    INTO v_max
    FROM proc_purchase_requests
   WHERE id LIKE v_pfx || '%'
     AND id ~ '\d+\s*$';
  RETURN v_pfx || lpad((v_max + 1)::text, 4, '0');
END $fn$;

REVOKE ALL ON FUNCTION pr_next_number()    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_next_number() TO authenticated;

-- ═══════════════ 2) حذف بنود الطلب: بالرؤية لا بالنطاق ═══════════════
DROP POLICY IF EXISTS "prc_delete" ON proc_pr_items;
CREATE POLICY "prc_delete" ON proc_pr_items FOR DELETE TO authenticated
  USING (proc_can_see_pr(pr_id));

-- ═══════════════ التراجع (للطوارئ) ═══════════════
/*
DROP FUNCTION IF EXISTS pr_next_number();
DROP POLICY IF EXISTS "prc_delete" ON proc_pr_items;
CREATE POLICY "prc_delete" ON proc_pr_items FOR DELETE TO authenticated
  USING (NOT proc_is_scoped());
*/

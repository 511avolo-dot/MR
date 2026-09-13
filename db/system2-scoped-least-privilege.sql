-- ════════════════════════════════════════════════════════════════════════════
--  نظام 2 — أقلّ امتياز للموظّف المُنطَّق: افتراضيّ «عرض المبالغ» يُصفَّر له
--  ----------------------------------------------------------------------------
--  الجذر: `proc_can_view_amounts()` كانت `coalesce(<المفتاح>, true)` — أي أنّ
--  **غياب** المفتاح يمنح المبالغ. وهو الصواب لموظّفي المكتب القائمين (صفوفهم
--  لا تحمل المفتاح أصلاً، فلا يفقد أحدٌ مبالغه)، لكنّه خطأ للموظّف الميدانيّ:
--  حسابٌ يُنشئه المالك من اللوحة وينسى إلغاء «عرض المبالغ والأسعار» يصير
--  **يستقبل المبالغ من الخادم** رغم أنّ نيّة المالك حجبها عنه.
--
--  رابط الدعوة (functions/api/staff-invite.js) يكتب `can_view_amounts:false`
--  صراحةً فالمدعوّون سالمون؛ هذه الهجرة تُغلق الباب على الإنشاء اليدويّ.
--
--  ⚠️ عدم الانحدار هو القيد الأوّل: الشرط الجديد يتفرّع على `scope_sectors`
--  للصفّ نفسه — غير المُنطَّق (NULL أو []) يبقى افتراضه **true** حرفيّاً كما
--  كان. الأربعة القائمون غير مُنطَّقين ⇒ صفر تغيير عليهم.
--
--  نظيرتها في الواجهة: `hasPermission` صارت تُرجع false للمُنطَّق عند غياب
--  المفتاح (index.html) — فيتطابق الجانبان بدل أن يُخفي أحدهما ما يُرسله الآخر.
--
--  تُشغَّل **بعد** db/system2-staff-scope.sql. إضافيّة وidempotent وقابلة
--  لإعادة التشغيل. كتلة التراجع في نهاية الملف.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION proc_can_view_amounts() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS(
    SELECT 1 FROM proc_users u
     WHERE lower(u.username) = lower(proc_me())
       AND coalesce(u.active, true)
       AND (u.role = 'admin'
            OR coalesce(
                 (u.permissions ->> 'can_view_amounts')::boolean,
                 -- الافتراضيّ عند غياب المفتاح: true لموظّف المكتب، false للمُنطَّق.
                 -- ⚠️ فخّ المنطق الثلاثيّ: `scope_sectors` عمودها **NULL** لكل
                 -- موظفي المكتب القائمين. فبلا `coalesce` الداخليّة يُنتج
                 -- التعبير NULL لا true، فيسقط الصفّ من EXISTS ويفقد الأربعةُ
                 -- القائمون مبالغهم عند النشر. (أمسكه LP1 قبل أي تطبيق حيّ.)
                 -- و`CASE` لا `AND` لأن ترتيب تقييم AND غير مضمون، و
                 -- jsonb_array_length على غير مصفوفة يرمي خطأً.
                 NOT coalesce(
                       CASE WHEN jsonb_typeof(u.scope_sectors) = 'array'
                            THEN jsonb_array_length(u.scope_sectors) > 0 END,
                       false)
               )));
$fn$;

GRANT EXECUTE ON FUNCTION proc_can_view_amounts() TO authenticated;


-- ═══════════════ التحقّق (شغّلها بعد التطبيق) ═══════════════
-- الأربعة القائمون (غير مُنطَّقين، بلا المفتاح) يجب أن يبقوا true:
--   SELECT username, proc_can_view_amounts() FROM proc_users WHERE active;   -- بانتحال كلٍّ
-- ومُنطَّق بلا المفتاح يجب أن يصير false، وبالمفتاح=true يبقى true.


-- ═══════════════ التراجع ═══════════════
-- CREATE OR REPLACE FUNCTION proc_can_view_amounts() RETURNS boolean
-- LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
--   SELECT EXISTS(
--     SELECT 1 FROM proc_users u
--      WHERE lower(u.username) = lower(proc_me())
--        AND coalesce(u.active, true)
--        AND (u.role = 'admin'
--             OR coalesce((u.permissions ->> 'can_view_amounts')::boolean, true)));
-- $fn$;

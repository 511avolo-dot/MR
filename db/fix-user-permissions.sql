-- ════════════════════════════════════════════════════════════════════════
--  إصلاح صلاحيات المستخدمين القائمين — تفعيل الاستيراد/التصدير لغير المديرين
-- ════════════════════════════════════════════════════════════════════════
--  المشكلة: مستخدمو المشتريات (مثل مصطفى ومحمود) أُنشئوا بصلاحيات قديمة تحوي
--  can_import=false و can_export=false صراحةً، فمُنعوا من:
--   • استيراد أمر الشراء من Excel (الزر مخفي عبر data-requires-perm="can_import")
--   • الاستيراد الجماعي CSV
--  بينما أصبح الافتراضي لهذه الصلاحيات «مسموح» في سجل الصلاحيات. القيمة المخزّنة
--  false تتجاوز الافتراضي، لذا نُصحّح السجلّات القائمة هنا.
--
--  يُنفَّذ مرة واحدة في Supabase → SQL Editor (آمن لإعادة التشغيل).
--  ملاحظة: الذكاء الاصطناعي (الاستيراد الذكي/التسعير الذكي) ليس مقيّداً بصلاحية
--  استيراد، بل يحتاج فقط ضبط GEMINI_API_KEY كسرّ على الخادم ليعمل لكل المستخدمين
--  (وليس فقط لمن لديه مفتاح محلي في متصفّحه).
-- ════════════════════════════════════════════════════════════════════════

UPDATE proc_users
   SET permissions = COALESCE(permissions, '{}'::jsonb)
                     || jsonb_build_object('can_import', true, 'can_export', true)
 WHERE role <> 'admin'
   AND (
        COALESCE((permissions->>'can_import')::boolean, true) = false
     OR COALESCE((permissions->>'can_export')::boolean, true) = false
   );

-- تحقّق: استعرض الصلاحيات بعد التحديث
-- SELECT username, role, permissions->>'can_import' AS can_import,
--        permissions->>'can_export' AS can_export
--   FROM proc_users ORDER BY role, username;

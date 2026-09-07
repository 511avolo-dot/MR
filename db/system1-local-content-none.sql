-- نظام 1 — مشروع Supabase القديم `yofcaxvstjcrmbgciwym`
-- إفادة المورّد بعدم امتلاك شهادة محتوى محلي (زرّ «لا توجد لدينا شهادة» في بريد الحملة).
--
-- لماذا عمود جديد و`local_content_has=false` وحده لا يكفي:
-- القيمة `false` مستعمَلة أصلاً لمن أجاب «لا» في **نموذج التسجيل** (19 صفّاً)، فلا
-- تُميّز «أفاد لاحقاً بعدم وجودها» عن «قال لا عند التسجيل» ولا تحمل تاريخ الإفادة.
-- والتمييز مطلوب تشغيليّاً: من أفاد لا يُراسَل ثانيةً، ويُعرض في سجلّه سبب الحسم.
--
-- إضافة فقط · nullable · لا تمسّ صفّاً قائماً · آمنة التكرار.
ALTER TABLE proc_supplier_registrations
  ADD COLUMN IF NOT EXISTS local_content_none_at timestamptz;

COMMENT ON COLUMN proc_supplier_registrations.local_content_none_at IS
  'وقت إفادة المورّد بعدم امتلاكه شهادة محتوى محلي عبر رابط الحملة (NULL = لم يُفِد).';

-- ════════════════════════════════════════════════════════════════════════
--  تأمين مخزن وثائق الموردين (supplier-docs) — حماية مفروضة من الخادم
--  يُنفَّذ في Supabase → SQL Editor. (يعمل بصلاحيات المحرّر العادية.)
--
--  ملاحظة: لا تُضِف "alter table storage.objects ..." — هذا الجدول مملوك
--  لِـ supabase_storage_admin وRLS مُفعّل عليه افتراضياً، ومحاولة تعديله
--  تُعطي الخطأ: must be owner of table objects.
-- ════════════════════════════════════════════════════════════════════════

-- ✅ الحماية الأساسية (هذا هو المهم): فرض الحجم والأنواع المسموحة من الخادم
--    يرفض أي رفع لملف ليس PDF/JPG/PNG أو يتجاوز 10م.ب — مهما كان مصدر الطلب.
update storage.buckets
set file_size_limit    = 10485760,   -- 10 MB
    allowed_mime_types = ARRAY['application/pdf','image/jpeg','image/jpg','image/png']
where id = 'supplier-docs';

-- تحقّق من التطبيق:
select id, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'supplier-docs';

-- ════════════════════════════════════════════════════════════════════════
--  (اختياري) سياسات الوصول RLS — تُضاف من لوحة تحكم Supabase وليس هنا:
--  Dashboard → Storage → (supplier-docs) → Policies → New policy
--
--   • رفع (INSERT): للأدوار anon, authenticated — Condition:  bucket_id = 'supplier-docs'
--   • قراءة (SELECT): للدور authenticated فقط — Condition: bucket_id = 'supplier-docs'
--   • حذف (DELETE): للدور authenticated فقط — Condition: bucket_id = 'supplier-docs'
--
--  ولزيادة الخصوصية: اجعل المخزن Private من إعدادات المخزن، واعرض الوثائق
--  للمدراء عبر روابط موقّتة:  SB.storage.from('supplier-docs').createSignedUrl(path, 3600)
--  بدلاً من getPublicUrl.
-- ════════════════════════════════════════════════════════════════════════

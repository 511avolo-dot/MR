-- ════════════════════════════════════════════════════════════════════════
--  تأمين مخزن وثائق الموردين (supplier-docs) — حماية مفروضة من الخادم
--  يُنفَّذ مرة واحدة في Supabase → SQL Editor.
--
--  لماذا؟ التحقق في register.html (الامتداد/النوع/الحجم/التوقيع) دفاعٌ على
--  جانب العميل فقط، ويمكن تجاوزه بمن يستدعي واجهة Supabase مباشرةً بمفتاح
--  anon. هذه القيود تُفرَض على مستوى الخادم فلا يمكن تجاوزها.
-- ════════════════════════════════════════════════════════════════════════

-- 1) قيود المخزن: حجم أقصى 10 م.ب + أنواع MIME المسموحة فقط (تُفرض خادمياً)
update storage.buckets
set file_size_limit   = 10485760,   -- 10 MB
    allowed_mime_types = ARRAY['application/pdf','image/jpeg','image/jpg','image/png']
where id = 'supplier-docs';

-- إن لم يكن المخزن موجوداً بعد، أنشئه بنفس القيود (وخاصّاً = غير عام):
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
select 'supplier-docs', 'supplier-docs', false, 10485760,
       ARRAY['application/pdf','image/jpeg','image/jpg','image/png']
where not exists (select 1 from storage.buckets where id = 'supplier-docs');

-- ════════════════════════════════════════════════════════════════════════
--  2) سياسات RLS على storage.objects للمخزن (راجِعها قبل التطبيق)
--  - الرفع (insert): مسموح للطلبات العامة لكن داخل هذا المخزن فقط.
--  - القراءة/التحميل: للمصادَقين فقط (لا قراءة عامة) → اعرض الوثائق للمدراء
--    عبر روابط موقّعة createSignedUrl بدل الروابط العامة.
--  - التعديل/الحذف: للمصادَقين فقط.
-- ════════════════════════════════════════════════════════════════════════
alter table storage.objects enable row level security;

drop policy if exists "supplier_docs_insert"      on storage.objects;
drop policy if exists "supplier_docs_read_admin"   on storage.objects;
drop policy if exists "supplier_docs_delete_admin" on storage.objects;

-- رفع وثائق التسجيل (البوابة عامة) — مقيّد بالمخزن المحدد
create policy "supplier_docs_insert" on storage.objects
  for insert to anon, authenticated
  with check ( bucket_id = 'supplier-docs' );

-- القراءة للمصادَقين (المدراء) فقط
create policy "supplier_docs_read_admin" on storage.objects
  for select to authenticated
  using ( bucket_id = 'supplier-docs' );

-- الحذف للمصادَقين فقط
create policy "supplier_docs_delete_admin" on storage.objects
  for delete to authenticated
  using ( bucket_id = 'supplier-docs' );

-- ملاحظة: إن جعلتَ المخزن خاصاً (public=false) فاعرض الوثائق في لوحة المدير عبر:
--   const { data } = await SB.storage.from('supplier-docs').createSignedUrl(path, 3600);
-- بدلاً من getPublicUrl، حتى لا تكون الوثائق متاحة للعموم.

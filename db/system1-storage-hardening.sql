-- ═══════════════════════════════════════════════════════════════════════════
--  تصليب مخزن وثائق تسجيل الموردين (النظام 1 — مشروع Supabase القديم
--  yofcaxvstjcrmbgciwym، مخزن `supplier-docs`)
--  ─────────────────────────────────────────────────────────────────────────
--  ⚠️ هذا الملف يخصّ **النظام 1/2** (proc_*) لا البوابة. شغّله على المشروع القديم.
--
--  ## المشكلة المؤكَّدة حيّاً (فحوص قراءة فقط، 2026-07-26)
--  المفتاح العام (anon) مضمَّن في `register.html` — وهو معلوم لأي زائر. وبه ثبت:
--    • سرد المخزن:  POST /storage/v1/object/list/supplier-docs  ⇒ **200** و**23 مجلّد
--      تسجيل** بأسمائها (DG-…) وأنواع وثائق كل مجلّد (cr / gosi / chamber / …).
--    • تنزيل وثيقة مورّد فعلية: GET /storage/v1/object/supplier-docs/DG-…/cr/….pdf
--      ⇒ **206** (نجح). أي أنّ **سجلات تجارية وشهادات واشتراكات ورسائل بنكية
--      لكل مورّد قابلة للتنزيل من الإنترنت بلا أي حساب.**
--    • بل ويمكن سكّ روابط موقّعة: POST /storage/v1/object/sign/… ⇒ **200**.
--    • والكتابة مفتوحة بالضرورة (الصفحة نفسها ترفع بمفتاح anon) ⇒ **أي شخص يرفع
--      أي ملف** إلى المخزن؛ وفحص التوقيع السحري في `register.html` يقع في المتصفّح
--      فيُتجاوَز كلّياً باستدعاء واجهة التخزين مباشرةً.
--  (الجدول نفسه سليم: `proc_supplier_registrations` يعيد لـanon صفراً من الصفوف —
--   RLS تعمل. الثغرة في **المخزن** لا في الجدول.)
--
--  ## العلاج على مرحلتين — والترتيب مهمّ كي لا يتعطّل تسجيل موردين حقيقيين
--
--  ### المرحلة 1 (فورية، بلا أي اعتماد على كود أو متغيّرات): أغلق القراءة
--  تُبقي **الرفع** بمفتاح anon يعمل كما هو اليوم (فلا ينكسر التسجيل)، وتمنع
--  السرد/التنزيل/التوقيع عن غير المسجَّلين. هذه وحدها تُغلق تسريب البيانات.
--  الأدمن في `index.html` يدخل بحساب Supabase حقيقي (دور authenticated) فيبقى
--  createSignedUrl لديه يعمل.
--
--  ### المرحلة 2 (بعد ضبط SUPABASE_SERVICE_ROLE_KEY في Cloudflare + نشر جديد):
--  أغلق **الكتابة** أيضاً. عندها يمرّ كل رفع عبر `/api/reg-doc` الذي يفحص الملف
--  بحارس طبقي (`functions/api/_file-guard.js`) ويرفعه بمفتاح الخدمة.
--  ⚠️ لا تُشغّل المرحلة 2 قبل التأكّد أنّ
--     `curl -s https://suppliers.aldeyabi.com/api/reg-doc` يعيد `{"ok":true,…}`
--     وإلّا تعطّل رفع الوثائق للموردين الجدد.
--
--  ## التحقّق بعد كل مرحلة (بنفس فحوص الاكتشاف)
--    KEY=<anon key من register.html>;  U=https://yofcaxvstjcrmbgciwym.supabase.co
--    curl -s -o /dev/null -w '%{http_code}\n' -X POST "$U/storage/v1/object/list/supplier-docs" \
--         -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
--         -H 'Content-Type: application/json' -d '{"prefix":"","limit":1}'
--    المتوقّع بعد المرحلة 1: **400/403** (كان 200).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── استطلاع: اعرض السياسات القائمة على المخزن قبل تغيير أي شيء ──────────────
--   (شغّل هذا وحده أولاً وانظر النتيجة — للتوثيق ولمعرفة ما سيُحذف.)
SELECT policyname, cmd, roles, qual::text, with_check::text
  FROM pg_policies
 WHERE schemaname = 'storage' AND tablename = 'objects'
 ORDER BY policyname;

-- ═══════════════════════ المرحلة 1 — إغلاق القراءة ═══════════════════════════
BEGIN;

-- (1) احذف أي سياسة على storage.objects تخصّ هذا المخزن تحديداً.
--     الحذف مقصور على ما يذكر 'supplier-docs' صراحةً — لا نمسّ مخازن أخرى.
DO $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT policyname FROM pg_policies
     WHERE schemaname='storage' AND tablename='objects'
       AND (coalesce(qual::text,'') LIKE '%supplier-docs%'
         OR coalesce(with_check::text,'') LIKE '%supplier-docs%')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', r.policyname);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'حُذفت % سياسة تخصّ supplier-docs', n;
END $$;

-- ⚠️ إن أظهر الاستطلاع أعلاه سياسة **عامّة** لا تذكر اسم المخزن (مثل
--    USING (true) لدور anon) فهي تُبقي المخزن مفتوحاً — احذفها يدوياً بعد
--    التأكّد من أنّها لا تخدم مخزناً آخر مطلوباً.

-- (2) قراءة الوثائق: للمستخدمين المسجَّلين فقط (شاشة الأدمن في index.html).
CREATE POLICY "supplier_docs_read_staff"
  ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'supplier-docs');

-- (3) الرفع: يبقى متاحاً لـanon **مؤقّتاً** كي لا يتعطّل التسجيل قبل المرحلة 2.
--     (لا سياسة SELECT لـanon ⇒ لا سرد ولا تنزيل ولا سكّ روابط موقّعة.)
CREATE POLICY "supplier_docs_insert_public_TEMP"
  ON storage.objects FOR INSERT TO anon
  WITH CHECK (bucket_id = 'supplier-docs');

-- ملاحظة: لا سياسات UPDATE/DELETE ⇒ ممنوعتان على الجميع عدا service_role
-- (الذي يتجاوز RLS بطبيعته) — فلا يستطيع أحد استبدال وثيقة مورّد أو حذفها.

COMMIT;

-- ═══════════════════════ المرحلة 2 — إغلاق الكتابة ═══════════════════════════
--  ⚠️ لا تُشغّلها إلا بعد أن يعيد /api/reg-doc القيمة {"ok":true}.
--  بعدها: العميل بلا أي صلاحية على المخزن؛ كل رفع يمرّ بالحارس الطبقي على الخادم.
--
-- BEGIN;
--   DROP POLICY IF EXISTS "supplier_docs_insert_public_TEMP" ON storage.objects;
-- COMMIT;
--
--  وبعد تنفيذها: أزِل «السقوط المؤقّت» في register.html (دالة uploadDocViaServer)
--  كي يصبح فشل الخادم خطأً ظاهراً لا رفعاً مباشراً صامتاً.

-- ═══════════════════════ متابعة موصى بها (ليست جزءاً من الإصلاح) ═════════════
--  • تدوير المفتاح العام (anon) للمشروع القديم — كان يمنح وصولاً واسعاً لفترة،
--    ويُفترض اعتباره «مكشوفاً» (وهو كذلك بطبيعته، لكن التدوير يبطل أي نسخ مخزّنة).
--  • مراجعة سجلّات التخزين (Supabase → Storage → Logs) بحثاً عن سردٍ/تنزيلٍ غير
--    مألوف قبل الإغلاق، لتقدير ما إذا كان الكشف قد استُغِلّ فعلاً.

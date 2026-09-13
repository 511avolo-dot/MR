-- ════════════════════════════════════════════════════════════════════════════
--  نظام 2 — إقفال الجداول التي فاتت هجرة النطاق (سياسات RESTRICTIVE)
-- ----------------------------------------------------------------------------
--  لماذا الآن: **الإطلاق نفسه هو ما يفتح الثغرة.** حتى اليوم كل مستخدمي
--  `authenticated` أربعةٌ من موظفي المكتب موثوقين، فسياسة `USING(true)` بلا
--  أثر عمليّ. وإنشاء حسابات موظفي الصيانة — وهو الإطلاق — يُدخل مستخدمين
--  **أقلّ ثقةً** إلى نفس الدور، فتصير كل سياسة `USING(true)` باباً مفتوحاً.
--
--  المقيس على الإنتاج (2026-09-13): `db/system2-staff-scope.sql` غطّت
--  purchase_orders · users · items/suppliers/history · purchase_requests
--  (+pr_items/pr_approvals) · audit_log. و**سبعة جداول لم تُغطَّ إطلاقاً**
--  وما تزال `USING(true)` لكل مستخدم مسجَّل، بلا حارس مُشغِّل خلفها:
--
--    proc_supplier_registrations  53 صفّاً — **الأخطر**: سجل تجاري · رقم ضريبي ·
--                                 آيبان واسم صاحب الحساب · مؤشّرات وثائق ·
--                                 هواتف وبريد مسؤولي الموردين. و`auth_update`
--                                 و`auth_delete` مفتوحتان: تعديل أو **حذف** طلب.
--    proc_ai_usage                658 · proc_item_aliases 95 · proc_rfq_quotes 2 ·
--    proc_rfqs                    1  · proc_pr_attachments 0 · proc_pr_audit 0
--
--  ⚠️ لا مسار في واجهة الموظّف المُنطَّق يقرأ أيّاً منها (مُتحقَّق بتتبّع كل
--     مستدعٍ): التسجيلات وراء `can_review_registrations` · بطاقات الأداء وراء
--     `can_manage_suppliers` · الأسماء البديلة والاستخدام الذكيّ في شاشة AI ·
--     RFQ شاشة مستقلّة — وكلّها خارج `SCOPED_PAGES`، و`hasPermission` صارت
--     **صارمة** للمُنطَّق (منح صريح أو لا شيء). و`proc_pr_attachments` و
--     `proc_pr_audit` بلا مرجع واحد في `index.html` (بقايا). فالإقفال بلا أثر
--     على أي شاشة قائمة.
--
--  ═══ لماذا RESTRICTIVE لا إعادة كتابة السياسات ═══
--  سياسات RLS المتساهلة (PERMISSIVE) **تُجمَع بـOR**، فتقييد جدول يتطلّب حذف
--  كل سياساته وإعادة بنائها — وهو ما فعلته هجرة النطاق على جداولها. أمّا
--  RESTRICTIVE فتُجمَع بـ**AND**: تُضاف فوق ما هو قائم، فلا تُحذف سياسة ولا
--  تُعاد كتابة واحدة، ولا يمكن أن تُوسِّع وصولاً بحال.
--  ⚠️ وهذا يحفظ ما لا يجوز المساس به: سياستا **anon**
--     `public_insert` / `public_insert_pending` على `proc_supplier_registrations`
--     اللتان يعتمد عليهما نموذج تسجيل الموردين العامّ (`register.html`).
--     RESTRICTIVE هنا `TO authenticated` فلا يمرّ بها دور anon إطلاقاً.
--
--  ═══ عدم الانحدار ═══
--  الشرط `NOT proc_is_scoped()` — والأربعة القائمون `scope_sectors` عندهم NULL
--  ⇒ `proc_is_scoped()` = false ⇒ الشرط true ⇒ **صفر تغيير لهم**. والمنع لا
--  يقع إلا على حسابٍ أُسنِد له قطاع، وهو ما لم يوجد بعد على الإنتاج.
--  ومسارات الخادم (`reg-doc.js` · `doc-renew.js` · `supplier-invite-link.js` …)
--  تعمل بمفتاح الخدمة فتتجاوز RLS كلّها.
--
--  ⚠️ تُشغَّل **بعد** `db/system2-staff-scope.sql` (تعتمد `proc_is_scoped()`).
--  إضافيّة وidempotent. كتلة التراجع في النهاية.
-- ════════════════════════════════════════════════════════════════════════════

-- الاعتماد الوحيد — نفشل مبكّراً برسالة مفهومة بدل خطأ «الدالّة غير موجودة»
-- على أوّل سياسة، فلا يبقى الجدول نصف مُقفَل.
DO $$
BEGIN
  IF to_regprocedure('proc_is_scoped()') IS NULL THEN
    RAISE EXCEPTION 'شغّل db/system2-staff-scope.sql أوّلاً — proc_is_scoped() غير موجودة';
  END IF;
END $$;

DO $lock$
DECLARE
  t text;
  -- ⚠️ قائمة صريحة لا تعداد آليّ: الإقفال قرار لكل جدول على حدة، وجدولٌ
  --    جديد يجب أن يُراجَع لا أن يُقفَل تلقائيّاً (قد يحتاجه الموظّف).
  tables text[] := ARRAY[
    'proc_supplier_registrations',
    'proc_pr_attachments',
    'proc_rfqs',
    'proc_rfq_quotes',
    'proc_item_aliases',
    'proc_ai_usage',
    'proc_pr_audit'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    -- جدول غائب (نسخة أقدم من المخطّط) لا يكسر الهجرة
    CONTINUE WHEN to_regclass('public.' || t) IS NULL;

    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS "no_scoped_access" ON %I', t);
    -- FOR ALL مقبولة هنا خلافاً للمتساهلة: RESTRICTIVE لا تُوسِّع شيئاً،
    -- فـ«لكل أمر» لا تضيف حمايةً — والـUSING تحكم القراءة/التعديل/الحذف
    -- والـWITH CHECK تحكم الإدراج/التعديل.
    EXECUTE format($p$
      CREATE POLICY "no_scoped_access" ON %I
        AS RESTRICTIVE FOR ALL TO authenticated
        USING      (NOT proc_is_scoped())
        WITH CHECK (NOT proc_is_scoped())
    $p$, t);
  END LOOP;
END $lock$;

COMMENT ON FUNCTION proc_is_scoped() IS
  'هل المتصل موظّف مُنطَّق بقطاع؟ يُستعمَل في سياسات النطاق وسياسات '
  'RESTRICTIVE في db/system2-scoped-table-lockdown.sql.';


-- ═══════════ التحقّق (شغّلها بعد التطبيق) ═══════════
-- SELECT tablename, policyname, permissive FROM pg_policies
--  WHERE schemaname='public' AND policyname='no_scoped_access' ORDER BY tablename;
--   ⇒ سبعة صفوف، permissive = 'RESTRICTIVE'
-- SELECT count(*) FROM pg_policies WHERE schemaname='public'
--   AND tablename='proc_supplier_registrations' AND 'anon' = ANY(roles);
--   ⇒ 2 (public_insert + public_insert_pending — لم تُمَسّا)


-- ═══════════ التراجع ═══════════
-- DO $$ DECLARE t text; BEGIN
--   FOREACH t IN ARRAY ARRAY['proc_supplier_registrations','proc_pr_attachments',
--                            'proc_rfqs','proc_rfq_quotes','proc_item_aliases',
--                            'proc_ai_usage','proc_pr_audit'] LOOP
--     EXECUTE format('DROP POLICY IF EXISTS "no_scoped_access" ON %I', t);
--   END LOOP;
-- END $$;

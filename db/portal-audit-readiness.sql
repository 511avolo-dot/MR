-- ════════════════════════════════════════════════════════════════════════════
--  فحص جاهزية البوابة — للقراءة فقط (SELECT حصراً، لا كتابة ولا DDL)
--  شغّله في: Supabase → مشروع البوابة mwbjoysuybgbrvfrprex → SQL Editor → Run
--  يجيب عن: (1) الهجرات المطبَّقة  (2) الإعدادات وقيمها  (3) جاهزية التشغيل
--  آمن تماماً على الإنتاج: لا يُنشئ ولا يعدّل ولا يحذف شيئاً.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) الهجرات: هل وصلت آخر الإصلاحات؟ ─────────────────────────────────────
SELECT '1) الهجرات المطبَّقة (آخر 15)' AS "الفحص";
SELECT version, name
FROM supabase_migrations.schema_migrations
ORDER BY version DESC
LIMIT 15;

-- الحاسم: وجود دوال آخر الإصلاحات فعليّاً في القاعدة (لا مجرّد صفّ هجرة).
SELECT '1ب) هل إصلاحاتنا الأخيرة حيّة فعلاً؟' AS "الفحص";
SELECT
  'p0_2d — إلغاء الطلب لمدير القسم/القطاع' AS "الإصلاح",
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='portal_cancel_request'
        AND position('v_is_mgr' in pg_get_functiondef(p.oid))>0)
    THEN '✅ مطبَّق' ELSE '❌ غير مطبَّق' END AS "الحالة"
UNION ALL SELECT
  'p0_2e — المُقدّم يؤكّد استلام طلبه',
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='portal_record_receipt'
        AND position('v_req.requester = v_me' in pg_get_functiondef(p.oid))>0)
    THEN '✅ مطبَّق' ELSE '❌ غير مطبَّق' END
UNION ALL SELECT
  'p0_2e — رفع الطلب متاح لكل وظيفة نشطة',
  CASE WHEN NOT EXISTS (SELECT 1 FROM portal_jobs
      WHERE active AND coalesce((permissions->>'can_create')::boolean,false)=false)
    THEN '✅ مطبَّق' ELSE '❌ ' || (SELECT count(*)::text FROM portal_jobs
      WHERE active AND coalesce((permissions->>'can_create')::boolean,false)=false)
      || ' وظيفة نشطة بلا صلاحية رفع' END
UNION ALL SELECT
  'p0_2g — مورد/مبلغ الفاتورة من التعميد المعتمَد',
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='portal_invoice_record'
        AND position('v_award' in pg_get_functiondef(p.oid))>0)
    THEN '✅ مطبَّق' ELSE '❌ غير مطبَّق' END
UNION ALL SELECT
  'p0_2a — منح السوبر-يوزر عبر portal_set_admin',
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='portal_set_admin')
    THEN '✅ مطبَّق' ELSE '❌ غير مطبَّق' END;

-- ── (2) الإعدادات: مفاتيح الحوكمة وقيمها الفعليّة ───────────────────────────
--  بنية الجدول key/value: مفاتيح الحوكمة كلّها داخل الصفّ key='portal_settings'.
SELECT '2) مفاتيح الحوكمة (0=مُطفأ · 1=مُفعَّل)' AS "الفحص";
WITH s AS (SELECT coalesce((SELECT value FROM portal_settings WHERE key='portal_settings'),'{}'::jsonb) AS v)
SELECT k AS "المفتاح",
       coalesce(s.v->>k,'(غير مضبوط)') AS "القيمة",
       CASE k
         WHEN 'budget_enforce'        THEN 'منع تجاوز الميزانية'
         WHEN 'three_way_enforce'     THEN 'المطابقة الثلاثية على الصرف الآجل'
         WHEN 'iban_change_control'   THEN 'ضبط تغيير الآيبان (وقاية احتيال)'
         WHEN 'contract_enforce'      THEN 'منع تجاوز سقف العقد'
         WHEN 'txn_notifications'     THEN 'إشعارات معامَلاتية'
         WHEN 'disb_gate_purchase'    THEN 'بوّابة صرف متدرّجة على مسار الشراء'
         WHEN 'expense_docs_required' THEN 'إلزام مستند داعم للصرف المباشر'
         WHEN 'quote_doc_required'    THEN 'إلزام مستند عرض المورد'
         WHEN 'three_way_tolerance_pct' THEN 'نسبة التسامح في المطابقة'
       END AS "المعنى"
FROM s, unnest(ARRAY['budget_enforce','three_way_enforce','iban_change_control','contract_enforce',
                     'txn_notifications','disb_gate_purchase','expense_docs_required','quote_doc_required',
                     'three_way_tolerance_pct']) AS k;

-- سياسة اللجنة (صفّ مستقلّ) — الشريحة التي تتطلّبها، وهل لها أعضاء.
SELECT '2ب) سياسة اللجنة' AS "الفحص";
SELECT
  coalesce((SELECT value->>'enabled' FROM portal_settings WHERE key='committee_policy'),'-') AS "مُفعَّلة",
  coalesce((SELECT value->>'min_amount_exclusive' FROM portal_settings WHERE key='committee_policy'),'-') AS "من (حصراً)",
  coalesce((SELECT value->>'max_amount_inclusive' FROM portal_settings WHERE key='committee_policy'),'-') AS "إلى (شاملاً)",
  coalesce((SELECT jsonb_array_length(value) FROM portal_settings WHERE key='committee_members'),0)::text AS "عدد الأعضاء",
  (SELECT count(*)::text FROM portal_users WHERE active
     AND coalesce((permissions->>'can_approve_committee')::boolean,false)) AS "حاملو الصلاحية";

-- ── (3) جاهزية التشغيل: الفجوات التي توقف العمل فعليّاً ─────────────────────
SELECT '3) جاهزية التشغيل — الفجوات الموقِفة' AS "الفحص";
WITH
act AS (SELECT * FROM portal_users WHERE active),
holders AS (
  SELECT k AS perm, (SELECT count(*) FROM act WHERE coalesce((act.permissions->>k)::boolean,false)) AS n
  FROM unnest(ARRAY['can_disburse','can_approve_committee','can_approve_disbursement',
                    'can_approve_award','can_issue_po','can_manage_procurement',
                    'can_approve_stage','can_verify_stock']) AS k),
comm AS (SELECT coalesce((SELECT jsonb_array_length(value) FROM portal_settings WHERE key='committee_members'),0) AS n)
SELECT 'اللجنة المصغّرة' AS "البند",
       ((SELECT n FROM holders WHERE perm='can_approve_committee') + (SELECT n FROM comm))::text AS "العدد",
       CASE WHEN ((SELECT n FROM holders WHERE perm='can_approve_committee') + (SELECT n FROM comm)) = 0
         THEN '❌ يوقف كل طلب فوق 25,000' ELSE '✅ سليم' END AS "الأثر"
UNION ALL
SELECT 'تنفيذ الصرف (فصل مهام)', (SELECT n FROM holders WHERE perm='can_disburse')::text,
       CASE WHEN (SELECT n FROM holders WHERE perm='can_disburse') < 2
         THEN '❌ يتجمّد الصرف — يلزم شخصان' ELSE '✅ سليم' END
UNION ALL
SELECT 'اعتماد الصرف', (SELECT n FROM holders WHERE perm='can_approve_disbursement')::text,
       CASE WHEN (SELECT n FROM holders WHERE perm='can_approve_disbursement') = 0
         THEN '❌ سلسلة الصرف بلا معتمِد' ELSE '✅ سليم' END
UNION ALL
-- ملاحظة: المسارات المبذورة تعتمد «مدير القسم» لا can_approve_stage — فصفر هنا ليس عائقاً
-- بذاته. العائق الحقيقيّ يظهر في القسم (4): مرحلة بلا معتمِد مؤهَّل.
SELECT 'حاملو can_approve_stage (إعلاميّ)', (SELECT n FROM holders WHERE perm='can_approve_stage')::text, 'ℹ️ يُقيَّم في القسم (4)'
UNION ALL
SELECT 'إدارة المشتريات والتسعير', (SELECT n FROM holders WHERE perm='can_manage_procurement')::text,
       CASE WHEN (SELECT n FROM holders WHERE perm='can_manage_procurement') = 0
         THEN '❌ لا تسعير' ELSE '✅ سليم' END
UNION ALL
SELECT 'اعتماد التعميد', (SELECT n FROM holders WHERE perm='can_approve_award')::text,
       CASE WHEN (SELECT n FROM holders WHERE perm='can_approve_award') = 0 THEN '❌ لا تعميد' ELSE '✅ سليم' END
UNION ALL
-- سلسلة أمر الشراء تُبنى من can_approve_committee/can_approve_finance/can_manage_users
-- (تحقَّقتُ من portal_build_po_chain) — لا من can_issue_po. فهذا إعلاميّ لا عائق.
SELECT 'حاملو can_issue_po (إعلاميّ)', (SELECT n FROM holders WHERE perm='can_issue_po')::text, 'ℹ️'
UNION ALL
SELECT 'اعتماد مالي (مرحلة في كل مسار)', (SELECT count(*)::text FROM act
         WHERE coalesce((act.permissions->>'can_approve_finance')::boolean,false)
           AND NOT coalesce(act.is_away,false)),
       CASE WHEN (SELECT count(*) FROM act
         WHERE coalesce((act.permissions->>'can_approve_finance')::boolean,false)
           AND NOT coalesce(act.is_away,false)) = 0
         THEN '❌ لا معتمِد متاح — كل طلب يقف عند التحقّق المالي' ELSE '✅ سليم' END
UNION ALL
SELECT 'تأكيد الاستلام', (SELECT n FROM holders WHERE perm='can_verify_stock')::text,
       CASE WHEN (SELECT n FROM holders WHERE perm='can_verify_stock') = 0
         THEN '⚠️ المُقدّم يستلم طلبه فقط' ELSE '✅ سليم' END
UNION ALL
SELECT 'أقسام نشطة بلا مدير',
       (SELECT count(*)::text FROM portal_departments WHERE active AND manager_user IS NULL),
       CASE WHEN (SELECT count(*) FROM portal_departments WHERE active AND manager_user IS NULL) > 0
         THEN '❌ طلبات تلك الأقسام لا تبني سلسلة' ELSE '✅ سليم' END
UNION ALL
SELECT 'مستخدمون نشطون بلا وظيفة',
       (SELECT count(*)::text FROM act WHERE role <> 'admin' AND coalesce(job_key,'') = ''),
       CASE WHEN (SELECT count(*) FROM act WHERE role <> 'admin' AND coalesce(job_key,'') = '') > 0
         THEN '⚠️ بلا صلاحيات — النظام يبدو لهم فارغاً' ELSE '✅ سليم' END
UNION ALL
SELECT 'حسابات تجريبية (demo_*) نشطة',
       (SELECT count(*)::text FROM act WHERE username LIKE 'demo\_%'),
       CASE WHEN (SELECT count(*) FROM act WHERE username LIKE 'demo\_%') > 0
         THEN '⚠️ استبدلها بمستخدمين حقيقيين قبل الإطلاق' ELSE '✅ سليم' END
UNION ALL
SELECT 'سوبر-يوزر (أدمن) نشط', (SELECT count(*)::text FROM act WHERE role = 'admin'),
       CASE WHEN (SELECT count(*) FROM act WHERE role='admin') = 0 THEN '❌ لا مدير بوابة' ELSE '✅ سليم' END;

-- ── (4) صحّة مسارات الاعتماد المخزَّنة ──────────────────────────────────────
SELECT '4) مسارات الاعتماد — مراحل بلا معتمِد مؤهَّل' AS "الفحص";
SELECT w.id AS "المسار", w.cycle AS "الدورة", st->>'label' AS "المرحلة",
       coalesce(st->>'role_key', st->>'resolver') AS "الإسناد",
       CASE
         WHEN st->>'resolver' = 'dept_manager' THEN
           CASE WHEN EXISTS (SELECT 1 FROM portal_departments WHERE active AND manager_user IS NOT NULL)
             THEN '✅' ELSE '❌ لا مدير قسم معيَّن' END
         WHEN st->>'resolver' = 'role' THEN
           CASE WHEN EXISTS (SELECT 1 FROM portal_users u WHERE u.active
               AND coalesce((u.permissions->>(st->>'role_key'))::boolean,false))
             THEN '✅' ELSE '❌ 0 مؤهَّلين' END
         WHEN st->>'resolver' = 'user' THEN
           CASE WHEN EXISTS (SELECT 1 FROM portal_users WHERE username = st->>'approver' AND active)
             THEN '✅' ELSE '❌ الشخص غير نشط' END
         ELSE '—' END AS "الحالة"
FROM portal_workflows w, jsonb_array_elements(coalesce(w.stages,'[]'::jsonb)) AS st
WHERE w.active
ORDER BY w.cycle, w.id, (st->>'seq')::int;

-- ── (5) حجم البيانات (هل بدأ تشغيل حقيقيّ؟) ─────────────────────────────────
SELECT '5) حجم البيانات' AS "الفحص";
SELECT 'الطلبات' AS "الجدول", count(*)::text AS "العدد" FROM portal_requests
UNION ALL SELECT 'منها مقفلة (مكتملة)', count(*)::text FROM portal_requests WHERE status='closed'
UNION ALL SELECT 'منها قيد المراجعة',   count(*)::text FROM portal_requests WHERE status='in_review'
UNION ALL SELECT 'المستخدمون النشطون',  count(*)::text FROM portal_users WHERE active
UNION ALL SELECT 'الأقسام النشطة',      count(*)::text FROM portal_departments WHERE active
UNION ALL SELECT 'الوظائف النشطة',      count(*)::text FROM portal_jobs WHERE active
UNION ALL SELECT 'سجلّ التدقيق',        count(*)::text FROM portal_audit;

-- ── (6) معتمِدون مُجازون بلا بديل — سبب خفيّ لتوقّف السلسلة ──────────────────
SELECT '6) حاملو صلاحيات حرِجة وهم في إجازة بلا مفوَّض مؤهَّل' AS "الفحص";
SELECT u.username AS "المستخدم", k AS "الصلاحية",
       coalesce(u.delegate_to,'(بلا مفوَّض)') AS "المفوَّض",
       CASE WHEN u.delegate_to IS NOT NULL AND EXISTS (SELECT 1 FROM portal_users x
              WHERE x.username=u.delegate_to AND x.active
                AND coalesce((x.permissions->>k)::boolean,false))
            THEN '✅ بديل مؤهَّل' ELSE '❌ لا بديل — المرحلة مسدودة' END AS "الحالة"
FROM portal_users u,
     unnest(ARRAY['can_approve_finance','can_approve_disbursement','can_approve_committee',
                  'can_manage_procurement','can_approve_award','can_disburse']) AS k
WHERE u.active AND coalesce(u.is_away,false)
  AND coalesce((u.permissions->>k)::boolean,false);

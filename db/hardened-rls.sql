-- ════════════════════════════════════════════════════════════════════════
--  تحصين سياسات RLS — نظام مجموعة الذيابي (التسعير + تسجيل الموردين)
-- ════════════════════════════════════════════════════════════════════════
--  المشكلة الحالية: كل الجداول تستخدم  USING (true) WITH CHECK (true)
--  أي أن مفتاح anon العام (المنشور في صفحة التسجيل) يمنح قراءة/كتابة/حذف
--  كاملة لأي شخص على الإنترنت: الأسعار، الموردين، المستخدمين، هاشات كلمات
--  المرور، وبيانات تسجيل الموردين الحساسة (PII).
--
--  يُنفَّذ هذا السكريبت في Supabase Dashboard → SQL Editor.
--  مقسوم إلى مرحلتين: مرحلة فورية غير كاسرة، ومرحلة تتطلب Supabase Auth.
-- ════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────
--  المرحلة 0 — إجراءات فورية وغير كاسرة (نفّذها الآن)
-- ─────────────────────────────────────────────────────────────────────────

-- (أ) إزالة مفتاح Gemini السري من جدول الإعدادات العام.
--     بعد ضبط GEMINI_API_KEY كسرّ في Cloudflare Pages، لم يعد التطبيق
--     بحاجة لتخزين المفتاح في قاعدة البيانات. هذا يزيل أخطر تسريب فوراً.
UPDATE proc_settings
   SET value = value - 'api_key'
 WHERE key = 'ai_config'
   AND value ? 'api_key';

-- (ب) (اختياري لكنه موصى به) إضافة salt لهاشات كلمات المرور يتطلب تغييراً
--     في التطبيق؛ حتى ذلك الحين، البند الأهم هو منع قراءة proc_users عبر anon
--     (انظر المرحلة 1). لا تُبقِ هاشات SHA-256 غير المملّحة قابلة للقراءة علناً.


-- ─────────────────────────────────────────────────────────────────────────
--  المرحلة 1 — التحصين الكامل (يتطلب Supabase Auth للوحة الإدارة)
-- ─────────────────────────────────────────────────────────────────────────
--  ⚠️ متطلّب مسبق: يجب أن يسجّل مستخدمو لوحة الإدارة (index.html) الدخول عبر
--     Supabase Auth (بريد/كلمة مرور أو رابط سحري) قبل تطبيق هذه السياسات،
--     وإلا ستتوقف قراءة/كتابة البيانات في لوحة الإدارة (لأنها تعمل حالياً
--     بمفتاح anon). راجع README → «ترحيل المصادقة».
--
--  المبدأ:
--   • تسجيل الموردين العام  → السماح بـ INSERT للجميع فقط (إرسال الطلب)،
--     ومنع القراءة/التعديل عن غير المصادَق عليهم (حماية PII).
--   • بقية الجداول            → القراءة والكتابة لمستخدمي Auth فقط.
--   • سجل التدقيق             → إضافة فقط، لا تعديل ولا حذف.

-- 1) البنود / الموردين / السجل — للمصادَق عليهم فقط
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['proc_items','proc_suppliers','proc_history'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS "Enable read for all"   ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "Enable insert for all" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "Enable update for all" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "Enable delete for all" ON %I', t);
    -- حذف الأسماء الجديدة أيضاً ليكون السكربت قابلاً لإعادة التشغيل (idempotent)
    EXECUTE format('DROP POLICY IF EXISTS "auth_read"   ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "auth_insert" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "auth_update" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "auth_delete" ON %I', t);
    EXECUTE format('CREATE POLICY "auth_read"   ON %I FOR SELECT TO authenticated USING (true)', t);
    EXECUTE format('CREATE POLICY "auth_insert" ON %I FOR INSERT TO authenticated WITH CHECK (true)', t);
    EXECUTE format('CREATE POLICY "auth_update" ON %I FOR UPDATE TO authenticated USING (true) WITH CHECK (true)', t);
    EXECUTE format('CREATE POLICY "auth_delete" ON %I FOR DELETE TO authenticated USING (true)', t);
  END LOOP;
END $$;

-- 2) المستخدمون — للمصادَق عليهم فقط (يمنع تسريب الهاشات للعموم)
ALTER TABLE proc_users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Enable read for all"   ON proc_users;
DROP POLICY IF EXISTS "Enable insert for all" ON proc_users;
DROP POLICY IF EXISTS "Enable update for all" ON proc_users;
DROP POLICY IF EXISTS "Enable delete for all" ON proc_users;
DROP POLICY IF EXISTS "auth_all"              ON proc_users;
CREATE POLICY "auth_all" ON proc_users FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 3) الإعدادات — للمصادَق عليهم فقط (لم تعد تحوي أسراراً بعد المرحلة 0)
ALTER TABLE proc_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Enable read for all"   ON proc_settings;
DROP POLICY IF EXISTS "Enable insert for all" ON proc_settings;
DROP POLICY IF EXISTS "Enable update for all" ON proc_settings;
DROP POLICY IF EXISTS "Enable delete for all" ON proc_settings;
DROP POLICY IF EXISTS "auth_all"              ON proc_settings;
CREATE POLICY "auth_all" ON proc_settings FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 4) سجل التدقيق — قراءة/إضافة للمصادَق عليهم، لا تعديل ولا حذف
ALTER TABLE proc_audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Enable read for all"   ON proc_audit_log;
DROP POLICY IF EXISTS "Enable insert for all" ON proc_audit_log;
DROP POLICY IF EXISTS "auth_read"             ON proc_audit_log;
DROP POLICY IF EXISTS "auth_insert"           ON proc_audit_log;
CREATE POLICY "auth_read"   ON proc_audit_log FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth_insert" ON proc_audit_log FOR INSERT TO authenticated WITH CHECK (true);

-- 5) استخدام الذكاء الاصطناعي
ALTER TABLE proc_ai_usage ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Enable read for all"   ON proc_ai_usage;
DROP POLICY IF EXISTS "Enable insert for all" ON proc_ai_usage;
DROP POLICY IF EXISTS "auth_read"             ON proc_ai_usage;
DROP POLICY IF EXISTS "auth_insert"           ON proc_ai_usage;
CREATE POLICY "auth_read"   ON proc_ai_usage FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth_insert" ON proc_ai_usage FOR INSERT TO authenticated WITH CHECK (true);

-- 6) تسجيل الموردين — إرسال عام (INSERT)، وقراءة/تعديل للمصادَق عليهم فقط
--    هذا يسمح للموردين بإرسال طلباتهم دون كشف طلبات الآخرين.
ALTER TABLE proc_supplier_registrations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Enable insert for all"  ON proc_supplier_registrations;
DROP POLICY IF EXISTS "Enable read for all"    ON proc_supplier_registrations;
DROP POLICY IF EXISTS "Enable update for all"  ON proc_supplier_registrations;
DROP POLICY IF EXISTS "Enable read for auth"   ON proc_supplier_registrations;
DROP POLICY IF EXISTS "Enable update for auth" ON proc_supplier_registrations;
DROP POLICY IF EXISTS "public_insert"          ON proc_supplier_registrations;
DROP POLICY IF EXISTS "auth_read"              ON proc_supplier_registrations;
DROP POLICY IF EXISTS "auth_update"            ON proc_supplier_registrations;
-- إرسال جديد للجميع (المورد المجهول)
CREATE POLICY "public_insert" ON proc_supplier_registrations FOR INSERT TO anon, authenticated WITH CHECK (true);
-- القراءة والتعديل للمصادَق عليهم فقط (فريق المشتريات)
CREATE POLICY "auth_read"   ON proc_supplier_registrations FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth_update" ON proc_supplier_registrations FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

-- ملاحظة حول «وضع الاستئناف» (resume) في صفحة التسجيل العامة:
--   ميزة استئناف الطلب تقرأ سجل المورد بمفتاح anon عبر (resume id + token).
--   إن كنت تستخدمها، أبقِ قراءة محدودة عبر دالة آمنة (RPC) تتحقق من الـ token،
--   بدل فتح SELECT للجميع. راجع README → «وضع الاستئناف الآمن».


-- ─────────────────────────────────────────────────────────────────────────
--  التخزين (Storage) — حاوية supplier-docs
-- ─────────────────────────────────────────────────────────────────────────
--  اجعل الحاوية خاصة (public = false) من Dashboard → Storage.
--  ارفع المستندات عبر رابط موقّع/مصادَق، واقرأها فقط للمصادَق عليهم.
--  مثال سياسة على storage.objects:

-- DROP POLICY IF EXISTS "supplier_docs_insert" ON storage.objects;
-- CREATE POLICY "supplier_docs_insert" ON storage.objects
--   FOR INSERT TO anon, authenticated
--   WITH CHECK (bucket_id = 'supplier-docs');
-- DROP POLICY IF EXISTS "supplier_docs_read" ON storage.objects;
-- CREATE POLICY "supplier_docs_read" ON storage.objects
--   FOR SELECT TO authenticated
--   USING (bucket_id = 'supplier-docs');

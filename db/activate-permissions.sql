-- ════════════════════════════════════════════════════════════════════════
--  تفعيل نظام الصلاحيات + Supabase Auth (الحزمة الدنيا — الآن فقط)
--  وحدات سير العمل (RFQ/الاعتمادات) مؤجّلة — لا تُشغّل سكربتاتها بعد.
-- ════════════════════════════════════════════════════════════════════════

-- (1) ضمان أعمدة جدول المستخدمين
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS permissions  JSONB DEFAULT '{}'::jsonb;
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS active       BOOLEAN DEFAULT true;
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS display_name TEXT;
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS role         TEXT DEFAULT 'user';

-- (2) بذر ملفات التعريف. الصلاحيات تُترك {} → التطبيق يطبّق الافتراضات حسب الدور
--     (المدير = كل الصلاحيات). password_hash نائب (الدخول عبر Supabase Auth).
--     ملاحظة: username يطابق الجزء قبل @ في البريد (غير حسّاس لحالة الأحرف).
INSERT INTO proc_users (username, display_name, password_hash, role, permissions, active, created_by)
VALUES
  ('Abdullah','عبدالله','managed_by_supabase_auth','admin','{}'::jsonb,true,'setup'),
  ('Mostafa','مصطفى خليل','managed_by_supabase_auth','user','{}'::jsonb,true,'setup'),
  ('Mahmoud','محمود العمودي','managed_by_supabase_auth','user','{}'::jsonb,true,'setup')
ON CONFLICT (username) DO UPDATE
  SET display_name = EXCLUDED.display_name,
      role         = EXCLUDED.role,
      active       = EXCLUDED.active;

-- (3) [موصى به بعد نجاح الدخول] إغلاق RLS على proc_users — للمصادَق عليهم فقط.
--     شغّله فقط بعد التأكد أن تسجيل الدخول عبر Auth يعمل، وإلا تُمنع قراءة
--     المستخدمين. (يمكن تأجيله إلى المرحلة 1 من db/hardened-rls.sql.)
-- ALTER TABLE proc_users ENABLE ROW LEVEL SECURITY;
-- DROP POLICY IF EXISTS "Enable read for all"   ON proc_users;
-- DROP POLICY IF EXISTS "Enable insert for all" ON proc_users;
-- DROP POLICY IF EXISTS "Enable update for all" ON proc_users;
-- DROP POLICY IF EXISTS "Enable delete for all" ON proc_users;
-- CREATE POLICY "auth_all" ON proc_users FOR ALL TO authenticated USING (true) WITH CHECK (true);

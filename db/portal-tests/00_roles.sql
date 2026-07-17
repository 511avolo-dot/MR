-- ════════════════════════════════════════════════════════════════════════════
--  أدوار Supabase المحاكاة لبيئة الاختبار (تُنشأ مرة على مستوى العنقود).
--  في Supabase الحقيقي هذه الأدوار قائمة؛ هنا نصنعها كي يُحمَّل المخطّط ويُختبر
--  نموذج الصلاحيات (anon/authenticated/service_role) كما في الإنتاج.
-- ════════════════════════════════════════════════════════════════════════════
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon')          THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator LOGIN NOINHERIT; END IF;
  GRANT anon, authenticated, service_role TO authenticator;
END $$;

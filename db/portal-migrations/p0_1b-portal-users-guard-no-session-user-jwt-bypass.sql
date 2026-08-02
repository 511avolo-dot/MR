-- ═══════════════════════════════════════════════════════════════════════════
--  P0-1b — إغلاق تجاوز session_user في portal_users_guard
--  السبب: أثبتت staging أن اعتماد portal_is_privileged() على session_user
--  يجعل مستخدم JWT عادي يمر كـ privileged في سياقات يكون فيها session_user=postgres.
--  القرار: الامتياز الخادمي لا يُستمد من session_user؛ فقط service_role JWT.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_is_privileged()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $function$
  SELECT portal_is_service();
$function$;

REVOKE ALL ON FUNCTION portal_is_privileged() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION portal_is_privileged() TO service_role;

-- ═══════════════════════════════════════════════════════════════════════════
--  055b — تثبيت search_path على portal_recurring_next (من مدقّق Supabase الحيّ)
--  ─────────────────────────────────────────────────────────────────────────
--  مدقّق Supabase رصد `function_search_path_mutable` على portal_recurring_next
--  (كانت LANGUAGE sql IMMUTABLE بلا SET search_path). تثبيتها = اتّساق مع بقيّة
--  الدوال (نمط 040). لا تغيّر سلوكيّ. مدمجة في db/portal-standalone.sql.
--  ⚠️ تُطبَّق حيّاً بعد 055.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION portal_recurring_next(p_from date, p_freq text) RETURNS date
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE p_freq
    WHEN 'weekly'    THEN p_from + INTERVAL '7 day'
    WHEN 'monthly'   THEN p_from + INTERVAL '1 month'
    WHEN 'quarterly' THEN p_from + INTERVAL '3 month'
    WHEN 'yearly'    THEN p_from + INTERVAL '1 year'
    ELSE p_from + INTERVAL '1 month' END::date;
$$;
REVOKE ALL ON FUNCTION portal_recurring_next(date, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_recurring_next(date, text) TO authenticated;

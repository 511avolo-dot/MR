-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 017 — سدّ استدعاء portal_run_sla من PUBLIC (مراجعة أمنية نهائية، MEDIUM)
--  المشكلة: 014 أضافت بوابة صلاحية على portal_sla_tick، لكن portal_run_sla نفسها بقيت
--  ممنوحة لـPUBLIC افتراضياً — فيستطيع anon استدعاؤها مباشرة عبر PostgREST متجاوزاً
--  البوابة (الأثر مخنوق: إشعارات/تدقيق تصعيد فقط، لا تسريب/تغيير حالة). نسحب المنح.
--  portal_sla_tick (DEFINER مملوكة لـpostgres) تستدعيها داخلياً دون حاجة لمنح PUBLIC.
--  idempotent. شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 016.
-- ═══════════════════════════════════════════════════════════════════════════

REVOKE ALL ON FUNCTION portal_run_sla() FROM PUBLIC;
REVOKE ALL ON FUNCTION portal_run_sla() FROM anon, authenticated;

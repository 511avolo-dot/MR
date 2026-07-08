-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 013 — تخصيص اللجنة المصغّرة (م1b)
--  المواصفات: لا توجد طريقة للأدمن لتعيين أعضاء اللجنة المصغّرة التي تعتمد أمر
--  الشراء في الشريحة >25 ألف. اللجنة تُقرأ في portal_po_transition من إعداد
--  committee_members (مصفوفة أسماء مستخدمين) أو صلاحية can_approve_committee.
--  هنا نضيف RPC آمنة (أدمن فقط) لضبط القائمة + تحقّق أن كل عضو مستخدم نشط + تدقيق.
--  idempotent. شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 012.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_set_committee(p_members jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_valid jsonb;
BEGIN
  IF v_me IS NULL OR NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح — إدارة اللجنة للأدمن فقط'; END IF;
  IF p_members IS NULL OR jsonb_typeof(p_members) <> 'array' THEN RAISE EXCEPTION 'صيغة القائمة غير صالحة'; END IF;
  -- أبقِ فقط الأعضاء الذين هم مستخدمون نشطون (تجاهل أي اسم غير صالح) + إزالة التكرار.
  SELECT coalesce(jsonb_agg(DISTINCT u.username), '[]'::jsonb) INTO v_valid
    FROM jsonb_array_elements_text(p_members) m
    JOIN portal_users u ON u.username = m AND u.active;

  INSERT INTO portal_settings(key, value) VALUES ('committee_members', v_valid)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

  PERFORM portal_audit_write(NULL, 'committee_set', v_me, 'portal', jsonb_build_object('members', v_valid));
  RETURN jsonb_build_object('ok', true, 'members', v_valid);
END $fn$;
REVOKE ALL ON FUNCTION portal_set_committee(jsonb) FROM public;
GRANT EXECUTE ON FUNCTION portal_set_committee(jsonb) TO authenticated;

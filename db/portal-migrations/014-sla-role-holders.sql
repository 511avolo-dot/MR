-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 014 — تصليب تصعيد SLA (م3/م4: فجوة approval-12 المؤكَّدة)
--  المشكلة: للمراحل المبنية على role_key (المالية/المشتريات) portal_resolve_stage
--  يعيد NULL، فكان التذكير يصل للأدمن فقط لا للمعتمِدين الفعليين. أيضاً الجدولة
--  كانت تعتمد pg_cron حصراً (إن لم تكن مفعّلة في المشروع فالتصعيد ميت).
--  الحلّ: (أ) عند غياب معتمِد محدَّد نُخطر كل حاملي role_key النشطين (مع التفويض).
--  (ب) الواجهة تستدعي portal_run_sla «كسولاً» عند تحميل مشتريات/أدمن — الخانق
--  الداخلي last_escalation_at يمنع التكرار، فالاستدعاء الكسول آمن ورخيص.
--  idempotent. شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 013.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_run_sla() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_req RECORD; v_stage portal_approvals%ROWTYPE; v_intended text; v_deleg text; v_cnt int := 0; v_h numeric := portal_sla_hours();
BEGIN
  FOR v_req IN SELECT * FROM portal_requests
      WHERE status = 'in_review' AND stage_due_at < now()
        AND (last_escalation_at IS NULL OR last_escalation_at < now() - make_interval(hours => v_h::int))
  LOOP
    SELECT * INTO v_stage FROM portal_approvals WHERE request_id = v_req.id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
    CONTINUE WHEN NOT FOUND;
    v_intended := portal_resolve_stage(v_req.id, v_stage);
    v_deleg := NULL;
    IF v_intended IS NOT NULL THEN
      SELECT delegate_to INTO v_deleg FROM portal_users WHERE username = v_intended AND is_away = true;
    END IF;

    IF v_intended IS NOT NULL THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        VALUES ('ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||v_intended,
                v_intended, 'system', 'تذكير: طلب متأخّر بانتظار اعتمادك', v_req.title, 'inbox')
        ON CONFLICT (id) DO NOTHING;
    ELSIF v_stage.role_key IS NOT NULL THEN
      -- مرحلة دور (مالية/مشتريات...): أخطر كل حاملي الصلاحية النشطين + مفوَّضي الغائبين منهم.
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||u.username,
               u.username, 'system', 'تذكير: طلب متأخّر بانتظار اعتماد مرحلتك ('||coalesce(v_stage.stage_label,'')||')', v_req.title, 'inbox'
        FROM portal_users u
        WHERE u.active AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
        ON CONFLICT (id) DO NOTHING;
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||u.delegate_to,
               u.delegate_to, 'system', 'تفويض: طلب متأخّر بانتظار اعتماد مرحلة ('||coalesce(v_stage.stage_label,'')||') بالنيابة', v_req.title, 'inbox'
        FROM portal_users u
        WHERE u.active AND u.is_away AND u.delegate_to IS NOT NULL
          AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
        ON CONFLICT (id) DO NOTHING;
    END IF;
    IF v_deleg IS NOT NULL THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        VALUES ('ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||v_deleg,
                v_deleg, 'system', 'تفويض: طلب متأخّر بانتظار اعتمادك (بالنيابة)', v_req.title, 'inbox')
        ON CONFLICT (id) DO NOTHING;
    END IF;
    INSERT INTO portal_notifications(id, recipient, type, title, body, link)
      SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||username,
             username, 'system', 'تصعيد SLA: طلب متأخّر', v_req.title, 'inbox'
      FROM portal_users WHERE role = 'admin' AND active = true
      ON CONFLICT (id) DO NOTHING;

    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_requests SET escalations = escalations + 1,
      escalated_at = coalesce(escalated_at, now()), last_escalation_at = now() WHERE id = v_req.id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_req.id, 'escalated', NULL, 'system', jsonb_build_object('intended', v_intended, 'stage_label', v_stage.stage_label));
    v_cnt := v_cnt + 1;
  END LOOP;
  RETURN v_cnt;
END $fn$;

-- الاستدعاء الكسول من الواجهة (مشتريات/أدمن): مقيَّد بصلاحية تشغيلية — ليس عاماً.
CREATE OR REPLACE FUNCTION portal_sla_tick() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RETURN 0;  -- صامت: لا خطأ في الواجهة لغير المخوَّلين
  END IF;
  RETURN portal_run_sla();
END $fn$;
REVOKE ALL ON FUNCTION portal_sla_tick() FROM public;
GRANT EXECUTE ON FUNCTION portal_sla_tick() TO authenticated;

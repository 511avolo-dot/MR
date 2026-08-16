-- ════════════════════════════════════════════════════════════════════════════
--  p0_2b — تصعيد SLA لا يُزعِج المُجازين (تكليف المالك 2026-08-13)
--  ---------------------------------------------------------------------------
--  المشكلة: portal_run_sla كانت تُدرِج تنبيه تصعيد لـ:
--    • المعتمِد المقصود حتى لو كان في إجازة (is_away)،
--    • كل حاملي صلاحية المرحلة النشطين دون استثناء المُجازين،
--    • **كل الأدمن النشطين** دون استثناء المُجاز.
--  فحساب مُجاز (كالمدير العام التجريبي) ظلّ يتلقّى بريد تصعيد لكل طلب متأخّر عبر الصادر.
--
--  الإصلاح (جراحيّ، يحافظ على منطق الفروع): المُجاز لا يُخطَر مباشرةً؛ يُوجَّه إلى
--  مفوَّضه إن وُجد (كما هو أصلاً). حاملو الصلاحية والأدمن المُجازون يُستثنون من التصعيد
--  المباشر. لا تغيير في التصعيد للنشطين غير المُجازين.
--  idempotent: CREATE OR REPLACE. مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_run_sla() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_req RECORD; v_stage portal_approvals%ROWTYPE; v_intended text; v_deleg text;
        v_away boolean; v_cnt int := 0; v_h numeric := portal_sla_hours();
BEGIN
  FOR v_req IN SELECT * FROM portal_requests
      WHERE status = 'in_review' AND stage_due_at < now()
        AND (last_escalation_at IS NULL OR last_escalation_at < now() - make_interval(hours => v_h::int))
  LOOP
    SELECT * INTO v_stage FROM portal_approvals WHERE request_id = v_req.id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
    CONTINUE WHEN NOT FOUND;
    v_intended := portal_resolve_stage(v_req.id, v_stage);
    v_deleg := NULL; v_away := false;
    IF v_intended IS NOT NULL THEN
      SELECT coalesce(is_away, false), (CASE WHEN is_away THEN delegate_to ELSE NULL END)
        INTO v_away, v_deleg FROM portal_users WHERE username = v_intended;
    END IF;

    IF v_intended IS NOT NULL THEN
      -- المعتمِد المقصود: لا يُخطَر إن كان في إجازة (مفوَّضه يُخطَر أدناه عبر v_deleg).
      IF NOT v_away THEN
        INSERT INTO portal_notifications(id, recipient, type, title, body, link)
          VALUES ('ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||v_intended,
                  v_intended, 'system', 'تذكير: طلب متأخّر بانتظار اعتمادك', v_req.title, 'inbox')
          ON CONFLICT (id) DO NOTHING;
      END IF;
    ELSIF v_stage.role_key IS NOT NULL THEN
      -- (014) مرحلة دور: حاملو الصلاحية النشطون **غير المُجازين** + مفوَّضو المُجازين منهم.
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||u.username,
               u.username, 'system', 'تذكير: طلب متأخّر بانتظار اعتماد مرحلتك ('||coalesce(v_stage.stage_label,'')||')', v_req.title, 'inbox'
        FROM portal_users u
        WHERE u.active AND NOT coalesce(u.is_away, false)
          AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
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
    -- تصعيد للأدمن النشطين **غير المُجازين** فقط (لا يُزعَج أدمن في إجازة).
    INSERT INTO portal_notifications(id, recipient, type, title, body, link)
      SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||username,
             username, 'system', 'تصعيد SLA: طلب متأخّر', v_req.title, 'inbox'
      FROM portal_users WHERE role = 'admin' AND active = true AND NOT coalesce(is_away, false)
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

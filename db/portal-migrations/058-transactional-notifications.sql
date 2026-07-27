-- ═══════════════════════════════════════════════════════════════════════════
--  058 — إشعارات معامَلاتية للاعتماد (Transactional Notifications) — المرحلة 6
--  ─────────────────────────────────────────────────────────────────────────
--  الفجوة (بند P1 من تدقيق 029): إشعارات سير العمل تُرسَل عبر `pa_notify`
--  (عميل → portal-notify.js) **بعد** تثبيت المعاملة — fire-and-forget: لو سقط
--  العميل بعد الالتزام وقبل الإرسال، يضيع الإشعار. الحلّ المؤسسي: تُلتقط نيّة إشعار
--  «المعتمِد التالي» **داخل نفس معاملة الانتقال**، فيُسلّمها الصادر المعامَلاتي (029)
--  بضمان exactly-once وإعادة محاولة.
--
--  التصميم (بلا لمس أيٍّ من الـ80 دالة انتقال): مُشغِّل AFTER UPDATE على
--  `portal_requests` يلتقط لحظة دخول/تقدّم الطلب لمرحلة اعتماد معلّقة (status صار
--  in_review مع تغيّر seq/الدخول)، فيُدرِج `portal_notifications` لمعتمِدي المرحلة —
--  ومُشغِّل 029 يلتقطها في `portal_outbox` للتسليم الدائم. **مُنطق مطابق لـ run_sla.**
--
--  ⚠️ خامل افتراضياً: مفتاح `txn_notifications` (0 = لا سلوك جديد إطلاقاً؛ لا ازدواج
--  مع pa_notify). عند تفعيل المالك (=1) **مع إزالة نداءات pa_notify لمراحل الاعتماد**
--  تكتمل التغطية المعامَلاتية بلا بريد مزدوج. النتيجة (لمُقدّم الطلب) تبقى عبر pa_notify.
--  ⚠️ تُطبَّق حيّاً بعد 057. مدمجة في db/portal-standalone.sql.
-- ═══════════════════════════════════════════════════════════════════════════

-- مفتاح التفعيل التدريجي (خامل)
UPDATE portal_settings SET value = value || jsonb_build_object('txn_notifications', 0)
 WHERE key = 'portal_settings' AND NOT (value ? 'txn_notifications');

-- ── مُدرِج إشعارات معتمِدي المرحلة المعلّقة (خادميّ داخليّ) ───────────────────
--   يعكس منطق مستلِمي portal_run_sla: المعتمِد المُحلّ (مدير قسم/مفوَّض) أو حاملو
--   role_key + مفوَّضوهم، مع استثناء مُقدّم الطلب (فصل مهام). type='approval'.
CREATE OR REPLACE FUNCTION portal_enqueue_stage_notifications(p_request_id text, p_cycle text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_req portal_requests%ROWTYPE; v_stage portal_approvals%ROWTYPE; v_intended text; v_cycle text; v_n int := 0;
BEGIN
  IF portal_setting_num('txn_notifications', 0) < 1 THEN RETURN 0; END IF;   -- خامل حتى التفعيل
  v_cycle := coalesce(nullif(p_cycle,''), 'need');
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id;
  IF NOT FOUND OR v_req.status <> 'in_review' THEN RETURN 0; END IF;
  SELECT * INTO v_stage FROM portal_approvals
    WHERE request_id = p_request_id AND cycle = v_cycle AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RETURN 0; END IF;

  v_intended := portal_resolve_stage(p_request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    IF v_intended <> v_req.requester THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        VALUES ('ntf_'||extract(epoch from clock_timestamp())::bigint||'_'||substr(md5(random()::text),1,8)||'_'||v_intended,
                v_intended, 'approval', 'طلب بانتظار اعتمادك', v_req.title, 'inbox') ON CONFLICT (id) DO NOTHING;
      v_n := 1;
    END IF;
    -- تفويض عند الغياب
    INSERT INTO portal_notifications(id, recipient, type, title, body, link)
      SELECT 'ntf_'||extract(epoch from clock_timestamp())::bigint||'_'||substr(md5(random()::text),1,8)||'_'||u.delegate_to,
             u.delegate_to, 'approval', 'تفويض: طلب بانتظار اعتمادك (بالنيابة)', v_req.title, 'inbox'
      FROM portal_users u WHERE u.username = v_intended AND u.is_away AND u.delegate_to IS NOT NULL AND u.delegate_to <> v_req.requester
      ON CONFLICT (id) DO NOTHING;
  ELSIF v_stage.role_key IS NOT NULL THEN
    INSERT INTO portal_notifications(id, recipient, type, title, body, link)
      SELECT 'ntf_'||extract(epoch from clock_timestamp())::bigint||'_'||substr(md5(random()::text),1,8)||'_'||u.username,
             u.username, 'approval', 'طلب بانتظار اعتماد مرحلتك ('||coalesce(v_stage.stage_label,'')||')', v_req.title, 'inbox'
      FROM portal_users u
      WHERE u.active AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false) AND u.username <> v_req.requester
      ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    INSERT INTO portal_notifications(id, recipient, type, title, body, link)
      SELECT 'ntf_'||extract(epoch from clock_timestamp())::bigint||'_'||substr(md5(random()::text),1,8)||'_'||u.delegate_to,
             u.delegate_to, 'approval', 'تفويض: طلب بانتظار اعتماد مرحلتك بالنيابة', v_req.title, 'inbox'
      FROM portal_users u WHERE u.active AND u.is_away AND u.delegate_to IS NOT NULL AND u.delegate_to <> v_req.requester
        AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
      ON CONFLICT (id) DO NOTHING;
  END IF;
  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION portal_enqueue_stage_notifications(text,text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_enqueue_stage_notifications(text,text) TO authenticated;

-- ── مُشغِّل الالتقاط: عند دخول/تقدّم مرحلة اعتماد معلّقة ─────────────────────
CREATE OR REPLACE FUNCTION portal_requests_notify() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  -- يفعل فقط عند دخول in_review أو تقدّم المرحلة (لا يفعل مع تحديثات SLA/الحقول الأخرى).
  IF NEW.status = 'in_review'
     AND (OLD.status IS DISTINCT FROM 'in_review' OR OLD.current_seq IS DISTINCT FROM NEW.current_seq) THEN
    PERFORM portal_enqueue_stage_notifications(NEW.id,
      CASE WHEN NEW.phase = 'disbursement' THEN 'disbursement' ELSE 'need' END);
  END IF;
  RETURN NULL;   -- AFTER trigger
END $fn$;
REVOKE ALL ON FUNCTION portal_requests_notify() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_requests_notify() TO authenticated;

DROP TRIGGER IF EXISTS trg_portal_requests_notify ON portal_requests;
CREATE TRIGGER trg_portal_requests_notify AFTER UPDATE ON portal_requests
  FOR EACH ROW EXECUTE FUNCTION portal_requests_notify();

-- تحقّق:
--   UPDATE portal_settings SET value = value || '{"txn_notifications":1}' WHERE key='portal_settings';
--   ثم أيّ اعتماد ينتقل لمرحلة تالية يُدرِج إشعاراً يلتقطه الصادر (portal_outbox).

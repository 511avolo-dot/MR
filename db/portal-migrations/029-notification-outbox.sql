-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 029 — صندوق الصادر المعامَلاتي للإشعارات (Transactional Outbox)
--  المشكلة (P0 من التدقيق الاستشاري): الإشعارات كانت fire-and-forget عبر
--  `pa_notify → /api/portal-notify` — إن سقط Resend/الشبكة لحظة الانتقال يضيع
--  التنبيه صمتاً بينما تُثبَّت الحالة، فيعلق الطلب ويُخرق SLA بلا أثر.
--
--  الحل (نمط Outbox المعامَلاتي — معياري في الأنظمة المؤسسية):
--    1) جدول `portal_outbox` دائم (server-only، RLS بلا سياسة كنمط email_tokens).
--    2) مُشغِّل AFTER INSERT على `portal_notifications` يُدرج نيّة الإرسال في
--       **نفس معاملة** انتقال الحالة ⇒ إمّا يُثبَّت الاثنان معاً أو لا شيء
--       (ضمان معامَلاتي حقيقي دون لمس أيٍّ من الـ80 دالة).
--    3) `portal_outbox_claim` (خادم فقط): يسحب الرسائل المستحقّة بـ
--       FOR UPDATE SKIP LOCKED (آمن للعمّال المتوازين) ويعلّمها processing.
--    4) `portal_outbox_mark`: نجاح ⇒ sent؛ فشل ⇒ إعادة جدولة بتراجع أُسّي،
--       وdead-letter بعد بلوغ الحد الأقصى للمحاولات.
--
--  خاملة وآمنة: لا سلوك يتغيّر حتى يُفعّل المالك عامل التسليم (Cron + CRON_SECRET).
--  المُشغِّل يلتقط النيّة فقط؛ دفاعي تماماً (لا يرفع استثناءً يكسر الانتقال).
--  idempotent — يُعاد تشغيلها بأمان. مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) جدول الصادر ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_outbox (
  id              BIGSERIAL PRIMARY KEY,
  ntf_id          TEXT UNIQUE,                          -- مفتاح تكرار (من portal_notifications.id)
  recipient       TEXT NOT NULL,                        -- portal_users.username
  channel         TEXT NOT NULL DEFAULT 'email',        -- email (قابل للتوسّع: sms/webhook)
  type            TEXT,
  title           TEXT NOT NULL,
  body            TEXT,
  link            TEXT,
  status          TEXT NOT NULL DEFAULT 'pending',      -- pending | processing | sent | dead
  attempts        INT  NOT NULL DEFAULT 0,
  max_attempts    INT  NOT NULL DEFAULT 6,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at         TIMESTAMPTZ
);

-- فهرس السحب: المستحقّة أولاً
CREATE INDEX IF NOT EXISTS idx_portal_outbox_due
  ON portal_outbox (next_attempt_at)
  WHERE status = 'pending';

-- server-only: RLS مُفعَّلة بلا أي سياسة ⇒ لا وصول للعميل (anon/authenticated) عبر
-- PostgREST إطلاقاً؛ فقط الدوال SECURITY DEFINER (مالكها postgres) تكتب/تقرأ.
ALTER TABLE portal_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON portal_outbox FROM anon, authenticated, PUBLIC;
GRANT  SELECT, INSERT, UPDATE ON portal_outbox TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_outbox_id_seq TO service_role;

-- ── (2) مُشغِّل الالتقاط المعامَلاتي ─────────────────────────────────────────
-- يعمل داخل نفس معاملة انتقال الحالة. دفاعي: أي خطأ لا يكسر الانتقال (يُبتلع
-- ويُسجَّل تحذيراً) — لأن ثبات الحوكمة أهم من التقاط نيّة بريد واحدة.
CREATE OR REPLACE FUNCTION portal_outbox_enqueue() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  BEGIN
    INSERT INTO portal_outbox (ntf_id, recipient, channel, type, title, body, link)
    VALUES (NEW.id, NEW.recipient, 'email', NEW.type, NEW.title, NEW.body, NEW.link)
    ON CONFLICT (ntf_id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'portal_outbox_enqueue تعذّر إدراج نيّة الإشعار %: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_portal_outbox_enqueue ON portal_notifications;
CREATE TRIGGER trg_portal_outbox_enqueue
  AFTER INSERT ON portal_notifications
  FOR EACH ROW EXECUTE FUNCTION portal_outbox_enqueue();

-- ── (3) سحب الدفعة المستحقّة (خادم فقط) ──────────────────────────────────────
-- FOR UPDATE SKIP LOCKED: عمّال متوازون لا يسحبون نفس الصف. يعلّم processing
-- ويرفع عدّاد المحاولات ذرّياً قبل الإرجاع (فلا إرسال مزدوج عند تعطّل العامل).
CREATE OR REPLACE FUNCTION portal_outbox_claim(p_limit int DEFAULT 20)
RETURNS SETOF portal_outbox
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT (portal_is_service() OR session_user IN ('postgres','supabase_admin')) THEN
    RAISE EXCEPTION 'portal_outbox_claim: صلاحية الخادم مطلوبة';
  END IF;
  RETURN QUERY
  WITH due AS (
    SELECT id FROM portal_outbox
    WHERE status = 'pending' AND next_attempt_at <= now()
    ORDER BY next_attempt_at
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(coalesce(p_limit,20), 100))
  )
  UPDATE portal_outbox o
    SET status = 'processing', attempts = o.attempts + 1, updated_at = now()
  FROM due WHERE o.id = due.id
  RETURNING o.*;
END $fn$;

-- ── (4) تعليم النتيجة: نجاح أو إعادة جدولة بتراجع أُسّي / dead-letter ─────────
CREATE OR REPLACE FUNCTION portal_outbox_mark(p_id bigint, p_ok boolean, p_error text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_row portal_outbox%ROWTYPE; v_delay_min int;
BEGIN
  IF NOT (portal_is_service() OR session_user IN ('postgres','supabase_admin')) THEN
    RAISE EXCEPTION 'portal_outbox_mark: صلاحية الخادم مطلوبة';
  END IF;
  SELECT * INTO v_row FROM portal_outbox WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','not_found'); END IF;

  IF p_ok THEN
    UPDATE portal_outbox SET status = 'sent', sent_at = now(), last_error = NULL, updated_at = now()
      WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'status', 'sent');
  END IF;

  -- فشل: dead-letter عند بلوغ الحد، وإلا إعادة جدولة بتراجع أُسّي (2^n دقيقة، بحدّ 60)
  IF v_row.attempts >= v_row.max_attempts THEN
    UPDATE portal_outbox SET status = 'dead', last_error = p_error, updated_at = now()
      WHERE id = p_id;
    RETURN jsonb_build_object('ok', false, 'status', 'dead', 'attempts', v_row.attempts);
  END IF;

  v_delay_min := LEAST(60, power(2, GREATEST(v_row.attempts,1))::int);
  UPDATE portal_outbox
    SET status = 'pending', next_attempt_at = now() + make_interval(mins => v_delay_min),
        last_error = p_error, updated_at = now()
    WHERE id = p_id;
  RETURN jsonb_build_object('ok', false, 'status', 'retry', 'retry_in_min', v_delay_min, 'attempts', v_row.attempts);
END $fn$;

-- صلاحيات التنفيذ: الخادم فقط (لا anon/authenticated)
REVOKE ALL ON FUNCTION portal_outbox_claim(int)               FROM anon, authenticated, PUBLIC;
REVOKE ALL ON FUNCTION portal_outbox_mark(bigint, boolean, text) FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_outbox_claim(int)               TO service_role;
GRANT EXECUTE ON FUNCTION portal_outbox_mark(bigint, boolean, text) TO service_role;

-- ── (اختياري) تنظيف القديم المُرسَل: يُستدعى من عامل التسليم دورياً ───────────
CREATE OR REPLACE FUNCTION portal_outbox_purge(p_days int DEFAULT 30)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_n int;
BEGIN
  IF NOT (portal_is_service() OR session_user IN ('postgres','supabase_admin')) THEN
    RAISE EXCEPTION 'portal_outbox_purge: صلاحية الخادم مطلوبة';
  END IF;
  DELETE FROM portal_outbox
    WHERE status = 'sent' AND sent_at < now() - make_interval(days => GREATEST(1, coalesce(p_days,30)));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION portal_outbox_purge(int) FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_outbox_purge(int) TO service_role;

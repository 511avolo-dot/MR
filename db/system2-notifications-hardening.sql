-- ════════════════════════════════════════════════════════════════════════════
--  نظام 2 — تصليب `proc_notifications`: القراءة للمستلِم، والكتابة عبر RPC وحدها
--  ----------------------------------------------------------------------------
--  الثغرة المقيسة (db/workflows.sql:53–56): السياسة الوحيدة على الجدول هي
--      CREATE POLICY "auth_all" FOR ALL TO authenticated USING(true) WITH CHECK(true)
--  أي أنّ **أي مستخدم مسجَّل**:
--    (أ) يقرأ إشعارات **كل** الموظفين (عناوينها ومتونها — قرارات اعتماد، مبالغ،
--        أسماء موردين) بطلب PostgREST واحد؛
--    (ب) **يُدرِج إشعاراً بانتحال أي مستلِم** بأي نصّ — فيصنع «قرار اعتماد» زائفاً
--        في جرس المدير مثلاً.
--  و`wfNotify` في الواجهة تُدرِج **من العميل**، فمؤلِّف الإشعار غير موثوق أصلاً.
--
--  هذه هجرة **أمنيّة مستقلّة** عن تصميم «المتابعة والتحديث المباشر»
--  (docs/تصميم-المتابعة-والتحديث-المباشر-بين-القسمين.md) — تُطبَّق وحدها بقرار
--  المالك، والتصميم يُبنى فوقها لاحقاً بعد مراجعة Codex.
--
--  ⚠️ عدم الانحدار: مسارا الخادم (`functions/api/notify.js` و`doc-renew.js`)
--  يُدرجان بمفتاح الخدمة فيتجاوزان RLS ولا يتأثّران. ومسار العميل الوحيد
--  (`wfNotify`) يُحوَّل إلى `proc_notify()` في نفس الدفعة.
--
--  تُشغَّل بعد db/workflows.sql. إضافيّة وidempotent. كتلة التراجع في النهاية.
-- ════════════════════════════════════════════════════════════════════════════

-- ═══════════ 1) عمود المُرسِل — مساءلة لم تكن ممكنة ═══════════
ALTER TABLE proc_notifications
  ADD COLUMN IF NOT EXISTS created_by TEXT;
COMMENT ON COLUMN proc_notifications.created_by IS
  'من أنشأ الإشعار — يُشتقّ خادميّاً من proc_me() داخل proc_notify()، لا يقبله العميل.';


-- ═══════════ 2) الامتيازات: سحب صريح ثمّ منح أدنى ═══════════
-- ⚠️ Supabase تضبط ALTER DEFAULT PRIVILEGES على public تمنح ALL لـanon/authenticated
--    على أي جدول جديد، فـ`GRANT SELECT` وحده **لا يسحب** INSERT/UPDATE/DELETE.
--    (الدرس المسجَّل في system2_request_flow_revoke_message_writes.)
REVOKE ALL ON proc_notifications FROM anon;
REVOKE ALL ON proc_notifications FROM authenticated;
GRANT  SELECT           ON proc_notifications TO authenticated;
-- تعليم «مقروء» فقط — لا تعديل للعنوان أو المتن أو المستلِم.
-- (RLS لا تُقيّد الأعمدة؛ التقييد العموديّ يكون بالمنح.)
GRANT  UPDATE (read)    ON proc_notifications TO authenticated;


-- ═══════════ 3) السياسات: القراءة والتعليم للمستلِم وحده ═══════════
ALTER TABLE proc_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all"        ON proc_notifications;
DROP POLICY IF EXISTS "ntf_select_own"  ON proc_notifications;
DROP POLICY IF EXISTS "ntf_update_own"  ON proc_notifications;

CREATE POLICY "ntf_select_own" ON proc_notifications FOR SELECT TO authenticated
  USING (proc_me() IS NOT NULL AND lower(recipient) = lower(proc_me()));

CREATE POLICY "ntf_update_own" ON proc_notifications FOR UPDATE TO authenticated
  USING      (proc_me() IS NOT NULL AND lower(recipient) = lower(proc_me()))
  WITH CHECK (proc_me() IS NOT NULL AND lower(recipient) = lower(proc_me()));

-- ⚠️ **لا سياسة INSERT ولا DELETE للعميل إطلاقاً** — الإدراج عبر proc_notify()
--    وحدها، والحذف/التنظيف بمفتاح الخدمة. (غياب السياسة = رفض افتراضيّ.)


-- ═══════════ 4) قناة الإدراج الوحيدة ═══════════
CREATE OR REPLACE FUNCTION proc_notify(
  p_recipient text,
  p_type      text,
  p_title     text,
  p_body      text DEFAULT NULL,
  p_link      text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := proc_me(); v_to text; v_id text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF coalesce(btrim(p_title), '') = '' THEN RAISE EXCEPTION 'عنوان الإشعار مطلوب'; END IF;

  -- المستلِم يُحلّ من سجلّ المستخدمين: لا إشعار لاسم ملفَّق أو حساب موقوف.
  SELECT username INTO v_to FROM proc_users
   WHERE lower(username) = lower(btrim(coalesce(p_recipient, '')))
     AND coalesce(active, true)
   LIMIT 1;
  IF v_to IS NULL THEN RETURN NULL; END IF;             -- ليس خطأً: لا مستلِم ⇒ لا إشعار
  IF lower(v_to) = lower(v_me) THEN RETURN NULL; END IF; -- لا يُشعَر الفاعل بفعل نفسه

  v_id := 'ntf_' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')
                 || '_' || substr(md5(random()::text), 1, 6);
  INSERT INTO proc_notifications (id, recipient, type, title, body, link, read, created_by)
  VALUES (v_id, v_to,
          nullif(btrim(coalesce(p_type, '')), ''),
          btrim(p_title),
          nullif(btrim(coalesce(p_body, '')), ''),
          nullif(btrim(coalesce(p_link, '')), ''),
          false, v_me);
  RETURN v_id;
END $fn$;

REVOKE ALL     ON FUNCTION proc_notify(text,text,text,text,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION proc_notify(text,text,text,text,text) TO authenticated;


-- ═══════════ التحقّق (شغّلها بعد التطبيق) ═══════════
-- SELECT polname, cmd FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid
--  WHERE c.relname='proc_notifications';                      -- ntf_select_own(r) · ntf_update_own(w)
-- SELECT has_table_privilege('authenticated','proc_notifications','INSERT');  -- false
-- SELECT has_table_privilege('authenticated','proc_notifications','DELETE');  -- false
-- SELECT has_column_privilege('authenticated','proc_notifications','read','UPDATE');   -- true
-- SELECT has_column_privilege('authenticated','proc_notifications','title','UPDATE');  -- false


-- ═══════════ التراجع ═══════════
-- DROP FUNCTION IF EXISTS proc_notify(text,text,text,text,text);
-- DROP POLICY IF EXISTS "ntf_select_own" ON proc_notifications;
-- DROP POLICY IF EXISTS "ntf_update_own" ON proc_notifications;
-- CREATE POLICY "auth_all" ON proc_notifications
--   FOR ALL TO authenticated USING (true) WITH CHECK (true);
-- GRANT ALL ON proc_notifications TO authenticated;

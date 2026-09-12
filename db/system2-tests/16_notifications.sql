-- ════════════════════════════════════════════════════════════════════════════
--  NT1–NT8 — تصليب `proc_notifications`
--  تُشغَّل بعد db/workflows.sql ثمّ db/system2-notifications-hardening.sql
--
--  الثغرة المُغلَقة: `auth_all FOR ALL USING(true) WITH CHECK(true)` كانت تتيح
--  لأي مستخدم مسجَّل قراءة إشعارات الجميع وإدراج إشعار بانتحال أي مستلِم.
--  التأكيدات **سلوكيّة بدور `authenticated` فعليّ** لا فحصاً لنصّ السياسة.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);

DO $$
DECLARE v_cnt int; v_id text; v_ok boolean;
BEGIN
  DELETE FROM proc_notifications WHERE recipient IN ('nt_alice','nt_bob');
  DELETE FROM proc_users        WHERE username  IN ('nt_alice','nt_bob','nt_gone');

  INSERT INTO proc_users (username, display_name, email, role, active, permissions)
  VALUES ('nt_alice','أليس','nt_alice@aldeyabi.com','user',true,'{}'::jsonb),
         ('nt_bob'  ,'بوب' ,'nt_bob@aldeyabi.com'  ,'user',true,'{}'::jsonb),
         ('nt_gone' ,'موقوف','nt_gone@aldeyabi.com','user',false,'{}'::jsonb);

  -- ── NT1: proc_notify تُدرِج، وتشتقّ المُرسِل من الهوية لا من العميل ──
  PERFORM set_config('request.jwt.claims','{"email":"nt_alice@aldeyabi.com"}',true);
  v_id := proc_notify('nt_bob','message','ردّ على طلبك','نصّ','pr:PR-1');
  IF v_id IS NULL THEN RAISE EXCEPTION 'NT1 فشل: لم يُدرَج إشعار'; END IF;
  IF NOT EXISTS (SELECT 1 FROM proc_notifications
                  WHERE id=v_id AND recipient='nt_bob' AND created_by='nt_alice'
                    AND read = false) THEN
    RAISE EXCEPTION 'NT1 فشل: المُرسِل أو المستلِم غير صحيح';
  END IF;

  -- ── NT2: لا يُشعَر الفاعل بفعل نفسه ──
  IF proc_notify('nt_alice','message','لنفسي','x',NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'NT2 فشل: أشعرت الفاعلَ بفعل نفسه';
  END IF;

  -- ── NT3: مستلِم ملفَّق أو موقوف ⇒ لا إشعار (وليس خطأً) ──
  IF proc_notify('لا_وجود_له','message','ع','ب',NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'NT3 فشل: أُدرِج إشعار لاسم ملفَّق';
  END IF;
  IF proc_notify('nt_gone','message','ع','ب',NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'NT3 فشل: أُدرِج إشعار لحساب موقوف';
  END IF;

  -- ── NT4: عنوان فارغ مرفوض ──
  BEGIN
    PERFORM proc_notify('nt_bob','message','   ','ب',NULL);
    RAISE EXCEPTION 'NT4 فشل: قُبِل عنوان فارغ';
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE 'NT4 فشل%' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'NT1–NT4 نجحت';
END $$;

-- ── NT5–NT8: RLS والامتيازات بدور `authenticated` فعليّ ──
DO $$
DECLARE v_cnt int; v_bad boolean := false;
BEGIN
  -- أليس (المُرسِلة، وليست المستلِمة) يجب ألّا ترى إشعار بوب
  PERFORM set_config('request.jwt.claims','{"email":"nt_alice@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  SELECT count(*) INTO v_cnt FROM proc_notifications WHERE recipient='nt_bob';
  PERFORM set_config('role','postgres',true);
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'NT5 فشل: قرأت أليس إشعارات بوب (% صفّاً)', v_cnt;
  END IF;

  -- بوب يرى إشعاره هو
  PERFORM set_config('request.jwt.claims','{"email":"nt_bob@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  SELECT count(*) INTO v_cnt FROM proc_notifications WHERE recipient='nt_bob';
  PERFORM set_config('role','postgres',true);
  IF v_cnt < 1 THEN RAISE EXCEPTION 'NT6 فشل: لا يرى المستلِم إشعاره'; END IF;

  -- ── NT7: الإدراج المباشر من العميل مرفوض (الامتياز مسحوب) ──
  PERFORM set_config('request.jwt.claims','{"email":"nt_alice@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    INSERT INTO proc_notifications (id, recipient, type, title, read)
    VALUES ('ntf_forged','nt_bob','decision','تم اعتماد طلبك ✓', false);
    v_bad := true;
  EXCEPTION WHEN insufficient_privilege OR others THEN
    v_bad := false;
  END;
  PERFORM set_config('role','postgres',true);
  IF v_bad THEN RAISE EXCEPTION 'NT7 فشل: أُدرِج إشعار مزوَّر مباشرةً من العميل'; END IF;

  RAISE NOTICE 'NT5–NT7 نجحت';
END $$;

-- ── NT8: تعليم «مقروء» مسموح، وتعديل المتن ممنوع (تقييد عموديّ بالمنح) ──
DO $$
BEGIN
  IF NOT has_column_privilege('authenticated','proc_notifications','read','UPDATE') THEN
    RAISE EXCEPTION 'NT8 فشل: المستلِم لا يستطيع تعليم إشعاره مقروءاً';
  END IF;
  IF has_column_privilege('authenticated','proc_notifications','title','UPDATE') THEN
    RAISE EXCEPTION 'NT8 فشل: يمكن تعديل عنوان الإشعار بعد إنشائه';
  END IF;
  IF has_table_privilege('authenticated','proc_notifications','DELETE') THEN
    RAISE EXCEPTION 'NT8 فشل: العميل يستطيع حذف الإشعارات';
  END IF;
  RAISE NOTICE 'NT8 نجحت';
END $$;

SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);
DELETE FROM proc_notifications WHERE recipient IN ('nt_alice','nt_bob');
DELETE FROM proc_users        WHERE username  IN ('nt_alice','nt_bob','nt_gone');
SELECT set_config('request.jwt.claims', '', false);

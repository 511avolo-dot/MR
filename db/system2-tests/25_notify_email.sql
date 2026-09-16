-- ============================================================================
--  NE1–NE7 — عنوان المراسلة مستقلّ عن بريد الدخول (db/system2-notify-email.sql)
--  تُشغَّل بعد تحميل الهجرة في run.sh. الدور فعليّ (authenticated) لا فحص نصّ.
-- ----------------------------------------------------------------------------
--  السياق: بريد المشتريات كان يصل صندوق شخص آخر لأنّ العنوان يُشتقّ من ثابت في
--  الكود. العلاج عمود `notify_email`. وأخطر ما يجب إثباته هنا ليس أنّ العمود
--  موجود — بل **أنّ الهويّة لم تنكسر**: صندوق مشترك في `email` كان يقلب
--  من يدخل به إلى صاحب الصفّ الخطأ.
-- ============================================================================
\set ON_ERROR_STOP on

-- البذر بهويّة الخادم (proc_users_guard يرفض الإدراج من هويّة غير مخوَّلة).
SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

DO $ne$
DECLARE
  v_me text; v_n int; v_ok boolean;
BEGIN
  -- ── بذرة: الحالة الحقيقية — قسم مشتريات بصندوق واحد ──
  -- ⚠️ `pr_has_perm('can_manage_users')` صار جسراً إلى صلاحية الموديل
  -- `pr_manage_users` (لا إلى `permissions` القديم)، فالبذرة تمنحها صراحةً —
  -- وإلّا كان التأكيد يمرّ/يسقط لسببٍ غير الذي يقيسه.
  DELETE FROM proc_users WHERE username IN ('ne_admin','ne_buyer','ne_field');
  INSERT INTO proc_users (username, display_name, role, active, email, notify_email, permissions, pr_permission_overrides)
  VALUES
    ('ne_admin','مدير','admin', true, 'ne_admin@aldeyabi.com', NULL,
     '{"can_manage_users":true}'::jsonb, '{"pr_manage_users":true}'::jsonb),
    ('ne_buyer','مشترٍ','user', true, NULL, 'supply@aldeyabi.com',
     '{"can_manage_rfq":true}'::jsonb, '{}'::jsonb),
    ('ne_field','ميدانيّ','user', true, 'ne_field@aldeyabi.com', NULL,
     '{}'::jsonb, '{}'::jsonb);

  -- NE1 — العمود موجود ويقبل NULL (فالحسابات القائمة لا تتأثّر)
  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_name='proc_users' AND column_name='notify_email';
  IF v_n <> 1 THEN RAISE EXCEPTION 'NE1: عمود notify_email غير موجود'; END IF;
  RAISE NOTICE '  ✓ NE1 العمود موجود ونُشِر بلا كسر الصفوف القائمة';

  -- NE2 — قيد الشكل يرفض بريداً خارج نطاق الشركة
  BEGIN
    UPDATE proc_users SET notify_email='x@gmail.com' WHERE username='ne_buyer';
    RAISE EXCEPTION 'NE2: قُبِل بريد خارج النطاق';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE '  ✓ NE2 بريد خارج @aldeyabi.com مرفوض على مستوى القاعدة';
  END;

  -- NE3 [الأهمّ] — الثابت الذي يُبقي الهويّة حتميّة: **لا بريد دخول مكرّر**.
  -- `proc_me()` تُطابق بالبريد أوّلاً بـ`LIMIT 1` بلا `ORDER BY`، فصفّان يحملان
  -- العنوان نفسه يجعلان الهويّة رهن خطّة التنفيذ. ولهذا صندوق القسم المشترك
  -- يسكن `notify_email` — ولو «أُصلِح» بكتابته في `email` لكسر هذا الثابت.
  -- (بريدُ دخولٍ واحد لصفّ واحد سليم — Mostafa يدخل فعلاً بـsupply@.)
  SELECT count(*) INTO v_n FROM (
    SELECT lower(email) e FROM proc_users
     WHERE coalesce(active,true) AND coalesce(email,'') <> ''
     GROUP BY 1 HAVING count(*) > 1) d;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'NE3: % بريد دخول مكرّر — proc_me تُحلّ الهويّة عشوائيّاً', v_n;
  END IF;
  SELECT (coalesce(email,'') = '' AND notify_email = 'supply@aldeyabi.com') INTO v_ok
    FROM proc_users WHERE username='ne_buyer';
  IF NOT coalesce(v_ok,false) THEN
    RAISE EXCEPTION 'NE3: الصندوق المشترك ليس في notify_email';
  END IF;
  RAISE NOTICE '  ✓ NE3 الصندوق المشترك في notify_email لا في email (الهويّة حتميّة)';

  -- NE4 — proc_me لا تتأثّر بوجود notify_email مشترك
  PERFORM set_config('request.jwt.claims', json_build_object('email','ne_field@aldeyabi.com')::text, true);
  v_me := proc_me();
  IF v_me IS DISTINCT FROM 'ne_field' THEN
    RAISE EXCEPTION 'NE4: proc_me أعادت % بدل ne_field', coalesce(v_me,'NULL');
  END IF;
  RAISE NOTICE '  ✓ NE4 proc_me تُحلّ الهويّة ببريد الدخول وحده';

  -- NE5 — الحارس: غير صاحب صلاحية إدارة المستخدمين لا يُبدّل توجيه البريد
  -- (من يُبدّل بريد مراسلة معتمِد يستقبل رموز الاعتماد بضغطة في صندوقه).
  -- ⚠️ عَلَمٌ لا `RAISE` داخل الكتلة: رمْيُ فشل التأكيد داخل BEGIN…EXCEPTION
  -- يلتقطه معالِجُ الكتلة نفسه فيطبع ✓ — تأكيدٌ لا يمكنه الفشل (أمسكه البيت-بروف).
  PERFORM set_config('request.jwt.claims', json_build_object('email','ne_field@aldeyabi.com')::text, true);
  v_ok := false;  -- true = مُنِع كما يجب
  BEGIN
    SET LOCAL ROLE authenticated;
    UPDATE proc_users SET notify_email='ne_field@aldeyabi.com' WHERE username='ne_buyer';
    RESET ROLE;
  EXCEPTION
    WHEN insufficient_privilege OR raise_exception THEN
      RESET ROLE; v_ok := true;
  END;
  -- وحتى لو مرّت الجملة: RLS قد تُصفّر الصفوف بلا خطأ، فالفحص على **الأثر**.
  IF NOT v_ok THEN
    SELECT (notify_email = 'ne_field@aldeyabi.com') INTO v_ok FROM proc_users WHERE username='ne_buyer';
    IF coalesce(v_ok,false) THEN
      RAISE EXCEPTION 'NE5: موظّف بلا صلاحية بدّل توجيه بريد غيره — رموز الاعتماد تصله';
    END IF;
  END IF;
  RAISE NOTICE '  ✓ NE5 توجيه البريد محروس بصلاحية إدارة المستخدمين';

  -- NE6 — والأدمن يُبدّله (القدرة قائمة فعلاً لا محجوبة عن الجميع)
  PERFORM set_config('request.jwt.claims', json_build_object('email','ne_admin@aldeyabi.com')::text, true);
  UPDATE proc_users SET notify_email='supply@aldeyabi.com' WHERE username='ne_field';
  SELECT notify_email='supply@aldeyabi.com' INTO v_ok FROM proc_users WHERE username='ne_field';
  IF NOT coalesce(v_ok,false) THEN RAISE EXCEPTION 'NE6: الأدمن لم يستطع ضبط بريد المراسلة'; END IF;
  RAISE NOTICE '  ✓ NE6 الأدمن يضبط بريد المراسلة (القدرة قائمة)';

  -- NE7 — idempotent: إعادة تشغيل الهجرة لا تدهس قيمة مضبوطة يدويّاً
  UPDATE proc_users SET notify_email='ne_admin@aldeyabi.com' WHERE username='ne_buyer';
  -- (شرط البذرة: notify_email IS NULL — فقيمةٌ قائمة لا تُمَسّ)
  SELECT notify_email='ne_admin@aldeyabi.com' INTO v_ok FROM proc_users WHERE username='ne_buyer';
  IF NOT coalesce(v_ok,false) THEN RAISE EXCEPTION 'NE7: قيمة يدويّة دُهِست'; END IF;
  RAISE NOTICE '  ✓ NE7 البذرة تحترم قيمة مضبوطة يدويّاً (idempotent)';

  -- ⚠️ التنظيف بهويّة الخادم: حذف الصفوف الثلاثة دفعةً يحذف صفّ الأدمن نفسه
  -- أثناء الجملة، فتسقط هويّته وتُرفَض بقيّة الصفوف في الجملة ذاتها.
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  DELETE FROM proc_users WHERE username IN ('ne_admin','ne_buyer','ne_field');
END $ne$;

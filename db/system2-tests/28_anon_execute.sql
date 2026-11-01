-- ════════════════════════════════════════════════════════════════════════════
--  AX0–AX7 — سحب تنفيذ anon عن مساعدات الهويّة والنطاق
--  تأكيدات **سلوكية**: السحب يُتحقَّق منه بالتشغيل (الحارس ما زال يمنع ·
--  التسجيل العامّ ما زال يعمل · السياسات ما زالت تُقيَّم) لا بقراءة منح.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

INSERT INTO proc_users(username,email,role,active,permissions,scope_sectors,pr_profile_key)
VALUES ('ax_user','ax_user@aldeyabi.com','user',true,'{}'::jsonb,
        '["الصيانة والتشغيل"]'::jsonb,'requester')
ON CONFLICT (username) DO UPDATE SET active=true, role='user',
  scope_sectors='["الصيانة والتشغيل"]'::jsonb, permissions='{}'::jsonb;

-- ════════════════════════════════════════════════════════════════════════════
--  AX0 [شرط لازم] — المنح لـanon **قابل للوجود فعلاً**، فالسحب ليس تأكيداً
--  فراغيّاً على امتياز لم يكن ممنوحاً أصلاً.
-- ════════════════════════════════════════════════════════════════════════════
GRANT EXECUTE ON FUNCTION proc_me(), proc_is_scoped(), proc_users_guard() TO anon;

DO $ax0$
DECLARE v_bad int := 0;
BEGIN
  IF NOT has_function_privilege('anon','proc_me()','EXECUTE') THEN v_bad := v_bad + 1; END IF;
  IF NOT has_function_privilege('anon','proc_is_scoped()','EXECUTE') THEN v_bad := v_bad + 1; END IF;
  IF NOT has_function_privilege('anon','proc_users_guard()','EXECUTE') THEN v_bad := v_bad + 1; END IF;
  IF v_bad > 0 THEN RAISE EXCEPTION 'AX0 فشل: المنح لـanon لم يُطبَّق — التأكيد يختبر فراغاً'; END IF;
  RAISE NOTICE 'AX0 ✅ [شرط لازم] anon كان ينفّذ المساعدات — الحالة المُبلَّغ عنها مُعادة إنتاجاً';
END $ax0$;

-- الهجرة نفسها هي ما يُداوي الحالة (لا استعلامٌ موازٍ في الاختبار)
\i db/system2-anon-execute-hardening.sql

-- ════════════════════════════════════════════════════════════════════════════
--  AX1 — anon لا ينفّذ أيّاً من الثماني
--  AX2 — المستخدم المسجَّل يحتفظ بمساعدات السياسات الأربع
--  AX3 — ولا ينفّذ المساعدات الداخلية الأربع
-- ════════════════════════════════════════════════════════════════════════════
DO $ax123$
DECLARE r record; v_bad text := '';
BEGIN
  FOR r IN SELECT f FROM (VALUES ('pr_is_admin()'),('pr_is_service()'),('pr_username()'),
      ('proc_me()'),('proc_is_scoped()'),('proc_scope_sectors()'),
      ('proc_can_see_po(text)'),('proc_users_guard()')) t(f)
  LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE') THEN v_bad := v_bad || r.f || ' '; END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'AX1 فشل: anon ما زال ينفّذ: %', v_bad; END IF;
  RAISE NOTICE 'AX1 ✅ anon لا ينفّذ أيّاً من الثماني';

  -- AX2: المسجَّل يحتفظ بما تستعمله السياسات **وبمساعدَي الحارسَين غير-DEFINER**.
  -- ⚠️ `pr_is_admin`/`pr_is_service` يُناديهما `pr_guard_status` و
  --    `pr_guard_approval` وهما غير SECURITY DEFINER ⇒ يُنفَّذان بهويّة المتصل،
  --    فسحبهما من المسجَّل يحوّل حارسَي الحوكمة إلى «permission denied».
  --    هذا التأكيد يمنع «تشديداً» لاحقاً يبدو تحسيناً وهو عطل.
  v_bad := '';
  FOR r IN SELECT f FROM (VALUES ('proc_me()'),('proc_is_scoped()'),
      ('proc_scope_sectors()'),('proc_can_see_po(text)'),
      ('pr_is_admin()'),('pr_is_service()')) t(f)
  LOOP
    IF NOT has_function_privilege('authenticated', r.f, 'EXECUTE') THEN v_bad := v_bad || r.f || ' '; END IF;
  END LOOP;
  IF v_bad <> '' THEN
    RAISE EXCEPTION 'AX2 فشل: المسجَّل فقد مساعدات تستعملها السياسات أو الحُرّاس غير-DEFINER: %', v_bad;
  END IF;
  RAISE NOTICE 'AX2 ✅ المسجَّل يحتفظ بمساعدات السياسات والحُرّاس الستّ';

  v_bad := '';
  FOR r IN SELECT f FROM (VALUES ('pr_username()'),('proc_users_guard()')) t(f)
  LOOP
    IF has_function_privilege('authenticated', r.f, 'EXECUTE') THEN v_bad := v_bad || r.f || ' '; END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'AX3 فشل: المسجَّل ما زال ينفّذ داخليّات: %', v_bad; END IF;
  RAISE NOTICE 'AX3 ✅ المساعدات الداخلية مسحوبة من المسجَّل كذلك';
END $ax123$;

-- ════════════════════════════════════════════════════════════════════════════
--  AX7 — **بالتشغيل**: حارسا الحوكمة غير-DEFINER ما زالا يعملان بهويّة
--  المستخدم المسجَّل. (لا يكفي فحص المنح: المقصود أنّ الحارس **يمنع** لا أنّه
--  يرمي خطأ صلاحية — والنتيجة من الخارج تبدو واحدة.)
-- ════════════════════════════════════════════════════════════════════════════
DO $ax7$
DECLARE v_err text := ''; v_blocked boolean := false;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"email":"ax_user@aldeyabi.com"}',true);
  BEGIN
    UPDATE proc_purchase_requests SET status='approved' WHERE false;
  EXCEPTION WHEN others THEN v_blocked := true; v_err := SQLERRM; END;
  RESET ROLE;
  IF v_blocked AND v_err ILIKE '%permission denied for function%' THEN
    RAISE EXCEPTION 'AX7 فشل: الحارس غير-DEFINER تعطّل بسحب تنفيذ مساعده ⇒ %', v_err;
  END IF;
  RAISE NOTICE 'AX7 ✅ حارسا الحوكمة غير-DEFINER يعملان (لا خطأ صلاحية على مساعديهما)';
END $ax7$;

-- ════════════════════════════════════════════════════════════════════════════
--  AX4 — **بالتشغيل**: حارس المستخدمين ما زال يمنع تصعيد الصلاحية بعد سحب
--  تنفيذه. (سحب EXECUTE عن دالّة مُشغِّل قد يُعطّلها — سابقة موثّقة، فلا يُكتفى
--  بقراءة المنح.)
-- ════════════════════════════════════════════════════════════════════════════
DO $ax4$
DECLARE v_ok boolean := false; v_role text; v_scope jsonb;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"email":"ax_user@aldeyabi.com"}',true);
  BEGIN
    UPDATE proc_users SET role='admin' WHERE username='ax_user';
  EXCEPTION WHEN others THEN v_ok := true; END;
  RESET ROLE;

  SELECT role, scope_sectors INTO v_role, v_scope FROM proc_users WHERE username='ax_user';
  IF v_role = 'admin' THEN
    RAISE EXCEPTION 'AX4 فشل: تصعيد الدور نفذ — الحارس تعطّل بسحب تنفيذه';
  END IF;
  IF NOT v_ok AND v_role <> 'user' THEN
    RAISE EXCEPTION 'AX4 فشل: الدور صار % بلا منع', v_role;
  END IF;
  RAISE NOTICE 'AX4 ✅ الحارس ما زال يمنع التصعيد بعد سحب تنفيذه (الدور %)', v_role;
END $ax4$;

-- ════════════════════════════════════════════════════════════════════════════
--  AX5 — **بالتشغيل**: المسار المشروع الوحيد لـanon ما زال يعمل — إدراج طلب
--  تسجيل مورّد — ويبقى لا يقرأ شيئاً.
-- ════════════════════════════════════════════════════════════════════════════
DO $ax5$
DECLARE v_n int; v_ins boolean := true; v_err text := '';
BEGIN
  SET LOCAL ROLE anon;
  PERFORM set_config('request.jwt.claims','{"role":"anon"}',true);
  -- ⚠️ يُلتقط فشل الإدراج كي يقول الإخفاقُ **أيّ عقدٍ انكسر** بدل أن يُسرّب
  --    خطأ سياسة خاماً؛ و`RAISE` الفشل خارج كتلة الالتقاط (وإلّا ابتلعها معالِجها).
  BEGIN
    INSERT INTO proc_supplier_registrations(id,legal_name_ar,status)
    VALUES ('DG-AX0001','مورّد اختبار السحب','pending');
  EXCEPTION WHEN others THEN v_ins := false; v_err := SQLERRM;
  END;
  SELECT count(*) INTO v_n FROM proc_supplier_registrations;
  RESET ROLE;
  IF NOT v_ins THEN
    RAISE EXCEPTION 'AX5 فشل: تسجيل المورّد العامّ مُنِع — المسار المشروع لـanon انكسر (%)', v_err;
  END IF;
  IF v_n <> 0 THEN RAISE EXCEPTION 'AX5 فشل: anon قرأ % صفّاً', v_n; END IF;
  SELECT count(*) INTO v_n FROM proc_supplier_registrations WHERE id='DG-AX0001';
  IF v_n <> 1 THEN RAISE EXCEPTION 'AX5 فشل: التسجيل العامّ لم يُدرَج (%)', v_n; END IF;
  RAISE NOTICE 'AX5 ✅ تسجيل المورّد العامّ ما زال يعمل، وanon يقرأ صفراً';
END $ax5$;

-- ════════════════════════════════════════════════════════════════════════════
--  AX6 — **بالتشغيل**: سياسات RLS التي تُنادي proc_me/proc_is_scoped ما زالت
--  تُقيَّم بهويّة المستخدم المسجَّل (لو سُحِبت عنه لانقطع دخوله).
-- ════════════════════════════════════════════════════════════════════════════
DO $ax6$
DECLARE v_n int;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"email":"ax_user@aldeyabi.com"}',true);
  SELECT count(*) INTO v_n FROM proc_users WHERE username='ax_user';
  RESET ROLE;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'AX6 فشل: المستخدم المُنطَّق لم يقرأ صفّه (%) — سياسةٌ انكسرت بالسحب', v_n;
  END IF;
  RAISE NOTICE 'AX6 ✅ سياسات الهويّة والنطاق ما زالت تُقيَّم للمستخدم المسجَّل';
  RAISE NOTICE '── AX0–AX7 كلها ناجحة ──';
END $ax6$;

DELETE FROM proc_supplier_registrations WHERE id='DG-AX0001';

-- ============================================================================
--  بريد المراسلة مستقلّ عن بريد الدخول  —  proc_users.notify_email
--  النظام 2 (proc_*) على مشروع Supabase القديم yofcaxvstjcrmbgciwym
--  تُطبَّق بعد: db/system2-staff-scope.sql  (تحتاج proc_users_guard / pr_is_service)
-- ----------------------------------------------------------------------------
--  السبب (بلاغ المالك 2026-09-16، مقيس):
--    بريد «طلب معتمد جاهز للمشتريات» كان يصل إلى mahmoud@aldeyabi.com — وهو
--    صندوق **شخص آخر** (محمود السيد) لا علاقة له بمحمود العامودي. الجذر أنّ
--    عمود `email` فارغ لثلاثة حسابات، فالعنوان **يُشتقّ** من ثابت مكتوب في
--    الكود منذ مايو (`AUTH_EMAIL_MAP`). وقرار المالك: قسم المشتريات له صندوق
--    عامّ واحد (supply@aldeyabi.com) ولا بريد مخصّص لموظّف بعينه.
--
--  ⚠️ ولماذا عمود جديد بدل ملء `email` القائم (قِيس قبل الكتابة — لا يُخمَّن):
--    `proc_me()` تُطابق **بالبريد أوّلاً**:
--        SELECT username FROM proc_users WHERE active AND lower(email)=jwt_email LIMIT 1
--    فلو كُتِب supply@aldeyabi.com في صفّ Mahmoud لصار دخول supply@ يُحلّ إلى
--    **Mahmoud** (الصفّ الوحيد الحامل لذلك البريد) بدل Mostafa — أي أنّ مديراً
--    (admin) ينقلب موظّفاً عاديّاً في كل جلسة. فالبريد في `email` هويّةُ دخول،
--    و`notify_email` عنوانُ مراسلة. الفصل مقصود ومحروس.
--
--  ⚠️ ولا يُمَسّ `AUTH_EMAIL_MAP` في `notify.js`/`admin-users.js`:
--    هناك يُستعمَل للهويّة (verifyStaff · اشتقاق حساب Auth · كلمة المرور)،
--    فتغييره كان سيمنع محمود من نقطة /api/notify ويوجّه عمليات حسابه لصندوق آخر.
-- ============================================================================

BEGIN;

-- 1) العمود ------------------------------------------------------------------
ALTER TABLE public.proc_users ADD COLUMN IF NOT EXISTS notify_email text;

COMMENT ON COLUMN public.proc_users.notify_email IS
  'عنوان المراسلة (إشعارات البريد) إن اختلف عن بريد الدخول — مثل صندوق قسم عامّ. '
  'لا يُستعمَل للهويّة إطلاقاً: proc_me()/pr_username() تقرآن email/username وحدهما.';

-- قيد الشكل: فارغ أو بريد شركة صالح بحروف صغيرة.
-- (بريد خارج النطاق لا يصله إشعار أصلاً — `userEmail` تشترط @aldeyabi.com —
--  فقبوله هنا يعني وعداً كاذباً بوصول البريد.)
DO $c$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.proc_users'::regclass AND conname = 'proc_users_notify_email_fmt'
  ) THEN
    ALTER TABLE public.proc_users
      ADD CONSTRAINT proc_users_notify_email_fmt
      CHECK (notify_email IS NULL OR notify_email ~ '^[a-z0-9._%+-]+@aldeyabi\.com$');
  END IF;
END $c$;

-- 2) الحارس ------------------------------------------------------------------
-- ⚠️ القاعدة 16: أي عمود جديد يحمل صلاحية أو **توجيهاً** يُضاف إلى قائمة
-- proc_users_guard في الهجرة نفسها. وتوجيه البريد صلاحيةٌ فعليّة: من يُبدّل
-- notify_email لمعتمِدٍ يستقبل **رموز الاعتماد بضغطة** في صندوقه.
CREATE OR REPLACE FUNCTION public.proc_users_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF pr_is_service() THEN RETURN COALESCE(NEW, OLD); END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.permissions             IS NOT DISTINCT FROM OLD.permissions
     AND NEW.role                    IS NOT DISTINCT FROM OLD.role
     AND NEW.active                  IS NOT DISTINCT FROM OLD.active
     AND NEW.is_away                 IS NOT DISTINCT FROM OLD.is_away
     AND NEW.delegate_to             IS NOT DISTINCT FROM OLD.delegate_to
     AND NEW.username                IS NOT DISTINCT FROM OLD.username
     AND NEW.email                   IS NOT DISTINCT FROM OLD.email
     AND NEW.notify_email            IS NOT DISTINCT FROM OLD.notify_email
     AND NEW.password_hash           IS NOT DISTINCT FROM OLD.password_hash
     AND NEW.scope_sectors           IS NOT DISTINCT FROM OLD.scope_sectors
     AND NEW.department_id           IS NOT DISTINCT FROM OLD.department_id
     AND NEW.manager_user            IS NOT DISTINCT FROM OLD.manager_user
     AND NEW.requested_role          IS NOT DISTINCT FROM OLD.requested_role
     AND NEW.pr_profile_key          IS NOT DISTINCT FROM OLD.pr_profile_key
     AND NEW.pr_permission_overrides IS NOT DISTINCT FROM OLD.pr_permission_overrides
     AND NEW.pr_department_ids       IS NOT DISTINCT FROM OLD.pr_department_ids
  THEN RETURN NEW; END IF;

  IF pr_has_perm('can_manage_users') THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل المستخدمين أو صلاحياتهم يتطلّب صلاحية «إدارة المستخدمين»';
END $function$;

COMMIT;

-- ============================================================================
--  3) ضبط الحالة القائمة — بيانات لا مخطّط (تُشغَّل مرّة واحدة على الإنتاج)
--     محمود العامودي يستعمل صندوق قسم المشتريات العامّ، ولا بريد مخصّص له.
--     idempotent: لا تُعيد الكتابة إن ضُبِطت قيمة يدويّاً لاحقاً.
-- ============================================================================
DO $seed$
DECLARE v_n int := 0;
BEGIN
  IF to_regclass('public.proc_users') IS NULL THEN RETURN; END IF;

  -- ⚠️ `proc_users_guard` يرفض أي كتابة من هويّة غير مخوَّلة، ومحرّر SQL/قناة
  -- الهجرة تعمل **بلا JWT** فتسقط على الحارس. نرفع هويّة الخدمة **محصورةً
  -- بالمعاملة** (`is_local=true`) فتُصفَّر تلقائياً بعدها (سابقة proc_config_guard).
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);

  UPDATE public.proc_users
     SET notify_email = 'supply@aldeyabi.com'
   WHERE username = 'Mahmoud'
     AND notify_email IS NULL
     AND coalesce(email,'') = '';
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n > 0 AND to_regclass('public.proc_audit_log') IS NOT NULL THEN
    INSERT INTO public.proc_audit_log (username, display_name, user_role, action, entity_type, entity_id, old_value, new_value)
    VALUES ('system', 'تصحيح بيانات', 'system', 'user_notify_email_set', 'user', 'Mahmoud',
            jsonb_build_object('notify_email', null, 'derived_to', 'mahmoud@aldeyabi.com'),
            jsonb_build_object('notify_email', 'supply@aldeyabi.com',
                               'reason', 'صندوق قسم المشتريات العامّ — mahmoud@aldeyabi.com يخصّ شخصاً آخر'));
  END IF;

  RAISE NOTICE 'notify_email seeded rows: %', v_n;
END $seed$;

-- ============================================================================
--  تحقّق سريع بعد التطبيق:
--    select username, email, notify_email from proc_users order by username;
--    -- ويجب أن يبقى: proc_me() لدخول supply@ = Mostafa  (الهويّة لم تتغيّر)
-- ============================================================================

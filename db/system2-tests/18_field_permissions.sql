-- ════════════════════════════════════════════════════════════════════════════
--  FP1–FP10 — صلاحيات الميدان قابلة للمنح والسحب **على الخادم**
--  تُشغَّل بعد db/system2-field-permissions.sql
--
--  بلاغ المالك: «لا صلاحيات ممكن إعطاؤها أو سحبها» لموظفي الصيانة والتشغيل.
--  الحراسة قبلها كانت **نطاقاً** («أنت صاحب الطلب») لا **صلاحية** — تمنع
--  الوصول لبيانات الغير ولا تُمكِّن المدير من تحديد ما يفعله موظّفه.
--
--  ⚠️ التأكيدات **سلوكية بدور `authenticated` فعليّ**: لا يكفي أن تُرجع
--  `proc_has_perm` قيمةً — المطلوب أن تمنع السياسةُ الكتابةَ فعلاً. (سابقة
--  «لا تُبدِّل التأكيد السلوكيّ بفحص نصّيّ» — الفحص النصّيّ هو ما مرّ عليه العيب.)
--
--  ⚠️ والقيد الأوّل عدم الانحدار: موظّف المكتب بلا المفاتيح الجديدة **يجب** أن
--  يبقى يرفع الطلبات ويرفع المستندات ويعلّق — وهو حال الثلاثة القائمين.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);

DO $$
DECLARE v boolean; v_err text; v_n int;
BEGIN
  DELETE FROM proc_pr_items WHERE pr_id LIKE 'FP-%';
  DELETE FROM proc_purchase_requests WHERE id LIKE 'FP-%';
  DELETE FROM proc_users WHERE username IN ('fp_office','fp_field','fp_field_no','fp_admin');

  INSERT INTO proc_users (username, display_name, email, role, active, permissions, scope_sectors)
  VALUES
    -- موظّف مكتب: بلا أي مفتاح جديد ولا نطاق — حال الثلاثة القائمين حرفيّاً
    ('fp_office','مكتب','fp_office@aldeyabi.com','user',true,'{}'::jsonb, NULL),
    -- ميدانيّ ممنوح كل قدرات الميدان (ما يكتبه رابط الدعوة)
    ('fp_field','ميدان','fp_field@aldeyabi.com','user',true,
     '{"can_create_pr":true,"can_upload_docs":true,"can_comment":true,
       "can_print_followup":true,"can_receive_po":true,"can_view_amounts":false}'::jsonb,
     '["الصيانة والتشغيل"]'::jsonb),
    -- ميدانيّ **مسحوبة منه** القدرات (قالب «متابعة فقط»)
    ('fp_field_no','ميدان-','fp_field_no@aldeyabi.com','user',true,
     '{"can_create_pr":false,"can_upload_docs":false,"can_comment":false}'::jsonb,
     '["الصيانة والتشغيل"]'::jsonb),
    ('fp_admin','أدمن','fp_admin@aldeyabi.com','admin',true,'{}'::jsonb, NULL);

  -- ══ FP1: عدم الانحدار — موظّف المكتب بلا المفاتيح يملكها كلّها ══
  PERFORM set_config('request.jwt.claims','{"email":"fp_office@aldeyabi.com"}',true);
  IF NOT (proc_has_perm('can_create_pr') AND proc_has_perm('can_upload_docs')
          AND proc_has_perm('can_comment') AND proc_has_perm('can_print_followup')) THEN
    RAISE EXCEPTION 'FP1 فشل: موظّف المكتب فقد قدرةً يملكها اليوم (انحدار)';
  END IF;

  -- ══ FP2: الميدانيّ الممنوح يملكها، والمسحوب منه لا ══
  PERFORM set_config('request.jwt.claims','{"email":"fp_field@aldeyabi.com"}',true);
  IF NOT (proc_has_perm('can_create_pr') AND proc_has_perm('can_upload_docs')
          AND proc_has_perm('can_comment')) THEN
    RAISE EXCEPTION 'FP2 فشل: المنح الصريح لم يصل الميدانيّ';
  END IF;
  PERFORM set_config('request.jwt.claims','{"email":"fp_field_no@aldeyabi.com"}',true);
  IF proc_has_perm('can_create_pr') OR proc_has_perm('can_upload_docs')
     OR proc_has_perm('can_comment') THEN
    RAISE EXCEPTION 'FP2 فشل: السحب الصريح لم يُطبَّق على الميدانيّ';
  END IF;

  -- ══ FP3: المُنطَّق **بلا مفتاح إطلاقاً** ممنوع (المنح صريح أو لا شيء) ══
  --    هذا ما يجعل رابط الدعوة ملزَماً بكتابة المفاتيح صراحةً.
  -- ⚠️ كل تعديل على `proc_users` يعود لهوية الخدمة أوّلاً: `proc_users_guard`
  --    يرفض تعديل الصلاحيات بلا صلاحية إدارية — وهو حارس حقيقيّ لا عائق اختبار.
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  UPDATE proc_users SET permissions = '{}'::jsonb WHERE username = 'fp_field_no';
  PERFORM set_config('request.jwt.claims','{"email":"fp_field_no@aldeyabi.com"}',true);
  IF proc_has_perm('can_create_pr') THEN
    RAISE EXCEPTION 'FP3 فشل: مُنطَّق بلا مفتاح مُنِح قدرةً ضمنيّاً';
  END IF;
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  UPDATE proc_users SET permissions =
    '{"can_create_pr":false,"can_upload_docs":false,"can_comment":false}'::jsonb
   WHERE username = 'fp_field_no';

  -- ══ FP4: الأدمن فوق كل ذلك ══
  PERFORM set_config('request.jwt.claims','{"email":"fp_admin@aldeyabi.com"}',true);
  IF NOT proc_has_perm('can_create_pr') THEN
    RAISE EXCEPTION 'FP4 فشل: الأدمن مُنِع من قدرة';
  END IF;

  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
END $$;

-- ══ FP5: السياسة تمنع الإدراج فعلاً (سلوكيّ بدور authenticated) ══
DO $$
DECLARE v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"fp_field_no@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    INSERT INTO proc_purchase_requests (id, title, requester, sector, status)
    VALUES ('FP-1','محاولة','fp_field_no','الصيانة والتشغيل','draft');
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN v_ok := true;
  END;
  -- RLS تُخفِق بـ42501 (insufficient_privilege) على WITH CHECK.
  IF NOT v_ok AND EXISTS (SELECT 1 FROM proc_purchase_requests WHERE id='FP-1') THEN
    PERFORM set_config('role','postgres',true);
    RAISE EXCEPTION 'FP5 فشل: مسحوبُ الصلاحية أنشأ طلباً';
  END IF;
  PERFORM set_config('role','postgres',true);
END $$;

-- ══ FP6: والممنوح يُنشئ طلبه فعلاً (لا يكفي المنع — لا بدّ أن يعمل) ══
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"fp_field@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  INSERT INTO proc_purchase_requests (id, title, requester, sector, status)
  VALUES ('FP-2','طلب مشروع','fp_field','الصيانة والتشغيل','draft');
  INSERT INTO proc_pr_items (pr_id, description, requested_qty)
  VALUES ('FP-2','فلتر', 10);
  PERFORM set_config('role','postgres',true);
  IF NOT EXISTS (SELECT 1 FROM proc_purchase_requests WHERE id='FP-2') THEN
    RAISE EXCEPTION 'FP6 فشل: الممنوح لم يستطع إنشاء طلبه';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM proc_pr_items WHERE pr_id='FP-2') THEN
    RAISE EXCEPTION 'FP6 فشل: الممنوح لم يستطع كتابة بنود طلبه';
  END IF;
END $$;

-- ══ FP7: وموظّف المكتب بلا المفاتيح يُنشئ كما كان (عدم الانحدار سلوكيّاً) ══
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"fp_office@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  INSERT INTO proc_purchase_requests (id, title, requester, sector, status)
  VALUES ('FP-3','طلب مكتب','fp_office','الإدارة العامة','draft');
  PERFORM set_config('role','postgres',true);
  IF NOT EXISTS (SELECT 1 FROM proc_purchase_requests WHERE id='FP-3') THEN
    RAISE EXCEPTION 'FP7 فشل: موظّف المكتب مُنِع من إنشاء طلب (انحدار)';
  END IF;
END $$;

-- ══ FP8: رفع المستند محكوم بمفتاحه وحده ══
--    الميدانيّ الممنوح `can_create_pr` لكن **مسحوباً منه** `can_upload_docs`
--    يجب أن يُمنَع من `pr_set_doc` وحدها — برهان أن المفاتيح مستقلّة لا واحد.
DO $$
DECLARE v_err text;
BEGIN
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  UPDATE proc_users SET permissions = permissions || '{"can_upload_docs":false}'::jsonb
   WHERE username = 'fp_field';
  PERFORM set_config('request.jwt.claims','{"email":"fp_field@aldeyabi.com"}',true);
  BEGIN
    PERFORM pr_set_doc('FP-2', 'docs/pr/FP-2/x.pdf', 'x.pdf');
    RAISE EXCEPTION 'FP8 فشل: رفع المستند مرّ رغم سحب can_upload_docs';
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err NOT LIKE '%صلاحية رفع المستندات%' THEN RAISE; END IF;
  END;
  -- وبإعادة المنح يمرّ (قابلية ضبط لا قاعدة مثبَّتة)
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  UPDATE proc_users SET permissions = permissions || '{"can_upload_docs":true}'::jsonb
   WHERE username = 'fp_field';
  PERFORM set_config('request.jwt.claims','{"email":"fp_field@aldeyabi.com"}',true);
  PERFORM pr_set_doc('FP-2', 'docs/pr/FP-2/x.pdf', 'x.pdf');
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  IF (SELECT doc_key FROM proc_purchase_requests WHERE id='FP-2') IS NULL THEN
    RAISE EXCEPTION 'FP8 فشل: إعادة المنح لم تُعِد قدرة الرفع';
  END IF;
END $$;

-- ══ FP9: التعليق والردّ بمفتاحهما — على الطلب وعلى أمر الشراء معاً ══
DO $$
DECLARE v_err text;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"fp_field_no@aldeyabi.com"}',true);
  BEGIN
    PERFORM pr_post_message('FP-2', 'محاولة', 'answer');
    RAISE EXCEPTION 'FP9 فشل: الردّ مرّ رغم سحب can_comment';
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err NOT LIKE '%صلاحية الردّ%' THEN RAISE; END IF;
  END;
  -- والممنوح يردّ فعلاً
  PERFORM set_config('request.jwt.claims','{"email":"fp_field@aldeyabi.com"}',true);
  PERFORM pr_post_message('FP-2', 'الكمية 100', 'answer');
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  IF NOT EXISTS (SELECT 1 FROM proc_pr_messages WHERE pr_id='FP-2') THEN
    RAISE EXCEPTION 'FP9 فشل: الممنوح لم يستطع الردّ';
  END IF;
END $$;

-- ══ FP10: القوالب تتبع رفع الطلبات (قرار المالك: أربعة مفاتيح لا سبعة) ══
DO $$
DECLARE v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"fp_field_no@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    INSERT INTO proc_pr_templates (id, name, owner, sector, items)
    VALUES ('FPT-1','قالب','fp_field_no','الصيانة والتشغيل','[]'::jsonb);
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN v_ok := true;
  END;
  PERFORM set_config('role','postgres',true);
  IF NOT v_ok AND EXISTS (SELECT 1 FROM proc_pr_templates WHERE id='FPT-1') THEN
    RAISE EXCEPTION 'FP10 فشل: مسحوبُ الصلاحية حفظ قالباً';
  END IF;
END $$;

-- تنظيف
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);
DELETE FROM proc_pr_messages WHERE pr_id LIKE 'FP-%';
DELETE FROM proc_pr_templates WHERE id LIKE 'FPT-%';
DELETE FROM proc_pr_items WHERE pr_id LIKE 'FP-%';
DELETE FROM proc_purchase_requests WHERE id LIKE 'FP-%';
DELETE FROM proc_users WHERE username IN ('fp_office','fp_field','fp_field_no','fp_admin');
SELECT set_config('request.jwt.claims', '', false);

DO $$ BEGIN RAISE NOTICE 'FP1–FP10 نجحت'; END $$;

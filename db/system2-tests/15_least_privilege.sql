-- ════════════════════════════════════════════════════════════════════════════
--  LP1–LP5 — أقلّ امتياز: افتراضيّ «عرض المبالغ» يُصفَّر للمُنطَّق وحده
--  تُشغَّل بعد db/system2-scoped-least-privilege.sql
--
--  ⚠️ القيد الأوّل هو عدم الانحدار: موظّف المكتب بلا المفتاح **يجب** أن يبقى
--  يرى المبالغ — وهو حال الأربعة القائمين على الإنتاج جميعاً.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

-- ⚠️ البذر والتنظيف بهوية الخدمة: `proc_users_guard` يرفض تعديل المستخدمين
-- بلا صلاحية إدارية. أمّا التأكيدات فتُجرى بهوية كل مستخدم على حدة.
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);

DO $$
DECLARE v boolean;
BEGIN
  -- تنظيف أي بقايا من تشغيل سابق
  DELETE FROM proc_users WHERE username IN ('lp_office','lp_field','lp_field_yes','lp_admin');

  INSERT INTO proc_users (username, display_name, email, role, active, permissions, scope_sectors)
  VALUES
    -- موظّف مكتب: لا مفتاح ولا نطاق (حال الأربعة القائمين حرفيّاً)
    ('lp_office','مكتب','lp_office@aldeyabi.com','user',true,'{}'::jsonb, NULL),
    -- موظّف ميدانيّ: نطاق، وبلا المفتاح (الحساب الذي يُنشئه المالك يدويّاً وينسى)
    ('lp_field','ميدان','lp_field@aldeyabi.com','user',true,'{}'::jsonb,'["الصيانة والتشغيل"]'::jsonb),
    -- ميدانيّ مُنِح المفتاح صراحةً (قابلية الضبط)
    ('lp_field_yes','ميدان+','lp_field_yes@aldeyabi.com','user',true,
     '{"can_view_amounts":true}'::jsonb,'["الصيانة والتشغيل"]'::jsonb),
    -- أدمن بنطاق: يبقى فوق كل شيء
    ('lp_admin','أدمن','lp_admin@aldeyabi.com','admin',true,'{}'::jsonb,'["الصيانة والتشغيل"]'::jsonb);

  -- ── LP1: موظّف المكتب بلا المفتاح يبقى يرى المبالغ (صفر انحدار) ──
  PERFORM set_config('request.jwt.claims','{"email":"lp_office@aldeyabi.com"}',true);
  SELECT proc_can_view_amounts() INTO v;
  IF v IS NOT TRUE THEN
    RAISE EXCEPTION 'LP1 فشل: موظّف المكتب فقد المبالغ (انحدار) — %', v;
  END IF;
  IF proc_is_scoped() THEN RAISE EXCEPTION 'LP1 فشل: موظّف المكتب صار مُنطَّقاً'; END IF;

  -- ── LP2: الميدانيّ بلا المفتاح لا يرى المبالغ (الإصلاح) ──
  PERFORM set_config('request.jwt.claims','{"email":"lp_field@aldeyabi.com"}',true);
  SELECT proc_can_view_amounts() INTO v;
  IF v IS NOT FALSE THEN
    RAISE EXCEPTION 'LP2 فشل: الميدانيّ بلا المفتاح ما زال يرى المبالغ — %', v;
  END IF;

  -- ── LP3: والمنح الصريح يُعيدها (قابلية ضبط لا قاعدة مثبَّتة) ──
  PERFORM set_config('request.jwt.claims','{"email":"lp_field_yes@aldeyabi.com"}',true);
  SELECT proc_can_view_amounts() INTO v;
  IF v IS NOT TRUE THEN
    RAISE EXCEPTION 'LP3 فشل: المنح الصريح لم يُعِد المبالغ للميدانيّ — %', v;
  END IF;

  -- ── LP4: الأدمن فوق الصرامة ولو أُسنِد له قطاع ──
  PERFORM set_config('request.jwt.claims','{"email":"lp_admin@aldeyabi.com"}',true);
  SELECT proc_can_view_amounts() INTO v;
  IF v IS NOT TRUE THEN RAISE EXCEPTION 'LP4 فشل: الأدمن فقد المبالغ — %', v; END IF;

  -- ── LP5: العرض يتبع الدالّة فعلاً — الميدانيّ يقرأ الصفّ بمبالغ فارغة ──
  --    (البرهان السلوكيّ: لا يكفي أن تُرجع الدالّة false.)
  PERFORM set_config('request.jwt.claims','{"email":"lp_field@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  IF EXISTS (SELECT 1 FROM proc_po_visible
              WHERE sector = 'الصيانة والتشغيل' AND total IS NOT NULL) THEN
    RAISE EXCEPTION 'LP5 فشل: مبلغ وصل الميدانيّ من العرض رغم تصفير الافتراضيّ';
  END IF;
  PERFORM set_config('role','postgres',true);

  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  DELETE FROM proc_users WHERE username IN ('lp_office','lp_field','lp_field_yes','lp_admin');
  RAISE NOTICE 'LP1–LP5 نجحت';
END $$;

SELECT set_config('request.jwt.claims', '', false);

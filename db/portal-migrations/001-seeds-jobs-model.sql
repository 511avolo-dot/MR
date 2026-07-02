-- ════════════════════════════════════════════════════════════════════════
--  Migration 001 — البذور المرجعية + نموذج الوظائف (المرحلة 1)
-- ════════════════════════════════════════════════════════════════════════
--  المصدر: «الملف الشامل المتكامل» الباب 4 (الأدوار والوظائف الـ18) والباب 5
--  (سلاسل القطاعات buildSectorWorkflows) — منقول حرفياً مع ترجمة مفاتيح
--  صلاحيات النموذج إلى مفاتيح النظام الحيّ (جدول الترجمة أدناه).
--
--  آمن لإعادة التشغيل بالكامل (idempotent). لا يمسّ أي بيانات قائمة إلا
--  تحديثاً موثّقاً واحداً: مفتاح اعتماد التعميد للشريحتين الدنيتين في DoA.
--
--  ترجمة مفاتيح الصلاحيات (نموذج → حيّ):
--    approveReq   → can_approve_stage      (اعتماد الحاجة — الدورة الأولى)
--    approveAward → can_approve_award      (اعتماد التعميد — الدورة الثانية)
--    issuePO      → can_issue_po           (إصدار أمر الشراء)
--    manageRfq    → can_manage_procurement (إدارة التسعير والعروض — قائم)
--    disburse     → can_disburse           (اعتماد وتنفيذ الصرف — قائم)
--    create       → can_create             (رفع الطلبات)
--    edit         → can_edit               (تعديل الطلبات)
--    manageUsers  → can_manage_users       (إدارة المستخدمين — قائم)
--    see.finance  → can_see_finance        (رؤية مالية)
--    التحقق المالي المسبق (مرحلة سير العمل) → can_approve_finance (قائم)
--  ملاحظة تعيين حيّ: أمين المستودع يحمل can_verify_stock لأن تسجيل الاستلام
--  في المحرّك الحيّ مبوّب بها (portal_record_receipt).
-- ════════════════════════════════════════════════════════════════════════


-- ═══════════════ 1) الأقسام/القطاعات الأربعة (باب 6 المرجعي) ═══════════════
-- بلا مدراء — يُسندون من شاشة الإدارة بعد إنشاء الحسابات الفعلية
-- (مستخدمو النموذج التجريبيون khalid/faisal... لا يُبذرون عمداً).

INSERT INTO portal_departments (id, name_ar, sector, active)
SELECT 'OPS', 'الصيانة والتشغيل', 'الصيانة والتشغيل', true
WHERE NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = 'OPS');

INSERT INTO portal_departments (id, name_ar, sector, active)
SELECT 'CON', 'الإنشاءات', 'الإنشاءات', true
WHERE NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = 'CON');

INSERT INTO portal_departments (id, name_ar, sector, active)
SELECT 'GA', 'الإدارة العامة', 'الإدارة العامة', true
WHERE NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = 'GA');

INSERT INTO portal_departments (id, name_ar, sector, active)
SELECT 'LOG', 'النقليات', 'النقليات', true
WHERE NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = 'LOG');


-- ═══════════════ 2) كتالوج الوظائف الـ18 (الباب 4 حرفياً) ═══════════════

-- الإدارة العليا
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'gm', 'المدير العام', 'الإدارة العليا', 'all', '{}'::jsonb,
       'صلاحية كاملة على النظام: اعتماد أعلى الشرائح، إدارة المستخدمين والإعدادات.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'gm');

-- المشتريات
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'proc_mgr', 'مدير المشتريات', 'المشتريات', 'all',
       '{"can_manage_procurement":true,"can_approve_award":true,"can_issue_po":true,"can_edit":true,"can_create":true,"can_see_finance":true}'::jsonb,
       'إدارة التسعير والمقارنة والتعميد وإصدار أوامر الشراء وطلبات الصرف.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'proc_mgr');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'proc_officer', 'مسؤول مشتريات', 'المشتريات', 'all',
       '{"can_manage_procurement":true,"can_edit":true,"can_create":true}'::jsonb,
       'تنفيذ التسعير وطلب العروض والمقارنة ومتابعة الموردين — دون اعتماد التعميد.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'proc_officer');

-- المالية
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'fin_mgr', 'المدير المالي', 'المالية', 'all',
       '{"can_approve_finance":true,"can_approve_stage":true,"can_disburse":true,"can_see_finance":true}'::jsonb,
       'التحقق المالي المسبق، واعتماد وتنفيذ الصرف (تم الصرف).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'fin_mgr');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'accountant', 'محاسب / رئيس حسابات', 'المالية', 'all',
       '{"can_disburse":true,"can_see_finance":true}'::jsonb,
       'اعتماد وتنفيذ الصرف (تم الصرف) — دون التحقق المالي المسبق للحاجة.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'accountant');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'fin_officer', 'موظف مالية', 'المالية', 'all',
       '{"can_see_finance":true}'::jsonb,
       'اطّلاع كامل على العمليات المالية والمشتريات دون صلاحية قرار.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'fin_officer');

-- الإدارة العامة
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'services_mgr', 'مدير الخدمات المساندة', 'الإدارة العامة', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات الإدارة العامة (المرحلة الأولى) ضمن نطاقه.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'services_mgr');

-- مدراء القطاعات
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'sector_mgr_ops', 'مدير قطاع الصيانة والتشغيل', 'مدراء القطاعات', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات قطاع الصيانة والتشغيل (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'sector_mgr_ops');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'sector_mgr_con', 'مدير قطاع الإنشاءات', 'مدراء القطاعات', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات قطاع الإنشاءات (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'sector_mgr_con');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'sector_mgr_log', 'مدير قطاع النقليات', 'مدراء القطاعات', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات قطاع النقليات (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'sector_mgr_log');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'sector_mgr_infra', 'مدير قطاع البنية التحتية والطرق', 'مدراء القطاعات', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد طلبات قطاع البنية التحتية والطرق (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'sector_mgr_infra');

-- المشاريع والعمليات
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'proj_mgr', 'مدير مشاريع القطاعات', 'المشاريع', 'sector',
       '{"can_approve_stage":true,"can_create":true}'::jsonb,
       'اعتماد ومتابعة طلبات مشاريع قطاعه (المرحلة الأولى).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'proj_mgr');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'proj_coord', 'منسّق مشاريع', 'المشاريع', 'sector',
       '{"can_create":true}'::jsonb,
       'رفع الطلبات ومتابعتها ضمن مشاريع قطاعه.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'proj_coord');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'ops_coord', 'منسّق عمليات', 'العمليات', 'sector',
       '{"can_create":true}'::jsonb,
       'رفع الطلبات ومتابعتها ضمن قطاعه.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'ops_coord');

-- الإشراف والعام
INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'supervisor', 'مشرف قطاع', 'الإشراف', 'sector',
       '{"can_create":true}'::jsonb,
       'رفع الطلبات ومتابعتها ضمن قطاعه — دون اعتماد.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'supervisor');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'employee', 'موظّف', 'عام', 'own',
       '{"can_create":true}'::jsonb,
       'رفع الطلبات ومتابعة طلباته الخاصة.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'employee');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'warehouse', 'أمين مستودع', 'المستودع', 'all',
       '{"can_verify_stock":true}'::jsonb,
       'اطّلاع ومتابعة الاستلام والمخزون (تسجيل الاستلام).', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'warehouse');

INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
SELECT 'qc', 'مراقب جودة', 'الجودة', 'all', '{}'::jsonb,
       'اطّلاع ومتابعة مطابقة المواصفات.', true
WHERE NOT EXISTS (SELECT 1 FROM portal_jobs WHERE key = 'qc');


-- ═══════════════ 3) سلاسل اعتماد القطاعات (buildSectorWorkflows بالأدوار) ═══════════════
-- كل سلسلة أولى ثابتة الشكل: مدير القطاع ← التحقق المالي المسبق ← إذن التسعير.
-- المرحلتان 2 و3 بالأدوار (can_approve_finance / can_manage_procurement) لا
-- بأسماء النموذج التجريبية — قرار المالك الموثّق. SLA لكل مرحلة 24 ساعة.

INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
SELECT 'wf-admin', 'طلبات الإدارة العامة / الموظفين', 10, 'الإدارة العامة', '[
  {"seq":1,"label":"اعتماد مدير الخدمات المساندة","resolver":"dept_manager","sla":24},
  {"seq":2,"label":"التحقق المالي المسبق","resolver":"role","role_key":"can_approve_finance","sla":24},
  {"seq":3,"label":"الإذن ببدء التسعير — مدير المشتريات","resolver":"role","role_key":"can_manage_procurement","sla":24}
]'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = 'wf-admin');

INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
SELECT 'wf-sec-ops', 'قطاع: الصيانة والتشغيل', 20, 'الصيانة والتشغيل', '[
  {"seq":1,"label":"اعتماد مدير قطاع الصيانة والتشغيل","resolver":"dept_manager","sla":24},
  {"seq":2,"label":"التحقق المالي المسبق","resolver":"role","role_key":"can_approve_finance","sla":24},
  {"seq":3,"label":"الإذن ببدء التسعير — مدير المشتريات","resolver":"role","role_key":"can_manage_procurement","sla":24}
]'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = 'wf-sec-ops');

INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
SELECT 'wf-sec-con', 'قطاع: الإنشاءات', 21, 'الإنشاءات', '[
  {"seq":1,"label":"اعتماد مدير قطاع الإنشاءات","resolver":"dept_manager","sla":24},
  {"seq":2,"label":"التحقق المالي المسبق","resolver":"role","role_key":"can_approve_finance","sla":24},
  {"seq":3,"label":"الإذن ببدء التسعير — مدير المشتريات","resolver":"role","role_key":"can_manage_procurement","sla":24}
]'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = 'wf-sec-con');

INSERT INTO portal_workflows (id, name, priority, sector, stages, active)
SELECT 'wf-sec-log', 'قطاع: النقليات', 22, 'النقليات', '[
  {"seq":1,"label":"اعتماد مدير قطاع النقليات","resolver":"dept_manager","sla":24},
  {"seq":2,"label":"التحقق المالي المسبق","resolver":"role","role_key":"can_approve_finance","sla":24},
  {"seq":3,"label":"الإذن ببدء التسعير — مدير المشتريات","resolver":"role","role_key":"can_manage_procurement","sla":24}
]'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM portal_workflows WHERE id = 'wf-sec-log');


-- ═══════════════ 4) DoA: فصل «اعتماد التعميد» عن «إدارة التسعير» ═══════════════
-- في النموذج approveAward صلاحية مستقلة عن manageRfq (مسؤول المشتريات يسعّر
-- ولا يعتمد). الشريحتان الدنيتان كانتا can_manage_procurement — تُحدَّثان إلى
-- can_approve_award (يحملها مدير المشتريات لا مسؤول المشتريات). تحديث موثّق
-- ومتعمّد؛ الشريحتان العليتان (can_manage_users = المدير العام) بلا تغيير.

UPDATE portal_doa SET award_role_key = 'can_approve_award'
WHERE award_role_key = 'can_manage_procurement'
  AND label IN ('أقل من 500', '500 – 100,000');


-- ═══════════════ 5) RPCs نموذج الوظائف ═══════════════

-- إسناد وظيفة لمستخدم: ينسخ صلاحيات الوظيفة (الإرث) ويضبط الدور.
-- gm = أدمن (كما النموذج: admin=(job==='gm')). حماية «آخر أدمن»: لا يُسمح
-- بإسناد وظيفة غير gm لأدمن إن كان الأدمن النشط الوحيد.
CREATE OR REPLACE FUNCTION portal_apply_job(p_username text, p_job_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_job portal_jobs%ROWTYPE;
  v_user portal_users%ROWTYPE;
  v_new_role text;
  v_other_admins int;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'إسناد الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  SELECT * INTO v_job FROM portal_jobs WHERE key = p_job_key AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'وظيفة غير موجودة أو غير مفعّلة'; END IF;
  SELECT * INTO v_user FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;

  v_new_role := CASE WHEN p_job_key = 'gm' THEN 'admin' ELSE 'user' END;
  IF v_user.role = 'admin' AND v_new_role <> 'admin' THEN
    SELECT count(*) INTO v_other_admins FROM portal_users
      WHERE role = 'admin' AND active AND username <> p_username;
    IF v_other_admins = 0 THEN
      RAISE EXCEPTION 'لا يمكن تجريد آخر أدمن نشط من صلاحياته — أسند gm لغيره أولاً';
    END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET job_key = p_job_key, permissions = v_job.permissions, role = v_new_role
    WHERE username = p_username;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_assigned', v_me, 'portal',
    jsonb_build_object('user', p_username, 'job', p_job_key));
  RETURN jsonb_build_object('ok', true, 'job', p_job_key, 'role', v_new_role);
END $fn$;

-- حفظ/تعديل وظيفة: التعديل يسري فوراً على كل حامليها (سيناريو 6-20).
CREATE OR REPLACE FUNCTION portal_save_job(p_key text, p_title text, p_category text,
    p_scope text, p_permissions jsonb, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_holders int;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'تعديل الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  IF coalesce(trim(p_key),'') = '' OR coalesce(trim(p_title),'') = '' THEN
    RAISE EXCEPTION 'مفتاح الوظيفة واسمها مطلوبان';
  END IF;
  IF p_scope NOT IN ('own','sector','all') THEN RAISE EXCEPTION 'نطاق غير صالح (own/sector/all)'; END IF;
  IF p_key = 'gm' AND NOT (p_permissions = '{}'::jsonb OR p_permissions IS NULL) THEN
    -- gm يستمد كل شيء من دور admin — صلاحياته لا تُحرَّر (حماية من إضعافها بالخطأ)
    RAISE EXCEPTION 'وظيفة المدير العام محمية — صلاحياتها من دور الأدمن مباشرة';
  END IF;

  INSERT INTO portal_jobs (key, title, category, scope, permissions, description, active)
  VALUES (p_key, trim(p_title), p_category, p_scope, coalesce(p_permissions,'{}'::jsonb), p_description, true)
  ON CONFLICT (key) DO UPDATE SET title = EXCLUDED.title, category = EXCLUDED.category,
    scope = EXCLUDED.scope, permissions = EXCLUDED.permissions, description = EXCLUDED.description;

  -- سريان فوري على الحاملين (لا يمسّ دورهم — gm فقط من يمنح admin)
  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_users SET permissions = coalesce(p_permissions,'{}'::jsonb) WHERE job_key = p_key;
  GET DIAGNOSTICS v_holders = ROW_COUNT;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'job_saved', v_me, 'portal',
    jsonb_build_object('job', p_key, 'holders_updated', v_holders));
  RETURN jsonb_build_object('ok', true, 'holders_updated', v_holders);
END $fn$;

-- حذف وظيفة: محمي بالدالة — لا حذف gm، ولا وظيفة يحملها موظفون.
CREATE OR REPLACE FUNCTION portal_delete_job(p_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_holders int;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_users') OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'حذف الوظائف يتطلّب صلاحية «إدارة المستخدمين»';
  END IF;
  IF p_key = 'gm' THEN RAISE EXCEPTION 'لا تُحذف وظيفة المدير العام'; END IF;
  SELECT count(*) INTO v_holders FROM portal_users WHERE job_key = p_key;
  IF v_holders > 0 THEN RAISE EXCEPTION 'لا يمكن حذف وظيفة يحملها % موظف — انقلهم أولاً', v_holders; END IF;
  DELETE FROM portal_jobs WHERE key = p_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'الوظيفة غير موجودة'; END IF;
  PERFORM portal_audit_write(NULL, 'job_deleted', v_me, 'portal', jsonb_build_object('job', p_key));
  RETURN jsonb_build_object('ok', true);
END $fn$;

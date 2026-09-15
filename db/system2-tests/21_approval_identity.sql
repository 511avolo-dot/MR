\set ON_ERROR_STOP on

-- ═══════════════════════════════════════════════════════════════════════════
-- AI1–AI9 — هويّة المعتمِدين · بقاء تاريخ القرارات · تاريخ التوريد الماضي
--   (db/system2-approval-identity-and-history.sql)
--
-- ⚠️ لماذا هذا الملفّ: الهجرة شُحنت في PR #106 ودخلت الإنتاج، لكنها لم تكن في
-- `run.sh` — فكانت الحزمة المحلّية تختبر **التعريفات القديمة** التي حلّت محلّها.
-- بيانات التجهيز هنا إدارية موثوقة؛ حارس الإنتاج يرفضها عمداً للمستخدم العاديّ.
-- ═══════════════════════════════════════════════════════════════════════════
SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

DO $approval_identity$
DECLARE
  r jsonb; v_id text; v_rev integer; n integer; v_txt text; blocked boolean := false;
  v_project text := (SELECT x->>'name' FROM proc_settings s,
                     jsonb_array_elements(s.value->'projects') x
                     WHERE s.key='projects_registry' LIMIT 1);
BEGIN
  -- AI1: عمودا الهويّة والإصدار موجودان على صفوف الاعتماد
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns
                WHERE table_name='proc_pr_approvals' AND column_name='approver_name') THEN
    RAISE EXCEPTION 'AI1 عمود approver_name مفقود';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns
                WHERE table_name='proc_pr_approvals' AND column_name='revision') THEN
    RAISE EXCEPTION 'AI1 عمود revision مفقود على صفوف الاعتماد';
  END IF;

  -- AI2: المفتاح الفريد واعٍ بالإصدار — وإلّا استحال بقاء تاريخ القرارات
  IF NOT EXISTS(
    SELECT 1 FROM pg_indexes WHERE tablename='proc_pr_approvals'
      AND indexname='uq_proc_pr_approval_stage' AND indexdef LIKE '%revision%') THEN
    RAISE EXCEPTION 'AI2 المفتاح الفريد ليس واعياً بالإصدار';
  END IF;

  -- ① الطالب يرفع الطلب
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    jsonb_build_object('title','طلب تاريخ القرارات','department_id','DEP-MAINT','project',v_project),
    '[{"description":"قطعة غيار","requested_qty":5,"unit":"حبة"}]'::jsonb, true, NULL);
  v_id := r->>'id';
  IF (r->>'revision')::integer <> 1 THEN RAISE EXCEPTION 'AI3 الإصدار الأوّل ليس 1'; END IF;

  -- AI3: الاسم المعروض مُثبَّت وقت الإسناد (الطالب المُنطَّق لا يقرأ جدول المستخدمين)
  SELECT approver_name INTO v_txt FROM proc_pr_approvals WHERE pr_id=v_id AND seq=1;
  IF coalesce(v_txt,'')<>'مدير الصيانة' THEN
    RAISE EXCEPTION 'AI3 اسم المعتمِد لم يُثبَّت عند الإسناد (%)', v_txt;
  END IF;

  -- ② الإعادة للتعديل
  PERFORM set_config('request.jwt.claims','{"email":"maintmgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM pr_decide(v_id,'return','الكميات تحتاج مراجعة');
  IF (SELECT status FROM proc_purchase_requests WHERE id=v_id)<>'returned' THEN
    RAISE EXCEPTION 'AI4 الطلب لم يعُد للطالب';
  END IF;

  -- AI5: اسم المقرِّر الفعليّ مُثبَّت مع القرار
  SELECT approver_name INTO v_txt FROM proc_pr_approvals
   WHERE pr_id=v_id AND revision=1 AND seq=1;
  IF coalesce(v_txt,'')<>'مدير الصيانة' THEN
    RAISE EXCEPTION 'AI5 اسم المقرِّر لم يُثبَّت مع القرار (%)', v_txt;
  END IF;

  -- ③ الطالب يُعدّل ويُعيد الإرسال
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    jsonb_build_object('title','طلب تاريخ القرارات — معدَّل','department_id','DEP-MAINT','project',v_project),
    '[{"description":"قطعة غيار","requested_qty":50,"unit":"حبة"}]'::jsonb, true, v_id);
  v_rev := (r->>'revision')::integer;
  IF v_rev <> 2 THEN RAISE EXCEPTION 'AI6 الإصدار لم يرتفع بعد إعادة الإرسال (%)', v_rev; END IF;

  -- AI7: صفّ الإعادة **باقٍ** — وهو ما يَعِد به محضر الطلب المطبوع
  SELECT count(*) INTO n FROM proc_pr_approvals
   WHERE pr_id=v_id AND revision=1 AND seq=1 AND decision='returned';
  IF n<>1 THEN RAISE EXCEPTION 'AI7 صفّ الإعادة حُذِف عند إعادة الإرسال'; END IF;

  -- AI8: ومرحلتا الإصدار الجديد معلّقتان بلا تعارض مفتاح
  SELECT count(*) INTO n FROM proc_pr_approvals
   WHERE pr_id=v_id AND revision=2 AND decision='pending';
  IF n<>2 THEN RAISE EXCEPTION 'AI8 مرحلتا الإصدار الجديد ليستا معلّقتين (%)', n; END IF;

  -- AI9: تاريخ توريد ماضٍ مرفوض على الخادم (سمة `min` تُتجاوَز بأدوات المطوّر)
  BEGIN
    PERFORM pr_save_request(
      jsonb_build_object('title','طلب بتاريخ ماضٍ','department_id','DEP-MAINT','project',v_project,
                         'needed_by',(current_date - 1)::text),
      '[{"description":"قطعة","requested_qty":1,"unit":"حبة"}]'::jsonb, true, NULL);
  EXCEPTION WHEN OTHERS THEN blocked := true;
  END;
  IF NOT blocked THEN RAISE EXCEPTION 'AI9 قُبِل تاريخ توريد ماضٍ'; END IF;

  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  RAISE NOTICE 'AI1–AI9 ✓ هويّة المعتمِدين وتاريخ القرارات وتاريخ التوريد';
END
$approval_identity$;

-- ════════════════════════════════════════════════════════════════════════════
--  WC0–WC10 — «مَن يملك المرحلة» و«مَن قرّر»: تأكيدات **سلوكية** تستدعي الدوال
--  فعلاً بهويّة مُنتحَلة، لا فحص نصّ.
--
--  ⚠️ العلّة المحروسة (بلاغ المالك 2026-09-16 بلقطة): اعتماد بوّابة التسعير كان
--     يكتب `proc_status='in_progress'` و`proc_started_by=<المعتمِد>` — فتُنسَب
--     مرحلة «التسعير والمقارنة» لمن أذِن لا لمن عمل، **ويُستهلَك انتقال
--     `received → in_progress`** فيتعذّر على المشتريات تسجيل بدء العمل أصلاً.
--
--  ⚠️⚠️ ومنهجيّاً: المُنصِّب نفسه صُحِّح، فلا تُنتِج البيئة المحلّية الحالةَ
--     المعطوبة تلقائيّاً — ولو اكتفينا بذلك لكانت تأكيدات المداواة **فراغيّة**.
--     لذا يُعيد هذا الملفّ **بناء حالة الإنتاج يدويّاً** (صفٌّ مختوم آليّاً)،
--     يُثبت أنّها معطوبة (WC5)، ثمّ يُشغّل الهجرة بـ`\i` ويتحقّق أنّها هي التي
--     داوتها (WC6–WC8).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

INSERT INTO proc_departments(id,name_ar,sector,manager_user,active)
VALUES ('DEP-WC','إدارة الوضوح','الصيانة والتشغيل','wc_mgr',true)
ON CONFLICT (id) DO UPDATE SET active=true, sector=EXCLUDED.sector, manager_user=EXCLUDED.manager_user;

INSERT INTO proc_users(username,email,display_name,role,active,permissions,scope_sectors,
                       pr_profile_key,pr_permission_overrides,department_id,pr_department_ids)
VALUES
 ('wc_req','wc_req@aldeyabi.com','طالب الوضوح','user',true,
  '{"can_comment":true,"can_upload_docs":true}'::jsonb,'["الصيانة والتشغيل"]'::jsonb,
  'requester','{}'::jsonb,'DEP-WC',ARRAY['DEP-WC']),
 ('wc_mgr','wc_mgr@aldeyabi.com','م.مدير الصيانة','user',true,'{}'::jsonb,NULL,
  'maintenance_manager','{}'::jsonb,'DEP-WC',ARRAY['DEP-WC']),
 ('wc_head','wc_head@aldeyabi.com','رئيس المشتريات','user',true,
  '{"can_manage_rfq":true}'::jsonb,NULL,'procurement_manager','{}'::jsonb,NULL,ARRAY['DEP-WC']),
 ('wc_buyer','wc_buyer@aldeyabi.com','مشترٍ منفّذ','user',true,
  '{"can_manage_rfq":true}'::jsonb,NULL,'procurement_officer','{}'::jsonb,NULL,ARRAY['DEP-WC'])
ON CONFLICT (username) DO UPDATE
  SET display_name=EXCLUDED.display_name, permissions=EXCLUDED.permissions,
      scope_sectors=EXCLUDED.scope_sectors, pr_profile_key=EXCLUDED.pr_profile_key,
      pr_permission_overrides='{}'::jsonb, department_id=EXCLUDED.department_id,
      pr_department_ids=EXCLUDED.pr_department_ids, active=true;

INSERT INTO proc_settings(key,value)
VALUES ('projects_registry','{"projects":[{"name":"مشروع الوضوح","aliases":[],"active":true}]}'::jsonb)
ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value;

CREATE TEMP TABLE _wc_ctx (k text primary key, v text);

DO $t$
DECLARE v_id text; v_ps text; v_by text; v_nm text; v_n int;
BEGIN
  -- ═══ بذرة: طلب يمرّ ببوّابتي الاعتماد ═══
  PERFORM set_config('request.jwt.claims','{"email":"wc_req@aldeyabi.com"}',true);
  v_id := (pr_save_request(
    jsonb_build_object('title','طلب الوضوح','department_id','DEP-WC',
                       'project','مشروع الوضوح','priority','عادي','justification','اختبار'),
    jsonb_build_array(jsonb_build_object('description','بند','unit','حبة','requested_qty',1)),
    true, NULL))->>'id';
  INSERT INTO _wc_ctx VALUES ('pr', v_id);

  /* ⚠️ الحزمة تتشارك قاعدة واحدة مع ملفّات سابقة أنشأت مستخدمي مشتريات، فقد
     يحلّ `pr_resolve_stage_approver` المرحلةَ لأحدهم. نُثبّت المعتمِدَين هنا
     كي يختبر التأكيدُ **مسار الإذن** لا مصادفةَ الإسناد. */
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  UPDATE proc_pr_approvals SET approver='wc_mgr',  approver_name='م.مدير الصيانة'
   WHERE pr_id=v_id AND seq=1 AND decision='pending';
  UPDATE proc_pr_approvals SET approver='wc_head', approver_name='رئيس المشتريات'
   WHERE pr_id=v_id AND seq=2 AND decision='pending';

  PERFORM set_config('request.jwt.claims','{"email":"wc_mgr@aldeyabi.com"}',true);
  PERFORM pr_decide(v_id,'approve','موافق');
  PERFORM set_config('request.jwt.claims','{"email":"wc_head@aldeyabi.com"}',true);
  PERFORM pr_decide(v_id,'approve','إذن بالتسعير');

  -- ═══ WC1: الإذن بالتسعير يُسلّم الطلب ولا يدّعي بدء العمل ═══
  SELECT proc_status, proc_started_by INTO v_ps, v_by
    FROM proc_purchase_requests WHERE id=v_id;
  IF v_ps <> 'received' OR v_by IS NOT NULL THEN
    RAISE EXCEPTION 'WC1 فشل: الحالة % والمُنسَب إليه % (المتوقَّع received وبلا اسم)', v_ps, v_by;
  END IF;
  RAISE NOTICE 'WC1 ✅ بعد الإذن: % · بلا نسبة عمل لأحد', v_ps;

  -- ═══ WC2: ومَن أذِن يبقى مسجَّلاً كمُجيز لا كمنفّذ ═══
  SELECT pricing_authorized_by INTO v_by FROM proc_purchase_requests WHERE id=v_id;
  IF lower(coalesce(v_by,'')) <> 'wc_head' THEN
    RAISE EXCEPTION 'WC2 فشل: المُجيز % لا wc_head', v_by;
  END IF;
  RAISE NOTICE 'WC2 ✅ المُجيز محفوظ (%) منفصلاً عن المنفّذ', v_by;

  -- ═══ WC3: المشتريات تستطيع الآن تسجيل بدء العمل (كان الانتقال مستهلَكاً) ═══
  PERFORM set_config('request.jwt.claims','{"email":"wc_buyer@aldeyabi.com"}',true);
  PERFORM pr_proc_stage(v_id,'in_progress');
  SELECT proc_status, proc_started_by INTO v_ps, v_by FROM proc_purchase_requests WHERE id=v_id;
  IF v_ps <> 'in_progress' OR lower(coalesce(v_by,'')) <> 'wc_buyer' THEN
    RAISE EXCEPTION 'WC3 فشل: % / % (المتوقَّع in_progress / wc_buyer)', v_ps, v_by;
  END IF;
  RAISE NOTICE 'WC3 ✅ بدء العمل يُنسَب لمن بدأه فعلاً (%)', v_by;

  -- ═══ WC4: اسم الفاعل يُخزَّن عربيّاً مع صفّ التدقيق (لا اسم دخول) ═══
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  INSERT INTO proc_pr_audit(pr_id,event,actor,channel,detail)
  VALUES(v_id,'stage_approved','wc_mgr','portal','{}'::jsonb);
  SELECT actor_name INTO v_nm FROM proc_pr_audit
   WHERE pr_id=v_id AND actor='wc_mgr' ORDER BY id DESC LIMIT 1;
  IF coalesce(v_nm,'') <> 'م.مدير الصيانة' THEN
    RAISE EXCEPTION 'WC4 فشل: اسم الفاعل % لا «م.مدير الصيانة»', v_nm;
  END IF;
  RAISE NOTICE 'WC4 ✅ المُشغِّل يملأ اسم الفاعل (%)', v_nm;

  -- ═══ WC5: فاعل مجهول لا يُفرَّغ اسمه (يسقط لاسم الدخول لا لـNULL) ═══
  INSERT INTO proc_pr_audit(pr_id,event,actor,channel,detail)
  VALUES(v_id,'submitted','ghost_user','portal','{}'::jsonb);
  SELECT actor_name INTO v_nm FROM proc_pr_audit
   WHERE pr_id=v_id AND actor='ghost_user' ORDER BY id DESC LIMIT 1;
  IF coalesce(v_nm,'') <> 'ghost_user' THEN
    RAISE EXCEPTION 'WC5 فشل: اسم الفاعل المجهول %', coalesce(v_nm,'(فارغ)');
  END IF;
  RAISE NOTICE 'WC5 ✅ المجهول يسقط لاسم دخوله لا لفراغ';
END $t$;

-- ═══════ إعادة بناء حالة الإنتاج: صفوف مختومة آليّاً بالاعتماد ═══════
--  (أ) `wc_auto`  — in_progress مختوم بالمُجيز نفسه وبنفس اللحظة ⇒ يجب أن يُداوى.
--  (ب) `wc_real`  — in_progress بدأه شخص آخر فعلاً       ⇒ لا يُمَسّ.
--  (ج) `wc_moved` — تجاوز المرحلة (rfq_issued)            ⇒ لا يُمَسّ.
DO $seed_prod$
DECLARE v_base text; v_t timestamptz := now();
BEGIN
  SELECT v INTO v_base FROM _wc_ctx WHERE k='pr';
  INSERT INTO proc_purchase_requests(id,request_no,title,department_id,requester,requester_name,
                                     status,workflow_state,proc_status,
                                     pricing_authorized_by,pricing_authorized_at,
                                     proc_started_by,proc_started_at,revision)
  VALUES
   ('WC-AUTO','WC-AUTO','مختوم آليّاً','DEP-WC','wc_req','طالب الوضوح',
    'approved','pricing','in_progress','wc_head',v_t,'wc_head',v_t,1),
   ('WC-REAL','WC-REAL','بدأه منفّذ فعلاً','DEP-WC','wc_req','طالب الوضوح',
    'approved','pricing','in_progress','wc_head',v_t,'wc_buyer',v_t + interval '5 min',1),
   ('WC-MOVED','WC-MOVED','تجاوز المرحلة','DEP-WC','wc_req','طالب الوضوح',
    'rfq_issued','pricing','rfq_issued','wc_head',v_t,'wc_head',v_t,1),
   /* (د) `WC-SAME` — **نفس الشخص أذِن ثمّ بدأ العمل فعلاً لاحقاً**. اسمه يطابق
      المُجيز لكنّ الطابع الزمنيّ مختلف ⇒ عملٌ حقيقيّ لا يُمَسّ. وهو ما يجعل
      شرط الطابع الزمنيّ ضرورةً لا زينة. */
   ('WC-SAME','WC-SAME','أذِن ثمّ بدأ بنفسه','DEP-WC','wc_req','طالب الوضوح',
    'approved','pricing','in_progress','wc_head',v_t,'wc_head',v_t + interval '20 min',1)
  ON CONFLICT (id) DO UPDATE SET proc_status=EXCLUDED.proc_status,
    proc_started_by=EXCLUDED.proc_started_by, proc_started_at=EXCLUDED.proc_started_at,
    pricing_authorized_by=EXCLUDED.pricing_authorized_by, pricing_authorized_at=EXCLUDED.pricing_authorized_at;

  -- شرط لازم: الحالة المعطوبة موجودة فعلاً قبل الهجرة، وإلّا فالتأكيدات فراغيّة
  IF (SELECT count(*) FROM proc_purchase_requests
       WHERE id='WC-AUTO' AND proc_status='in_progress' AND proc_started_by='wc_head') <> 1 THEN
    RAISE EXCEPTION 'WC6 فشل: لم يُعَد بناء الحالة المعطوبة — ما يليها فراغيّ';
  END IF;
  RAISE NOTICE 'WC6 ✅ أُعيد إنتاج الحالة المعطوبة (مختوم بالمُجيز)';
END $seed_prod$;

-- ═══════ تشغيل الهجرة التصحيحية على الحالة المُعاد بناؤها ═══════
\i db/system2-request-workspace-clarity.sql

DO $t2$
DECLARE v_ps text; v_by text; v_n int;
BEGIN
  -- ═══ WC7: المختوم آليّاً عاد إلى «وصل للمشتريات» بلا نسبة ═══
  SELECT proc_status, proc_started_by INTO v_ps, v_by FROM proc_purchase_requests WHERE id='WC-AUTO';
  IF v_ps <> 'received' OR v_by IS NOT NULL THEN
    RAISE EXCEPTION 'WC7 فشل: WC-AUTO بقي % / %', v_ps, coalesce(v_by,'—');
  END IF;
  RAISE NOTICE 'WC7 ✅ المختوم آليّاً أُعيد إلى received بلا نسبة عمل';

  -- ═══ WC8: ولا تُمَسّ الصفوف ذات العمل الحقيقيّ ولا ما تجاوز المرحلة ═══
  SELECT proc_status, proc_started_by INTO v_ps, v_by FROM proc_purchase_requests WHERE id='WC-REAL';
  IF v_ps <> 'in_progress' OR lower(coalesce(v_by,'')) <> 'wc_buyer' THEN
    RAISE EXCEPTION 'WC8 فشل: أُتلف عملٌ حقيقيّ (% / %)', v_ps, coalesce(v_by,'—');
  END IF;
  SELECT proc_status INTO v_ps FROM proc_purchase_requests WHERE id='WC-MOVED';
  IF v_ps <> 'rfq_issued' THEN
    RAISE EXCEPTION 'WC8 فشل: مُسَّ ما تجاوز المرحلة (%)', v_ps;
  END IF;
  /* نفس الشخص أذِن ثمّ بدأ لاحقاً — يفرّقه **الطابع الزمنيّ** وحده. */
  SELECT proc_status, proc_started_by INTO v_ps, v_by FROM proc_purchase_requests WHERE id='WC-SAME';
  IF v_ps <> 'in_progress' OR lower(coalesce(v_by,'')) <> 'wc_head' THEN
    RAISE EXCEPTION 'WC8 فشل: أُتلف عملُ من أذِن ثمّ بدأ بنفسه (% / %)', v_ps, coalesce(v_by,'—');
  END IF;
  RAISE NOTICE 'WC8 ✅ العمل الحقيقيّ (ولو من المُجيز نفسه) وما تجاوز المرحلة سليمان';

  -- ═══ WC9: المداواة تُعلِن نفسها في السجلّ ولا تحذف صفّاً ═══
  SELECT count(*) INTO v_n FROM proc_pr_audit
   WHERE pr_id='WC-AUTO' AND event='proc_reset_to_received';
  IF v_n <> 1 THEN RAISE EXCEPTION 'WC9 فشل: صفوف التصحيح % لا 1', v_n; END IF;
  RAISE NOTICE 'WC9 ✅ التصحيح مُعلَن في سجلّ الطلب';

  -- ═══ WC10: الردم ملأ أسماء الصفوف القديمة ═══
  SELECT count(*) INTO v_n FROM proc_pr_audit
   WHERE nullif(btrim(coalesce(actor_name,'')),'') IS NULL AND actor IS NOT NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'WC10 فشل: % صفّ تدقيق بلا اسم فاعل', v_n; END IF;
  RAISE NOTICE 'WC10 ✅ لا صفّ تدقيق بلا اسم فاعل';

  RAISE NOTICE 'WC1–WC10 نجحت';
END $t2$;

-- تنظيف صفوف البذرة الاصطناعية كي لا تُلوّث تأكيدات لاحقة
DELETE FROM proc_purchase_requests WHERE id IN ('WC-AUTO','WC-REAL','WC-MOVED','WC-SAME');

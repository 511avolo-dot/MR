-- ════════════════════════════════════════════════════════════════════════════
--  تأكيدات دورة الطلب — db/system2-request-flow.sql
-- ----------------------------------------------------------------------------
--  تُشغَّل بعد 00_stub.sql + system2-staff-scope.sql + 10_scope.sql ثم الترقية.
--  ⚠️ RLS **فعليّة**: كل فحص بـ`SET LOCAL ROLE authenticated` + هوية JWT.
--  كل تأكيد `RAISE EXCEPTION` عند الفشل، والملف بـ`ON_ERROR_STOP=1`.
-- ════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- ═══ بذور خاصّة بهذا الملف (لا تمسّ بذور 10_scope) ═══
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);

INSERT INTO proc_users (username, display_name, email, role, permissions, active, scope_sectors) VALUES
  -- موظّف مشتريات: يعالج الطلبات، غير مُنطَّق (يرى الكل) — كواقع الإنتاج.
  ('proc1','فريق المشتريات','proc1@aldeyabi.com','user',
   '{"can_manage_rfq":true}'::jsonb, true, NULL)
ON CONFLICT (username) DO NOTHING;

INSERT INTO proc_purchase_requests (id, title, sector, requester, status) VALUES
  ('PR-F1','طلب صالح المعتمَد','الصيانة والتشغيل','saleh','approved'),
  ('PR-F2','طلب صالح تحت الاعتماد','الصيانة والتشغيل','saleh','in_review')
ON CONFLICT (id) DO NOTHING;

SELECT set_config('request.jwt.claims', '', false);

DO $$
DECLARE n int; ok boolean; v_st text; v_by text; v_at timestamptz;
BEGIN
  -- ═══ FL1 — لا معالجة قبل اكتمال سلسلة الاعتماد ═══
  BEGIN
    PERFORM t_as('proc1@aldeyabi.com');
    SET LOCAL ROLE authenticated;
    BEGIN PERFORM pr_proc_stage('PR-F2','in_progress'); ok := false;
    EXCEPTION WHEN OTHERS THEN ok := true; END;
    RESET ROLE;
    IF NOT ok THEN RAISE EXCEPTION 'FL1 فشل: عولج طلب لم يُعتمَد بعد'; END IF;
  END;

  -- ═══ FL2 — المعالجة صلاحية مشتريات: الطالب نفسه لا يستطيعها ═══
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_proc_stage('PR-F1','in_progress'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'FL2 فشل: مقدّم الطلب عالجه بنفسه'; END IF;

  -- ═══ FL3 — المشتريات تبدأ العمل: يُسجَّل من بدأ ومتى ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  PERFORM pr_proc_stage('PR-F1','in_progress');
  RESET ROLE;
  SELECT proc_status, proc_started_by, proc_started_at INTO v_st, v_by, v_at
    FROM proc_purchase_requests WHERE id='PR-F1';
  IF v_st <> 'in_progress' OR v_by <> 'proc1' OR v_at IS NULL THEN
    RAISE EXCEPTION 'FL3 فشل: المرحلة/من بدأ/متى = %/%/%', v_st, v_by, v_at;
  END IF;

  -- ═══ FL4 — لا رجوع لمرحلة سابقة ولا تكرار (لا يُمحى أثر من عمل عليه) ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_proc_stage('PR-F1','in_progress'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'FL4 فشل: أُعيدت المرحلة نفسها فطُمِس أثر من بدأ'; END IF;

  -- ═══ FL5 — التقدّم لجمع العروض يُسجَّل، ثم لا رجوع ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  PERFORM pr_proc_stage('PR-F1','quotes_collected');
  RESET ROLE;
  SELECT proc_status, quotes_collected_by INTO v_st, v_by
    FROM proc_purchase_requests WHERE id='PR-F1';
  IF v_st <> 'quotes_collected' OR v_by <> 'proc1' THEN
    RAISE EXCEPTION 'FL5 فشل: %/%', v_st, v_by;
  END IF;
  -- و«من بدأ العمل» لم يُمحَ بالتقدّم (الطالب يسأل عنه)
  SELECT proc_started_by INTO v_by FROM proc_purchase_requests WHERE id='PR-F1';
  IF v_by <> 'proc1' THEN RAISE EXCEPTION 'FL5 فشل: مُحي من بدأ العمل عند التقدّم'; END IF;

  -- ═══ FL6 — الاستفهام لا يُغيّر حالة الطلب ولا مرحلته ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  PERFORM pr_post_message('PR-F1','هل الكمية 10 أم 100؟','question');
  RESET ROLE;
  SELECT status || '|' || coalesce(proc_status,'') INTO v_st
    FROM proc_purchase_requests WHERE id='PR-F1';
  IF v_st <> 'approved|quotes_collected' THEN
    RAISE EXCEPTION 'FL6 فشل: الاستفهام غيّر حالة الطلب (%)', v_st;
  END IF;

  -- ═══ FL7 — الطالب يجيب على طلبه ═══
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  PERFORM pr_post_message('PR-F1','100','answer');
  SELECT count(*) INTO n FROM proc_pr_messages WHERE pr_id='PR-F1';
  RESET ROLE;
  IF n <> 2 THEN RAISE EXCEPTION 'FL7 فشل: رسائل الطلب = % (المتوقّع 2)', n; END IF;

  -- ═══ FL8 — طلب خارج نطاق الموظّف: لا يُستفهَم فيه ولا تُقرأ رسائله ═══
  -- (nasser مُنطَّق على «الصيانة والتشغيل»، و PR-2 قطاعه «الإنشاءات»)
  PERFORM t_as('nasser@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_post_message('PR-2','رسالة','message'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'FL8 فشل: كُتبت رسالة على طلب خارج النطاق'; END IF;

  -- ═══ FL9 — رسالة فارغة أو طويلة مرفوضة ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_post_message('PR-F1','   ','question'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RESET ROLE; RAISE EXCEPTION 'FL9 فشل: قُبلت رسالة فارغة'; END IF;
  BEGIN PERFORM pr_post_message('PR-F1', repeat('ب', 4001),'question'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'FL9 فشل: قُبلت رسالة تتجاوز الحدّ'; END IF;

  -- ═══ FL10 — لا كتابة مباشرة في المحادثة (لا انتحال مؤلِّف) ═══
  -- قفلان: لا امتياز INSERT على الجدول، ولا سياسة INSERT — والكتابة عبر RPC وحدها.
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO proc_pr_messages (pr_id, author, kind, body)
    VALUES ('PR-F1','proc1','question','رسالة منتحَلة');
    ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'FL10 فشل: أُدرجت رسالة بمؤلِّف منتحَل'; END IF;

  -- ═══ FL11 — القوالب: صاحبها يكتب، وزميل القطاع يقرأ ═══
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  INSERT INTO proc_pr_templates (id, name, owner, sector, items)
  VALUES ('TPL-T1','الشهريّ لبرج الشمال','saleh','الصيانة والتشغيل',
          '[{"description":"فلتر","requested_qty":10}]'::jsonb);
  RESET ROLE;
  PERFORM t_as('nasser@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_pr_templates WHERE id='TPL-T1';
  RESET ROLE;
  IF n <> 1 THEN RAISE EXCEPTION 'FL11 فشل: زميل القطاع لا يرى قالب فريقه'; END IF;

  -- ═══ FL12 — ولا يعدّله ولا يحذفه (صاحبه وحده) ═══
  PERFORM t_as('nasser@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  UPDATE proc_pr_templates SET name='مُختطَف' WHERE id='TPL-T1';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RESET ROLE; RAISE EXCEPTION 'FL12 فشل: عدّل زميلٌ قالب غيره'; END IF;
  DELETE FROM proc_pr_templates WHERE id='TPL-T1';
  GET DIAGNOSTICS n = ROW_COUNT;
  RESET ROLE;
  IF n <> 0 THEN RAISE EXCEPTION 'FL12 فشل: حذف زميلٌ قالب غيره'; END IF;

  -- ═══ FL13 — ولا ينتحل ملكيّته عند الإنشاء ═══
  PERFORM t_as('nasser@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO proc_pr_templates (id, name, owner, sector, items)
    VALUES ('TPL-T2','قالب باسم غيري','saleh','الصيانة والتشغيل','[]'::jsonb);
    ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'FL13 فشل: أُنشئ قالب باسم مستخدم آخر'; END IF;

  -- ═══ FL14 — قالب قطاع آخر لا يراه المُنطَّق ═══
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', false);
  INSERT INTO proc_pr_templates (id, name, owner, sector, items)
  VALUES ('TPL-T3','قالب الإنشاءات','Mostafa','الإنشاءات','[]'::jsonb)
  ON CONFLICT (id) DO NOTHING;
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_pr_templates WHERE id='TPL-T3';
  RESET ROLE;
  IF n <> 0 THEN RAISE EXCEPTION 'FL14 فشل: رأى المُنطَّق قالب قطاع ليس قطاعه'; END IF;

  -- ═══ FL15 — عدم انحدار: غير المُنطَّق يرى كل القوالب ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_pr_templates;
  RESET ROLE;
  IF n < 2 THEN RAISE EXCEPTION 'FL15 فشل: المشتريات ترى % قالباً فقط', n; END IF;

  -- ═══ FL16 — قفل الامتياز على المحادثة قائم فعلاً (لا يُفترَض) ═══
  -- الكعب يمنح ALL افتراضياً كـSupabase، فهذا التأكيد يفشل إن نسيت الهجرة السحب.
  IF has_table_privilege('authenticated','proc_pr_messages','INSERT')
  OR has_table_privilege('authenticated','proc_pr_messages','UPDATE')
  OR has_table_privilege('authenticated','proc_pr_messages','DELETE') THEN
    RAISE EXCEPTION 'FL16 فشل: امتياز كتابة مباشرة على المحادثة لم يُسحَب';
  END IF;
  IF NOT has_table_privilege('authenticated','proc_pr_messages','SELECT') THEN
    RAISE EXCEPTION 'FL16 فشل: قراءة المحادثة مسحوبة (تكسر عرض الحوار)';
  END IF;
  IF has_table_privilege('anon','proc_pr_templates','SELECT')
  OR has_table_privilege('anon','proc_pr_messages','SELECT') THEN
    RAISE EXCEPTION 'FL16 فشل: anon يقرأ جداول الطلبات';
  END IF;
  -- والقوالب تبقى كاملة الامتياز (بيانات المستخدم يكتبها بنفسه، وRLS تحكمها)
  IF NOT has_table_privilege('authenticated','proc_pr_templates','INSERT') THEN
    RAISE EXCEPTION 'FL16 فشل: الموظّف لا يستطيع حفظ قالب';
  END IF;

  PERFORM set_config('request.jwt.claims', '', false);
  RAISE NOTICE '✓ FL1–FL16 — كل تأكيدات دورة الطلب ناجحة';
END $$;

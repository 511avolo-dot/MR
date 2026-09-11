-- ════════════════════════════════════════════════════════════════════════════
--  تأكيدات نموذج المتابعة — db/system2-request-tracking.sql
-- ----------------------------------------------------------------------------
--  «متابعة وليس وورك فلو» (قرار المالك): لا سلسلة اعتماد؛ الطلب يصل المشتريات
--  مباشرةً بسند موقَّع، ويُربط بأمر شراء **موجود فعلاً**، فيراه صاحبه.
--  RLS فعليّة: كل فحص بـ`SET LOCAL ROLE authenticated` + هوية JWT.
-- ════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);
INSERT INTO proc_purchase_requests (id, title, sector, requester, status) VALUES
  ('PR-T1','طلب متابعة','الصيانة والتشغيل','saleh','submitted'),
  ('PR-T2','مسودّة','الصيانة والتشغيل','saleh','draft')
ON CONFLICT (id) DO NOTHING;
SELECT set_config('request.jwt.claims', '', false);

DO $$
DECLARE n int; ok boolean; v_po text; v_ps text; v_key text;
BEGIN
  -- ═══ TR1 — سلسلة الاعتماد مُطفأة: لا قاعدة نشطة تبني مراحل ═══
  SELECT count(*) INTO n FROM proc_approval_rules WHERE active IS DISTINCT FROM false;
  IF n <> 0 THEN RAISE EXCEPTION 'TR1 فشل: % قاعدة اعتماد ما تزال نشطة', n; END IF;

  -- ═══ TR2 — الطلب المُرسَل (submitted) يُعالَج مباشرةً بلا اعتماد ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  PERFORM pr_proc_stage('PR-T1','in_progress');
  RESET ROLE;
  SELECT proc_status INTO v_ps FROM proc_purchase_requests WHERE id='PR-T1';
  IF v_ps <> 'in_progress' THEN RAISE EXCEPTION 'TR2 فشل: % ', v_ps; END IF;

  -- ═══ TR3 — «صدر أمر الشراء» لا تُدَّعى بزرّ: تتطلّب ربطاً فعليّاً ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_proc_stage('PR-T1','po_issued'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'TR3 فشل: أُعلن صدور أمر شراء بلا ربط'; END IF;

  -- ═══ TR4 — رقم أمر غير موجود يُرفض (لا ربط بأرقام ملفَّقة) ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_link_po('PR-T1','P.O-LA-YOUJAD-9999'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'TR4 فشل: رُبِط الطلب برقم أمر غير موجود'; END IF;

  -- ═══ TR5 — الربط الصحيح يضبط الرقم والمرحلة معاً ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  PERFORM pr_link_po('PR-T1','PO-A');
  RESET ROLE;
  SELECT po_number, proc_status INTO v_po, v_ps FROM proc_purchase_requests WHERE id='PR-T1';
  IF v_po <> 'PO-A' OR v_ps <> 'po_issued' THEN
    RAISE EXCEPTION 'TR5 فشل: %/%', v_po, v_ps;
  END IF;

  -- ═══ TR6 — الربط صلاحية مشتريات: مقدّم الطلب لا يربط لنفسه ═══
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_link_po('PR-T1','PO-C'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'TR6 فشل: ربط مقدّمُ الطلب أمراً بنفسه'; END IF;

  -- ═══ TR7 — لا ربط بمسودّة ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_link_po('PR-T2','PO-A'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'TR7 فشل: رُبِط أمر شراء بمسودّة'; END IF;

  -- ═══ TR8 — فكّ الربط يُعيد المرحلة ويترك أثراً ═══
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  PERFORM pr_unlink_po('PR-T1');
  RESET ROLE;
  SELECT po_number, proc_status INTO v_po, v_ps FROM proc_purchase_requests WHERE id='PR-T1';
  IF v_po IS NOT NULL OR v_ps <> 'in_progress' THEN
    RAISE EXCEPTION 'TR8 فشل: %/%', coalesce(v_po,'—'), v_ps;
  END IF;
  SELECT count(*) INTO n FROM proc_audit_log
   WHERE entity_id='PR-T1' AND action IN ('pr_link_po','pr_unlink_po');
  IF n < 2 THEN RAISE EXCEPTION 'TR8 فشل: أثر التدقيق ناقص (%)', n; END IF;

  -- ═══ TR9 — مفتاح المرفق مقيَّد بمجال الطلب (لا تلفيق مفتاح طلب آخر) ═══
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_set_doc('PR-T1','docs/pr/PR-OTHER/x.pdf','x.pdf'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RESET ROLE; RAISE EXCEPTION 'TR9 فشل: قُبِل مفتاح خارج مجال الطلب'; END IF;
  PERFORM pr_set_doc('PR-T1','docs/pr/PR-T1/ok.pdf','الطلب الموقَّع.pdf');
  RESET ROLE;
  SELECT doc_key INTO v_key FROM proc_purchase_requests WHERE id='PR-T1';
  IF v_key <> 'docs/pr/PR-T1/ok.pdf' THEN RAISE EXCEPTION 'TR9 فشل: %', coalesce(v_key,'—'); END IF;

  -- ═══ TR10 — المرفق يرفعه صاحبه أو المشتريات، لا أيّ موظّف آخر ═══
  PERFORM t_as('nasser@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_set_doc('PR-T1','docs/pr/PR-T1/hack.pdf','hack.pdf'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'TR10 فشل: استبدل موظّفٌ آخر سند الطلب'; END IF;

  RAISE NOTICE '✓ TR1–TR10 — كل تأكيدات نموذج المتابعة ناجحة';
END $$;

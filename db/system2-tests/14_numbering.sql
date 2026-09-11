-- ════════════════════════════════════════════════════════════════════════════
--  تأكيدات الترقيم الخادميّ وحوكمة السند والربط
--  db/system2-request-numbering.sql (+ تصليب pr_set_doc / pr_link_po)
-- ----------------------------------------------------------------------------
--  ⚠️ هذه التأكيدات **سلوكية**: تستدعي الدوالّ فعلاً بهوية JWT وRLS مُفعَّلة.
--  العيوب التي تغطّيها مرّت كلّها من فحوص نصّية، فلا تُبدَّل بفحص نصّيّ.
-- ════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- بذرة: طلبٌ يخصّ قطاعاً **لا يراه** موظّف «الصيانة والتشغيل» — هذا بالضبط ما
-- كان يُخفي الرقم عن العميل فيقترح رقماً مستعمَلاً.
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);
INSERT INTO proc_purchase_requests (id, title, sector, requester, status) VALUES
  ('PR-DG' || to_char(now(),'YYYY') || '-0007','طلب قطاع آخر','الإنشاءات','Mostafa','submitted')
ON CONFLICT (id) DO NOTHING;
INSERT INTO proc_pr_items (pr_id, seq, description, requested_qty)
VALUES ('PR-T2', 1, 'بند مسودّة', 3) ON CONFLICT DO NOTHING;
SELECT set_config('request.jwt.claims', '', false);

DO $$
DECLARE ok boolean; v_num text; v_year text := to_char(now(),'YYYY'); n int; v_st text;
BEGIN
  -- ═══ NM1 — الرقم يُحسب على **كل** الصفوف لا على ما يراه العميل ═══
  -- موظّف مُنطَّق لا يرى 0007 إطلاقاً؛ الدالّة يجب أن تتجاوزه لا أن تُعيده.
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_purchase_requests
   WHERE id = 'PR-DG' || v_year || '-0007';
  v_num := pr_next_number();
  RESET ROLE;
  IF n <> 0 THEN
    RAISE EXCEPTION 'NM1 لاغٍ: الصفّ مرئيّ للموظّف فالسيناريو لا يختبر شيئاً';
  END IF;
  IF v_num <> 'PR-DG' || v_year || '-0008' THEN
    RAISE EXCEPTION 'NM1 فشل: اقترح % وهو رقم مستعمَل أو خاطئ (المتوقّع %-0008)',
      v_num, 'PR-DG' || v_year;
  END IF;

  -- ═══ NM2 — الدالّة تتطلّب هوية (لا ترقيم لمجهول) ═══
  PERFORM set_config('request.jwt.claims', '', true);
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_next_number(); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'NM2 فشل: رقّم لمستخدم بلا هوية'; END IF;

  -- ═══ NM3 — الموظّف المُنطَّق يحذف بنود طلبه (كان ممنوعاً فتتضاعف البنود) ═══
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  DELETE FROM proc_pr_items WHERE pr_id = 'PR-T2';
  RESET ROLE;
  SELECT count(*) INTO n FROM proc_pr_items WHERE pr_id = 'PR-T2';
  IF n <> 0 THEN
    RAISE EXCEPTION 'NM3 فشل: بقي % بنداً — إعادة الحفظ ستُضاعف البنود', n;
  END IF;

  -- ═══ NM4 — بنود طلبٍ خارج الرؤية لا تُحذف (لم نُضعِف النطاق) ═══
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  INSERT INTO proc_pr_items (pr_id, seq, description, requested_qty)
  VALUES ('PR-DG' || v_year || '-0007', 1, 'بند قطاع آخر', 1);
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  DELETE FROM proc_pr_items WHERE pr_id = 'PR-DG' || v_year || '-0007';
  RESET ROLE;
  SELECT count(*) INTO n FROM proc_pr_items WHERE pr_id = 'PR-DG' || v_year || '-0007';
  IF n <> 1 THEN RAISE EXCEPTION 'NM4 فشل: حُذف بند طلبٍ خارج نطاقه'; END IF;

  -- ═══ NM5 — السند لا يُمسَح بعد الإرسال (المرفق هو الاعتماد) ═══
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  UPDATE proc_purchase_requests
     SET doc_key = 'docs/pr/PR-T1/x.pdf', doc_name = 'سند.pdf', requester = 'saleh',
         status = 'submitted'
   WHERE id = 'PR-T1';
  PERFORM t_as('saleh@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_set_doc('PR-T1', NULL, NULL); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN RAISE EXCEPTION 'NM5 فشل: مُسِح سند طلبٍ مُرسَل'; END IF;
  SELECT doc_key INTO v_st FROM proc_purchase_requests WHERE id='PR-T1';
  IF coalesce(v_st,'') = '' THEN RAISE EXCEPTION 'NM5 فشل: السند اختفى فعليّاً'; END IF;

  -- ═══ NM6 — أمر شراء واحد لطلب واحد (لا يدّعيه طلبان) ═══
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  INSERT INTO proc_purchase_requests (id, title, sector, requester, status)
  VALUES ('PR-T3','طلب ثانٍ','الصيانة والتشغيل','saleh','submitted')
  ON CONFLICT (id) DO NOTHING;
  UPDATE proc_purchase_requests SET po_number='PO-A' WHERE id='PR-T1';
  PERFORM t_as('proc1@aldeyabi.com');
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM pr_link_po('PR-T3','PO-A'); ok := false;
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  IF NOT ok THEN
    RAISE EXCEPTION 'NM6 فشل: أمر الشراء نفسه رُبِط بطلبين — «صدر أمر رقم …» يكذب';
  END IF;

  RAISE NOTICE '✓ NM1–NM6 نجحت';
END $$;

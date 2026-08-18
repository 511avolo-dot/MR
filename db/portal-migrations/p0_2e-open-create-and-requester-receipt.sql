-- ════════════════════════════════════════════════════════════════════════════
--  p0_2e — (أ) رفع الطلب متاح لكل موظّف · (ب) مُقدّم الطلب يؤكّد استلام طلبه
--  (تكليف المالك 2026-08-18)
--  ---------------------------------------------------------------------------
--  ملاحظة المالك: «الطلب المفروض أيّ موظف يمكنه تقديم طلب — لماذا أُسنِد الوظيفة؟
--  وأيضاً الاستلام المفروض أيّ شخص طلب يمكنه الاستلام.»
--
--  الواقع المرصود قبل هذه الهجرة:
--   (أ) 9 وظائف نشطة بلا can_create (gm · warehouse · qc · accountant · bank_officer ·
--       fin_officer · fin_mgr · fin_manager · fin_accounts_mgr) ⇒ حاملوها لا يستطيعون
--       رفع طلب إطلاقاً رغم أنّهم موظّفون.
--   (ب) portal_record_receipt تشترط can_verify_stock حصراً، بينما **الواجهة تعرض
--       لمُقدّم الطلب مهمّة «بانتظار تأكيد استلامك»** (myTasks: r.requester===ME) —
--       فيضغط المُقدّم ويُرفض من الخادم. خلل فعليّ بين الواجهة والحوكمة.
--
--  الإصلاح:
--   (أ) منح can_create لكل وظيفة **نشطة** (دمج jsonb، لا يمسّ أيّ صلاحية أخرى).
--       الحارس نفسه في portal_create_request يبقى كما هو (لم يُضعَّف) — غيّرنا البذور لا الحارس،
--       فيبقى منع الحسابات المعطَّلة/بلا وظيفة قائماً.
--   (ب) portal_record_receipt: يُقبل **مُقدّم الطلب نفسه** لطلبه هو، إضافةً لحاملي
--       can_verify_stock. لا يُفتح لأيّ مستخدم آخر.
--
--  ⚠️ ملاحظة حوكمية مُثبَتة (قرار المالك صراحةً): تأكيد المُقدّم لاستلام طلبه هو
--  ممارسة معتادة للخدمات والتوريد المباشر، لكنّه يُضعِف فصل «الطالب ≠ المستلِم».
--  لا يمسّ هذا فصل مهام **الصرف** الثلاثي (الطالب ≠ المعتمِد ≠ المنفّذ) الذي يبقى كما هو،
--  والتدقيق يسجّل هوية المستلِم دائماً. يمكن التراجع بإلغاء شرط requester أدناه.
--
--  idempotent: UPDATE بدمج || + CREATE OR REPLACE. مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (أ) رفع الطلب متاح لكل موظّف: منح can_create لكل وظيفة نشطة ────────────────
DO $grant$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  UPDATE portal_jobs
     SET permissions = coalesce(permissions,'{}'::jsonb) || '{"can_create":true}'::jsonb
   WHERE active
     AND coalesce((permissions->>'can_create')::boolean,false) = false;
  -- مزامنة المستخدمين الحاملين لتلك الوظائف (صلاحياتهم منسوخة من الوظيفة عند الإسناد).
  UPDATE portal_users u
     SET permissions = coalesce(u.permissions,'{}'::jsonb) || '{"can_create":true}'::jsonb
    FROM portal_jobs j
   WHERE u.job_key = j.key AND j.active AND u.role <> 'admin'
     AND coalesce((u.permissions->>'can_create')::boolean,false) = false;
  PERFORM set_config('app.portal_transition','0',true);
  PERFORM portal_audit_write(NULL, 'jobs_create_opened', 'system:p0_2e', 'portal',
    jsonb_build_object('note','can_create granted to every active job (owner mandate: any employee may submit)'));
END $grant$;

-- ── (ب) مُقدّم الطلب يؤكّد استلام طلبه (نسخة طبق الأصل من الدالة القائمة، غُيِّر سطر التفويض فقط) ──
CREATE OR REPLACE FUNCTION portal_record_receipt(p_request_id text, p_lines jsonb, p_note text DEFAULT NULL,
    p_doc_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_line jsonb;
  v_remaining numeric;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  -- (p0_2e) المستلِم: حامل صلاحية تأكيد الاستلام (المستودع/الجودة) **أو مُقدّم الطلب نفسه**.
  IF NOT (portal_has_perm('can_verify_stock') OR v_req.requester = v_me) THEN
    RAISE EXCEPTION 'غير مصرّح';
  END IF;
  IF v_req.phase <> 'receipt' THEN RAISE EXCEPTION 'الطلب ليس بانتظار استلام'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  FOR v_line IN SELECT * FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) LOOP
    IF coalesce((v_line->>'qty')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'كمية استلام غير صالحة (يجب أن تكون موجبة)';
    END IF;
    UPDATE portal_request_items
      SET received_qty = LEAST(qty, received_qty + (v_line->>'qty')::numeric)
      WHERE id = (v_line->>'item_id')::bigint AND request_id = p_request_id;
  END LOOP;

  INSERT INTO portal_receipts(request_id, received_by, note, lines, doc_key)
    VALUES (p_request_id, v_me, p_note, p_lines, nullif(trim(coalesce(p_doc_key,'')),''));
  SELECT sum(GREATEST(qty - received_qty, 0)) INTO v_remaining FROM portal_request_items WHERE request_id = p_request_id;

  IF coalesce(v_remaining, 0) <= 0 THEN
    UPDATE portal_requests SET status = 'closed', phase = 'closed', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    PERFORM portal_audit_write(p_request_id, 'closed', v_me, 'portal', '{}'::jsonb);
  ELSE
    UPDATE portal_requests SET updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'receipt_recorded', v_me, 'portal',
    jsonb_build_object('note', p_note, 'remaining', v_remaining, 'has_doc', (nullif(trim(coalesce(p_doc_key,'')),'') IS NOT NULL),
                       'by_role', CASE WHEN portal_has_perm('can_verify_stock') THEN 'stock' ELSE 'requester' END));
  RETURN jsonb_build_object('ok', true, 'remaining', coalesce(v_remaining,0));
END $fn$;

-- تشغيل كل هجرات التصليب (005 → 015) بالترتيب. آمن + idempotent (إضافة فقط).
-- المكان: Supabase → مشروع mwbjoysuybgbrvfrprex → SQL Editor → الصق الكل → Run.
-- من شغّل حتى 012 سابقاً: يكفيه 013+014+015 (آخر ثلاث كتل في هذا الملف).

-- ═══ 005-resubmit.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 005 — إعادة تقديم الطلب المُعاد (returned → in_review)
--  تُصلح المانع B2: كانت الواجهة تنادي portal_submit_request التي ترفض غير
--  المسودّة، فيموت الطلب المُعاد. هذه RPC ذرّية تُعيد بناء سلسلة الاعتماد من
--  البداية وتُعيد الحالة in_review — بحمايات (returned فقط، مُقدّم الطلب/أدمن).
--  idempotent (CREATE OR REPLACE). شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_resubmit_request(p_request_id text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_first int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'returned' THEN RAISE EXCEPTION 'يمكن إعادة تقديم الطلبات المُعادة فقط'; END IF;
  IF v_req.requester <> v_me AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'إعادة التقديم تقتصر على مُقدّم الطلب';
  END IF;

  PERFORM set_config('app.portal_transition','1',true);
  -- إعادة بناء نفس سلسلة الحاجة من البداية (كل المراحل pending) — لا إدراج سلسلة جديدة
  UPDATE portal_approvals
     SET decision='pending', approver=NULL, comment=NULL, acted_at=NULL, channel='portal'
   WHERE request_id = p_request_id;
  SELECT min(seq) INTO v_first FROM portal_approvals WHERE request_id = p_request_id;
  UPDATE portal_requests
     SET status='in_review', phase='requisition', current_seq = coalesce(v_first,1),
         updated_at=now(), updated_by=v_me
   WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition','0',true);

  PERFORM portal_audit_write(p_request_id,'resubmitted',v_me,'portal',jsonb_build_object('comment',p_comment));
  RETURN jsonb_build_object('ok',true,'status','in_review');
END $fn$;

REVOKE ALL ON FUNCTION portal_resubmit_request(text,text) FROM public;
GRANT EXECUTE ON FUNCTION portal_resubmit_request(text,text) TO authenticated;


-- ═══ 006-guard-alignment.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 006 — مواءمة حارس الإلغاء مع المواصفات (الباب 7 + سيناريو 6-5)
--  المواصفات: «بصلاحية المشتريات/الأدمن في أي وقت، أو مقدّم الطلب قبل بدء التزويد».
--  كان الخادم يقصر الإلغاء على المُقدّم/الأدمن فقط، فتظهر أزرار الواجهة للمشتريات
--  ثم يرفضها الخادم. هنا نوسّعه ليشمل صلاحيات المشتريات — مع إبقاء منع إلغاء
--  المغلق/الملغى وقيد «المُقدّم قبل التعميد». idempotent.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_cancel_request(p_request_id text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status IN ('closed','cancelled') THEN RAISE EXCEPTION 'لا يمكن إلغاء طلب مُغلق'; END IF;

  -- من يُلغي: الأدمن/المشتريات (أي وقت) — أو المُقدّم قبل بدء التعميد فقط.
  IF NOT (
        portal_is_admin()
        OR portal_has_perm('can_manage_procurement')
        OR portal_has_perm('can_approve_award')
        OR portal_has_perm('can_issue_po')
        OR (v_req.requester = v_me AND v_req.status IN ('draft','in_review','returned'))
     ) THEN
    RAISE EXCEPTION 'غير مصرّح بإلغاء هذا الطلب في حالته الحالية';
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_requests SET status = 'cancelled', cancelled_by = v_me, cancelled_at = now(), cancel_reason = p_reason, updated_at = now()
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'cancelled', v_me, 'portal', jsonb_build_object('reason', p_reason));
  RETURN jsonb_build_object('ok', true, 'status', 'cancelled');
END $fn$;


-- ═══ 007-doa-po-chain.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 007 — مصفوفة DoA الجديدة + سلسلة اعتماد أمر الشراء متعددة المراحل
--  ──────────────────────────────────────────────────────────────────────────
--  التعميد (التوصية على مورد) = مدير المشتريات دائماً (award_review كما هو).
--  اعتماد أمر الشراء = سلسلة تكبر بالقيمة:
--    0–25K:      مدير المشتريات فقط (يُصدر مباشرة)
--    25–150K:    + اللجنة المصغّرة (can_approve_committee)
--    150–250K:   + المدير المالي (can_approve_finance)
--    250–500K:   + المدير العام (can_manage_users)
--    >500K:      الكل + المدير العام (مناقصة رسمية)
--  idempotent. شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1) أعمدة DoA الجديدة (أعلام سلسلة أمر الشراء) ──
ALTER TABLE portal_doa ADD COLUMN IF NOT EXISTS po_committee boolean NOT NULL DEFAULT false;
ALTER TABLE portal_doa ADD COLUMN IF NOT EXISTS po_finance   boolean NOT NULL DEFAULT false;
ALTER TABLE portal_doa ADD COLUMN IF NOT EXISTS po_gm        boolean NOT NULL DEFAULT false;

-- ── 2) إعادة بذر الشرائح الخمس (استبدال كامل — بحماية علم الإدارة) ──
DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  -- فكّ ارتباط التعميدات التاريخية بشرائح DoA قبل استبدالها (تجنّب انتهاك FK).
  -- النظام يشتقّ الشريحة من قيمة التعميد (winner_total) لا من doa_id، فلا أثر على المستندات.
  UPDATE portal_award SET doa_id = NULL WHERE doa_id IS NOT NULL;
  DELETE FROM portal_doa;
  INSERT INTO portal_doa (max_value, quotes_required, committee_required, award_role_key, po_role_key,
                          po_committee, po_finance, po_gm, label, note, priority) VALUES
   (25000,   1, false, 'can_approve_award', 'can_manage_procurement', false, false, false, '0 – 25,000',        'اعتماد مدير المشتريات (تعميد + أمر شراء)', 10),
   (150000,  3, true,  'can_approve_award', 'can_manage_procurement', true,  false, false, '25,001 – 150,000',   'أمر الشراء: مدير المشتريات + اللجنة', 20),
   (250000,  3, true,  'can_approve_award', 'can_manage_procurement', true,  true,  false, '150,001 – 250,000',  'أمر الشراء: + المدير المالي', 30),
   (500000,  3, true,  'can_approve_award', 'can_manage_procurement', true,  true,  true,  '250,001 – 500,000',  'أمر الشراء: + المدير العام', 40),
   (NULL,    3, true,  'can_approve_award', 'can_manage_procurement', true,  true,  true,  'أكثر من 500,000',     'مناقصة رسمية — كل الاعتمادات + المدير العام', 50);
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

-- ── 3) أعضاء اللجنة (قائمة يحدّدها الأدمن) في portal_settings ──
INSERT INTO portal_settings (key, value)
SELECT 'committee_members', '[]'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM portal_settings WHERE key = 'committee_members');

-- ── 4) جدول سلسلة اعتماد أمر الشراء ──
CREATE TABLE IF NOT EXISTS portal_po_approvals (
  id            BIGSERIAL PRIMARY KEY,
  request_id    TEXT NOT NULL REFERENCES portal_requests(id) ON DELETE CASCADE,
  seq           INT NOT NULL,
  stage_label   TEXT,
  kind          TEXT,                                   -- committee | finance | gm | proc
  role_key      TEXT,
  approver      TEXT,
  decision      TEXT NOT NULL DEFAULT 'pending',        -- pending | approved | rejected | returned
  comment       TEXT,
  acted_at      TIMESTAMPTZ,
  channel       TEXT NOT NULL DEFAULT 'portal',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (request_id, seq)
);

-- حارس: كتابة عبر دوال البوابة فقط (نفس نمط portal_award_approvals)
CREATE OR REPLACE FUNCTION portal_po_approvals_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF portal_is_privileged() THEN RETURN COALESCE(NEW, OLD); END IF;
  IF current_setting('app.portal_transition', true) = '1' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF portal_is_admin() THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'سلسلة أمر الشراء تُدار عبر دوال البوابة فقط';
END $fn$;
DROP TRIGGER IF EXISTS trg_portal_po_appr_guard ON portal_po_approvals;
CREATE TRIGGER trg_portal_po_appr_guard BEFORE INSERT OR UPDATE OR DELETE ON portal_po_approvals
  FOR EACH ROW EXECUTE FUNCTION portal_po_approvals_guard();

-- RLS
ALTER TABLE portal_po_approvals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_all" ON portal_po_approvals;
CREATE POLICY "auth_all" ON portal_po_approvals FOR ALL TO authenticated USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON portal_po_approvals TO authenticated;
GRANT ALL ON portal_po_approvals TO service_role;
GRANT USAGE, SELECT ON SEQUENCE portal_po_approvals_id_seq TO authenticated, service_role;

-- ── 5) بنّاء سلسلة أمر الشراء حسب الشريحة (يُستدعى عند اعتماد التعميد النهائي) ──
CREATE OR REPLACE FUNCTION portal_build_po_chain(p_request_id text, p_total numeric) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE d portal_doa%ROWTYPE; v_seq int := 0;
BEGIN
  SELECT * INTO d FROM portal_doa WHERE max_value IS NULL OR p_total <= max_value ORDER BY priority ASC LIMIT 1;
  DELETE FROM portal_po_approvals WHERE request_id = p_request_id;
  IF d.po_committee THEN v_seq := v_seq + 1;
    INSERT INTO portal_po_approvals(request_id,seq,stage_label,kind,role_key) VALUES (p_request_id,v_seq,'اعتماد اللجنة المصغّرة','committee','can_approve_committee'); END IF;
  IF d.po_finance THEN v_seq := v_seq + 1;
    INSERT INTO portal_po_approvals(request_id,seq,stage_label,kind,role_key) VALUES (p_request_id,v_seq,'اعتماد المدير المالي','finance','can_approve_finance'); END IF;
  IF d.po_gm THEN v_seq := v_seq + 1;
    INSERT INTO portal_po_approvals(request_id,seq,stage_label,kind,role_key) VALUES (p_request_id,v_seq,'اعتماد المدير العام','gm','can_manage_users'); END IF;
  RETURN v_seq;  -- عدد مراحل الاعتماد (0 = يُصدر أمر الشراء مباشرة)
END $fn$;
REVOKE ALL ON FUNCTION portal_build_po_chain(text,numeric) FROM public;
GRANT EXECUTE ON FUNCTION portal_build_po_chain(text,numeric) TO authenticated, service_role;

-- ── 6) portal_award_transition (معدّلة: تبني سلسلة أمر الشراء بدل الإصدار المباشر) ──
CREATE OR REPLACE FUNCTION portal_award_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_award_approvals%ROWTYPE;
  v_perm boolean; v_decision text; v_status text; v_phase text; v_po_stages int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'award_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار اعتماد التعميد'; END IF;
  IF v_req.requester = v_me THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;
  -- فصل المهام: من رسا العرض لا يعتمد تعميده (يمنع موظف مشتريات من ترسية العرض
  -- واعتماده بنفسه في الشرائح التي مفتاح اعتمادها can_manage_procurement).
  IF EXISTS (SELECT 1 FROM portal_award WHERE request_id = p_request_id AND awarded_by = v_me)
     AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد تعميد رسّيته بنفسك (فصل المهام)';
  END IF;

  SELECT * INTO v_stage FROM portal_award_approvals
    WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة تعميد معلّقة'; END IF;

  SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm FROM portal_users WHERE username = v_me;
  IF NOT coalesce(v_perm,false) AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action = 'reject' AND coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض'; END IF;

  v_decision := CASE p_action WHEN 'approve' THEN 'approved' ELSE 'rejected' END;

  PERFORM set_config('app.portal_transition', '1', true);

  UPDATE portal_award_approvals SET decision = v_decision, approver = v_me, comment = p_comment, acted_at = now()
    WHERE request_id = p_request_id AND seq = v_stage.seq;

  IF p_action = 'approve' THEN
    UPDATE portal_award SET status = 'approved' WHERE request_id = p_request_id;
    -- بناء سلسلة اعتماد أمر الشراء حسب شريحة القيمة (0–25K = 0 مراحل → إصدار مباشر)
    v_po_stages := portal_build_po_chain(p_request_id, (SELECT coalesce(winner_total,0) FROM portal_award WHERE request_id = p_request_id));
    IF v_po_stages = 0 THEN
      v_status := 'awarded'; v_phase := 'payment';
      UPDATE portal_requests SET status = v_status, phase = v_phase, po_issued_by = v_me, po_issued_at = now(), updated_at = now(), updated_by = v_me
        WHERE id = p_request_id;
    ELSE
      v_status := 'po_review'; v_phase := 'po_review';
      UPDATE portal_requests SET status = v_status, phase = v_phase, current_seq = 1, updated_at = now(), updated_by = v_me
        WHERE id = p_request_id;
    END IF;
  ELSE
    v_status := 'pricing'; v_phase := 'pricing'; -- يعود للتسعير لاختيار عرض آخر
    UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
    UPDATE portal_requests SET status = v_status, phase = v_phase, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'award_' || v_decision, v_me, 'portal', jsonb_build_object('comment', p_comment));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;

-- ── 7) portal_po_transition ──
CREATE OR REPLACE FUNCTION portal_po_transition(p_request_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_req portal_requests%ROWTYPE; v_stage portal_po_approvals%ROWTYPE;
        v_perm boolean; v_remaining int; v_committee jsonb;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'po_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار اعتماد أمر الشراء'; END IF;
  IF v_req.requester = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)'; END IF;

  SELECT * INTO v_stage FROM portal_po_approvals WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة أمر شراء معلّقة'; END IF;

  IF v_stage.kind = 'committee' THEN
    SELECT value INTO v_committee FROM portal_settings WHERE key = 'committee_members';
    IF NOT ( portal_is_admin()
             OR coalesce((SELECT (permissions ->> 'can_approve_committee')::boolean FROM portal_users WHERE username = v_me), false)
             OR (v_committee IS NOT NULL AND v_committee ? v_me) ) THEN
      RAISE EXCEPTION 'لست عضواً في اللجنة المصغّرة';
    END IF;
  ELSE
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm FROM portal_users WHERE username = v_me;
    IF NOT coalesce(v_perm,false) AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;
  END IF;

  IF NOT portal_is_admin() THEN
    IF EXISTS (SELECT 1 FROM portal_po_approvals WHERE request_id = p_request_id AND approver = v_me AND decision = 'approved') THEN
      RAISE EXCEPTION 'لا تعتمد أكثر من مرحلة في أمر الشراء نفسه (فصل المهام)';
    END IF;
    IF EXISTS (SELECT 1 FROM portal_award WHERE request_id = p_request_id AND awarded_by = v_me) THEN
      RAISE EXCEPTION 'من رسا التعميد لا يعتمد أمر شرائه (فصل المهام)';
    END IF;
  END IF;

  IF p_action IN ('reject','return') AND coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب'; END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  IF p_action = 'approve' THEN
    UPDATE portal_po_approvals SET decision = 'approved', approver = v_me, comment = p_comment, acted_at = now()
      WHERE request_id = p_request_id AND seq = v_stage.seq;
    SELECT count(*) INTO v_remaining FROM portal_po_approvals WHERE request_id = p_request_id AND decision = 'pending';
    IF v_remaining = 0 THEN
      UPDATE portal_requests SET status = 'awarded', phase = 'payment', po_issued_by = v_me, po_issued_at = now(),
             current_seq = 0, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    ELSE
      UPDATE portal_requests SET current_seq = v_stage.seq + 1, updated_at = now(), updated_by = v_me WHERE id = p_request_id;
    END IF;
  ELSE
    UPDATE portal_po_approvals SET decision = CASE p_action WHEN 'reject' THEN 'rejected' ELSE 'returned' END,
           approver = v_me, comment = p_comment, acted_at = now() WHERE request_id = p_request_id AND seq = v_stage.seq;
    UPDATE portal_award SET status = 'rejected' WHERE request_id = p_request_id;
    UPDATE portal_requests SET status = 'pricing', phase = 'pricing', updated_at = now(), updated_by = v_me WHERE id = p_request_id;
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'po_' || p_action, v_me, 'portal', jsonb_build_object('comment', p_comment, 'stage', v_stage.stage_label));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', (SELECT status FROM portal_requests WHERE id = p_request_id));
END $fn$;
REVOKE ALL ON FUNCTION portal_po_transition(text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_po_transition(text, text, text) TO authenticated;


-- ═══ 008-flexible-return.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 008 — الإرجاع المرن (اختيار مَن يعود له الطلب) — الدورة الأولى
--  المواصفات (توجيه المالك): «الرفض أو الموافقة أو الإعادة، واختيار الشخص أو
--  القسم الذي يعود له الطلب، والذي عاد إليه الطلب يمكنه أن يعيده أيضاً لمن سبقه
--  في أي إجراء في المعاملة.»
--
--  قبل هذه الهجرة كان الإرجاع يعيد الطلب إلى مقدّمه فقط (status='returned').
--  الآن يقبل portal_pr_transition معاملاً جديداً p_return_to_seq:
--    • 0  → إرجاع إلى مقدّم الطلب (السلوك القديم — يعيد التقديم عبر resubmit).
--    • >0 → إعادة فتح مرحلة اعتماد سابقة بعينها: تُصفَّر تلك المرحلة وكل ما بعدها
--          إلى pending، ويعود الطلب إلى in_review على تلك المرحلة. المعتمِد الذي
--          عاد إليه الطلب يستطيع بدوره إرجاعه لمن سبقه (نفس الآلية تعمل تراكمياً).
--
--  التوقيع الجديد 5 معاملات — نسقط القديم (4) ونعيد الإنشاء. نداءات الواجهة
--  بالمعاملات المُسمّاة تبقى تعمل (p_return_to_seq افتراضيّه 0). idempotent.
--  شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex بعد 005/006/007.
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS portal_pr_transition(text, text, text, date);
CREATE OR REPLACE FUNCTION portal_pr_transition(p_request_id text, p_action text,
    p_comment text DEFAULT NULL, p_hold_until date DEFAULT NULL, p_return_to_seq int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_stage portal_approvals%ROWTYPE;
  v_target portal_approvals%ROWTYPE;
  v_pending int; v_next_seq int; v_decision text; v_status text; v_phase text;
  v_ok boolean := false; v_intended text; v_perm boolean;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','defer') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_req.status <> 'in_review' THEN RAISE EXCEPTION 'الطلب ليس قيد المراجعة'; END IF;

  SELECT * INTO v_stage FROM portal_approvals
    WHERE request_id = p_request_id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة معلّقة'; END IF;

  IF portal_setting_bool('sod_requester_cannot_approve', true)
     AND v_req.requester = v_me AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'لا يمكنك اعتماد طلبك (فصل المهام)';
  END IF;
  -- فصل المهام متعدّد المراحل: من اعتمد مرحلة سابقة لا يعتمد مرحلة لاحقة لنفس الطلب
  IF EXISTS (SELECT 1 FROM portal_approvals WHERE request_id = p_request_id
              AND approver = v_me AND decision = 'approved' AND seq < v_stage.seq)
     AND NOT portal_is_admin() THEN
    RAISE EXCEPTION 'اعتمدت مرحلة سابقة لهذا الطلب — لا يجوز اعتماد أكثر من مرحلة (فصل المهام)';
  END IF;

  v_intended := portal_resolve_stage(p_request_id, v_stage);
  IF v_intended IS NOT NULL THEN
    v_ok := (portal_qualified_approver(v_intended, v_req.requester) = v_me);
  ELSIF v_stage.role_key IS NOT NULL THEN
    SELECT coalesce((permissions ->> v_stage.role_key)::boolean, false) INTO v_perm
      FROM portal_users WHERE username = v_me;
    v_ok := coalesce(v_perm, false);
  END IF;
  IF NOT v_ok AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لست المُعتمِد لهذه المرحلة'; END IF;

  IF p_action IN ('reject','return','defer') AND coalesce(trim(p_comment),'') = '' THEN
    RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع/التأجيل';
  END IF;

  -- التأجيل المالي (سيناريو 6-4): من بوابة التحقق المالي فقط (أو الأدمن).
  IF p_action = 'defer' THEN
    IF v_stage.role_key IS DISTINCT FROM 'can_approve_finance' AND NOT portal_is_admin() THEN
      RAISE EXCEPTION 'التأجيل المالي متاح في مرحلة التحقق المالي فقط';
    END IF;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_requests SET status = 'on_hold', hold_reason = p_comment, hold_until = p_hold_until,
           held_by = v_me, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(p_request_id, 'deferred', v_me, 'portal',
      jsonb_build_object('reason', p_comment, 'until', p_hold_until));
    RETURN jsonb_build_object('ok', true, 'action', 'defer', 'status', 'on_hold');
  END IF;

  -- ═══ الإرجاع المرن إلى مرحلة سابقة (p_return_to_seq > 0) ═══
  IF p_action = 'return' AND coalesce(p_return_to_seq, 0) > 0 THEN
    -- يجب أن تكون المرحلة الهدف سابقة للمرحلة الحالية (لا يُعاد للأمام ولا لنفسها).
    IF p_return_to_seq >= v_stage.seq THEN
      RAISE EXCEPTION 'الإرجاع يكون لمرحلة سابقة فقط';
    END IF;
    SELECT * INTO v_target FROM portal_approvals
      WHERE request_id = p_request_id AND seq = p_return_to_seq;
    IF NOT FOUND THEN RAISE EXCEPTION 'المرحلة الهدف غير موجودة'; END IF;

    PERFORM set_config('app.portal_transition', '1', true);
    -- سجّل قرار المرحلة الحالية كـ«معاد» مع سبب ووجهة، ثم أعد فتح الهدف وكل ما بعده.
    UPDATE portal_approvals SET decision = 'returned', approver = v_me, comment = p_comment,
           acted_at = now(), channel = 'portal'
      WHERE request_id = p_request_id AND seq = v_stage.seq;
    UPDATE portal_approvals SET decision = 'pending', approver = NULL, comment = NULL,
           acted_at = NULL, channel = 'portal'
      WHERE request_id = p_request_id AND seq >= p_return_to_seq AND seq <> v_stage.seq;
    -- المرحلة الحالية نفسها تُعاد إلى pending أيضاً (كي تُعتمد مجدداً عند الرجوع للأمام)،
    -- لكن بعد أن سجّلنا حدث الإرجاع عليها؛ نعيد ضبطها الآن.
    UPDATE portal_approvals SET decision = 'pending', approver = NULL, comment = NULL,
           acted_at = NULL, channel = 'portal'
      WHERE request_id = p_request_id AND seq = v_stage.seq;
    UPDATE portal_requests SET status = 'in_review', phase = 'requisition',
           current_seq = p_return_to_seq, updated_at = now(), updated_by = v_me
      WHERE id = p_request_id;
    PERFORM set_config('app.portal_transition', '0', true);

    PERFORM portal_audit_write(p_request_id, 'stage_returned', v_me, 'portal',
      jsonb_build_object('from_seq', v_stage.seq, 'to_seq', p_return_to_seq,
                         'to_stage', v_target.stage_label, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', 'return', 'decision', 'returned',
      'status', 'in_review', 'finalized', false, 'seq', v_stage.seq, 'return_to_seq', p_return_to_seq);
  END IF;

  -- ═══ الاعتماد / الرفض / الإرجاع إلى المقدّم (return_to_seq=0) ═══
  v_decision := CASE p_action WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' ELSE 'returned' END;

  SELECT count(*) INTO v_pending FROM portal_approvals WHERE request_id = p_request_id AND decision = 'pending';

  IF p_action = 'approve' THEN
    IF v_pending <= 1 THEN
      v_status := 'pricing'; v_phase := 'pricing'; v_next_seq := v_stage.seq;
    ELSE
      SELECT min(seq) INTO v_next_seq FROM portal_approvals WHERE request_id = p_request_id AND decision = 'pending' AND seq > v_stage.seq;
      v_status := 'in_review'; v_phase := 'requisition';
    END IF;
  ELSIF p_action = 'reject' THEN
    v_status := 'rejected'; v_phase := 'requisition'; v_next_seq := 0;
  ELSE
    v_status := 'returned'; v_phase := 'requisition'; v_next_seq := 0;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);

  UPDATE portal_approvals SET decision = v_decision, approver = v_me, comment = p_comment, acted_at = now(), channel = 'portal'
    WHERE request_id = p_request_id AND seq = v_stage.seq;

  UPDATE portal_requests SET status = v_status, current_seq = coalesce(v_next_seq,0), phase = v_phase, updated_at = now(), updated_by = v_me
    WHERE id = p_request_id;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'stage_' || v_decision, v_me, 'portal', jsonb_build_object('stage', v_stage.stage_label, 'comment', p_comment));

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'decision', v_decision, 'status', v_status,
                             'finalized', v_status <> 'in_review', 'seq', v_stage.seq);
END $fn$;

REVOKE ALL ON FUNCTION portal_pr_transition(text, text, text, date, int) FROM public;
GRANT EXECUTE ON FUNCTION portal_pr_transition(text, text, text, date, int) TO authenticated;


-- ═══ الإرجاع في دورة الصرف: إجراء «return» غير نهائي مع توجيه (M1) ═══
-- كانت الواجهة تُظهر «إلى مَن يعود؟» لكن الخادم يعامل الإرجاع كرفض. الآن نُضيف
-- إجراء return مستقلاً: الطلب يعود إلى awarded (يُعيد المشتريات إصدار الصرف) والوجهة
-- تُحفظ في التدقيق. التوقيع يكتسب p_return_to (نص اختياري). idempotent.
DROP FUNCTION IF EXISTS portal_payment_transition(bigint, text, text);
CREATE OR REPLACE FUNCTION portal_payment_transition(p_payment_id bigint, p_action text, p_comment text DEFAULT NULL, p_return_to text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_pay portal_payments%ROWTYPE; v_status text;
BEGIN
  IF v_me IS NULL OR NOT portal_has_perm('can_disburse') THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_action NOT IN ('approve','reject','return','disburse') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;

  SELECT * INTO v_pay FROM portal_payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الصرف غير موجود'; END IF;

  IF p_action = 'approve' THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF v_pay.requested_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك اعتماد صرفٍ طلبته بنفسك (فصل المهام)'; END IF;
    v_status := 'approved_pay';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, approved_by = v_me, approved_at = now(), comment = p_comment WHERE id = p_payment_id;
    PERFORM set_config('app.portal_transition', '0', true);
  ELSIF p_action IN ('reject','return') THEN
    IF v_pay.status <> 'pending_pay' THEN RAISE EXCEPTION 'حالة غير مطابقة'; END IF;
    IF coalesce(trim(p_comment),'') = '' THEN RAISE EXCEPTION 'السبب مطلوب للرفض/الإرجاع'; END IF;
    v_status := CASE p_action WHEN 'return' THEN 'returned' ELSE 'rejected' END;
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, comment = p_comment WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'awarded', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal',
      jsonb_build_object('payment_id', p_payment_id, 'return_to', p_return_to, 'comment', p_comment));
    RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
  ELSE -- disburse
    IF v_pay.status <> 'approved_pay' THEN RAISE EXCEPTION 'يلزم اعتماد الصرف أولاً'; END IF;
    IF v_pay.approved_by = v_me AND NOT portal_is_admin() THEN RAISE EXCEPTION 'لا يمكنك تنفيذ صرفٍ اعتمدته بنفسك (فصل المهام)'; END IF;
    v_status := 'disbursed';
    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_payments SET status = v_status, disbursed_by = v_me, disbursed_at = now() WHERE id = p_payment_id;
    UPDATE portal_requests SET status = 'receipt_pending', phase = 'receipt', updated_at = now(), updated_by = v_me WHERE id = v_pay.request_id;
    PERFORM set_config('app.portal_transition', '0', true);
  END IF;

  PERFORM portal_audit_write(v_pay.request_id, 'payment_' || v_status, v_me, 'portal', jsonb_build_object('payment_id', p_payment_id));
  RETURN jsonb_build_object('ok', true, 'action', p_action, 'status', v_status);
END $fn$;

REVOKE ALL ON FUNCTION portal_payment_transition(bigint, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_payment_transition(bigint, text, text, text) TO authenticated;


-- ═══ 009-visibility-rls.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 009 — فرض نطاق الرؤية على مستوى قاعدة البيانات (RLS) — H1
--  المواصفات (نظام لشركة كبيرة): كل مستخدم يرى فقط ما يخصّه حسب نطاق وظيفته:
--    • all    → كل الطلبات (المشتريات/المالية/المستودع/الجودة/المدير العام/الأدمن).
--    • sector → طلبات قطاعه (قسمه ضمن نفس sector) + طلباته.
--    • own    → طلباته فقط.
--  وفي كل الأحوال: يرى أي طلب هو **معتمِد فيه فعلاً** (شارك في سلسلته) حتى لو خارج نطاقه.
--
--  قبل هذه الهجرة كانت السياسة `auth_all USING(true)` تكشف كل الصفوف لأي مستخدم
--  مصادَق. الآن نستبدل سياسة SELECT على الجداول المعامَلاتية بسياسة مُنطاقة، ونُبقي
--  الكتابة عبر RPC (SECURITY DEFINER يتجاوز RLS) والمحارس (deny-by-default) كما هي.
--  جداول الإعداد (users/departments/jobs/doa/workflows/settings/suppliers) تبقى
--  عامة القراءة (يحتاجها التطبيق لعرض الأسماء/الأقسام) وكتابتها للأدمن بمحارسها.
--
--  الدوال SECURITY DEFINER كي تتجاوز استعلاماتها الداخلية RLS (تمنع التكرار
--  اللانهائي عند قراءة portal_approvals من داخل سياسة portal_approvals). idempotent.
--  شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex بعد 005–008.
-- ═══════════════════════════════════════════════════════════════════════════

-- نطاق المستخدم الحالي (من وظيفته؛ الأدمن دائماً all).
CREATE OR REPLACE FUNCTION portal_my_scope() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT CASE WHEN portal_is_admin() THEN 'all'
              ELSE coalesce((SELECT j.scope FROM portal_users u
                             LEFT JOIN portal_jobs j ON j.key = u.job_key
                             WHERE u.username = portal_username()), 'own') END;
$fn$;

-- قطاع المستخدم الحالي (sector قسمه).
CREATE OR REPLACE FUNCTION portal_my_sector() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT d.sector FROM portal_users u
    JOIN portal_departments d ON d.id = u.department_id
   WHERE u.username = portal_username();
$fn$;

-- هل يرى المستخدم الحالي طلباً بحقوله (id/requester/department)؟
CREATE OR REPLACE FUNCTION portal_can_see_request(p_id text, p_requester text, p_dept text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    portal_is_admin()
    OR portal_my_scope() = 'all'
    OR p_requester = portal_username()
    OR (portal_my_scope() = 'sector' AND EXISTS (
          SELECT 1 FROM portal_departments d
           WHERE d.id = p_dept AND d.sector IS NOT DISTINCT FROM portal_my_sector()))
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.approver = portal_username());
$fn$;

-- نفس الفحص عبر معرّف الطلب فقط (لجداول الأدلّة الفرعية).
CREATE OR REPLACE FUNCTION portal_can_see_request(p_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT portal_can_see_request(r.id, r.requester, r.department_id)
    FROM portal_requests r WHERE r.id = p_id;
$fn$;

REVOKE ALL ON FUNCTION portal_my_scope() FROM public;
REVOKE ALL ON FUNCTION portal_my_sector() FROM public;
REVOKE ALL ON FUNCTION portal_can_see_request(text, text, text) FROM public;
REVOKE ALL ON FUNCTION portal_can_see_request(text) FROM public;
GRANT EXECUTE ON FUNCTION portal_my_scope() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION portal_my_sector() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION portal_can_see_request(text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION portal_can_see_request(text) TO authenticated, service_role;

-- ═══ استبدال سياسة رأس الطلب: SELECT مُنطاق + كتابة عامة (المحارس هي المدافع) ═══
-- سياسات لكل أمر لأن FOR ALL عامة تُلغي تقييد SELECT (السياسات المسموحة تُدمج بـOR).
-- الكتابة تبقى عامة كي تظل محارس deny-by-default تُطلق الاستثناء كما قبل — لا نُضعف.
DROP POLICY IF EXISTS "auth_all"   ON portal_requests;
DROP POLICY IF EXISTS "see_scoped" ON portal_requests;
DROP POLICY IF EXISTS "wr_ins" ON portal_requests;
DROP POLICY IF EXISTS "wr_upd" ON portal_requests;
DROP POLICY IF EXISTS "wr_del" ON portal_requests;
CREATE POLICY "see_scoped" ON portal_requests FOR SELECT TO authenticated
  USING (portal_can_see_request(id, requester, department_id));
CREATE POLICY "wr_ins" ON portal_requests FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "wr_upd" ON portal_requests FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "wr_del" ON portal_requests FOR DELETE TO authenticated USING (true);

-- ═══ جداول الأدلّة الفرعية: SELECT مُقيَّد برؤية الطلب الأب + كتابة عامة ═══
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'portal_request_items','portal_approvals','portal_offers','portal_award',
    'portal_award_approvals','portal_po_approvals','portal_payments','portal_receipts'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS "auth_all" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "see_by_request" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "wr_ins" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "wr_upd" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "wr_del" ON %I', t);
    EXECUTE format('CREATE POLICY "see_by_request" ON %I FOR SELECT TO authenticated USING (portal_can_see_request(request_id))', t);
    EXECUTE format('CREATE POLICY "wr_ins" ON %I FOR INSERT TO authenticated WITH CHECK (true)', t);
    EXECUTE format('CREATE POLICY "wr_upd" ON %I FOR UPDATE TO authenticated USING (true) WITH CHECK (true)', t);
    EXECUTE format('CREATE POLICY "wr_del" ON %I FOR DELETE TO authenticated USING (true)', t);
  END LOOP;
END $$;

-- ═══ التدقيق: الأدمن يرى الكل؛ غيره يرى تدقيق الطلبات المرئية له فقط ═══
DROP POLICY IF EXISTS "audit_read" ON portal_audit;
CREATE POLICY "audit_read" ON portal_audit FOR SELECT TO authenticated
  USING (portal_is_admin() OR (request_id IS NOT NULL AND portal_can_see_request(request_id)));


-- ═══ 010-invitations.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 010 — بوابة الدعوات + تقييد النطاق البريدي (D)
--  المواصفات (توجيه المالك): روابط تسجيل للموظفين، بريد @aldeyabi حصراً، رفض أي
--  بريد خارجي/شخصي إلا ما يعتمده الأدمن مسبقاً (قائمة بيضاء).
--
--  • جدول portal_invitations: دعوات لمرة واحدة برمز عشوائي وصلاحية زمنية — يُدار
--    خادمياً فقط (لا سياسة RLS للعميل، كنمط portal_email_tokens المُثبَت). الأدمن
--    ينشئ الدعوة عبر /api/portal-invite، والموظف يُسجّل عبر /api/portal-register.
--  • إعدادات: allowed_email_domain='aldeyabi.com' + email_whitelist=[] (يضيف إليها
--    الأدمن العناوين الخارجية المعتمَدة مسبقاً). الخادم هو مرجع القرار (لا العميل).
--  • دالة portal_email_allowed(email): مرجع موحّد لقرار القبول (نطاق الشركة أو
--    قائمة بيضاء) — تُستعمل في الاختبار وأي تحقّق قاعدي.
--  idempotent. شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex بعد 005–009.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS portal_invitations (
  id            BIGSERIAL PRIMARY KEY,
  token         TEXT UNIQUE NOT NULL,
  email         TEXT NOT NULL,
  display_name  TEXT,
  job_key       TEXT REFERENCES portal_jobs(key),
  department_id TEXT REFERENCES portal_departments(id),
  role          TEXT NOT NULL DEFAULT 'user',              -- user | admin
  status        TEXT NOT NULL DEFAULT 'pending',           -- pending | accepted | revoked | expired
  invited_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days'),
  accepted_at   TIMESTAMPTZ,
  accepted_user TEXT
);
CREATE INDEX IF NOT EXISTS idx_portal_inv_email  ON portal_invitations(lower(email));
CREATE INDEX IF NOT EXISTS idx_portal_inv_status ON portal_invitations(status);

-- تفعيل RLS بلا أي سياسة = مقفل كلياً على العميل (خادم/الدوال DEFINER فقط).
ALTER TABLE portal_invitations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON portal_invitations FROM authenticated, anon;
GRANT ALL ON portal_invitations TO service_role;
GRANT USAGE, SELECT ON SEQUENCE portal_invitations_id_seq TO service_role;

-- ═══ إعدادات النطاق البريدي (تُدمج في صف الإعدادات الموحّد دون مسح غيرها) ═══
INSERT INTO portal_settings(key, value) VALUES ('portal_settings', '{}'::jsonb)
  ON CONFLICT (key) DO NOTHING;
UPDATE portal_settings SET value = value || jsonb_build_object('allowed_email_domain','aldeyabi.com')
  WHERE key='portal_settings' AND NOT (value ? 'allowed_email_domain');
UPDATE portal_settings SET value = value || jsonb_build_object('email_whitelist','[]'::jsonb)
  WHERE key='portal_settings' AND NOT (value ? 'email_whitelist');

-- ═══ مرجع قرار قبول البريد: نطاق الشركة أو القائمة البيضاء (حصراً) ═══
CREATE OR REPLACE FUNCTION portal_email_allowed(p_email text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH s AS (SELECT value FROM portal_settings WHERE key='portal_settings')
  SELECT
    lower(trim(coalesce(p_email,''))) <> ''
    AND (
      -- نطاق الشركة
      lower(trim(p_email)) LIKE ('%@' || lower(coalesce((SELECT value->>'allowed_email_domain' FROM s), 'aldeyabi.com')))
      -- أو قائمة بيضاء يعتمدها الأدمن مسبقاً (تطابق حرفي، غير حسّاس لحالة الأحرف)
      OR EXISTS (
        SELECT 1 FROM s, jsonb_array_elements_text(coalesce((SELECT value->'email_whitelist' FROM s), '[]'::jsonb)) w
        WHERE lower(trim(w)) = lower(trim(p_email))
      )
    );
$fn$;
REVOKE ALL ON FUNCTION portal_email_allowed(text) FROM public;
GRANT EXECUTE ON FUNCTION portal_email_allowed(text) TO authenticated, service_role;


-- ═══ 011-delete-user.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 011 — حذف المستخدم بأمان (E) — portal_delete_user
--  RPC ذرّية بحمايات على مستوى القاعدة (دفاع في العمق فوق تحقّق الخادم):
--    • أدمن فقط (portal_is_admin).
--    • لا حذف للذات.
--    • لا حذف لآخر أدمن نشط (قفل استشاري لتفادي السباق).
--    • فك الارتباطات (delegate_to/manager_user/مدير القسم) قبل الحذف تفادياً لقيود FK.
--    • تدقيق append-only بحدث user_deleted (request_id = NULL مسموح).
--  idempotent. شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex بعد 005–010.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_delete_user(p_username text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_role text; v_active boolean; v_admins int;
BEGIN
  IF v_me IS NULL OR NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_username IS NULL OR p_username = v_me THEN RAISE EXCEPTION 'لا يمكنك حذف حسابك'; END IF;

  SELECT role, active INTO v_role, v_active FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;

  -- قفل استشاري على «آخر أدمن» ثم فحص العدد (يمنع سباق حذف أدمنين متزامنين).
  -- الحماية تخصّ حذف أدمن **نشط** فقط (حذف أدمن غير نشط لا يُنقص عدد النشطين).
  IF v_role = 'admin' AND v_active THEN
    PERFORM pg_advisory_xact_lock(hashtext('portal_last_admin'));
    SELECT count(*) INTO v_admins FROM portal_users WHERE role = 'admin' AND active;
    IF v_admins <= 1 THEN RAISE EXCEPTION 'لا يمكن حذف آخر أدمن نشط للبوابة'; END IF;
  END IF;

  -- فك الارتباطات كي لا تفشل قيود المفتاح الأجنبي.
  UPDATE portal_users       SET delegate_to  = NULL WHERE delegate_to  = p_username;
  UPDATE portal_users       SET manager_user = NULL WHERE manager_user = p_username;
  UPDATE portal_departments SET manager_user = NULL WHERE manager_user = p_username;

  DELETE FROM portal_users WHERE username = p_username;

  PERFORM portal_audit_write(NULL, 'user_deleted', v_me, 'portal',
    jsonb_build_object('deleted_user', p_username, 'role', v_role));
  RETURN jsonb_build_object('ok', true, 'deleted', p_username);
END $fn$;

REVOKE ALL ON FUNCTION portal_delete_user(text) FROM public;
GRANT EXECUTE ON FUNCTION portal_delete_user(text) TO authenticated;


-- ═══ 012-audit-hardening.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 012 — إصلاحات ما بعد المراجعة الأمنية/الجودة
--  (1) نطاق الرؤية: مدير قطاع بلا قسم (department_id=NULL) كان portal_my_sector()
--      يرجع NULL فيطابق كل الأقسام ذات القطاع NULL → رؤية أوسع من المفترض. نُقيّده
--      بأن يكون قطاع المستخدم غير NULL (وإلا يسقط إلى own عبر بقية شروط الرؤية).
--  (2) حذف المستخدم: portal_requests.requester = NOT NULL FK بلا ON DELETE، فحذف
--      مستخدم له طلبات يفشل بانتهاك FK. الصواب حوكمياً (سلامة التدقيق): منع الحذف
--      الصلب لمن له سجلّ معاملات وتوجيهه إلى «تعطيل الحساب» بدلاً منه.
--  idempotent (CREATE OR REPLACE). شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 011.
-- ═══════════════════════════════════════════════════════════════════════════

-- (1) رؤية الطلب — تقييد فرع القطاع بألّا يكون قطاع المستخدم NULL.
CREATE OR REPLACE FUNCTION portal_can_see_request(p_id text, p_requester text, p_dept text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    portal_is_admin()
    OR portal_my_scope() = 'all'
    OR p_requester = portal_username()
    OR (portal_my_scope() = 'sector' AND portal_my_sector() IS NOT NULL AND EXISTS (
          SELECT 1 FROM portal_departments d
           WHERE d.id = p_dept AND d.sector = portal_my_sector()))
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.approver = portal_username());
$fn$;

-- (2) حذف المستخدم — منع الحذف الصلب لمن له طلبات (سلامة التدقيق) + توجيه للتعطيل.
CREATE OR REPLACE FUNCTION portal_delete_user(p_username text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_role text; v_active boolean; v_admins int;
BEGIN
  IF v_me IS NULL OR NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_username IS NULL OR p_username = v_me THEN RAISE EXCEPTION 'لا يمكنك حذف حسابك'; END IF;
  SELECT role, active INTO v_role, v_active FROM portal_users WHERE username = p_username FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المستخدم غير موجود'; END IF;
  IF v_role = 'admin' AND v_active THEN
    PERFORM pg_advisory_xact_lock(hashtext('portal_last_admin'));
    SELECT count(*) INTO v_admins FROM portal_users WHERE role = 'admin' AND active;
    IF v_admins <= 1 THEN RAISE EXCEPTION 'لا يمكن حذف آخر أدمن نشط للبوابة'; END IF;
  END IF;
  -- سلامة التدقيق: لا حذف صلب لمن له سجلّ معاملات (طلبات) — يُعطَّل حسابه بدلاً من ذلك.
  IF EXISTS (SELECT 1 FROM portal_requests WHERE requester = p_username) THEN
    RAISE EXCEPTION 'لا يمكن حذف مستخدم له طلبات مسجّلة (سلامة التدقيق) — عطّل حسابه بدلاً من الحذف';
  END IF;
  UPDATE portal_users       SET delegate_to  = NULL WHERE delegate_to  = p_username;
  UPDATE portal_users       SET manager_user = NULL WHERE manager_user = p_username;
  UPDATE portal_departments SET manager_user = NULL WHERE manager_user = p_username;
  DELETE FROM portal_users WHERE username = p_username;
  PERFORM portal_audit_write(NULL, 'user_deleted', v_me, 'portal',
    jsonb_build_object('deleted_user', p_username, 'role', v_role));
  RETURN jsonb_build_object('ok', true, 'deleted', p_username);
END $fn$;


-- ═══ 013-committee-mgmt.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 013 — تخصيص اللجنة المصغّرة (م1b)
--  المواصفات: لا توجد طريقة للأدمن لتعيين أعضاء اللجنة المصغّرة التي تعتمد أمر
--  الشراء في الشريحة >25 ألف. اللجنة تُقرأ في portal_po_transition من إعداد
--  committee_members (مصفوفة أسماء مستخدمين) أو صلاحية can_approve_committee.
--  هنا نضيف RPC آمنة (أدمن فقط) لضبط القائمة + تحقّق أن كل عضو مستخدم نشط + تدقيق.
--  idempotent. شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 012.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_set_committee(p_members jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_valid jsonb;
BEGIN
  IF v_me IS NULL OR NOT portal_is_admin() THEN RAISE EXCEPTION 'غير مصرّح — إدارة اللجنة للأدمن فقط'; END IF;
  IF p_members IS NULL OR jsonb_typeof(p_members) <> 'array' THEN RAISE EXCEPTION 'صيغة القائمة غير صالحة'; END IF;
  -- أبقِ فقط الأعضاء الذين هم مستخدمون نشطون (تجاهل أي اسم غير صالح) + إزالة التكرار.
  SELECT coalesce(jsonb_agg(DISTINCT u.username), '[]'::jsonb) INTO v_valid
    FROM jsonb_array_elements_text(p_members) m
    JOIN portal_users u ON u.username = m AND u.active;

  INSERT INTO portal_settings(key, value) VALUES ('committee_members', v_valid)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

  PERFORM portal_audit_write(NULL, 'committee_set', v_me, 'portal', jsonb_build_object('members', v_valid));
  RETURN jsonb_build_object('ok', true, 'members', v_valid);
END $fn$;
REVOKE ALL ON FUNCTION portal_set_committee(jsonb) FROM public;
GRANT EXECUTE ON FUNCTION portal_set_committee(jsonb) TO authenticated;


-- ═══ 014-sla-role-holders.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 014 — تصليب تصعيد SLA (م3/م4: فجوة approval-12 المؤكَّدة)
--  المشكلة: للمراحل المبنية على role_key (المالية/المشتريات) portal_resolve_stage
--  يعيد NULL، فكان التذكير يصل للأدمن فقط لا للمعتمِدين الفعليين. أيضاً الجدولة
--  كانت تعتمد pg_cron حصراً (إن لم تكن مفعّلة في المشروع فالتصعيد ميت).
--  الحلّ: (أ) عند غياب معتمِد محدَّد نُخطر كل حاملي role_key النشطين (مع التفويض).
--  (ب) الواجهة تستدعي portal_run_sla «كسولاً» عند تحميل مشتريات/أدمن — الخانق
--  الداخلي last_escalation_at يمنع التكرار، فالاستدعاء الكسول آمن ورخيص.
--  idempotent. شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 013.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_run_sla() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_req RECORD; v_stage portal_approvals%ROWTYPE; v_intended text; v_deleg text; v_cnt int := 0; v_h numeric := portal_sla_hours();
BEGIN
  FOR v_req IN SELECT * FROM portal_requests
      WHERE status = 'in_review' AND stage_due_at < now()
        AND (last_escalation_at IS NULL OR last_escalation_at < now() - make_interval(hours => v_h::int))
  LOOP
    SELECT * INTO v_stage FROM portal_approvals WHERE request_id = v_req.id AND decision = 'pending' ORDER BY seq ASC LIMIT 1;
    CONTINUE WHEN NOT FOUND;
    v_intended := portal_resolve_stage(v_req.id, v_stage);
    v_deleg := NULL;
    IF v_intended IS NOT NULL THEN
      SELECT delegate_to INTO v_deleg FROM portal_users WHERE username = v_intended AND is_away = true;
    END IF;

    IF v_intended IS NOT NULL THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        VALUES ('ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||v_intended,
                v_intended, 'system', 'تذكير: طلب متأخّر بانتظار اعتمادك', v_req.title, 'inbox')
        ON CONFLICT (id) DO NOTHING;
    ELSIF v_stage.role_key IS NOT NULL THEN
      -- مرحلة دور (مالية/مشتريات...): أخطر كل حاملي الصلاحية النشطين + مفوَّضي الغائبين منهم.
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||u.username,
               u.username, 'system', 'تذكير: طلب متأخّر بانتظار اعتماد مرحلتك ('||coalesce(v_stage.stage_label,'')||')', v_req.title, 'inbox'
        FROM portal_users u
        WHERE u.active AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
        ON CONFLICT (id) DO NOTHING;
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||u.delegate_to,
               u.delegate_to, 'system', 'تفويض: طلب متأخّر بانتظار اعتماد مرحلة ('||coalesce(v_stage.stage_label,'')||') بالنيابة', v_req.title, 'inbox'
        FROM portal_users u
        WHERE u.active AND u.is_away AND u.delegate_to IS NOT NULL
          AND coalesce((u.permissions ->> v_stage.role_key)::boolean, false)
        ON CONFLICT (id) DO NOTHING;
    END IF;
    IF v_deleg IS NOT NULL THEN
      INSERT INTO portal_notifications(id, recipient, type, title, body, link)
        VALUES ('ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||v_deleg,
                v_deleg, 'system', 'تفويض: طلب متأخّر بانتظار اعتمادك (بالنيابة)', v_req.title, 'inbox')
        ON CONFLICT (id) DO NOTHING;
    END IF;
    INSERT INTO portal_notifications(id, recipient, type, title, body, link)
      SELECT 'ntf_'||extract(epoch from now())::bigint||'_'||substr(md5(random()::text),1,6)||'_'||username,
             username, 'system', 'تصعيد SLA: طلب متأخّر', v_req.title, 'inbox'
      FROM portal_users WHERE role = 'admin' AND active = true
      ON CONFLICT (id) DO NOTHING;

    PERFORM set_config('app.portal_transition', '1', true);
    UPDATE portal_requests SET escalations = escalations + 1,
      escalated_at = coalesce(escalated_at, now()), last_escalation_at = now() WHERE id = v_req.id;
    PERFORM set_config('app.portal_transition', '0', true);
    PERFORM portal_audit_write(v_req.id, 'escalated', NULL, 'system', jsonb_build_object('intended', v_intended, 'stage_label', v_stage.stage_label));
    v_cnt := v_cnt + 1;
  END LOOP;
  RETURN v_cnt;
END $fn$;

-- الاستدعاء الكسول من الواجهة (مشتريات/أدمن): مقيَّد بصلاحية تشغيلية — ليس عاماً.
CREATE OR REPLACE FUNCTION portal_sla_tick() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_manage_procurement') OR portal_has_perm('can_disburse')) THEN
    RETURN 0;  -- صامت: لا خطأ في الواجهة لغير المخوَّلين
  END IF;
  RETURN portal_run_sla();
END $fn$;
REVOKE ALL ON FUNCTION portal_sla_tick() FROM public;
GRANT EXECUTE ON FUNCTION portal_sla_tick() TO authenticated;


-- ═══ 015-pending-approver-visibility.sql ═══
-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 015 — رؤية المعتمِد المنتظَر (إغلاق ثغرة حجب حقيقية من فحص السيناريوهات)
--  المشكلة المكتشفة: portal_can_see_request كانت تمنح الرؤية للمالك/القطاع/all/
--  «معتمِد شارك فعلاً» — لكن **المعتمِد المقصود للمرحلة المعلّقة** ذا النطاق own
--  (مدير قسم بلا وظيفة، مفوَّض موظف عن غائب، عضو لجنة موظف) لا يرى الطلب الذي
--  ينتظر اعتماده أصلاً، فلا يستطيع فتحه ولا اعتماده من الواجهة.
--  الحلّ: توسيع الرؤية لتشمل من تستهدفه أي مرحلة معلّقة في السلاسل الثلاث
--  (الحاجة/التعميد/أمر الشراء) مباشرةً أو تفويضاً — دون توسيع عام.
--  idempotent. شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 014.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_can_see_request(p_id text, p_requester text, p_dept text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    portal_is_admin()
    OR portal_my_scope() = 'all'
    OR p_requester = portal_username()
    OR (portal_my_scope() = 'sector' AND portal_my_sector() IS NOT NULL AND EXISTS (
          SELECT 1 FROM portal_departments d
           WHERE d.id = p_dept AND d.sector = portal_my_sector()))
    -- معتمِد شارك فعلاً في سلسلة الحاجة
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.approver = portal_username())
    -- (015) المعتمِد المقصود لمرحلة معلّقة في سلسلة الحاجة (مباشرة)
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND ( a.approver = portal_username()
                        OR (a.role_key IS NOT NULL AND portal_has_perm(a.role_key))
                        OR (a.resolver = 'dept_manager' AND EXISTS (
                              SELECT 1 FROM portal_departments d
                               WHERE d.id = p_dept AND d.manager_user = portal_username())) ))
    -- (015) المفوَّض عن معتمِد غائب لمرحلة معلّقة
    OR EXISTS (SELECT 1
                 FROM portal_approvals a
                 JOIN portal_users u ON u.is_away AND u.delegate_to = portal_username()
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND ( a.approver = u.username
                        OR (a.role_key IS NOT NULL AND coalesce((u.permissions ->> a.role_key)::boolean, false))
                        OR (a.resolver = 'dept_manager' AND EXISTS (
                              SELECT 1 FROM portal_departments d
                               WHERE d.id = p_dept AND d.manager_user = u.username)) ))
    -- (015) معتمِد معلّق في سلسلة اعتماد التعميد
    OR EXISTS (SELECT 1 FROM portal_award_approvals a
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND a.role_key IS NOT NULL AND portal_has_perm(a.role_key))
    -- (015) معتمِد معلّق في سلسلة أمر الشراء (صلاحية أو عضوية اللجنة المصغّرة)
    OR EXISTS (SELECT 1 FROM portal_po_approvals a
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND ( (a.role_key IS NOT NULL AND portal_has_perm(a.role_key))
                        OR (a.kind = 'committee' AND EXISTS (
                              SELECT 1 FROM portal_settings s
                               WHERE s.key = 'committee_members' AND s.value ? portal_username())) ));
$fn$;


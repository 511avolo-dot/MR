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

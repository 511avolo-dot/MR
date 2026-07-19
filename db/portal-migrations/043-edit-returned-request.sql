-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 043 — تعديل الطلب المُعاد للتصحيح (سدّ ثغرة «الإعادة الذكية») — بعد 042
--  المشروع: mwbjoysuybgbrvfrprex (البوابة، نظام 3). idempotent — مدمجة في standalone.
--
--  الثغرة (من ملاحظة المالك، مؤكَّدة بالكود): عند إرجاع طلب للمقدّم «للتعديل»، لم تكن
--  توجد أي دالة لتعديل محتواه فعلاً — `portal_resubmit_request` تُعيد بناء السلسلة فقط
--  بلا استقبال بنود/ملاحظة معدَّلة. فالإرجاع للتعديل كان بلا معنى.
--
--  الحلّ (قرار المالك): `portal_update_request` — يعدّل محتوى الطلب:
--   • الصلاحية: المقدّم أو حامل can_edit (المشتريات نيابةً) أو أدمن.
--   • الحالة: `returned` فقط. ملاحظة حوكمية: الطلب لا يبلغ `returned` إلا **قبل التعميد**
--     (إرجاع اعتماد الحاجة p_return_to_seq=0، أو bounce التسعير) — أمّا بعد التعميد فكل
--     الإرجاعات تذهب للمشتريات لا للمقدّم (منع الإرجاع الجذري بعد التعميد). فالقيد على
--     `returned` يضمن تلقائياً عدم تعديل المحتوى بعد اعتماد التعميد.
--   • يعيد التحقّق والحساب كالإنشاء تماماً (الإجمالي/عدد العروض/علم التجزئة).
--   • يستبدل البنود (طور ما قبل الاستلام — received_qty=0، آمن؛ العروض إن وُجدت من جولة
--     تسعير سابقة تكون superseded أصلاً).
--   • **يُصفّر كل اعتمادات الحاجة** (تغيّر المحتوى ⇒ إعادة اعتماد كاملة، لا اعتماد على
--     محتوى قديم) + عدّاد مراجعة `revision` + تدقيق `request_edited`.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS revision int NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION portal_update_request(
    p_request_id text, p_title text, p_items jsonb, p_project text, p_priority text,
    p_need_by date, p_proc_type text DEFAULT 'normal',
    p_justification text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_req portal_requests%ROWTYPE;
  v_item jsonb; v_seq int := 0; v_est numeric := 0;
  v_q numeric; v_p numeric; v_quotes int;
  v_win_days numeric; v_thr numeric; v_cluster_sum numeric; v_peers int; v_all_below boolean;
  v_split boolean := false; v_rev int;
  MAXQ CONSTANT numeric := 1000000; MAXP CONSTANT numeric := 100000000;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT * INTO v_req FROM portal_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;

  -- الصلاحية: المقدّم أو حامل can_edit أو أدمن.
  IF NOT (v_req.requester = v_me OR portal_has_perm('can_edit') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'تعديل الطلب يقتصر على مُقدّمه أو حامل صلاحية «تعديل الطلبات»';
  END IF;
  -- الحالة: مُعاد للتصحيح فقط (يضمن تلقائياً «ما قبل التعميد»).
  IF v_req.status <> 'returned' THEN
    RAISE EXCEPTION 'لا يُعدَّل إلا طلب مُعاد للتصحيح (الحالة الحالية: %)', v_req.status;
  END IF;

  -- تحقّق المدخلات (مطابق لـ portal_create_request).
  IF coalesce(trim(p_title),'')   = '' THEN RAISE EXCEPTION 'اكتب وصف الطلب'; END IF;
  IF coalesce(trim(p_project),'') = '' THEN RAISE EXCEPTION 'اسم المشروع مطلوب'; END IF;
  IF p_need_by IS NULL THEN RAISE EXCEPTION 'تاريخ التوريد المطلوب مطلوب'; END IF;
  IF coalesce(p_proc_type,'normal') NOT IN ('normal','single','emergency') THEN RAISE EXCEPTION 'نوع شراء غير صالح'; END IF;
  IF coalesce(p_proc_type,'normal') <> 'normal' AND coalesce(trim(p_justification),'') = '' THEN
    RAISE EXCEPTION 'التبرير مطلوب لهذا النوع من الشراء';
  END IF;
  IF jsonb_array_length(coalesce(p_items,'[]'::jsonb)) < 1 THEN RAISE EXCEPTION 'أضِف بنداً واحداً على الأقل'; END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF coalesce(trim(v_item->>'desc'),'') = '' THEN RAISE EXCEPTION 'وصف كل بند مطلوب'; END IF;
    IF jsonb_typeof(v_item->'qty') <> 'number' OR jsonb_typeof(coalesce(v_item->'price','0'::jsonb)) <> 'number' THEN
      RAISE EXCEPTION 'كمية/سعر غير رقمي في: %', v_item->>'desc';
    END IF;
    v_q := (v_item->>'qty')::numeric; v_p := coalesce((v_item->>'price')::numeric,0);
    IF v_q <= 0 OR v_q > MAXQ THEN RAISE EXCEPTION 'كمية غير منطقية في: %', v_item->>'desc'; END IF;
    IF v_p < 0 OR v_p > MAXP THEN RAISE EXCEPTION 'سعر غير منطقي في: %', v_item->>'desc'; END IF;
    v_est := v_est + v_q * v_p;
  END LOOP;

  -- عدد العروض المطلوب (حسب النوع/الشريحة) — نفس منطق الإنشاء.
  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    v_quotes := 1;
  ELSE
    SELECT quotes_required INTO v_quotes FROM portal_doa
      WHERE max_value IS NULL OR v_est <= max_value ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
    v_quotes := coalesce(v_quotes, 3);
  END IF;

  -- علم التجزئة (النمط الكلاسيكي — نفس منطق الإنشاء، مع استثناء الطلب نفسه من العنقود).
  IF portal_setting_bool('split_guard', true) THEN
    v_thr := portal_setting_num('split_threshold', 100000);
    v_win_days := portal_setting_num('split_window_days', 7);
    SELECT count(*), coalesce(sum(est_total),0), coalesce(bool_and(est_total < v_thr), true)
      INTO v_peers, v_cluster_sum, v_all_below
      FROM portal_requests
      WHERE department_id = v_req.department_id AND status <> 'rejected' AND id <> p_request_id
        AND created_at >= now() - make_interval(days => v_win_days::int)
        AND created_at <= now() + make_interval(days => v_win_days::int);
    IF v_peers > 0 AND (v_cluster_sum + v_est) >= v_thr AND v_all_below AND v_est < v_thr THEN v_split := true; END IF;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);

  -- استبدال البنود.
  DELETE FROM portal_request_items WHERE request_id = p_request_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_seq := v_seq + 1;
    INSERT INTO portal_request_items (request_id, seq, description, unit, qty, unit_price)
      VALUES (p_request_id, v_seq, v_item->>'desc', v_item->>'unit', (v_item->>'qty')::numeric, coalesce((v_item->>'price')::numeric, 0));
  END LOOP;

  -- تحديث رأس الطلب + عدّاد المراجعة.
  UPDATE portal_requests SET
    title = trim(p_title), project = trim(p_project), priority = coalesce(nullif(p_priority,''), 'متوسط'),
    need_by = p_need_by, proc_type = coalesce(p_proc_type,'normal'),
    justification = nullif(trim(coalesce(p_justification,'')),''), note = nullif(trim(coalesce(p_note,'')),''),
    est_total = v_est, quotes_required = v_quotes, split_flag = v_split,
    revision = coalesce(revision,0) + 1, updated_at = now(), updated_by = v_me
  WHERE id = p_request_id
  RETURNING revision INTO v_rev;

  -- تصفير كل اعتمادات الحاجة (تغيّر المحتوى ⇒ إعادة اعتماد كاملة).
  UPDATE portal_approvals SET decision = 'pending', approver = NULL, comment = NULL, acted_at = NULL, channel = 'portal'
    WHERE request_id = p_request_id;

  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(p_request_id, 'request_edited', v_me, 'portal',
    jsonb_build_object('new_total', v_est, 'items', jsonb_array_length(p_items), 'revision', v_rev, 'split_flag', v_split));
  RETURN jsonb_build_object('ok', true, 'est_total', v_est, 'quotes_required', v_quotes, 'split_flag', v_split, 'revision', v_rev);
END $fn$;
REVOKE ALL ON FUNCTION portal_update_request(text, text, jsonb, text, text, date, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION portal_update_request(text, text, jsonb, text, text, date, text, text, text) TO authenticated;

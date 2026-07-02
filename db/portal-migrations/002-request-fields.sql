-- ════════════════════════════════════════════════════════════════════════
--  Migration 002 — إكمال نموذج رفع الطلب (المرحلة 2 — سيناريو 6-1)
-- ════════════════════════════════════════════════════════════════════════
--  المصدر: «الملف الشامل المتكامل» سيناريو 6-1 (submitRequest) حرفياً:
--   • اسم المشروع وتاريخ التوريد إلزاميان.
--   • نوع الشراء normal/single/emergency — التبرير إلزامي لغير العادي.
--   • حدود منطقية للكميات والأسعار (MAXQ=1,000,000 / MAXP=100,000,000).
--   • القطاع يُشتق من ملف الموظف — لا يُقبل قسم مختلف من غير الأدمن.
--   • عدد العروض المطلوب: single/emergency → 1 (يتجاوز DoA)، وإلا حسب DoA.
--  آمن لإعادة التشغيل بالكامل (idempotent).
-- ════════════════════════════════════════════════════════════════════════

-- 1) الأعمدة الجديدة
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS project TEXT;
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS need_by DATE;
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS justification TEXT;
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS note TEXT;
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS split_flag BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE portal_requests ADD COLUMN IF NOT EXISTS quotes_required INT;

-- 2) دالة الإنشاء المحدّثة — التوقيع القديم يبقى للتوافق الخلفي (يفوّض للجديد
--    بقيم فارغة سترفضها الإلزامات الجديدة — قصداً: لا مسار التفافي حول الحقول).
CREATE OR REPLACE FUNCTION portal_create_request(
    p_title text, p_department_id text, p_priority text, p_items jsonb,
    p_project text, p_need_by date, p_proc_type text DEFAULT 'normal',
    p_justification text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_my_dept text;
  v_dept text;
  v_id text;
  v_item jsonb;
  v_seq int := 0;
  v_est numeric := 0;
  v_name text;
  v_q numeric; v_p numeric;
  v_quotes int;
  MAXQ CONSTANT numeric := 1000000;      -- حد الكمية المنطقي (المرجع 6-1)
  MAXP CONSTANT numeric := 100000000;    -- حد السعر المنطقي (المرجع 6-1)
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (portal_has_perm('can_create') OR portal_is_admin()) THEN
    RAISE EXCEPTION 'رفع الطلبات يتطلّب صلاحية «رفع الطلبات» — راجع الإدارة لإسناد وظيفة';
  END IF;
  IF coalesce(trim(p_title), '') = '' THEN RAISE EXCEPTION 'اكتب وصف الطلب'; END IF;
  IF coalesce(trim(p_project), '') = '' THEN RAISE EXCEPTION 'اسم المشروع مطلوب'; END IF;
  IF p_need_by IS NULL THEN RAISE EXCEPTION 'تاريخ التوريد المطلوب مطلوب'; END IF;
  IF coalesce(p_proc_type,'normal') NOT IN ('normal','single','emergency') THEN
    RAISE EXCEPTION 'نوع شراء غير صالح';
  END IF;
  IF coalesce(p_proc_type,'normal') <> 'normal' AND coalesce(trim(p_justification),'') = '' THEN
    RAISE EXCEPTION 'التبرير مطلوب لهذا النوع من الشراء';
  END IF;

  -- القطاع يُشتق من ملف الموظف (المرجع: الموظف لا يختار القطاع). الأدمن فقط
  -- يستطيع الرفع نيابةً عن قسم آخر (تشغيل/إعداد).
  SELECT department_id INTO v_my_dept FROM portal_users WHERE username = v_me;
  v_dept := CASE
    WHEN portal_is_admin() AND coalesce(p_department_id,'') <> '' THEN p_department_id
    ELSE coalesce(v_my_dept, p_department_id)
  END;
  IF coalesce(v_dept,'') = '' THEN RAISE EXCEPTION 'لا قسم في ملفك — راجع الإدارة'; END IF;
  IF NOT portal_is_admin() AND coalesce(p_department_id,'') <> '' AND p_department_id <> v_dept THEN
    RAISE EXCEPTION 'القطاع يُحدَّد تلقائياً من ملفك — لا يمكن اختيار قسم آخر';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = v_dept AND active) THEN
    RAISE EXCEPTION 'قطاعك مغلق حالياً لاستقبال الطلبات — راجع الإدارة';
  END IF;

  IF jsonb_array_length(coalesce(p_items, '[]'::jsonb)) < 1 THEN RAISE EXCEPTION 'أضِف بنداً واحداً على الأقل'; END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF coalesce(trim(v_item->>'desc'), '') = '' THEN RAISE EXCEPTION 'وصف كل بند مطلوب'; END IF;
    v_q := coalesce((v_item->>'qty')::numeric, 0);
    v_p := coalesce((v_item->>'price')::numeric, 0);
    IF v_q <= 0 OR v_q > MAXQ THEN RAISE EXCEPTION 'كمية غير منطقية في: %', v_item->>'desc'; END IF;
    IF v_p < 0 OR v_p > MAXP THEN RAISE EXCEPTION 'سعر غير منطقي في: %', v_item->>'desc'; END IF;
    v_est := v_est + v_q * v_p;
  END LOOP;

  -- عدد العروض المطلوب: الاستثنائي عرض واحد (مبرَّر)، وإلا حسب شريحة DoA للقيمة التقديرية.
  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    v_quotes := 1;
  ELSE
    SELECT quotes_required INTO v_quotes FROM portal_doa
      WHERE max_value IS NULL OR v_est <= max_value
      ORDER BY priority ASC, max_value ASC NULLS LAST LIMIT 1;
    v_quotes := coalesce(v_quotes, 3);
  END IF;

  v_id := 'REQ-' || to_char(now(), 'YYYYMMDD') || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
  SELECT display_name INTO v_name FROM portal_users WHERE username = v_me;

  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_requests (id, title, department_id, requester, requester_name, priority,
                               est_total, created_by, project, need_by, proc_type, justification, note, quotes_required)
    VALUES (v_id, trim(p_title), v_dept, v_me, v_name, coalesce(nullif(p_priority, ''), 'متوسط'),
            v_est, v_me, trim(p_project), p_need_by, coalesce(p_proc_type,'normal'),
            nullif(trim(coalesce(p_justification,'')),''), nullif(trim(coalesce(p_note,'')),''), v_quotes);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_seq := v_seq + 1;
    INSERT INTO portal_request_items (request_id, seq, description, unit, qty, unit_price)
      VALUES (v_id, v_seq, v_item->>'desc', v_item->>'unit', (v_item->>'qty')::numeric, coalesce((v_item->>'price')::numeric, 0));
  END LOOP;
  PERFORM set_config('app.portal_transition', '0', true);

  IF coalesce(p_proc_type,'normal') <> 'normal' THEN
    PERFORM portal_audit_write(v_id, 'proc_type', v_me, 'portal',
      jsonb_build_object('type', p_proc_type, 'justification', p_justification));
  END IF;

  RETURN portal_submit_request(v_id) || jsonb_build_object('id', v_id, 'quotes_required', v_quotes);
END $fn$;

-- 3) التوقيع القديم (4 معاملات) يُحذف — كان بلا الحقول الإلزامية الجديدة، وبقاؤه
--    يفتح مسار التفاف يرفع طلبات بلا مشروع/تاريخ. الواجهة تستدعي التوقيع الكامل.
DROP FUNCTION IF EXISTS portal_create_request(text, text, text, jsonb);

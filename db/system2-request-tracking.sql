-- ════════════════════════════════════════════════════════════════════════════
--  الطلبات: **متابعة لا وورك فلو** — تصحيح نموذج بقرار المالك (2026-09-10)
-- ----------------------------------------------------------------------------
--  توجيه المالك حرفيّاً: «نظام بسيط وليس وورك فلو، عشان نتابع بعض ولا نضيّع
--  المعلومات أو ننسى أو تتلخبط. ما في مواضيع اعتمادات وقصص طويلة — إلا أن
--  نمكّنهم من رفع الطلب PDF موقَّع من المدير، ويتابعون الطلب بدون نجيهم أو
--  يجونا. والعروض والمقارنة طبعاً برّا السستم، ورفعنا أمر الشراء يظهر لهم
--  ونقدر نربط الأمر بالطلب: هذا الطلب صدر له أمر رقم كذا. وخلاص متابعة.»
--
--  فالاعتماد يقع **على الورق خارج النظام**، ودليله مرفق PDF موقَّع؛ والنظام
--  يحفظ الدليل ويتابع الحالة ويربط الطلب بأمر الشراء. لا سلسلة اعتماد
--  إلكترونية، ولا مراحل معتمِدين، ولا حاجة لضبط مدراء الأقسام.
--
--  ⚠️ تُطبَّق بعد `db/system2-request-flow.sql`.
--  إضافيّة وidempotent. **لا تحذف أي جدول ولا صفّاً**: جداول الاعتماد تبقى
--  كما هي (فارغة) فيمكن إحياء المسار لاحقاً بلا هجرة عكسية.
-- ════════════════════════════════════════════════════════════════════════════

-- ═══════════════ 1) دليل الاعتماد الورقيّ: مرفق الطلب ═══════════════
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS doc_key  TEXT;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS doc_name TEXT;
COMMENT ON COLUMN proc_purchase_requests.doc_key IS
  'مفتاح R2 لمرفق الطلب الموقَّع من المدير — دليل الاعتماد الورقيّ (docs/pr/<pr_id>/…)';

-- ═══════════════ 2) إطفاء سلسلة الاعتماد الإلكترونية ═══════════════
-- ⚠️ تعطيل لا حذف: البذرة تبقى في الجدول فيُستأنف المسار بضبط active=true
-- إن قرّر المالك يوماً. `prMatchRule` في الواجهة تُصفّي `active !== false`.
-- ⚠️ `proc_config_guard` يحرس مسار الموافقات والأقسام: أي تعديل يتطلّب هوية
-- إدارية أو خدمية. نرفع هوية الخدمة **محصورةً بالمعاملة** (`is_local=true`)
-- فتُصفَّر تلقائياً عند انتهائها — لا تسرّب صلاحية خارج هذه الهجرة.
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
UPDATE proc_approval_rules SET active = false WHERE active IS DISTINCT FROM false;
SELECT set_config('request.jwt.claims', '', true);

-- ═══════════════ 3) مراحل المتابعة (لا مراحل اعتماد) ═══════════════
--  (فارغ/received) = وصل المشتريات
--   → in_progress      = بدأ العمل (طلب العروض والمقارنة خارج النظام)
--   → quotes_collected = اكتمل جمع العروض   [اختيارية — يجوز تخطّيها]
--   → po_issued        = صدر أمر الشراء     [تُضبط تلقائياً عند الربط]
--   → closed           = مُقفل
CREATE OR REPLACE FUNCTION pr_proc_stage(p_pr_id text, p_stage text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_name text; v_pr proc_purchase_requests%ROWTYPE;
  v_cur text; v_at timestamptz := now();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_stage NOT IN ('in_progress','quotes_collected','po_issued','closed') THEN
    RAISE EXCEPTION 'مرحلة غير صالحة';
  END IF;
  IF NOT (pr_has_perm('can_manage_rfq') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'معالجة الطلب تتطلّب صلاحية المشتريات';
  END IF;

  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id = p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  -- ⚠️ `submitted` هي حالة الطلب المُرسَل في نموذج المتابعة؛ و`approved` تُقبل
  -- للتوافق مع أي طلب قديم مرّ بسلسلة اعتماد قبل هذا التصحيح.
  IF v_pr.status NOT IN ('submitted','approved') THEN
    RAISE EXCEPTION 'الطلب ليس في وضع المتابعة (حالته: %)', coalesce(v_pr.status,'—');
  END IF;

  v_cur := coalesce(nullif(v_pr.proc_status,''), 'received');
  -- تقدّم للأمام فقط: لا يُعاد الطلب لمرحلة سابقة فيُمحى أثر من عمل عليه.
  IF (v_cur = 'received'         AND p_stage <> 'in_progress')
  OR (v_cur = 'in_progress'      AND p_stage NOT IN ('quotes_collected','po_issued'))
  OR (v_cur = 'quotes_collected' AND p_stage <> 'po_issued')
  OR (v_cur = 'po_issued'        AND p_stage <> 'closed')
  OR (v_cur = 'closed') THEN
    RAISE EXCEPTION 'انتقال غير مسموح: % ← %', v_cur, p_stage;
  END IF;
  -- «صدر أمر الشراء» حقيقةٌ يثبتها الربط لا زرّ: تمرّ حصراً عبر pr_link_po.
  IF p_stage = 'po_issued' AND coalesce(v_pr.po_number,'') = '' THEN
    RAISE EXCEPTION 'اربط الطلب بأمر الشراء أولاً (pr_link_po)';
  END IF;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  v_name := coalesce(v_name, v_me);

  UPDATE proc_purchase_requests SET
    proc_status         = p_stage,
    proc_started_by     = CASE WHEN p_stage='in_progress'      THEN v_me ELSE proc_started_by END,
    proc_started_at     = CASE WHEN p_stage='in_progress'      THEN v_at ELSE proc_started_at END,
    quotes_collected_by = CASE WHEN p_stage='quotes_collected' THEN v_me ELSE quotes_collected_by END,
    quotes_collected_at = CASE WHEN p_stage='quotes_collected' THEN v_at ELSE quotes_collected_at END,
    updated_by = v_me, updated_at = v_at
  WHERE id = p_pr_id;

  RETURN jsonb_build_object('ok', true, 'stage', p_stage, 'by', v_name, 'at', v_at);
END $fn$;

-- ═══════════════ 4) ربط الطلب بأمر الشراء ═══════════════
-- جوهر المتابعة: «هذا الطلب صدر له أمر رقم كذا». الرقم **يُتحقَّق من وجوده**
-- في `proc_purchase_orders` فلا يُكتب رقم ملفَّق أو بكتابة مختلفة يكسر الربط.
CREATE OR REPLACE FUNCTION pr_link_po(p_pr_id text, p_po_number text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_name text; v_pr proc_purchase_requests%ROWTYPE;
  v_po text := btrim(coalesce(p_po_number,'')); v_old text; v_at timestamptz := now();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (pr_has_perm('can_manage_rfq') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'ربط أمر الشراء يتطلّب صلاحية المشتريات';
  END IF;
  IF v_po = '' THEN RAISE EXCEPTION 'رقم أمر الشراء مطلوب'; END IF;
  IF NOT EXISTS (SELECT 1 FROM proc_purchase_orders WHERE po_number = v_po) THEN
    RAISE EXCEPTION 'أمر الشراء % غير موجود في النظام', v_po;
  END IF;

  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id = p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_pr.status = 'draft' THEN RAISE EXCEPTION 'لا يُربط أمر شراء بمسودّة'; END IF;
  v_old := v_pr.po_number;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  v_name := coalesce(v_name, v_me);

  UPDATE proc_purchase_requests
     SET po_number = v_po,
         -- الربط نفسه هو ما يُثبت «صدر أمر الشراء» (لا يتراجع عن closed)
         proc_status = CASE WHEN coalesce(proc_status,'') = 'closed' THEN proc_status
                            ELSE 'po_issued' END,
         updated_by = v_me, updated_at = v_at
   WHERE id = p_pr_id;

  INSERT INTO proc_audit_log (username, display_name, action, entity_type, entity_id,
                              old_value, new_value)
  VALUES (v_me, v_name, CASE WHEN v_old IS NULL THEN 'pr_link_po' ELSE 'pr_relink_po' END,
          'pr', p_pr_id,
          CASE WHEN v_old IS NULL THEN NULL ELSE jsonb_build_object('po_number', v_old) END,
          jsonb_build_object('po_number', v_po));

  RETURN jsonb_build_object('ok', true, 'po_number', v_po, 'previous', v_old,
                            'by', v_name, 'at', v_at);
END $fn$;

-- فكّ الربط (تصحيح خطأ) — بنفس الصلاحية وبأثر تدقيق، ويُعيد المرحلة لما قبلها.
CREATE OR REPLACE FUNCTION pr_unlink_po(p_pr_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := proc_me(); v_name text; v_old text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (pr_has_perm('can_manage_rfq') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'فكّ الربط يتطلّب صلاحية المشتريات';
  END IF;
  SELECT po_number INTO v_old FROM proc_purchase_requests WHERE id = p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF coalesce(v_old,'') = '' THEN RAISE EXCEPTION 'لا يوجد أمر مرتبط'; END IF;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  v_name := coalesce(v_name, v_me);
  UPDATE proc_purchase_requests
     SET po_number = NULL,
         proc_status = CASE WHEN proc_status = 'po_issued' THEN 'in_progress' ELSE proc_status END,
         updated_by = v_me, updated_at = now()
   WHERE id = p_pr_id;

  INSERT INTO proc_audit_log (username, display_name, action, entity_type, entity_id, old_value)
  VALUES (v_me, v_name, 'pr_unlink_po', 'pr', p_pr_id, jsonb_build_object('po_number', v_old));
  RETURN jsonb_build_object('ok', true, 'previous', v_old);
END $fn$;

-- ═══════════════ 5) مرفق الطلب: تسجيل المفتاح بعد رفعه ═══════════════
-- المفتاح يُولَّد خادميّاً في `/api/pr-doc`؛ هذه تثبّته على الصفّ بحارس ملكية،
-- وتقيّده بمجال الطلب نفسه فلا يُلفَّق مفتاحٌ يشير لمرفق طلب آخر.
CREATE OR REPLACE FUNCTION pr_set_doc(p_pr_id text, p_key text, p_name text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := proc_me(); v_req text; v_st text; v_old text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  SELECT requester, status, doc_key INTO v_req, v_st, v_old
    FROM proc_purchase_requests WHERE id = p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF NOT (lower(coalesce(v_req,'')) = lower(v_me)
          OR pr_has_perm('can_manage_rfq') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'المرفق يرفعه مقدّم الطلب أو المشتريات';
  END IF;
  IF p_key IS NOT NULL AND p_key NOT LIKE ('docs/pr/' || p_pr_id || '/%') THEN
    RAISE EXCEPTION 'مفتاح المرفق خارج مجال هذا الطلب';
  END IF;

  UPDATE proc_purchase_requests
     SET doc_key = p_key, doc_name = p_name, updated_by = v_me, updated_at = now()
   WHERE id = p_pr_id;

  INSERT INTO proc_audit_log (username, action, entity_type, entity_id, old_value, new_value)
  VALUES (v_me, 'pr_doc_set', 'pr', p_pr_id,
          CASE WHEN v_old IS NULL THEN NULL ELSE jsonb_build_object('doc_key', v_old) END,
          jsonb_build_object('doc_key', p_key, 'doc_name', p_name));
  RETURN jsonb_build_object('ok', true, 'doc_key', p_key);
END $fn$;

REVOKE ALL ON FUNCTION pr_link_po(text, text)          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_unlink_po(text)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_set_doc(text, text, text)    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_link_po(text, text)       TO authenticated;
GRANT EXECUTE ON FUNCTION pr_unlink_po(text)           TO authenticated;
GRANT EXECUTE ON FUNCTION pr_set_doc(text, text, text) TO authenticated;

-- ═══════════════ التراجع (للطوارئ) ═══════════════
/*
UPDATE proc_approval_rules SET active = true;   -- إحياء سلسلة الاعتماد
DROP FUNCTION IF EXISTS pr_link_po(text, text);
DROP FUNCTION IF EXISTS pr_unlink_po(text);
DROP FUNCTION IF EXISTS pr_set_doc(text, text, text);
-- الأعمدة تُترك (بلا ضرر): doc_key / doc_name
*/

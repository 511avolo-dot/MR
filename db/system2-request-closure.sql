-- ════════════════════════════════════════════════════════════════════════════
--  إقفال دورة طلب الشراء: إلغاء · إقفال بالاستلام · أرشفة
--  ---------------------------------------------------------------------------
--  طلب المالك (2026-09-14): «إلغاء الطلب في حال تكنسل · أرشفة الطلبات بعد
--  إقفالها · ربطها بأمر ومن ثم إقفاله باستلام كامل، وفي حال إغلاق أمر الشراء
--  باستلام كامل يُغلق الطلب بالاستلام أيضاً».
--
--  القياس قبل البناء أثبت أنّ الثلاثة **غير موجودة**:
--    · لا دالّة إلغاء إطلاقاً — الحالة 'cancelled' مذكورة في الواجهة فقط
--      (index.html:12923, 13782) ولا شيء يضبطها.
--    · لا أرشفة للطلبات.
--    · `po_record_receipt` لا تمسّ `proc_purchase_requests` بحرف واحد، فأمر
--      شراء يبلغ «تسليم كامل» يترك طلبه معلّقاً في 'ordered' إلى الأبد.
--  و`closed_by`/`closed_at` موجودان في الجدول منذ هجرة الموديل **ولا أحد يكتبهما**.
--
--  ⚠️ يُطبَّق بعد db/system2-purchase-request-workspace.sql.
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ───────────────────────────── الأرشفة (أعمدة) ─────────────────────────────
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS archived_by text;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS cancel_reason text;

-- فهرس القائمة النشطة: الأرشيف يُستبعَد من الطابور الافتراضيّ.
CREATE INDEX IF NOT EXISTS idx_proc_pr_active_queue
  ON proc_purchase_requests(workflow_state) WHERE archived_at IS NULL;

-- ⚠️ العمودان الجديدان يحملان أثراً حوكميّاً لا صلاحية، لكنّ حارس المستخدمين
-- ليس معنيّاً بهما — المعنيّ هو أنّ الكتابة المباشرة على الطلبات مسحوبة أصلاً
-- (REVOKE INSERT/UPDATE في هجرة الموديل)، فلا سبيل إليهما إلا عبر الدوال أدناه.

-- ═══════════════════════════ ② إلغاء الطلب ═══════════════════════════
-- من يُلغي: المقدّم لطلبه **قبل** صدور أمر شراء · أو المشتريات/الأدمن في أي وقت
-- قبل الإقفال. السبب إلزاميّ (يظهر في المسار وسجلّ التدقيق).
CREATE OR REPLACE FUNCTION pr_cancel_request(p_pr_id text, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_pr proc_purchase_requests%ROWTYPE;
  v_reason text := btrim(coalesce(p_reason,'')); v_now timestamptz := now();
  v_owner boolean; v_proc boolean; v_links int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF length(v_reason) < 3 THEN RAISE EXCEPTION 'سبب الإلغاء مطلوب'; END IF;

  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id = p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;

  IF v_pr.status = 'cancelled' THEN RAISE EXCEPTION 'الطلب ملغى مسبقاً'; END IF;
  -- ⚠️ المُقفَل لا يُلغى: البضاعة استُلمت فعلاً. التصحيح بعده يكون بمرتجع
  -- على أمر الشراء لا بإلغاء الطلب (نفس قاعدة البوابة في portal_payment_void).
  IF v_pr.status = 'closed' OR v_pr.workflow_state = 'closed' THEN
    RAISE EXCEPTION 'لا يُلغى طلب مُقفَل باستلام — استعمل مرتجعاً على أمر الشراء';
  END IF;

  v_owner := lower(coalesce(v_pr.requester,'')) = lower(v_me);
  v_proc  := pr_has_module_perm('pr_manage_pricing') OR pr_is_admin();

  IF NOT v_proc THEN
    IF NOT v_owner THEN RAISE EXCEPTION 'لا تملك صلاحية إلغاء هذا الطلب'; END IF;
    -- المقدّم يُلغي ما لم يصدر له أمر شراء بعد؛ بعدها القرار للمشتريات.
    IF v_pr.workflow_state IN ('ordered','partially_ordered') THEN
      RAISE EXCEPTION 'صدر أمر شراء لهذا الطلب — الإلغاء من المشتريات';
    END IF;
  END IF;

  -- فكّ روابط أوامر الشراء النشطة كي لا يبقى أمر منسوباً لطلب ملغى.
  UPDATE proc_pr_po_links
     SET active=false, unlinked_by=v_me, unlinked_at=v_now,
         note = concat_ws(' · ', note, 'إلغاء الطلب: ' || v_reason)
   WHERE pr_id = p_pr_id AND active;
  GET DIAGNOSTICS v_links = ROW_COUNT;

  -- تُصفَّر المراحل المعلّقة فلا يبقى قرار منتظَر على طلب ملغى.
  UPDATE proc_pr_approvals
     SET decision='cancelled', comment=coalesce(comment, v_reason), acted_at=v_now
   WHERE pr_id = p_pr_id AND decision='pending';

  PERFORM set_config('app.pr_transition','1',true);
  UPDATE proc_purchase_requests
     SET status='cancelled', workflow_state='cancelled', current_seq=0,
         current_owner=NULL, cancel_reason=v_reason,
         updated_by=v_me, updated_at=v_now
   WHERE id = p_pr_id;

  INSERT INTO proc_audit_log(username, action, entity_type, entity_id, new_value)
  VALUES (v_me,'pr_cancelled','pr',p_pr_id,
          jsonb_build_object('reason',v_reason,'unlinked_pos',v_links,'from',v_pr.workflow_state));
  INSERT INTO proc_pr_audit(pr_id, event, actor, channel, detail)
  VALUES (p_pr_id,'cancelled',v_me,'portal',
          jsonb_build_object('reason',v_reason,'unlinked_pos',v_links));

  RETURN jsonb_build_object('ok',true,'id',p_pr_id,'unlinked_pos',v_links);
END $fn$;

-- ═══════════════ ⑤ إقفال الطلب عند اكتمال استلام أوامره ═══════════════
-- يُقفَل الطلب **فقط** حين تبلغ **كل** أوامره المرتبطة النشطة «تسليم كامل».
-- طلبٌ مرتبط بأمرين ونصفُ بنوده في الثاني لا يُقفَل باستلام الأول — وهذا
-- جوهر الصحّة هنا.
CREATE OR REPLACE FUNCTION pr_close_from_po(p_po_number text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_pr text; v_n int := 0; v_pending int; v_now timestamptz := now();
BEGIN
  FOR v_pr IN
    SELECT DISTINCT l.pr_id FROM proc_pr_po_links l
     WHERE l.active AND l.po_number = btrim(coalesce(p_po_number,''))
  LOOP
    -- هل بقي أمر مرتبط بهذا الطلب لم يبلغ التسليم الكامل؟
    SELECT count(*) INTO v_pending
      FROM proc_pr_po_links l2
      JOIN proc_purchase_orders o ON o.po_number = l2.po_number
     WHERE l2.pr_id = v_pr AND l2.active
       AND coalesce(o.status,'') <> 'تسليم كامل';
    CONTINUE WHEN v_pending > 0;

    PERFORM set_config('app.pr_transition','1',true);
    UPDATE proc_purchase_requests
       SET workflow_state='closed', status='closed', proc_status='closed',
           current_seq=0, current_owner=NULL,
           closed_by=coalesce(proc_me(),'system'), closed_at=v_now,
           -- ③ الأرشفة تلقائيّة عند الإقفال: الطلب المُقفَل يخرج من الطابور
           --    ويبقى كاملاً في الأرشيف بلا حذف.
           archived_at=coalesce(archived_at, v_now),
           archived_by=coalesce(archived_by, coalesce(proc_me(),'system')),
           updated_by=coalesce(proc_me(),'system'), updated_at=v_now
     WHERE id = v_pr AND coalesce(workflow_state,'') <> 'closed';

    IF FOUND THEN
      v_n := v_n + 1;
      INSERT INTO proc_audit_log(username, action, entity_type, entity_id, new_value)
      VALUES (coalesce(proc_me(),'system'),'pr_closed_by_receipt','pr',v_pr,
              jsonb_build_object('po_number',p_po_number));
      INSERT INTO proc_pr_audit(pr_id, event, actor, channel, detail)
      VALUES (v_pr,'closed_by_receipt',coalesce(proc_me(),'system'),'system',
              jsonb_build_object('po_number',p_po_number));
    END IF;
  END LOOP;
  RETURN v_n;
END $fn$;

-- ⚠️ مُشغِّل لا نداء داخل po_record_receipt: حالة أمر الشراء تتغيّر من عدّة
-- مسارات (الاستلام عبر RPC · تغيير المرحلة من الدرج · الاستيراد · المزامنة)،
-- فالمُشغِّل يلتقطها كلّها ولا يعتمد على تعديل دالّة بعينها.
CREATE OR REPLACE FUNCTION proc_po_receipt_closes_pr() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF coalesce(NEW.status,'') = 'تسليم كامل'
     AND coalesce(OLD.status,'') IS DISTINCT FROM coalesce(NEW.status,'') THEN
    PERFORM pr_close_from_po(NEW.po_number);
  END IF;
  RETURN NULL;
END $fn$;

DROP TRIGGER IF EXISTS trg_po_receipt_closes_pr ON proc_purchase_orders;
CREATE TRIGGER trg_po_receipt_closes_pr
  AFTER UPDATE OF status ON proc_purchase_orders
  FOR EACH ROW EXECUTE FUNCTION proc_po_receipt_closes_pr();

-- ═══════════════════════════ ③ الأرشفة اليدوية ═══════════════════════════
-- الإقفال يُؤرشِف تلقائيّاً؛ وهذه للحالات النهائية الأخرى (ملغى/مرفوض) ولإعادة
-- الإظهار عند الحاجة. لا تُؤرشَف طلبات قيد العمل.
CREATE OR REPLACE FUNCTION pr_set_archived(p_pr_id text, p_archived boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := proc_me(); v_pr proc_purchase_requests%ROWTYPE; v_now timestamptz := now();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT (pr_has_module_perm('pr_manage_pricing') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'الأرشفة صلاحية مشتريات';
  END IF;
  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id=p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;

  IF p_archived AND coalesce(v_pr.status,'') NOT IN ('closed','cancelled','rejected') THEN
    RAISE EXCEPTION 'لا يُؤرشَف طلب قيد العمل — أقفِله أو ألغِه أوّلاً';
  END IF;

  PERFORM set_config('app.pr_transition','1',true);
  UPDATE proc_purchase_requests
     SET archived_at = CASE WHEN p_archived THEN coalesce(archived_at, v_now) ELSE NULL END,
         archived_by = CASE WHEN p_archived THEN coalesce(archived_by, v_me) ELSE NULL END,
         updated_by=v_me, updated_at=v_now
   WHERE id=p_pr_id;

  INSERT INTO proc_audit_log(username, action, entity_type, entity_id, new_value)
  VALUES (v_me, CASE WHEN p_archived THEN 'pr_archived' ELSE 'pr_unarchived' END,
          'pr', p_pr_id, jsonb_build_object('status',v_pr.status));
  RETURN jsonb_build_object('ok',true,'id',p_pr_id,'archived',p_archived);
END $fn$;

-- ─────────────────────────────── الصلاحيات ───────────────────────────────
REVOKE ALL ON FUNCTION pr_cancel_request(text,text)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_set_archived(text,boolean)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_close_from_po(text)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION proc_po_receipt_closes_pr()       FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION pr_cancel_request(text,text)   TO authenticated;
GRANT EXECUTE ON FUNCTION pr_set_archived(text,boolean)  TO authenticated;

COMMIT;

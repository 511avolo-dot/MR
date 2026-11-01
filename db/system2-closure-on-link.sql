-- ════════════════════════════════════════════════════════════════════════════
--  إقفال الطلب عند الربط · وتحرير الطلب عند إلغاء أمر الشراء
--  ---------------------------------------------------------------------------
--  من دراسة النظام (2026-11-01). **القياس قبل البناء** على قاعدة الإنتاج:
--    · 34 طلباً حيّاً عالقاً على «صدر أمر الشراء» بمتوسّط 22.9 يوماً وأقصاها 45،
--      و15 طلباً **أُرشِف بلا إقفال** (الفريق يتحايل على العطل).
--    · آخر إقفال تلقائيّ وقع 2026-10-20. والـ19 إقفالاً التاريخيّة كلّها بأثر
--      المُشغِّل (`pr_closed_by_receipt` في التدقيق) — فالآلية تعمل حين تُستدعى.
--
--  ① العيب الأوّل — **المُشغِّل يلتقط تغيّر حالة الأمر، والمشتريات تربط الأمر
--     بعد تسليمه**. مُثبَت بالطوابع الزمنية على الإنتاج:
--       P.O-DG26-3274: تسليم 22-10 09:58  ←  ربط 27-10 10:45  (PR-0053 عَلِق 14 يوماً)
--       P.O-DG26-3276: تسليم 09:58:42     ←  ربط 10:12:21     (PR-0054 عَلِق 14 يوماً)
--     فالحالة لا تتغيّر بعد الربط أبداً ⇒ المُشغِّل لا يفيق ⇒ الطلب عالق للأبد.
--     العلاج: **المتغيّر الثابت صار «روابط الطلب النشطة»** لا «تغيّر حالة الأمر» —
--     مُشغِّل مؤجَّل على `proc_pr_po_links` يُعيد تقييم الإقفال عند الربط كذلك.
--
--  ② العيب الثاني — **أمرٌ ملغى يُجمّد طلبه إلى الأبد**: شرط الإقفال «كل الأوامر
--     المرتبطة بلغت التسليم الكامل»، والملغى لا يبلغه ولا يُفَكّ ربطه. مُثبَت:
--       P.O-DG26-3230 أُلغي 07-10 وكان مربوطاً 21-09 ⇒ PR-0016 و PR-0018
--       عَلِقا 45 و 42 يوماً.
--     العلاج: إلغاء الأمر يفكّ روابطه بأثر تدقيق ويُعيد الطلب لطابور المشتريات.
--
--  ③ وعيب ثالث كامن كشفته قراءة الكود: الشرط يقارن الحالة **نصّاً** بـ
--     'تسليم كامل'، و`PO_STATUS_ALIAS` في الواجهة يُطابق 'مُسلَّم' عليها
--     (index.html:19242). فأمرٌ بالمرادف لا يُقرأ مُسلَّماً في القاعدة أبداً.
--     العلاج: `po_is_delivered()` مصدراً واحداً لمعنى «سُلّم».
--
--  ⚠️ يُطبَّق بعد db/system2-request-closure.sql.
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ═════════════════ ③ معنى «سُلّم» — مصدر واحد مع المرادف ═════════════════
-- ⚠️ أي مقارنة جديدة لحالة تسليم أمر الشراء تمرّ بهذه الدالّة لا بنصّ حرفيّ:
--    الواجهة تطابق 'مُسلَّم' على 'تسليم كامل' عبر PO_STATUS_ALIAS، فمقارنة
--    نصّية في القاعدة خاطئة بالبناء مهما كانت البيانات اليوم.
CREATE OR REPLACE FUNCTION po_is_delivered(p_status text)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = public AS $fn$
  SELECT btrim(coalesce(p_status,'')) IN ('تسليم كامل','مُسلَّم');
$fn$;

CREATE OR REPLACE FUNCTION po_is_cancelled(p_status text)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = public AS $fn$
  SELECT btrim(coalesce(p_status,'')) = 'ملغى';
$fn$;

-- ══════════ ① الإقفال مُنطاقاً بالطلب لا بالأمر (المتغيّر الثابت) ══════════
-- يُقفَل الطلب حين تبلغ **كل** أوامره المرتبطة النشطة التسليم الكامل.
-- ثلاثة حُرّاس لا يسقط منها واحد:
--   · **رابط نشط واحد على الأقل** — وإلّا أقفلَ طلباً لم يُربَط بأمر قطّ
--     (العدّ صفر فالشرط «لا أمر غير مُسلَّم» يتحقّق فراغيّاً).
--   · الحالات النهائية لا تُمَسّ (مُقفَل/ملغى/مرفوض).
--   · الشرط يمرّ بـ`po_is_delivered` فيقبل المرادف.
CREATE OR REPLACE FUNCTION pr_close_if_received(p_pr_id text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_links int; v_pending int; v_status text; v_state text;
  v_actor text := coalesce(proc_me(),'system'); v_now timestamptz := now();
  v_po text;
BEGIN
  IF p_pr_id IS NULL THEN RETURN false; END IF;

  SELECT coalesce(status,''), coalesce(workflow_state,'')
    INTO v_status, v_state
    FROM proc_purchase_requests WHERE id = p_pr_id;
  IF NOT FOUND THEN RETURN false; END IF;
  IF v_status IN ('closed','cancelled','rejected') OR v_state IN ('closed','cancelled','rejected') THEN
    RETURN false;
  END IF;

  SELECT count(*),
         count(*) FILTER (WHERE NOT po_is_delivered(o.status)),
         min(l.po_number)
    INTO v_links, v_pending, v_po
    FROM proc_pr_po_links l
    JOIN proc_purchase_orders o ON o.po_number = l.po_number
   WHERE l.pr_id = p_pr_id AND l.active;

  IF coalesce(v_links,0) = 0 THEN RETURN false; END IF;   -- حارس الفراغ
  IF coalesce(v_pending,0) > 0 THEN RETURN false; END IF;

  PERFORM set_config('app.pr_transition','1',true);
  UPDATE proc_purchase_requests
     SET workflow_state='closed', status='closed', proc_status='closed',
         current_seq=0, current_owner=NULL,
         closed_by=v_actor, closed_at=v_now,
         -- الأرشفة تلقائيّة عند الإقفال (قرار هجرة الإقفال): يخرج من الطابور
         -- ويبقى كاملاً في الأرشيف بلا حذف.
         archived_at=coalesce(archived_at, v_now),
         archived_by=coalesce(archived_by, v_actor),
         updated_by=v_actor, updated_at=v_now
   WHERE id = p_pr_id AND coalesce(workflow_state,'') <> 'closed';

  IF NOT FOUND THEN RETURN false; END IF;

  INSERT INTO proc_audit_log(username, action, entity_type, entity_id, new_value)
  VALUES (v_actor,'pr_closed_by_receipt','pr',p_pr_id,
          jsonb_build_object('po_number',v_po,'linked_pos',v_links));
  INSERT INTO proc_pr_audit(pr_id, event, actor, channel, detail)
  VALUES (p_pr_id,'closed_by_receipt',v_actor,'system',
          jsonb_build_object('po_number',v_po,'linked_pos',v_links));
  RETURN true;
END $fn$;

-- التوقيع القائم محفوظ (تستدعيه هجرة الإقفال ومُشغِّلها): صار غلافاً رقيقاً
-- حول الدالّة المُنطاقة بالطلب، فالمنطق في موضع واحد.
CREATE OR REPLACE FUNCTION pr_close_from_po(p_po_number text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_pr text; v_n int := 0;
BEGIN
  FOR v_pr IN
    SELECT DISTINCT l.pr_id FROM proc_pr_po_links l
     WHERE l.active AND l.po_number = btrim(coalesce(p_po_number,''))
  LOOP
    IF pr_close_if_received(v_pr) THEN v_n := v_n + 1; END IF;
  END LOOP;
  RETURN v_n;
END $fn$;

-- حالة الأمر تتغيّر من عدّة مسارات (استلام عبر RPC · تغيير المرحلة من الدرج ·
-- الاستيراد · المزامنة) فالمُشغِّل يلتقطها كلّها. الجديد: المرادف يُقرأ تسليماً.
CREATE OR REPLACE FUNCTION proc_po_receipt_closes_pr() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF po_is_delivered(NEW.status)
     AND coalesce(OLD.status,'') IS DISTINCT FROM coalesce(NEW.status,'') THEN
    PERFORM pr_close_from_po(NEW.po_number);
  END IF;
  RETURN NULL;
END $fn$;

DROP TRIGGER IF EXISTS trg_po_receipt_closes_pr ON proc_purchase_orders;
CREATE TRIGGER trg_po_receipt_closes_pr
  AFTER UPDATE OF status ON proc_purchase_orders
  FOR EACH ROW EXECUTE FUNCTION proc_po_receipt_closes_pr();

-- ═════════ ① المُشغِّل الناقص: الربط نفسه يُعيد تقييم الإقفال ═════════
-- ⚠️ **مؤجَّل (CONSTRAINT TRIGGER … INITIALLY DEFERRED) عن قصد، لا تجعله فوريّاً:**
--    `pr_link_purchase_order` تُدرِج الرابط **ثمّ** تُحدِّث الطلب
--    (workflow_state='ordered'). فمُشغِّل فوريّ يُقفل الطلب ثمّ تدهسه تلك
--    الكتابة ⇒ صفٌّ نصفُ مُقفَل (status='closed' و workflow_state='ordered')
--    وهو أسوأ من العلّة نفسها. التأجيل إلى الالتزام يجعل التقييم على الحالة
--    النهائية للمعاملة.
-- ⚠️ ولا يُستدعى إلا على رابط **نشط**: الإقفال على فكّ الربط كان سيُقفل طلباً
--    فُكّ عنه أمرُه غير المُسلَّم وبقي المُسلَّم وحده — أي إقفالٌ وجزءٌ من
--    المطلوب لم يُشترَ أصلاً. فكّ الربط يُعيد الطلب للمشتريات (أدناه) لا يُقفله.
CREATE OR REPLACE FUNCTION proc_pr_link_closes_pr() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NEW.active THEN PERFORM pr_close_if_received(NEW.pr_id); END IF;
  RETURN NULL;
END $fn$;

DROP TRIGGER IF EXISTS trg_pr_link_closes_pr ON proc_pr_po_links;
CREATE CONSTRAINT TRIGGER trg_pr_link_closes_pr
  AFTER INSERT OR UPDATE ON proc_pr_po_links
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION proc_pr_link_closes_pr();

-- ═══════════ حالة الطلب بعد تغيّر روابطه — مصدر واحد ═══════════
-- كانت منسوخة داخل `pr_unlink_purchase_order`؛ استُخرجت كي يستعملها مسار
-- إلغاء الأمر أدناه بالدلالة نفسها بدل نسخة ثانية تتفارق عند أوّل تعديل.
-- ⚠️ الحالات النهائية لا تُفتَح بتغيّر الروابط: طلبٌ أُقفِل باستلام بضاعته
--    لا يعود للمشتريات لأنّ أمراً آخر أُلغي، والملغى يبقى ملغى.
CREATE OR REPLACE FUNCTION pr_sync_po_state(p_pr_id text, p_actor text DEFAULT NULL)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_cov numeric; v_status text; v_state text;
  v_actor text := coalesce(nullif(btrim(coalesce(p_actor,'')),''), proc_me(), 'system');
BEGIN
  SELECT coalesce(status,''), coalesce(workflow_state,'')
    INTO v_status, v_state
    FROM proc_purchase_requests WHERE id = p_pr_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_status IN ('closed','cancelled','rejected') OR v_state IN ('closed','cancelled','rejected') THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(sum(least(i.requested_qty,coalesce(x.allocated,0)))/nullif(sum(i.requested_qty),0),0)
    INTO v_cov
    FROM proc_pr_items i LEFT JOIN (
      SELECT a.pr_item_id, sum(a.allocated_qty) allocated
        FROM proc_pr_item_allocations a
        JOIN proc_pr_po_links l ON l.id=a.link_id AND l.active
       GROUP BY a.pr_item_id
    ) x ON x.pr_item_id=i.id
   WHERE i.pr_id=p_pr_id;

  UPDATE proc_purchase_requests r SET
    po_number=(SELECT l.po_number FROM proc_pr_po_links l
                WHERE l.pr_id=r.id AND l.active ORDER BY l.linked_at LIMIT 1),
    workflow_state=CASE WHEN v_cov>=1 THEN 'ordered'
      WHEN EXISTS(SELECT 1 FROM proc_pr_po_links l WHERE l.pr_id=r.id AND l.active)
      THEN 'partially_ordered' ELSE 'pricing' END,
    proc_status=CASE WHEN v_cov>=1 THEN 'po_issued' ELSE 'in_progress' END,
    updated_by=v_actor, updated_at=now()
  WHERE r.id=p_pr_id;

  RETURN v_cov;
END $fn$;

-- ═════════════ ② إلغاء أمر الشراء يحرّر طلبه بدل أن يُجمّده ═════════════
CREATE OR REPLACE FUNCTION proc_po_cancel_releases_pr() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_actor text := coalesce(proc_me(),'system'); v_now timestamptz := now();
  v_pr text; v_prs text[];
BEGIN
  IF NOT po_is_cancelled(NEW.status) THEN RETURN NULL; END IF;
  IF NOT (coalesce(OLD.status,'') IS DISTINCT FROM coalesce(NEW.status,'')) THEN RETURN NULL; END IF;

  -- الطلبات الحيّة المرتبطة بهذا الأمر (المُقفَل/الملغى لا يُمَسّ).
  SELECT array_agg(DISTINCT l.pr_id) INTO v_prs
    FROM proc_pr_po_links l
    JOIN proc_purchase_requests r ON r.id = l.pr_id
   WHERE l.active AND l.po_number = NEW.po_number
     AND coalesce(r.status,'') NOT IN ('closed','cancelled','rejected')
     AND coalesce(r.workflow_state,'') NOT IN ('closed','cancelled','rejected');

  IF v_prs IS NULL OR array_length(v_prs,1) IS NULL THEN RETURN NULL; END IF;

  UPDATE proc_pr_po_links
     SET active=false, unlinked_by=v_actor, unlinked_at=v_now,
         note = concat_ws(' · ', note, 'أُلغي أمر الشراء — فُكّ الربط تلقائيّاً')
   WHERE active AND po_number = NEW.po_number AND pr_id = ANY(v_prs);

  FOREACH v_pr IN ARRAY v_prs LOOP
    PERFORM pr_sync_po_state(v_pr, v_actor);
    INSERT INTO proc_audit_log(username, action, entity_type, entity_id, new_value)
    VALUES (v_actor,'pr_po_cancelled_released','pr',v_pr,
            jsonb_build_object('po_number',NEW.po_number,'from',coalesce(OLD.status,'')));
    INSERT INTO proc_pr_audit(pr_id, event, actor, channel, detail)
    VALUES (v_pr,'po_cancelled_released',v_actor,'system',
            jsonb_build_object('po_number',NEW.po_number));
  END LOOP;

  RETURN NULL;
END $fn$;

DROP TRIGGER IF EXISTS trg_po_cancel_releases_pr ON proc_purchase_orders;
CREATE TRIGGER trg_po_cancel_releases_pr
  AFTER UPDATE OF status ON proc_purchase_orders
  FOR EACH ROW EXECUTE FUNCTION proc_po_cancel_releases_pr();

-- ───────────── فكّ الربط اليدويّ يمرّ بالمصدر الواحد نفسه ─────────────
-- الجسم مطابق للقائم في الأثر، عدا أنّ حساب التغطية والحالة صار نداءً واحداً
-- (وحارس الحالات النهائية داخله: فكّ ربط عن طلب مُقفَل لم يعُد يُعيده للعمل).
CREATE OR REPLACE FUNCTION pr_unlink_purchase_order(p_pr_id text, p_po_number text, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text:=proc_me(); v_reason text:=btrim(coalesce(p_reason,'')); v_count integer; v_coverage numeric;
BEGIN
  IF v_me IS NULL OR NOT (pr_has_module_perm('pr_link_purchase_orders') OR pr_is_admin()) THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF length(v_reason)<3 THEN RAISE EXCEPTION 'سبب فك الربط مطلوب'; END IF;
  PERFORM 1 FROM proc_purchase_requests WHERE id=p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الشراء غير موجود'; END IF;
  UPDATE proc_pr_po_links SET active=false,unlinked_by=v_me,unlinked_at=now(),note=concat_ws(' · ',note,'فك الربط: '||v_reason)
  WHERE pr_id=p_pr_id AND po_number=btrim(p_po_number) AND active;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count=0 THEN RAISE EXCEPTION 'الرابط غير موجود'; END IF;
  v_coverage := pr_sync_po_state(p_pr_id, v_me);
  INSERT INTO proc_audit_log(username,action,entity_type,entity_id,new_value)
  VALUES(v_me,'pr_po_unlinked','pr',p_pr_id,jsonb_build_object('po_number',btrim(p_po_number),'reason',v_reason));
  INSERT INTO proc_pr_audit(pr_id,event,actor,channel,detail)
  VALUES(p_pr_id,'po_unlinked',v_me,'portal',jsonb_build_object('po_number',btrim(p_po_number),'reason',v_reason));
  RETURN jsonb_build_object('ok',true);
END;
$fn$;

-- ═══════════════════════ الردم: ما عَلِق يُقفَل الآن ═══════════════════════
-- ⚠️ الردم يستعمل الحارس نفسه لا استعلاماً موازياً: ما يُقفله هو بالضبط ما
--    سيُقفله المُشغِّل غداً. و`proc_me()` فارغة في الهجرة ⇒ `closed_by='system'`
--    مع أثر تدقيق `pr_closed_by_receipt` (نفس أثر الـ19 إقفالاً التاريخيّة).
DO $backfill$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN SELECT DISTINCT l.pr_id FROM proc_pr_po_links l WHERE l.active LOOP
    IF pr_close_if_received(r.pr_id) THEN v_n := v_n + 1; END IF;
  END LOOP;
  RAISE NOTICE 'ردم الإقفال: % طلباً أُقفِل', v_n;
END $backfill$;

-- وأوامرٌ ملغاة ما زالت مربوطة بطلبات حيّة: تُفَكّ وتُعاد الطلبات للمشتريات.
DO $backfill2$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT l.pr_id, l.po_number
      FROM proc_pr_po_links l
      JOIN proc_purchase_orders o ON o.po_number = l.po_number
      JOIN proc_purchase_requests q ON q.id = l.pr_id
     WHERE l.active AND po_is_cancelled(o.status)
       AND coalesce(q.status,'') NOT IN ('closed','cancelled','rejected')
       AND coalesce(q.workflow_state,'') NOT IN ('closed','cancelled','rejected')
  LOOP
    UPDATE proc_pr_po_links
       SET active=false, unlinked_by='system', unlinked_at=now(),
           note = concat_ws(' · ', note, 'أُلغي أمر الشراء — فُكّ الربط تلقائيّاً')
     WHERE active AND pr_id=r.pr_id AND po_number=r.po_number;
    PERFORM pr_sync_po_state(r.pr_id,'system');
    INSERT INTO proc_audit_log(username, action, entity_type, entity_id, new_value)
    VALUES ('system','pr_po_cancelled_released','pr',r.pr_id,
            jsonb_build_object('po_number',r.po_number,'backfill',true));
    INSERT INTO proc_pr_audit(pr_id, event, actor, channel, detail)
    VALUES (r.pr_id,'po_cancelled_released','system','system',
            jsonb_build_object('po_number',r.po_number,'backfill',true));
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'ردم الأوامر الملغاة: % رابطاً فُكّ', v_n;
END $backfill2$;

-- ─────────────────────────────── الصلاحيات ───────────────────────────────
-- دوال المُشغِّلات تُستدعى عبر المُشغِّل وحده، والمُنطاقة بالطلب خادميّة:
-- إقفال طلبٍ ليس فعلاً يطلبه العميل بل أثرٌ لحالة الأمر أو الربط.
REVOKE ALL ON FUNCTION pr_close_if_received(text)          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION pr_close_from_po(text)              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION pr_sync_po_state(text,text)         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION proc_po_receipt_closes_pr()         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION proc_po_cancel_releases_pr()        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION proc_pr_link_closes_pr()            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION po_is_delivered(text)               FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION po_is_cancelled(text)               FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_unlink_purchase_order(text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION po_is_delivered(text)            TO authenticated;
GRANT EXECUTE ON FUNCTION po_is_cancelled(text)            TO authenticated;
GRANT EXECUTE ON FUNCTION pr_unlink_purchase_order(text,text,text) TO authenticated;

COMMIT;

-- ════════════════════════════════════════════════════════════════════════════
--  CO0–CO14 — الإقفال عند الربط · وتحرير الطلب عند إلغاء أمر الشراء
--  تأكيدات **سلوكية** تستدعي الدوال والمُشغِّلات فعلاً بهويّة مُنتحَلة.
--
--  ⚠️ لماذا كل فعلٍ في كتلة `DO` مستقلّة ولا تُجمَع كتلة واحدة:
--     مُشغِّل الربط **مؤجَّل إلى الالتزام** (CONSTRAINT TRIGGER … DEFERRED) عن
--     قصد، لأنّ `pr_link_purchase_order` تُدرِج الرابط ثمّ تُحدِّث الطلب. وكل
--     عبارة `DO` في psql معاملةٌ بذاتها، فالمُشغِّل يفيق في نهايتها ويقرأ
--     التأكيدُ التاليّ أثرَه. و`SET CONSTRAINTS ALL IMMEDIATE` **لا تصلح بديلاً**
--     هنا: تُحوِّل بقيّة المعاملة إلى الوضع الفوريّ فتُعيد إنتاج العلّة التي
--     يحرسها التأجيل نفسه.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

-- ───────────────────────────────── البذرة ─────────────────────────────────
SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

CREATE TABLE IF NOT EXISTS _co_ids(k text PRIMARY KEY, v text);

INSERT INTO proc_departments(id,name_ar,sector,manager_user,active)
VALUES ('DEP-CO','إدارة الربط','الصيانة والتشغيل','co_mgr',true)
ON CONFLICT (id) DO UPDATE SET active=true, manager_user='co_mgr';

INSERT INTO proc_users(username,email,role,active,permissions,scope_sectors,
                       pr_profile_key,pr_permission_overrides,department_id,pr_department_ids)
VALUES
 ('co_req','co_req@aldeyabi.com','user',true,'{}'::jsonb,'["الصيانة والتشغيل"]'::jsonb,
  'requester','{}'::jsonb,'DEP-CO',ARRAY['DEP-CO']),
 ('co_mgr','co_mgr@aldeyabi.com','user',true,'{}'::jsonb,NULL,
  'maintenance_manager','{}'::jsonb,'DEP-CO',ARRAY['DEP-CO']),
 ('co_proc','co_proc@aldeyabi.com','user',true,'{}'::jsonb,NULL,
  'procurement_manager','{}'::jsonb,NULL,ARRAY['DEP-CO'])
ON CONFLICT (username) DO UPDATE
  SET pr_profile_key=EXCLUDED.pr_profile_key, pr_permission_overrides='{}'::jsonb,
      department_id=EXCLUDED.department_id, pr_department_ids=EXCLUDED.pr_department_ids,
      scope_sectors=EXCLUDED.scope_sectors, active=true;

-- أوامر شراء: مُسلَّم · مُسلَّم بالمرادف · غير مُسلَّم · ثانٍ · للإلغاء
INSERT INTO proc_purchase_orders(po_number,issue_date,sector,project,supplier,status)
VALUES ('PO-CO-DONE', current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','تسليم كامل'),
       ('PO-CO-ALIAS',current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','مُسلَّم'),
       ('PO-CO-OPEN', current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','قيد التوريد'),
       ('PO-CO-OPEN2',current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','قيد التوريد'),
       -- ⚠️ أمران مفتوحان مستقلّان لـCO9 و CO11: إعادة استعمال PO-CO-OPEN كانت
       --    تجعلهما يقرآن حالةً غيّرها CO4 (فيُقفَل الطلب قبل الشرط المسبق).
       ('PO-CO-OPEN3',current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','قيد التوريد'),
       ('PO-CO-OPEN4',current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','قيد التوريد'),
       ('PO-CO-CANC', current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','قيد التوريد'),
       ('PO-CO-CANC2',current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','قيد التوريد'),
       ('PO-CO-BF',   current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','تسليم كامل'),
       ('PO-CO-BFC',  current_date,'الصيانة والتشغيل','مشروع الربط','مورّد','قيد التوريد')
ON CONFLICT (po_number) DO UPDATE SET status=EXCLUDED.status;

INSERT INTO proc_settings(key,value)
VALUES ('projects_registry','{"projects":[{"name":"مشروع الربط","aliases":[],"active":true}]}'::jsonb)
ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value;

-- مساعد: طلبٌ جديد مُعتمَد حتى إذن التسعير، جاهز للربط.
-- ⚠️ لا يُنتحَل معتمِدٌ بالاسم: المراحل تُعتمَد بهويّة **المُعتمِد الذي أسنده
--    المحرّك فعلاً** (`pr_resolve_stage_approver`). الانتحال بالاسم كان يسقط في
--    الحزمة الكاملة لأنّ ملفّات سابقة تبذر حاملين آخرين لنفس الصلاحية فيختار
--    المحرّك غيرهم — وهو سلوكٌ صحيح لا عيب، فالمساعد هو ما يجب أن يتبعه.
CREATE OR REPLACE FUNCTION _co_make(p_title text, p_qty numeric DEFAULT 2) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_id text; v_appr text; v_mail text; v_guard int := 0;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"co_req@aldeyabi.com"}',true);
  v_id := (pr_save_request(
    jsonb_build_object('title',p_title,'department_id','DEP-CO','project','مشروع الربط',
                       'priority','عادي','justification','اختبار'),
    jsonb_build_array(jsonb_build_object('description','بند','unit','حبة','requested_qty',p_qty)),
    true, NULL))->>'id';

  LOOP
    v_guard := v_guard + 1;
    EXIT WHEN v_guard > 8;
    SELECT a.approver INTO v_appr FROM proc_pr_approvals a
     WHERE a.pr_id=v_id AND a.decision='pending' ORDER BY a.seq LIMIT 1;
    EXIT WHEN v_appr IS NULL;
    SELECT u.email INTO v_mail FROM proc_users u WHERE lower(u.username)=lower(v_appr) LIMIT 1;
    IF v_mail IS NULL THEN RAISE EXCEPTION 'المعتمِد % بلا بريد في البذرة', v_appr; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('email',v_mail)::text, true);
    PERFORM pr_decide(v_id,'approve','موافق');
  END LOOP;

  IF (SELECT coalesce(status,'') FROM proc_purchase_requests WHERE id=v_id) <> 'approved' THEN
    RAISE EXCEPTION 'المساعد فشل: الطلب % لم يبلغ approved', v_id;
  END IF;
  RETURN v_id;
END $$;

-- مساعد: ربط كامل الكمية
CREATE OR REPLACE FUNCTION _co_link(p_id text, p_po text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"co_proc@aldeyabi.com"}',true);
  PERFORM pr_link_purchase_order(p_id,p_po,
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',i.requested_qty))
       FROM proc_pr_items i WHERE i.pr_id=p_id),'ربط');
END $$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO0 [شرط لازم] — بلا مُشغِّل الربط يبقى الطلب عالقاً: العلّة المُبلَّغ عنها
--  تُعاد إنتاجاً هنا، فلا يمرّ CO1 فراغيّاً على مسارٍ لا علاقة له بالعيب.
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE proc_pr_po_links DISABLE TRIGGER trg_pr_link_closes_pr;

DO $co0a$
DECLARE v_id text;
BEGIN
  v_id := _co_make('CO0 عالق بلا مُشغِّل');
  PERFORM _co_link(v_id,'PO-CO-DONE');
  INSERT INTO _co_ids VALUES ('co0',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co0a$;

DO $co0b$
DECLARE v_state text;
BEGIN
  SELECT workflow_state INTO v_state FROM proc_purchase_requests
   WHERE id=(SELECT v FROM _co_ids WHERE k='co0');
  IF v_state = 'closed' THEN
    RAISE EXCEPTION 'CO0 فشل: أُقفِل والمُشغِّل مُعطَّل — التأكيد لا يختبر المُشغِّل';
  END IF;
  RAISE NOTICE 'CO0 ✅ [شرط لازم] بلا المُشغِّل: الربط بأمر مُسلَّم يترك الطلب على % — العلّة مُعادة إنتاجاً', v_state;
END $co0b$;

ALTER TABLE proc_pr_po_links ENABLE TRIGGER trg_pr_link_closes_pr;

-- ════════════════════════════════════════════════════════════════════════════
--  CO1 — الربط بأمر **سُلّم قبل الربط** يُقفل الطلب (جوهر الإصلاح)
-- ════════════════════════════════════════════════════════════════════════════
DO $co1a$
DECLARE v_id text;
BEGIN
  v_id := _co_make('CO1 ربط بعد التسليم');
  PERFORM _co_link(v_id,'PO-CO-DONE');
  INSERT INTO _co_ids VALUES ('co1',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co1a$;

DO $co1b$
DECLARE v_state text; v_n int;
BEGIN
  SELECT workflow_state||'|'||coalesce(status,'')||'|'||coalesce(proc_status,'')||'|'||(archived_at IS NOT NULL)::text
    INTO v_state FROM proc_purchase_requests WHERE id=(SELECT v FROM _co_ids WHERE k='co1');
  IF v_state <> 'closed|closed|closed|true' THEN
    RAISE EXCEPTION 'CO1 فشل: % (المتوقَّع closed|closed|closed|true)', v_state;
  END IF;
  SELECT count(*) INTO v_n FROM proc_pr_audit
   WHERE pr_id=(SELECT v FROM _co_ids WHERE k='co1') AND event='closed_by_receipt';
  IF v_n <> 1 THEN RAISE EXCEPTION 'CO1 فشل: صفوف أثر الإقفال = %', v_n; END IF;
  RAISE NOTICE 'CO1 ✅ الربط بأمر مُسلَّم أقفل الطلب وأرشفه بأثر تدقيق ⇒ %', v_state;
END $co1b$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO2 — المرادف 'مُسلَّم' يُقرأ تسليماً (PO_STATUS_ALIAS)
-- ════════════════════════════════════════════════════════════════════════════
DO $co2a$
DECLARE v_id text;
BEGIN
  IF NOT po_is_delivered('مُسلَّم') THEN RAISE EXCEPTION 'CO2 فشل: المرادف لا يُقرأ تسليماً'; END IF;
  IF po_is_delivered('تسليم جزئي') THEN RAISE EXCEPTION 'CO2 فشل: التسليم الجزئيّ قُرِئ كاملاً'; END IF;
  v_id := _co_make('CO2 مرادف');
  PERFORM _co_link(v_id,'PO-CO-ALIAS');
  INSERT INTO _co_ids VALUES ('co2',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co2a$;

DO $co2b$
DECLARE v_state text;
BEGIN
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=(SELECT v FROM _co_ids WHERE k='co2');
  IF v_state <> 'closed' THEN RAISE EXCEPTION 'CO2 فشل: %', v_state; END IF;
  RAISE NOTICE 'CO2 ✅ أمرٌ بحالة «مُسلَّم» أقفل طلبه';
END $co2b$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO3 — الربط بأمر غير مُسلَّم لا يُقفل (لا إقفال متعجّل)
-- ════════════════════════════════════════════════════════════════════════════
DO $co3a$
DECLARE v_id text;
BEGIN
  v_id := _co_make('CO3 أمر مفتوح');
  PERFORM _co_link(v_id,'PO-CO-OPEN');
  INSERT INTO _co_ids VALUES ('co3',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co3a$;

DO $co3b$
DECLARE v_state text;
BEGIN
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=(SELECT v FROM _co_ids WHERE k='co3');
  IF v_state = 'closed' THEN RAISE EXCEPTION 'CO3 فشل: أُقفِل وأمره قيد التوريد'; END IF;
  RAISE NOTICE 'CO3 ✅ أمرٌ غير مُسلَّم لا يُقفل الطلب (%)', v_state;
END $co3b$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO4 — أمران: لا يُقفَل إلا باكتمالهما (عدم انحدار على القاعدة القائمة)
-- ════════════════════════════════════════════════════════════════════════════
DO $co4a$
DECLARE v_id text;
BEGIN
  v_id := _co_make('CO4 أمران');
  PERFORM set_config('request.jwt.claims','{"email":"co_proc@aldeyabi.com"}',true);
  PERFORM pr_link_purchase_order(v_id,'PO-CO-OPEN',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',1)) FROM proc_pr_items i WHERE i.pr_id=v_id),'أوّل');
  PERFORM pr_link_purchase_order(v_id,'PO-CO-OPEN2',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',1)) FROM proc_pr_items i WHERE i.pr_id=v_id),'ثانٍ');
  INSERT INTO _co_ids VALUES ('co4',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co4a$;

DO $co4b$
DECLARE v_state text;
BEGIN
  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_state;
  UPDATE proc_purchase_orders SET status='تسليم كامل' WHERE po_number='PO-CO-OPEN';
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=(SELECT v FROM _co_ids WHERE k='co4');
  IF v_state = 'closed' THEN RAISE EXCEPTION 'CO4 فشل: أُقفِل والأمر الثاني لم يُستلَم'; END IF;
  UPDATE proc_purchase_orders SET status='تسليم كامل' WHERE po_number='PO-CO-OPEN2';
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=(SELECT v FROM _co_ids WHERE k='co4');
  IF v_state <> 'closed' THEN RAISE EXCEPTION 'CO4 فشل: لم يُقفَل باكتمال الأمرين (%)', v_state; END IF;
  RAISE NOTICE 'CO4 ✅ لا إقفال إلا باكتمال كل أوامر الطلب';
END $co4b$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO5 — حارس الفراغ: طلبٌ بلا رابط نشط لا يُقفَل أبداً
--  (العدّ صفر فشرط «لا أمر غير مُسلَّم» يتحقّق فراغيّاً — وهذا ما يحرسه)
-- ════════════════════════════════════════════════════════════════════════════
DO $co5$
DECLARE v_id text; v_closed boolean; v_state text;
BEGIN
  v_id := _co_make('CO5 بلا روابط');
  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_state;
  v_closed := pr_close_if_received(v_id);
  IF v_closed THEN RAISE EXCEPTION 'CO5 فشل: أُقفِل طلبٌ لم يُربَط بأمر قطّ'; END IF;
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state = 'closed' THEN RAISE EXCEPTION 'CO5 فشل: الحالة %', v_state; END IF;
  RAISE NOTICE 'CO5 ✅ طلبٌ بلا رابط نشط لا يُقفَل (%)', v_state;
END $co5$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO6 — إلغاء أمر الشراء يفكّ ربطه ويُعيد الطلب لطابور المشتريات
--  (العلّة الثانية: PR-0016 و PR-0018 عَلِقا 45 و 42 يوماً)
-- ════════════════════════════════════════════════════════════════════════════
DO $co6a$
DECLARE v_id text;
BEGIN
  v_id := _co_make('CO6 أمر ملغى');
  PERFORM _co_link(v_id,'PO-CO-CANC');
  INSERT INTO _co_ids VALUES ('co6',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co6a$;

DO $co6b$
DECLARE v_id text; v_state text; v_n int;
BEGIN
  v_id := (SELECT v FROM _co_ids WHERE k='co6');
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'ordered' THEN RAISE EXCEPTION 'CO6 شرط مسبق: الحالة قبل الإلغاء % لا ordered', v_state; END IF;

  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_state;
  UPDATE proc_purchase_orders SET status='ملغى' WHERE po_number='PO-CO-CANC';

  SELECT count(*) INTO v_n FROM proc_pr_po_links WHERE pr_id=v_id AND po_number='PO-CO-CANC' AND active;
  IF v_n <> 0 THEN RAISE EXCEPTION 'CO6 فشل: الرابط ما زال نشطاً'; END IF;
  SELECT workflow_state||'|'||coalesce(proc_status,'') INTO v_state
    FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'pricing|in_progress' THEN
    RAISE EXCEPTION 'CO6 فشل: % (المتوقَّع pricing|in_progress)', v_state;
  END IF;
  SELECT count(*) INTO v_n FROM proc_pr_audit WHERE pr_id=v_id AND event='po_cancelled_released';
  IF v_n <> 1 THEN RAISE EXCEPTION 'CO6 فشل: أثر التحرير = % صفّاً', v_n; END IF;
  RAISE NOTICE 'CO6 ✅ إلغاء الأمر فكّ ربطه وأعاد الطلب للمشتريات بأثر تدقيق ⇒ %', v_state;
END $co6b$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO7 — إلغاء أمرٍ **لا يُعيد فتح** طلبٍ أُقفِل باستلام بضاعته
-- ════════════════════════════════════════════════════════════════════════════
DO $co7$
DECLARE v_id text; v_state text;
BEGIN
  v_id := (SELECT v FROM _co_ids WHERE k='co1');   -- مُقفَل في CO1 على PO-CO-DONE
  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_state;
  UPDATE proc_purchase_orders SET status='ملغى' WHERE po_number='PO-CO-DONE';
  SELECT workflow_state||'|'||coalesce(status,'') INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'closed|closed' THEN
    RAISE EXCEPTION 'CO7 فشل: طلبٌ مُقفَل انفتح بإلغاء أمره ⇒ %', v_state;
  END IF;
  RAISE NOTICE 'CO7 ✅ الحالات النهائية لا تُفتَح بتغيّر الروابط';
  UPDATE proc_purchase_orders SET status='تسليم كامل' WHERE po_number='PO-CO-DONE';
END $co7$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO8 — الملغى وحده يُفَكّ: رابطٌ سليم آخر يبقى والحالة تُعاد حسابها
-- ════════════════════════════════════════════════════════════════════════════
DO $co8a$
DECLARE v_id text;
BEGIN
  v_id := _co_make('CO8 أمران أحدهما يُلغى');
  PERFORM set_config('request.jwt.claims','{"email":"co_proc@aldeyabi.com"}',true);
  PERFORM pr_link_purchase_order(v_id,'PO-CO-CANC2',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',1)) FROM proc_pr_items i WHERE i.pr_id=v_id),'يُلغى');
  PERFORM pr_link_purchase_order(v_id,'PO-CO-BFC',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',1)) FROM proc_pr_items i WHERE i.pr_id=v_id),'يبقى');
  INSERT INTO _co_ids VALUES ('co8',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co8a$;

DO $co8b$
DECLARE v_id text; v_state text; v_n int;
BEGIN
  v_id := (SELECT v FROM _co_ids WHERE k='co8');
  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_state;
  UPDATE proc_purchase_orders SET status='ملغى' WHERE po_number='PO-CO-CANC2';
  SELECT count(*) INTO v_n FROM proc_pr_po_links WHERE pr_id=v_id AND active;
  IF v_n <> 1 THEN RAISE EXCEPTION 'CO8 فشل: الروابط النشطة = % (المتوقَّع 1)', v_n; END IF;
  SELECT count(*) INTO v_n FROM proc_pr_po_links WHERE pr_id=v_id AND active AND po_number='PO-CO-BFC';
  IF v_n <> 1 THEN RAISE EXCEPTION 'CO8 فشل: فُكّ الرابط السليم'; END IF;
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'partially_ordered' THEN
    RAISE EXCEPTION 'CO8 فشل: % (المتوقَّع partially_ordered — نصف الكمية بقي مربوطاً)', v_state;
  END IF;
  RAISE NOTICE 'CO8 ✅ الملغى وحده فُكّ والتغطية أُعيد حسابها ⇒ %', v_state;
END $co8b$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO9 — فكّ الربط لا يُقفل: لو أُقفِل لأُقفِل طلبٌ نصفُ مطلوبه لم يُشترَ أصلاً
--  (هذا سبب قصر المُشغِّل على الرابط **النشط** — وهو ما يحرسه هذا التأكيد)
-- ════════════════════════════════════════════════════════════════════════════
DO $co9a$
DECLARE v_id text; v_state text;
BEGIN
  v_id := _co_make('CO9 فكّ ربط');
  PERFORM set_config('request.jwt.claims','{"email":"co_proc@aldeyabi.com"}',true);
  PERFORM pr_link_purchase_order(v_id,'PO-CO-BF',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',1)) FROM proc_pr_items i WHERE i.pr_id=v_id),'مُسلَّم');
  PERFORM pr_link_purchase_order(v_id,'PO-CO-OPEN3',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',1)) FROM proc_pr_items i WHERE i.pr_id=v_id),'غير مُسلَّم');
  INSERT INTO _co_ids VALUES ('co9',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co9a$;

DO $co9b$
DECLARE v_id text; v_state text;
BEGIN
  v_id := (SELECT v FROM _co_ids WHERE k='co9');
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state = 'closed' THEN RAISE EXCEPTION 'CO9 شرط مسبق: أُقفِل قبل فكّ الربط'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"co_proc@aldeyabi.com"}',true);
  PERFORM pr_unlink_purchase_order(v_id,'PO-CO-OPEN3','لم يُنفَّذ');
END $co9b$;

DO $co9c$
DECLARE v_id text; v_state text;
BEGIN
  v_id := (SELECT v FROM _co_ids WHERE k='co9');
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state = 'closed' THEN
    RAISE EXCEPTION 'CO9 فشل: فكّ الربط أقفل الطلب ونصف مطلوبه لم يُشترَ';
  END IF;
  RAISE NOTICE 'CO9 ✅ فكّ الربط يُعيد الطلب للمشتريات ولا يُقفله (%)', v_state;
END $co9c$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO10 — دوال الإقفال خادميّة: العميل لا ينفّذها
-- ════════════════════════════════════════════════════════════════════════════
DO $co10$
DECLARE r record; v_bad text := '';
BEGIN
  FOR r IN SELECT f, g FROM (VALUES
      ('pr_close_if_received(text)','anon'),('pr_close_if_received(text)','authenticated'),
      ('pr_close_from_po(text)','anon'),('pr_close_from_po(text)','authenticated'),
      ('pr_sync_po_state(text,text)','anon'),('pr_sync_po_state(text,text)','authenticated'),
      ('proc_pr_link_closes_pr()','anon'),('proc_pr_link_closes_pr()','authenticated'),
      ('proc_po_cancel_releases_pr()','anon'),('proc_po_cancel_releases_pr()','authenticated'),
      ('po_is_delivered(text)','anon'),('po_is_cancelled(text)','anon')
    ) AS t(f,g)
  LOOP
    IF has_function_privilege(r.g, r.f, 'EXECUTE') THEN v_bad := v_bad || r.g || '→' || r.f || ' '; END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'CO10 فشل: تنفيذ مكشوف: %', v_bad; END IF;
  -- والمستخدم المسجَّل يبقى يقرأ معنى الحالة (تستعمله الواجهة)
  IF NOT has_function_privilege('authenticated','po_is_delivered(text)','EXECUTE') THEN
    RAISE EXCEPTION 'CO10 فشل: po_is_delivered محجوبة عن المستخدم المسجَّل';
  END IF;
  RAISE NOTICE 'CO10 ✅ دوال الإقفال خادميّة و po_is_delivered متاحة للمستخدم المسجَّل';
END $co10$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO11 — الطلب الملغى لا يُقفله تسليمُ أمرٍ كان مربوطاً به
-- ════════════════════════════════════════════════════════════════════════════
DO $co11a$
DECLARE v_id text;
BEGIN
  v_id := _co_make('CO11 ملغى');
  PERFORM _co_link(v_id,'PO-CO-OPEN4');
  INSERT INTO _co_ids VALUES ('co11',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co11a$;

DO $co11b$
DECLARE v_id text; v_state text; v_closed boolean;
BEGIN
  v_id := (SELECT v FROM _co_ids WHERE k='co11');
  PERFORM set_config('request.jwt.claims','{"email":"co_proc@aldeyabi.com"}',true);
  PERFORM pr_cancel_request(v_id,'قرار إداريّ');
  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_state;
  -- يُعاد الربط قسراً لمحاكاة صفٍّ تاريخيّ ثمّ يُسلَّم الأمر
  UPDATE proc_pr_po_links SET active=true WHERE pr_id=v_id AND po_number='PO-CO-OPEN4';
  UPDATE proc_purchase_orders SET status='تسليم كامل' WHERE po_number='PO-CO-OPEN4';
  v_closed := pr_close_if_received(v_id);
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_closed OR v_state <> 'cancelled' THEN
    RAISE EXCEPTION 'CO11 فشل: طلبٌ ملغى أُقفِل ⇒ % / %', v_closed, v_state;
  END IF;
  RAISE NOTICE 'CO11 ✅ الملغى يبقى ملغىً';
  UPDATE proc_purchase_orders SET status='قيد التوريد' WHERE po_number='PO-CO-OPEN4';
END $co11b$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO12 — الإقفال لا يتكرّر: نداء ثانٍ يُرجِع false ولا يُضيف أثراً
-- ════════════════════════════════════════════════════════════════════════════
DO $co12$
DECLARE v_id text; v_closed boolean; v_n int; v_state text;
BEGIN
  v_id := (SELECT v FROM _co_ids WHERE k='co1');
  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_state;
  v_closed := pr_close_if_received(v_id);
  IF v_closed THEN RAISE EXCEPTION 'CO12 فشل: أُقفِل مرّتين'; END IF;
  SELECT count(*) INTO v_n FROM proc_pr_audit WHERE pr_id=v_id AND event='closed_by_receipt';
  IF v_n <> 1 THEN RAISE EXCEPTION 'CO12 فشل: أثر الإقفال تكرّر (%)', v_n; END IF;
  RAISE NOTICE 'CO12 ✅ الإقفال فعلٌ واحد لا يتكرّر';
END $co12$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO14 — فكّ ربط يدويّ عن طلبٍ **مُقفَل** لا يُعيده للعمل
--  ⚠️ هذا التأكيد أضافه البيت-بروف: حارس الحالات النهائية في `pr_sync_po_state`
--     **لم يعضّ** بلا أمره، لأنّ مسار إلغاء الأمر يُصفّي النهائيّ قبل بلوغه.
--     المسار الحيّ للحارس هو `pr_unlink_purchase_order` وهو بلا تصفية — وبدونه
--     يصير الصفّ نصفَ مفتوح (status='closed' و workflow_state='pricing').
-- ════════════════════════════════════════════════════════════════════════════
DO $co14$
DECLARE v_id text; v_state text;
BEGIN
  v_id := (SELECT v FROM _co_ids WHERE k='co2');   -- مُقفَل في CO2 على PO-CO-ALIAS
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'closed' THEN RAISE EXCEPTION 'CO14 شرط مسبق: % لا closed', v_state; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"co_proc@aldeyabi.com"}',true);
  PERFORM pr_unlink_purchase_order(v_id,'PO-CO-ALIAS','تصحيح إداريّ');
  SELECT workflow_state||'|'||coalesce(status,'')||'|'||coalesce(proc_status,'')
    INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'closed|closed|closed' THEN
    RAISE EXCEPTION 'CO14 فشل: فكّ الربط أعاد فتح طلب مُقفَل ⇒ %', v_state;
  END IF;
  RAISE NOTICE 'CO14 ✅ فكّ الربط لا يُعيد فتح المُقفَل ⇒ %', v_state;
END $co14$;

-- ════════════════════════════════════════════════════════════════════════════
--  CO13 — الردم: حالة الإنتاج تُعاد بناءً (مُشغِّل مُعطَّل ⇒ طلبٌ عالق + أمر
--  ملغى مربوط) ثمّ تُشغَّل الهجرة نفسها بـ\i، ويُتحقَّق أنّها هي التي داوتها.
--  ⚠️ وهذا ما يمنع التأكيد الفراغيّ: بلا إعادة بناء الحالة المعطوبة، الردم
--     يمرّ بلا أن يجد ما يُداويه.
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE proc_pr_po_links DISABLE TRIGGER trg_pr_link_closes_pr;
ALTER TABLE proc_purchase_orders DISABLE TRIGGER trg_po_cancel_releases_pr;

DO $co13a$
DECLARE v_id text; v_id2 text; v_state text;
BEGIN
  -- (أ) طلبٌ عالق: مربوط بأمر سُلّم قبل الربط
  v_id := _co_make('CO13 عالق للردم');
  PERFORM _co_link(v_id,'PO-CO-BF');
  INSERT INTO _co_ids VALUES ('co13a',v_id) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;

  -- (ب) طلبٌ مُجمَّد: مربوط بأمر أُلغي بعد الربط
  v_id2 := _co_make('CO13 مُجمَّد بأمر ملغى');
  PERFORM _co_link(v_id2,'PO-CO-BFC');
  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_state;
  UPDATE proc_purchase_orders SET status='ملغى' WHERE po_number='PO-CO-BFC';
  INSERT INTO _co_ids VALUES ('co13b',v_id2) ON CONFLICT (k) DO UPDATE SET v=EXCLUDED.v;
END $co13a$;

DO $co13b$
DECLARE v_a text; v_b text;
BEGIN
  SELECT workflow_state INTO v_a FROM proc_purchase_requests WHERE id=(SELECT v FROM _co_ids WHERE k='co13a');
  SELECT workflow_state INTO v_b FROM proc_purchase_requests WHERE id=(SELECT v FROM _co_ids WHERE k='co13b');
  IF v_a = 'closed' THEN RAISE EXCEPTION 'CO13 شرط مسبق: (أ) أُقفِل والمُشغِّل مُعطَّل'; END IF;
  IF v_b <> 'ordered' THEN RAISE EXCEPTION 'CO13 شرط مسبق: (ب) % لا ordered', v_b; END IF;
  RAISE NOTICE 'CO13 الحالة المعطوبة مُعادة: (أ)=% · (ب)=%', v_a, v_b;
END $co13b$;

\i db/system2-closure-on-link.sql

DO $co13c$
DECLARE v_a text; v_b text; v_n int;
BEGIN
  SELECT workflow_state||'|'||coalesce(closed_by,'') INTO v_a
    FROM proc_purchase_requests WHERE id=(SELECT v FROM _co_ids WHERE k='co13a');
  IF v_a <> 'closed|system' THEN RAISE EXCEPTION 'CO13 فشل: الردم لم يُقفل العالق ⇒ %', v_a; END IF;

  SELECT workflow_state||'|'||coalesce(proc_status,'') INTO v_b
    FROM proc_purchase_requests WHERE id=(SELECT v FROM _co_ids WHERE k='co13b');
  IF v_b <> 'pricing|in_progress' THEN RAISE EXCEPTION 'CO13 فشل: الردم لم يحرّر المُجمَّد ⇒ %', v_b; END IF;
  SELECT count(*) INTO v_n FROM proc_pr_po_links
   WHERE pr_id=(SELECT v FROM _co_ids WHERE k='co13b') AND active;
  IF v_n <> 0 THEN RAISE EXCEPTION 'CO13 فشل: بقي % رابطاً لأمر ملغى', v_n; END IF;

  -- والمُشغِّلان أُعيدا بإعادة تشغيل الهجرة (DROP + CREATE)
  SELECT count(*) INTO v_n FROM pg_trigger
   WHERE tgname IN ('trg_pr_link_closes_pr','trg_po_cancel_releases_pr') AND tgenabled <> 'D';
  IF v_n <> 2 THEN RAISE EXCEPTION 'CO13 فشل: المُشغِّلان النشطان = %', v_n; END IF;
  RAISE NOTICE 'CO13 ✅ الردم أقفل العالق وحرّر المُجمَّد وأعاد المُشغِّلين ⇒ % · %', v_a, v_b;

  RAISE NOTICE '── CO0–CO14 كلها ناجحة ──';
END $co13c$;

DROP FUNCTION IF EXISTS _co_make(text,numeric);
DROP FUNCTION IF EXISTS _co_link(text,text);
DROP TABLE IF EXISTS _co_ids;

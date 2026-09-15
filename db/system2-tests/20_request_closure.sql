-- ════════════════════════════════════════════════════════════════════════════
--  CL1–CL12 — إقفال دورة الطلب: إلغاء · إقفال بالاستلام · أرشفة
--  تأكيدات **سلوكية** تستدعي الدوال فعلاً بهويّة مُنتحَلة، لا فحص نصّ.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

-- ── بذرة: إدارة · مستخدمون · أمرا شراء ──
SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

INSERT INTO proc_departments(id,name_ar,sector,manager_user,active)
VALUES ('DEP-CL','إدارة الإقفال','الصيانة والتشغيل','cl_mgr',true)
ON CONFLICT (id) DO UPDATE SET active=true, manager_user='cl_mgr';

INSERT INTO proc_users(username,email,role,active,permissions,scope_sectors,
                       pr_profile_key,pr_permission_overrides,department_id,pr_department_ids)
VALUES
 ('cl_req','cl_req@aldeyabi.com','user',true,'{}'::jsonb,'["الصيانة والتشغيل"]'::jsonb,
  'requester','{}'::jsonb,'DEP-CL',ARRAY['DEP-CL']),
 ('cl_mgr','cl_mgr@aldeyabi.com','user',true,'{}'::jsonb,NULL,
  'maintenance_manager','{}'::jsonb,'DEP-CL',ARRAY['DEP-CL']),
 ('cl_proc','cl_proc@aldeyabi.com','user',true,'{}'::jsonb,NULL,
  'procurement_manager','{}'::jsonb,NULL,ARRAY['DEP-CL'])
ON CONFLICT (username) DO UPDATE
  SET pr_profile_key=EXCLUDED.pr_profile_key, pr_permission_overrides='{}'::jsonb,
      department_id=EXCLUDED.department_id, pr_department_ids=EXCLUDED.pr_department_ids,
      scope_sectors=EXCLUDED.scope_sectors, active=true;

INSERT INTO proc_purchase_orders(po_number,issue_date,sector,project,supplier,status)
VALUES ('PO-CL-1',current_date,'الصيانة والتشغيل','مشروع الإقفال','مورّد','جديد'),
       ('PO-CL-2',current_date,'الصيانة والتشغيل','مشروع الإقفال','مورّد','جديد')
ON CONFLICT (po_number) DO UPDATE SET status='جديد';

-- سجلّ المشاريع كي يمرّ فحص pr_project_is_canonical
INSERT INTO proc_settings(key,value)
VALUES ('projects_registry','{"projects":[{"name":"مشروع الإقفال","aliases":[],"active":true}]}'::jsonb)
ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value;

-- ═══════════════════ مساعد: طلب جديد مُعتمَد حتى التسعير ═══════════════════
CREATE OR REPLACE FUNCTION _cl_make_request(p_title text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_id text;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"cl_req@aldeyabi.com"}',true);
  v_id := (pr_save_request(
    jsonb_build_object('title',p_title,'department_id','DEP-CL','project','مشروع الإقفال',
                       'priority','عادي','justification','اختبار'),
    jsonb_build_array(jsonb_build_object('description','بند','unit','حبة','requested_qty',2)),
    true, NULL))->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"cl_mgr@aldeyabi.com"}',true);
  PERFORM pr_decide(v_id,'approve','موافق');
  PERFORM set_config('request.jwt.claims','{"email":"cl_proc@aldeyabi.com"}',true);
  PERFORM pr_decide(v_id,'approve','إذن');
  RETURN v_id;
END $$;

DO $t$
DECLARE v_id text; v_id2 text; v_ok boolean; v_msg text; v_state text; v_n int;
BEGIN
  -- ══════════════ CL1: المقدّم يُلغي طلبه قبل أمر الشراء ══════════════
  PERFORM set_config('request.jwt.claims','{"email":"cl_req@aldeyabi.com"}',true);
  v_id := (pr_save_request(
    jsonb_build_object('title','للإلغاء','department_id','DEP-CL','project','مشروع الإقفال'),
    jsonb_build_array(jsonb_build_object('description','بند','unit','حبة','requested_qty',1)),
    true,NULL))->>'id';
  PERFORM pr_cancel_request(v_id,'لم نعد بحاجته');
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'cancelled' THEN RAISE EXCEPTION 'CL1 فشل: الحالة %', v_state; END IF;
  RAISE NOTICE 'CL1 ✅ المقدّم ألغى طلبه ⇒ %', v_state;

  -- ══════════════ CL2: السبب إلزاميّ ══════════════
  v_ok := false;
  BEGIN
    v_id2 := (pr_save_request(
      jsonb_build_object('title','بلا سبب','department_id','DEP-CL','project','مشروع الإقفال'),
      jsonb_build_array(jsonb_build_object('description','بند','unit','حبة','requested_qty',1)),
      true,NULL))->>'id';
    PERFORM pr_cancel_request(v_id2,'  ');
  EXCEPTION WHEN others THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'CL2 فشل: قُبِل إلغاء بلا سبب'; END IF;
  RAISE NOTICE 'CL2 ✅ الإلغاء بلا سبب مرفوض';

  -- ══════════════ CL3: لا يُلغى ملغىً مرّتين ══════════════
  v_ok := false;
  BEGIN PERFORM pr_cancel_request(v_id,'مرّة أخرى');
  EXCEPTION WHEN others THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'CL3 فشل: أُلغي مرّتين'; END IF;
  RAISE NOTICE 'CL3 ✅ الإلغاء المكرّر مرفوض';

  -- ══════════════ CL4: غير المالك وغير المشتريات مرفوض ══════════════
  v_id2 := _cl_make_request('حارس الملكية');
  PERFORM set_config('request.jwt.claims','{"email":"cl_mgr@aldeyabi.com"}',true);
  v_ok := false;
  BEGIN PERFORM pr_cancel_request(v_id2,'محاولة');
  EXCEPTION WHEN others THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'CL4 فشل: مدير الصيانة ألغى طلب غيره'; END IF;
  RAISE NOTICE 'CL4 ✅ الإلغاء محكوم بالملكية أو المشتريات';

  -- ══════════════ CL5: بعد أمر الشراء يُمنَع المقدّم ويُسمَح للمشتريات ══════════════
  PERFORM set_config('request.jwt.claims','{"email":"cl_proc@aldeyabi.com"}',true);
  PERFORM pr_link_purchase_order(v_id2,'PO-CL-1',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',i.requested_qty))
       FROM proc_pr_items i WHERE i.pr_id=v_id2),'ربط');
  PERFORM set_config('request.jwt.claims','{"email":"cl_req@aldeyabi.com"}',true);
  v_ok := false;
  BEGIN PERFORM pr_cancel_request(v_id2,'بعد الأمر');
  EXCEPTION WHEN others THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'CL5 فشل: المقدّم ألغى بعد صدور أمر الشراء'; END IF;
  RAISE NOTICE 'CL5 ✅ المقدّم لا يُلغي بعد أمر الشراء';

  -- ══════════════ CL6: إلغاء المشتريات يفكّ روابط الأوامر ══════════════
  PERFORM set_config('request.jwt.claims','{"email":"cl_proc@aldeyabi.com"}',true);
  PERFORM pr_cancel_request(v_id2,'قرار إداريّ');
  SELECT count(*) INTO v_n FROM proc_pr_po_links WHERE pr_id=v_id2 AND active;
  IF v_n <> 0 THEN RAISE EXCEPTION 'CL6 فشل: بقي % رابط نشط', v_n; END IF;
  SELECT count(*) INTO v_n FROM proc_pr_approvals WHERE pr_id=v_id2 AND decision='pending';
  IF v_n <> 0 THEN RAISE EXCEPTION 'CL6 فشل: بقيت % مرحلة معلّقة', v_n; END IF;
  RAISE NOTICE 'CL6 ✅ الإلغاء يفكّ الروابط ويُصفّر المراحل المعلّقة';

  -- ══════════════ CL7: التسليم الكامل يُقفل الطلب ويُؤرشفه ══════════════
  v_id := _cl_make_request('للإقفال بالاستلام');
  PERFORM set_config('request.jwt.claims','{"email":"cl_proc@aldeyabi.com"}',true);
  PERFORM pr_link_purchase_order(v_id,'PO-CL-1',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',i.requested_qty))
       FROM proc_pr_items i WHERE i.pr_id=v_id),'ربط');
  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_msg;
  UPDATE proc_purchase_orders SET status='تسليم كامل' WHERE po_number='PO-CL-1';
  SELECT workflow_state||'|'||coalesce(status,'')||'|'||(archived_at IS NOT NULL)::text
    INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'closed|closed|true' THEN RAISE EXCEPTION 'CL7 فشل: %', v_state; END IF;
  RAISE NOTICE 'CL7 ✅ التسليم الكامل أقفل الطلب وأرشفه ⇒ %', v_state;

  -- ══════════════ CL8: لا يُقفَل قبل اكتمال **كل** أوامره ══════════════
  UPDATE proc_purchase_orders SET status='جديد' WHERE po_number IN ('PO-CL-1','PO-CL-2');
  v_id := _cl_make_request('أمران');
  PERFORM set_config('request.jwt.claims','{"email":"cl_proc@aldeyabi.com"}',true);
  PERFORM pr_link_purchase_order(v_id,'PO-CL-1',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',1)) FROM proc_pr_items i WHERE i.pr_id=v_id),'أوّل');
  PERFORM pr_link_purchase_order(v_id,'PO-CL-2',
    (SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'qty',1)) FROM proc_pr_items i WHERE i.pr_id=v_id),'ثانٍ');
  SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) INTO v_msg;
  UPDATE proc_purchase_orders SET status='تسليم كامل' WHERE po_number='PO-CL-1';
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state = 'closed' THEN RAISE EXCEPTION 'CL8 فشل: أُقفِل والأمر الثاني لم يُستلَم'; END IF;
  RAISE NOTICE 'CL8 ✅ لم يُقفَل — أمرٌ ثانٍ لم يكتمل (%)', v_state;

  -- ══════════════ CL9: وباكتمال الثاني يُقفَل ══════════════
  UPDATE proc_purchase_orders SET status='تسليم كامل' WHERE po_number='PO-CL-2';
  SELECT workflow_state INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'closed' THEN RAISE EXCEPTION 'CL9 فشل: %', v_state; END IF;
  RAISE NOTICE 'CL9 ✅ اكتمال كل الأوامر أقفل الطلب';

  -- ══════════════ CL10: المُقفَل لا يُلغى ══════════════
  PERFORM set_config('request.jwt.claims','{"email":"cl_proc@aldeyabi.com"}',true);
  v_ok := false;
  BEGIN PERFORM pr_cancel_request(v_id,'محاولة بعد الإقفال');
  EXCEPTION WHEN others THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'CL10 فشل: أُلغي طلب مُقفَل'; END IF;
  RAISE NOTICE 'CL10 ✅ المُقفَل لا يُلغى (يُصحَّح بمرتجع)';

  -- ══════════════ CL11: لا تُؤرشَف طلبات قيد العمل ══════════════
  v_id2 := _cl_make_request('قيد العمل');
  PERFORM set_config('request.jwt.claims','{"email":"cl_proc@aldeyabi.com"}',true);
  v_ok := false;
  BEGIN PERFORM pr_set_archived(v_id2,true);
  EXCEPTION WHEN others THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'CL11 فشل: أُرشِف طلب قيد العمل'; END IF;
  RAISE NOTICE 'CL11 ✅ الأرشفة ممنوعة على طلب قيد العمل';

  -- ══════════════ CL12: الأرشفة صلاحية مشتريات + يمكن إلغاؤها ══════════════
  PERFORM set_config('request.jwt.claims','{"email":"cl_req@aldeyabi.com"}',true);
  v_ok := false;
  BEGIN PERFORM pr_set_archived(v_id,false);
  EXCEPTION WHEN others THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'CL12 فشل: المقدّم أرشف/أظهر'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"cl_proc@aldeyabi.com"}',true);
  PERFORM pr_set_archived(v_id,false);
  SELECT (archived_at IS NULL)::text INTO v_state FROM proc_purchase_requests WHERE id=v_id;
  IF v_state <> 'true' THEN RAISE EXCEPTION 'CL12 فشل: لم تُرفَع الأرشفة'; END IF;
  RAISE NOTICE 'CL12 ✅ الأرشفة صلاحية مشتريات وقابلة للرفع';

  RAISE NOTICE '── CL1–CL12 كلها ناجحة ──';
END $t$;

DROP FUNCTION IF EXISTS _cl_make_request(text);

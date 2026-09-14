\set ON_ERROR_STOP on

-- Launch workspace: profiles, two gates, atomic creation, and many-to-many PO links.
-- Test fixtures are trusted provisioning data. The production guard intentionally
-- rejects these account/configuration writes for ordinary authenticated users.
SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

DO $upgrade_regression$
BEGIN
  IF coalesce((SELECT (pr_permission_overrides->>'pr_view_financials')::boolean
               FROM proc_users WHERE username='ws_legacy_office'),false) IS NOT TRUE THEN
    RAISE EXCEPTION 'WS30 existing unscoped office amount visibility was not preserved';
  END IF;
  IF coalesce((SELECT (pr_permission_overrides->>'pr_view_financials')::boolean
               FROM proc_users WHERE username='ws_legacy_scoped'),false) IS TRUE THEN
    RAISE EXCEPTION 'WS31 scoped account received amount visibility';
  END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public'
      AND tablename IN ('proc_pr_attachments','proc_pr_audit')
      AND policyname='no_scoped_access' AND permissive='RESTRICTIVE')<>2 THEN
    RAISE EXCEPTION 'WS32 restrictive lockdown policies were removed';
  END IF;

  PERFORM set_config('request.jwt.claims','{"email":"ws_legacy_office@aldeyabi.com","role":"authenticated"}',true);
  IF NOT proc_can_view_amounts() THEN RAISE EXCEPTION 'WS33 office amount behavior regressed'; END IF;
  IF NOT pr_has_perm('can_create_pr') OR NOT pr_has_perm('can_comment') THEN
    RAISE EXCEPTION 'WS34 compatibility permission mapping failed';
  END IF;
  PERFORM set_config('request.jwt.claims','{"email":"ws_legacy_scoped@aldeyabi.com","role":"authenticated"}',true);
  IF proc_can_view_amounts() THEN RAISE EXCEPTION 'WS35 scoped amount behavior regressed'; END IF;
  IF pr_has_perm('can_create_pr') OR pr_has_perm('can_upload_docs') OR pr_has_perm('can_comment') THEN
    RAISE EXCEPTION 'WS35 scoped opt-in behavior regressed';
  END IF;
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
END
$upgrade_regression$;

INSERT INTO proc_users(username,display_name,email,role,permissions,active,department_id)
VALUES
 ('requester1','طالب الصيانة','requester1@aldeyabi.com','user','{}',true,'DEP-MAINT'),
 ('requester2','موظف بلا اعتماد','requester2@aldeyabi.com','user','{}',true,'DEP-MAINT'),
 ('maintmgr','مدير الصيانة','maintmgr@aldeyabi.com','user','{}',true,'DEP-MAINT'),
 ('procmgr','مدير المشتريات','procmgr@aldeyabi.com','user','{}',true,NULL),
 ('buyer1','موظف المشتريات','buyer1@aldeyabi.com','user','{}',true,NULL)
ON CONFLICT(username) DO UPDATE SET active=true;

UPDATE proc_users SET pr_profile_key='requester' WHERE username='requester1';
UPDATE proc_users SET pr_profile_key='requester' WHERE username='requester2';
UPDATE proc_users SET pr_profile_key='maintenance_manager' WHERE username='maintmgr';
UPDATE proc_users SET pr_profile_key='procurement_manager' WHERE username='procmgr';
UPDATE proc_users SET pr_profile_key='procurement_officer' WHERE username='buyer1';

-- WS41–WS43: an ordinary user cannot self-assign any workspace authority or
-- widen their department scope through the otherwise broad users UPDATE path.
DO $workspace_user_guard$
DECLARE blocked boolean := false; n integer := 0;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  PERFORM set_config('role','authenticated',true);
  BEGIN
    UPDATE proc_users
       SET pr_profile_key='module_admin',
           pr_permission_overrides='{"pr_view_financials":true,"pr_manage_users":true,"pr_view_all":true}'::jsonb,
           pr_department_ids=ARRAY['DEP-FINANCE'],
           department_id='DEP-FINANCE'
     WHERE username='requester1';
  EXCEPTION WHEN OTHERS THEN blocked := true;
  END;
  PERFORM set_config('role','postgres',true);
  IF NOT blocked THEN RAISE EXCEPTION 'WS41 self-escalation through workspace columns was accepted'; END IF;
  IF EXISTS(SELECT 1 FROM proc_users WHERE username='requester1'
            AND (pr_profile_key<>'requester' OR pr_permission_overrides<>'{}'::jsonb
                 OR cardinality(pr_department_ids)>0 OR department_id<>'DEP-MAINT')) THEN
    RAISE EXCEPTION 'WS42 rejected self-escalation changed the stored profile';
  END IF;

  -- Harmless profile activity is still writable, preserving the original guard contract.
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  PERFORM set_config('role','authenticated',true);
  UPDATE proc_users SET last_login=now() WHERE username='requester1';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('role','postgres',true);
  IF n<>1 THEN RAISE EXCEPTION 'WS43 harmless last_login update was blocked'; END IF;
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
END
$workspace_user_guard$;

INSERT INTO proc_departments(id,name_ar,sector,manager_user,active)
VALUES('DEP-MAINT','إدارة الصيانة والتشغيل','الصيانة والتشغيل','maintmgr',true)
ON CONFLICT(id) DO UPDATE SET manager_user='maintmgr',active=true;

INSERT INTO proc_settings(key,value) VALUES('projects_registry',
 '{"version":1,"projects":[{"id":"PRJ-1","name":"مشروع المقر الرئيسي","active":true}]}'::jsonb)
ON CONFLICT(key) DO UPDATE SET value=excluded.value;

INSERT INTO proc_purchase_orders(po_number,project,supplier,status,total)
VALUES('PO-TEST-1','مشروع المقر الرئيسي','مورد الاختبار','صادر',1500)
ON CONFLICT(po_number) DO NOTHING;

SELECT set_config('request.jwt.claims','{}',false);

DO $test$
DECLARE r jsonb; v_id text; v_item bigint; v_draft text;
BEGIN
  -- requester: server number + atomic header/items + exactly two stages.
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    '{"title":"مواد صيانة دورية","department_id":"DEP-MAINT","department":"إدارة الصيانة والتشغيل","project":"مشروع المقر الرئيسي","priority":"عالي","requester_name":"طالب الصيانة"}'::jsonb,
    '[{"description":"فلتر تكييف","unit":"حبة","requested_qty":10}]'::jsonb,
    true,NULL);
  IF NOT coalesce((r->>'ok')::boolean,false) THEN RAISE EXCEPTION 'WS1 failed'; END IF;
  v_id := r->>'id';
  IF v_id !~ '^PR-DG[0-9]{4}-[0-9]{4,}$' THEN RAISE EXCEPTION 'WS2 server number failed: %',v_id; END IF;
  IF (SELECT count(*) FROM proc_pr_approvals WHERE pr_id=v_id)<>2 THEN RAISE EXCEPTION 'WS3 approval count'; END IF;
  IF (SELECT workflow_state FROM proc_purchase_requests WHERE id=v_id)<>'maintenance_review' THEN RAISE EXCEPTION 'WS4 first gate'; END IF;
  IF NOT EXISTS(SELECT 1 FROM proc_purchase_requests WHERE id=v_id
                AND department='إدارة الصيانة والتشغيل' AND sector='الصيانة والتشغيل'
                AND requester_name='طالب الصيانة') THEN
    RAISE EXCEPTION 'WS25 authoritative organization or requester identity failed';
  END IF;
  IF NOT proc_can_see_pr(v_id) THEN RAISE EXCEPTION 'WS36 requester cannot see own request'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"requester2@aldeyabi.com","role":"authenticated"}',true);
  IF proc_can_see_pr(v_id) THEN RAISE EXCEPTION 'WS37 unrelated requester can see another request'; END IF;

  -- maintenance manager gate.
  PERFORM set_config('request.jwt.claims','{"email":"maintmgr@aldeyabi.com","role":"authenticated"}',true);
  IF NOT proc_can_see_pr(v_id) THEN RAISE EXCEPTION 'WS38 assigned manager cannot see request'; END IF;
  r := pr_decide(v_id,'approve','الحاجة مؤكدة حسب خطة الصيانة');
  IF r->>'workflow_state'<>'procurement_review' THEN RAISE EXCEPTION 'WS5 maintenance decision'; END IF;

  -- procurement manager authorizes pricing.
  PERFORM set_config('request.jwt.claims','{"email":"procmgr@aldeyabi.com","role":"authenticated"}',true);
  r := pr_decide(v_id,'approve','ابدأ التسعير والمقارنة');
  IF r->>'workflow_state'<>'pricing' THEN RAISE EXCEPTION 'WS6 procurement decision'; END IF;
  IF (SELECT status FROM proc_purchase_requests WHERE id=v_id)<>'approved' THEN RAISE EXCEPTION 'WS7 approved status'; END IF;

  -- allocation is guarded and updates coverage.
  SELECT id INTO v_item FROM proc_pr_items WHERE pr_id=v_id LIMIT 1;
  PERFORM set_config('request.jwt.claims','{"email":"buyer1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_link_purchase_order(v_id,'PO-TEST-1',jsonb_build_array(jsonb_build_object('item_id',v_item,'qty',6)), 'دفعة أولى');
  IF round((r->>'coverage')::numeric,2)<>0.60 THEN RAISE EXCEPTION 'WS8 coverage: %',r; END IF;
  IF (SELECT workflow_state FROM proc_purchase_requests WHERE id=v_id)<>'partially_ordered' THEN RAISE EXCEPTION 'WS9 partial state'; END IF;

  -- Replacing an existing link must exclude its old allocations from validation.
  r := pr_link_purchase_order(v_id,'PO-TEST-1',jsonb_build_array(jsonb_build_object('item_id',v_item,'qty',5)), 'تعديل التوزيع');
  IF round((r->>'coverage')::numeric,2)<>0.50 THEN RAISE EXCEPTION 'WS10 replacement coverage: %',r; END IF;
  IF (SELECT count(*) FROM proc_pr_item_allocations a JOIN proc_pr_po_links l ON l.id=a.link_id
      WHERE l.pr_id=v_id AND l.po_number='PO-TEST-1' AND l.active)<>1 THEN RAISE EXCEPTION 'WS11 replacement duplicated allocation'; END IF;

  BEGIN
    PERFORM pr_link_purchase_order(v_id,'PO-TEST-1',jsonb_build_array(jsonb_build_object('item_id',v_item,'qty',11)), 'تجاوز');
    RAISE EXCEPTION 'WS12 over-allocation accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='WS12 over-allocation accepted' THEN RAISE; END IF;
  END;

  r := pr_register_attachment(v_id,'docs/pr/'||v_id||'/test.pdf','مخطط فني.pdf','technical','application/pdf',4096);
  IF NOT coalesce((r->>'ok')::boolean,false) OR (SELECT count(*) FROM proc_pr_attachments WHERE pr_id=v_id)<>1 THEN
    RAISE EXCEPTION 'WS13 attachment registration failed';
  END IF;

  -- A second request can link to the same PO: PO↔PR is truly many-to-many.
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    '{"title":"طلب صيانة ثان","department_id":"DEP-MAINT","department":"إدارة الصيانة والتشغيل","project":"مشروع المقر الرئيسي","priority":"متوسط"}'::jsonb,
    '[{"description":"سير مكيف","unit":"حبة","requested_qty":2}]'::jsonb,true,NULL);
  v_id := r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"maintmgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM pr_decide(v_id,'approve','معتمد');
  PERFORM set_config('request.jwt.claims','{"email":"procmgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM pr_decide(v_id,'approve','ابدأ');
  SELECT id INTO v_item FROM proc_pr_items WHERE pr_id=v_id LIMIT 1;
  PERFORM set_config('request.jwt.claims','{"email":"buyer1@aldeyabi.com","role":"authenticated"}',true);
  PERFORM pr_link_purchase_order(v_id,'PO-TEST-1',jsonb_build_array(jsonb_build_object('item_id',v_item,'qty',2)),NULL);
  IF (SELECT count(DISTINCT pr_id) FROM proc_pr_po_links WHERE po_number='PO-TEST-1' AND active)<>2 THEN
    RAISE EXCEPTION 'WS14 same PO did not aggregate requests';
  END IF;

  -- View-all procurement access must not allow editing another employee's draft.
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    '{"title":"مسودة محمية","department_id":"DEP-MAINT","department":"اسم مزور","sector":"قطاع مزور","project":"مشروع المقر الرئيسي"}'::jsonb,
    '[{"description":"قطعة غيار","unit":"حبة","requested_qty":1}]'::jsonb,false,NULL);
  v_draft := r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"maintmgr@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM pr_save_request(
      '{"title":"تعديل غير مصرح","department_id":"DEP-MAINT","project":"مشروع المقر الرئيسي"}'::jsonb,
      '[{"description":"قطعة غيار","unit":"حبة","requested_qty":1}]'::jsonb,false,v_draft);
    RAISE EXCEPTION 'WS26 unauthorized draft edit accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='WS26 unauthorized draft edit accepted' THEN RAISE; END IF;
    IF SQLERRM<>'لا يمكنك تعديل طلب مستخدم آخر' THEN RAISE EXCEPTION 'WS26 unexpected denial: %',SQLERRM; END IF;
  END;

  -- A delegate must be active and carry the permission required by the gate.
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  UPDATE proc_users SET is_away=true,delegate_to='requester2' WHERE username='maintmgr';
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    '{"title":"اختبار التفويض","department_id":"DEP-MAINT","project":"مشروع المقر الرئيسي"}'::jsonb,
    '[{"description":"مادة اختبار","unit":"حبة","requested_qty":1}]'::jsonb,true,NULL);
  v_id := r->>'id';
  PERFORM set_config('request.jwt.claims','{"email":"requester2@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM pr_decide(v_id,'approve','محاولة بلا صلاحية');
    RAISE EXCEPTION 'WS27 unqualified delegate approved';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='WS27 unqualified delegate approved' THEN RAISE; END IF;
    IF SQLERRM<>'هذه المرحلة ليست مسندة إليك' THEN RAISE EXCEPTION 'WS27 unexpected denial: %',SQLERRM; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  UPDATE proc_users SET is_away=false,delegate_to=NULL WHERE username='maintmgr';

  -- Separation of duties applies even when the requester owns the approval profile.
  PERFORM set_config('request.jwt.claims','{"email":"maintmgr@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    '{"title":"اختبار فصل المهام","department_id":"DEP-MAINT","project":"مشروع المقر الرئيسي"}'::jsonb,
    '[{"description":"مادة اختبار","unit":"حبة","requested_qty":1}]'::jsonb,true,NULL);
  v_id := r->>'id';
  BEGIN
    PERFORM pr_decide(v_id,'approve','اعتماد ذاتي');
    RAISE EXCEPTION 'WS28 requester self-approval accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='WS28 requester self-approval accepted' THEN RAISE; END IF;
    IF SQLERRM<>'لا يجوز لمقدم الطلب اعتماد طلبه' THEN RAISE EXCEPTION 'WS28 unexpected denial: %',SQLERRM; END IF;
  END;

  -- The historical RFQ award-approval panel remains usable through guarded RPCs.
  PERFORM set_config('request.jwt.claims','{"email":"buyer1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_submit_award_request('ترسية اختبار','مورد الاختبار',100,'{}'::jsonb,1);
  v_id := r->>'id';
  IF v_id NOT LIKE 'apr_%' THEN RAISE EXCEPTION 'WS39 award request id'; END IF;
  PERFORM set_config('request.jwt.claims','{"email":"procmgr@aldeyabi.com","role":"authenticated"}',true);
  r := pr_decide_award_request(v_id,true,'موافق');
  IF r->>'status'<>'approved' THEN RAISE EXCEPTION 'WS40 award decision compatibility'; END IF;
END $test$;

DO $grants$
BEGIN
  IF has_table_privilege('authenticated','proc_purchase_requests','UPDATE') THEN RAISE EXCEPTION 'WS15 direct request update granted'; END IF;
  IF has_table_privilege('authenticated','proc_pr_approvals','UPDATE') THEN RAISE EXCEPTION 'WS16 direct approval update granted'; END IF;
  IF has_table_privilege('authenticated','proc_pr_attachments','INSERT') THEN RAISE EXCEPTION 'WS17 direct attachment insert granted'; END IF;
  IF has_table_privilege('authenticated','proc_departments','DELETE') THEN RAISE EXCEPTION 'WS18 department hard delete granted'; END IF;
  IF has_table_privilege('authenticated','proc_approval_rules','DELETE') THEN RAISE EXCEPTION 'WS19 workflow hard delete granted'; END IF;
  IF NOT has_function_privilege('authenticated','pr_save_request(jsonb,jsonb,boolean,text)','EXECUTE') THEN RAISE EXCEPTION 'WS20 save RPC missing'; END IF;
  IF NOT has_function_privilege('authenticated','pr_decide(text,text,text)','EXECUTE') THEN RAISE EXCEPTION 'WS21 decision RPC missing'; END IF;
  IF NOT has_function_privilege('authenticated','pr_register_attachment(text,text,text,text,text,bigint)','EXECUTE') THEN RAISE EXCEPTION 'WS22 attachment RPC missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='proc_departments'
                 AND policyname='pr_department_update' AND qual LIKE '%pr_manage_workflows%') THEN
    RAISE EXCEPTION 'WS23 department workflow-admin policy missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='proc_approval_rules'
                 AND policyname='pr_rule_delete_deny' AND qual='false') THEN
    RAISE EXCEPTION 'WS24 workflow hard-delete deny policy missing';
  END IF;
  IF has_function_privilege('anon','pr_effective_permissions(text)','EXECUTE')
     OR has_function_privilege('anon','proc_can_see_pr(text)','EXECUTE') THEN
    RAISE EXCEPTION 'WS29 anonymous helper execution granted';
  END IF;
END $grants$;

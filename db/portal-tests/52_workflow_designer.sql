-- ════════════════════════════════════════════════════════════════════════════
--  52 — حفظ مسار الاعتماد من المصمّم (P0-1u، تكليف المالك C6) + عقد انتقالي آمن
--  (مراجعة Gate): المصمّم كان عنصراً ميّتاً (تحرير في الذاكرة بلا حفظ). الآن RPC أدمن
--  محروس يحفظ/يحذف بتحقّق بنيوي + فشل-مغلق (مرحلة دور بلا معتمِد ممكن / seq مكرّر).
--  العقد الانتقالي المُثبَت: تعديل المسار **لا يُعيد كتابة** سلسلة طلب قيد التنفيذ
--  (اللقطة مثبَّتة في portal_approvals وقت الإنشاء). ليس محرّك Stage-5 المُصدَّر — انتقالي فقط.
--  الهويّة عبر request.jwt.claims (auth.jwt()). يُشغَّل بعد p0_1b.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $acl$
BEGIN
  IF has_function_privilege('anon','portal_save_workflow(text,text,integer,text,numeric,numeric,jsonb,text)','EXECUTE')
     OR has_function_privilege('anon','portal_delete_workflow(text)','EXECUTE') THEN
    RAISE EXCEPTION 'WF12 FAIL: anon retains EXECUTE on a workflow mutation RPC';
  END IF;
  RAISE NOTICE 'PASS WF12 anon cannot execute workflow mutation RPCs';
END $acl$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 't52_%';
  DELETE FROM portal_workflows WHERE id LIKE 't52_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('t52_admin','t52_admin@aldeyabi.com','أدمن','admin','{}','GA'),
    ('t52_mgr','t52_mgr@aldeyabi.com','مدير مستخدمين (غير أدمن)','user','{"can_manage_users":true}','GA'),
    ('t52_appr','t52_appr@aldeyabi.com','معتمِد مرحلة','user','{"can_approve_stage":true}','OPS'),
    ('t52_fin','t52_fin@aldeyabi.com','مالية','user','{"can_approve_finance":true}','GA'),
    ('t52_req','t52_req@aldeyabi.com','مقدّم','user','{"can_create":true}','OPS');
  UPDATE portal_departments SET manager_user='t52_appr' WHERE id='OPS';
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $t$
DECLARE v_stages jsonb; v_cnt int; v_id text; v_wf text; v_snap1 jsonb; v_snap2 jsonb; v_st text; v_seq int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"t52_admin@aldeyabi.com","role":"authenticated"}',true);

  -- WF1 حفظ مسار جديد (مرحلتان: مدير قسم ثم دور مالي reachable عبر t52_fin)
  PERFORM portal_save_workflow('t52_wf','مسار اختبار',30,'الإدارة العامة',0,NULL,
    '[{"seq":1,"label":"مدير القسم","resolver":"dept_manager"},
      {"seq":2,"label":"التحقق المالي","resolver":"role","role_key":"can_approve_finance"}]'::jsonb,'need');
  SELECT stages, jsonb_array_length(stages) INTO v_stages, v_cnt FROM portal_workflows WHERE id='t52_wf' AND active;
  IF v_cnt IS DISTINCT FROM 2 OR (v_stages->1->>'role_key') <> 'can_approve_finance' THEN
    RAISE EXCEPTION 'WF1 FAIL: not persisted correctly (cnt=%, stages=%)', v_cnt, v_stages; END IF;
  RAISE NOTICE 'PASS WF1 admin saves a workflow (persisted with stages)';

  -- WF2 upsert يحدّث المراحل
  PERFORM portal_save_workflow('t52_wf','مسار اختبار',30,'الإدارة العامة',0,NULL,
    '[{"seq":1,"label":"مدير القسم","resolver":"dept_manager"}]'::jsonb,'need');
  SELECT jsonb_array_length(stages) INTO v_cnt FROM portal_workflows WHERE id='t52_wf';
  IF v_cnt IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'WF2 FAIL: upsert did not update (cnt=%)', v_cnt; END IF;
  RAISE NOTICE 'PASS WF2 upsert updates an existing workflow';

  -- WF3 مُحلّل غير صالح مرفوض
  BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,'[{"seq":1,"label":"ط","resolver":"whoever"}]'::jsonb,'need');
    RAISE EXCEPTION 'WF3 FAIL'; EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF3 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF3 invalid resolver rejected'; END;

  -- WF4 مفتاح دور غير معروف مرفوض
  BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,'[{"seq":1,"label":"ط","resolver":"role","role_key":"can_bogus"}]'::jsonb,'need');
    RAISE EXCEPTION 'WF4 FAIL'; EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF4 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF4 unknown role_key rejected'; END;

  -- WF5 معتمِد (user) غير موجود مرفوض
  BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,'[{"seq":1,"label":"ط","resolver":"user","approver":"ghost_user"}]'::jsonb,'need');
    RAISE EXCEPTION 'WF5 FAIL'; EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF5 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF5 non-existent user approver rejected'; END;

  -- WF5b معتمِد موجود مقبول
  PERFORM portal_save_workflow('t52_wf2','مسار مستخدم',31,NULL,0,NULL,'[{"seq":1,"label":"معتمِد","resolver":"user","approver":"t52_appr"}]'::jsonb,'need');
  IF NOT EXISTS(SELECT 1 FROM portal_workflows WHERE id='t52_wf2' AND active) THEN RAISE EXCEPTION 'WF5b FAIL'; END IF;
  RAISE NOTICE 'PASS WF5b valid user approver accepted';

  -- WF6 مراحل فارغة مرفوضة
  BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,'[]'::jsonb,'need');
    RAISE EXCEPTION 'WF6 FAIL'; EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF6 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF6 empty stages rejected'; END;

  -- WF7 حذف مسار غير مستخدَم → يُحذف
  PERFORM portal_delete_workflow('t52_wf2');
  IF EXISTS(SELECT 1 FROM portal_workflows WHERE id='t52_wf2') THEN RAISE EXCEPTION 'WF7 FAIL'; END IF;
  RAISE NOTICE 'PASS WF7 unused workflow deleted';

  -- WF10 فشل-مغلق (حتميّ): نعطّل مؤقّتاً أي حامل نشط لـcan_approve_disbursement داخل
  -- معاملة فرعية تُرجَع بالكامل، فنثبت أنّ مرحلة دور بلا معتمِد ممكن تُرفض قبل النشر.
  BEGIN
    PERFORM set_config('app.portal_transition','1',true);
    UPDATE portal_users SET active=false
      WHERE active AND coalesce((permissions->>'can_approve_disbursement')::boolean,false);
    PERFORM set_config('app.portal_transition','0',true);
    BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,'[{"seq":1,"label":"صرف","resolver":"role","role_key":"can_approve_disbursement"}]'::jsonb,'need');
      RAISE EXCEPTION 'WF10 FAIL: unreachable role stage accepted';
    EXCEPTION WHEN OTHERS THEN
      IF sqlerrm LIKE 'WF10 FAIL%' THEN RAISE; END IF;
      IF sqlerrm NOT LIKE '%بلا معتمِد ممكن%' THEN RAISE EXCEPTION 'WF10 FAIL: wrong reason: %', sqlerrm; END IF;
    END;
    RAISE EXCEPTION 'WF10_ROLLBACK';   -- تراجع عن التعطيل المؤقّت
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm = 'WF10_ROLLBACK' THEN RAISE NOTICE 'PASS WF10 unreachable role stage fails closed (holders temp-disabled, rolled back)';
    ELSE RAISE; END IF;
  END;

  -- WF11 فشل-مغلق: أرقام seq مكرّرة مرفوضة
  BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,
      '[{"seq":1,"label":"أ","resolver":"dept_manager"},{"seq":1,"label":"ب","resolver":"dept_manager"}]'::jsonb,'need');
    RAISE EXCEPTION 'WF11 FAIL: duplicate seq accepted';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF11 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF11 duplicate seq rejected'; END;

  -- WF9 [العقد الانتقالي] تعديل المسار لا يُعيد كتابة سلسلة طلب قيد التنفيذ (اللقطة مثبَّتة)
  PERFORM set_config('request.jwt.claims','{"email":"t52_req@aldeyabi.com","role":"authenticated"}',true);
  v_id := (portal_create_request('طلب لقطة','OPS','متوسط',
            '[{"desc":"بند","unit":"عدد","qty":1,"price":1000}]','مشروع', (now()+interval '7 day')::date))->>'id';
  SELECT workflow_id, status, current_seq INTO v_wf, v_st, v_seq FROM portal_requests WHERE id=v_id;
  SELECT jsonb_agg(to_jsonb(a) ORDER BY a.seq) INTO v_snap1 FROM portal_approvals a WHERE a.request_id=v_id AND a.cycle='need';
  IF v_snap1 IS NULL THEN RAISE EXCEPTION 'WF9 FAIL: no chain snapshot after submit'; END IF;
  -- الأدمن يعدّل نفس المسار الحاكم (مرحلة واحدة مختلفة تماماً)
  PERFORM set_config('request.jwt.claims','{"email":"t52_admin@aldeyabi.com","role":"authenticated"}',true);
  PERFORM portal_save_workflow(v_wf, coalesce((SELECT name FROM portal_workflows WHERE id=v_wf),'مسار'),
    coalesce((SELECT priority FROM portal_workflows WHERE id=v_wf),50),
    (SELECT sector FROM portal_workflows WHERE id=v_wf), 0, NULL,
    '[{"seq":1,"label":"مرحلة معدَّلة كليّاً","resolver":"user","approver":"t52_fin"}]'::jsonb,'need');
  SELECT jsonb_agg(to_jsonb(a) ORDER BY a.seq) INTO v_snap2 FROM portal_approvals a WHERE a.request_id=v_id AND a.cycle='need';
  IF v_snap1 IS DISTINCT FROM v_snap2 THEN
    RAISE EXCEPTION 'WF9 FAIL: in-flight request chain was rewritten by a workflow edit'; END IF;
  PERFORM 1 FROM portal_requests WHERE id=v_id AND status=v_st AND current_seq=v_seq;
  IF NOT FOUND THEN RAISE EXCEPTION 'WF9 FAIL: in-flight request status/seq changed by a workflow edit'; END IF;
  RAISE NOTICE 'PASS WF9 workflow edit does NOT rewrite an in-flight request (immutable snapshot)';

  -- WF8 غير الأدمن مرفوض
  PERFORM set_config('request.jwt.claims','{"email":"t52_mgr@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_save_workflow('t52_x','x',10,NULL,0,NULL,'[{"seq":1,"label":"ط","resolver":"dept_manager"}]'::jsonb,'need');
    RAISE EXCEPTION 'WF8 FAIL'; EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF8 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF8 non-admin blocked from saving workflows'; END;
END $t$;

-- تنظيف متسامح: لا نحذف الطلب المُنشأ (تدقيقه append-only غير قابل للحذف — بالتصميم)؛
-- القاعدة CI مؤقّتة و52 آخر ملف. نُعيد مدير OPS ونحذف مسارات/مستخدمي t52 القابلين للحذف.
DO $c$ BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  BEGIN UPDATE portal_departments SET manager_user=NULL WHERE id='OPS' AND manager_user='t52_appr'; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM portal_workflows WHERE id LIKE 't52_%'; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN DELETE FROM portal_users WHERE username LIKE 't52_%'
    AND username NOT IN (SELECT requester FROM portal_requests WHERE requester IS NOT NULL);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM set_config('app.portal_transition','0',true);
END $c$;

SELECT '════ WORKFLOW DESIGNER PERSIST + عقد انتقالي (P0-1u): WF1..WF12 PASS ════' AS result;

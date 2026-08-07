-- ════════════════════════════════════════════════════════════════════════════
--  52 — حفظ مسار الاعتماد من المصمّم (P0-1u، تكليف المالك C6)
--  المصمّم كان يحرّر في الذاكرة بلا حفظ (عنصر ميّت). الآن RPC أدمن محروس يحفظ/يحذف
--  المسارات مع تحقّق بنيوي — والحوكمة (SoD/deny-by-default) مستقلّة عن تصميم المسار.
--  الهويّة عبر request.jwt.claims (auth.jwt()). يُشغَّل بعد p0_1b.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 't52_%';
  DELETE FROM portal_workflows WHERE id LIKE 't52_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('t52_admin','t52_admin@aldeyabi.com','أدمن','admin','{}','GA'),
    ('t52_mgr','t52_mgr@aldeyabi.com','مدير مستخدمين (غير أدمن)','user','{"can_manage_users":true}','GA'),
    ('t52_appr','t52_appr@aldeyabi.com','معتمِد','user','{"can_approve_stage":true}','GA');
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $t$
DECLARE v_stages jsonb; v_cnt int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"t52_admin@aldeyabi.com","role":"authenticated"}',true);

  -- WF1 الأدمن يحفظ مساراً جديداً (مرحلتان: مدير قسم ثم دور مالي) → يُخزَّن بمراحله
  PERFORM portal_save_workflow('t52_wf','مسار اختبار','30','الإدارة العامة',0,NULL,
    '[{"seq":1,"label":"مدير القسم","resolver":"dept_manager"},
      {"seq":2,"label":"التحقق المالي","resolver":"role","role_key":"can_approve_finance"}]'::jsonb,'need');
  SELECT stages, jsonb_array_length(stages) INTO v_stages, v_cnt FROM portal_workflows WHERE id='t52_wf' AND active;
  IF v_cnt IS DISTINCT FROM 2 OR (v_stages->1->>'role_key') <> 'can_approve_finance' THEN
    RAISE EXCEPTION 'WF1 FAIL: workflow not persisted correctly (cnt=%, stages=%)', v_cnt, v_stages; END IF;
  RAISE NOTICE 'PASS WF1 admin saves a workflow (persisted with stages)';

  -- WF2 التعديل (upsert) يحدّث المراحل
  PERFORM portal_save_workflow('t52_wf','مسار اختبار','30','الإدارة العامة',0,NULL,
    '[{"seq":1,"label":"مدير القسم","resolver":"dept_manager"}]'::jsonb,'need');
  SELECT jsonb_array_length(stages) INTO v_cnt FROM portal_workflows WHERE id='t52_wf';
  IF v_cnt IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'WF2 FAIL: upsert did not update stages (cnt=%)', v_cnt; END IF;
  RAISE NOTICE 'PASS WF2 upsert updates an existing workflow';

  -- WF3 مُحلّل غير صالح مرفوض
  BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,'[{"seq":1,"label":"ط","resolver":"whoever"}]'::jsonb,'need');
    RAISE EXCEPTION 'WF3 FAIL: invalid resolver accepted';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF3 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF3 invalid resolver rejected'; END;

  -- WF4 مفتاح دور غير معروف مرفوض
  BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,'[{"seq":1,"label":"ط","resolver":"role","role_key":"can_bogus"}]'::jsonb,'need');
    RAISE EXCEPTION 'WF4 FAIL: unknown role_key accepted';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF4 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF4 unknown role_key rejected'; END;

  -- WF5 معتمِد (user) غير موجود مرفوض
  BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,'[{"seq":1,"label":"ط","resolver":"user","approver":"ghost_user"}]'::jsonb,'need');
    RAISE EXCEPTION 'WF5 FAIL: non-existent approver accepted';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF5 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF5 non-existent user approver rejected'; END;

  -- WF5b معتمِد موجود (user) مقبول
  PERFORM portal_save_workflow('t52_wf2','مسار مستخدم',31,NULL,0,NULL,'[{"seq":1,"label":"معتمِد محدَّد","resolver":"user","approver":"t52_appr"}]'::jsonb,'need');
  IF NOT EXISTS(SELECT 1 FROM portal_workflows WHERE id='t52_wf2' AND active) THEN RAISE EXCEPTION 'WF5b FAIL: valid user approver rejected'; END IF;
  RAISE NOTICE 'PASS WF5b valid user approver accepted';

  -- WF6 مراحل فارغة مرفوضة
  BEGIN PERFORM portal_save_workflow('t52_bad','x',10,NULL,0,NULL,'[]'::jsonb,'need');
    RAISE EXCEPTION 'WF6 FAIL: empty stages accepted';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF6 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF6 empty stages rejected'; END;

  -- WF7 حذف مسار غير مستخدَم → يُحذف فعليّاً
  PERFORM portal_delete_workflow('t52_wf2');
  IF EXISTS(SELECT 1 FROM portal_workflows WHERE id='t52_wf2') THEN RAISE EXCEPTION 'WF7 FAIL: unused workflow not deleted'; END IF;
  RAISE NOTICE 'PASS WF7 unused workflow deleted';

  -- WF8 غير الأدمن مرفوض
  PERFORM set_config('request.jwt.claims','{"email":"t52_mgr@aldeyabi.com","role":"authenticated"}',true);
  BEGIN PERFORM portal_save_workflow('t52_x','x',10,NULL,0,NULL,'[{"seq":1,"label":"ط","resolver":"dept_manager"}]'::jsonb,'need');
    RAISE EXCEPTION 'WF8 FAIL: non-admin saved a workflow';
  EXCEPTION WHEN OTHERS THEN IF sqlerrm LIKE 'WF8 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS WF8 non-admin blocked from saving workflows (%.40)', left(sqlerrm,40); END;
END $t$;

DO $c$ BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_workflows WHERE id LIKE 't52_%';
  DELETE FROM portal_users WHERE username LIKE 't52_%';
  PERFORM set_config('app.portal_transition','0',true);
END $c$;

SELECT '════ WORKFLOW DESIGNER PERSIST (P0-1u): WF1..WF8 = 9/9 PASS ════' AS result;

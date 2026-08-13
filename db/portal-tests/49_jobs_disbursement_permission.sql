-- ════════════════════════════════════════════════════════════════════════════
--  49 — إسناد صلاحية الصرف can_approve_disbursement للوظائف (P0-1r، تكليف المالك A2)
--  محرّك الصرف (050) أدخل مفتاح can_approve_disbursement لكنّ قائمة portal_save_job
--  البيضاء (v_allowed) لم تُدرِجه، فكان مدير البوابة يعجز عن إنشاء/تعديل أي وظيفة
--  تمنح اعتماد الصرف («مفتاح صلاحية غير معروف»). P0-1r يسدّ الفجوة مع إبقاء الحوكمة:
--  المفتاح حسّاس ⇒ صكّه/إسناده يتطلّب أدمن كاملاً (منع التصعيد الذاتي).
--  الهويّة عبر request.jwt.claims (auth.jwt() مُحاكاة Supabase). RAISE ⇒ خروج غير صفري.
--  يُشغَّل بعد p0_1b (إزالة تجاوز session_user) كي تبيت السلبيات فعليّاً.
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
  DELETE FROM portal_users WHERE username LIKE 't49_%';
  DELETE FROM portal_jobs  WHERE key LIKE 't49_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions,department_id) VALUES
    ('t49_admin','t49_admin@aldeyabi.com','أدمن الاختبار','admin','{}','GA'),
    ('t49_mgr','t49_mgr@aldeyabi.com','مدير مستخدمين (غير أدمن)','user','{"can_manage_users":true}','GA'),
    ('t49_target','t49_target@aldeyabi.com','هدف الإسناد','user','{"can_create":true}','GA'),
    ('t49_target2','t49_target2@aldeyabi.com','هدف الإسناد 2','user','{"can_create":true}','GA');
  PERFORM set_config('app.portal_transition','0',true);
END $seed$;

DO $t$
DECLARE v_n int; v_res jsonb;
BEGIN
  -- ── الموجب (أدمن): إنشاء وظيفة تمنح can_approve_disbursement (كان مرفوضاً قبل P0-1r) ──
  PERFORM set_config('request.jwt.claims','{"email":"t49_admin@aldeyabi.com","role":"authenticated"}',true);
  v_res := portal_save_job('t49_disb','معتمِد الصرف','GA','all','{"can_approve_disbursement":true}'::jsonb,'اعتماد الصرف');
  IF NOT coalesce((v_res->>'ok')::boolean,false) THEN RAISE EXCEPTION 'D1 FAIL: admin could not save a disbursement-approver job'; END IF;
  PERFORM 1 FROM portal_jobs WHERE key='t49_disb' AND active AND coalesce((permissions->>'can_approve_disbursement')::boolean,false);
  IF NOT FOUND THEN RAISE EXCEPTION 'D1 FAIL: saved job missing can_approve_disbursement'; END IF;
  RAISE NOTICE 'PASS D1 admin can create a job granting can_approve_disbursement';

  -- ── الموجب (أدمن): إسناد الوظيفة لمستخدم (الوظيفة الحسّاسة تتطلّب أدمن — والأدمن يمرّ) ──
  v_res := portal_apply_job('t49_target','t49_disb');
  IF NOT coalesce((v_res->>'ok')::boolean,false) THEN RAISE EXCEPTION 'D2 FAIL: admin could not assign disbursement-approver job'; END IF;
  PERFORM 1 FROM portal_users WHERE username='t49_target' AND coalesce((permissions->>'can_approve_disbursement')::boolean,false);
  IF NOT FOUND THEN RAISE EXCEPTION 'D2 FAIL: assignee did not receive can_approve_disbursement'; END IF;
  RAISE NOTICE 'PASS D2 admin can assign a disbursement-approver job';

  -- ── ضبط موجب (غير أدمن يملك can_manage_users): وظيفة غير حسّاسة تنجح (الهويّة صحيحة) ──
  PERFORM set_config('request.jwt.claims','{"email":"t49_mgr@aldeyabi.com","role":"authenticated"}',true);
  v_res := portal_save_job('t49_plain','منسّق','GA','own','{"can_create":true}'::jsonb,'رفع طلبات');
  IF NOT coalesce((v_res->>'ok')::boolean,false) THEN RAISE EXCEPTION 'D3 FAIL: manager could not save a non-sensitive job (identity check)'; END IF;
  RAISE NOTICE 'PASS D3 non-admin can_manage_users holder can still save a non-sensitive job';

  -- ── السلبي (منع التصعيد): غير الأدمن لا يصكّ وظيفة تمنح can_approve_disbursement ──
  BEGIN
    PERFORM portal_save_job('t49_disb2','معتمِد صرف 2','GA','all','{"can_approve_disbursement":true}'::jsonb,'x');
    RAISE EXCEPTION 'D4 FAIL: non-admin minted a disbursement-approval job';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'D4 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS D4 non-admin blocked from minting can_approve_disbursement (%.60)', left(sqlerrm,60);
  END;

  -- ── السلبي (منع التصعيد): غير الأدمن لا يُسند وظيفة تمنح can_approve_disbursement ──
  BEGIN
    PERFORM portal_apply_job('t49_target2','t49_disb');
    RAISE EXCEPTION 'D5 FAIL: non-admin assigned a disbursement-approval job';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'D5 FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS D5 non-admin blocked from assigning can_approve_disbursement (%.60)', left(sqlerrm,60);
  END;

  -- ── انحدار: مفتاح غير معروف يبقى مرفوضاً (القائمة البيضاء ما زالت مقفلة) ──
  PERFORM set_config('request.jwt.claims','{"email":"t49_admin@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_save_job('t49_bad','خطأ','GA','all','{"can_bogus":true}'::jsonb,'x');
    RAISE EXCEPTION 'D6 FAIL: unknown permission key was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF sqlerrm LIKE 'D6 FAIL%' THEN RAISE; END IF;
    IF sqlerrm NOT LIKE '%غير معروف%' THEN RAISE EXCEPTION 'D6 FAIL: wrong rejection reason: %', sqlerrm; END IF;
    RAISE NOTICE 'PASS D6 unknown permission key still rejected';
  END;

  -- ── تغطية: وظيفة نشطة واحدة على الأقل تمنح can_approve_disbursement (fin_accounts_mgr البذرة) ──
  SELECT count(*) INTO v_n FROM portal_jobs WHERE active AND coalesce((permissions->>'can_approve_disbursement')::boolean,false);
  IF v_n < 1 THEN RAISE EXCEPTION 'D7 FAIL: no active job grants can_approve_disbursement (disbursement stage-1 has no possible approver)'; END IF;
  RAISE NOTICE 'PASS D7 % active job(s) grant can_approve_disbursement', v_n;
END $t$;

-- تنظيف بيانات الاختبار
DO $c$ BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  DELETE FROM portal_users WHERE username LIKE 't49_%';
  DELETE FROM portal_jobs  WHERE key LIKE 't49_%';
  PERFORM set_config('app.portal_transition','0',true);
END $c$;

SELECT '════ JOBS DISBURSEMENT PERMISSION (P0-1r): D1..D7 = 7/7 PASS ════' AS result;

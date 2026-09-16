-- ════════════════════════════════════════════════════════════════════════════
--  نظام 2 — وضوح مساحة طلبات الشراء: مَن يملك المرحلة · ومَن قرّر · بأي لغة
-- ----------------------------------------------------------------------------
--  بلاغ المالك (2026-09-16، بلقطات): «المراحل التي بعد اعتمادي تخصّ مصطفى خليل
--  ومحمود العامودي — لماذا مسجَّلة لدى عبدالله؟» · «سجلّ القرارات جميعه عبدالله
--  والقرارات بالإنجليزي وغير متّزنة في الواجهة».
--
--  ═══ ① «إذن التسعير» كان يُسجَّل «بدأ العمل» باسم المعتمِد ═══
--  `pr_decide` (و`pr_transition_email`) عند اعتماد بوّابة التسعير كانت تكتب:
--      proc_status='in_progress', proc_started_by=v_me, proc_started_at=now()
--  أي أنّ مَن **أذِن** ببدء التسعير يُسجَّل فوراً أنّه **بدأ العمل** — وثلاثة
--  آثار مقيسة على الإنتاج:
--    (أ) مرحلة «التسعير والمقارنة» في مسار الطلب تُنسَب إليه لا لفريق المشتريات
--        (مقيس: `proc_started_by='Abdullah'` على **كل** الطلبات الستّة المعتمَدة،
--         و`proc_started_at = pricing_authorized_at` إلى الميكروثانية).
--    (ب) انتقال `received → in_progress` يُستهلَك قبل أن يراه أحد، فزرّ «بدأت
--        العمل عليه» لدى المشتريات **لا يعمل أبداً** (`pr_proc_stage` ترفض
--        الانتقال من `in_progress` إلى `in_progress`) — فلا أحد يُسنَد إليه
--        العمل، و`prWorkspaceNeedsAction` لا تُعلِّم الطلب لفريق المشتريات.
--    (ج) صفّ تدقيق ثالث `proc_in_progress` باسم المعتمِد في الثانية نفسها،
--        فيبدو السجلّ «كلّه عبدالله».
--  **الصواب:** الاعتماد يُسلّم الطلب للمشتريات في حالة `received` (وصل، بانتظار
--  من يبدأ)، و**الختم يقع حين يبدأ العمل فعلاً** عبر `pr_proc_stage`.
--
--  ═══ ② سجلّ القرارات بأسماء المستخدمين ═══
--  `proc_pr_audit.actor` اسم دخول (`Abdullah` · `m.elsobky`) لا اسم كامل،
--  والجدول **بلا عمود اسم**. ولا يصحّ الترجمة في المتصفّح: سياسة `users_select`
--  تحجب عن الموظّف المُنطَّق صفوف غيره (قاعدة المشروع 18: الاسم المعروض يُخزَّن
--  مع الصفّ). وكُتّاب هذا الجدول كُثر، فالحلّ **مُشغِّل واحد** يملأ الاسم عند
--  الإدراج مهما كان الكاتب — حاضراً أو مستقبلاً — بدل تعديل كل دالّة.
--
--  ⚠️ بُنيت الدالّتان على **التعريف الحيّ** (بعد هجرات هويّة المعتمِدين وختم
--     الرمز بالإصدار) لا على نسخة المستودع الأقدم؛ الفارق الوحيد عن الحيّ هو
--     سطر الحالة في فرع التسعير.
--  ⚠️ تُشغَّل بعد `db/system2-purchase-request-workspace.sql`. إضافيّة
--     وidempotent. كتلة التراجع في النهاية.
-- ════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  IF to_regprocedure('pr_proc_stage(text,text)') IS NULL THEN
    RAISE EXCEPTION 'شغّل db/system2-request-flow.sql أوّلاً — pr_proc_stage غير موجودة';
  END IF;
END $$;

-- ═════════ ① اسم الفاعل يُخزَّن مع صفّ التدقيق ═════════
ALTER TABLE proc_pr_audit ADD COLUMN IF NOT EXISTS actor_name text;

CREATE OR REPLACE FUNCTION proc_pr_audit_fill_actor_name()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF nullif(btrim(coalesce(NEW.actor_name,'')),'') IS NULL THEN
    SELECT nullif(btrim(u.display_name),'') INTO NEW.actor_name
      FROM proc_users u WHERE lower(u.username)=lower(coalesce(NEW.actor,'')) LIMIT 1;
    NEW.actor_name := coalesce(NEW.actor_name, NEW.actor);
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_proc_pr_audit_actor_name ON proc_pr_audit;
CREATE TRIGGER trg_proc_pr_audit_actor_name
  BEFORE INSERT ON proc_pr_audit
  FOR EACH ROW EXECUTE FUNCTION proc_pr_audit_fill_actor_name();

-- ردم الصفوف القائمة (بلا لمس ما يحمل اسماً بالفعل)
UPDATE proc_pr_audit a
   SET actor_name = coalesce(nullif(btrim(u.display_name),''), a.actor)
  FROM proc_users u
 WHERE lower(u.username) = lower(coalesce(a.actor,''))
   AND nullif(btrim(coalesce(a.actor_name,'')),'') IS NULL;
UPDATE proc_pr_audit SET actor_name = actor
 WHERE nullif(btrim(coalesce(actor_name,'')),'') IS NULL AND actor IS NOT NULL;

-- ═════════ ② الاعتماد يُسلّم للمشتريات ولا يدّعي بدء العمل ═════════
CREATE OR REPLACE FUNCTION pr_decide(p_pr_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_pr proc_purchase_requests%ROWTYPE; v_step proc_pr_approvals%ROWTYPE;
  v_action text := lower(btrim(coalesce(p_action,''))); v_now timestamptz := now(); v_name text; v_authorized boolean:=false;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF v_action NOT IN ('approve','return','reject') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;
  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id=p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_pr.status<>'in_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار قرار'; END IF;
  SELECT * INTO v_step FROM proc_pr_approvals
    WHERE pr_id=p_pr_id AND decision='pending' ORDER BY seq LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة معلّقة'; END IF;
  IF lower(coalesce(v_pr.requester,''))=lower(v_me) THEN
    RAISE EXCEPTION 'لا يجوز لمقدم الطلب اعتماد طلبه';
  END IF;
  v_authorized := lower(coalesce(v_step.approver,''))=lower(v_me)
    AND coalesce((pr_effective_permissions(v_me)->>v_step.role_key)::boolean,false);
  IF NOT v_authorized AND v_step.approver IS NOT NULL THEN
    SELECT coalesce(u.is_away,false) AND lower(coalesce(u.delegate_to,''))=lower(v_me)
      AND EXISTS(SELECT 1 FROM proc_users d WHERE lower(d.username)=lower(v_me) AND coalesce(d.active,true)
        AND coalesce((pr_effective_permissions(d.username)->>v_step.role_key)::boolean,false))
      INTO v_authorized FROM proc_users u WHERE lower(u.username)=lower(v_step.approver) LIMIT 1;
  END IF;
  IF NOT (coalesce(v_authorized,false) OR pr_is_admin()) THEN RAISE EXCEPTION 'هذه المرحلة ليست مسندة إليك'; END IF;
  IF v_action IN ('return','reject') AND length(btrim(coalesce(p_comment,'')))<3 THEN
    RAISE EXCEPTION 'سبب الإرجاع أو الرفض مطلوب';
  END IF;
  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  PERFORM set_config('app.pr_transition','1',true);
  UPDATE proc_pr_approvals SET decision=CASE v_action WHEN 'approve' THEN 'approved' WHEN 'return' THEN 'returned' ELSE 'rejected' END,
    comment=nullif(btrim(coalesce(p_comment,'')),''),acted_at=v_now,approver=v_me,
    approver_name=coalesce(nullif(btrim(v_name),''),v_me) WHERE id=v_step.id;

  IF v_action='return' THEN
    UPDATE proc_purchase_requests SET status='returned',workflow_state='returned',current_owner=requester,
      return_reason=p_comment,updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  ELSIF v_action='reject' THEN
    UPDATE proc_purchase_requests SET status='rejected',workflow_state='rejected',current_owner=NULL,
      return_reason=p_comment,updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  ELSIF v_step.stage_key='maintenance_need' THEN
    UPDATE proc_purchase_requests SET current_seq=2,workflow_state='procurement_review',
      current_owner=(SELECT approver FROM proc_pr_approvals
                      WHERE pr_id=p_pr_id AND seq=2 AND decision='pending'
                      ORDER BY revision DESC LIMIT 1),
      maintenance_approved_by=v_me,maintenance_approved_at=v_now,updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  ELSE
    /* ⚠️ `received` لا `in_progress`: الإذن بالتسعير تسليمٌ للمشتريات، وبدءُ
       العمل فعلٌ لاحق يملكه من يقوم به (`pr_proc_stage`). وكتابة `proc_started_by`
       هنا كانت تنسب العمل للمعتمِد **وتستهلك الانتقال** فيتعذّر على المشتريات
       تسجيل بدء العمل أصلاً. */
    UPDATE proc_purchase_requests SET status='approved',current_seq=0,workflow_state='pricing',
      proc_status=CASE WHEN coalesce(nullif(proc_status,''),'received')='received'
                       THEN 'received' ELSE proc_status END,
      current_owner=NULL,pricing_authorized_by=v_me,pricing_authorized_at=v_now,
      updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  END IF;
  INSERT INTO proc_audit_log(username,display_name,action,entity_type,entity_id,new_value)
  VALUES(v_me,coalesce(v_name,v_me),'pr_'||v_action,'pr',p_pr_id,
         jsonb_build_object('stage_key',v_step.stage_key,'comment',nullif(p_comment,'')));
  RETURN jsonb_build_object('ok',true,'action',v_action,'stage_key',v_step.stage_key,
    'workflow_state',CASE WHEN v_action='return' THEN 'returned' WHEN v_action='reject' THEN 'rejected'
      WHEN v_step.stage_key='maintenance_need' THEN 'procurement_review' ELSE 'pricing' END);
END;
$fn$;

-- نظيرتها في مسار البريد — العلّة نفسها حرفيّاً
CREATE OR REPLACE FUNCTION pr_transition_email(p_token text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_tok proc_email_tokens%ROWTYPE; v_pr proc_purchase_requests%ROWTYPE;
  v_step proc_pr_approvals%ROWTYPE; v_me text; v_action text:=lower(btrim(coalesce(p_action,'')));
  v_ok boolean:=false; v_now timestamptz:=now(); v_state text; v_status text; v_name text;
BEGIN
  IF v_action NOT IN ('approve','reject','return') THEN RETURN jsonb_build_object('error','invalid_action','code',400); END IF;
  SELECT * INTO v_tok FROM proc_email_tokens WHERE token=p_token FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','unknown_token','code',404); END IF;
  IF v_tok.used THEN RETURN jsonb_build_object('error','used','code',410); END IF;
  IF v_tok.expires_at<v_now THEN RETURN jsonb_build_object('error','expired','code',410); END IF;
  v_me:=v_tok.approver;
  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id=v_tok.pr_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','pr_not_found','code',404); END IF;
  -- الحارس: الرمز يخصّ الإصدار الذي وُصِف في بريده.
  IF coalesce(v_tok.revision,1) <> coalesce(v_pr.revision,1) THEN
    RETURN jsonb_build_object('error','stale_revision','code',409);
  END IF;
  IF v_pr.status<>'in_review' THEN RETURN jsonb_build_object('error','not_in_review','code',409); END IF;
  SELECT * INTO v_step FROM proc_pr_approvals WHERE pr_id=v_tok.pr_id AND decision='pending' ORDER BY seq LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','no_pending','code',409); END IF;
  IF v_step.seq<>v_tok.seq THEN RETURN jsonb_build_object('error','stage_changed','code',409); END IF;
  IF lower(coalesce(v_pr.requester,''))=lower(v_me) THEN RETURN jsonb_build_object('error','sod','code',403); END IF;
  SELECT lower(coalesce(v_step.approver,''))=lower(v_me)
         OR coalesce((pr_effective_permissions(v_me)->>v_step.role_key)::boolean,false)
         OR EXISTS(SELECT 1 FROM proc_users u WHERE lower(u.username)=lower(v_me) AND u.role='admin' AND coalesce(u.active,true))
    INTO v_ok;
  IF NOT v_ok AND v_step.approver IS NOT NULL THEN
    SELECT coalesce(u.is_away,false) AND lower(coalesce(u.delegate_to,''))=lower(v_me)
      AND EXISTS(SELECT 1 FROM proc_users d WHERE lower(d.username)=lower(v_me) AND coalesce(d.active,true)
        AND coalesce((pr_effective_permissions(d.username)->>v_step.role_key)::boolean,false))
      INTO v_ok FROM proc_users u WHERE lower(u.username)=lower(v_step.approver) LIMIT 1;
  END IF;
  IF NOT coalesce(v_ok,false) THEN RETURN jsonb_build_object('error','not_approver','code',403); END IF;
  IF v_action IN ('reject','return') AND length(btrim(coalesce(p_comment,'')))<3 THEN
    RETURN jsonb_build_object('error','comment_required','code',400);
  END IF;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  UPDATE proc_email_tokens SET used=true,used_at=v_now WHERE token=p_token;
  PERFORM set_config('app.pr_transition','1',true);
  UPDATE proc_pr_approvals SET decision=CASE v_action WHEN 'approve' THEN 'approved' WHEN 'return' THEN 'returned' ELSE 'rejected' END,
    comment=nullif(btrim(coalesce(p_comment,'')),''),acted_at=v_now,approver=v_me,
    approver_name=coalesce(nullif(btrim(v_name),''),v_me),channel='email' WHERE id=v_step.id;
  IF v_action='return' THEN
    v_state:='returned';v_status:='returned';
    UPDATE proc_purchase_requests SET status=v_status,workflow_state=v_state,current_owner=requester,return_reason=p_comment,updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  ELSIF v_action='reject' THEN
    v_state:='rejected';v_status:='rejected';
    UPDATE proc_purchase_requests SET status=v_status,workflow_state=v_state,current_owner=NULL,return_reason=p_comment,updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  ELSIF v_step.stage_key='maintenance_need' THEN
    v_state:='procurement_review';v_status:='in_review';
    UPDATE proc_purchase_requests SET current_seq=2,workflow_state=v_state,
      current_owner=(SELECT approver FROM proc_pr_approvals
                      WHERE pr_id=v_pr.id AND seq=2 AND decision='pending'
                      ORDER BY revision DESC LIMIT 1),
      maintenance_approved_by=v_me,maintenance_approved_at=v_now,updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  ELSE
    v_state:='pricing';v_status:='approved';
    UPDATE proc_purchase_requests SET status=v_status,current_seq=0,workflow_state=v_state,
      proc_status=CASE WHEN coalesce(nullif(proc_status,''),'received')='received'
                       THEN 'received' ELSE proc_status END,
      current_owner=NULL,pricing_authorized_by=v_me,pricing_authorized_at=v_now,
      updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  END IF;
  RETURN jsonb_build_object('ok',true,'action',v_action,'status',v_status,'workflow_state',v_state,
    'finalized',v_status<>'in_review','seq',v_step.seq,
    'pr',jsonb_build_object('id',v_pr.id,'title',v_pr.title,'department',v_pr.department,
      'department_id',v_pr.department_id,'requester',v_pr.requester,'requester_name',v_pr.requester_name));
END;
$fn$;

-- ═════════ ③ مداواة الصفوف المختومة آليّاً ═════════
--  الشرط قاطع: نفس الشخص **ونفس الطابع الزمنيّ إلى الميكروثانية** ⇒ الختم جاء
--  من الاعتماد لا من عمل حقيقيّ. وما تجاوز `in_progress` (عرض تسعير صادر أو
--  عروض مجمَّعة) لا يُمَسّ — هناك عملٌ فعليّ وقع.
DO $heal$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT id, proc_started_by FROM proc_purchase_requests
     WHERE proc_status = 'in_progress'
       AND proc_started_by IS NOT NULL
       AND lower(proc_started_by) = lower(coalesce(pricing_authorized_by,''))
       AND proc_started_at = pricing_authorized_at
  LOOP
    UPDATE proc_purchase_requests
       SET proc_status='received', proc_started_by=NULL, proc_started_at=NULL
     WHERE id = r.id;
    -- تصحيحٌ مُعلَن في السجلّ: لا يُحذَف صفّ قديم، بل يُضاف ما يشرحه.
    INSERT INTO proc_pr_audit(pr_id,event,actor,actor_name,channel,detail)
    VALUES(r.id,'proc_reset_to_received','system','النظام','system',
      jsonb_build_object('reason','ختم «بدء العمل» كان يقع تلقائياً عند الإذن بالتسعير',
                         'previous_started_by',r.proc_started_by));
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'أُعيد % طلباً إلى حالة «وصل للمشتريات»', n;
END $heal$;

-- ════════════════════════════════════════════════════════════════════════════
--  التراجع (لا تُشغّله إلا بقرار صريح)
-- ----------------------------------------------------------------------------
--  DROP TRIGGER IF EXISTS trg_proc_pr_audit_actor_name ON proc_pr_audit;
--  DROP FUNCTION IF EXISTS proc_pr_audit_fill_actor_name();
--  -- وإعادة السطر القديم في فرع التسعير:
--  --   proc_status='in_progress', proc_started_by=v_me,
--  --   proc_started_at=coalesce(proc_started_at,v_now)
--  -- ⚠️ ذلك يُعيد نسبة العمل للمعتمِد ويمنع المشتريات من تسجيل بدء العمل.
-- ════════════════════════════════════════════════════════════════════════════

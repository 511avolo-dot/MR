-- ═══════════════════════════════════════════════════════════════════════════
-- النظام 2 — رمز الاعتماد البريديّ يُختَم بإصدار الطلب
-- تُطبَّق بعد: db/system2-approval-identity-and-history.sql
--
-- الثغرة (مؤكَّدة بالتشغيل الفعليّ لا بالقراءة):
--   ① الطالب يرفع الطلب (إصدار 1، كمية 5) ⇒ يُسكّ رمز بريد للمعتمِد.
--   ② المعتمِد يُعيده للتعديل.
--   ③ الطالب يُعدّل جوهريّاً (كمية 500) ويُعيد الإرسال ⇒ إصدار 2.
--   ④ **الرمز القديم ما زال يعمل** ⇒ ضغطة «اعتمد» في بريد يصف الكمية 5
--      تعتمد الكمية 500. مُعاد إنتاجه: `{"ok": true, … "workflow_state":
--      "procurement_review"}` على طلب صار إصداره 2.
--
-- هذه ليست ثغرة صلاحية — الشخص نفسه مخوَّل — بل **ثغرة رضا**: يُسجَّل قرارٌ
-- على محتوى لم يره صاحبه. وهي تُبطل معنى دورة «الإرجاع للتعديل» كلّها.
--
-- ⚠️ لماذا لا يكفي إبطال الرموز في طبقة البريد:
--   `createToken` في `_pr-shared.js` يُبطِل الرموز السابقة لنفس
--   (الطلب/المرحلة/المعتمِد) عند سكّ رمز جديد — لكنّ ذلك يعتمد على أن تُرسَل
--   إشعارات المرحلة **مرّة أخرى لنفس الأشخاص**. فإن تغيّر المعتمِد المسنَد
--   (كما حدث فعلاً عند نقل DEP-OPS إلى م.محمد السبكي)، أو فشل إرسال بريد
--   أحدهم، أو لم يستدعِ العميل الإشعار أصلاً — بقي الرمز القديم حيّاً.
--   الختم بالإصدار **يُنفَّذ في القاعدة** فلا يعتمد على أيٍّ من ذلك.
--
-- ⚠️ ولماذا لا نُشدِّد على «حامل الرمز يجب أن يكون المعتمِد المسنَد»:
--   `notifyPending` يُرسل رمزاً **لكل معتمِد مؤهَّل** (حاملي مفتاح الدور)،
--   لا للمسنَد وحده — وهو سلوك مقصود. تشديدُه كان سيُعطّل اعتماد أيّ مدير
--   مشتريات غير المسنَد. قِيس قبل التصميم فلم يُشدَّد.
--
-- ⚠️ ترتيب التسليم مُلزِم: **الكود أوّلاً ثمّ الهجرة.**
--   `createToken` صار يُرسل `revision` ويسقط بتسامح إن غاب العمود (400)، فهو
--   يعمل قبل الهجرة وبعدها. أمّا تطبيق الهجرة على كودٍ قديم لا يُرسل الإصدار
--   فيجعل كل رمز جديد يُختَم افتراضيّاً بـ1، فتُرفَض اعتمادات أيّ طلب بلغ
--   إصداره 2 فأكثر. والردم أدناه يُصلح نافذة ما بين النشر والهجرة.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE proc_email_tokens ADD COLUMN IF NOT EXISTS revision integer NOT NULL DEFAULT 1;

-- الردم: كل رمز قائم غير مستخدَم ولم تنتهِ صلاحيته يُختَم بالإصدار الحاليّ
-- لطلبه — فلا تُبطِل الهجرةُ رمزاً حيّاً في صندوق بريد معتمِد الآن.
UPDATE proc_email_tokens t
   SET revision = coalesce(r.revision,1)
  FROM proc_purchase_requests r
 WHERE r.id = t.pr_id AND NOT t.used AND t.expires_at > now()
   AND t.revision <> coalesce(r.revision,1);

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
  -- ⚠️ الحارس الجديد: الرمز يخصّ الإصدار الذي وُصِف في بريده. أي تعديل على
  -- محتوى الطلب يرفع `revision`، فيفقد الرمز القديم صلاحيته حتماً — بلا
  -- اعتماد على إعادة الإرسال ولا على العميل.
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
      -- ⚠️ بعد بقاء تاريخ القرارات صار (pr_id,seq) غير فريد — القيد على
      -- `pending` إلزاميّ وإلّا أعاد الاستعلام أكثر من صفّ وفشل التحديث.
      current_owner=(SELECT approver FROM proc_pr_approvals
                      WHERE pr_id=v_pr.id AND seq=2 AND decision='pending'
                      ORDER BY revision DESC LIMIT 1),
      maintenance_approved_by=v_me,maintenance_approved_at=v_now,updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  ELSE
    v_state:='pricing';v_status:='approved';
    UPDATE proc_purchase_requests SET status=v_status,current_seq=0,workflow_state=v_state,proc_status='in_progress',current_owner=NULL,
      pricing_authorized_by=v_me,pricing_authorized_at=v_now,proc_started_by=v_me,
      proc_started_at=coalesce(proc_started_at,v_now),updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  END IF;
  RETURN jsonb_build_object('ok',true,'action',v_action,'status',v_status,'workflow_state',v_state,
    'finalized',v_status<>'in_review','seq',v_step.seq,
    'pr',jsonb_build_object('id',v_pr.id,'title',v_pr.title,'department',v_pr.department,
      'department_id',v_pr.department_id,'requester',v_pr.requester,'requester_name',v_pr.requester_name));
END;
$fn$;

REVOKE ALL ON FUNCTION pr_transition_email(text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION pr_transition_email(text,text,text) TO service_role;

COMMIT;

-- ═══════════════════════════ كتلة التراجع ═════════════════════════════════
-- BEGIN;
--   -- أعِد تعريف pr_transition_email من
--   -- db/system2-approval-identity-and-history.sql (بلا فحص الإصدار)، ثمّ:
--   ALTER TABLE proc_email_tokens DROP COLUMN IF EXISTS revision;
-- COMMIT;

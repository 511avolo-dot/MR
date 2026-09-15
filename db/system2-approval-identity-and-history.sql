-- ═══════════════════════════════════════════════════════════════════════════
-- النظام 2 — هويّة المعتمِدين + حفظ تاريخ الإعادة في سلسلة الاعتماد
-- تُطبَّق بعد: db/system2-purchase-request-workspace.sql ثم db/system2-request-closure.sql
--
-- بلاغان من المالك (2026-09-15):
--   (أ) «مسميات الأشخاص في النظام يكتب الاسم وليس اسم المستخدم في سير العمل
--        أو في سلسلة الموافقات».
--        الجذر: `proc_pr_approvals` **بلا عمود `approver_name`** إطلاقاً، والواجهة
--        تقرأ `a.approver_name || a.approver` فتسقط حتماً إلى اسم المستخدم.
--        ⚠️ ولا يصحّ حلّها في المتصفّح: سياسة `users_select` تسمح للموظّف المُنطَّق
--        بقراءة **صفّه وحده**، فمقدّم الطلب — وهو أكثر من يحتاج معرفة من يُمسك طلبه —
--        لا يستطيع ترجمة اسم المستخدم إلى اسم. الاسم يُخزَّن على صفّ الاعتماد خادميّاً
--        فيسافر مع الصفّ تحت الـRLS القائمة.
--
--   (ب) «تأكّد أنّ الطلب يرجع للطالب و**تُحفظ كامل المعلومات** عند إرجاعه وعند
--        إعادة استلامه وعودته في سير العمل».
--        الجذر: `pr_save_request` كانت تنفّذ `DELETE FROM proc_pr_approvals WHERE pr_id=v_id`
--        عند كل إعادة إرسال ⇒ **يُمحى صفّ الإعادة نفسه** (من أعاد ومتى ولماذا)،
--        و`return_reason` يُصفَّر. فيظهر الطلب بعد إعادة الإرسال وكأنّه لم يُعَد قطّ.
--        وهذا يناقض ما يَعِد به محضر الطلب المطبوع حرفيّاً: «مع بقاء السجل السابق دون حذف».
--
-- الحلّ: عمود `revision` على صفوف الاعتماد + مفتاح فريد (pr_id, revision, seq)
--        + حذف المعلّق وحده عند إعادة الإرسال (فيبقى المقرَّر تاريخاً).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ───────────────────────────── 1) المخطّط ─────────────────────────────────
ALTER TABLE proc_pr_approvals ADD COLUMN IF NOT EXISTS approver_name text;
ALTER TABLE proc_pr_approvals ADD COLUMN IF NOT EXISTS revision integer NOT NULL DEFAULT 1;

-- المفتاح الفريد القديم (pr_id, seq) يمنع بقاء تاريخ الإعادة، لأن الإصدار الجديد
-- يعيد استعمال seq 1 و2. يُستبدَل بمفتاح واعٍ بالإصدار.
DROP INDEX IF EXISTS uq_proc_pr_approval_stage;
CREATE UNIQUE INDEX IF NOT EXISTS uq_proc_pr_approval_stage
  ON proc_pr_approvals (pr_id, revision, seq);
CREATE INDEX IF NOT EXISTS idx_prappr_pr_rev ON proc_pr_approvals (pr_id, revision);

-- ───────────────────────── 2) ردم الصفوف القائمة ──────────────────────────
-- الاسم المعروض للمعتمِد المسنَد؛ الصفوف التي لا يطابق اسمها مستخدماً تبقى NULL
-- فتسقط الواجهة إلى اسم المستخدم كما كانت (لا اختراع أسماء).
UPDATE proc_pr_approvals a
   SET approver_name = u.display_name
  FROM proc_users u
 WHERE a.approver_name IS NULL
   AND a.approver IS NOT NULL
   AND lower(u.username) = lower(a.approver)
   AND nullif(btrim(u.display_name),'') IS NOT NULL;

-- صفوف الطلبات القائمة كلّها من الإصدار الحالي لطلبها.
UPDATE proc_pr_approvals a
   SET revision = coalesce(r.revision,1)
  FROM proc_purchase_requests r
 WHERE r.id = a.pr_id AND a.revision <> coalesce(r.revision,1);

-- اسم مقدّم الطلب على الطلبات الأقدم من الموديل (PR-DG2026-0001 مثلاً).
UPDATE proc_purchase_requests r
   SET requester_name = u.display_name
  FROM proc_users u
 WHERE r.requester_name IS NULL
   AND lower(u.username) = lower(r.requester)
   AND nullif(btrim(u.display_name),'') IS NOT NULL;

-- ─────────────────────── 3) مساعد: الاسم المعروض ──────────────────────────
CREATE OR REPLACE FUNCTION pr_display_name(p_username text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce(nullif(btrim(u.display_name),''), p_username)
  FROM proc_users u WHERE lower(u.username)=lower(p_username) LIMIT 1;
$fn$;

-- ──────────────────── 4) الحفظ: يُبقي تاريخ القرارات ──────────────────────
CREATE OR REPLACE FUNCTION pr_save_request(
  p_request jsonb,
  p_items jsonb,
  p_submit boolean DEFAULT true,
  p_pr_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_id text; v_now timestamptz := now();
  v_existing proc_purchase_requests%ROWTYPE; v_revision integer := 1;
  v_title text := btrim(coalesce(p_request->>'title',''));
  v_department_id text := nullif(btrim(coalesce(p_request->>'department_id','')),'');
  v_department text; v_sector text; v_requester_name text;
  v_project text := nullif(btrim(coalesce(p_request->>'project','')),'');
  v_manager text; v_proc_manager text; v_item_count integer;
BEGIN
  IF v_me IS NULL OR NOT pr_has_module_perm('pr_create') THEN RAISE EXCEPTION 'لا تملك صلاحية إنشاء طلب شراء'; END IF;
  IF jsonb_typeof(coalesce(p_items,'[]'::jsonb)) <> 'array' THEN RAISE EXCEPTION 'صيغة البنود غير صالحة'; END IF;
  IF jsonb_array_length(coalesce(p_items,'[]'::jsonb))>200 THEN RAISE EXCEPTION 'تجاوز الطلب الحد الأقصى للبنود'; END IF;
  IF length(v_title)>200 OR length(coalesce(p_request->>'justification',''))>4000 THEN
    RAISE EXCEPTION 'أحد حقول الطلب يتجاوز الطول المسموح';
  END IF;
  SELECT count(*) INTO v_item_count FROM jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x
    WHERE btrim(coalesce(x->>'description',''))<>'' AND coalesce((x->>'requested_qty')::numeric,0)>0;
  IF v_title='' OR v_department_id IS NULL THEN RAISE EXCEPTION 'عنوان الطلب والإدارة مطلوبان لحفظ المسودة'; END IF;
  IF p_submit AND (v_project IS NULL OR v_item_count=0) THEN
    RAISE EXCEPTION 'العنوان والإدارة والمشروع المعتمد وبند واحد صالح مطلوبة للإرسال';
  END IF;
  -- ⚠️ تاريخ توريد ماضٍ = طلب متأخّر يوم إنشائه (تصعيد فوريّ وترتيب أولويات مضلّل).
  -- الواجهة تمنعه بـ`min`، والخادم هو الحكم لأن سمة العنصر تُتجاوَز بأدوات المطوّر.
  IF p_submit AND nullif(p_request->>'needed_by','')::date IS NOT NULL
     AND nullif(p_request->>'needed_by','')::date < current_date THEN
    RAISE EXCEPTION 'تاريخ التوريد المطلوب لا يمكن أن يكون قبل اليوم';
  END IF;
  SELECT d.name_ar,d.sector INTO v_department,v_sector
  FROM proc_departments d WHERE d.id=v_department_id AND d.active;
  IF NOT FOUND THEN RAISE EXCEPTION 'الإدارة غير موجودة أو غير نشطة'; END IF;
  SELECT coalesce(nullif(btrim(u.display_name),''),v_me) INTO v_requester_name
  FROM proc_users u WHERE lower(u.username)=lower(v_me) AND coalesce(u.active,true) LIMIT 1;
  IF v_requester_name IS NULL THEN RAISE EXCEPTION 'حساب مقدم الطلب غير نشط أو غير موجود'; END IF;
  IF v_department_id IS NOT NULL AND NOT pr_has_module_perm('pr_view_all') AND NOT EXISTS(
    SELECT 1 FROM proc_users u WHERE lower(u.username)=lower(v_me)
      AND (u.department_id=v_department_id OR v_department_id=ANY(coalesce(u.pr_department_ids,'{}'::text[])))
  ) THEN RAISE EXCEPTION 'لا يمكنك إنشاء طلب لإدارة خارج نطاقك'; END IF;
  IF v_project IS NOT NULL AND NOT pr_project_is_canonical(v_project) THEN
    RAISE EXCEPTION 'المشروع غير موجود في سجل المشاريع المعتمد';
  END IF;

  IF p_pr_id IS NULL THEN
    v_id := pr_next_number();
  ELSE
    SELECT * INTO v_existing FROM proc_purchase_requests WHERE id=p_pr_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
    IF lower(coalesce(v_existing.requester,''))<>lower(v_me)
       AND NOT (pr_has_module_perm('pr_manage_users') OR pr_is_admin()) THEN
      RAISE EXCEPTION 'لا يمكنك تعديل طلب مستخدم آخر';
    END IF;
    IF v_existing.status NOT IN ('draft','returned') THEN RAISE EXCEPTION 'لا يمكن تعديل الطلب في حالته الحالية'; END IF;
    v_id := v_existing.id; v_revision := coalesce(v_existing.revision,1)+1;
    INSERT INTO proc_pr_versions(pr_id,revision,snapshot,reason,created_by)
    VALUES(v_id,coalesce(v_existing.revision,1),jsonb_build_object(
      'request',to_jsonb(v_existing),
      'items',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.seq) FROM proc_pr_items i WHERE i.pr_id=v_id),'[]'::jsonb)
    ),nullif(p_request->>'revision_reason',''),v_me)
    ON CONFLICT (pr_id,revision) DO NOTHING;
  END IF;

  IF p_submit THEN
    v_manager := pr_resolve_stage_approver(v_department_id,'pr_approve_maintenance');
    v_proc_manager := pr_resolve_stage_approver(v_department_id,'pr_authorize_pricing');
    IF v_manager IS NULL THEN RAISE EXCEPTION 'لم يُعيّن مدير صيانة مخوّل لهذه الإدارة'; END IF;
    IF v_proc_manager IS NULL THEN RAISE EXCEPTION 'لم يُعيّن مدير مشتريات مخوّل'; END IF;
  END IF;

  INSERT INTO proc_purchase_requests(
    id,request_no,title,department_id,department,sector,project,requester,requester_name,
    requester_mobile,request_date,needed_by,priority,justification,currency,status,current_seq,
    workflow_state,current_owner,submitted_at,revision,return_reason,created_by,created_at,updated_by,updated_at
  ) VALUES (
    v_id,v_id,v_title,v_department_id,v_department,v_sector,v_project,v_me,
    v_requester_name,left(nullif(btrim(coalesce(p_request->>'requester_mobile','')),''),30),current_date,
    nullif(p_request->>'needed_by','')::date,coalesce(nullif(p_request->>'priority',''),'متوسط'),
    nullif(p_request->>'justification',''),'SAR',CASE WHEN p_submit THEN 'in_review' ELSE 'draft' END,
    CASE WHEN p_submit THEN 1 ELSE 0 END,CASE WHEN p_submit THEN 'maintenance_review' ELSE 'draft' END,
    CASE WHEN p_submit THEN v_manager ELSE v_me END,CASE WHEN p_submit THEN v_now ELSE NULL END,
    v_revision,NULL,v_me,v_now,v_me,v_now
  )
  ON CONFLICT (id) DO UPDATE SET
    title=EXCLUDED.title,department_id=EXCLUDED.department_id,department=EXCLUDED.department,
    sector=EXCLUDED.sector,project=EXCLUDED.project,requester_name=EXCLUDED.requester_name,
    requester_mobile=EXCLUDED.requester_mobile,needed_by=EXCLUDED.needed_by,priority=EXCLUDED.priority,
    justification=EXCLUDED.justification,status=EXCLUDED.status,current_seq=EXCLUDED.current_seq,
    workflow_state=EXCLUDED.workflow_state,current_owner=EXCLUDED.current_owner,
    submitted_at=coalesce(proc_purchase_requests.submitted_at,EXCLUDED.submitted_at),revision=EXCLUDED.revision,
    return_reason=NULL,updated_by=v_me,updated_at=v_now;

  DELETE FROM proc_pr_items WHERE pr_id=v_id;
  INSERT INTO proc_pr_items(pr_id,seq,item_code,description,unit,contract_qty,stock_balance,requested_qty,category,notes)
  SELECT v_id,ord::integer,left(nullif(btrim(x->>'item_code'),''),80),left(btrim(x->>'description'),500),left(nullif(btrim(x->>'unit'),''),40),
         nullif(x->>'contract_qty','')::numeric,nullif(x->>'stock_balance','')::numeric,
         (x->>'requested_qty')::numeric,left(nullif(btrim(x->>'category'),''),120),left(nullif(btrim(x->>'notes'),''),1000)
  FROM jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) WITH ORDINALITY AS q(x,ord)
  WHERE btrim(coalesce(x->>'description',''))<>'' AND coalesce((x->>'requested_qty')::numeric,0)>0;

  -- ⚠️ التغيير الجوهريّ: يُحذف **المعلّق وحده**. كل صفّ حمل قراراً (اعتماد/إعادة/
  -- رفض/إلغاء) يبقى تاريخاً دائماً لهذا الطلب، فسلسلة القرارات تُظهر دورة الإعادة
  -- كاملةً بعد إعادة الإرسال — وهو ما يَعِد به محضر الطلب المطبوع.
  DELETE FROM proc_pr_approvals WHERE pr_id=v_id AND decision='pending';
  IF p_submit THEN
    INSERT INTO proc_pr_approvals(pr_id,revision,seq,stage_key,stage_label,resolver,role_key,approver,approver_name,decision,assigned_at,assigned_by,due_at)
    VALUES
      (v_id,v_revision,1,'maintenance_need','اعتماد الحاجة — مدير الصيانة والتشغيل','department_manager','pr_approve_maintenance',v_manager,pr_display_name(v_manager),'pending',v_now,v_me,v_now+interval '24 hours'),
      (v_id,v_revision,2,'procurement_pricing','إذن بدء التسعير — مدير المشتريات','permission','pr_authorize_pricing',v_proc_manager,pr_display_name(v_proc_manager),'pending',v_now,v_me,v_now+interval '48 hours');
  END IF;

  INSERT INTO proc_audit_log(username,display_name,action,entity_type,entity_id,new_value)
  SELECT v_me,coalesce(u.display_name,v_me),CASE WHEN p_submit THEN 'pr_submitted' ELSE 'pr_draft_saved' END,
         'pr',v_id,jsonb_build_object('revision',v_revision,'workflow_state',CASE WHEN p_submit THEN 'maintenance_review' ELSE 'draft' END)
  FROM (SELECT 1) z LEFT JOIN proc_users u ON lower(u.username)=lower(v_me) LIMIT 1;

  RETURN jsonb_build_object('ok',true,'id',v_id,'revision',v_revision,'submitted',p_submit,
                            'workflow_state',CASE WHEN p_submit THEN 'maintenance_review' ELSE 'draft' END);
END;
$fn$;

-- ──────────────── 5) القرار: يُثبّت اسم المقرِّر الفعليّ ───────────────────
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
  -- اسم المقرِّر يُثبَّت مع قراره: من قرّر فعلاً قد لا يكون المسنَد إليه (تفويض/أدمن).
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
    -- ⚠️ مع بقاء تاريخ الإصدارات صار (pr_id,seq) غير فريد، فيجب تقييد البحث
    -- بالمرحلة المعلّقة وإلّا أعاد الاستعلام الفرعيّ أكثر من صفّ وفشل التحديث.
    UPDATE proc_purchase_requests SET current_seq=2,workflow_state='procurement_review',
      current_owner=(SELECT approver FROM proc_pr_approvals
                      WHERE pr_id=p_pr_id AND seq=2 AND decision='pending'
                      ORDER BY revision DESC LIMIT 1),
      maintenance_approved_by=v_me,maintenance_approved_at=v_now,updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  ELSE
    UPDATE proc_purchase_requests SET status='approved',current_seq=0,workflow_state='pricing',proc_status='in_progress',
      current_owner=NULL,pricing_authorized_by=v_me,pricing_authorized_at=v_now,
      proc_started_by=v_me,proc_started_at=coalesce(proc_started_at,v_now),updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  END IF;
  INSERT INTO proc_audit_log(username,display_name,action,entity_type,entity_id,new_value)
  VALUES(v_me,coalesce(v_name,v_me),'pr_'||v_action,'pr',p_pr_id,
         jsonb_build_object('stage_key',v_step.stage_key,'comment',nullif(p_comment,'')));
  RETURN jsonb_build_object('ok',true,'action',v_action,'stage_key',v_step.stage_key,
    'workflow_state',CASE WHEN v_action='return' THEN 'returned' WHEN v_action='reject' THEN 'rejected'
      WHEN v_step.stage_key='maintenance_need' THEN 'procurement_review' ELSE 'pricing' END);
END;
$fn$;

-- ───────────── 6) القرار بالبريد: نفس التثبيت ونفس التقييد ────────────────
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

-- ─────────────────────────── 7) الامتيازات ────────────────────────────────
REVOKE ALL ON FUNCTION pr_display_name(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_display_name(text) TO authenticated;

COMMIT;

-- ═══════════════════════════ كتلة التراجع ═════════════════════════════════
-- BEGIN;
--   DROP INDEX IF EXISTS uq_proc_pr_approval_stage;
--   -- ⚠️ لا يمكن استعادة المفتاح القديم إن وُجد أكثر من إصدار لطلب واحد؛
--   -- احذف صفوف الإصدارات الأقدم أولاً إن أردت الرجوع فعلاً:
--   -- DELETE FROM proc_pr_approvals a USING proc_purchase_requests r
--   --   WHERE r.id=a.pr_id AND a.revision < coalesce(r.revision,1);
--   CREATE UNIQUE INDEX uq_proc_pr_approval_stage ON proc_pr_approvals (pr_id, seq);
--   ALTER TABLE proc_pr_approvals DROP COLUMN IF EXISTS revision;
--   ALTER TABLE proc_pr_approvals DROP COLUMN IF EXISTS approver_name;
-- COMMIT;

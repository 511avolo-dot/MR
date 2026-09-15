\set ON_ERROR_STOP on

-- ═══════════════════════════════════════════════════════════════════════════
-- TK1–TK7 — رمز الاعتماد البريديّ مختوم بإصدار الطلب
--   (db/system2-email-token-revision.sql)
--
-- الثغرة المُعاد إنتاجها قبل الإصلاح: رمز مسكوك على إصدار 1 (كمية 5) اعتمد
-- إصدار 2 (كمية 500) بضغطة في بريد يصف الكمية القديمة.
-- ═══════════════════════════════════════════════════════════════════════════
SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

DO $email_token_revision$
DECLARE
  r jsonb; out jsonb; v_id text; v_id2 text; n integer;
  v_project text := (SELECT x->>'name' FROM proc_settings s,
                     jsonb_array_elements(s.value->'projects') x
                     WHERE s.key='projects_registry' LIMIT 1);
BEGIN
  -- TK1: عمود الختم موجود وافتراضه 1 (فلا ينكسر رمز قديم بلا ختم)
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns
                WHERE table_name='proc_email_tokens' AND column_name='revision') THEN
    RAISE EXCEPTION 'TK1 عمود revision مفقود على proc_email_tokens';
  END IF;

  -- ① طلب جديد (إصدار 1) + رمز بريد مختوم به
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    jsonb_build_object('title','طلب رمز البريد','department_id','DEP-MAINT','project',v_project),
    '[{"description":"قطعة غيار","requested_qty":5,"unit":"حبة"}]'::jsonb, true, NULL);
  v_id := r->>'id';
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  INSERT INTO proc_email_tokens(token,pr_id,seq,approver,revision,expires_at)
  VALUES('TKrev0000000000000001',v_id,1,'maintmgr',1,now()+interval '7 days');

  -- ② إعادة للتعديل ثمّ تعديل جوهريّ وإعادة إرسال ⇒ إصدار 2
  PERFORM set_config('request.jwt.claims','{"email":"maintmgr@aldeyabi.com","role":"authenticated"}',true);
  PERFORM pr_decide(v_id,'return','الكميات تحتاج مراجعة');
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    jsonb_build_object('title','طلب رمز البريد — معدَّل','department_id','DEP-MAINT','project',v_project),
    '[{"description":"قطعة غيار","requested_qty":500,"unit":"حبة"}]'::jsonb, true, v_id);
  IF (r->>'revision')::integer <> 2 THEN RAISE EXCEPTION 'TK2 الشرط المسبق لم يتحقّق: الإصدار لم يرتفع'; END IF;

  -- TK3 [لبّ الإصلاح]: الرمز القديم يُرفَض
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  out := pr_transition_email('TKrev0000000000000001','approve',NULL);
  IF coalesce((out->>'ok')::boolean,false) THEN
    RAISE EXCEPTION 'TK3 رمز إصدار 1 اعتمد إصدار 2 — الثغرة مفتوحة';
  END IF;
  IF out->>'error' <> 'stale_revision' THEN
    RAISE EXCEPTION 'TK3 رُفِض الرمز لسبب آخر (%) لا لقِدَم الإصدار', out->>'error';
  END IF;

  -- TK4: والرفض **لم يستهلك** الرمز ولم يمسّ الطلب (رفض لا أثر له)
  IF (SELECT used FROM proc_email_tokens WHERE token='TKrev0000000000000001') THEN
    RAISE EXCEPTION 'TK4 الرمز المرفوض استُهلك';
  END IF;
  IF (SELECT workflow_state FROM proc_purchase_requests WHERE id=v_id)<>'maintenance_review' THEN
    RAISE EXCEPTION 'TK4 تغيّرت حالة الطلب رغم رفض الرمز';
  END IF;

  -- TK5: رمز مختوم بالإصدار الجاري **يعمل** — الحارس يمنع القديم لا كل رمز
  INSERT INTO proc_email_tokens(token,pr_id,seq,approver,revision,expires_at)
  VALUES('TKrev0000000000000002',v_id,1,'maintmgr',2,now()+interval '7 days');
  out := pr_transition_email('TKrev0000000000000002','approve',NULL);
  IF NOT coalesce((out->>'ok')::boolean,false) THEN
    RAISE EXCEPTION 'TK5 رمز الإصدار الجاري رُفِض (%)', out->>'error';
  END IF;
  IF (SELECT workflow_state FROM proc_purchase_requests WHERE id=v_id)<>'procurement_review' THEN
    RAISE EXCEPTION 'TK5 الاعتماد بالبريد لم ينقل المرحلة';
  END IF;
  -- واسم المقرِّر مُثبَّت في المسار البريديّ أيضاً
  IF (SELECT approver_name FROM proc_pr_approvals
        WHERE pr_id=v_id AND revision=2 AND seq=1)<>'مدير الصيانة' THEN
    RAISE EXCEPTION 'TK5 المسار البريديّ لم يُثبّت اسم المقرِّر';
  END IF;

  -- TK6: طلب لم يُعدَّل قطّ (إصدار 1) — الرمز يعمل كما كان: صفر انحدار
  PERFORM set_config('request.jwt.claims','{"email":"requester1@aldeyabi.com","role":"authenticated"}',true);
  r := pr_save_request(
    jsonb_build_object('title','طلب بلا تعديل','department_id','DEP-MAINT','project',v_project),
    '[{"description":"قطعة","requested_qty":2,"unit":"حبة"}]'::jsonb, true, NULL);
  v_id2 := r->>'id';
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  INSERT INTO proc_email_tokens(token,pr_id,seq,approver,revision,expires_at)
  VALUES('TKrev0000000000000003',v_id2,1,'maintmgr',1,now()+interval '7 days');
  out := pr_transition_email('TKrev0000000000000003','approve',NULL);
  IF NOT coalesce((out->>'ok')::boolean,false) THEN
    RAISE EXCEPTION 'TK6 انحدار: رمز طلب غير معدَّل رُفِض (%)', out->>'error';
  END IF;

  -- TK7: الدالّة خادمية بحتة — لا anon ولا authenticated
  IF has_function_privilege('anon','pr_transition_email(text,text,text)','EXECUTE')
     OR has_function_privilege('authenticated','pr_transition_email(text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TK7 دالّة القرار البريديّ مكشوفة لعميل';
  END IF;

  RAISE NOTICE 'TK1–TK7 ✓ رمز البريد مختوم بالإصدار';
END
$email_token_revision$;

-- TK8: الردم لا يُبطِل رمزاً حيّاً — إعادة تشغيل الهجرة على رمز غير مستخدَم
-- لطلب إصداره 2 تُعيد ختمه بـ2 بدل تركه على 1.
DO $backfill$
DECLARE v_id text; v_rev integer;
BEGIN
  SELECT id, revision INTO v_id, v_rev FROM proc_purchase_requests
   WHERE revision>1 ORDER BY id LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'TK8 الشرط المسبق مفقود: لا طلب بإصدار >1'; END IF;
  INSERT INTO proc_email_tokens(token,pr_id,seq,approver,revision,expires_at)
  VALUES('TKrev0000000000000009',v_id,1,'maintmgr',1,now()+interval '7 days');
  UPDATE proc_email_tokens t SET revision = coalesce(r.revision,1)
    FROM proc_purchase_requests r
   WHERE r.id = t.pr_id AND NOT t.used AND t.expires_at > now()
     AND t.revision <> coalesce(r.revision,1);
  IF (SELECT revision FROM proc_email_tokens WHERE token='TKrev0000000000000009') <> v_rev THEN
    RAISE EXCEPTION 'TK8 الردم لم يُعِد ختم الرمز الحيّ بالإصدار الجاري';
  END IF;
  RAISE NOTICE 'TK8 ✓ الردم يحمي الرمز الحيّ';
END
$backfill$;

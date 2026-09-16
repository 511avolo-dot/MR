-- ════════════════════════════════════════════════════════════════════════════
--  PA1–PA12 — مرفقات الطلب: الرؤية بعد فكّ الإقفال · الإزالة المحكومة ·
--             مرفقات المناقشة. تأكيدات **سلوكية** بدور `authenticated` فعليّ
--             وهويّة مُنتحَلة — لا فحص نصّ سياسة.
--
--  ⚠️ العلّة التي تحرسها: الموظّف المُنطَّق كان يرفع مرفقاً (ينجح — الدالّة
--     DEFINER) ثمّ لا يراه إطلاقاً (سياسة `no_scoped_access` الـRESTRICTIVE
--     تُجمَع بـAND فتُلغي `pr_can_view_request`). فالفحص النصّيّ على وجود
--     `pr_attachment_select` كان يمرّ والعطل قائم.
--
--  ⚠️⚠️ الأهمّ منهجيّاً: البيئة المحلّية **لا تحمل حالة الإنتاج** — قائمة
--     الإقفال في `db/system2-scoped-table-lockdown.sql` لم تعُد تضمّ الجدولين
--     (كي لا تُعيد إعادةُ تشغيلها العطلَ)، فلا سياسة RESTRICTIVE تُنشأ محلّياً
--     أصلاً. ولو اكتفينا بذلك لكانت PA1 **فراغيّة**: تمرّ بلا أن تختبر شيئاً،
--     ولمرّ حذفُ جدول من قائمة الهجرة بلا إخفاق (مُتحقَّق تجريبيّاً).
--     لذا يُعيد هذا الملفّ **بناء حالة الإنتاج** (السياستان)، يُثبت أنّها تحجب
--     فعلاً (PA0 = العَرَض المُبلَّغ عنه حرفيّاً)، ثمّ يُشغّل الهجرة ويتحقّق
--     أنّها هي التي رفعت الحجب.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

SELECT set_config('request.jwt.claims','{"role":"service_role"}',false);

INSERT INTO proc_departments(id,name_ar,sector,manager_user,active)
VALUES ('DEP-PA','إدارة المرفقات','الصيانة والتشغيل','pa_mgr',true),
       ('DEP-PB','إدارة أخرى','النقليات','pa_mgr2',true)
ON CONFLICT (id) DO UPDATE SET active=true, sector=EXCLUDED.sector, manager_user=EXCLUDED.manager_user;

INSERT INTO proc_users(username,email,display_name,role,active,permissions,scope_sectors,
                       pr_profile_key,pr_permission_overrides,department_id,pr_department_ids)
VALUES
 -- المُقدّم: **مُنطَّق** — هو بالضبط من كان محجوباً عن مرفقات طلبه
 ('pa_req','pa_req@aldeyabi.com','طالب','user',true,
  '{"can_comment":true,"can_upload_docs":true}'::jsonb,'["الصيانة والتشغيل"]'::jsonb,
  'requester','{}'::jsonb,'DEP-PA',ARRAY['DEP-PA']),
 ('pa_mgr','pa_mgr@aldeyabi.com','مدير الصيانة','user',true,'{}'::jsonb,NULL,
  'maintenance_manager','{}'::jsonb,'DEP-PA',ARRAY['DEP-PA']),
 ('pa_proc','pa_proc@aldeyabi.com','مشتريات','user',true,'{}'::jsonb,NULL,
  'procurement_manager','{}'::jsonb,NULL,ARRAY['DEP-PA']),
 -- موظّف مُنطَّق في إدارة أخرى: يجب ألّا يرى شيئاً (فكّ الإقفال ليس انفتاحاً)
 ('pa_other','pa_other@aldeyabi.com','غريب','user',true,
  '{"can_comment":true,"can_upload_docs":true}'::jsonb,'["النقليات"]'::jsonb,
  'requester','{}'::jsonb,'DEP-PB',ARRAY['DEP-PB'])
ON CONFLICT (username) DO UPDATE
  SET permissions=EXCLUDED.permissions, scope_sectors=EXCLUDED.scope_sectors,
      pr_profile_key=EXCLUDED.pr_profile_key, pr_permission_overrides='{}'::jsonb,
      department_id=EXCLUDED.department_id, pr_department_ids=EXCLUDED.pr_department_ids, active=true;

INSERT INTO proc_settings(key,value)
VALUES ('projects_registry','{"projects":[{"name":"مشروع المرفقات","aliases":[],"active":true}]}'::jsonb)
ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value;

-- ═══════ إعادة بناء حالة الإنتاج: الإقفال العامّ على جدولَي الموديل ═══════
DO $seed_prod$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['proc_pr_attachments','proc_pr_audit'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS "no_scoped_access" ON %I', t);
    EXECUTE format($p$CREATE POLICY "no_scoped_access" ON %I
      AS RESTRICTIVE FOR ALL TO authenticated
      USING (NOT proc_is_scoped()) WITH CHECK (NOT proc_is_scoped())$p$, t);
  END LOOP;
END $seed_prod$;

-- ═══════ البذرة: طلب للمُقدّم المُنطَّق + مرفقان ═══════
CREATE TEMP TABLE _pa_ctx (pr_id text, a1 bigint, a2 bigint);

DO $seed$
DECLARE v_id text; v_a1 bigint; v_a2 bigint; v_n int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"email":"pa_req@aldeyabi.com"}',true);
  v_id := (pr_save_request(
    jsonb_build_object('title','طلب بمرفقات','department_id','DEP-PA',
                       'project','مشروع المرفقات','priority','عادي','justification','اختبار'),
    jsonb_build_array(jsonb_build_object('description','بند','unit','حبة','requested_qty',1)),
    true, NULL))->>'id';

  v_a1 := (pr_register_attachment(v_id, 'docs/pr/'||v_id||'/aaaaaaaa-1111.pdf',
            'مواصفة.pdf','support','application/pdf',2048))->>'id';
  v_a2 := (pr_register_attachment(v_id, 'docs/pr/'||v_id||'/bbbbbbbb-2222.png',
            'صورة الموقع.png','other','image/png',4096))->>'id';

  INSERT INTO _pa_ctx VALUES (v_id, v_a1, v_a2);

  -- ═════ PA0: **العَرَض المُبلَّغ عنه** — مع الإقفال العامّ يرى المُقدّم صفراً ═════
  --  (وهو شرط لازم: لو مرّت PA1 بلا هذه، لكانت لا تختبر شيئاً.)
  PERFORM set_config('role','authenticated',true);
  SELECT count(*) INTO v_n FROM proc_pr_attachments WHERE pr_id=v_id;
  PERFORM set_config('role','postgres',true);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PA0 فشل: الإقفال العامّ لم يُعَد بناؤه — التأكيدات التالية فراغيّة (يرى %)', v_n;
  END IF;
  RAISE NOTICE 'PA0 ✅ أُعيد إنتاج العطل: المُقدّم يرى 0 من مرفقات طلبه';
END $seed$;

-- ═══════ تشغيل الهجرة التصحيحية على حالة الإنتاج المُعاد بناؤها ═══════
\i db/system2-pr-attachments-unlock.sql

DO $t$
DECLARE
  v_id text; v_a1 bigint; v_a2 bigint; v_n int; v_del timestamptz;
BEGIN
  SELECT pr_id, a1, a2 INTO v_id, v_a1, v_a2 FROM _pa_ctx;

  -- ══════════ PA1: وبعد الهجرة يرى مرفقَي طلبه (لبّ البلاغ) ══════════
  PERFORM set_config('request.jwt.claims','{"email":"pa_req@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  SELECT count(*) INTO v_n FROM proc_pr_attachments WHERE pr_id=v_id AND deleted_at IS NULL;
  PERFORM set_config('role','postgres',true);
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'PA1 فشل: المُقدّم المُنطَّق يرى % مرفقاً من 2 (الإقفال ما يزال يحجبه)', v_n;
  END IF;
  RAISE NOTICE 'PA1 ✅ المُقدّم المُنطَّق يرى مرفقات طلبه (%)', v_n;

  -- ══════════ PA2: ويرى سجلّ طلبه كذلك (`proc_pr_audit` مصابة بالعلّة نفسها) ══════════
  PERFORM set_config('role','authenticated',true);
  SELECT count(*) INTO v_n FROM proc_pr_audit WHERE pr_id=v_id;
  PERFORM set_config('role','postgres',true);
  IF v_n < 1 THEN RAISE EXCEPTION 'PA2 فشل: سجلّ الطلب محجوب عن مُقدّمه'; END IF;
  RAISE NOTICE 'PA2 ✅ سجلّ الطلب مرئيّ لمُقدّمه (% حدثاً)', v_n;

  -- ══════════ PA3: فكّ الإقفال ليس انفتاحاً — موظّف إدارة أخرى صفر ══════════
  PERFORM set_config('request.jwt.claims','{"email":"pa_other@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  SELECT (SELECT count(*) FROM proc_pr_attachments)
       + (SELECT count(*) FROM proc_pr_audit) INTO v_n;
  PERFORM set_config('role','postgres',true);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PA3 فشل: موظّف خارج الإدارة قرأ % صفّاً', v_n;
  END IF;
  RAISE NOTICE 'PA3 ✅ موظّف إدارة أخرى محجوب (0)';

  -- ══════════ PA4: المشتريات ترى المرفقات (pr_view_all) ══════════
  PERFORM set_config('request.jwt.claims','{"email":"pa_proc@aldeyabi.com"}',true);
  PERFORM set_config('role','authenticated',true);
  SELECT count(*) INTO v_n FROM proc_pr_attachments WHERE pr_id=v_id AND deleted_at IS NULL;
  PERFORM set_config('role','postgres',true);
  IF v_n <> 2 THEN RAISE EXCEPTION 'PA4 فشل: المشتريات ترى % من 2', v_n; END IF;
  RAISE NOTICE 'PA4 ✅ المشتريات ترى المرفقات';

  -- ══════════ PA5: الكتابة المباشرة ما تزال مقفلة بعد فكّ السياسة ══════════
  IF has_table_privilege('authenticated','proc_pr_attachments','INSERT')
     OR has_table_privilege('authenticated','proc_pr_attachments','UPDATE')
     OR has_table_privilege('authenticated','proc_pr_attachments','DELETE') THEN
    RAISE EXCEPTION 'PA5 فشل: العميل يملك كتابة مباشرة على المرفقات';
  END IF;
  RAISE NOTICE 'PA5 ✅ لا كتابة مباشرة للعميل (الكتابة عبر الدوال وحدها)';

  -- ══════════ PA6: الجداول الخمسة الأخرى تبقى مُقفَلة ══════════
  SELECT count(*) INTO v_n FROM pg_policies
   WHERE schemaname='public' AND policyname='no_scoped_access';
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'PA6 فشل: سياسات الإقفال % لا 5 (فُتِح جدول لا يجوز فتحه أو أُعيد إقفال جدولَي الموديل)', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM pg_policies
   WHERE schemaname='public' AND tablename IN ('proc_pr_attachments','proc_pr_audit')
     AND permissive='RESTRICTIVE';
  IF v_n <> 0 THEN RAISE EXCEPTION 'PA6 فشل: بقيت % سياسة RESTRICTIVE على جدولَي الموديل', v_n; END IF;
  RAISE NOTICE 'PA6 ✅ خمسة جداول مُقفَلة وجدولا الموديل مفتوحان بحارسهما';

  -- ══════════ PA7: الإزالة — من ليس رافعاً ولا مشتريات يُمنَع ══════════
  BEGIN
    PERFORM set_config('request.jwt.claims','{"email":"pa_mgr@aldeyabi.com"}',true);
    PERFORM pr_remove_attachment(v_a1);
    RAISE EXCEPTION 'PA7 فشل: مدير الصيانة أزال مرفق غيره';
  EXCEPTION WHEN OTHERS THEN
    IF position('PA7 فشل' in SQLERRM)>0 THEN RAISE; END IF;
    RAISE NOTICE 'PA7 ✅ غير الرافع مُنِع (%)', left(SQLERRM,60);
  END;

  -- ══════════ PA8: الرافع يُزيل — **حذف ناعم** لا تدمير ══════════
  PERFORM set_config('request.jwt.claims','{"email":"pa_req@aldeyabi.com"}',true);
  PERFORM pr_remove_attachment(v_a1);
  SELECT deleted_at INTO v_del FROM proc_pr_attachments WHERE id=v_a1;
  IF v_del IS NULL THEN RAISE EXCEPTION 'PA8 فشل: لم يُوسَم المرفق مُزالاً'; END IF;
  SELECT count(*) INTO v_n FROM proc_pr_attachments WHERE id=v_a1;
  IF v_n <> 1 THEN RAISE EXCEPTION 'PA8 فشل: الصفّ حُذِف فعليّاً (الأثر ضاع)'; END IF;
  SELECT count(*) INTO v_n FROM proc_pr_audit WHERE pr_id=v_id AND event='attachment_removed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'PA8 فشل: لم يُسجَّل حدث الإزالة'; END IF;
  RAISE NOTICE 'PA8 ✅ إزالة ناعمة بأثر تدقيق (الصفّ باقٍ)';

  -- ══════════ PA9: رسالة مناقشة بمرفق — المعرّف يُحفَظ على الرسالة ══════════
  PERFORM set_config('request.jwt.claims','{"email":"pa_req@aldeyabi.com"}',true);
  PERFORM pr_post_message(v_id,'هذه صورة الموقع','answer', ARRAY[v_a2]);
  SELECT count(*) INTO v_n FROM proc_pr_messages
   WHERE pr_id=v_id AND attachment_ids @> ARRAY[v_a2];
  IF v_n <> 1 THEN RAISE EXCEPTION 'PA9 فشل: مرفق الرسالة لم يُحفَظ'; END IF;
  RAISE NOTICE 'PA9 ✅ رسالة المناقشة تحمل مرفقها';

  -- ══════════ PA10: مرفق لا يخصّ الطلب يُرفَض (لا إسقاط صامت) ══════════
  BEGIN
    PERFORM pr_post_message(v_id,'مرفق ملفَّق','answer', ARRAY[999999::bigint]);
    RAISE EXCEPTION 'PA10 فشل: قُبِل مرفق لا وجود له';
  EXCEPTION WHEN OTHERS THEN
    IF position('PA10 فشل' in SQLERRM)>0 THEN RAISE; END IF;
    RAISE NOTICE 'PA10 ✅ مرفق غريب مرفوض (%)', left(SQLERRM,50);
  END;

  -- ══════════ PA11: رسالة بمرفق بلا نصّ مقبولة · وبلا الاثنين مرفوضة ══════════
  PERFORM pr_post_message(v_id,'','answer', ARRAY[v_a2]);
  BEGIN
    PERFORM pr_post_message(v_id,'   ','answer', NULL);
    RAISE EXCEPTION 'PA11 فشل: قُبِلت رسالة فارغة بلا مرفق';
  EXCEPTION WHEN OTHERS THEN
    IF position('PA11 فشل' in SQLERRM)>0 THEN RAISE; END IF;
    RAISE NOTICE 'PA11 ✅ المرفق وحده يكفي · والفراغ التامّ مرفوض';
  END;

  -- ══════════ PA12: لا إزالة من طلب منتهٍ ══════════
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  UPDATE proc_purchase_requests SET status='cancelled' WHERE id=v_id;
  BEGIN
    PERFORM set_config('request.jwt.claims','{"email":"pa_req@aldeyabi.com"}',true);
    PERFORM pr_remove_attachment(v_a2);
    RAISE EXCEPTION 'PA12 فشل: أُزيل مرفق من طلب منتهٍ';
  EXCEPTION WHEN OTHERS THEN
    IF position('PA12 فشل' in SQLERRM)>0 THEN RAISE; END IF;
    RAISE NOTICE 'PA12 ✅ مرفقات الطلب المنتهي لا تُمَسّ';
  END;

  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  RAISE NOTICE 'PA1–PA12 نجحت';
END $t$;

-- ════════════════════════════════════════════════════════════════════════════
--  نظام 2 — مرفقات الطلب: فكّ إقفال فات عليه الزمن + إزالة مرفق محكومة
-- ----------------------------------------------------------------------------
--  ⚠️ بلاغ المالك (2026-09-16): «المرفقات لا يمكن فتحها، ولا تظهر لجميع
--     المسجّلين في النظام — أنا فقط. وبعد الرفع يظهر أنه لا يوجد مرفقات
--     للطلب.» وهذا الملفّ يعالج شقّه الخادميّ؛ وشقّ العارض في `index.html`.
--
--  ═══ الجذر المقيس على الإنتاج (لا مُستنتَج) ═══
--  `db/system2-scoped-table-lockdown.sql` (2026-09-13) أضافت سياسة
--  RESTRICTIVE واحدة `no_scoped_access USING (NOT proc_is_scoped())` على سبعة
--  جداول، على **حقيقة مقيسة يومها**: «`proc_pr_attachments` و`proc_pr_audit`
--  بلا مرجع واحد في `index.html` (بقايا)» — وكانا فعلاً بصفر صفّ.
--
--  ثمّ جاء موديل مساحة عمل طلبات الشراء (2026-09-14) فجعل الجدولين **قلب
--  الموديل**: `pr_register_attachment` تكتب فيهما، و`index.html` يقرأهما في
--  `prLoadAll`. والسياسة الباقية تُجمَع بـ**AND** فتُلغي حارسهما الخاصّ:
--
--    proc_pr_attachments : PERMISSIVE pr_attachment_select USING pr_can_view_request(pr_id)
--                          RESTRICTIVE no_scoped_access    USING (NOT proc_is_scoped())
--
--  ⇒ **كل موظّف مُنطَّق يرى صفر مرفق — حتى مرفق طلبه الذي رفعه هو.** والرفع
--  ينجح (`pr_register_attachment` هي SECURITY DEFINER فتتجاوز RLS) فيقع بالضبط
--  ما وصفه المالك: يرفع ثمّ «لا يوجد مرفقات»؛ والأدمن غير المُنطَّق يراها وحده.
--  مقيس على الإنتاج: `mostafa.kishk` و`m.elsobky` كلاهما
--  `scope_sectors = ["الصيانة والتشغيل"]` — وهما كلّ من يرفع طلبات اليوم.
--  و`proc_pr_audit` مصاب بالعلّة نفسها ⇒ الموظّف بلا سجلّ لطلبه.
--
--  ═══ لماذا الحذف لا يُضعِف شيئاً ═══
--  الجدولان يحملان أصلاً حارس الموديل نفسه الذي تحمله أشقّاؤهما غير المُقفَلة
--  (`proc_pr_messages` · `proc_pr_po_links` · `proc_pr_versions` ·
--  `proc_pr_item_allocations`): `pr_can_view_request(pr_id)` = طلبي، أو طلب
--  إدارتي، أو طلب أنا معتمِده، أو `pr_view_all`. فحذف الإقفال يعيدهما إلى
--  **مستوى إخوتهما بالضبط** لا إلى الانفتاح. والكتابة تبقى مقفلة تماماً:
--  `authenticated` يملك **SELECT فقط** (مقيس) ولا سياسة INSERT/UPDATE/DELETE
--  إطلاقاً ⇒ كل كتابة عبر دوال DEFINER محكومة.
--
--  ⚠️ والجداول الخمسة الأخرى تبقى مُقفَلة كما هي: التسجيلات · RFQ وعروضها ·
--     الأسماء البديلة · استخدام الذكاء — لا مسار للموظّف المُنطَّق إليها.
--
--  ═══ إزالة مرفق ═══
--  «رفع عدّة مرفقات» بلا «إزالة مرفق أُرفِق خطأً» ناقص: لا سبيل لتصحيح ملفّ
--  رُفِع بالخطأ إلا بتركه ظاهراً على الطلب. `pr_remove_attachment` حذف **ناعم**
--  (`deleted_at`) لا تدمير: الملفّ يبقى في R2 والصفّ يبقى في الجدول وسجلّا
--  التدقيق يحفظان مَن أزاله ومتى — وفاءً بقاعدة المشروع «لا مسار في النظام
--  يحذف ملفّ مورّد/مستند».
--
--  ⚠️ تُشغَّل بعد `db/system2-purchase-request-workspace.sql`. إضافيّة
--     وidempotent. كتلة التراجع في النهاية.
-- ════════════════════════════════════════════════════════════════════════════

-- الاعتمادات — نفشل مبكّراً برسالة مفهومة بدل خطأ غامض في منتصف الهجرة.
DO $$
BEGIN
  IF to_regprocedure('pr_can_view_request(text)') IS NULL THEN
    RAISE EXCEPTION 'شغّل db/system2-purchase-request-workspace.sql أوّلاً — pr_can_view_request غير موجودة';
  END IF;
END $$;

-- ───────────────── ① فكّ الإقفال عن جدولَي الموديل وحدهما ─────────────────
DO $unlock$
DECLARE
  t text;
  -- ⚠️ قائمة صريحة لا `DROP ... FROM pg_policies WHERE policyname='no_scoped_access'`:
  --    الخمسة الأخرى تبقى مُقفَلة، وحذفها آليّاً يفتحها بصمت.
  tables text[] := ARRAY['proc_pr_attachments', 'proc_pr_audit'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    CONTINUE WHEN to_regclass('public.' || t) IS NULL;
    EXECUTE format('DROP POLICY IF EXISTS "no_scoped_access" ON %I', t);
  END LOOP;
END $unlock$;

-- حارس أثر لا حارس اسم: لو بقيت سياسة RESTRICTIVE أخرى بأي اسم على الجدولين
-- لظلّ الموظّف محجوباً والهجرة «ناجحة». (سابقة مثبَّتة: الحذف بالاسم نجح
-- وترك التسريب مفتوحاً لأن الاسم الحيّ كان مختلفاً.)
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_policies
  WHERE schemaname='public' AND tablename IN ('proc_pr_attachments','proc_pr_audit')
    AND permissive='RESTRICTIVE';
  IF n > 0 THEN
    RAISE EXCEPTION 'بقيت % سياسة RESTRICTIVE على جدولَي المرفقات/السجلّ — الموظّف المُنطَّق ما يزال محجوباً', n;
  END IF;
END $$;

-- ولا نفتح كتابةً: التأكيد أنّ العميل ما زال بـSELECT وحدها بعد فكّ الإقفال.
DO $$
BEGIN
  IF has_table_privilege('authenticated','proc_pr_attachments','INSERT')
     OR has_table_privilege('authenticated','proc_pr_attachments','UPDATE')
     OR has_table_privilege('authenticated','proc_pr_attachments','DELETE') THEN
    RAISE EXCEPTION 'العميل يملك كتابة مباشرة على proc_pr_attachments — الكتابة عبر الدوال المحكومة وحدها';
  END IF;
END $$;

-- ───────────────── ② إزالة مرفق — حذف ناعم محكوم ─────────────────
CREATE OR REPLACE FUNCTION pr_remove_attachment(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me();
  v_row proc_pr_attachments%ROWTYPE;
  v_status text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;

  SELECT * INTO v_row FROM proc_pr_attachments WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'المرفق غير موجود'; END IF;
  IF v_row.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'id', p_id, 'already', true);
  END IF;

  -- الرؤية أوّلاً: لا يُزال مرفقُ طلبٍ لا يراه صاحب الفعل أصلاً.
  IF NOT pr_can_view_request(v_row.pr_id) THEN RAISE EXCEPTION 'الطلب خارج نطاقك'; END IF;

  -- ⚠️ الصلاحية: رافعُ المرفق نفسه، أو من يملك إدارة التسعير/الموديل. مجرّد
  --    `pr_upload_attachments` لا يكفي لإزالة مرفق **غيرك** — رفعُ دليلٍ شيء
  --    وإزالةُ دليل غيرك شيء آخر.
  IF NOT ( lower(coalesce(v_row.uploaded_by,'')) = lower(v_me)
           OR pr_has_module_perm('pr_manage_pricing')
           OR pr_is_admin() ) THEN
    RAISE EXCEPTION 'لا تملك صلاحية إزالة هذا المرفق';
  END IF;

  -- لا يُمسّ دليلُ طلبٍ أُقفِل أو أُلغي: سجلّه صار أثراً تاريخيّاً.
  SELECT status INTO v_status FROM proc_purchase_requests WHERE id = v_row.pr_id;
  IF v_status IN ('closed','cancelled','rejected') THEN
    RAISE EXCEPTION 'لا تُزال مرفقات طلب منتهٍ';
  END IF;

  UPDATE proc_pr_attachments SET deleted_at = now() WHERE id = p_id;

  INSERT INTO proc_audit_log(username,action,entity_type,entity_id,old_value)
  VALUES(v_me,'pr_attachment_removed','pr',v_row.pr_id,
    jsonb_build_object('attachment_id',p_id,'file_name',v_row.file_name,
                       'object_key',v_row.object_key,'uploaded_by',v_row.uploaded_by));
  INSERT INTO proc_pr_audit(pr_id,event,actor,channel,detail)
  VALUES(v_row.pr_id,'attachment_removed',v_me,'portal',
    jsonb_build_object('attachment_id',p_id,'file_name',v_row.file_name));

  RETURN jsonb_build_object('ok', true, 'id', p_id, 'pr_id', v_row.pr_id);
END;
$fn$;

REVOKE ALL ON FUNCTION pr_remove_attachment(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_remove_attachment(bigint) TO authenticated;

-- ───────────────── ③ مرفق مع رسالة المناقشة ─────────────────
--  ⚠️ طلب المالك (2026-09-16): «حتى المناقشات المفروض أن يصبح هناك إمكانية
--     إضافة مرفق فيها». وهي ليست رفاهية: قناة الاستفهام بين المشتريات والطالب
--     كانت **نصّاً فقط**، فسؤالٌ عن مواصفة أو صورة عطل يُجاب خارج النظام
--     (واتساب) فتضيع المعلومة — وهي العلّة نفسها التي بُنيت القناة لعلاجها.
--
--  الربط بمعرّفات مرفقات الطلب لا بنسخة ثانية من الملفّ: المرفق يُسجَّل عبر
--  `pr_register_attachment` (فيمرّ بحارس الملفّات وR2 وسجلّ التدقيق) ثمّ تشير
--  إليه الرسالة. فالدليل واحد يظهر في لوحة المرفقات وفي الخيط معاً.
ALTER TABLE proc_pr_messages ADD COLUMN IF NOT EXISTS attachment_ids bigint[];

--  ⚠️ التوقيع القديم يُسقَط لا يُترَك: بقاؤه مع توقيعٍ رابعٍ ذي قيمة افتراضية
--     يجعل نداءً بثلاثة معاملات مرشَّحاً لاثنين. والإسقاط **متوافق خلفيّاً**:
--     العميل المنشور ينادي بثلاثة معاملات مسمّاة فتملأ القيمةُ الافتراضية الرابع.
DROP FUNCTION IF EXISTS pr_post_message(text, text, text);

--  بُني على **التعريف الحيّ** (حارس `can_comment` من
--  `db/system2-field-permissions.sql`) لا على نسخة المستودع الأقدم.
--  وأُعيد إدراج سطر التدقيق الذي سقط سهواً في تلك الهجرة: رسالةٌ بلا أثر
--  تدقيق تُناقض كون القناة سجلّاً للقرارات.
CREATE OR REPLACE FUNCTION pr_post_message(
  p_pr_id text, p_body text, p_kind text DEFAULT 'message',
  p_attachment_ids bigint[] DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_name text; v_txt text := btrim(coalesce(p_body,''));
  v_kind text := lower(coalesce(p_kind,'message')); v_id bigint;
  v_ids bigint[]; v_bad int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT proc_has_perm('can_comment') THEN
    RAISE EXCEPTION 'لا تملك صلاحية الردّ داخل النظام';
  END IF;
  -- رسالةٌ بلا نصّ ولا مرفق لا معنى لها؛ ومرفقٌ بلا نصّ مقبول (يُوسَم بسطر).
  IF v_txt = '' AND coalesce(array_length(p_attachment_ids,1),0) = 0 THEN
    RAISE EXCEPTION 'الرسالة فارغة';
  END IF;
  IF length(v_txt) > 4000 THEN RAISE EXCEPTION 'الرسالة طويلة جداً (4000 حرف كحدّ أقصى)'; END IF;
  IF v_kind NOT IN ('question','answer','message') THEN v_kind := 'message'; END IF;
  IF NOT EXISTS (SELECT 1 FROM proc_purchase_requests WHERE id = p_pr_id) THEN
    RAISE EXCEPTION 'الطلب غير موجود';
  END IF;
  IF NOT proc_can_see_pr(p_pr_id) THEN RAISE EXCEPTION 'هذا الطلب خارج نطاقك'; END IF;

  -- المرفقات: كلٌّ موجود وحيّ و**على هذا الطلب**. الإسقاط الصامت لمعرّف خاطئ
  -- يعني رسالةً تَعِد بمرفق لا وجود له — فالرفض أصدق.
  IF coalesce(array_length(p_attachment_ids,1),0) > 0 THEN
    IF array_length(p_attachment_ids,1) > 10 THEN
      RAISE EXCEPTION 'حدّ المرفقات في الرسالة الواحدة عشرة';
    END IF;
    SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_attachment_ids) AS x;
    SELECT count(*) INTO v_bad FROM unnest(v_ids) AS x
      WHERE NOT EXISTS (SELECT 1 FROM proc_pr_attachments a
                        WHERE a.id = x AND a.pr_id = p_pr_id AND a.deleted_at IS NULL);
    IF v_bad > 0 THEN RAISE EXCEPTION 'مرفق غير موجود أو لا يخصّ هذا الطلب'; END IF;
  END IF;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  INSERT INTO proc_pr_messages (pr_id, author, author_name, body, kind, attachment_ids)
  VALUES (p_pr_id, v_me, coalesce(v_name, v_me), v_txt, v_kind, v_ids)
  RETURNING id INTO v_id;

  INSERT INTO proc_audit_log (username, display_name, action, entity_type, entity_id, new_value)
  VALUES (v_me, coalesce(v_name,v_me), 'pr_'||v_kind, 'pr', p_pr_id,
          jsonb_build_object('body', left(v_txt,300),
                             'attachments', coalesce(array_length(v_ids,1),0)));

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'kind', v_kind,
                            'attachments', coalesce(array_length(v_ids,1),0));
END $fn$;

REVOKE ALL ON FUNCTION pr_post_message(text, text, text, bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_post_message(text, text, text, bigint[]) TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
--  التراجع (لا تُشغّله إلا بقرار صريح — يُعيد حجب المرفقات عن الموظّف المُنطَّق)
-- ----------------------------------------------------------------------------
--  DO $$ DECLARE t text;
--  BEGIN
--    FOREACH t IN ARRAY ARRAY['proc_pr_attachments','proc_pr_audit'] LOOP
--      EXECUTE format($p$CREATE POLICY "no_scoped_access" ON %I
--        AS RESTRICTIVE FOR ALL TO authenticated
--        USING (NOT proc_is_scoped()) WITH CHECK (NOT proc_is_scoped())$p$, t);
--    END LOOP;
--  END $$;
--  DROP FUNCTION IF EXISTS pr_remove_attachment(bigint);
-- ════════════════════════════════════════════════════════════════════════════

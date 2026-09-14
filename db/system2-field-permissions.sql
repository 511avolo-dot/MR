-- ════════════════════════════════════════════════════════════════════════════
--  صلاحيات الميدان — قدرات موظّف الصيانة والتشغيل تصير قابلة للمنح والسحب
--  ────────────────────────────────────────────────────────────────────────────
--  بلاغ المالك (2026-09-13): «لا يوجد إدارة صلاحيات للمستخدمين الخاصين بالصيانة
--  والتشغيل مثل رفع مستند وغيره من الأدوات — لا يوجد صلاحيات ممكن إعطاؤها أو سحبها».
--
--  والقياس أثبته: من تسع قدرات فعليّة لموظّف الميدان، **اثنتان فقط** كان لهما
--  مفتاح (`can_receive_po` و`can_view_amounts`). الباقي محروس بالرؤية/الملكية —
--  «أنت صاحب الطلب» / «الأمر في قطاعك» — وهي حراسة **نطاق** لا **صلاحية**:
--  تمنع الوصول إلى بيانات الغير، ولا تُمكِّن المدير من أن يقول «هذا الموظّف يرفع
--  طلباً ولا يرفع مستنداً» أو «هذا يتابع ولا يرفع». فالقدرات كانت ضمنيّة: من كان
--  مُنطَّقاً امتلكها كلّها بلا قرار.
--
--  هذه الهجرة تُنشئ أربعة مفاتيح ونظائرها على الخادم:
--    can_create_pr      رفع طلبات الشراء (وتعديلها وحذفها وقوالبها)
--    can_upload_docs    رفع المستندات والسندات
--    can_comment        التعليق على الأوامر والردّ على استفهام المشتريات
--    can_print_followup طباعة تقرير المتابعة الميدانيّ  ← واجهة فقط (لا كتابة)
--
--  ⚠️ عدم الانحدار هو القيد الأوّل — والفخّ هنا حقيقيّ:
--  `pr_has_perm()` القائمة افتراضها **false** عند غياب المفتاح، واستعمالها هنا
--  كان **سيسلب موظفي المكتب الثلاثة** رفعَ الطلبات والمستندات والتعليق لحظة
--  التطبيق (صفوفهم لا تحمل المفاتيح الجديدة أصلاً). فبُنيت `proc_has_perm()`
--  بدلالة `proc_can_view_amounts` المُثبَتة: الغياب = **true لموظّف المكتب**
--  و**false للمُنطَّق**، وهو ما يطابق `hasPermission` في الواجهة حرفيّاً.
--
--  تُشغَّل **بعد** db/system2-staff-scope.sql و db/system2-request-flow.sql
--  و db/system2-request-tracking.sql. إضافيّة وidempotent. كتلة التراجع في النهاية.
-- ════════════════════════════════════════════════════════════════════════════

-- ═══════════════ 1) المُساعد: صلاحية بدلالة ثلاثية صحيحة ═══════════════
-- `p_office_default` = الافتراضيّ عند غياب المفتاح لموظّف المكتب (غير المُنطَّق)،
-- ويطابق `userDefault` في كتالوج الواجهة `PERMISSION_DEFS`. المُنطَّق افتراضه
-- **false دائماً** (المنح صريح أو لا شيء).
--
-- ⚠️ `CASE` لا `AND`، و`coalesce` داخليّة على `jsonb_array_length`:
--    `scope_sectors` عمودها NULL لكل موظفي المكتب، فبدونها يُنتج التعبير NULL
--    لا true فيسقط الصفّ من EXISTS ويفقد المكتبُ قدراته. (نفس فخّ LP1.)
CREATE OR REPLACE FUNCTION proc_has_perm(p_key text, p_office_default boolean DEFAULT true)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS(
    SELECT 1 FROM proc_users u
     WHERE lower(u.username) = lower(proc_me())
       AND coalesce(u.active, true)
       AND (u.role = 'admin'
            OR coalesce(
                 (u.permissions ->> p_key)::boolean,
                 CASE WHEN coalesce(
                             CASE WHEN jsonb_typeof(u.scope_sectors) = 'array'
                                  THEN jsonb_array_length(u.scope_sectors) > 0 END,
                             false)
                      THEN false            -- مُنطَّق: الغياب = منع
                      ELSE p_office_default -- موظّف مكتب: الغياب = الافتراضيّ
                 END)
           ));
$fn$;
REVOKE ALL ON FUNCTION proc_has_perm(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION proc_has_perm(text, boolean) TO authenticated;


-- ═══════════════ 2) رفع الطلبات: السياسات ═══════════════
-- الرؤية (`pr_select`) **لا تُمَسّ**: سحب الرفع لا يعني إخفاء طلباته السابقة —
-- «متابعة فقط» يظلّ يتابع ما رفعه قبل السحب.
ALTER TABLE proc_purchase_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "pr_insert" ON proc_purchase_requests;
DROP POLICY IF EXISTS "pr_update" ON proc_purchase_requests;
DROP POLICY IF EXISTS "pr_delete" ON proc_purchase_requests;
CREATE POLICY "pr_insert" ON proc_purchase_requests FOR INSERT TO authenticated
  WITH CHECK (proc_has_perm('can_create_pr')
              AND (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me())));
CREATE POLICY "pr_update" ON proc_purchase_requests FOR UPDATE TO authenticated
  USING      (proc_has_perm('can_create_pr')
              AND (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me())))
  WITH CHECK (proc_has_perm('can_create_pr')
              AND (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me())));
CREATE POLICY "pr_delete" ON proc_purchase_requests FOR DELETE TO authenticated
  USING      (proc_has_perm('can_create_pr')
              AND (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me())));

-- بنود الطلب تتبع الطلب: من لا يرفع طلباً لا يكتب بنوده.
-- ⚠️ `prc_select` تبقى على `proc_can_see_pr` وحدها (رؤية لا صلاحية).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['proc_pr_items','proc_pr_approvals'] LOOP
    CONTINUE WHEN to_regclass('public.' || t) IS NULL;
    EXECUTE format('DROP POLICY IF EXISTS "prc_insert" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "prc_update" ON %I', t);
    EXECUTE format('DROP POLICY IF EXISTS "prc_delete" ON %I', t);
    EXECUTE format($f$CREATE POLICY "prc_insert" ON %I FOR INSERT TO authenticated
                        WITH CHECK (proc_has_perm('can_create_pr') AND proc_can_see_pr(pr_id))$f$, t);
    EXECUTE format($f$CREATE POLICY "prc_update" ON %I FOR UPDATE TO authenticated
                        USING (proc_has_perm('can_create_pr') AND proc_can_see_pr(pr_id))
                        WITH CHECK (proc_has_perm('can_create_pr') AND proc_can_see_pr(pr_id))$f$, t);
    -- ⚠️ الحذف بـ`proc_can_see_pr` لا `NOT proc_is_scoped()`: المُنطَّق يحذف بنود
    --    طلبه عند إعادة الحفظ (تُحذف ثمّ تُدرَج)، وبدونها تتضاعف البنود. (سابقة NM.)
    EXECUTE format($f$CREATE POLICY "prc_delete" ON %I FOR DELETE TO authenticated
                        USING (proc_has_perm('can_create_pr') AND proc_can_see_pr(pr_id))$f$, t);
  END LOOP;
END $$;

-- القوالب المتكرّرة جزء من «رفع الطلبات» (قرار المالك: أربعة مفاتيح لا سبعة).
DO $$
BEGIN
  IF to_regclass('public.proc_pr_templates') IS NULL THEN RETURN; END IF;
  DROP POLICY IF EXISTS "tpl_insert" ON proc_pr_templates;
  DROP POLICY IF EXISTS "tpl_update" ON proc_pr_templates;
  DROP POLICY IF EXISTS "tpl_delete" ON proc_pr_templates;
  CREATE POLICY "tpl_insert" ON proc_pr_templates FOR INSERT TO authenticated
    WITH CHECK (proc_has_perm('can_create_pr')
                AND (lower(owner) = lower(proc_me()) OR NOT proc_is_scoped()));
  CREATE POLICY "tpl_update" ON proc_pr_templates FOR UPDATE TO authenticated
    USING      (proc_has_perm('can_create_pr')
                AND (lower(owner) = lower(proc_me()) OR NOT proc_is_scoped()))
    WITH CHECK (proc_has_perm('can_create_pr')
                AND (lower(owner) = lower(proc_me()) OR NOT proc_is_scoped()));
  CREATE POLICY "tpl_delete" ON proc_pr_templates FOR DELETE TO authenticated
    USING      (proc_has_perm('can_create_pr')
                AND (lower(owner) = lower(proc_me()) OR NOT proc_is_scoped()));
END $$;


-- ═══════════════ 3) رفع المستندات: pr_set_doc ═══════════════
-- ⚠️ الحارس **أوّل شيء** بعد الهوية: من لا يملك الصلاحية يُرفَض قبل أن نلمس
--    الطلب أو نأخذ عليه قفلاً.
CREATE OR REPLACE FUNCTION pr_set_doc(p_pr_id text, p_key text, p_name text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := proc_me(); v_req text; v_st text; v_old text;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT proc_has_perm('can_upload_docs') THEN
    RAISE EXCEPTION 'لا تملك صلاحية رفع المستندات';
  END IF;
  SELECT requester, status, doc_key INTO v_req, v_st, v_old
    FROM proc_purchase_requests WHERE id = p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF NOT (lower(coalesce(v_req,'')) = lower(v_me)
          OR pr_has_perm('can_manage_rfq') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'المرفق يرفعه مقدّم الطلب أو المشتريات';
  END IF;
  IF p_key IS NOT NULL AND p_key NOT LIKE ('docs/pr/' || p_pr_id || '/%') THEN
    RAISE EXCEPTION 'مفتاح المرفق خارج مجال هذا الطلب';
  END IF;
  -- ⚠️ الدليل لا يُمسَح بعد الإرسال: المرفق **هو** الاعتماد في هذا النموذج،
  -- فإزالته تترك طلباً مُرسَلاً بلا سنده. المسح مسموح في المسودّة والمُعاد فقط.
  IF p_key IS NULL AND coalesce(v_old,'') <> ''
     AND coalesce(v_st,'') NOT IN ('draft','returned') THEN
    RAISE EXCEPTION 'لا يُزال سند الطلب بعد إرساله (الحالة: %)', coalesce(v_st,'—');
  END IF;
  -- الاستبدال بعد الإرسال بصلاحية المشتريات وحدها (تصحيح مستند خاطئ).
  IF p_key IS NOT NULL AND coalesce(v_old,'') <> '' AND p_key <> v_old
     AND coalesce(v_st,'') NOT IN ('draft','returned')
     AND NOT (pr_has_perm('can_manage_rfq') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'استبدال سند طلب مُرسَل من صلاحية المشتريات';
  END IF;
  UPDATE proc_purchase_requests
     SET doc_key = p_key, doc_name = p_name, updated_at = now(), updated_by = v_me
   WHERE id = p_pr_id;
  RETURN jsonb_build_object('ok', true, 'key', p_key);
END $fn$;
REVOKE ALL ON FUNCTION pr_set_doc(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_set_doc(text, text, text) TO authenticated;


-- ═══════════════ 4) التعليق والردّ ═══════════════
CREATE OR REPLACE FUNCTION pr_post_message(p_pr_id text, p_body text, p_kind text DEFAULT 'message')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_name text; v_txt text := btrim(coalesce(p_body,''));
  v_kind text := lower(coalesce(p_kind,'message')); v_id bigint;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT proc_has_perm('can_comment') THEN
    RAISE EXCEPTION 'لا تملك صلاحية الردّ داخل النظام';
  END IF;
  IF v_txt = '' THEN RAISE EXCEPTION 'الرسالة فارغة'; END IF;
  IF length(v_txt) > 4000 THEN RAISE EXCEPTION 'الرسالة طويلة جداً (4000 حرف كحدّ أقصى)'; END IF;
  IF v_kind NOT IN ('question','answer','message') THEN v_kind := 'message'; END IF;
  IF NOT EXISTS (SELECT 1 FROM proc_purchase_requests WHERE id = p_pr_id) THEN
    RAISE EXCEPTION 'الطلب غير موجود';
  END IF;
  IF NOT proc_can_see_pr(p_pr_id) THEN RAISE EXCEPTION 'هذا الطلب خارج نطاقك'; END IF;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  INSERT INTO proc_pr_messages (pr_id, author, author_name, body, kind)
  VALUES (p_pr_id, v_me, coalesce(v_name, v_me), v_txt, v_kind)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $fn$;
REVOKE ALL ON FUNCTION pr_post_message(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_post_message(text, text, text) TO authenticated;

-- ملاحظات متابعة أمر الشراء — الحارس نفسه بالمفتاح نفسه.
-- ⚠️ يُعاد تعريفها بالكامل لأن `CREATE OR REPLACE` لا يُضيف سطراً لجسم قائم.
CREATE OR REPLACE FUNCTION po_add_comment(p_po text, p_text text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_name text; v_sector text; v_at timestamptz := now();
  v_txt text := btrim(coalesce(p_text, ''));
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF NOT proc_has_perm('can_comment') THEN
    RAISE EXCEPTION 'لا تملك صلاحية إضافة ملاحظات المتابعة';
  END IF;
  IF v_txt = '' THEN RAISE EXCEPTION 'الملاحظة فارغة'; END IF;
  IF length(v_txt) > 2000 THEN RAISE EXCEPTION 'الملاحظة طويلة جداً (2000 حرف كحدّ أقصى)'; END IF;

  SELECT sector INTO v_sector FROM proc_purchase_orders WHERE po_number = p_po FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'أمر الشراء غير موجود'; END IF;
  IF NOT proc_can_see_po(v_sector) THEN RAISE EXCEPTION 'هذا الأمر خارج نطاقك'; END IF;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  UPDATE proc_purchase_orders
     SET comments = coalesce(comments, '[]'::jsonb) || jsonb_build_object(
           'text', v_txt, 'by', coalesce(v_name, v_me), 'at', to_char(v_at, 'YYYY-MM-DD"T"HH24:MI:SS')),
         updated_at = v_at, updated_by = v_me
   WHERE po_number = p_po;
  RETURN jsonb_build_object('ok', true);
END $fn$;
REVOKE ALL ON FUNCTION po_add_comment(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION po_add_comment(text, text) TO authenticated;


-- ═══════════════ التحقّق (شغّلها بعد التطبيق) ═══════════════
-- موظّف المكتب (غير مُنطَّق، بلا المفاتيح) يجب أن يبقى true للأربعة:
--   SELECT proc_has_perm('can_create_pr'), proc_has_perm('can_upload_docs'),
--          proc_has_perm('can_comment'),   proc_has_perm('can_print_followup');
-- ومُنطَّق بلا مفتاح ⇒ false، وبمفتاح=true ⇒ true، وبمفتاح=false ⇒ false.


-- ═══════════════ التراجع ═══════════════
/*
-- إعادة السياسات إلى ما قبل هذه الهجرة (حراسة نطاق بلا صلاحية):
DROP POLICY IF EXISTS "pr_insert" ON proc_purchase_requests;
DROP POLICY IF EXISTS "pr_update" ON proc_purchase_requests;
DROP POLICY IF EXISTS "pr_delete" ON proc_purchase_requests;
CREATE POLICY "pr_insert" ON proc_purchase_requests FOR INSERT TO authenticated
  WITH CHECK (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me()));
CREATE POLICY "pr_update" ON proc_purchase_requests FOR UPDATE TO authenticated
  USING (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me()))
  WITH CHECK (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me()));
CREATE POLICY "pr_delete" ON proc_purchase_requests FOR DELETE TO authenticated
  USING (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me()));
-- ثمّ أعِد تشغيل الأقسام المعنيّة من system2-request-flow.sql و
-- system2-request-tracking.sql لاستعادة الدوال الثلاث بأجسامها السابقة.
DROP FUNCTION IF EXISTS proc_has_perm(text, boolean);
*/

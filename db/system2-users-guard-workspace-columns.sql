-- ════════════════════════════════════════════════════════════════════════════
--  سدّ تصعيد صلاحية: أعمدة الموديل الجديدة خارج حارس proc_users
--  ---------------------------------------------------------------------------
--  🔴 الثغرة (مُستغَلَّة فعليّاً قبل هذا الملف):
--     سياسة `users_update` على `proc_users` هي USING(true) WITH CHECK(true)،
--     فالمدافع الوحيد هو المُشغِّل `proc_users_guard`. والحارس يمرّر أي UPDATE
--     لا يمسّ قائمته الحسّاسة كـ«تعديل حميد» — و`db/system2-purchase-request-workspace.sql`
--     أضاف ثلاثة أعمدة تحمل صلاحيات **خارج تلك القائمة**:
--        pr_permission_overrides · pr_profile_key · pr_department_ids
--     فكان أي مستخدم مسجَّل يمنح نفسه بطلب PATCH واحد:
--        {"pr_view_financials":true,"pr_manage_users":true,"pr_view_all":true}
--     ⇒ proc_can_view_amounts() تصير true (وهي ما يُفرِغ المبالغ في
--       proc_po_visible) · ويدير مستخدمي الموديل · ويرى كل الطلبات.
--
--  ⚠️ وهي **نفس ثغرة 2026-09-10 حرفيّاً** حين أُضيف `scope_sectors` بلا حارس.
--     القاعدة المستفادة: كل عمود جديد يحمل صلاحية يُضاف إلى هذه القائمة في
--     نفس الهجرة التي تُنشئه — وإلّا صار منحاً ذاتيّاً صامتاً.
--
--  يُطبَّق بعد db/system2-purchase-request-workspace.sql.
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION proc_users_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF pr_is_service() THEN RETURN COALESCE(NEW, OLD); END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.permissions   IS NOT DISTINCT FROM OLD.permissions
     AND NEW.role          IS NOT DISTINCT FROM OLD.role
     AND NEW.active        IS NOT DISTINCT FROM OLD.active
     AND NEW.is_away       IS NOT DISTINCT FROM OLD.is_away
     AND NEW.delegate_to   IS NOT DISTINCT FROM OLD.delegate_to
     AND NEW.username      IS NOT DISTINCT FROM OLD.username
     AND NEW.email         IS NOT DISTINCT FROM OLD.email
     AND NEW.password_hash IS NOT DISTINCT FROM OLD.password_hash
     AND NEW.scope_sectors IS NOT DISTINCT FROM OLD.scope_sectors
     -- أعمدة موديل طلبات الشراء — تحمل صلاحيات فتُحرَس كالبقيّة:
     AND NEW.pr_profile_key          IS NOT DISTINCT FROM OLD.pr_profile_key
     AND NEW.pr_permission_overrides IS NOT DISTINCT FROM OLD.pr_permission_overrides
     AND NEW.pr_department_ids       IS NOT DISTINCT FROM OLD.pr_department_ids
  THEN RETURN NEW; END IF;

  IF pr_has_perm('can_manage_users') THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل المستخدمين أو صلاحياتهم يتطلّب صلاحية «إدارة المستخدمين»';
END $fn$;

COMMIT;

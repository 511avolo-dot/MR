-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 015 — رؤية المعتمِد المنتظَر (إغلاق ثغرة حجب حقيقية من فحص السيناريوهات)
--  المشكلة المكتشفة: portal_can_see_request كانت تمنح الرؤية للمالك/القطاع/all/
--  «معتمِد شارك فعلاً» — لكن **المعتمِد المقصود للمرحلة المعلّقة** ذا النطاق own
--  (مدير قسم بلا وظيفة، مفوَّض موظف عن غائب، عضو لجنة موظف) لا يرى الطلب الذي
--  ينتظر اعتماده أصلاً، فلا يستطيع فتحه ولا اعتماده من الواجهة.
--  الحلّ: توسيع الرؤية لتشمل من تستهدفه أي مرحلة معلّقة في السلاسل الثلاث
--  (الحاجة/التعميد/أمر الشراء) مباشرةً أو تفويضاً — دون توسيع عام.
--  idempotent. شغّلها في Supabase mwbjoysuybgbrvfrprex بعد 014.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION portal_can_see_request(p_id text, p_requester text, p_dept text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    portal_is_admin()
    OR portal_my_scope() = 'all'
    OR p_requester = portal_username()
    OR (portal_my_scope() = 'sector' AND portal_my_sector() IS NOT NULL AND EXISTS (
          SELECT 1 FROM portal_departments d
           WHERE d.id = p_dept AND d.sector = portal_my_sector()))
    -- معتمِد شارك فعلاً في سلسلة الحاجة
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.approver = portal_username())
    -- (015) المعتمِد المقصود لمرحلة معلّقة في سلسلة الحاجة (مباشرة)
    OR EXISTS (SELECT 1 FROM portal_approvals a
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND ( a.approver = portal_username()
                        OR (a.role_key IS NOT NULL AND portal_has_perm(a.role_key))
                        OR (a.resolver = 'dept_manager' AND EXISTS (
                              SELECT 1 FROM portal_departments d
                               WHERE d.id = p_dept AND d.manager_user = portal_username())) ))
    -- (015) المفوَّض عن معتمِد غائب لمرحلة معلّقة
    OR EXISTS (SELECT 1
                 FROM portal_approvals a
                 JOIN portal_users u ON u.is_away AND u.delegate_to = portal_username()
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND ( a.approver = u.username
                        OR (a.role_key IS NOT NULL AND coalesce((u.permissions ->> a.role_key)::boolean, false))
                        OR (a.resolver = 'dept_manager' AND EXISTS (
                              SELECT 1 FROM portal_departments d
                               WHERE d.id = p_dept AND d.manager_user = u.username)) ))
    -- (015) معتمِد معلّق في سلسلة اعتماد التعميد
    OR EXISTS (SELECT 1 FROM portal_award_approvals a
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND a.role_key IS NOT NULL AND portal_has_perm(a.role_key))
    -- (015) معتمِد معلّق في سلسلة أمر الشراء (صلاحية أو عضوية اللجنة المصغّرة)
    OR EXISTS (SELECT 1 FROM portal_po_approvals a
                WHERE a.request_id = p_id AND a.decision = 'pending'
                  AND ( (a.role_key IS NOT NULL AND portal_has_perm(a.role_key))
                        OR (a.kind = 'committee' AND EXISTS (
                              SELECT 1 FROM portal_settings s
                               WHERE s.key = 'committee_members' AND s.value ? portal_username())) ));
$fn$;

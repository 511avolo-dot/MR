-- ═══════════════════════════════════════════════════════════════════════════
-- النظام 2 — تصليب كشف دوال DEFINER (من مدقّق Supabase الحيّ 2026-09-15)
-- تُطبَّق بعد: db/system2-approval-identity-and-history.sql
--
-- بطلب المالك «تأكّد أن كل شيء سليم في القاعدة أو النظام، افحص كل شيء».
-- المدقّق أظهر 21 دالّة DEFINER قابلة للتنفيذ من `anon`. أغلبها **مقصود/حميد**
-- (مساعدات هويّة تُرجِع NULL بلا JWT، وRPCs تفحص الصلاحية داخلها) — وهو موثّق
-- سابقاً. لكن ثلاث فئات منها ليست كذلك، ولا مستدعي لأيٍّ منها في المستودع كلّه
-- (مُتحقَّق بالبحث على `index.html` و`requests.html` و`functions/api/*`):
--
--   ① `pr_run_sla()` — SECURITY DEFINER **وتكتب** (تصعيد + إشعارات + تدقيق).
--      كشفها لـ`anon` يعني أنّ أي زائر بلا حساب يُطلق دورة تصعيد كاملة عبر
--      `/rest/v1/rpc/pr_run_sla`. هذه سابقة مُغلَقة في البوابة (الهجرة 017)
--      ولم تُغلَق هنا. تُقصر على `service_role`.
--
--   ② `pr_transition(text,text,text)` — الدالّة القديمة التي حلّ محلّها
--      `pr_decide`. لا تُستدعى من أي مكان، وتبقى مكشوفة لـ`anon`. تُقصر.
--
--   ③ دوال المُشغِّلات (`pr_guard_approval` · `pr_audit_approval` ·
--      `proc_config_guard` · `proc_settings_guard` · `proc_users_guard`)
--      تُستدعى عبر المُشغِّل وحده. نداؤها مباشرةً يفشل بطبيعته، لكن إبقاءها
--      في السطح المكشوف ضجيجٌ دائم في المدقّق يُخفي ما يستحقّ النظر.
--
--   ④ `proc_drop_all_policies(text)` — مساعد هجرات يُنفّذ `DROP POLICY` بـ
--      `EXECUTE format(...)`، وهو **SECURITY INVOKER** (فلا يملك المتصل حقّ
--      الحذف) لكنّه بلا `search_path` مثبَّت ومكشوف في الـAPI. لا شأن لمساعد
--      هجرات بواجهة عامّة.
--
-- ⚠️ لا يُسحَب شيء يستعمله كودٌ منشور: الأربعة بلا مستدعٍ واحد في المستودع.
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ① دورة SLA: خادمية بحتة
REVOKE ALL ON FUNCTION pr_run_sla() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION pr_run_sla() TO service_role;

-- ② الانتقال القديم (حلّ محلّه pr_decide)
REVOKE ALL ON FUNCTION pr_transition(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION pr_transition(text, text, text) TO service_role;

-- ③ دوال المُشغِّلات — تُستدعى عبر المُشغِّل لا عبر الـAPI
REVOKE ALL ON FUNCTION pr_guard_approval()   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION pr_audit_approval()   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION pr_audit_status()     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION proc_config_guard()   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION proc_settings_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION proc_users_guard()    FROM PUBLIC, anon, authenticated;

-- ④ مساعد الهجرات: search_path مثبَّت + خارج السطح المكشوف
CREATE OR REPLACE FUNCTION proc_drop_all_policies(p_table text)
RETURNS void
LANGUAGE plpgsql SET search_path = public AS $fn$
DECLARE p record;
BEGIN
  FOR p IN SELECT policyname FROM pg_policies
            WHERE schemaname = 'public' AND tablename = p_table LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p.policyname, p_table);
  END LOOP;
END $fn$;
REVOKE ALL ON FUNCTION proc_drop_all_policies(text) FROM PUBLIC, anon, authenticated;

COMMIT;

-- ═══════════════════════════ كتلة التراجع ═════════════════════════════════
-- BEGIN;
--   GRANT EXECUTE ON FUNCTION pr_run_sla() TO authenticated, anon;
--   GRANT EXECUTE ON FUNCTION pr_transition(text,text,text) TO authenticated, anon;
--   GRANT EXECUTE ON FUNCTION pr_guard_approval(), pr_audit_approval(), pr_audit_status(),
--         proc_config_guard(), proc_settings_guard(), proc_users_guard() TO authenticated, anon;
--   GRANT EXECUTE ON FUNCTION proc_drop_all_policies(text) TO authenticated, anon;
-- COMMIT;

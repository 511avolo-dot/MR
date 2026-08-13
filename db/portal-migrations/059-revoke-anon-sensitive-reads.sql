-- ═══════════════════════════════════════════════════════════════════════════
--  059 — تصليب دفاعي: سحب منح SELECT للـanon عن جداول PII/مالية/هوية (تدقيق 2026-07-27)
--  ─────────────────────────────────────────────────────────────────────────
--  الرصد (تدقيق المؤسسة): للدور `anon` منحُ جدولٍ (table-level GRANT SELECT) على
--  `portal_users`/`portal_payments`/`portal_suppliers`/`portal_beneficiaries` —
--  وهو منح افتراضي من Supabase. **RLS يحجب كل الصفوف فعلاً** (سياسات SELECT مقصورة
--  على `authenticated` بشرط صلاحية)، فلا تسريب قائم؛ لكنّ المنح غير المستخدَم سطحُ
--  هجوم زائد (لا مسار قراءة anon شرعي — كل القراءات في `loadAll` خلف جلسة Auth،
--  وصفحات المورّد تستخدم RPC لا قراءة جداول). سحبه = دفاع في العمق (belt-and-suspenders).
--
--  آمن ومتحقَّق: لا كود anon يقرأ هذه الجداول (فحص `loadAll` خلف `if(!session)` +
--  فحص صفحات المورّد). service_role/authenticated غير متأثّرين. idempotent.
--  ⚠️ تُطبَّق حيّاً بعد 058. مدمجة في db/portal-standalone.sql.
-- ═══════════════════════════════════════════════════════════════════════════
-- سحب منح anon (مُتحقَّق حيّاً أنّ authenticated لا يرث anon فلا يتأثّر) + تأكيد صريح
-- لمنح authenticated (لا-عمل على Supabase حيث كل دور مستقلّ؛ يوثّق النيّة ويصمد لأي نموذج أدوار).
REVOKE SELECT ON portal_users         FROM anon;
REVOKE SELECT ON portal_payments      FROM anon;
REVOKE SELECT ON portal_suppliers     FROM anon;
REVOKE SELECT ON portal_beneficiaries FROM anon;
GRANT  SELECT ON portal_users         TO authenticated;
GRANT  SELECT ON portal_payments      TO authenticated;
GRANT  SELECT ON portal_suppliers     TO authenticated;
GRANT  SELECT ON portal_beneficiaries TO authenticated;

-- تحقّق:
--   SELECT has_table_privilege('anon','portal_payments','SELECT');           ⇒ false
--   SELECT has_table_privilege('authenticated','portal_payments','SELECT');  ⇒ true

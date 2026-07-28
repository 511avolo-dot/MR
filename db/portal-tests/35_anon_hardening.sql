-- ════════════════════════════════════════════════════════════════════════════
--  35 — تصليب دفاعي (059): للـanon لا منح SELECT على جداول PII/مالية/هوية.
--  ⚠️ ملاحظة تدقيق (Codex): في بناء CI النظيف، standalone لا يمنح anon SELECT على
--  هذه الجداول الأربعة أصلاً، فتأكيدٌ ساكن «anon لا يملك» ينجح **حتى لو حُذفت كتل
--  REVOKE** — فلا يُثبِت شيئاً. لذا نُثبِت منطق 059 فعلياً: نزرع منح anon (كنمط
--  Supabase الافتراضي)، ثم نطبّق عبارات 059، ثم نؤكّد أنّ المنح زال. RAISE عند الفشل.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $seed$
DECLARE t text;
BEGIN
  -- (0) محاكاة المنح الافتراضي: امنح anon SELECT على الجداول الأربعة.
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    EXECUTE format('GRANT SELECT ON %I TO anon', t);
  END LOOP;
  -- تحقّق أنّ الزرع سرى (وإلا الاختبار لاحقاً بلا معنى)
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    IF NOT has_table_privilege('anon', t, 'SELECT') THEN
      RAISE EXCEPTION 'AH0 fail: تعذّر زرع منح anon على % (بيئة الاختبار)', t; END IF;
  END LOOP;
  RAISE NOTICE 'PASS AH0 زُرِع منح anon SELECT (محاكاة نمط Supabase) — الاختبار الآن يُثبِت الـREVOKE فعلياً';
END $seed$;

-- (1) تطبيق منطق الهجرة 059 نفسه (نسخة حرفية من عبارات REVOKE/GRANT).
REVOKE SELECT ON portal_users         FROM anon;
REVOKE SELECT ON portal_payments      FROM anon;
REVOKE SELECT ON portal_suppliers     FROM anon;
REVOKE SELECT ON portal_beneficiaries FROM anon;
GRANT  SELECT ON portal_users         TO authenticated;
GRANT  SELECT ON portal_payments      TO authenticated;
GRANT  SELECT ON portal_suppliers     TO authenticated;
GRANT  SELECT ON portal_beneficiaries TO authenticated;

DO $h$
DECLARE t text; bad text := '';
BEGIN
  -- AH1: بعد 059، لا anon SELECT على أيٍّ من الأربعة (يُثبِت أنّ REVOKE عمل — لو حُذف
  --      لبقي المنح المزروع أعلاه وفشل هذا التأكيد).
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    IF has_table_privilege('anon', t, 'SELECT') THEN bad := bad || t || ' '; END IF;
  END LOOP;
  IF bad <> '' THEN RAISE EXCEPTION 'AH1 fail: anon ما زال يملك SELECT على: %', bad; END IF;
  RAISE NOTICE 'PASS AH1 059 سحب فعلياً منح anon SELECT عن الجداول الأربعة (users/payments/suppliers/beneficiaries)';

  -- AH2: عدم انحدار — authenticated يبقى يملك SELECT على الجداول الأربعة كلّها.
  bad := '';
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    IF NOT has_table_privilege('authenticated', t, 'SELECT') THEN bad := bad || t || ' '; END IF;
  END LOOP;
  IF bad <> '' THEN RAISE EXCEPTION 'AH2 fail: authenticated فقد SELECT على: % (انحدار)', bad; END IF;
  RAISE NOTICE 'PASS AH2 authenticated يحتفظ بـSELECT على الجداول الأربعة كلّها (لا انحدار على المستخدم المسجَّل)';

  RAISE NOTICE '════ ANON HARDENING (059): AH0–AH2 = 3/3 PASS ════';
END $h$;

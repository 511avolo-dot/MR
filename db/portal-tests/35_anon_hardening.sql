-- ════════════════════════════════════════════════════════════════════════════
--  35 — تصليب دفاعي (059): للـanon لا منح SELECT على جداول PII/مالية/هوية.
--  ⚠️ تدقيق Codex (جولة 2): يجب أن يشغّل الاختبار **ملف الهجرة الفعلي** لا نسخة مضمَّنة —
--  وإلا بقي أخضر حتى لو حُذف/كُسِر الملف المُرسَل. لذا: نزرع منح anon (نمط Supabase)، ثم
--  نُدرِج ملف الهجرة 059 نفسه عبر \ir (include-relative)، ثم نؤكّد أنّ المنح زال. RAISE عند الفشل.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $seed$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    EXECUTE format('GRANT SELECT ON %I TO anon', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    IF NOT has_table_privilege('anon', t, 'SELECT') THEN
      RAISE EXCEPTION 'AH0 fail: تعذّر زرع منح anon على % (بيئة الاختبار)', t; END IF;
  END LOOP;
  RAISE NOTICE 'PASS AH0 زُرِع منح anon SELECT (محاكاة نمط Supabase) قبل تشغيل ملف الهجرة الفعلي';
END $seed$;

-- تشغيل **ملف الهجرة 059 المُرسَل نفسه** (لا نسخة) — أي كسر فيه يُفشِل AH1 لاحقاً.
\ir ../portal-migrations/059-revoke-anon-sensitive-reads.sql

DO $h$
DECLARE t text; bad text := '';
BEGIN
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    IF has_table_privilege('anon', t, 'SELECT') THEN bad := bad || t || ' '; END IF;
  END LOOP;
  IF bad <> '' THEN RAISE EXCEPTION 'AH1 fail: ملف الهجرة 059 لم يسحب منح anon عن: %', bad; END IF;
  RAISE NOTICE 'PASS AH1 ملف الهجرة 059 المُرسَل سحب فعلياً منح anon SELECT عن الجداول الأربعة';

  bad := '';
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    IF NOT has_table_privilege('authenticated', t, 'SELECT') THEN bad := bad || t || ' '; END IF;
  END LOOP;
  IF bad <> '' THEN RAISE EXCEPTION 'AH2 fail: authenticated فقد SELECT على: % (انحدار)', bad; END IF;
  RAISE NOTICE 'PASS AH2 authenticated يحتفظ بـSELECT على الجداول الأربعة كلّها (لا انحدار)';

  RAISE NOTICE '════ ANON HARDENING (059، ملف فعلي): AH0–AH2 = 3/3 PASS ════';
END $h$;

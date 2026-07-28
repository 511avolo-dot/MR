-- ════════════════════════════════════════════════════════════════════════════
--  35 — تصليب دفاعي (059): للـanon لا منح SELECT على جداول PII/مالية/هوية.
--  تأكيد أنّ REVOKE سرى (RLS كان يحجب الصفوف؛ هذا يزيل المنح نفسه). RAISE عند الفشل.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $h$
DECLARE t text; bad text := '';
BEGIN
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    IF has_table_privilege('anon', t, 'SELECT') THEN bad := bad || t || ' '; END IF;
  END LOOP;
  IF bad <> '' THEN RAISE EXCEPTION 'AH1 fail: anon ما زال يملك SELECT على: %', bad; END IF;
  RAISE NOTICE 'PASS AH1 لا منح anon SELECT على جداول PII/مالية/هوية (users/payments/suppliers/beneficiaries)';

  -- عدم انحدار: authenticated يبقى يملك SELECT على كل الجداول الأربعة (القراءة الشرعية بعد الدخول)
  bad := '';
  FOREACH t IN ARRAY ARRAY['portal_users','portal_payments','portal_suppliers','portal_beneficiaries'] LOOP
    IF NOT has_table_privilege('authenticated', t, 'SELECT') THEN bad := bad || t || ' '; END IF;
  END LOOP;
  IF bad <> '' THEN RAISE EXCEPTION 'AH2 fail: authenticated فقد SELECT على: % (انحدار)', bad; END IF;
  RAISE NOTICE 'PASS AH2 authenticated يحتفظ بـSELECT على الجداول الأربعة كلّها (لا انحدار على المستخدم المسجَّل)';

  RAISE NOTICE '════ ANON HARDENING (059): AH1–AH2 = 2/2 PASS ════';
END $h$;

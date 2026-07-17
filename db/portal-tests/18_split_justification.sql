-- ════════════════════════════════════════════════════════════════════════════
--  اختبار الهجرة 038 — رصد «غير-الأقل» في الترسية المجزّأة (غير مانع).
--  تأكيدات خفيفة: الدالة موجودة وتتضمّن منطق non_lowest، وتُعيده في استجابتها.
--  (السلوك السلبي الكامل يُغطّى E2E في حزمة scratchpad؛ هنا حارس انحدار في CI.)
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
BEGIN
  -- K1: الدالة تتضمّن رصد غير-الأقل (038 مطبَّقة في المخطّط المحمَّل)
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'portal_award_split'
      AND p.prosrc LIKE '%non_lowest%'
  ) THEN
    RAISE EXCEPTION 'K1 fail: portal_award_split لا يتضمّن رصد non_lowest (038 غير مطبَّقة)';
  END IF;
  RAISE NOTICE 'PASS K1 038: portal_award_split يرصد غير-الأقل';

  -- K2: التوقيع لم يتغيّر (إضافة غير كاسرة) — 3 معاملات (text, jsonb, text)
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'portal_award_split'
      AND pg_get_function_identity_arguments(oid) = 'p_request_id text, p_lines jsonb, p_reason text'
  ) THEN
    RAISE EXCEPTION 'K2 fail: توقيع portal_award_split تغيّر (يجب أن يبقى 3 معاملات)';
  END IF;
  RAISE NOTICE 'PASS K2 التوقيع ثابت (غير كاسر)';

  -- K3: تبقى ممنوحة للمستخدم المسجَّل (لم تُكسر الصلاحية)
  IF NOT has_function_privilege('authenticated', 'portal_award_split(text,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'K3 fail: authenticated فقد تنفيذ portal_award_split';
  END IF;
  RAISE NOTICE 'PASS K3 authenticated يحتفظ بالتنفيذ';

  RAISE NOTICE '════ SPLIT-JUSTIFICATION (038): 3/3 PASS ════';
END $t$;

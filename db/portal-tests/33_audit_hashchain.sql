-- ════════════════════════════════════════════════════════════════════════════
--  33 — تدقيق مقاوم للعبث (Hash-Chained WORM, 057).
--  الإدراج يُسلسِل التجزئة · التحقّق يؤكّد السلامة · العبث على مستوى القاعدة
--  (تجاوز التطبيق) يُكتشَف · صلاحية التحقّق. كل تأكيد RAISE عند الفشل ⇒ خروج غير صفري.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

DO $seed$
BEGIN
  DELETE FROM portal_users WHERE username LIKE 'hc_%';
  INSERT INTO portal_users(username,email,display_name,role,permissions) VALUES
    ('hc_fin','hc_fin@aldeyabi.com','مالية','user','{"can_see_finance":true}'),
    ('hc_emp','hc_emp@aldeyabi.com','موظف','user','{"can_create":true}');
END $seed$;

DO $b$
DECLARE v_h1 text; v_p2 text; v_h2 text; v_r jsonb; v_id bigint; v_orig jsonb; v_err text;
BEGIN
  -- كتابة ثلاثة صفوف تدقيق (request_id NULL لتفادي قيد FK)
  PERFORM portal_audit_write(NULL,'hc_test_1','tester','portal','{"n":1}'::jsonb);
  PERFORM portal_audit_write(NULL,'hc_test_2','tester','portal','{"n":2}'::jsonb);
  PERFORM portal_audit_write(NULL,'hc_test_3','tester','portal','{"n":3}'::jsonb);

  -- HC1: التجزئة والسلسلة مملوءتان + كل prev_hash = row_hash السابق
  SELECT row_hash INTO v_h1 FROM portal_audit WHERE event='hc_test_1' ORDER BY id DESC LIMIT 1;
  SELECT prev_hash, row_hash INTO v_p2, v_h2 FROM portal_audit WHERE event='hc_test_2' ORDER BY id DESC LIMIT 1;
  IF v_h1 IS NULL OR length(v_h1)<>64 THEN RAISE EXCEPTION 'HC1 fail: row_hash غير محسوب (%)', v_h1; END IF;
  IF v_p2 <> v_h1 THEN RAISE EXCEPTION 'HC1 fail: السلسلة غير مترابطة (prev≠السابق)'; END IF;
  RAISE NOTICE 'PASS HC1 السلسلة مترابطة (SHA-256، prev=row السابق)';

  -- HC2: التحقّق يؤكّد السلامة (بهوية مالية)
  PERFORM set_config('request.jwt.claims','{"email":"hc_fin@aldeyabi.com","role":"authenticated"}',true);
  v_r := portal_audit_verify();
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'HC2 fail: السلسلة مكسورة عند صفّ سليم (%)', v_r; END IF;
  RAISE NOTICE 'PASS HC2 التحقّق يؤكّد السلامة (checked=%)', v_r->>'checked';

  -- HC3: عبث على مستوى القاعدة (تعطيل المُشغِّلات لمحاكاة تجاوز التطبيق) يُكتشَف
  SELECT id, detail INTO v_id, v_orig FROM portal_audit WHERE event='hc_test_2' ORDER BY id DESC LIMIT 1;
  SET session_replication_role = replica;   -- يتجاوز حارس الثبات (محاكاة عبث DBA)
  UPDATE portal_audit SET detail='{"n":999}'::jsonb WHERE id=v_id;
  SET session_replication_role = origin;
  v_r := portal_audit_verify();
  IF (v_r->>'ok') <> 'false' OR (v_r->>'broken_at')::bigint <> v_id THEN
    RAISE EXCEPTION 'HC3 fail: لم يُكتشَف العبث (%)', v_r; END IF;
  RAISE NOTICE 'PASS HC3 العبث على صفّ ماضٍ يكسر السلسلة ويُكتشَف (broken_at=%)', v_id;

  -- استعادة الصفّ الأصلي (تعود السلسلة سليمة)
  SET session_replication_role = replica;
  UPDATE portal_audit SET detail=v_orig WHERE id=v_id;
  SET session_replication_role = origin;
  v_r := portal_audit_verify();
  IF (v_r->>'ok') <> 'true' THEN RAISE EXCEPTION 'HC3 fail: لم تُستعَد السلامة بعد الإرجاع (%)', v_r; END IF;
  RAISE NOTICE 'PASS HC3b استعادة الصفّ الأصلي تُعيد السلسلة سليمة';

  -- HC4: التحقّق صلاحية مالية/أدمن (موظف عادي مرفوض)
  PERFORM set_config('request.jwt.claims','{"email":"hc_emp@aldeyabi.com","role":"authenticated"}',true);
  BEGIN
    PERFORM portal_audit_verify();
    RAISE EXCEPTION 'HC4 fail: موظف عادي تحقّق من التدقيق';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE 'HC4 fail%' THEN RAISE; END IF;
    IF v_err NOT LIKE '%صلاحية%' THEN RAISE EXCEPTION 'HC4 fail: سبب آخر %', v_err; END IF;
  END;
  RAISE NOTICE 'PASS HC4 التحقّق مقيَّد بصلاحية مالية/أدمن';

  RAISE NOTICE '════ AUDIT HASH-CHAIN (057): HC1–HC4 = 5/5 PASS ════';
END $b$;

-- ════════════════════════════════════════════════════════════════════════════
--  اختبار ضبط تغيير آيبان المورد (الهجرة 032) — تأكيدات.
--  يختبر حارس الآيبان (الإنفاذ الأمني الحرِج) + صلاحيات دوال المسار.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_sid bigint; v_blocked boolean; v_iban text;
BEGIN
  PERFORM set_config('app.portal_transition','1',true);
  -- تنظيف + مورد بآيبان صالح
  DELETE FROM portal_supplier_iban_changes WHERE new_iban LIKE 'SA9%';
  DELETE FROM portal_suppliers WHERE name = 'مورد-آيبان-اختبار';
  UPDATE portal_settings SET value = value - 'iban_change_control' WHERE key='portal_settings';
  INSERT INTO portal_suppliers(name, iban, active)
    VALUES ('مورد-آيبان-اختبار','SA1100000000000000000001', true) RETURNING id INTO v_sid;

  -- I1: الضبط مُطفأ (افتراضي) ⇒ تغيير الآيبان المباشر يعمل (لا كسر للسلوك الحالي)
  UPDATE portal_suppliers SET iban = 'SA2200000000000000000002' WHERE id = v_sid;
  SELECT iban INTO v_iban FROM portal_suppliers WHERE id = v_sid;
  IF v_iban <> 'SA2200000000000000000002' THEN RAISE EXCEPTION 'I1 fail: الضبط مطفأ ومع ذلك مُنع'; END IF;
  RAISE NOTICE 'PASS I1 الضبط مُطفأ = تغيير مباشر مسموح (لا كسر)';

  -- I2: الضبط مُفعَّل ⇒ تغيير الآيبان المباشر ممنوع
  UPDATE portal_settings SET value = jsonb_set(coalesce(value,'{}'::jsonb),'{iban_change_control}','1') WHERE key='portal_settings';
  v_blocked := false;
  BEGIN
    UPDATE portal_suppliers SET iban = 'SA9900000000000000000009' WHERE id = v_sid;
  EXCEPTION WHEN OTHERS THEN v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'I2 fail: تغيير الآيبان المباشر لم يُمنَع رغم التفعيل'; END IF;
  SELECT iban INTO v_iban FROM portal_suppliers WHERE id = v_sid;
  IF v_iban <> 'SA2200000000000000000002' THEN RAISE EXCEPTION 'I2 fail: الآيبان تغيّر رغم المنع'; END IF;
  RAISE NOTICE 'PASS I2 الضبط مُفعَّل = تغيير مباشر ممنوع';

  -- I3: الضبط مُفعَّل + علم الاعتماد (مسار الاعتماد) ⇒ يُطبَّق التغيير
  PERFORM set_config('app.iban_change_approved','1',true);
  UPDATE portal_suppliers SET iban = 'SA9900000000000000000009' WHERE id = v_sid;
  PERFORM set_config('app.iban_change_approved','0',true);
  SELECT iban INTO v_iban FROM portal_suppliers WHERE id = v_sid;
  IF v_iban <> 'SA9900000000000000000009' THEN RAISE EXCEPTION 'I3 fail: مسار الاعتماد لم يُطبّق'; END IF;
  RAISE NOTICE 'PASS I3 مسار الاعتماد يُطبّق التغيير';

  -- I4: الضبط مُفعَّل ⇒ تعديل حقل غير الآيبان (contact) يبقى مسموحاً
  UPDATE portal_suppliers SET contact = '0500000000' WHERE id = v_sid;
  RAISE NOTICE 'PASS I4 الحقول غير البنكية غير مقيّدة';

  -- تنظيف
  DELETE FROM portal_supplier_iban_changes WHERE supplier_id = v_sid;
  DELETE FROM portal_suppliers WHERE id = v_sid;
  UPDATE portal_settings SET value = value - 'iban_change_control' WHERE key='portal_settings';
  RAISE NOTICE '════ IBAN: 4/4 PASS ════';
END $t$;

-- I5: صلاحيات المسار (anon محجوب / authenticated مسموح)
DO $t$
BEGIN
  IF has_function_privilege('anon','portal_supplier_iban_request(bigint,text,text)','EXECUTE')
     OR has_function_privilege('anon','portal_supplier_iban_approve(bigint)','EXECUTE')
    THEN RAISE EXCEPTION 'I5 fail: anon ينفّذ دوال تغيير الآيبان'; END IF;
  IF NOT has_function_privilege('authenticated','portal_supplier_iban_request(bigint,text,text)','EXECUTE')
     OR NOT has_function_privilege('authenticated','portal_supplier_iban_approve(bigint)','EXECUTE')
    THEN RAISE EXCEPTION 'I5 fail: authenticated لا ينفّذ دوال المسار'; END IF;
  RAISE NOTICE 'PASS I5 صلاحيات المسار سليمة (anon=منع، authenticated=سماح)';
END $t$;

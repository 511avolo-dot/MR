-- ════════════════════════════════════════════════════════════════════════════
--  تأكيدات دعوة موظفي القطاع — db/system2-staff-invite.sql
--  (منطق الرمز والتسجيل مُختبَر سلوكيّاً في db/portal-tests/file-guard.test.mjs)
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

DO $$
DECLARE n int; v jsonb;
BEGIN
  -- ═══ IV1 — عمود الجوّال موجود (بيانات التواصل التي يُدخِلها الموظّف) ═══
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_name='proc_users' AND column_name='mobile';
  IF n <> 1 THEN RAISE EXCEPTION 'IV1 فشل: عمود mobile غير موجود'; END IF;

  -- ═══ IV2 — مفتاح الإبطال مبذور بصفر (لا إبطال ابتداءً) ═══
  SELECT value INTO v FROM proc_settings WHERE key='staff_invite';
  IF v IS NULL OR (v->>'epoch') IS NULL THEN
    RAISE EXCEPTION 'IV2 فشل: مفتاح staff_invite غير مبذور';
  END IF;
  IF (v->>'epoch')::bigint <> 0 THEN
    RAISE EXCEPTION 'IV2 فشل: الإبطال مضبوط ابتداءً (%)', v->>'epoch';
  END IF;

  -- ═══ IV3 — إعادة التشغيل لا تُصفّر إبطالاً قائماً (ON CONFLICT DO NOTHING) ═══
  UPDATE proc_settings SET value='{"epoch":123456}'::jsonb WHERE key='staff_invite';
  INSERT INTO proc_settings (key, value) VALUES ('staff_invite','{"epoch":0}'::jsonb)
    ON CONFLICT (key) DO NOTHING;
  SELECT value INTO v FROM proc_settings WHERE key='staff_invite';
  IF (v->>'epoch')::bigint <> 123456 THEN
    RAISE EXCEPTION 'IV3 فشل: إعادة تشغيل الهجرة أحيت روابط مُبطَلة';
  END IF;
  UPDATE proc_settings SET value='{"epoch":0}'::jsonb WHERE key='staff_invite';

  RAISE NOTICE '✓ IV1–IV3 — تأكيدات الدعوة ناجحة';
END $$;

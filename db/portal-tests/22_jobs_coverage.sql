-- ════════════════════════════════════════════════════════════════════════════
--  22 — تغطية الأدوار: كل صلاحية تحرس مرحلة في سير العمل تمنحها وظيفة نشطة واحدة على
--  الأقل (فلا مرحلة «معلّقة بلا معتمِد ممكن»)، + سدّ فجوة الوظائف الفارغة (الهجرة 042).
--  يمنع انحداراً مستقبلياً لو أُفرِغت وظيفة حرِجة. تأكيدات RAISE ⇒ خروج غير صفري.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE
  -- المفاتيح الحرِجة التي تحرس مراحل سير العمل (يجب أن تمنحها وظيفة نشطة واحدة على الأقل).
  -- ملاحظة: can_approve_committee مستثنى عمداً — عضوية اللجنة تُضبط كقائمة أسماء عبر
  -- portal_set_committee (committee_members)، لا بوظيفة. وcan_manage_company صلاحية أدمن عليا.
  v_required text[] := ARRAY[
    'can_create','can_approve_stage','can_approve_finance','can_manage_procurement',
    'can_approve_award','can_issue_po','can_disburse','can_verify_stock','can_manage_users'];
  v_key text; v_n int; v_disb int;
BEGIN
  -- (1) تغطية كل مفتاح حرِج
  FOREACH v_key IN ARRAY v_required LOOP
    SELECT count(*) INTO v_n FROM portal_jobs
      WHERE active AND coalesce((permissions->>v_key)::boolean,false);
    IF v_n = 0 THEN
      RAISE EXCEPTION 'COVERAGE fail: لا وظيفة نشطة تمنح % — مرحلة سير العمل التابعة له بلا معتمِد ممكن', v_key;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS J1 كل صلاحية حرِجة (% مفتاحاً) تمنحها وظيفة نشطة ≥1', array_length(v_required,1);

  -- (2) الهجرة 042: المدير العام يمنح can_manage_users (هويّة مرحلة PO العليا)
  SELECT count(*) INTO v_n FROM portal_jobs WHERE key='gm' AND coalesce((permissions->>'can_manage_users')::boolean,false);
  IF v_n <> 1 THEN RAISE EXCEPTION 'J2 fail: وظيفة gm لا تمنح can_manage_users (مرحلة اعتماد المدير العام ستتعطّل)'; END IF;
  RAISE NOTICE 'PASS J2 وظيفة gm تمنح can_manage_users';

  -- (3) الهجرة 042: مراقب الجودة يمنح can_verify_stock
  SELECT count(*) INTO v_n FROM portal_jobs WHERE key='qc' AND coalesce((permissions->>'can_verify_stock')::boolean,false);
  IF v_n <> 1 THEN RAISE EXCEPTION 'J3 fail: وظيفة qc لا تمنح can_verify_stock'; END IF;
  RAISE NOTICE 'PASS J3 وظيفة qc تمنح can_verify_stock';

  -- (4) لا وظيفة نشطة فارغة الصلاحيات (كل وظيفة إمّا تمنح شيئاً أو معطّلة)
  SELECT count(*) INTO v_n FROM portal_jobs WHERE active AND permissions = '{}'::jsonb;
  IF v_n <> 0 THEN RAISE EXCEPTION 'J4 fail: توجد % وظيفة نشطة بصلاحيات فارغة {}', v_n; END IF;
  RAISE NOTICE 'PASS J4 لا وظيفة نشطة بصلاحيات فارغة';

  -- (5) الصرف بفصل مهام ثلاثي: يجب أن تمنح can_disburse وظيفتان مختلفتان على الأقل
  --     (كي يوجد معتمِد ومنفّذ مختلفان مبدئياً على مستوى الأدوار).
  SELECT count(*) INTO v_disb FROM portal_jobs WHERE active AND coalesce((permissions->>'can_disburse')::boolean,false);
  IF v_disb < 2 THEN RAISE EXCEPTION 'J5 fail: can_disburse تمنحه % وظيفة فقط — فصل مهام الصرف يحتاج ≥2', v_disb; END IF;
  RAISE NOTICE 'PASS J5 can_disburse تمنحه % وظيفة (يدعم فصل مهام الصرف: معتمِد≠منفّذ)', v_disb;
END $t$;

SELECT '════ JOBS-COVERAGE (042): كل التأكيدات نجحت ════' AS result;

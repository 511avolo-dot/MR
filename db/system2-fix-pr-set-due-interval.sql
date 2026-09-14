-- ════════════════════════════════════════════════════════════════════════════
--  إصلاح حرِج: مُشغِّل pr_set_due يُفشِل كل إنشاء طلب شراء
--  ---------------------------------------------------------------------------
--  🔴 العَرَض على الإنتاج (مكتشَف بتشغيل دورة طلب حيّة، 2026-09-14):
--       ERROR: 42883: function make_interval(hours => numeric) does not exist
--       QUERY: NEW.stage_due_at := now() + make_interval(hours => v_h)
--       CONTEXT: PL/pgSQL function pr_set_due() line 8
--
--  الجذر: `db/pr-portal.sql` يُعرّف `v_h numeric := pr_sla_hours()`، و
--  `pr_sla_hours()` تُرجع numeric — بينما `make_interval` معاملها `hours integer`.
--  فلا يوجد توقيع مطابق ⇒ يفشل المُشغِّل ⇒ **يفشل كل INSERT/UPDATE يضع الطلب
--  في `in_review`**، أي كل رفع طلب وكل انتقال مرحلة.
--
--  ⚠️ عيب كامن منذ `pr-portal.sql`: لم يظهر لأن بوابة الطلبات الداخلية لم
--  تُستعمل فعليّاً على الإنتاج (صفر طلب) حتى إطلاق موديل طلبات الشراء.
--  ولم تلتقطه الحزم المحلّية لأن قيمة SLA لا تُبذَر فيها فيختلف مسار النوع.
--
--  العلاج: ضرب الفترة بدل `make_interval` — آمن نوعيّاً **ويحفظ الكسور**
--  (make_interval(hours=>int) كان سيبتر نصف الساعة).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION pr_set_due() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $fn$
DECLARE v_h numeric := pr_sla_hours();
BEGIN
  IF NEW.status = 'in_review' THEN
    IF TG_OP='INSERT'
       OR OLD.status IS DISTINCT FROM 'in_review'
       OR NEW.current_seq IS DISTINCT FROM OLD.current_seq THEN
      -- ⚠️ لا تُعِدها إلى make_interval(hours => v_h): معاملها integer وv_h numeric.
      NEW.stage_due_at := now() + (coalesce(v_h,24) * interval '1 hour');
    END IF;
  ELSE
    NEW.stage_due_at := NULL;
  END IF;
  RETURN NEW;
END $fn$;

-- الموضع الثاني بالعلّة نفسها — تصعيد SLA كان معطّلاً كذلك (v_sla numeric):
-- يُصلَح جراحيّاً بلا إعادة كتابة الجسم (165 سطراً) كي لا ينحرف عن الحيّ.
DO $fix$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='pr_run_sla';
  IF v_def IS NULL OR position('make_interval(hours => v_sla)' in v_def)=0 THEN RETURN; END IF;
  EXECUTE replace(v_def,'make_interval(hours => v_sla)','(coalesce(v_sla,24) * interval ''1 hour'')');
END $fix$;

COMMIT;

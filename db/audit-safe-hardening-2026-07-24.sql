-- ═══════════════════════════════════════════════════════════════════════════
--  تصليب آمن غير كاسر — من الفحص الأمني/الوظيفي العميق (النظام 2، مشروع yofcaxvstjcrmbgciwym)
--  مُطبَّق حيّاً 2026-07-24 عبر MCP apply_migration + مُتحقَّق منه بالانتحال (rollback).
--
--  السياق: كل جداول proc_* سياستها RLS = TO authenticated USING(true)/CHECK(true).
--  الحماية على الجداول الحسّاسة تتم عبر مُشغِّلات حارسة (BEFORE trigger) لا عبر RLS:
--    - proc_users        → trg_proc_users_guard  / proc_users_guard()   (قائم مسبقاً — يمنع تصعيد الصلاحية)
--    - proc_approval_rules→ trg_proc_apprules_guard/ proc_config_guard() (قائم مسبقاً)
--  هذا الملف يسدّ فجوتين مكشوفتين (بلا حارس) + يثبّت search_path على 4 دوال.
--  ملاحظة: جداول التشغيل (proc_items/history/suppliers/rfq/po) تبقى مفتوحة للكتابة
--  للمستخدم المسجَّل لأنّ الواجهة تكتبها مباشرةً — تحصينها يتطلّب تحويل الكتابة إلى RPC
--  (مشروع منفصل على نمط البوابة، غير مُطبَّق هنا تفادياً لكسر النظام الحيّ).
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) تثبيت search_path على الدوال التي تفتقده (تحذيرات مدقّق Supabase الأمني).
ALTER FUNCTION public.pr_guard_approval() SET search_path = public;
ALTER FUNCTION public.pr_guard_status()   SET search_path = public;
ALTER FUNCTION public.pr_is_service()     SET search_path = public;
ALTER FUNCTION public.pr_set_due()        SET search_path = public;

-- 2) حارس proc_settings (كان مكشوفاً — أي مستخدم مسجَّل كان يستطيع تغيير عتبة الاعتماد/إعداد
--    الذكاء/قوالب البريد مباشرةً عبر PostgREST). السماح لـ: الخادم، أو صلاحيات إدارية، أو
--    مُراجِع التسجيلات (يحرّر قوالب البريد). الأدمن يمرّ دائماً (pr_has_perm يعيد true لدور admin).
CREATE OR REPLACE FUNCTION public.proc_settings_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF pr_is_service()
     OR pr_has_perm('can_manage_users')
     OR pr_has_perm('can_manage_company')
     OR pr_has_perm('can_review_registrations')
     OR pr_has_perm('can_manage_ai_settings')
  THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل الإعدادات يتطلّب صلاحية إدارية';
END $fn$;
DROP TRIGGER IF EXISTS trg_proc_settings_guard ON public.proc_settings;
CREATE TRIGGER trg_proc_settings_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.proc_settings
  FOR EACH ROW EXECUTE FUNCTION public.proc_settings_guard();

-- 3) حارس proc_departments (كان مكشوفاً — الأقسام تؤثّر على التوجيه/الاعتماد). يعيد استخدام
--    proc_config_guard (يتطلّب can_manage_users/can_manage_company؛ الأدمن يمرّ دائماً).
DROP TRIGGER IF EXISTS trg_proc_depts_guard ON public.proc_departments;
CREATE TRIGGER trg_proc_depts_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.proc_departments
  FOR EACH ROW EXECUTE FUNCTION public.proc_config_guard();

-- 4) تطبيع بيانات: proc_suppliers.commercial_reg = '—' (شرطة placeholder) → NULL
--    (كان يُفسد كشف التكرار بالسجل التجاري). 17 صفّاً.
UPDATE public.proc_suppliers SET commercial_reg = NULL WHERE commercial_reg = '—';

-- التحقّق (مُنفَّذ حيّاً بالانتحال، rolled-back):
--   admin=ALLOWED · mahmoud(can_review_registrations)=ALLOWED · bakar(بلا صلاحية)=BLOCKED ✓

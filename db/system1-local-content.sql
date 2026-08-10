-- ════════════════════════════════════════════════════════════════════════════
--  النظام 1 — بوابة تسجيل الموردين: شهادة المحتوى المحلي (اختيارية)
--  المشروع: Supabase القديم  yofcaxvstjcrmbgciwym  (جدول proc_supplier_registrations)
--
--  الغرض: إضافة ثلاثة أعمدة اختيارية لتخزين بيانات شهادة المحتوى المحلي التي يُدخلها
--  المورّد في الخطوة الثانية من register.html. المستند نفسه (ملف الشهادة) لا يحتاج
--  عموداً جديداً — يُخزَّن مساره ضمن doc_paths JSONB بالمفتاح "local_content".
--
--  الأمان: إضافة أعمدة فقط (idempotent). لا حذف، لا تعديل بيانات، لا مساس بـ RLS.
--  الواجهة مُصمَّمة لتعمل حتى قبل تشغيل هذه الهجرة (تُسقِط الحقول تلقائياً عند غيابها)،
--  لكن بدونها لا تُحفظ بيانات الشهادة. شغّلها مرّة واحدة على المشروع القديم.
--
--  ⚠️ هذا النظام 1 (منفصل تماماً عن البوابة/النظام 3). لا علاقة له بـ portal_*.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE proc_supplier_registrations
  ADD COLUMN IF NOT EXISTS local_content_has        boolean,        -- نعم/لا: هل لديه شهادة سارية
  ADD COLUMN IF NOT EXISTS local_content_cert_no    text,           -- رقم الشهادة (عند «نعم» فقط)
  ADD COLUMN IF NOT EXISTS local_content_percentage numeric(6,2);   -- النسبة % (0–100، عند «نعم» فقط)

COMMENT ON COLUMN proc_supplier_registrations.local_content_has        IS 'هل لدى المورّد شهادة محتوى محلي سارية (اختياري).';
COMMENT ON COLUMN proc_supplier_registrations.local_content_cert_no    IS 'رقم شهادة المحتوى المحلي — يُملأ فقط عند local_content_has = true.';
COMMENT ON COLUMN proc_supplier_registrations.local_content_percentage IS 'نسبة المحتوى المحلي % (0–100) — تُملأ فقط عند local_content_has = true. مستند الشهادة في doc_paths->>''local_content''.';

-- ── ملاحظة تشغيلية بشأن الاستئناف/إعادة التقديم (resume) ──────────────────────
-- إن كانت لديك دالة RPC باسم resubmit_registration تُحدِّث الصفّ عبر تعيين أعمدة
-- صريحة (بدل UPDATE ... = p_data كاملاً)، فأضِف إليها الأعمدة الثلاثة أعلاه كي
-- تُحفظ بيانات الشهادة أيضاً عند تعديل مورّد لطلبه. المسار الأساسي (تسجيل جديد
-- عبر INSERT) يعمل فور تشغيل هذه الهجرة بلا تغيير آخر.

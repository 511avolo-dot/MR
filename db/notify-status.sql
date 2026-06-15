-- ════════════════════════════════════════════════════════════════════════
--  تتبّع حالة إشعار البريد لكل طلب تسجيل
--  يضيف عموداً يسجّل آخر إشعار بريد أُرسل للمورد (الحدث/النجاح/الوقت/المستقبِل)
--  ليظهر للمراجِع داخل تفاصيل الطلب دون مغادرة النظام.
--
--  يُنفَّذ مرة واحدة في: Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

ALTER TABLE proc_supplier_registrations
  ADD COLUMN IF NOT EXISTS last_notify jsonb;

-- شكل القيمة المخزّنة (يكتبها التطبيق بعد كل قرار):
-- { "event":"approved", "sent":true, "to":"info@supplier.com",
--   "at":"2026-06-13T02:00:00Z", "reason":null }

-- مقاييس كفاءة تعبئة الطلب (مؤشرات أداء التسجيل) — يكتبها التطبيق عند الإرسال:
-- { "duration_min":6.4, "clicks":92, "fields_filled":28, "fields_auto":17,
--   "fields_manual":11, "auto_fill_rate":61, "docs_uploaded":4, "ai_used":true, ... }
ALTER TABLE proc_supplier_registrations
  ADD COLUMN IF NOT EXISTS metrics jsonb;

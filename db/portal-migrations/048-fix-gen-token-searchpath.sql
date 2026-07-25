-- ═══════════════════════════════════════════════════════════════════════════
--  048 — إصلاح عطب إنتاجي صامت: portal_gen_token() كانت ترمي خطأً دائماً
--  ─────────────────────────────────────────────────────────────────────────
--  اكتُشف أثناء بناء بوابة المورّد (047): استدعاء portal_gen_token فشل بـ
--    ERROR 42883: function gen_random_bytes(integer) does not exist
--
--  الجذر: امتداد pgcrypto مثبَّت في مخطّط "extensions" (النمط القياسي في
--  Supabase)، بينما الدالة مثبَّتة على search_path=public وحده — فلا تُحَلّ
--  gen_random_bytes. وتثبيت search_path كان إجراءً أمنياً سليماً (هجرة 030)
--  لكنه أغفل أنّ الدالة تعتمد على امتداد خارج public.
--
--  الأثر المؤكَّد بالبيانات: portal_email_tokens = **0 صفّ منذ إنشاء النظام**،
--  أي أنّ portal_create_token لم تنجح ولا مرّة ⇒ **الاعتماد بضغطة واحدة من
--  البريد لم يعمل إطلاقاً**. عطب صامت تماماً: لا رسالة خطأ تصل المستخدم،
--  ولا شيء في الواجهة يشير إليه.
--
--  الإصلاح: توسيع search_path ليشمل extensions (النمط الموصى به من Supabase)
--  دون التفريط في تثبيته (لا يزال مقيّداً، لا مفتوحاً).
--  ✅ مُطبَّق حيّاً ومُتحقَّق: portal_gen_token() تعيد 43 محرفاً بصيغة صحيحة.
-- ═══════════════════════════════════════════════════════════════════════════
ALTER FUNCTION public.portal_gen_token()  SET search_path = public, extensions;
ALTER FUNCTION public.portal_create_token(text,text,integer,text,numeric) SET search_path = public, extensions;
ALTER FUNCTION public.portal_supplier_invite(text,text,text,int) SET search_path = public, extensions;

-- تحقّق: SELECT length(portal_gen_token()); ⇒ 43

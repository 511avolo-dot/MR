# سجل جلسة العمل — بوابة الطلبات والموافقات (نظام 3)

> ملخّص دائم لجلسة مكثّفة: إصلاح الدخول → تدقيق أمني عميق → إصلاح تسليم البريد.
> الفرع: `claude/modest-goldberg-2p0gjn` · الإنتاج: `main` · Supabase: `mwbjoysuybgbrvfrprex`.

---

## 1) إصلاح الدخول («تعذّر تحميل الحساب») — ✅ مكتمل
**الجذر الثلاثي:** (أ) سياسة RLS مُنطاقة على `portal_users` كانت تُخفي صف الأدمن → أُعيدت إلى
`auth_all USING(true)`؛ (ب) **مُغلِّف `loadAll`** (السطر ~3384) كان ينفّذ `await _pa_loadAll_c()` **دون
إرجاع نتيجته** فترجع undefined ويفشل الدخول دائماً → أُصلح بـ`var _ok=...; return _ok;`؛ (ج) فرع meRow
كان يمسح `__paReason` بعد signOut → أُعيد الترتيب. **الدخول يعمل الآن.**

## 2) اختبار تشغيلي شامل — ✅ 22+ سيناريو صفر إخفاقات
دورتان كاملتان حتى الإقفال · كل شرائح DoA (≤25K مباشر · لجنة · مالية · مدير عام · مناقصة) ·
رفض/إرجاع/إرجاع مرن/إعادة تقديم/تعليق/استلام جزئي/تجزئة · تعيين اللجنة · الموردون · سياسة الدعوات.
(سكربتات الاختبار في scratchpad: `portal_e2e.sql`, `portal_scenarios.sql`, `portal_e2e_neg.sql`.)

## 3) تدقيق أمني عدائي عميق (8 وكلاء + تحقّق تنفيذي) — ✅ كل الثغرات أُغلقت ومؤكَّدة على الإنتاج
**هجرة 019 (تصليب حرِج)** — كل استغلال أُعيد تشغيله بعد الإصلاح → يُرفض:
- **الصرف:** سقف المبلغ (=التعميد+الضريبة، كان يُقبل 900K لتعميد 20K) · صرف واحد فقط (كان 3 صفوف) ·
  إعادة فحص حالة الطلب (كان الصرف يُلغي إلغاء الطلب).
- **DEFINER مكشوفة لـPUBLIC:** سحب `portal_create_token`/`portal_pr_transition_email` (تزوير اعتماد بلا
  حساب) و`portal_audit_write` (حقن تدقيق) → service_role.
- **الحُرّاس:** `portal_users_guard`/`portal_config_guard` رفض افتراضي (كانا يمرّران can_manage_users/company
  → ترقية ذاتية لأدمن + تخريب DoA بـPATCH مباشر) + حظر تصعيد في save_job/apply_job.
- **حوكمة:** فرض عدد العروض عند التعميد · رفض كمية استلام سالبة.
- **RLS:** بوابة مالية على `portal_payments`/`portal_suppliers` (كشف آيبان لأدوار غير مالية).
**هجرة 020:** كشف تفتيت شرائح DoA (علم تحذيري: تفتيت 480K→2×240K للتهرّب من اعتماد المدير العام).
**إصلاحات كود:** `portal-action.js` origin من PUBLIC_ORIGIN · حُرّاس الأدمن `active !== true`.
**التحقّق على الإنتاج:** استعلام `has_function_privilege`/`pg_get_functiondef`/`pg_policies` = **9/9 true**.
الملفات: `db/portal-migrations/019-security-hardening.sql` + `020-split-tier-aware.sql` + مجمّع
`RUN-ALL-005-to-020.sql` (مُطبَّقة كلها في Supabase). مدموجة في `portal-standalone.sql`.

## 4) تسليم البريد/الدعوات — ✅ يعمل (شُخِّص عبر Resend الحيّ)
- Resend: النطاق `suppliers.aldeyabi.com` **verified** (SPF/DKIM سليمة) · كل الرسائل **delivered**.
- بريد الشركة **Microsoft 365 / Outlook** — يستقبل بنجاح (اختباران وصلا للوارد: بلا رابط + مع رابط).
- **الدعوات السابقة «لم تصل» سببها:** `PUBLIC_ORIGIN` غُيّر إلى `https://portal.aldeyabi.com` **قبل تفعيل
  النطاق** → رابط التفعيل يعطي خطأ شهادة SSL (untrusted certificate). البريد نفسه يصل.

---

## ⚠️ المعلّق الوحيد — تصحيح سجل DNS (دقيقة واحدة)
في لوحة DNS الخاصة بـ`aldeyabi.com` يوجد سجل CNAME مضاف بخطأ إملائي:
- **الحالي (خطأ):** RDATA = `aldeyabi-procurement.**page**.dev` ← بلا s
- **الصحيح:** `aldeyabi-procurement.**pages**.dev` ← «pag**e**s» بحرف s (مطابق لسجل `suppliers` العامل)

**الخطوات:** عدّل RDATA → `aldeyabi-procurement.pages.dev` → احفظ → Cloudflare → aldeyabi-procurement →
Custom domains → portal.aldeyabi.com → «Check DNS records» → انتظر **Active + SSL** → أرسل دعوة جديدة (ستفتح).

**بديل مؤقّت (إن أردت البوابة تعمل قبل إصلاح DNS):** أرجِع `PUBLIC_ORIGIN` إلى
`https://aldeyabi-procurement.pages.dev` في Cloudflare → الدعوات تعمل فوراً؛ وبعد تفعيل النطاق غيّرها إليه.

---

## حالة النشر
- الكود كامل على `main` ومنشور على Cloudflare (آخر كوميت أمني `266ae00`/`ce51fe6`).
- قاعدة البيانات: الهجرات حتى **020** مُطبَّقة ومؤكَّدة حيّاً على الإنتاج.
- **جاهز للاستخدام** بعد تصحيح حرف `page`→`pages` في DNS.

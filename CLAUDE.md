# ذاكرة المشروع — مجموعة الذيابي (Al-Deyabi Group)

> هذا الملف هو المرجع الدائم. **اقرأه أولاً في كل جلسة.** يمنع الخلط بين الأنظمة الثلاثة
> المنفصلة ويحفظ حالة العمل والقرارات. حدّثه كلما تغيّر شيء جوهري.

---

## ⚠️ القاعدة الذهبية: ثلاثة أنظمة منفصلة — لا تخلط بينها أبداً

| # | النظام | الواجهة | قاعدة البيانات | مشروع Supabase |
|---|--------|---------|----------------|----------------|
| 1 | **بوابة الموردين** (تسجيل الموردين) | `register.html` | `proc_supplier_registrations` (+ proc_*) | القديم `yofcaxvstjcrmbgciwym` |
| 2 | **نظام المشتريات** (النظام الرئيسي) | `index.html` (+ `requests.html` + `rfq.html`) | جداول `proc_*` / `pr_*` | القديم `yofcaxvstjcrmbgciwym` |
| 3 | **بوابة الطلبات والموافقات** (الجديدة، معزولة) | `purchase-portal.html` | جداول `portal_*` فقط | **الجديد `mwbjoysuybgbrvfrprex`** |

- النظامان 1 و2 يتشاركان **نفس مشروع Supabase القديم** وجداول `proc_*`/`pr_*`.
- النظام 3 **معزول فيزيائياً بالكامل**: مشروع Supabase مستقل، جداول `portal_*` فقط، لا يمسّ أي `proc_*`.
- **`requests.html` (نظام 2) ≠ `purchase-portal.html` (نظام 3).** كلاهما «طلبات شراء» لكنهما نظامان مختلفان تماماً. لا تخلط بينهما.

---

## النظام 3 — بوابة الطلبات والموافقات (عملنا الحالي، معزول تماماً)

**المبدأ الحاكم (توجيه المالك الصريح):** معزولة 100% عن `index.html` وكل `proc_*`.
لا ربط، لا اختلاط، لا تعديل على أي كائن قائم. «اشتغل على البوابة فقط.»

### الملفات (كلها جديدة — لم يُعدَّل أي ملف قائم)
- `db/portal-standalone.sql` — المخطّط الكامل: 17 جدول `portal_*`، دوال RPC ذرّية
  (SECURITY DEFINER)، محارس **رفض افتراضي (deny-by-default)**، RLS، تدقيق append-only،
  رموز بريد لمرة واحدة، بذور DoA، وكتلة تراجع (rollback) في نهايته.
- `purchase-portal.html` — الواجهة المستقلة (تصميم newsystem.html) موصولة بـ Supabase حقيقي.
- `functions/api/_portal-shared.js` — وحدة بريد مشتركة للبوابة (قوالب + رموز اعتماد).
- `functions/api/portal-notify.js` — إشعارات كل حدث (POST بأنواع kind: request/award/payment/receipt).
- `functions/api/portal-action.js` — الاعتماد بضغطة واحدة من البريد (portal_pr_transition_email).
- `functions/api/portal-users.js` — إدارة مستخدمي البوابة (admin فقط).

### متغيّرات البيئة (Cloudflare Pages) الخاصة بالبوابة
البوابة تقرأ **متغيّرات مستقلة** كي لا تلمس المشروع القديم أبداً:
- `PORTAL_SUPABASE_URL` = `https://mwbjoysuybgbrvfrprex.supabase.co`
- `PORTAL_SUPABASE_SERVICE_ROLE_KEY` = *(سرّي — المالك يضعه في Cloudflare، لا يُكتب هنا أبداً)*
- `RESEND_API_KEY` = *(مشترك للبريد — موجود مسبقاً)*
- الواجهة تستخدم anon key العام (مضمّن في `purchase-portal.html`، آمن).

### دورة الحياة (آلة الحالة)
`draft → in_review` (الدورة 1: سلسلة موافقات الحاجة) `→ pricing` (إدخال عروض)
`→ award_review` (الدورة 2: اعتماد التعميد حسب DoA بالقيمة) `→ awarded/payment`
`→ payment_pending` (طلب صرف) `→ receipt_pending` (بعد الصرف) `→ closed` (اكتمال الاستلام).

### قواعد الأمان المثبَّتة (لا تُضعِفها)
- كل انتقال حالة عبر RPC ذرّية ترفع علم `app.portal_transition` ثم تُصفّره.
- المحارس **رفض افتراضي**: أي كتابة مباشرة من العميل مرفوضة إلا عبر RPC/خادم/أدمن.
- جداول الأدلّة المقفلة: `portal_offers`, `portal_request_items`, `portal_receipts` (حارس `portal_locked_guard`).
- فصل المهام (SoD): الطالب ≠ المعتمِد؛ من يرسي التعميد ≠ من يعتمده؛ طالب الصرف ≠ معتمِده ≠ منفّذه؛ ومعتمِد مرحلة سابقة لا يعتمد لاحقة.
- `portal_email_tokens` بلا سياسة RLS (خادم فقط). `portal_audit` غير قابل للتعديل حتى بـ service_role.
- `portal_notifications` مقيّدة بالمستلِم. الهوية تُشتقّ من `session_user`/JWT لا `current_user` (خطأ SECURITY DEFINER معروف).

### الاختبار
بيئة PostgreSQL محلية تحاكي Supabase (`authenticator` + `SET ROLE` + `service_role BYPASSRLS`).
سكربتات الاختبار في مجلد scratchpad: `00_supabase_stub.sql`, `01_seed_and_test.sql` (E2E: 10 اختبار سلبي + دورة كاملة),
`02b.sql` (محارس), `03_rls_positive_path.sql`, `04_create_request.sql`, `06_reaward.sql`, `07_locked.sql`.
**آخر تشغيل: كل الاختبارات ناجحة.**

---

## حالة النشر الحالية (النظام 3) — حدّثها مع كل تقدّم

- [x] بناء المخطّط + الواجهة + دوال البريد + إدارة المستخدمين.
- [x] مراجعة أمنية عدائية + إصلاح كل الثغرات (SoD، deny-by-default، جداول مقفلة).
- [x] فصل الكود إلى مشروع Supabase مستقل (متغيّرات `PORTAL_SUPABASE_*`).
- [x] إنشاء مشروع Supabase الجديد `mwbjoysuybgbrvfrprex` + تشغيل `portal-standalone.sql` (نجح).
- [x] ربط الواجهة بعنوان + anon key الجديد (كوميت `11190bd`).
- [ ] **معلّق على المالك:** إضافة `PORTAL_SUPABASE_URL` + `PORTAL_SUPABASE_SERVICE_ROLE_KEY` في Cloudflare.
- [ ] **معلّق على المالك:** إنشاء حساب الأدمن الأول (Auth user + صف `portal_users` role='admin' بنفس البريد).
- [ ] **معلّق:** الدفع إلى `main` للنشر (بعد تأكيد المتغيّرات).
- [ ] **قرار معلّق:** الدومين — مقترح مسار نظيف `/portal` + نطاق فرعي `portal.aldeyabi.com`. لم يُنفّذ بعد.

### إنشاء أول أدمن للبوابة (الطريقة)
1. Supabase (المشروع الجديد) → Authentication → Users → Add user (بريد + كلمة مرور + Auto Confirm).
2. SQL: `INSERT INTO portal_users (username,email,display_name,role,active) VALUES ('admin','<نفس البريد>','المدير العام','admin',true);`
   (البريد يجب أن يطابق حساب Auth تماماً — الربط عبر البريد.)

---

## سير العمل (Git) — التزم به
- التطوير على الفرع: **`claude/modest-goldberg-2p0gjn`**.
- commit + `git push -u origin <branch>`.
- النشر إلى `main` **فقط بعد إذن المالك**: `git checkout -B main origin/main` → `git cherry-pick <sha>` →
  تأكّد `git diff --stat <branch>` فارغ → push main → ارجع للفرع.
- الإصدار المباشر (النظام 2/1): `https://aldeyabi-procurement.pages.dev` (Cloudflare Pages).

## البريد (Resend)
- النطاق الموثّق: `suppliers.aldeyabi.com`. المُرسِل: `noreply@suppliers.aldeyabi.com`. الردّ: `supply@aldeyabi.com`.
- دوال البريد للنظام 2: `notify.js` + `_pr-shared.js` + `pr-action.js`. **لا تلمسها من أجل البوابة** — البوابة لها `portal-*` منفصلة.

---

## ملاحظات مهمة لتجنّب الأخطاء
- عند العمل على البوابة (نظام 3): استعمل `portal_*` و`PORTAL_SUPABASE_*` و`purchase-portal.html`/`functions/api/portal-*` فقط.
- عند العمل على النظام الرئيسي (نظام 2): `proc_*`/`pr_*` و`SUPABASE_*` و`index.html`/`requests.html`/`admin-users.js`/`notify.js`.
- لا تُعدّل `index.html` أو أي `proc_*` من أجل البوابة إطلاقاً (توجيه صريح ومتكرّر من المالك).
- عنوان الموديل المُهيَّأ: `claude-opus-4-8` — لا تُدرجه في أي كوميت/كود.

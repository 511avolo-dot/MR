# دليل ترحيل المصادقة إلى Supabase Auth

هذا الدليل يُكمل تحصين RLS. **نفّذه على مشروع Supabase تجريبي أولًا**، ثم
كرّره على الإنتاج بعد نجاح الاختبار.

> الخلفية: تسجيل الدخول الآن يتم عبر **Supabase Auth** (رمز JWT)، مما يسمح
> لسياسات RLS بالوثوق بالمستخدم على مستوى الخادم. المستخدم يكتب اسمه فقط
> (مثل `Abdullah`) ويحوّله التطبيق داخليًا إلى بريد اصطلاحي
> `abdullah@aldeyabi.local` — فلا تتغيّر تجربة الدخول.

---

## الخطوة 1 — تفعيل مزوّد البريد

Supabase Dashboard → **Authentication → Providers → Email**:
- فعّل **Email**.
- **Authentication → Settings**: أوقِف **"Confirm email"** (المستخدمون داخليون
  ببريد اصطلاحي غير حقيقي، فلا يمكنهم تأكيد البريد).

## الخطوة 2 — إنشاء حسابات الدخول

**Authentication → Users → Add user** لكل مستخدم (Email + Password + علّم
"Auto Confirm User"):

| الاسم في الشاشة | البريد المُدخَل | الدور |
|-----------------|------------------|-------|
| Abdullah | `abdullah@aldeyabi.local` | admin |
| Mostafa  | `mostafa@aldeyabi.local`  | user  |
| Mahmoud  | `mahmoud@aldeyabi.local`  | user  |

> اختر كلمات مرور قوية (لم تعُد هاشات SHA-256 القديمة مستخدمة).

## الخطوة 3 — بذر ملفات التعريف (الأدوار/الصلاحيات)

في **SQL Editor** — يربط كل اسم مستخدم بدوره وصلاحياته. عمود `password_hash`
لم يعد يُستخدم للدخول (مُدار في Auth) لكنه إلزامي في المخطط، فنضع قيمة نائبة:

```sql
INSERT INTO proc_users (username, display_name, password_hash, role, permissions, active, created_by)
VALUES
  ('Abdullah','عبدالله','managed_by_supabase_auth','admin',
    '{"can_delete":true,"can_export":true,"can_import":true,"can_manage_suppliers":true,"can_manage_cloud":true,"can_manage_users":true}'::jsonb,
    true,'migration'),
  ('Mostafa','مصطفى خليل','managed_by_supabase_auth','user',
    '{"can_delete":false,"can_export":false,"can_import":false,"can_manage_suppliers":true,"can_manage_cloud":false,"can_manage_users":false}'::jsonb,
    true,'migration'),
  ('Mahmoud','محمود العمودي','managed_by_supabase_auth','user',
    '{"can_delete":false,"can_export":false,"can_import":false,"can_manage_suppliers":true,"can_manage_cloud":false,"can_manage_users":false}'::jsonb,
    true,'migration')
ON CONFLICT (username) DO UPDATE
  SET display_name = EXCLUDED.display_name,
      role        = EXCLUDED.role,
      permissions = EXCLUDED.permissions,
      active      = EXCLUDED.active;
```

> مهم: يجب أن يتطابق `username` هنا مع الجزء الأول من البريد (حسّاس بلا حالة:
> `Abdullah` ↔ `abdullah@...`).

## الخطوة 4 — اختبار الدخول (قبل إغلاق RLS)

افتح `index.html` المتصل بالمشروع التجريبي، وسجّل الدخول باسم `Abdullah`
وكلمة المرور الجديدة. يجب أن:
- يفتح النظام ويظهر الدور «مدير».
- تعمل القراءة/الكتابة (RLS ما زالت مفتوحة في هذه المرحلة).

## الخطوة 5 — تطبيق إغلاق RLS

شغّل `db/hardened-rls.sql` (المرحلة 1) على المشروع التجريبي.

## الخطوة 6 — التحقق من الإغلاق

- **مصادَق عليه:** أعد تسجيل الدخول في `index.html` → يجب أن يعمل كل شيء.
- **مجهول (anon):** جرّب استعلامًا بمفتاح anon فقط (دون دخول) → يجب أن
  **يُرفَض** (لا صفوف / خطأ صلاحية). هذا هو الدليل على نجاح التحصين.
- سجّل الخروج ثم أعد التحميل → يجب أن تُطلب إعادة الدخول (الجلسة المنتهية تُطرد).

---

## ملاحظات وقيود معروفة

1. **إنشاء مستخدم جديد من واجهة الإدارة:** يُنشئ حساب Auth تلقائيًا (عبر عميل
   مؤقت) + صف ملف تعريف. يتطلب أن يكون "Confirm email" متوقفًا.
2. **تغيير كلمة مرور مستخدم آخر:** يتم من لوحة Supabase (Authentication →
   Users)؛ لا يمكن من المتصفح لأسباب أمنية (يحتاج service_role). أما تغيير
   كلمة المرور **الذاتية** فيعمل من التطبيق مباشرة.
3. **ميزة «استئناف الطلب» في صفحة التسجيل العامة** تقرأ سجل المورد بمفتاح anon
   عبر (id + token). بعد المرحلة 1 ستُمنع هذه القراءة. الحل: دالة RPC آمنة
   تتحقق من الـ token وتعيد السجل، بدل فتح SELECT للجميع. **عالِج هذا قبل
   تطبيق المرحلة 1 على الإنتاج** إن كنت تعتمد على ميزة الاستئناف.
4. **حذف مستخدم** من واجهة الإدارة يحذف ملف التعريف فقط؛ احذف حساب Auth
   المقابل من لوحة Supabase لإكمال الإزالة.

## (اختياري لاحقًا) دالة إدارة مستخدمين كاملة

لإبقاء كل إدارة المستخدمين (إنشاء/تعطيل/إعادة تعيين كلمات مرور الآخرين) داخل
الواجهة بأمان، يمكن إضافة Cloudflare Pages Function تستخدم `service_role`
(سرّ خادم) وتتحقق من أن المستدعي مدير عبر الـ JWT. أخبِرنا إن رغبت بذلك.

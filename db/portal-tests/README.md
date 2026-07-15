# حزمة اختبار البوابة (النظام 3)

اختبارات انحدار دائمة **داخل المستودع** (بدل بيئة scratchpad المؤقتة) — تُشغَّل آلياً
على كل PR/دفع يمسّ البوابة عبر `.github/workflows/portal-tests.yml`.

## المحتوى
| الملف | الغرض |
|-------|-------|
| `00_roles.sql` | أدوار Supabase المحاكاة (anon/authenticated/service_role/authenticator) على مستوى العنقود. |
| `10_outbox.sql` | صندوق الصادر المعامَلاتي (029): التقاط · idempotency · claim · منع سحب مزدوج · تراجع أُسّي · dead-letter · sent · purge (8 تأكيدات). |
| `11_security.sql` | التصليب الأمني (030) + نموذج الصلاحيات: anon محجوب · authenticated سليم · search_path · عدم كسر الدورة (7 تأكيدات). |
| `run.sh` | يحمّل `portal-standalone.sql` كاملاً في قاعدة نظيفة ثم يشغّل التأكيدات. أي فشل ⇒ خروج غير صفري. |

كل الاختبارات صيغة **تأكيدات** (`RAISE EXCEPTION` عند الخطأ) مع `ON_ERROR_STOP=1`،
فتُفشِل البناء تلقائياً.

## التشغيل محلياً
```bash
# على عنقود PostgreSQL قائم (مثال: socket /tmp/pt منفذ 5455)
PGHOST=localhost PGPORT=5455 PGUSER=postgres bash db/portal-tests/run.sh
```

## التوسّع
عند إضافة هجرة جديدة بمنطق حرِج: أضِف ملف تأكيدات `NN_*.sql` هنا وأدرجه في `run.sh`،
واحرص أن يُدمج تغيير المخطّط في `portal-standalone.sql` (التنصيب النظيف الذي تحمّله الحزمة).

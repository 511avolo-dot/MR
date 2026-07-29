#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  حزمة اختبار البوابة (النظام 3) — تُحمّل المخطّط الكامل في PostgreSQL نظيف ثم
#  تشغّل تأكيدات الصادر المعامَلاتي والتصليب الأمني. أي فشل ⇒ خروج غير صفري.
#
#  الاستخدام:
#    • CI (حاوية postgres جاهزة):   PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres bash db/portal-tests/run.sh
#    • محلياً على عنقود قائم:       PGHOST=/tmp/pt PGPORT=5455 PGUSER=postgres bash db/portal-tests/run.sh
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
DB="${PGDATABASE:-portal_ci}"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q)

echo "▶ قاعدة اختبار نظيفة: $DB على $PGHOST:$PGPORT"
"${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"

echo "▶ أدوار Supabase المحاكاة"
"${PSQL[@]}" -d postgres -f "$HERE/00_roles.sql"

echo "▶ تحميل المخطّط الكامل (portal-standalone.sql + الهجرات المدمجة 029/030)"
if ! "${PSQL[@]}" -d "$DB" -f "$ROOT/db/portal-standalone.sql" > /tmp/portal_schema_load.log 2>&1; then
  echo "❌ فشل تحميل المخطّط:"; grep -iE "ERROR|FATAL" /tmp/portal_schema_load.log | head -30; exit 1
fi
grep -iE "030:" /tmp/portal_schema_load.log || true

echo "▶ اختبارات الصادر المعامَلاتي (029)"
"${PSQL[@]}" -d "$DB" -f "$HERE/10_outbox.sql"

echo "▶ اختبارات التصليب الأمني (030)"
"${PSQL[@]}" -d "$DB" -f "$HERE/11_security.sql"

echo "▶ اختبارات ضبط الميزانية (031)"
"${PSQL[@]}" -d "$DB" -f "$HERE/12_budget.sql"

echo "▶ اختبارات ضبط آيبان المورد (032)"
"${PSQL[@]}" -d "$DB" -f "$HERE/13_supplier_iban.sql"

echo "▶ اختبارات المطابقة الثلاثية (033)"
"${PSQL[@]}" -d "$DB" -f "$HERE/14_three_way.sql"

echo "▶ اختبارات المرتجعات + إشعار مدين (034)"
"${PSQL[@]}" -d "$DB" -f "$HERE/15_returns.sql"

echo "▶ اختبارات تعدّد العملات (035)"
"${PSQL[@]}" -d "$DB" -f "$HERE/16_currency.sql"

echo "▶ اختبارات العقود الإطارية (037)"
"${PSQL[@]}" -d "$DB" -f "$HERE/17_contracts.sql"

echo "▶ اختبارات رصد غير-الأقل في الترسية المجزّأة (038)"
"${PSQL[@]}" -d "$DB" -f "$HERE/18_split_justification.sql"

echo "▶ اختبارات تكامل المرتجع + إلزام مورد الفاتورة (039)"
"${PSQL[@]}" -d "$DB" -f "$HERE/19_return_invoice_integrity.sql"

echo "▶ سيناريوهات دورة الحياة عبر RPC فعلي بهوية مُنتحَلة (تأجيل/تفويض/تجزئة/استلام جزئي/لجنة/إرجاع)"
"${PSQL[@]}" -d "$DB" -f "$HERE/20_scenarios_lifecycle.sql"

echo "▶ سيناريوهات متقدّمة عبر RPC فعلي (سلسلة PO عالية/دفعات على مراحل/مرتجع+إشعار مدين)"
"${PSQL[@]}" -d "$DB" -f "$HERE/21_scenarios_advanced.sql"

echo "▶ تغطية الأدوار: كل صلاحية حرِجة تمنحها وظيفة نشطة + سدّ الوظائف الفارغة (042)"
"${PSQL[@]}" -d "$DB" -f "$HERE/22_jobs_coverage.sql"

echo "▶ الإعادة الذكية للتصحيح: تعديل الطلب المُعاد + الحُرّاس (043)"
"${PSQL[@]}" -d "$DB" -f "$HERE/23_rework_edit.sql"

echo "▶ إعادة فتح التعميد من طور الصرف: تصحيح العروض/الأسعار + الحارس (044)"
"${PSQL[@]}" -d "$DB" -f "$HERE/24_reopen_award.sql"

if command -v node >/dev/null 2>&1; then
  echo "▶ تأكيدات حارس الملفات المرفوعة + نقطة /api/reg-doc (JS)"
  node "$HERE/file-guard.test.mjs" | tail -3
fi

echo "▶ إلزام مستند عرض المورد + رفع المورّد لعرضه (049)"
"${PSQL[@]}" -d "$DB" -f "$HERE/25_quote_doc.sql"

echo "▶ محرّك الصرف الموحّد الواعي بالدورة: صرف مستقلّ + فصل مهام + إرجاع + قابلية ضبط (050)"
"${PSQL[@]}" -d "$DB" -f "$HERE/26_disbursement_core.sql"

echo "▶ حوكمة مالية متقدّمة: idempotency (exactly-once) + إبطال saga (051)"
"${PSQL[@]}" -d "$DB" -f "$HERE/27_idempotency_void.sql"

echo "▶ ضبط ميزانية الصرف المستقلّ: المرتبط + المنع/التحذير (052)"
"${PSQL[@]}" -d "$DB" -f "$HERE/28_expense_budget.sql"

echo "▶ سجلّ المستفيدين + ضبط تغيير آيبان المستفيد + فرض السجلّ في الصرف (053)"
"${PSQL[@]}" -d "$DB" -f "$HERE/29_beneficiary_master.sql"

echo "▶ الاعتماد الجماعي الواعي بالدورة + فصل المهام لكل عنصر (054)"
"${PSQL[@]}" -d "$DB" -f "$HERE/30_bulk_approve.sql"

echo "▶ الصرف المتكرّر/المجدوَل: قوالب + مولّد خادميّ + حماية الفيضان (055)"
"${PSQL[@]}" -d "$DB" -f "$HERE/31_recurring_expenses.sql"

echo "▶ الاعتماد بالبريد لدورة الصرف: رمز واعٍ بالدورة + انتقال بريديّ مُعمَّم (056)"
"${PSQL[@]}" -d "$DB" -f "$HERE/32_email_disbursement.sql"

echo "▶ تدقيق مقاوم للعبث (Hash-Chained WORM): سلسلة + تحقّق + كشف عبث (057)"
"${PSQL[@]}" -d "$DB" -f "$HERE/33_audit_hashchain.sql"

echo "▶ تصليب دفاعي: سحب منح anon عن جداول PII/مالية (059)"
"${PSQL[@]}" -d "$DB" -f "$HERE/35_anon_hardening.sql"

echo "▶ إشعارات معامَلاتية للاعتماد: مُشغِّل يلتقط معتمِد المرحلة → الصادر (058)"
"${PSQL[@]}" -d "$DB" -f "$HERE/34_txn_notifications.sql"

echo "▶ إصلاحات Codex: ربط قسم الصرف بالمُنشئ (AUTHZ-01) + ميزانية الصرف المتكرّر (GOV-01) — 060"
"${PSQL[@]}" -d "$DB" -f "$HERE/36_authz_expense_recurring_budget.sql"

echo "▶ المستندات الداعمة للصرف المباشر: مسودّة→رفع→تقديم + عدم التغيير + الإصدارات (062)"
"${PSQL[@]}" -d "$DB" -f "$HERE/37_request_documents.sql"

echo ""
echo "✅ كل اختبارات البوابة نجحت (192 تأكيداً: 8 صادر + 8 أمان + 5 ميزانية + 5 آيبان + 7 مطابقة + 4 مرتجعات + 5 عملات + 5 عقود + 3 ترسية مجزّأة + 3 تكامل مرتجع/فاتورة + 23 سيناريو دورة حياة + 12 سيناريو متقدّم + 5 تغطية أدوار + 7 إعادة/تعديل + 5 إعادة فتح تعميد + 9 إلزام مستند العرض + 10 محرّك الصرف + 8 حوكمة متقدّمة + 4 ميزانية الصرف + 7 سجلّ مستفيدين + 4 اعتماد جماعي + 7 صرف متكرّر + 6 اعتماد بريد الصرف + 5 تدقيق مقاوم للعبث + 4 إشعارات معامَلاتية + 3 تصليب anon + 6 إصلاحات Codex [AUTHZ-01/GOV-01/قسم نشط] + 14 مستندات الصرف المباشر [062+round3]) + 18 تأكيد حارس ملفات + 7 تأكيدات نقطة رفع وثائق التسجيل."

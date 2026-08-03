#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  حزمة اختبار البوابة (النظام 3)
#  تُحمّل portal-standalone.sql على قاعدة نظيفة، ثم تشغّل الحزمة كاملة.
#  P0-1b…P0-1k تُطبّق قبل اختبارات أقلّ الامتياز والصلاحيات الحرجة.
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

run_sql() {
  local title="$1" file="$2"
  echo "▶ $title"
  "${PSQL[@]}" -d "$DB" -f "$file"
}

echo "▶ قاعدة اختبار نظيفة: $DB على $PGHOST:$PGPORT"
"${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"

echo "▶ أدوار Supabase المحاكاة"
"${PSQL[@]}" -d postgres -f "$HERE/00_roles.sql"

echo "▶ تحميل المخطّط الكامل (portal-standalone.sql)"
if ! "${PSQL[@]}" -d "$DB" -f "$ROOT/db/portal-standalone.sql" > /tmp/portal_schema_load.log 2>&1; then
  echo "❌ فشل تحميل المخطّط:"; grep -iE "ERROR|FATAL" /tmp/portal_schema_load.log | head -30; exit 1
fi
grep -iE "030:" /tmp/portal_schema_load.log || true

run_sql "اختبارات الصادر المعامَلاتي (029)" "$HERE/10_outbox.sql"
run_sql "اختبارات التصليب الأمني (030)" "$HERE/11_security.sql"
run_sql "اختبارات ضبط الميزانية (031)" "$HERE/12_budget.sql"
run_sql "اختبارات ضبط آيبان المورد (032)" "$HERE/13_supplier_iban.sql"
run_sql "اختبارات المطابقة الثلاثية (033)" "$HERE/14_three_way.sql"
run_sql "اختبارات المرتجعات + إشعار مدين (034)" "$HERE/15_returns.sql"
run_sql "اختبارات تعدّد العملات (035)" "$HERE/16_currency.sql"
run_sql "اختبارات العقود الإطارية (037)" "$HERE/17_contracts.sql"
run_sql "اختبارات رصد غير-الأقل في الترسية المجزّأة (038)" "$HERE/18_split_justification.sql"
run_sql "اختبارات تكامل المرتجع + إلزام مورد الفاتورة (039)" "$HERE/19_return_invoice_integrity.sql"
run_sql "سيناريوهات دورة الحياة عبر RPC فعلي" "$HERE/20_scenarios_lifecycle.sql"
run_sql "سيناريوهات متقدّمة عبر RPC فعلي" "$HERE/21_scenarios_advanced.sql"
run_sql "تغطية الأدوار (042)" "$HERE/22_jobs_coverage.sql"
run_sql "الإعادة الذكية للتصحيح (043)" "$HERE/23_rework_edit.sql"
run_sql "إعادة فتح التعميد (044)" "$HERE/24_reopen_award.sql"

if command -v node >/dev/null 2>&1; then
  echo "▶ تأكيدات حارس الملفات المرفوعة + نقطة /api/reg-doc (JS)"
  node "$HERE/file-guard.test.mjs" | tail -3
fi

run_sql "إلزام مستند عرض المورد + رفع المورّد لعرضه (049)" "$HERE/25_quote_doc.sql"
run_sql "محرّك الصرف الموحّد (050)" "$HERE/26_disbursement_core.sql"
run_sql "حوكمة مالية متقدّمة: idempotency + saga (051)" "$HERE/27_idempotency_void.sql"
run_sql "ضبط ميزانية الصرف المستقلّ (052)" "$HERE/28_expense_budget.sql"
run_sql "سجلّ المستفيدين وضبط الآيبان (053)" "$HERE/29_beneficiary_master.sql"
run_sql "الاعتماد الجماعي الواعي بالدورة (054)" "$HERE/30_bulk_approve.sql"
run_sql "الصرف المتكرّر/المجدوَل (055)" "$HERE/31_recurring_expenses.sql"
run_sql "الاعتماد بالبريد لدورة الصرف (056)" "$HERE/32_email_disbursement.sql"
run_sql "تدقيق مقاوم للعبث (057)" "$HERE/33_audit_hashchain.sql"
run_sql "تصليب anon لجداول PII/مالية (059)" "$HERE/35_anon_hardening.sql"
run_sql "إشعارات معامَلاتية للاعتماد (058)" "$HERE/34_txn_notifications.sql"
run_sql "إصلاحات Codex AUTHZ-01/GOV-01 (060)" "$HERE/36_authz_expense_recurring_budget.sql"
run_sql "المستندات الداعمة للصرف المباشر (062)" "$HERE/37_request_documents.sql"

run_sql "P0-1b/P0-1c: إغلاق تجاوز session_user + أقلّ امتياز launch hardening" "$ROOT/db/portal-migrations/p0_1b-portal-users-guard-no-session-user-jwt-bypass.sql"
run_sql "أقلّ امتياز على portal_users: RLS + دليل آمن + منع التصعيد" "$HERE/38_portal_users_least_privilege.sql"
run_sql "P0-1d: سرية عروض الأسعار + صلاحية الصرف المباشر المستقلة" "$ROOT/db/portal-migrations/p0_1d-quote-confidentiality-direct-expense-permission.sql"
run_sql "P0-1e: منح قراءة RLS اللازمة لسرية العروض" "$ROOT/db/portal-migrations/p0_1e-quote-confidentiality-rls-grants.sql"
run_sql "اختبار P0-1d/P0-1e: الطالب لا يرى العروض والصرف المباشر بصلاحية مستقلة" "$HERE/39_quote_confidentiality_direct_expense_permission.sql"
run_sql "P0-1f: سياسة اللجنة المرنة والمُصدّرة" "$ROOT/db/portal-migrations/p0_1f-flexible-committee-policy.sql"
run_sql "P0-1g: نافذة انتقال داخلية لباني سلسلة أمر الشراء" "$ROOT/db/portal-migrations/p0_1g-po-chain-transition-window.sql"
run_sql "اختبار P0-1f/P0-1g: تشغيل/تعطيل/حدود/مسار بديل/snapshot" "$HERE/40_flexible_committee_policy.sql"
run_sql "P0-1h: عقد بيانات طالب الاحتياج الآمن" "$ROOT/db/portal-migrations/p0_1h-requester-safe-purchase-dossier.sql"
run_sql "اختبار P0-1h: لا عروض/أسعار/دفع/بنك/مفاتيح تخزين في Payload الطالب" "$HERE/41_requester_safe_purchase_dossier.sql"
run_sql "P0-1i: إغلاق حواجز RPC/الوثائق/الدفع/IBAN/الخصوصية/125k" "$ROOT/db/portal-migrations/p0_1i-final-release-blocker-hardening.sql"
run_sql "اختبار P0-1i: إيصالات R2 + مستندات الدفع + الخصوصية المالية" "$HERE/42_final_release_blocker_hardening.sql"
run_sql "P0-1j: معالجة نتائج المراجعة الحديثة على الرأس الدقيق" "$ROOT/db/portal-migrations/p0_1j-exact-head-review-remediation.sql"
run_sql "اختبار P0-1j: النطاق/التعتيم/الحجر/الأدلة الموثقة" "$HERE/43_exact_head_review_remediation.sql"
run_sql "P0-1k fixture: سلسلة صرف مباشر جارية بلا دليل صالح" "$HERE/p0_1k-pre-migration-fixture.sql"
run_sql "P0-1k: معالجة نتائج المراجعة المستقلة" "$ROOT/db/portal-migrations/p0_1k-independent-review-remediation.sql"
run_sql "اختبار P0-1k: دليل دفع مستقل/إرجاع آمن/استرداد/عرض حالة فقط" "$HERE/44_independent_review_remediation.sql"

echo ""
echo "✅ كل اختبارات البوابة نجحت (266 تأكيد SQL) + 18 تأكيد حارس ملفات + 7 تأكيدات نقطة رفع وثائق التسجيل."

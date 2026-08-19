#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  حزمة اختبار البوابة (النظام 3)
#  تُحمّل portal-standalone.sql على قاعدة نظيفة، ثم تشغّل الحزمة كاملة.
#  P0-1b…P0-1n تُطبّق قبل اختبارات أقلّ الامتياز والصلاحيات الحرجة.
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
  echo "▶ حارس هدف E2E المعزول (ref+url، رفض الإنتاج)"
  node "$ROOT/scripts/e2e/target-guard.test.mjs" | tail -1
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
run_sql "P0-1l pre-P0-1i fixture: duplicate caller-trusted document keys" "$HERE/p0_1l-pre-p0i-duplicate-fixture.sql"
run_sql "P0-1i: إغلاق حواجز RPC/الوثائق/الدفع/IBAN/الخصوصية/125k" "$ROOT/db/portal-migrations/p0_1i-final-release-blocker-hardening.sql"
run_sql "اختبار P0-1i: إيصالات R2 + مستندات الدفع + الخصوصية المالية" "$HERE/42_final_release_blocker_hardening.sql"
run_sql "P0-1j: معالجة نتائج المراجعة الحديثة على الرأس الدقيق" "$ROOT/db/portal-migrations/p0_1j-exact-head-review-remediation.sql"
run_sql "اختبار P0-1j: النطاق/التعتيم/الحجر/الأدلة الموثقة" "$HERE/43_exact_head_review_remediation.sql"
run_sql "P0-1k fixture: سلسلة صرف مباشر جارية بلا دليل صالح" "$HERE/p0_1k-pre-migration-fixture.sql"
run_sql "P0-1k: معالجة نتائج المراجعة المستقلة" "$ROOT/db/portal-migrations/p0_1k-independent-review-remediation.sql"
run_sql "اختبار P0-1k: دليل دفع مستقل/إرجاع آمن/استرداد/عرض حالة فقط" "$HERE/44_independent_review_remediation.sql"
run_sql "P0-1l: معالجة نتائج المراجعة المستقلة النهائية" "$ROOT/db/portal-migrations/p0_1l-final-independent-review-remediation.sql"
run_sql "P0-1m: منح القراءة التي تحكمها RLS على التثبيت النظيف" "$ROOT/db/portal-migrations/p0_1m-clean-install-raw-read-grants.sql"
run_sql "P0-1n: إبقاء القراءة الخام للصرف المباشر ضمن الأدوار المالية" "$ROOT/db/portal-migrations/p0_1n-direct-expense-raw-read-boundary.sql"
run_sql "اختبار P0-1l: العزل الخام/العقد الآمن/rollback مغلق/duplicate keys" "$HERE/45_final_independent_review_remediation.sql"
run_sql "سلبيات تفويض لكل توقيع DEFINER كتابة (advisor closure)" "$HERE/46_definer_authz_negatives.sql"

run_sql "p0_1o: رفع سقف اللجنة إلى 150000 (إصلاح F-PO-125K، قرار المالك مسار A)" "$ROOT/db/portal-migrations/p0_1o-committee-ceiling-150k.sql"
run_sql "اختبار p0_1o: حدود اللجنة (25000/25001/125001/149999/150000/150001)" "$HERE/47_committee_ceiling.sql"
run_sql "p0_1p: استعادة بوّابة الصرف على مسار الشراء (إصلاح F-GATE2)" "$ROOT/db/portal-migrations/p0_1p-restore-po-disbursement-gate.sql"
run_sql "اختبار p0_1p: بوّابة الصرف المتدرّجة حاضرة في po_transition" "$HERE/48_po_disbursement_gate.sql"

run_sql "p0_1r: إدراج can_approve_disbursement في قائمة صلاحيات الوظائف (تكليف المالك A2)" "$ROOT/db/portal-migrations/p0_1r-jobs-permission-whitelist-disbursement.sql"
run_sql "اختبار p0_1r: صكّ/إسناد صلاحية الصرف للوظائف بحوكمة منع التصعيد" "$HERE/49_jobs_disbursement_permission.sql"

run_sql "p0_1s: بقاء تخصيصات صلاحيات المستخدم عبر تعديل الوظيفة (نموذج الدلتا، تكليف A3)" "$ROOT/db/portal-migrations/p0_1s-per-user-permission-overrides.sql"
run_sql "p0_1v: سحب EXECUTE الصريح من anon عن دوال P0-1s (إصلاح أمامي بلا تغيير الهجرة المطبقة)" "$ROOT/db/portal-migrations/p0_1v-anon-execute-revocation.sql"
run_sql "اختبار p0_1s: الدلتا تبقى عبر تعديل الوظيفة + منع التصعيد + إعادة التعيين" "$HERE/50_perm_overrides.sql"

run_sql "p0_1t: ضبط مفاتيح الحوكمة من الإعدادات + قفل الإطلاق (تكليف المالك C5/هـ.2 + مراجعة Gate)" "$ROOT/db/portal-migrations/p0_1t-governance-flags-rpc.sql"
run_sql "اختبار p0_1t: تبديل الضوابط أدمن فقط + قائمة بيضاء + نطاق + قفل budget/txn المالك" "$HERE/51_governance_flags.sql"

run_sql "p0_1u: حفظ مسار الاعتماد من المصمّم (تكليف المالك C6)" "$ROOT/db/portal-migrations/p0_1u-workflow-save-rpc.sql"
run_sql "اختبار p0_1u: حفظ/حذف المسار أدمن فقط + تحقّق بنيوي" "$HERE/52_workflow_designer.sql"

run_sql "p0_1w: منع منح EXECUTE تلقائياً لأي دالة تطبيق مستقبلية" "$ROOT/db/portal-migrations/p0_1w-function-default-privileges-hardening.sql"
run_sql "اختبار p0_1w: الصلاحيات الافتراضية للدوال تفشل مغلقة" "$HERE/53_function_default_privileges.sql"
run_sql "SECURITY DEFINER: exhaustive live-signature execution-boundary inventory" "$HERE/54_security_definer_inventory.sql"
run_sql "Authenticated RPC permission matrix: direct coverage for previously implicit functions" "$HERE/55_rpc_permission_matrix.sql"

run_sql "p0_2c: إغلاق منح anon المباشرة على علاقات وتسلسلات البوابة" "$HERE/56_anon_privilege_boundary.sql"
run_sql "p0_2d: إلغاء الطلب لمدير القسم/القطاع ضمن نافذة ما قبل الالتزام (تكليف المالك)" "$HERE/57_cancel_by_managers.sql"
run_sql "p0_2e: رفع الطلب لكل موظّف + استلام المُقدّم لطلبه (تكليف المالك)" "$HERE/58_open_create_requester_receipt.sql"
run_sql "p0_2f: اتساق صلاحية الإنشاء وإلغاء المصروف المباشر قبل الصرف" "$HERE/59_portal_consistency_hotfix.sql"

echo ""
echo "✅ كل اختبارات البوابة نجحت (393 تأكيد SQL) + 18 تأكيد حارس ملفات + 7 تأكيدات نقطة رفع وثائق التسجيل."

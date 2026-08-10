#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# F1 proof — staging lineage صادق:
#   A: baseline through 061؛ تُستثنى اختبارات 062 وما يعتمد عليها.
#   B: baseline through 061 + 062؛ تُطبق P0-1b…P0-1n وتنجح الحزمة الكاملة.
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" PGPASSWORD="${PGPASSWORD:-postgres}"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q)
DB="${PGDATABASE:-baseline_verify}"
BASE="$ROOT/db/staging-bootstrap/baseline_through_061.sql"
M062="$ROOT/db/portal-migrations/062-request-documents.sql"
P0B="$ROOT/db/portal-migrations/p0_1b-portal-users-guard-no-session-user-jwt-bypass.sql"
P0D="$ROOT/db/portal-migrations/p0_1d-quote-confidentiality-direct-expense-permission.sql"
P0E="$ROOT/db/portal-migrations/p0_1e-quote-confidentiality-rls-grants.sql"
P0F="$ROOT/db/portal-migrations/p0_1f-flexible-committee-policy.sql"
P0G="$ROOT/db/portal-migrations/p0_1g-po-chain-transition-window.sql"
P0H="$ROOT/db/portal-migrations/p0_1h-requester-safe-purchase-dossier.sql"
P0I="$ROOT/db/portal-migrations/p0_1i-final-release-blocker-hardening.sql"
P0J="$ROOT/db/portal-migrations/p0_1j-exact-head-review-remediation.sql"
P0K="$ROOT/db/portal-migrations/p0_1k-independent-review-remediation.sql"
P0K_FIXTURE="$ROOT/db/portal-tests/p0_1k-pre-migration-fixture.sql"
P0L="$ROOT/db/portal-migrations/p0_1l-final-independent-review-remediation.sql"
P0L_DUP_FIXTURE="$ROOT/db/portal-tests/p0_1l-pre-p0i-duplicate-fixture.sql"
P0M="$ROOT/db/portal-migrations/p0_1m-clean-install-raw-read-grants.sql"
P0N="$ROOT/db/portal-migrations/p0_1n-direct-expense-raw-read-boundary.sql"
P0O="$ROOT/db/portal-migrations/p0_1o-committee-ceiling-150k.sql"
P0P="$ROOT/db/portal-migrations/p0_1p-restore-po-disbursement-gate.sql"
# Tests that depend on post-baseline (062 / P0-1i-phase / later) migrations, skipped in Phase A.
# 47_committee_ceiling depends on p0_1o (committee ceiling 150k) which is applied only in Phase B.
# 54_security_definer_inventory and 55_rpc_permission_matrix audit the final
# post-P0 execution surface, not the legacy 061 surface.
DEP062_RE='(11_security|37_request_documents|41_requester_safe_purchase_dossier|42_final_release_blocker_hardening|43_exact_head_review_remediation|44_independent_review_remediation|45_final_independent_review_remediation|47_committee_ceiling|48_po_disbursement_gate|54_security_definer_inventory|55_rpc_permission_matrix)\.sql$'

echo "▶ [1] drift guard: baseline مطابق للمولَّد الحتميّ"
node "$ROOT/scripts/deploy/build-baseline.mjs" --check

DBA="${DB}_a"; DBB="${DB}_b"
echo "▶ [2] roles + قواعد نظيفة"
"${PSQL[@]}" -d postgres -f "$ROOT/db/portal-tests/00_roles.sql" >/dev/null
"${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DBA;" -c "CREATE DATABASE $DBA;" -c "DROP DATABASE IF EXISTS $DBB;" -c "CREATE DATABASE $DBB;"

echo "▶ [3] المرحلة أ — تحميل الأساس through 061 ($DBA)"
if ! "${PSQL[@]}" -d "$DBA" -f "$BASE" >/tmp/baseline_load.log 2>&1; then
  echo "❌ فشل تحميل الأساس:"; grep -iE "ERROR|FATAL" /tmp/baseline_load.log | head -20; exit 1; fi
ABS=$("${PSQL[@]}" -d "$DBA" -tAc "select count(*) from information_schema.tables where table_name='portal_request_documents'")
[ "$ABS" = "0" ] || { echo "❌ 062 يجب أن تكون غائبة عن الأساس (=$ABS)"; exit 1; }
CORE=$("${PSQL[@]}" -d "$DBA" -tAc "select count(*) from information_schema.tables where table_name in ('portal_requests','portal_payments','portal_audit','portal_approvals')")
[ "$CORE" = "4" ] || { echo "❌ كائنات 061 الأساسية ناقصة (=$CORE/4)"; exit 1; }

echo "▶ [4] المرحلة أ — حزمة 061 مع الاستثناءات الصادقة"
a_pass=0; a_skip=0; a_p0b=0; a_p0d=0; a_p0e=0; a_p0f=0; a_p0g=0
for f in $(ls "$ROOT"/db/portal-tests/[0-9]*.sql | sort); do
  b=$(basename "$f")
  if [[ "$b" =~ $DEP062_RE ]]; then a_skip=$((a_skip+1)); echo "   ⏭️  (062/P0-1i phase) $b"; continue; fi
  if [[ "$b" == "38_portal_users_least_privilege.sql" && "$a_p0b" = "0" ]]; then
    "${PSQL[@]}" -d "$DBA" -f "$P0B" >/tmp/p0b_a.log 2>&1 || { echo "❌ P0-1b/P0-1c A"; cat /tmp/p0b_a.log; exit 1; }
    a_p0b=1
  fi
  if [[ "$b" == "39_quote_confidentiality_direct_expense_permission.sql" ]]; then
    if [[ "$a_p0d" = "0" ]]; then "${PSQL[@]}" -d "$DBA" -f "$P0D" >/tmp/p0d_a.log 2>&1 || { cat /tmp/p0d_a.log; exit 1; }; a_p0d=1; fi
    if [[ "$a_p0e" = "0" ]]; then "${PSQL[@]}" -d "$DBA" -f "$P0E" >/tmp/p0e_a.log 2>&1 || { cat /tmp/p0e_a.log; exit 1; }; a_p0e=1; fi
  fi
  if [[ "$b" == "40_flexible_committee_policy.sql" ]]; then
    if [[ "$a_p0f" = "0" ]]; then "${PSQL[@]}" -d "$DBA" -f "$P0F" >/tmp/p0f_a.log 2>&1 || { cat /tmp/p0f_a.log; exit 1; }; a_p0f=1; fi
    if [[ "$a_p0g" = "0" ]]; then "${PSQL[@]}" -d "$DBA" -f "$P0G" >/tmp/p0g_a.log 2>&1 || { cat /tmp/p0g_a.log; exit 1; }; a_p0g=1; fi
  fi
  "${PSQL[@]}" -d "$DBA" -f "$f" >/tmp/phaseA.log 2>&1 || { echo "❌ المرحلة أ فشل $b:"; grep -iE "ERROR|EXCEPTION" /tmp/phaseA.log | head -5; exit 1; }
  a_pass=$((a_pass+1))
done
echo "   ✓ المرحلة أ: $a_pass نجح · $a_skip مؤجل لِما بعد 062/P0-1i"

echo "▶ [5] المرحلة ب — أساس نظيف ($DBB) ثم 062"
if ! "${PSQL[@]}" -d "$DBB" -f "$BASE" >/tmp/base_b.log 2>&1; then echo "❌ فشل تحميل الأساس B"; grep -iE "ERROR|FATAL" /tmp/base_b.log|head; exit 1; fi
if ! "${PSQL[@]}" -d "$DBB" -f "$M062" >/tmp/m062_load.log 2>&1; then echo "❌ فشل 062:"; grep -iE "ERROR|FATAL" /tmp/m062_load.log | head -20; exit 1; fi
PRE=$("${PSQL[@]}" -d "$DBB" -tAc "select count(*) from information_schema.tables where table_name='portal_request_documents'")
[ "$PRE" = "1" ] || { echo "❌ 062 يجب أن تظهر بعد التطبيق (=$PRE)"; exit 1; }

echo "▶ [6] المرحلة ب — الحزمة الكاملة على أساس+062"
b_pass=0; b_p0b=0; b_p0d=0; b_p0e=0; b_p0f=0; b_p0g=0; b_p0h=0; b_p0i=0; b_p0j=0; b_p0k=0; b_p0l=0; b_p0m=0; b_p0n=0; b_p0o=0; b_p0p=0
for f in $(ls "$ROOT"/db/portal-tests/[0-9]*.sql | sort); do
  b=$(basename "$f")
  if [[ "$b" == "38_portal_users_least_privilege.sql" && "$b_p0b" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0B" >/tmp/p0b_b.log 2>&1 || { cat /tmp/p0b_b.log; exit 1; }; b_p0b=1
  fi
  if [[ "$b" == "39_quote_confidentiality_direct_expense_permission.sql" ]]; then
    if [[ "$b_p0d" = "0" ]]; then "${PSQL[@]}" -d "$DBB" -f "$P0D" >/tmp/p0d_b.log 2>&1 || { cat /tmp/p0d_b.log; exit 1; }; b_p0d=1; fi
    if [[ "$b_p0e" = "0" ]]; then "${PSQL[@]}" -d "$DBB" -f "$P0E" >/tmp/p0e_b.log 2>&1 || { cat /tmp/p0e_b.log; exit 1; }; b_p0e=1; fi
  fi
  if [[ "$b" == "40_flexible_committee_policy.sql" ]]; then
    if [[ "$b_p0f" = "0" ]]; then "${PSQL[@]}" -d "$DBB" -f "$P0F" >/tmp/p0f_b.log 2>&1 || { cat /tmp/p0f_b.log; exit 1; }; b_p0f=1; fi
    if [[ "$b_p0g" = "0" ]]; then "${PSQL[@]}" -d "$DBB" -f "$P0G" >/tmp/p0g_b.log 2>&1 || { cat /tmp/p0g_b.log; exit 1; }; b_p0g=1; fi
  fi
  if [[ "$b" == "41_requester_safe_purchase_dossier.sql" && "$b_p0h" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0H" >/tmp/p0h_b.log 2>&1 || { echo "❌ P0-1h B"; cat /tmp/p0h_b.log; exit 1; }; b_p0h=1
  fi
  if [[ "$b" == "42_final_release_blocker_hardening.sql" && "$b_p0i" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0L_DUP_FIXTURE" >/tmp/p0l_dup_fixture_b.log 2>&1 || { echo "❌ P0-1l duplicate fixture B"; cat /tmp/p0l_dup_fixture_b.log; exit 1; }
    "${PSQL[@]}" -d "$DBB" -f "$P0I" >/tmp/p0i_b.log 2>&1 || { echo "❌ P0-1i B"; cat /tmp/p0i_b.log; exit 1; }; b_p0i=1
  fi
  if [[ "$b" == "43_exact_head_review_remediation.sql" && "$b_p0j" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0J" >/tmp/p0j_b.log 2>&1 || { echo "❌ P0-1j B"; cat /tmp/p0j_b.log; exit 1; }; b_p0j=1
  fi
  if [[ "$b" == "44_independent_review_remediation.sql" && "$b_p0k" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0K_FIXTURE" >/tmp/p0k_fixture_b.log 2>&1 || { echo "❌ P0-1k fixture B"; cat /tmp/p0k_fixture_b.log; exit 1; }
    "${PSQL[@]}" -d "$DBB" -f "$P0K" >/tmp/p0k_b.log 2>&1 || { echo "❌ P0-1k B"; cat /tmp/p0k_b.log; exit 1; }; b_p0k=1
  fi
  if [[ "$b" == "45_final_independent_review_remediation.sql" && "$b_p0l" = "0" && "$b_p0m" = "0" && "$b_p0n" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0L" >/tmp/p0l_b.log 2>&1 || { echo "❌ P0-1l B"; cat /tmp/p0l_b.log; exit 1; }; b_p0l=1
    "${PSQL[@]}" -d "$DBB" -f "$P0M" >/tmp/p0m_b.log 2>&1 || { echo "❌ P0-1m B"; cat /tmp/p0m_b.log; exit 1; }; b_p0m=1
    "${PSQL[@]}" -d "$DBB" -f "$P0N" >/tmp/p0n_b.log 2>&1 || { echo "❌ P0-1n B"; cat /tmp/p0n_b.log; exit 1; }; b_p0n=1
  fi
  if [[ "$b" == "47_committee_ceiling.sql" && "$b_p0o" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0O" >/tmp/p0o_b.log 2>&1 || { echo "❌ P0-1o B"; cat /tmp/p0o_b.log; exit 1; }; b_p0o=1
  fi
  if [[ "$b" == "48_po_disbursement_gate.sql" && "$b_p0p" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0P" >/tmp/p0p_b.log 2>&1 || { echo "❌ P0-1p B"; cat /tmp/p0p_b.log; exit 1; }; b_p0p=1
  fi
  "${PSQL[@]}" -d "$DBB" -f "$f" >/tmp/phaseB.log 2>&1 || { echo "❌ المرحلة ب فشل $b:"; grep -iE "ERROR|EXCEPTION" /tmp/phaseB.log | head -5; exit 1; }
  b_pass=$((b_pass+1))
done
echo "   ✓ المرحلة ب: $b_pass ملفاً نجح على أساس+062+P0-1b…P0-1n"

echo "▶ [7] ✅ F1 proof PASS — A=$a_pass/$a_skip مؤجل · 062 ✓ · P0-1b…P0-1n ✓ · B=$b_pass"

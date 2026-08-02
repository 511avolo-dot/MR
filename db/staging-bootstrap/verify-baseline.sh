#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  F1 proof (G1-FINAL-01) — لينيَج staging صادق:
#    المرحلة أ: قاعدة فارغة → baseline_through_061 → حزمة 061 تنجح.
#    المرحلة ب: baseline_through_061 → 062 → الحزمة الكاملة تنجح.
#  P0-1b/P0-1c/P0-1d/P0-1e/P0-1f تُطبّق قبل اختبارات أقلّ الامتياز
#  وسرية العروض وسياسات سير العمل المرنة.
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
DEP062_RE='(11_security|37_request_documents)\.sql$'

echo "▶ [1] drift guard: baseline مطابق للمولَّد الحتميّ"
node "$ROOT/scripts/deploy/build-baseline.mjs" --check

DBA="${DB}_a"; DBB="${DB}_b"
echo "▶ [2] roles + قواعد نظيفة"
"${PSQL[@]}" -d postgres -f "$ROOT/db/portal-tests/00_roles.sql" >/dev/null
"${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DBA;" -c "CREATE DATABASE $DBA;" -c "DROP DATABASE IF EXISTS $DBB;" -c "CREATE DATABASE $DBB;"

echo "▶ [3] المرحلة أ — تحميل الأساس (through 061) على قاعدة فارغة ($DBA)"
if ! "${PSQL[@]}" -d "$DBA" -f "$BASE" > /tmp/baseline_load.log 2>&1; then
  echo "❌ فشل تحميل الأساس:"; grep -iE "ERROR|FATAL" /tmp/baseline_load.log | head -20; exit 1; fi
ABS=$("${PSQL[@]}" -d "$DBA" -tAc "select count(*) from information_schema.tables where table_name='portal_request_documents'")
[ "$ABS" = "0" ] || { echo "❌ 062 يجب أن تكون غائبة عن الأساس (=$ABS)"; exit 1; }
CORE=$("${PSQL[@]}" -d "$DBA" -tAc "select count(*) from information_schema.tables where table_name in ('portal_requests','portal_payments','portal_audit','portal_approvals')")
[ "$CORE" = "4" ] || { echo "❌ كائنات 061 الأساسية ناقصة (=$CORE/4)"; exit 1; }

echo "▶ [4] المرحلة أ — الحزمة على 061 (باستثناء ملفات 062 الطبيعية)"
a_pass=0; a_skip=0; a_p0b=0; a_p0d=0; a_p0e=0; a_p0f=0
for f in $(ls "$ROOT"/db/portal-tests/[0-9]*.sql | sort); do
  b=$(basename "$f")
  if [[ "$b" =~ $DEP062_RE ]]; then a_skip=$((a_skip+1)); echo "   ⏭️  (062-phase) $b"; continue; fi
  if [[ "$b" == "38_portal_users_least_privilege.sql" && "$a_p0b" = "0" ]]; then
    "${PSQL[@]}" -d "$DBA" -f "$P0B" >/tmp/p0b_a.log 2>&1 || { echo "❌ فشل تطبيق P0-1b/P0-1c في المرحلة أ"; cat /tmp/p0b_a.log; exit 1; }
    a_p0b=1
  fi
  if [[ "$b" == "39_quote_confidentiality_direct_expense_permission.sql" ]]; then
    if [[ "$a_p0d" = "0" ]]; then
      "${PSQL[@]}" -d "$DBA" -f "$P0D" >/tmp/p0d_a.log 2>&1 || { echo "❌ فشل تطبيق P0-1d في المرحلة أ"; cat /tmp/p0d_a.log; exit 1; }
      a_p0d=1
    fi
    if [[ "$a_p0e" = "0" ]]; then
      "${PSQL[@]}" -d "$DBA" -f "$P0E" >/tmp/p0e_a.log 2>&1 || { echo "❌ فشل تطبيق P0-1e في المرحلة أ"; cat /tmp/p0e_a.log; exit 1; }
      a_p0e=1
    fi
  fi
  if [[ "$b" == "40_flexible_committee_policy.sql" && "$a_p0f" = "0" ]]; then
    "${PSQL[@]}" -d "$DBA" -f "$P0F" >/tmp/p0f_a.log 2>&1 || { echo "❌ فشل تطبيق P0-1f في المرحلة أ"; cat /tmp/p0f_a.log; exit 1; }
    a_p0f=1
  fi
  "${PSQL[@]}" -d "$DBA" -f "$f" >/tmp/phaseA.log 2>&1 || { echo "❌ المرحلة أ فشل $b:"; grep -iE "ERROR|EXCEPTION" /tmp/phaseA.log | head -5; exit 1; }
  a_pass=$((a_pass+1))
done
echo "   ✓ المرحلة أ: $a_pass نجح · $a_skip مؤجَّل لِما-بعد-062 · P0-1b/P0-1d/P0-1e/P0-1f طبّقت"

echo "▶ [5] إثبات التطبيق التدريجيّ — أساس نظيف ($DBB) → 062"
if ! "${PSQL[@]}" -d "$DBB" -f "$BASE" > /tmp/base_b.log 2>&1; then echo "❌ فشل تحميل الأساس ($DBB)"; grep -iE "ERROR|FATAL" /tmp/base_b.log|head; exit 1; fi
if ! "${PSQL[@]}" -d "$DBB" -f "$M062" > /tmp/m062_load.log 2>&1; then
  echo "❌ فشل تطبيق 062 فوق الأساس:"; grep -iE "ERROR|FATAL" /tmp/m062_load.log | head -20; exit 1; fi
PRE=$("${PSQL[@]}" -d "$DBB" -tAc "select count(*) from information_schema.tables where table_name='portal_request_documents'")
[ "$PRE" = "1" ] || { echo "❌ 062 يجب أن تظهر بعد التطبيق (=$PRE)"; exit 1; }

echo "▶ [6] المرحلة ب — الحزمة الكاملة على (أساس+062)"
b_pass=0; b_p0b=0; b_p0d=0; b_p0e=0; b_p0f=0
for f in $(ls "$ROOT"/db/portal-tests/[0-9]*.sql | sort); do
  b=$(basename "$f")
  if [[ "$b" == "38_portal_users_least_privilege.sql" && "$b_p0b" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0B" >/tmp/p0b_b.log 2>&1 || { echo "❌ فشل تطبيق P0-1b/P0-1c في المرحلة ب"; cat /tmp/p0b_b.log; exit 1; }
    b_p0b=1
  fi
  if [[ "$b" == "39_quote_confidentiality_direct_expense_permission.sql" ]]; then
    if [[ "$b_p0d" = "0" ]]; then
      "${PSQL[@]}" -d "$DBB" -f "$P0D" >/tmp/p0d_b.log 2>&1 || { echo "❌ فشل تطبيق P0-1d في المرحلة ب"; cat /tmp/p0d_b.log; exit 1; }
      b_p0d=1
    fi
    if [[ "$b_p0e" = "0" ]]; then
      "${PSQL[@]}" -d "$DBB" -f "$P0E" >/tmp/p0e_b.log 2>&1 || { echo "❌ فشل تطبيق P0-1e في المرحلة ب"; cat /tmp/p0e_b.log; exit 1; }
      b_p0e=1
    fi
  fi
  if [[ "$b" == "40_flexible_committee_policy.sql" && "$b_p0f" = "0" ]]; then
    "${PSQL[@]}" -d "$DBB" -f "$P0F" >/tmp/p0f_b.log 2>&1 || { echo "❌ فشل تطبيق P0-1f في المرحلة ب"; cat /tmp/p0f_b.log; exit 1; }
    b_p0f=1
  fi
  "${PSQL[@]}" -d "$DBB" -f "$f" >/tmp/phaseB.log 2>&1 || { echo "❌ المرحلة ب فشل $b:"; grep -iE "ERROR|EXCEPTION" /tmp/phaseB.log | head -5; exit 1; }
  b_pass=$((b_pass+1))
done
echo "   ✓ المرحلة ب: $b_pass ملفّ نجح على (أساس+062+P0-1b/P0-1d/P0-1e/P0-1f)"

echo "▶ [7] ✅ F1 proof PASS — Phase A(061)=$a_pass نجح/$a_skip مؤجَّل · 062 ✓ · P0-1b/P0-1d/P0-1e/P0-1f ✓ · Phase B=$b_pass نجح — خروج 0"

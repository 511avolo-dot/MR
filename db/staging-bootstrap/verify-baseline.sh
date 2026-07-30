#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  F1 proof — لينيَج staging صادق: قاعدة فارغة → baseline_through_061 → (062) → الحزمة.
#  يثبت أنّ قطعة الأساس تُنشئ قاعدة فارغة بنجاح (بلا 062)، وأنّ 062 تُطبَّق منفصلةً فوقها، وأنّ الحزمة
#  الكاملة تنجح على (أساس+062). لا اختراع تاريخ · لا migration repair · لا استهداف إنتاج.
#  الاستخدام (CI بحاوية postgres):  PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres bash db/staging-bootstrap/verify-baseline.sh
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" PGPASSWORD="${PGPASSWORD:-postgres}"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q)
DB="${PGDATABASE:-baseline_verify}"
BASE="$ROOT/db/staging-bootstrap/baseline_through_061.sql"
M062="$ROOT/db/portal-migrations/062-request-documents.sql"

echo "▶ [1/7] drift guard: baseline مطابق للمولَّد الحتميّ"
node "$ROOT/scripts/deploy/build-baseline.mjs" --check

echo "▶ [2/7] قاعدة فارغة نظيفة: $DB"
"${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
"${PSQL[@]}" -d postgres -f "$ROOT/db/portal-tests/00_roles.sql" >/dev/null

echo "▶ [3/7] تحميل قطعة الأساس (through 061) على قاعدة فارغة"
if ! "${PSQL[@]}" -d "$DB" -f "$BASE" > /tmp/baseline_load.log 2>&1; then
  echo "❌ فشل تحميل الأساس:"; grep -iE "ERROR|FATAL" /tmp/baseline_load.log | head -20; exit 1; fi

echo "▶ [4/7] تأكيد: 062 غائبة عن الأساس + كائنات 061 الأساسية موجودة"
ABS=$("${PSQL[@]}" -d "$DB" -tAc "select count(*) from information_schema.tables where table_name='portal_request_documents'")
[ "$ABS" = "0" ] || { echo "❌ portal_request_documents يجب أن تكون غائبة عن الأساس (=$ABS)"; exit 1; }
CORE=$("${PSQL[@]}" -d "$DB" -tAc "select count(*) from information_schema.tables where table_name in ('portal_requests','portal_payments','portal_audit','portal_approvals')")
[ "$CORE" = "4" ] || { echo "❌ كائنات 061 الأساسية ناقصة (=$CORE/4)"; exit 1; }
echo "   ✓ الأساس مخطّط 061 صالح (062 غائبة، 4/4 كائنات أساسية)"

echo "▶ [5/7] تطبيق الهجرة 062 منفصلةً فوق الأساس"
if ! "${PSQL[@]}" -d "$DB" -f "$M062" > /tmp/m062_load.log 2>&1; then
  echo "❌ فشل تطبيق 062 فوق الأساس:"; grep -iE "ERROR|FATAL" /tmp/m062_load.log | head -20; exit 1; fi
PRE=$("${PSQL[@]}" -d "$DB" -tAc "select count(*) from information_schema.tables where table_name='portal_request_documents'")
[ "$PRE" = "1" ] || { echo "❌ portal_request_documents يجب أن تظهر بعد 062 (=$PRE)"; exit 1; }
echo "   ✓ 062 مُطبَّقة (portal_request_documents موجودة)"

echo "▶ [6/7] الحزمة الكاملة تنجح على (أساس+062)"
n=0
for f in $(ls "$ROOT"/db/portal-tests/[0-9]*.sql | sort); do
  "${PSQL[@]}" -d "$DB" -f "$f" >/tmp/suite_t.log 2>&1 || { echo "❌ فشل $(basename "$f"):"; grep -iE "ERROR|EXCEPTION" /tmp/suite_t.log | head -5; exit 1; }
  n=$((n+1))
done
echo "   ✓ $n ملفّ تأكيد نجح على (أساس+062)"

echo "▶ [7/7] ✅ F1 proof PASS — قاعدة فارغة → أساس(061) → 062 → حزمة ($n) — خروج 0"

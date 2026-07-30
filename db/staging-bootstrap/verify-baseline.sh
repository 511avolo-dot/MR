#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  F1 proof (G1-FINAL-01) — لينيَج staging صادق بمرحلتين على قاعدة واحدة، بسجلّات/عدّادات منفصلة:
#    المرحلة أ: قاعدة فارغة → baseline_through_061 → **الحزمة على 061 تنجح** (قبل 062).
#    المرحلة ب: تطبيق 062 → **الحزمة الكاملة تنجح** (بعد 062).
#  فلو حوى الأساس انحداراً قبل-062، تفشل المرحلة أ حتى لو «أصلحه/أخفاه» 062.
#  ملفّان يعتمدان 062 بطبيعتهما فيُشغَّلان في المرحلة ب فقط (موثَّق صراحةً، لا إخفاء):
#    • 37_request_documents.sql — يختبر ميزة 062 (portal_request_documents/create_expense_draft).
#    • 11_security.sql — يُعدّد سطح الدوال الخادمية الذي **تغيّره الهجرة 062** (تحقّق سطح ما-بعد-062).
#  لا اختراع تاريخ · لا migration repair · لا استهداف إنتاج.
#  الاستخدام (CI بحاوية postgres):  PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres bash db/staging-bootstrap/verify-baseline.sh
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" PGPASSWORD="${PGPASSWORD:-postgres}"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q)
DB="${PGDATABASE:-baseline_verify}"
BASE="$ROOT/db/staging-bootstrap/baseline_through_061.sql"
M062="$ROOT/db/portal-migrations/062-request-documents.sql"
# ملفّات تعتمد 062 بطبيعتها (تُشغَّل في المرحلة ب فقط):
DEP062_RE='(11_security|37_request_documents)\.sql$'

echo "▶ [1] drift guard: baseline مطابق للمولَّد الحتميّ"
node "$ROOT/scripts/deploy/build-baseline.mjs" --check

# ملاحظة: حزمة التأكيدات تُراكِم حالة (مثل 10_outbox) فلا تُعاد على نفس القاعدة؛ لذا كل مرحلة على قاعدة نظيفة
# منفصلة. الطابع التسلسليّ (أساس → 062 تدريجيّاً) يُثبَت مستقلّاً على قاعدة ثالثة قبل حزمة المرحلة ب.
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

echo "▶ [4] المرحلة أ — الحزمة على 061 (باستثناء ملفّي 062-الطبيعيّين) يجب أن تنجح"
a_pass=0; a_skip=0
for f in $(ls "$ROOT"/db/portal-tests/[0-9]*.sql | sort); do
  b=$(basename "$f")
  if [[ "$b" =~ $DEP062_RE ]]; then a_skip=$((a_skip+1)); echo "   ⏭️  (062-phase) $b"; continue; fi
  "${PSQL[@]}" -d "$DBA" -f "$f" >/tmp/phaseA.log 2>&1 || { echo "❌ المرحلة أ فشل $b (انحدار قبل-062):"; grep -iE "ERROR|EXCEPTION" /tmp/phaseA.log | head -5; exit 1; }
  a_pass=$((a_pass+1))
done
echo "   ✓ المرحلة أ: $a_pass نجح · $a_skip مؤجَّل لِما-بعد-062"

echo "▶ [5] إثبات التطبيق التدريجيّ — أساس نظيف ($DBB) → تطبيق 062 فوقه"
if ! "${PSQL[@]}" -d "$DBB" -f "$BASE" > /tmp/base_b.log 2>&1; then echo "❌ فشل تحميل الأساس ($DBB)"; grep -iE "ERROR|FATAL" /tmp/base_b.log|head; exit 1; fi
if ! "${PSQL[@]}" -d "$DBB" -f "$M062" > /tmp/m062_load.log 2>&1; then
  echo "❌ فشل تطبيق 062 فوق الأساس:"; grep -iE "ERROR|FATAL" /tmp/m062_load.log | head -20; exit 1; fi
PRE=$("${PSQL[@]}" -d "$DBB" -tAc "select count(*) from information_schema.tables where table_name='portal_request_documents'")
[ "$PRE" = "1" ] || { echo "❌ 062 يجب أن تظهر بعد التطبيق (=$PRE)"; exit 1; }

echo "▶ [6] المرحلة ب — الحزمة الكاملة على (أساس+062) يجب أن تنجح"
b_pass=0
for f in $(ls "$ROOT"/db/portal-tests/[0-9]*.sql | sort); do
  b=$(basename "$f")
  "${PSQL[@]}" -d "$DBB" -f "$f" >/tmp/phaseB.log 2>&1 || { echo "❌ المرحلة ب فشل $b:"; grep -iE "ERROR|EXCEPTION" /tmp/phaseB.log | head -5; exit 1; }
  b_pass=$((b_pass+1))
done
echo "   ✓ المرحلة ب: $b_pass ملفّ نجح على (أساس+062)"

echo "▶ [7] ✅ F1 proof PASS — Phase A(061)=$a_pass نجح/$a_skip مؤجَّل · التطبيق التدريجيّ 062 ✓ · Phase B(062)=$b_pass نجح — خروج 0"

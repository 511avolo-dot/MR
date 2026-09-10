#!/usr/bin/env bash
# تشغيل تأكيدات نطاق موظفي الصيانة (النظام 2) على PostgreSQL محلّي.
#   PGHOST/PGPORT/PGUSER من البيئة، أو مثيل محلّي على 5433.
#   الاستعمال: bash db/system2-tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

DB="${DB:-system2_scope_test}"
export PGHOST="${PGHOST:-/tmp/pgsock}" PGPORT="${PGPORT:-5433}" PGUSER="${PGUSER:-postgres}"

psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB;" >/dev/null
psql -q -d postgres -c "CREATE DATABASE $DB;"        >/dev/null

for f in db/system2-tests/00_stub.sql db/system2-staff-scope.sql db/system2-tests/10_scope.sql; do
  printf '  %-42s' "$(basename "$f")"
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >/dev/null 2>/tmp/s2t.err \
    && echo "ok" \
    || { echo "FAILED"; grep -m3 'ERROR' /tmp/s2t.err || cat /tmp/s2t.err; exit 1; }
done

# الهجرة idempotent — إعادة تشغيلها يجب ألّا تكسر شيئاً
printf '  %-42s' "re-run (idempotent)"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f db/system2-staff-scope.sql >/dev/null 2>&1 && echo "ok" || { echo "FAILED"; exit 1; }

psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB;" >/dev/null
echo "✓ تأكيدات النطاق (SC1–SC16) — خروج 0"

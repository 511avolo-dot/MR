# EXECUTION LOG — Enterprise Certification Audit

Auditor: Claude (combined Principal Eng / Security / DevSecOps / DB / Procurement / QA / SRE roles)
Date: 2026-07-27
Branch: `audit/enterprise-certification-2026-07-27` (based on `main` @ `b9d9d6d`)
Scope: System 3 (procurement/approvals portal) primary; System 1 (supplier registration) and System 2 (procurement main) reviewed for isolation and shared surfaces.

No secret values are recorded in this log. Live database mutations were made **only** through reviewed idempotent migrations; all live *inspection* queries were read-only.

## Chronology

1. **Safety / branch check.** `git status` clean. Referenced audit branch `audit/enterprise-certification-2026-07-27` and commit `54b971a` were **NOT present** on origin (`git ls-remote` → none). Created a fresh audit branch off merged `main` (`b9d9d6d`). Did **not** modify `main`.
2. **Baseline test evidence.** `bash db/portal-tests/run.sh` on PostgreSQL 16 (local unprivileged cluster, port 5455) → **EXIT 0**, 189 `PASS` assertion lines, 0 failures (171 SQL assertions + 18 file-guard JS + 5 reg-doc endpoint). Captured `/tmp/audit_suite.log`.
3. **JS integrity.** `node --check` on every `functions/api/*.js` → all OK. `node db/portal-tests/file-guard.test.mjs` → PASS.
4. **Inventory.** Enumerated top-level, `functions/api` (20 endpoints), 59 migration files, 11 HTML pages; LOC of the large surfaces (portal 6.0k, index 22.9k, register 4.7k, standalone 7.3k).
5. **Live DB security advisors** (`get_advisors` security, project `mwbjoysuybgbrvfrprex`): 134 WARN + 5 INFO. All WARN fall into 4 documented-benign classes **except one actionable**: `auth_leaked_password_protection` (disabled).
6. **RLS / guard verification (did NOT assume).**
   - Enumerated every open-write (`always_true`) table from advisors (17 tables).
   - Live `pg_trigger` query: **every** open-write table has a `*_guard` trigger; the 5 tables with **no** guard (`portal_budgets`, `portal_contracts`, `portal_recurring_expenses`, `portal_returns`, `portal_supplier_invoices`) have **only SELECT policies** (writes deny-by-default) — verified via `pg_policies`.
   - Confirmed local suite S-series proves guards deny non-privileged writes (guards test privilege, not role — authoritative since `postgres` is privileged and would bypass in a live probe).
7. **PII / financial read-exposure review.** Live `pg_policies`: `portal_payments`/`portal_suppliers` SELECT gated to finance/procurement with request visibility; `portal_users`/`portal_settings` readable by all `authenticated` (design choice); `portal_beneficiaries` readable by `can_create` (4/15 users).
8. **Finding SEC-01 (anon residual grants).** Live `has_table_privilege`: `anon` held table-level SELECT on `portal_users/payments/suppliers/beneficiaries` (Supabase default). Verified **no anon read path** exists (all reads in `loadAll()` gated by `if(!session)`; supplier pages use RPCs). Confirmed `authenticated` does **not** inherit `anon` (`pg_auth_members`) and holds direct grants → `REVOKE FROM anon` is safe on production.
9. **Remediation SEC-01.** Added migration `059-revoke-anon-sensitive-reads.sql` (REVOKE anon SELECT + explicit GRANT authenticated) + test `35_anon_hardening.sql` (AH1/AH2). Test initially caught a local-stub role-inheritance artifact; hardened the migration to re-affirm the authenticated grant. Re-ran suite → EXIT 0. Applied live via `apply_migration`; verified `anon=false`, `authenticated=true` on all four tables.
10. **Documentation + handoff.** Produced the `audit-output/` package; committed to the audit branch; PR opened/updated (draft, not merged).

## Commands executed (representative)
- `bash db/portal-tests/run.sh` (PGHOST=/home/postgres/pt PGPORT=5455)
- `node --check functions/api/*.js`; `node db/portal-tests/file-guard.test.mjs`
- Supabase MCP: `get_advisors(security)`, `list_migrations`, `execute_sql` (read-only inspection), `apply_migration(059)`
- `git checkout -B audit/... origin/main`

## Remaining uncertainties (see UNRESOLVED_ITEMS.md)
Dynamic web pen-testing, load/soak/chaos testing, and full browser E2E of the new converter UI panels were **not** executed in this environment and are marked NOT VERIFIABLE.

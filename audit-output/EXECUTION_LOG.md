# EXECUTION LOG — Enterprise Certification Audit

Auditor: Claude (combined Principal Eng / Security / DevSecOps / DB / Procurement / QA / SRE roles)
Date: 2026-07-27
Branch: `audit/enterprise-certification-2026-07-27` (based on `main` @ `b9d9d6d`)
Scope: System 3 (procurement/approvals portal) primary; System 1 (supplier registration) and System 2 (procurement main) reviewed for isolation and shared surfaces.

No secret values are recorded in this log. Live database mutations were made **only** through reviewed idempotent migrations; all live *inspection* queries were read-only.

## Chronology

1. **Safety / branch check.** `git status` clean. Referenced audit branch `audit/enterprise-certification-2026-07-27` and commit `54b971a` were **NOT present** on origin (`git ls-remote` → none). Created a fresh audit branch off merged `main` (`b9d9d6d`). Did **not** modify `main`.
2. **Baseline test evidence.** `bash db/portal-tests/run.sh` on PostgreSQL 16 (local unprivileged cluster, port 5455) → **EXIT 0**, 0 failures, **201 assertions** total = 177 SQL (`NOTICE PASS` lines) + 18 file-guard JS + 6 reg-doc endpoint. (An earlier draft mis-stated this as 189/194; the 172nd SQL assertion was added when test 35 was hardened — see step 11.) Captured `/tmp/audit_suite.log`.
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
10. **Documentation + handoff.** Produced the `audit-output/` package; committed to the audit branch; draft PR #74 opened (not merged); posted a Codex-handoff-triggering `@codex review` and subscribed.
11. **Independent Codex review + honest re-verification (2026-07-28).** Codex filed 11 findings on PR #74. I re-verified **each against the source** (not trusting the bot): confirmed **AUTHZ-01** (`portal_create_expense` no department binding — read `portal-standalone.sql`), **SEC-06** (`reg-doc.js` forgeable same-origin + service-role upload + destructive cleanup — read the file), **SEC-07** (admin SoD exemption — `AND NOT portal_is_admin()` at lines 1074/1088/1187/1208/1209 + `portal_has_perm` admin-true), **SEC-03** (manual-IBAN bypass when `p_beneficiary_id` null), **GOV-01** (`portal_recurring_run` skips budget), **AUD-01** (`portal_audit_verify` doesn't detect truncation), the incomplete API inventory (INFO-05, `ls functions/api` = 21 files), the per-file breakdown (11_security emits 8 not 7; 26_disbursement 10 not 11 — counted from the run log), and the **vacuous AH1** test (standalone never grants `anon` those SELECTs, so the assertion was a no-op). Actions: hardened test 35 (AH0 seeds → 059 revokes → AH1/AH2 assert), fixed `run.sh` breakdown (now 177 SQL / 195 total (rev 1; later 201 after test 36)), and **rewrote FINDINGS / FINAL_CERTIFICATION / EXECUTIVE / TECHNICAL / PRODUCTION_BLOCKERS / API_SECURITY_MATRIX / README** to the corrected verdict **NOT READY** (2 HIGH). Suite re-run: EXIT 0, 201 assertions. Code remediations for AUTHZ-01/SEC-06/etc. referred to the owner for scope (governance changes to a live financial system).

12. **Owner-directed remediation + re-test (2026-07-28, rev 2).** Owner chose: fix the code defects now; keep admin as
    superuser (SEC-07 accepted); keep manual IBAN (SEC-03 accepted). Implemented **migration `060`** — AUTHZ-01
    (bind `portal_create_expense` department to caller, mirroring `portal_create_request`) + GOV-01 (budget check in
    `portal_recurring_run`, skip over-budget templates when `budget_enforce=1`) — merged into `portal-standalone.sql`.
    Implemented **SEC-06** partial fix in `reg-doc.js`: removed the destructive delete-existing cleanup (unique
    filenames only) + explicit doc-type allowlist; residual credential upgrade (SEC-06-R) documented as a go-live
    condition. Added test **`36_authz_expense_recurring_budget.sql`** (AZ1–3 + GOV1–2) and updated test 28 (its B4 case
    relied on a cross-department write, now forbidden — rewritten to an OPS user). Re-ran suite → **EXIT 0, 201
    assertions** (177 SQL + 18 file-guard + 6 endpoint — the 6th endpoint case pins the closed doc-type allowlist).
    `node --check reg-doc.js` OK. Rewrote the audit docs to verdict **READY WITH CONDITIONS** (0 open HIGH). Migration
    `060` was subsequently **applied live 2026-07-28** (Supabase re-authorized): migration registered, both function bodies + grants verified, and a rolled-back behavioral proof confirmed cross-dept expense is rejected on production.

## Commands executed (representative)
- `bash db/portal-tests/run.sh` (PGHOST=/home/postgres/pt PGPORT=5455)
- `node --check functions/api/*.js`; `node db/portal-tests/file-guard.test.mjs`
- Supabase MCP: `get_advisors(security)`, `list_migrations`, `execute_sql` (read-only inspection), `apply_migration(059)`, `apply_migration(060)` + rolled-back behavioral proof
- `git checkout -B audit/... origin/main`

## Remaining uncertainties (see UNRESOLVED_ITEMS.md)
Dynamic web pen-testing, load/soak/chaos testing, and full browser E2E of the new converter UI panels were **not** executed in this environment and are marked NOT VERIFIABLE.

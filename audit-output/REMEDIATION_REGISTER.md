# REMEDIATION REGISTER

## SEC-01 — Revoke residual anon SELECT on PII/financial/identity tables
- **Finding ID:** SEC-01 (MEDIUM, defense-in-depth)
- **Root cause:** Supabase grants table-level SELECT to `anon` by default on new tables; RLS was the only control removing rows. The grant itself was unnecessary (no anon read path).
- **Files changed:** `db/portal-migrations/059-revoke-anon-sensitive-reads.sql` (new); merged block appended to `db/portal-standalone.sql`; `db/portal-tests/35_anon_hardening.sql` (new); `db/portal-tests/run.sh` (wired, count → 171).
- **Migration:** 059 (idempotent). Applied live to `mwbjoysuybgbrvfrprex` via `apply_migration`.
- **Tests added:** `35_anon_hardening.sql` — AH1 (anon has no SELECT on users/payments/suppliers/beneficiaries), AH2 (authenticated retains SELECT; no regression).
- **Commands executed:** `bash db/portal-tests/run.sh` → EXIT 0 (AH1/AH2 PASS); `apply_migration`; `execute_sql` verification.
- **Test results:** local suite EXIT 0; live verify `anon_*=false`, `auth_*=true` on all four tables.
- **Regression risk:** none — verified `authenticated` does not inherit `anon` (`pg_auth_members`) and holds direct grants; the migration re-affirms the authenticated grant explicitly.
- **Rollback guidance:** `GRANT SELECT ON portal_users, portal_payments, portal_suppliers, portal_beneficiaries TO anon;` (restores prior state). RLS would still deny rows.
- **Remaining limitations:** does not change RLS (already correct). `portal_settings` intentionally left with its authenticated read (used pre-scope by UI); revisit under SEC-04 if insider threat is in scope.

## Audit-accuracy defects fixed after Codex review (2026-07-28)
- **Assertion count** — headline "189/194" corrected to **195** (172 SQL + 18 file-guard + 5 endpoint); per-file breakdown in `run.sh` corrected (11_security 8, 26_disbursement 10).
- **Vacuous AH1 test** — `35_anon_hardening.sql` now **seeds** the four `anon` SELECT grants, applies 059, then asserts removal (AH0/AH1/AH2), so it genuinely pins the revoke. Suite EXIT 0, 195 assertions.
- **Documentation honesty** — FINDINGS / FINAL_CERTIFICATION / EXECUTIVE / TECHNICAL / PRODUCTION_BLOCKERS / API_SECURITY_MATRIX / README rewritten to verdict **NOT READY** with the verified findings below.

## Verified code defects — NOT auto-remediated (referred to owner; changes to a live financial system)
| ID | Severity | Reason not auto-fixed / decision needed |
|----|----------|------------------------------------------|
| AUTHZ-01 direct-expense department binding | HIGH | Fix is small (mirror `portal_create_request`), but it's a governance change to a live RPC + needs a migration + live apply (owner's standing rule). Recommend implementing now. |
| SEC-06 reg-doc unauthenticated write/delete | HIGH | Needs a **product decision**: which credential (signed token vs authenticated session) + non-destructive cleanup. System-1 surface; pair with `system1-storage-hardening.sql`. |
| SEC-07 admin SoD exemption | MEDIUM | **Policy decision**: is admin-as-superuser intended, or should the admin bypass be removed on payment execution? |
| SEC-03 manual-IBAN bypass | MEDIUM | **Product decision**: forbid free-typed IBANs for bank expenses (require approved beneficiary) vs keep manual entry. |
| GOV-01 recurring budget bypass | MEDIUM | Add budget check to `portal_recurring_run`; migration + live apply. Recommend implementing. |
| AUD-01 audit truncation | LOW | Add an external head-hash checkpoint; design + owner sign-off. |

## Items NOT auto-remediated (owner/config-gated, unchanged)
| ID | Reason not auto-fixed |
|----|----------------------|
| SEC-02 leaked-password protection | Supabase Dashboard toggle — no code. |
| SEC-04 user/settings directory read | Broad blast radius across the UI; needs owner decision on insider-threat model. |
| OPS-01/OPS-02 dormant flags | Intentional gradual-enforcement; owner flips per launch plan. |
| SEC-05 System-1 storage policies | Owner-run SQL; frontend already fails safe (but see SEC-06 for the reg-doc auth gap). |

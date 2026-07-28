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

## Items NOT auto-remediated (documented, owner/decision-gated)
| ID | Reason not auto-fixed |
|----|----------------------|
| SEC-02 leaked-password protection | Supabase Dashboard toggle — no code. |
| SEC-03 beneficiary read breadth | Fixing the policy breaks the direct-expense beneficiary picker; needs a UI redesign (names-only) + owner sign-off. |
| SEC-04 user/settings directory read | Broad blast radius across the UI; needs owner decision on insider-threat model. |
| OPS-01/OPS-02 dormant flags | Intentional gradual-enforcement; owner flips per launch plan. |
| SEC-05 System-1 storage policies | Owner-run SQL; frontend already fails safe. |

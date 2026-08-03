# REMEDIATION REGISTER

## P0-1j — Fresh exact-head review remediation (2026-08-03)
- **Scope:** eight current findings on PR #74 starting at `a7d770a`; no migration 063.
- **Files:** `p0_1j-exact-head-review-remediation.sql`, `portal-doc.js`,
  `portal-upload-cleanup.js`, `purchase-portal.html`, SQL/JS tests and audit evidence.
- **Staging application:** `20260803093553_p0_1j_exact_head_review_remediation`
  plus index follow-up `20260803093756_p0_1j_upload_receipt_fk_index`, only on
  `vpfnycxzqziltsnzxbpb`.
- **Verification:** 13 rollback-safe SQL assertions on staging; 14 functional
  contract checks; 5 document-authorization checks; 5 cleanup checks; Stage-1 60/60; browser fixture 6/6;
  file guard 18/18 and registration endpoint 7/7.
- **Rollback:** restore the pre-P0-1j staging snapshot. Do not drop evidence,
  verification, or quarantine columns in place; that would destroy audit state.
- **Remaining:** full SQL suite/CI, Preview deploy and authenticated E2E, cron
  secret/schedule, advisor triage, fresh independent exact-head review.

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
- **Assertion count** — headline "189/194" corrected; per-file breakdown in `run.sh` corrected (11_security 8, 26_disbursement 10). After adding test 36, the suite is **203 assertions (178 SQL + 18 file-guard + 7 endpoint)**.
- **Vacuous AH1 test** — `35_anon_hardening.sql` now **seeds** the four `anon` SELECT grants, applies 059, then asserts removal (AH0/AH1/AH2), so it genuinely pins the revoke. Suite EXIT 0.
- **Documentation honesty** — FINDINGS / FINAL_CERTIFICATION / EXECUTIVE / TECHNICAL / PRODUCTION_BLOCKERS / API_SECURITY_MATRIX / README rewritten to verdict **NOT READY** with the verified findings below.

## Code defects — resolution after owner direction (2026-07-28)
| ID | Severity | Resolution |
|----|----------|-----------|
| AUTHZ-01 direct-expense department binding | HIGH | **FIXED** — migration `060`: department bound to caller (admin any / non-admin own). Test 36 (AZ1–3). Applied live 2026-07-28 + verified (rolled-back proof). |
| SEC-06 reg-doc destructive write | HIGH | **PARTIALLY FIXED** — `reg-doc.js`: destructive cleanup removed (unique filenames), explicit doc-type allowlist. **Residual SEC-06-R (MEDIUM):** credential/token upgrade is a go-live condition (registration-flow change + live test). |
| GOV-01 recurring budget bypass | MEDIUM | **FIXED** — `060`: budget enforced in `portal_recurring_run` (skips over-budget templates when enforce=1). Test 36 (GOV1–2). Applied live 2026-07-28 + verified (rolled-back proof). |
| SEC-07 admin SoD exemption | MEDIUM | **OWNER-ACCEPTED** — admin stays superuser. Documented + recommended compensating controls (≥2 admins, monitoring). No code change. |
| SEC-03 manual-IBAN bypass | MEDIUM | **OWNER-ACCEPTED** — manual IBAN entry retained. Documented. No code change. |
| AUD-01 audit truncation | LOW | OPEN (documented) — add an external head-hash checkpoint; design + owner sign-off. |

## Items NOT auto-remediated (owner/config-gated, unchanged)
| ID | Reason not auto-fixed |
|----|----------------------|
| SEC-02 leaked-password protection | Supabase Dashboard toggle — no code. |
| SEC-04 user/settings directory read | Broad blast radius across the UI; needs owner decision on insider-threat model. |
| OPS-01/OPS-02 dormant flags | Intentional gradual-enforcement; owner flips per launch plan. |
| SEC-05 System-1 storage policies | Owner-run SQL. **Correction (2nd Codex pass):** the frontend does **not** fail safe — `register.html` falls back to a direct anonymous Storage upload (bypassing the guard) when the server endpoint is unconfigured/unreachable. This anon write path is live until the SEC-06 consolidated gate (set key + remove fallback + revoke anon Storage writes + credential) is done. Tightly coupled with SEC-06. |

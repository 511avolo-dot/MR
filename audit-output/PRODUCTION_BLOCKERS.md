# PRODUCTION BLOCKERS

**Status (rev 2, 2026-07-28): the two HIGH defects are remediated. No open HIGH code blocker.**

Rev 1 (after Codex) identified 2 HIGH code defects. Rev 2 (owner-directed) remediated them; the assertion suite now
covers the fixes (tests AZ1–3, GOV1–2). Remaining items are **conditions**, not open blockers:

- **AUTHZ-01 (HIGH) → FIXED** (migration `060`): `portal_create_expense` binds the department to the caller. Test 36.
- **GOV-01 (MED) → FIXED** (`060`): budget enforced in `portal_recurring_run`. Test 36.
- **SEC-06 (HIGH) → destructive vector FIXED** (`reg-doc.js`): the delete-existing-files cleanup is removed (unique
  filenames only) and the broad regex is replaced with an explicit allowlist. **Residual (SEC-06-R, MEDIUM):** no
  caller credential — inert while the service key is unset; complete the token/credential upgrade **before** enabling
  `SUPABASE_SERVICE_ROLE_KEY` for the registration path (pair with `db/system1-storage-hardening.sql`).

## Conditions before real (non-dummy) go-live
1. **Apply migration `060` live** (after 059).
2. Complete **SEC-06-R** (reg-doc credential upgrade) before enabling the registration service key.
3. SEC-02 leaked-password protection + MFA/SSO decision (owner dashboard).
4. System-1 storage hardening Phase 1 (owner SQL) + confirm `/api/reg-doc` `{ok:true}`.
5. Enterprise data setup (committee/GM/managers/jobs/users) — high-value PO chains need a configured committee.
6. Decide/flip governance enforcement flags per launch plan.
7. Supabase PITR tier + RTO/RPO; external audit-chain anchor (AUD-01).
8. Browser E2E of the new converter panels.

**Owner-accepted risks (documented, not blockers):** SEC-07 (admin superuser) and SEC-03 (manual IBAN retained).

Portal migrations `022→059` are applied live; `060` is in the repo and **pending live apply**. Suite green
(EXIT 0, 177 SQL + 23 JS).

## Conditions that MUST be satisfied before real (non-dummy) go-live
These are **operational/owner** gates, not code blockers — but production onboarding of real users/money should not proceed until they are done:

1. **SEC-02 — Enable leaked-password protection** (Supabase Auth) and decide MFA/SSO for finance/admin. (Owner dashboard.)
2. **SEC-05 — Apply System-1 storage hardening** (`db/system1-storage-hardening.sql` Phase 1) and confirm `/api/reg-doc` returns `{ok:true}` before removing the anon INSERT fallback. (Owner SQL + Cloudflare env.)
3. **Enterprise data setup** — real committee members, GA/LOG managers, jobs, and users. The live verification (documented in CLAUDE.md) showed `committee_members = []` and demo users only; **high-value PO chains (>250K) cannot complete without a configured committee/GM** — this is a configuration gap, not a code defect.
4. **Enforcement decision** — flip the governance flags the business wants active (`budget_enforce`, `iban_change_control`, `three_way_enforce`, `contract_enforce`, `disb_gate_purchase`). Shipped dormant; currently NOT enforcing.
5. **Backup/DR posture** — confirm Supabase PITR tier + documented RTO/RPO (not verifiable from repo).

## Independent-verification gate
This certification is based on static + database evidence and the automated assertion suite. It is **not** a substitute for the second (Codex) review, dynamic web pen-test, and a browser E2E pass of the new UI panels. Treat those as release gates.

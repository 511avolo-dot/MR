# PRODUCTION BLOCKERS

**Status (revised 2026-07-28 after Codex review): 2 HIGH code defects must be fixed before real go-live.**

The first issue of this file said "no code-level blockers." An independent Codex review disproved that; both items were
re-verified against the source. These are must-fix **before onboarding real users/money**:

1. **AUTHZ-01 (HIGH) — cross-department direct-expense write.** `portal_create_expense` accepts any existing
   `p_department_id` without binding it to the caller's scope, so a `can_create` user can raise an expense against
   another department's chain and budget. Fix: mirror `portal_create_request` (derive/validate department from caller).
2. **SEC-06 (HIGH) — unauthenticated, destructive `reg-doc.js`.** Only a forgeable same-origin header gates a
   service-role upload that also **deletes** existing files under a known `reg_id/doc` prefix. Fix: require a real
   credential; make cleanup non-destructive/scoped; use an explicit doc-type allowlist. (Currently inert at `503` while
   the service key is unset — do not enable the key until fixed.)

**Strongly recommended before go-live (MEDIUM):** SEC-07 (decide/disclose the admin SoD exemption), SEC-03 (require an
approved beneficiary for bank expenses), GOV-01 (enforce budget in `portal_recurring_run`). LOW: AUD-01 (external
audit-chain anchor for truncation detection).

The portal migrations `022→059` are applied live and the assertion suite is green (EXIT 0, 195 assertions), but a green
suite does **not** cover the above — they are logic/authz defects the current tests do not exercise.

## Conditions that MUST be satisfied before real (non-dummy) go-live
These are **operational/owner** gates, not code blockers — but production onboarding of real users/money should not proceed until they are done:

1. **SEC-02 — Enable leaked-password protection** (Supabase Auth) and decide MFA/SSO for finance/admin. (Owner dashboard.)
2. **SEC-05 — Apply System-1 storage hardening** (`db/system1-storage-hardening.sql` Phase 1) and confirm `/api/reg-doc` returns `{ok:true}` before removing the anon INSERT fallback. (Owner SQL + Cloudflare env.)
3. **Enterprise data setup** — real committee members, GA/LOG managers, jobs, and users. The live verification (documented in CLAUDE.md) showed `committee_members = []` and demo users only; **high-value PO chains (>250K) cannot complete without a configured committee/GM** — this is a configuration gap, not a code defect.
4. **Enforcement decision** — flip the governance flags the business wants active (`budget_enforce`, `iban_change_control`, `three_way_enforce`, `contract_enforce`, `disb_gate_purchase`). Shipped dormant; currently NOT enforcing.
5. **Backup/DR posture** — confirm Supabase PITR tier + documented RTO/RPO (not verifiable from repo).

## Independent-verification gate
This certification is based on static + database evidence and the automated assertion suite. It is **not** a substitute for the second (Codex) review, dynamic web pen-test, and a browser E2E pass of the new UI panels. Treat those as release gates.

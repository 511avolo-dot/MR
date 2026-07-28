# PRODUCTION BLOCKERS

**Status: NO CODE-LEVEL BLOCKERS IDENTIFIED for System 3 (portal).**

No verified condition in the audited code makes deployment unacceptable: no auth/authorization bypass, no cross-supplier exposure, no financial-integrity failure, no workflow bypass, no secret exposure, no destructive migration. The portal migrations `022→059` are already applied live and the full assertion suite is green (EXIT 0).

## Conditions that MUST be satisfied before real (non-dummy) go-live
These are **operational/owner** gates, not code blockers — but production onboarding of real users/money should not proceed until they are done:

1. **SEC-02 — Enable leaked-password protection** (Supabase Auth) and decide MFA/SSO for finance/admin. (Owner dashboard.)
2. **SEC-05 — Apply System-1 storage hardening** (`db/system1-storage-hardening.sql` Phase 1) and confirm `/api/reg-doc` returns `{ok:true}` before removing the anon INSERT fallback. (Owner SQL + Cloudflare env.)
3. **Enterprise data setup** — real committee members, GA/LOG managers, jobs, and users. The live verification (documented in CLAUDE.md) showed `committee_members = []` and demo users only; **high-value PO chains (>250K) cannot complete without a configured committee/GM** — this is a configuration gap, not a code defect.
4. **Enforcement decision** — flip the governance flags the business wants active (`budget_enforce`, `iban_change_control`, `three_way_enforce`, `contract_enforce`, `disb_gate_purchase`). Shipped dormant; currently NOT enforcing.
5. **Backup/DR posture** — confirm Supabase PITR tier + documented RTO/RPO (not verifiable from repo).

## Independent-verification gate
This certification is based on static + database evidence and the automated assertion suite. It is **not** a substitute for the second (Codex) review, dynamic web pen-test, and a browser E2E pass of the new UI panels. Treat those as release gates.

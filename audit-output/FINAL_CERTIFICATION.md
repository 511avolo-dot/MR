# FINAL CERTIFICATION — Al-Deyabi Procurement & Disbursement Portal (System 3)

**Certification status: `READY WITH CONDITIONS`**

Audited artifact: branch `audit/enterprise-certification-2026-07-27` (base `main` @ `b9d9d6d`, portal migrations `022→059`).
Auditor: Claude, combined Principal Engineer / Architect / AppSec / DevSecOps / DB / Procurement / QA / SRE / Production-Readiness roles.
Date: 2026-07-27. Evidence basis: static review + live database inspection (read-only) + automated assertion suite (EXIT 0).

---

## What "READY WITH CONDITIONS" means here
The **code and database logic of System 3 are production-grade**: no BLOCKER/CRITICAL/HIGH defect was verified, the
security model (deny-by-default writes, SoD, request-scoped visibility, tamper-evident audit) holds under inspection,
and the full automated suite is green. **Conditions** are the non-code gates in `PRODUCTION_BLOCKERS.md` — owner
configuration (leaked-password protection, committee/GM/data setup, enforcement-flag flips, DR posture) and the two
independent gates (Codex second review + browser E2E of the new converter panels). None of these are code defects; all
must be closed before onboarding real users and money.

## Category scores (0–5; 5 = enterprise-grade, evidence-backed)

| Category | Score | Basis |
|---|---|---|
| Authentication | 3.5 | Supabase Auth + email-matched profiles; **leaked-password protection off (SEC-02)**, MFA/SSO not enforced — owner config. |
| Authorization / RLS | 4.5 | Deny-by-default writes (36 `always_true` policies re-gated by `*_guard` triggers, all verified present); request-scoped reads; SEC-01 residual anon grants fixed (059). |
| Segregation of Duties | 5 | Triple separation on disbursement (requester ≠ approver(s) ≠ executor) proven by tests 26/27/32 and live rollback runs. |
| Financial integrity | 5 | Payment ≤ award caps, split per-supplier caps, installment caps, idempotency (051), saga void (051), three-way match (033) — all asserted. |
| Auditability | 5 | Append-only + SHA256 hash-chain WORM (057) with tamper detection (`portal_audit_verify`), advisory-locked. |
| Data protection (PII/IBAN) | 4 | IBANs finance/procurement-gated; IBAN-change control (032/053); **SEC-03** beneficiary breadth open by design (owner decision). |
| Reliability / workflows | 4.5 | Durable in-DB state machine, transactional outbox (029), `FOR UPDATE` locking; email full-durability activation pending (OPS-02). |
| Test / CI | 4.5 | 189 automated assertions (171 SQL + 18 file-guard + 5 endpoint), CI on every portal PR; **no browser E2E** (INFO-04). |
| Observability / DR | 2.5 | Health endpoints + loud failure logs added; **backup/PITR tier + RTO/RPO not in repo** — NOT VERIFIABLE. |
| Frontend correctness | 3 | Converter panels syntax-verified only; **not browser-tested** — flagged as the top second-review priority. |

## Findings roll-up
**BLOCKER 0 · CRITICAL 0 · HIGH 0 · MEDIUM 3 · LOW 4 · INFORMATIONAL 4.** One MEDIUM defense-in-depth item
(SEC-01) was fixed and live-verified this audit (migration 059). The remaining MEDIUM/LOW are owner-config or
design-decision gated (SEC-02, SEC-03, SEC-04, OPS-01/02, SEC-05). Full detail in `FINDINGS.md`.

## Conditions to clear before real go-live (from `PRODUCTION_BLOCKERS.md`)
1. Enable Supabase leaked-password protection; decide MFA/SSO for finance/admin (SEC-02).
2. Apply System-1 storage hardening Phase 1 + confirm `/api/reg-doc` `{ok:true}` (SEC-05).
3. Configure enterprise data: real committee members, GA/LOG managers, jobs, users (high-value PO chains cannot complete otherwise).
4. Decide and flip governance enforcement flags per launch plan (OPS-01).
5. Confirm Supabase PITR tier + documented RTO/RPO.
6. Independent gates: Codex second review (`CODEX_HANDOFF.md`) + browser E2E pass of new converter panels.

## Sign-off
On the audited code and database evidence, System 3 is **certified READY WITH CONDITIONS**. This certification covers
static and database-level evidence and the automated suite; it does not substitute for the independent Codex review,
dynamic web pen-test, and browser E2E, which are release gates. Systems 1 and 2 were reviewed only for isolation and
shared surfaces (confirmed isolated); they were not re-certified here.

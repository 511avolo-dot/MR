# FINAL CERTIFICATION — Al-Deyabi Procurement & Disbursement Portal (System 3)

**Certification status: `NOT READY` (revised 2026-07-28 after independent Codex review)**

Audited artifact: branch `audit/enterprise-certification-2026-07-27` (base `main` @ `b9d9d6d`, portal migrations `022→059`).
Auditor: Claude, combined Principal Engineer / Architect / AppSec / DevSecOps / DB / Procurement / QA / SRE / Production-Readiness roles.
Date: 2026-07-27; revised 2026-07-28. Evidence basis: static review + live database inspection (read-only) + automated assertion suite (EXIT 0) + independent Codex review of PR #74.

---

## ⚠️ Revision (2026-07-28) — verdict downgraded from READY WITH CONDITIONS to NOT READY
The first issue of this certification claimed **0 HIGH** and scored SoD/financial/audit at 5/5. An independent Codex
review challenged those claims and I **re-verified each against the source**. Two are **confirmed HIGH code defects**:
- **AUTHZ-01** — `portal_create_expense` accepts a client-supplied `p_department_id` with **no caller-scope binding**, so any `can_create` user can raise a direct expense against another department's workflow and budget (cross-department write).
- **SEC-06** — `functions/api/reg-doc.js` is an **unauthenticated, destructive** public write path (forgeable same-origin only; service-role upload + deletes existing files under a known prefix).
Plus MEDIUM corrections: admins are **exempt from all SoD** (SEC-07 — SoD is not "universal"); manual-IBAN entry bypasses the vetted-beneficiary control (SEC-03); recurring generation bypasses budget enforcement (GOV-01); the hash-chain does not detect **truncation** (AUD-01). The earlier scores were overstated. Honest verdict: **NOT READY** until the two HIGH items are remediated and re-tested; the MEDIUM items should be resolved or explicitly risk-accepted by the owner.

## What "NOT READY" means here
The workflow **engine** (durable state machine, deny-by-default writes re-gated by guards, request-scoped reads for
non-admins, idempotency/saga, outbox) is sound and well-tested — but **verified HIGH authorization/data-integrity
defects exist in code** (AUTHZ-01, SEC-06), so the system should **not** onboard real users/money until they are fixed.
This is in addition to the owner-config gates in `PRODUCTION_BLOCKERS.md` and the still-pending browser E2E.

## Category scores (0–5; 5 = enterprise-grade, evidence-backed)

| Category | Score | Basis |
|---|---|---|
| Authentication | 3.5 | Supabase Auth + email-matched profiles; **leaked-password protection off (SEC-02)**, MFA/SSO not enforced — owner config. |
| Authorization / RLS | 2.5 | Deny-by-default writes verified; request-scoped reads for non-admins — **but AUTHZ-01 (cross-department direct-expense write) is a verified HIGH**; SEC-01 anon grants fixed (059). |
| Segregation of Duties | 3 | Triple separation holds for **non-admins** (tests 26/27/32) — **but admins are exempt from all SoD (SEC-07)**; not "universal." |
| Financial integrity | 3.5 | Payment ≤ award caps, split/installment caps, idempotency (051), saga void (051), three-way match (033) asserted — **but budget not enforced on recurring generation (GOV-01)** and manual-IBAN bypass (SEC-03). |
| Auditability | 4 | Append-only + SHA256 hash-chain detects in-place edits (057) — **but does not detect truncation/suffix-deletion (AUD-01)**; no external anchor. |
| Data protection (PII/IBAN) | 3 | Payment/supplier IBANs finance/procurement-gated; **beneficiary IBANs readable by `can_create` (SEC-03)**; manual-IBAN entry bypasses the vetted beneficiary. |
| Reliability / workflows | 4 | Durable in-DB state machine, transactional outbox (029), `FOR UPDATE` locking; email full-durability activation pending (OPS-02). |
| Test / CI | 4 | 172 SQL + 18 file-guard + 5 endpoint assertions, CI on every portal PR; **no browser E2E** (INFO-04); one prior test (AH1) was vacuous and is now fixed. |
| Observability / DR | 2.5 | Health endpoints + loud failure logs; **backup/PITR tier + RTO/RPO not in repo** — NOT VERIFIABLE. |
| Frontend correctness | 2.5 | Converter panels syntax-verified only; **not browser-tested** — remains a release gate; API matrix inventory was incomplete (now fixed). |
| API security review | 2.5 | Portal endpoints JWT/token-gated — **but SEC-06 (reg-doc unauthenticated destructive write) is a verified HIGH**; inventory now complete. |

## Findings roll-up
**BLOCKER 0 · CRITICAL 0 · HIGH 2 · MEDIUM 5 · LOW 3 · INFORMATIONAL 3.** SEC-01 (defense-in-depth) and two
audit-accuracy defects (assertion breakdown; vacuous AH1 test) were fixed this audit. The two HIGH (AUTHZ-01, SEC-06)
require code fixes before go-live; the MEDIUM (SEC-07 admin-SoD, SEC-03 beneficiary IBAN, GOV-01 recurring budget,
SEC-02 leaked-password) are code-fix or owner-decision gated. Full detail in `FINDINGS.md`.

## Must-fix before go-live (code)
1. **AUTHZ-01** — bind `portal_create_expense` to the caller's department (reject/normalize cross-department `p_department_id`) + test.
2. **SEC-06** — authenticate `reg-doc.js` with a real credential; make cleanup non-destructive/scoped; explicit doc-type allowlist.
3. **SEC-07** — decide the admin-SoD policy (remove admin bypass on payment execution, or add a compensating control) and disclose it.
4. **SEC-03** — require an approved beneficiary for `bank` expenses (names-only picker + server-side IBAN).
5. **GOV-01** — enforce budget in `portal_recurring_run`.

## Conditions to clear before real go-live (owner/config, from `PRODUCTION_BLOCKERS.md`)
6. Enable Supabase leaked-password protection; decide MFA/SSO for finance/admin (SEC-02).
7. Apply System-1 storage hardening Phase 1 + confirm `/api/reg-doc` `{ok:true}` (SEC-05, and see SEC-06).
8. Configure enterprise data: real committee members, GA/LOG managers, jobs, users (high-value PO chains cannot complete otherwise).
9. Decide and flip governance enforcement flags per launch plan (OPS-01).
10. Confirm Supabase PITR tier + documented RTO/RPO; add an external audit-chain anchor (AUD-01).
11. Independent gates: browser E2E pass of new converter panels (Codex review is now done — findings incorporated).

## Sign-off
On the audited code and database evidence **plus the independent Codex review**, System 3 is **NOT READY** for real
(non-dummy) production use: two verified HIGH code defects (AUTHZ-01, SEC-06) and several MEDIUM governance gaps remain.
The workflow engine itself is sound; once the must-fix items are remediated and re-tested, re-certification to READY
WITH CONDITIONS is expected. This certification covers static + database evidence, the automated suite, and the Codex
review; it does not substitute for a dynamic web pen-test and browser E2E, which remain release gates. Systems 1 and 2
were reviewed only for isolation (confirmed); System 1's `reg-doc.js` (SEC-06) is the one shared surface flagged here.

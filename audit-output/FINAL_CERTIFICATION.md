# FINAL CERTIFICATION — Al-Deyabi Procurement & Disbursement Portal (System 3)

**Certification status: `READY WITH CONDITIONS` (rev 2 — 2026-07-28, after Codex review + owner-directed remediation)**

Audited artifact: branch `audit/enterprise-certification-2026-07-27` (base `main` @ `b9d9d6d`, portal migrations `022→059`).
Auditor: Claude, combined Principal Engineer / Architect / AppSec / DevSecOps / DB / Procurement / QA / SRE / Production-Readiness roles.
Date: 2026-07-27; revised 2026-07-28. Evidence basis: static review + live database inspection (read-only) + automated assertion suite (EXIT 0) + independent Codex review of PR #74.

---

## ⚠️ Revision history (2026-07-28)
**Rev 1** downgraded the (overstated) first issue to **NOT READY** after an independent Codex review confirmed two HIGH
code defects and several MEDIUM/LOW corrections — each re-verified against the source.
**Rev 2 (this document):** after owner direction, the blocking items were **remediated and re-tested**, raising the
verdict back to **READY WITH CONDITIONS**:
- **AUTHZ-01 (HIGH) → FIXED** (migration `060`): `portal_create_expense` now binds the department to the caller
  (mirrors `portal_create_request`; admin may cross-department per owner decision, non-admin forced to own). Test 36.
- **SEC-06 (HIGH) → server path improved; end-to-end STILL OPEN** (corrected by 2nd Codex pass): `reg-doc.js` had its
  destructive cleanup removed + explicit allowlist, **but the endpoint is not "inert"** — `register.html` falls back to
  a **direct anonymous Storage upload** on 503/404/network-error that bypasses the allowlist + `_file-guard`, and that
  is the **live** path while the service key is unset. This is an **open HIGH for System-1 registration** (go-live
  blocker). Consolidated gate: set key → remove anon fallback → revoke anon Storage writes → add credential → verify
  live policy. (The client-side destructive delete was also removed this audit.)
- **GOV-01 (MED) → FIXED** (`060`): `portal_recurring_run` now enforces budget (skips over-budget templates when
  `budget_enforce=1`). Test 36.
- **SEC-07 (admin SoD) and SEC-03 (manual IBAN) → OWNER-ACCEPTED** decisions, documented (admin stays superuser with
  recommended compensating controls; manual IBAN entry retained).
- **AUD-01 (LOW)** audit-truncation gap remains documented.

## What "READY WITH CONDITIONS" means here
The workflow engine is sound and well-tested, and the two blocking HIGH defects are remediated (one fully, one's
destructive vector removed with a documented residual). **No open HIGH code defect remains.** The conditions before
real go-live are: apply migration `060` live; complete the SEC-06 credential upgrade (paired with System-1 storage
hardening) before enabling the service key; the owner-config gates in `PRODUCTION_BLOCKERS.md`; and the still-pending
browser E2E. The owner-accepted items (SEC-07, SEC-03) are risks the owner has explicitly chosen to carry.

## Category scores (0–5; 5 = enterprise-grade, evidence-backed)

| Category | Score | Basis |
|---|---|---|
| Authentication | 3.5 | Supabase Auth + email-matched profiles; **leaked-password protection off (SEC-02)**, MFA/SSO not enforced — owner config. |
| Authorization / RLS | 4 | Deny-by-default writes verified; request-scoped reads for non-admins; **AUTHZ-01 cross-department expense FIXED (060)**; SEC-01 anon grants fixed (059). |
| Segregation of Duties | 3.5 | Triple separation holds for **non-admins** (tests 26/27/32); **admins are SoD-exempt by owner decision (SEC-07, accepted)** with recommended compensating controls. |
| Financial integrity | 4.5 | Payment ≤ award caps, split/installment caps, idempotency (051), saga void (051), three-way match (033); **recurring budget FIXED (GOV-01/060)**; manual-IBAN retained by owner decision (SEC-03). |
| Auditability | 4 | Append-only + SHA256 hash-chain detects in-place edits (057) — **does not detect truncation/suffix-deletion (AUD-01, LOW, documented)**; external anchor recommended. |
| Data protection (PII/IBAN) | 3.5 | Payment/supplier IBANs finance/procurement-gated; beneficiary IBANs readable by `can_create` and manual entry retained (SEC-03, owner-accepted). |
| Reliability / workflows | 4 | Durable in-DB state machine, transactional outbox (029), `FOR UPDATE` locking; email full-durability activation pending (OPS-02). |
| Test / CI | 4.5 | 177 SQL + 18 file-guard + 6 endpoint assertions (incl. new AZ1–3/GOV1–2), CI on every portal PR; **no browser E2E** (INFO-04); prior vacuous AH1 test fixed. |
| Observability / DR | 2.5 | Health endpoints + loud failure logs; **backup/PITR tier + RTO/RPO not in repo** — NOT VERIFIABLE. |
| Frontend correctness | 2.5 | Converter panels syntax-verified only; **not browser-tested** — remains a release gate; API matrix inventory now complete. |
| API security review | 3.5 | Portal endpoints JWT/token-gated; **SEC-06 destructive vector FIXED (reg-doc.js)** — residual credential upgrade (SEC-06-R, MEDIUM) is a go-live condition; inventory now complete. |

## Findings roll-up (open)
**BLOCKER 0 · CRITICAL 0 · HIGH 1** (SEC-06, System-1 registration) **· MEDIUM 2 · LOW 3 · INFORMATIONAL 3**, plus **2 owner-accepted** (SEC-07, SEC-03). System-3's own code has **0 open HIGH**.
Fixed this audit: SEC-01 (059), **AUTHZ-01 (060)**, **GOV-01 (060)**, **SEC-06 destructive+allowlist (reg-doc.js)**, and
two audit-accuracy defects. Remaining MEDIUM: SEC-06-R (reg-doc credential upgrade — go-live condition) and SEC-02
(leaked-password — owner config). Full detail in `FINDINGS.md`.

## Done this revision (code)
1. **AUTHZ-01 — FIXED** (migration `060`): department bound to caller in `portal_create_expense` + test 36.
2. **SEC-06 — destructive vector FIXED** (`reg-doc.js`): removed delete-existing cleanup; explicit doc-type allowlist.
3. **GOV-01 — FIXED** (`060`): budget enforced in `portal_recurring_run` + test 36.
4. **SEC-07 / SEC-03 — OWNER-ACCEPTED** and documented (admin superuser; manual IBAN retained).

## Conditions to clear before real go-live
1. ~~Apply migration `060` live~~ **DONE 2026-07-28** — applied & verified on `mwbjoysuybgbrvfrprex` (rolled-back proof: cross-dept expense rejected).
2. **SEC-06 (System-1 registration, HIGH) — single consolidated gate before enabling registration for real suppliers:** (a) set `SUPABASE_SERVICE_ROLE_KEY`; (b) **remove the anonymous browser fallback** in `register.html`; (c) run `db/system1-storage-hardening.sql` to **revoke anonymous Storage writes**; (d) add a real upload credential to `reg-doc.js` (SEC-06-R); (e) verify the live Storage policy denies anon writes. Until done, the guard-bypassing anonymous upload path is live.
3. Enable Supabase leaked-password protection; decide MFA/SSO for finance/admin (SEC-02).
4. Apply System-1 storage hardening Phase 1 + confirm `/api/reg-doc` `{ok:true}` (SEC-05).
5. Configure enterprise data: real committee members, GA/LOG managers, jobs, users (high-value PO chains cannot complete otherwise).
6. Decide and flip governance enforcement flags per launch plan (OPS-01).
7. Confirm Supabase PITR tier + documented RTO/RPO; add an external audit-chain anchor (AUD-01).
8. Browser E2E pass of the new converter panels (Codex source review is done — findings incorporated).

## Sign-off
On the audited code and database evidence, the independent Codex review, and the owner-directed remediation, **System 3
is READY WITH CONDITIONS** — its own code has **no open HIGH** (AUTHZ-01/GOV-01 fixed, tested, applied live). Separately,
**System-1 registration carries an open HIGH (SEC-06)**: the anonymous browser upload fallback bypasses the file guard
and is live while the service key is unset — a go-live blocker for the supplier-registration surface until the
consolidated gate (set key → remove fallback → revoke anon Storage writes → add credential → verify) is complete. This
certification covers static + database evidence, the automated suite (177 SQL + 24 JS, EXIT 0), and the
Codex review; it does not substitute for a dynamic web pen-test and browser E2E, which remain release gates. Systems 1
and 2 were reviewed only for isolation (confirmed); System 1's `reg-doc.js` is the one shared surface touched here.

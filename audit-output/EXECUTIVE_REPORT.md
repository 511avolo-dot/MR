# EXECUTIVE REPORT — Procurement & Disbursement Portal Certification

**Audience:** owner / non-technical stakeholders. **Bottom line (revised 2026-07-28):** the workflow engine is solid,
but an independent review found **two serious code issues that must be fixed before real users and money go live**, plus
a few controls the first review described too favorably. Verdict is now **NOT READY** until those are fixed.

## One-paragraph verdict
The Al-Deyabi procurement and disbursement portal (System 3) was put through a rigorous, evidence-based audit, then a
**second independent review (Codex)** which deliberately tried to disprove the first review's conclusions. That was the
right thing to do: it found real problems the first pass had missed or described too generously. The core engine — how
requests flow, get approved, and are paid — is well-built and well-tested. **But two "high" severity code defects were
confirmed:** (1) a regular user can start a payment against **another department's** budget, and (2) a
supplier-document upload web address accepts files **without any login** and can delete a supplier's existing documents.
Several "separation of duties" and "budget" protections were also found to have exceptions the first report did not
disclose. Because of the two high-severity items, the honest status is **"Not Ready"** until they are fixed and
re-tested — not merely pending owner setup.

## What was checked, in plain terms (corrected)
- **Can someone approve their own payment, or pay without approval?** For **normal users, no** — the system enforces
  three different people across request, approval, and execution. **However, an "admin" user is exempt from these
  checks** and could do all three alone. This must be disclosed and decided (limit admins, or add monitoring).
- **Can a regular user spend against another department?** **Yes — this is a real defect** (direct-expense creation does
  not check the user's own department). Must be fixed.
- **Can a low-level user read everyone's bank details?** Partly: supplier and payment IBANs are limited to
  finance/procurement, **but the separate "beneficiaries" list (with IBANs) is readable by any user who can create a
  request.** Also, a "manual entry" option lets a requester type any IBAN, bypassing the approved-beneficiary check.
- **Can spending exceed the approved amount?** Payments are capped to the approved award (verified). **But** budget
  limits are **not enforced** on automatically-generated recurring expenses.
- **Can the audit log be tampered with?** In-place edits are detectable (cryptographic chaining). **But** deleting the
  end of the log, or all of it, is **not** currently detected — an external checkpoint is recommended.
- **Does the code pass its own tests?** Yes — 195 automated checks pass with zero failures. (One of those tests was
  found to be ineffective and was fixed during this review so it now actually catches the regression it claims to.)

## Must-fix (code) before go-live
1. Bind direct expenses to the requester's own department.
2. Require a real login on the supplier-document upload endpoint and stop it from deleting existing files.
3. Decide the admin exception to separation-of-duties (and disclose it).
4. Require an approved beneficiary for bank payments (don't allow free-typed IBANs).
5. Enforce budget limits on recurring expenses.

## Owner setup (unchanged) before go-live
6. Turn on leaked-password protection; decide two-factor login for finance/admin.
7. Apply the supplier-registration storage lock-down (owner script) — tied to item 2.
8. Enter real organizational data (committee, managers, jobs, staff) — large POs can't complete without a committee.
9. Choose which budget/IBAN/invoice/contract controls to switch on.
10. Confirm the backup/disaster-recovery plan.
11. A hands-on click-through of the new screens in a browser (still pending).

## Risk statement
There **are** now code-level reasons not to deploy yet: a cross-department spending path and an unauthenticated,
delete-capable upload endpoint. Both are fixable with targeted changes. Until then, do not onboard real users or money.

## Recommendation
Fix the five must-fix items, re-run the tests, then complete the owner setup and the browser click-through. Re-certify
afterward. Full technical detail is in `TECHNICAL_REPORT.md` and `FINDINGS.md`.

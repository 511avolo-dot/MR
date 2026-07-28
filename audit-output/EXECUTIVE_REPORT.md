# EXECUTIVE REPORT — Procurement & Disbursement Portal Certification

**Audience:** owner / non-technical stakeholders. **Bottom line (rev 2, 2026-07-28):** an independent review found two
serious code issues; **both have now been fixed and re-tested**, so the status is back to **"Ready with Conditions"** —
a short list of setup steps and one follow-up remain before real users and money go live.

## One-paragraph verdict
The portal was put through a rigorous audit, then a **second independent review (Codex)** that deliberately tried to
disprove the first review's conclusions — which was the right thing to do, and it found real problems the first pass had
missed or described too generously. Two "high" severity issues were confirmed: (1) a regular user could start a payment
against **another department's** budget, and (2) a supplier-document upload address accepted files **without a login**
and could **delete** a supplier's existing documents. **Both are now fixed:** the expense now stays within the user's
own department, and the upload address no longer deletes anything and only accepts a fixed list of document types. Two
lesser points were **your explicit decisions** (admins keep full override; typing a bank IBAN by hand stays allowed) —
both documented. One follow-up remains on the upload address (adding a proper login token) before its server key is
switched on. Net status: **Ready with Conditions.**

## What was checked, in plain terms (corrected)
- **Can someone approve their own payment, or pay without approval?** For **normal users, no** — the system enforces
  three different people across request, approval, and execution. **However, an "admin" user is exempt from these
  checks** and could do all three alone. This must be disclosed and decided (limit admins, or add monitoring).
- **Can a regular user spend against another department?** **No longer — fixed.** Direct expenses are now tied to the
  creator's own department (admins may still choose any, by your decision).
- **Can a low-level user read everyone's bank details?** Supplier and payment IBANs are limited to finance/procurement.
  The separate "beneficiaries" list (with IBANs) is readable by anyone who can create a request, and typing an IBAN by
  hand stays allowed — **both are your accepted decisions**, documented.
- **Can spending exceed the approved amount?** Payments are capped to the approved award (verified). Budget limits are
  **now also enforced** on automatically-generated recurring expenses (**fixed**).
- **Can the audit log be tampered with?** In-place edits are detectable (cryptographic chaining). Deleting the end of
  the log is not yet detected — an external checkpoint is recommended (low priority, documented).
- **Does the code pass its own tests?** Yes — 200 automated checks pass with zero failures (including new tests for the
  two fixes). One earlier test was found ineffective and was corrected so it now actually catches its regression.

## Fixed this revision (code)
1. Direct expenses bound to the creator's own department (was the cross-department defect).
2. Supplier-document upload no longer deletes existing files, and only accepts a fixed list of document types.
3. Budget limits enforced on recurring expenses.

## Your accepted decisions (documented)
- Admins keep full override of separation-of-duties (recommend ≥2 admins + monitoring of admin financial actions).
- Manual IBAN entry stays available for direct expenses.

## Remaining conditions before go-live
1. Apply the new database migration (060) to the live database.
2. Add a proper login token to the supplier-upload endpoint **before** its server key is switched on.
3. Turn on leaked-password protection; decide two-factor login for finance/admin.
4. Apply the supplier-registration storage lock-down (owner script).
5. Enter real organizational data (committee, managers, jobs, staff).
6. Choose which budget/IBAN/invoice/contract controls to switch on; confirm backup/disaster-recovery.
7. A hands-on click-through of the new screens in a browser (still pending).

## Risk statement
The two high-severity code issues are fixed and re-tested, so there is **no known high-severity code reason to block**.
Remaining risk is operational (the conditions above) plus the two decisions you have chosen to accept.

## Recommendation
The blocking code issues are fixed. Apply migration 060 live, complete the upload-endpoint login token, finish the owner
setup and the browser click-through, then proceed to onboarding. Full technical detail is in `TECHNICAL_REPORT.md` and
`FINDINGS.md`.

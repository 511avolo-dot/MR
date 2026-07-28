# EXECUTIVE REPORT — Procurement & Disbursement Portal Certification

**Audience:** owner / non-technical stakeholders. **Bottom line:** the system's code is ready; a short list of
owner setup steps remains before real users and money go live.

## One-paragraph verdict
The Al-Deyabi procurement and disbursement portal (System 3) was put through a rigorous, evidence-based audit covering
security, financial controls, workflow correctness, data protection, and operational readiness. **No serious defect was
found in the code.** The controls that matter for a company handling real purchase orders and payments — who can approve
what, separation of duties so no one person can both request and pay, spending caps, a tamper-proof audit trail, and
protection of bank details — are all present and were verified against the live database and an automated test suite that
passes cleanly. The system is **certified "Ready with Conditions."** The conditions are **setup and policy decisions the
owner controls**, not programming fixes.

## What was checked, in plain terms
- **Can someone approve their own payment, or pay without approval?** No — the system enforces at least three different
  people across request, approval, and execution. Verified.
- **Can a low-level user read everyone's data or bank IBANs?** No — bank details are limited to finance/procurement, and
  each user sees only their own department's requests. One leftover technical grant was found and **fixed during the audit**.
- **Can spending exceed what was approved?** No — payments are capped to the approved award, including split-supplier and
  installment cases. Verified.
- **Can the audit log be tampered with, even by a database administrator?** The log is now cryptographically chained, so
  tampering is detectable. Verified.
- **Does the code pass its own tests?** Yes — 194 automated checks pass with zero failures, and they run automatically on
  every change.

## The conditions before real go-live (owner actions, not code)
1. **Turn on leaked-password protection** in the Supabase dashboard, and decide on two-factor login for finance/admin.
2. **Apply the supplier-registration storage lock-down** (an owner-run script) — the code side is already safe.
3. **Enter real organizational data** — the approval committee, general/logistics managers, jobs, and staff accounts.
   Large purchase orders cannot complete until the committee is configured.
4. **Choose which spending controls to switch on** (budget limits, IBAN-change approval, invoice matching, contract
   ceilings). These shipped off-by-default for a safe rollout.
5. **Confirm the backup/disaster-recovery plan** with the hosting provider.
6. **Two independent reviews:** a second automated code review (handoff prepared) and a hands-on click-through of the new
   screens in a browser.

## Risk statement
There is **no known code-level reason not to deploy**. The residual risk is operational: shipping before the owner
completes the setup above would mean some governance controls are not yet enforcing and high-value approvals cannot
complete. Those are controllable and clearly documented.

## Recommendation
Proceed toward launch. Close the six conditions in `PRODUCTION_BLOCKERS.md`, complete the two independent reviews, then
onboard real users. Full technical detail is in `TECHNICAL_REPORT.md` and `FINDINGS.md`.

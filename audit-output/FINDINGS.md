# FINDINGS — Enterprise Certification Audit (2026-07-27, rev. 2026-07-28 post-Codex)

Sorted by severity. Confidence: VERIFIED / HIGHLY LIKELY / POSSIBLE / NOT VERIFIABLE.

> **Revision note (2026-07-28).** An independent Codex review of PR #74 surfaced several defects this audit had
> **understated or overstated**. Each was re-verified against the source and is incorporated below. Net effect: the
> earlier "0 HIGH" claim was wrong — there are **2 HIGH** code defects. Certification downgraded (see FINAL_CERTIFICATION).

Summary counts: **BLOCKER 0 · CRITICAL 0 · HIGH 2 · MEDIUM 5 · LOW 3 · INFORMATIONAL 3**.
Fixed this audit: SEC-01 (059, verified) + two audit-accuracy defects (assertion breakdown; AH1 now actually pins the revoke).

---

## HIGH

### AUTHZ-01 — `portal_create_expense` does not bind the expense to the caller's department — **VERIFIED**
- Severity: HIGH · Confidence: VERIFIED (`db/portal-standalone.sql`, `portal_create_expense`)
- Process: Authorization / cross-department (horizontal privilege)
- Evidence: the function validates only that `p_department_id` **exists** (`IF p_department_id IS NULL OR NOT EXISTS (SELECT 1 FROM portal_departments …)`); it never compares it against the caller's profile/scope. Contrast `portal_create_request`, which derives the department from the caller. Any `can_create` user can submit `p_department_id` for **another** department, routing the expense through that department's approval chain, visibility, and budget.
- Impact: cross-department spend initiation and budget consumption; contradicts the "authorization model is sound" claim.
- Remediation: derive the department from the caller (or reject when `p_department_id` is outside `portal_my_scope()`), mirroring `portal_create_request`. Test: a `can_create` user in dept A is rejected/normalized when passing dept B.
- Status: OPEN (code fix required; owner-scope decision — see REMEDIATION_REGISTER).

### SEC-06 — `functions/api/reg-doc.js` is an unauthenticated, destructive public write path — **VERIFIED**
- Severity: HIGH · Confidence: VERIFIED (`functions/api/reg-doc.js`)
- Process: System-1 storage / authentication
- Evidence: the only gate is `sameOrigin()` — a check of the `origin`/`referer`/`host` headers, which are **forgeable by any non-browser client**. No caller credential is required. On success the handler uploads with the **service-role key** and then **deletes** every existing object under `${regId}/${doc}/` as "stale". `DOC_RE` (`^[a-z][a-z0-9_]{1,24}$`) is a broad pattern, not a real allowlist.
- Impact: anyone reaching the endpoint can consume service-role-backed storage and, if a real `reg_id`+`doc` is known, overwrite/delete a supplier's genuine registration documents. My API matrix mischaracterized this as "server-key-authenticated … allowlist" — that was wrong.
- Mitigating (current): returns `503 not_configured` while `SUPABASE_SERVICE_ROLE_KEY` is unset in prod, so it is presently inert — but the path is unsafe once the key is configured.
- Remediation: require a real credential (signed token / authenticated session); make cleanup non-destructive or scoped; replace the regex with an explicit doc-type allowlist. Pair with `db/system1-storage-hardening.sql` before real supplier onboarding.
- Status: OPEN (code fix required).

---

## MEDIUM

### SEC-07 — Administrators are exempt from all segregation-of-duties checks — **VERIFIED**
- Severity: MEDIUM · Confidence: VERIFIED (`portal_pr_transition`/`portal_payment_transition`: `AND NOT portal_is_admin()` at the requester≠approver, stage-eligibility, and requester/approver/executor checks; `portal_has_perm` returns true for admins on every key)
- Process: Segregation of duties
- Evidence: because every SoD guard is suppressed for `role='admin'` and admins hold all permissions, **one admin can create a direct expense, approve its entire chain, and execute the payment.** The earlier certification scored SoD 5/5 as "universal triple separation" — overstated; separation binds **non-admins only**.
- Whether intended: admin-as-superuser is common, but for a financial-controls certification it must be disclosed. Recommend removing the admin bypass on **payment execution** specifically, or a compensating control (≥2 admins, admin-action monitoring/alerting, admins excluded from routine operational roles).
- Status: OPEN (disclosed; policy decision).

### SEC-03 — Beneficiary bank details: manual-IBAN entry bypasses the vetted-beneficiary control — **VERIFIED (corrected)**
- Severity: MEDIUM · Confidence: VERIFIED
- Process: Payments / fraud control
- Evidence: `portal_create_expense`'s `p_beneficiary_id` is optional; when null, the bank branch validates only the IBAN **format** (`^SA\d{22}$`) and accepts any client-supplied IBAN — the UI exposes this as "manual entry." The earlier finding claimed "the RPC already enforces the vetted IBAN"; that holds **only** when `p_beneficiary_id` is supplied. A requester can thus pay a bank account that never passed the beneficiary master or its IBAN-change approval.
- Also: `portal_beneficiaries` SELECT policy includes `can_create` (4/15 users), so beneficiary IBANs are readable by every requester (data-minimization gap).
- Remediation: for `bank` expenses, require an approved `p_beneficiary_id` (at least when `iban_change_control=1`); expose names-only in the picker and resolve IBAN server-side. Status: OPEN (design decision).

### GOV-01 — Recurring generation bypasses budget enforcement — **VERIFIED**
- Severity: MEDIUM · Confidence: VERIFIED (`portal_recurring_run`)
- Process: Budget control
- Evidence: the generator `INSERT`s into `portal_requests` and calls `portal_build_chain` directly, **without** `portal_create_expense` or a `portal_budget_committed` vs `portal_budgets` check. So even with `budget_enforce=1`, an over-budget recurring expense is still generated. The TECHNICAL_REPORT budget claim is corrected to exclude the recurring path.
- Remediation: apply the same budget check in `portal_recurring_run` (or route generation through `portal_create_expense`). Status: OPEN.

### SEC-02 — Leaked-password protection disabled (Supabase Auth)
- Severity: MEDIUM · Confidence: VERIFIED (advisor). Owner action — enable in Dashboard; decide MFA/SSO for finance/admin. Status: OPEN (owner config).

### SEC-01 — Residual `anon` table-SELECT grants — **FIXED (059)**
- Severity: MEDIUM (defense-in-depth) · Confidence: VERIFIED. `REVOKE … FROM anon` + explicit `GRANT … TO authenticated` on users/payments/suppliers/beneficiaries; applied live, verified `anon=false`/`authenticated=true`. Test `35_anon_hardening.sql` now **seeds the grants, applies 059, and asserts removal** (AH0/AH1/AH2) so it genuinely pins the revoke (Codex correctly noted the prior test was vacuous in clean CI). Regression risk: none.

---

## LOW

### AUD-01 — Hash-chain does not detect truncation/suffix deletion — **VERIFIED (corrected)**
- Confidence: VERIFIED. `portal_audit_verify()` recomputes only the rows that remain, so deleting a valid **suffix** (or the whole chain) returns `ok:true`; HC3 proves middle-row **mutation** detection only. The WORM/tamper-evident claim is qualified: it detects in-place edits, not deletion/truncation. Recommend an externally-anchored checkpoint (periodic signed head-hash + expected row count). Status: OPEN (documented).

### SEC-04 — `portal_users` / `portal_settings` readable by all authenticated (`auth_all USING(true)`)
- Confidence: VERIFIED. Design choice; exposes emails + permission map + committee membership to any logged-in user. Scope the directory read if malicious insiders are in the threat model. Not fixed (broad blast radius).

### SEC-05 — System-1 storage hardening pending owner apply
- Confidence: HIGHLY LIKELY. `db/system1-storage-hardening.sql` Phase 1 closes the historically-open `supplier-docs` bucket; owner-run. Fix reg-doc auth (SEC-06) as part of the same effort.

---

## INFORMATIONAL

### INFO-05 — API security matrix was an incomplete endpoint inventory — **FIXED**
Codex correctly noted the matrix omitted `admin-users.js`, `ai.js`, `invite-supplier.js`, `portal-signup.js`, `portal-supplier-invite.js`, `verify.js`, and listed the helper `_pr-shared.js` as if a handler. `API_SECURITY_MATRIX.md` is corrected to inventory every handler and mark helpers as such.

### INFO-01 — 94 SECURITY DEFINER functions executable by `authenticated`
Intended RPC surface; each internally guarded (JWT identity, SoD for non-admins, perm checks). S7/S8 pin the server-only set (16). No action.

### INFO-02/03/04 — deny-by-default write policies + server-only tables + dynamic/load/E2E not executed
36 `always_true` write policies re-gated by `*_guard` triggers (verified present); 5 server-only RLS-no-policy tables (correct); load/chaos/browser-E2E remain NOT VERIFIABLE — see CODEX_HANDOFF and UNRESOLVED_ITEMS.

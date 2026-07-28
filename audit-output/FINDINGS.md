# FINDINGS — Enterprise Certification Audit (2026-07-27, rev. 2026-07-28 post-Codex)

Sorted by severity. Confidence: VERIFIED / HIGHLY LIKELY / POSSIBLE / NOT VERIFIABLE.

> **Revision note (2026-07-28).** An independent Codex review of PR #74 surfaced defects this audit had understated or
> overstated; each was re-verified against the source. **Rev 2 (same day):** after owner direction, the two HIGH items
> were **remediated in code** (migration `060` + `reg-doc.js`) and two MEDIUM items are **owner-accepted decisions**.
> Net: **0 open HIGH**; verdict raised back to READY WITH CONDITIONS (see FINAL_CERTIFICATION).

Summary counts (open): **BLOCKER 0 · CRITICAL 0 · HIGH 0 · MEDIUM 2 · LOW 3 · INFORMATIONAL 3** · plus **2 owner-accepted** (SEC-07, SEC-03).
Fixed this audit: SEC-01 (059) · **AUTHZ-01 (060)** · **GOV-01 (060)** · **SEC-06 destructive-delete + allowlist (reg-doc.js)** · audit-accuracy defects (assertion breakdown; AH1 now pins the revoke).

---

## HIGH — none open (both remediated 2026-07-28)

### AUTHZ-01 — `portal_create_expense` cross-department write — **FIXED (060)**
- Was HIGH · Confidence: VERIFIED (fix + test)
- Evidence (original): the function validated only that `p_department_id` **exists**, never against the caller's scope, so any `can_create` user could raise an expense against another department's chain/budget.
- Fix: migration `060` binds the department to the caller exactly as `portal_create_request` (admin may specify any department per owner decision; non-admin is forced to their own — no fall-through to client input). Test `36_authz_expense_recurring_budget.sql` (AZ1 cross-dept rejected, AZ2 own-dept allowed, AZ3 admin cross-dept allowed). Suite EXIT 0. **Applied live 2026-07-28 + verified** (rolled-back behavioral proof: demo_emp_ops OPS→GA rejected).
- Status: FIXED in repo; live-apply pending.

### SEC-06 — `reg-doc.js` unauthenticated/destructive write — **PARTIALLY FIXED (reg-doc.js); residual MEDIUM**
- Was HIGH · Confidence: VERIFIED
- Evidence (original): only a forgeable `sameOrigin()` gate; service-role upload then **deleted** existing files under `${regId}/${doc}/`; `DOC_RE` was a broad regex.
- Fix (this audit): **removed the destructive cleanup entirely** (unique random filenames only — no overwrite/delete vector) and **replaced the regex with an explicit allowlist** (`{cr,vat,gosi,iban,address}`). This closes the worst part (destruction of a supplier's genuine documents).
- **Residual (MEDIUM, see below):** the endpoint still lacks a real caller credential — once `SUPABASE_SERVICE_ROLE_KEY` is set, an attacker (forgeable same-origin) could still *additively* upload guard-passing files under a known `reg_id`. Currently inert (`503` while key unset). Full credential/token auth requires a change to the registration flow (register.html inserts via anon with no server step to mint a token) and live testing — tracked as a go-live condition paired with `db/system1-storage-hardening.sql`.
- Status: destructive + allowlist FIXED; credential upgrade OPEN (MEDIUM, go-live condition).

---

## MEDIUM (open)

### SEC-06-R — `reg-doc.js` still has no caller credential (residual) — **OPEN**
- Severity: MEDIUM · Confidence: VERIFIED. Additive-only now (non-destructive), inert until the service key is configured. Remediation: mint a per-registration signed token in the registration flow (server-side), or require an authenticated session; enforce before accepting the upload. Go-live condition.

### SEC-02 — Leaked-password protection disabled (Supabase Auth)
- Severity: MEDIUM · Confidence: VERIFIED (advisor). Owner action — enable in Dashboard; decide MFA/SSO for finance/admin. Status: OPEN (owner config).

---

## OWNER-ACCEPTED (documented decisions, 2026-07-28)

### SEC-07 — Administrators are exempt from all segregation-of-duties checks — **ACCEPTED**
- Confidence: VERIFIED (`AND NOT portal_is_admin()` at the requester/stage/executor checks; `portal_has_perm` admin-true ⇒ one admin can create+approve+execute a payment).
- **Owner decision: keep admin as full superuser.** Documented as an accepted risk. Recommended compensating controls: keep ≥2 admins, exclude admins from routine operational roles, and monitor/alert on admin financial actions. Not a code change.

### SEC-03 — Manual-IBAN entry bypasses the vetted beneficiary — **ACCEPTED**
- Confidence: VERIFIED (`p_beneficiary_id` optional; null ⇒ any format-valid client IBAN accepted).
- **Owner decision: keep manual IBAN entry available** for direct expenses. Documented as accepted risk (`iban_change_control` still governs the beneficiary master; the picker path enforces the vetted IBAN when a beneficiary is selected). Also note `portal_beneficiaries` SELECT includes `can_create` (data-minimization) — left as-is per this decision.

### GOV-01 — Recurring generation bypassed budget enforcement — **FIXED (060)**
- Was MEDIUM · Confidence: VERIFIED (fix + test). `portal_recurring_run` now checks `portal_budget_committed` vs `portal_budgets` per template before creating; with `budget_enforce=1` an over-budget template is **skipped** (advance `next_run` + WARNING) instead of generating an over-budget request; `=0` warns only. Test `36` GOV1/GOV2. Applied live 2026-07-28 (migration 060 registered + function body verified).

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

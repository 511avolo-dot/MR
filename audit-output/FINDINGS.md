# FINDINGS — Enterprise Certification Audit (2026-07-27, rev. 2026-07-28 post-Codex)

Sorted by severity. Confidence: VERIFIED / HIGHLY LIKELY / POSSIBLE / NOT VERIFIABLE.

> **Revision note (2026-07-28).** An independent Codex review of PR #74 surfaced defects this audit had understated or
> overstated; each was re-verified against the source. **Rev 2:** after owner direction, AUTHZ-01/GOV-01 were fixed
> (migration `060`, applied live) and SEC-07/SEC-03 are owner-accepted. **Rev 3 (2026-07-28, 2nd Codex pass):** Codex
> correctly showed SEC-06 is **not "inert"** — `register.html` falls back to a **guard-bypassing anonymous Storage
> upload**, which is the **live** path while the service key is unset. SEC-06 is therefore an **open HIGH for System-1
> registration** (go-live blocker), corrected below. System-3's own code has 0 open HIGH.

Summary counts (open): **BLOCKER 0 · CRITICAL 0 · HIGH 1** (SEC-06 — System-1 registration) **· MEDIUM 2 · LOW 3 · INFORMATIONAL 3** · plus **2 owner-accepted** (SEC-07, SEC-03).
Fixed this audit: SEC-01 (059) · **AUTHZ-01 (060, live)** · **GOV-01 (060, live)** · SEC-06 **server-path** destructive-delete + allowlist (`reg-doc.js`) + client-fallback destructive-delete removed · **reg-doc allowlist corrected to real form doc IDs** · **061 (live): active-department check, budget advisory-lock (TOCTOU), unrounded budget precision, live beneficiary refresh, skip-audit** · audit-accuracy defects (assertion breakdown; AH1 now runs the real 059 artifact).

---

## HIGH — 1 open (SEC-06, System-1 registration); AUTHZ-01 remediated

### AUTHZ-01 — `portal_create_expense` cross-department write — **FIXED (060)**
- Was HIGH · Confidence: VERIFIED (fix + test)
- Evidence (original): the function validated only that `p_department_id` **exists**, never against the caller's scope, so any `can_create` user could raise an expense against another department's chain/budget.
- Fix: migration `060` binds the department to the caller exactly as `portal_create_request` (admin may specify any department per owner decision; non-admin is forced to their own — no fall-through to client input). Test `36_authz_expense_recurring_budget.sql` (AZ1 cross-dept rejected, AZ2 own-dept allowed, AZ3 admin cross-dept allowed). Suite EXIT 0. **Applied live 2026-07-28 + verified** (rolled-back behavioral proof: demo_emp_ops OPS→GA rejected).
- Status: FIXED in repo; live-apply pending.

### SEC-06 — Registration-document upload is unauthenticated; the browser falls back to a guard-bypassing anonymous Storage write — **SERVER PATH improved; end-to-end NOT fail-closed (HIGH, go-live blocker for System-1 registration)**
- Severity: HIGH (System-1 registration) · Confidence: VERIFIED (`functions/api/reg-doc.js` + `register.html:2934–2975`)
- Evidence (original): the server endpoint's only gate is a forgeable `sameOrigin()`; it uploaded with the service-role key and **deleted** existing files under `${regId}/${doc}/`; `DOC_RE` was a broad regex.
- Server-path fix (this audit): removed the destructive cleanup (unique filenames only) and replaced the regex with an explicit allowlist. Client-side destructive delete in the fallback also removed (this audit). **Round-2 correction:** the allowlist was fixed to the real form doc IDs `{cr,vat,gosi,chamber,natl_addr,iban_cert,municipal,quality,safety,clients,brochure}` — the prior `{…,iban,address}` set omitted required docs and would have broken registration.
- **⚠️ Corrected by Codex (VERIFIED): the endpoint is NOT "inert" while the key is unset.** `register.html.uploadDocViaServer` **falls back to a direct anonymous Supabase Storage upload** (`SB.storage.from('supplier-docs').upload(...)`, lines 2962–2974) on `503 not_configured`, `404`, **or any network error**. Because `SUPABASE_SERVICE_ROLE_KEY` is currently unset in production, **this anonymous fallback is the live path today** — and it **bypasses the server allowlist and `_file-guard` entirely** (the client-side check is trivially skippable by calling Storage directly), writing to the historically-open `supplier-docs` bucket. So SEC-06 is a **live exposure**, not dormant; my earlier "inert" characterization was wrong.
- Consolidated remediation (**credential-first**, single atomic gate — corrected per Codex: enabling the key *before* a credential just swaps the anon fallback for a credential-free service-role endpoint): (1) **implement + verify a real upload credential/token in `reg-doc.js` (SEC-06-R)** — safe while the key is unset (endpoint returns 503); (2) **atomic cutover:** deploy the authenticated endpoint **and** set `SUPABASE_SERVICE_ROLE_KEY` **and** remove the anonymous browser fallback in `register.html` **and** run `db/system1-storage-hardening.sql` to revoke anonymous Storage writes; (3) **live-verify both**: a properly-credentialed upload succeeds, and an anon direct-Storage write / a no-credential endpoint call are denied. Ties directly to SEC-05. Also: `reg-doc.js` allowlist was corrected this round to the real form doc IDs (`cr,vat,gosi,chamber,natl_addr,iban_cert` + optional `municipal,quality,safety,clients,brochure`) — the prior `{…,iban,address}` set would have 400'd required uploads and broken registration.
- Status: server path improved; **end-to-end OPEN — System-1 registration go-live blocker** until the consolidated gate above is complete.

---

## MEDIUM (open)

### SEC-06-R — `reg-doc.js` still has no caller credential (residual of SEC-06) — **OPEN**
- Severity: MEDIUM · Confidence: VERIFIED. Even after the anon fallback is removed and Storage writes are locked down, the server endpoint authenticates only by a forgeable same-origin header. Remediation: mint a per-registration signed token in the registration flow (server-side), or require an authenticated session; enforce before accepting the upload. Part of the SEC-06 consolidated gate.

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

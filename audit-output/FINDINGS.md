# FINDINGS — Enterprise Certification Audit (2026-07-27)

Sorted by severity. Confidence: VERIFIED / HIGHLY LIKELY / POSSIBLE / NOT VERIFIABLE.

Summary counts: **BLOCKER 0 · CRITICAL 0 · HIGH 0 · MEDIUM 3 · LOW 4 · INFORMATIONAL 4**.
One MEDIUM/LOW defense-in-depth item (SEC-01) was **fixed and verified** this audit (migration 059).

---

## BLOCKER — none
No authentication bypass, authorization bypass, cross-tenant/cross-supplier exposure, financial-integrity failure, workflow bypass, secret exposure, or destructive-migration risk was verified. See TECHNICAL_REPORT for the positive evidence behind each.

## CRITICAL — none

## HIGH — none

---

## MEDIUM

### SEC-01 — Residual `anon` table-SELECT grants on PII/financial tables — **FIXED (059)**
- Severity: MEDIUM (defense-in-depth) · Confidence: VERIFIED
- Process: Authorization / data exposure
- Evidence: live `has_table_privilege('anon','portal_payments','SELECT')=true` (also users/suppliers/beneficiaries). Supabase default grant.
- Why not higher: **RLS already denies all rows to anon** (SELECT policies are `authenticated`-only with permission predicates), and there is **no anon code path** reading these tables (`loadAll()` is gated by `if(!session)`; supplier pages use RPCs). So no live data leak — only an unnecessary grant / larger surface.
- Fix: `db/portal-migrations/059-revoke-anon-sensitive-reads.sql` — `REVOKE SELECT … FROM anon` + explicit `GRANT SELECT … TO authenticated`. Test `db/portal-tests/35_anon_hardening.sql` (AH1 anon has none; AH2 authenticated retains). Applied live; verified `anon=false`, `authenticated=true`.
- Regression risk: none (authenticated independent of anon — verified `pg_auth_members`).

### SEC-02 — Leaked-password protection disabled (Supabase Auth)
- Severity: MEDIUM · Confidence: VERIFIED (advisor `auth_leaked_password_protection`)
- Process: Authentication
- Impact: users may set passwords known in breach corpora (HaveIBeenPwned).
- Remediation: **owner action** — enable in Supabase Dashboard → Auth → Password protection. No code change. Also recommend MFA/SSO for finance/admin roles (not yet enforced).
- Status: OPEN (owner config).

### SEC-03 — Beneficiary bank details readable by all `can_create` holders
- Severity: MEDIUM · Confidence: VERIFIED
- Process: Payments / data minimization
- Evidence: `portal_beneficiaries` SELECT policy includes `portal_has_perm('can_create')` (4/15 active users). Beneficiary IBANs are therefore visible to every requester, unlike `portal_suppliers` (finance/procurement only).
- Why intentional-but-flagged: the direct-expense form's beneficiary picker (053 UI) needs the list for `can_create` users. Tightening the policy would break that feature.
- Recommendation (not auto-fixed, to avoid breaking the feature without owner sign-off): expose **names only** to `can_create` and fetch/enforce IBAN server-side on selection (the RPC already enforces the vetted IBAN — the UI display is the only place the full IBAN leaks). Documented for owner decision.
- Status: OPEN (design decision).

---

## LOW

### SEC-04 — `portal_users` / `portal_settings` readable by all authenticated (`auth_all USING(true)`)
- Confidence: VERIFIED. Design choice (config/user directory public-read to authenticated). Exposes emails + permission map + committee membership to any logged-in user, aiding internal reconnaissance. Recommend scoping the directory read (e.g., self + same-department + admin) if the threat model includes malicious insiders. Not fixed (broad blast radius; used widely by the UI).

### OPS-01 — Gradual-enforcement flags shipped dormant (default 0)
- Confidence: VERIFIED. `budget_enforce`, `iban_change_control`, `disb_gate_purchase`, `three_way_enforce`, `contract_enforce`, `txn_notifications` are all 0 in production. This is **intentional and safe** (no behavior change), but it means several governance controls are **not currently enforcing**. Owner must flip them per the launch plan. Documented so it is not mistaken for “active.”

### OPS-02 — Transactional-notification full activation is a two-step owner task
- Confidence: VERIFIED. Migration 058 makes stage notifications durable but is dormant; full activation requires `txn_notifications=1` **and** removing the `pa_notify` stage-approval calls to avoid double email. Until then, workflow email remains fire-and-forget (029/P1 partially open by design).

### SEC-05 — System-1 storage hardening pending owner apply
- Confidence: HIGHLY LIKELY (from repo state). `db/system1-storage-hardening.sql` (Phase 1) closes the historically-open `supplier-docs` bucket but is an owner-run script; the frontend already fails safe (server upload + `_file-guard`, 503 fallback). Confirm applied before real supplier onboarding.

---

## INFORMATIONAL

### INFO-01 — 94 SECURITY DEFINER functions executable by `authenticated`
Intended: the entire portal RPC surface. Each is internally guarded (identity from JWT, SoD, perm checks). S7/S8 tests pin the server-only set (16). No action.

### INFO-02 — 36 `always_true` write policies
Intended deny-by-default pattern: writes are re-gated by `*_guard` BEFORE triggers (verified present on all such tables). No action; documented so a future reviewer does not “fix” the policies and thereby disable RPC writes.

### INFO-03 — 5 RLS-enabled tables with no policy (server-only)
`portal_email_tokens`, `portal_outbox`, `portal_idempotency`, `portal_invitations`, `portal_supplier_tokens` — deliberately server-only (no client access). Correct.

### INFO-04 — Load / chaos / full browser-E2E not executed
Environment cannot run production-scale load tests, browser automation of the new converter panels, or provider-outage chaos. Marked NOT VERIFIABLE; see UNRESOLVED_ITEMS and CODEX_HANDOFF for the second-reviewer plan.

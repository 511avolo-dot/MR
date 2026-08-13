# REMEDIATION REGISTER

## P0-1l — Final independent exact-head review remediation (2026-08-03)
- **Fresh-review follow-up (P0-1n):** exact-head review of `f8254fb134` found
  that the generic raw-request helper widened direct-expense rows to ordinary
  stage approvers and that the guarded deploy payload stopped at 062. P0-1n
  retains the broad operational predicate only for purchase requests and keeps
  direct-expense raw rows finance/procurement/disbursement-only; a non-finance
  approver regression receives the redacted RPC feed but zero raw rows.
  `scripts/deploy/supabase-push.mjs` now adds an explicit
  `apply-remediations` phase containing the ordered, versioned, SHA-pinned
  P0-1b…P0-1n chain and fails closed if the pending set differs.
- **P0-1n Staging:** rollback transaction passed, then migration
  `20260803125546_p0_1n_direct_expense_raw_read_boundary` was applied only on
  `vpfnycxzqziltsnzxbpb`. Production and migration 063 remain untouched.
- **Clean-install follow-up (P0-1m):** the first exact-head CI run exposed that
  the deterministic baseline lacked `authenticated` table-level `SELECT` on
  the raw child tables. P0-1m grants read only; P0-1l RLS remains the
  authoritative row boundary. This preserves privileged workflows and lets a
  fresh install exercise requester denial through RLS rather than failing at
  the table privilege layer. Staging already had all seven grants; the
  idempotent lineage migration
  `20260803123153_p0_1m_clean_install_raw_read_grants` was applied only on
  `vpfnycxzqziltsnzxbpb`. Migration 063 remains absent.
- **Scope:** seven findings raised by the independent review of exact head
  `1b334dc81a7b55048176954de3adeb74a0a9c38a`; migration 063 remains absent.
- **R2 destructive-operation identity:** cleanup requires a fixed, non-secret
  staging-only sentinel through the actual `QUOTES_BUCKET` binding before any
  list/delete. The sentinel was created only in `aldeyabi-quotes-staging`.
- **Requester purchase privacy:** raw request, item, approval, receipt, PO/award
  approval, audit and purchase-document metadata are restricted to effective
  operational roles. Requester UI now consumes `portal_my_purchase_dossiers()`
  and reconstructs only the explicitly nonfinancial client projection.
- **Evidence rollback:** `expense_docs_required=0` is no longer supported; the
  server setting is forced to 1, submission is unconditionally evidence-gated,
  the legacy create RPC always returns a document-required draft, and the UI no
  longer advertises an off state.
- **Legacy duplicate keys:** P0-1i now detects every repeated pre-receipt 062
  storage key, preserves all rows as inactive audit history with deterministic
  quarantine keys, and only then creates the unique index. A pre-P0-1i fixture
  proves the full clean-install path.
- **Cleanup lifecycle:** only unconsumed and unexpired upload receipts preserve
  an object; consumed/expired receipts no longer leak deleted document objects.
- **Exact deployment evidence:** `portal-config` exposes the Cloudflare build
  commit and hosted smoke must match it to the exact PR-head SHA. Both workflows now
  include `_portal-shared.js` in path filters.
- **Staging:** transactional P0-1l + six SQL regressions passed with rollback and
  zero QA residue; permanent migration
  `20260803121401_p0_1l_final_independent_review_remediation` was applied only to
  `vpfnycxzqziltsnzxbpb`. Post-check: evidence setting 1, anon helper execution
  false, five restricted raw-child policies present.
- **Local verification:** cleanup 9/9, functional security contract 17/17,
  Stage-1 60/60, document authorization 7/7, syntax and diff checks passed.
  Local Playwright was not counted because its Chromium binary is absent; the
  exact-head CI browser job remains required.
- **Advisor state:** 96 security entries (7 INFO / 89 WARN) and 30 performance
  INFO. The two new authenticated `SECURITY DEFINER` boolean helpers are used by
  RLS and remain part of the binding signature-by-signature review gate.
- **Pending exact-head evidence:** final CI, Preview deployment, responses and
  resolution for the seven review threads, then a fresh independent review.
  Verdict remains **NOT READY FOR PRODUCTION**.

## P0-1k — Independent exact-head review remediation (2026-08-03)
- **Scope:** six findings raised by the independent review of PR #74 at
  `c2859f0805b90b79dddce4fe76aa35588c59a39f`; implementation commit
  `87eb93e2d82b1b8c607be92783432243cc7a04d2`. Migration 063 remains absent.
- **Direct-payment evidence:** new direct-payment inserts lock and require an
  active, receipt-verified, unlinked `payment_request` document, copy only its
  trusted proof metadata, and atomically link the document to the new payment.
- **In-flight reconciliation:** verified historical direct-expense documents
  are classified as `payment_request`; an `in_review` chain without that
  evidence is returned and audited instead of remaining runnable. Staging
  reconciled 2 requests; the post-check found 0 runnable invalid chains.
- **Requester privacy:** `portal_safe_visible_payments()` now returns only
  payment ID, request ID and status (all amounts, kinds, custody, actors,
  timestamps, comments and quarantine fields are `NULL`).
- **Recovery:** finance/admin can attach a fresh receipt-backed normalized
  payment-request document through `portal_recover_legacy_payment_evidence`;
  `anon` execution is revoked and the portal exposes the same controlled path.
- **Cloudflare:** bounded R2 cleanup returns/accepts an opaque continuation
  cursor across invocations. Return documents use a separate read class so
  in-scope finance readers are authorized without widening GRN access.
- **Staging application:**
  `20260803112523_p0_1k_independent_review_remediation`, only on
  `vpfnycxzqziltsnzxbpb`.
- **Verification:** transactional Staging migration + 10 regression assertions
  passed with rollback before application; Stage-1 60/60; cleanup 7/7;
  document authorization 7/7; functional contract 15/15. Exact implementation
  CI `portal-tests` run `30809867192` (#194) and hosted smoke `30809867118`
  (#25) passed. Cloudflare Preview deployment
  `9d5d1fa6-3ac3-418e-84b4-ef4d822e5f73` succeeded at the implementation
  commit. All six independent-review threads were answered with evidence and
  resolved.
- **Advisor state:** 94 security entries (7 INFO / 87 WARN) and 31 performance
  INFO. The new recovery RPC is intentionally `SECURITY DEFINER` but performs
  effective-role, request-scope, payment-state and fresh-receipt checks; the
  broader signature-by-signature advisor review remains a binding release gate.
- **Rollback:** do not remove or relabel linked evidence. If a forward defect is
  discovered, revoke the recovery RPC and payment-transition RPCs, keep affected
  payments/requests returned or quarantined, and deploy a reviewed forward fix.
- **Remaining:** authenticated hosted multi-role E2E, legacy missing-object/QA
  reconciliation, credential-rotation evidence, leaked-password protection,
  full advisor disposition, fresh review of the final exact head, and explicit
  owner release authorization. Verdict remains **NOT READY FOR PRODUCTION**.

## P0-1j — Fresh exact-head review remediation (2026-08-03)
- **Scope:** eight current findings on PR #74 starting at `a7d770a`; no migration 063.
- **Files:** `p0_1j-exact-head-review-remediation.sql`, `portal-doc.js`,
  `portal-upload-cleanup.js`, `purchase-portal.html`, SQL/JS tests and audit evidence.
- **Staging application:** `20260803093553_p0_1j_exact_head_review_remediation`
  plus index follow-up `20260803093756_p0_1j_upload_receipt_fk_index`, only on
  `vpfnycxzqziltsnzxbpb`.
- **Verification:** 13 rollback-safe SQL assertions on staging; 14 functional
  contract checks; 5 document-authorization checks; 5 cleanup checks; Stage-1 60/60; browser fixture 6/6;
  file guard 18/18 and registration endpoint 7/7. Exact-head CI run
  `30806576478` passed 256 SQL + 18 + 7, with full baseline proof; hosted smoke
  run `30806576369` passed.
- **Rollback:** restore the pre-P0-1j staging snapshot. Do not drop evidence,
  verification, or quarantine columns in place; that would destroy audit state.
- **Cloudflare/R2:** exact-head Preview deployed; explicit cleanup configuration
  is present. Five proven orphan objects deleted, seven referenced objects
  preserved. One missing legacy quote object and pre-existing QA residue remain.
- **Remaining:** authenticated hosted E2E, legacy data reconciliation, advisor
  triage/password and credential-rotation evidence, fresh independent review.

## SEC-01 — Revoke residual anon SELECT on PII/financial/identity tables
- **Finding ID:** SEC-01 (MEDIUM, defense-in-depth)
- **Root cause:** Supabase grants table-level SELECT to `anon` by default on new tables; RLS was the only control removing rows. The grant itself was unnecessary (no anon read path).
- **Files changed:** `db/portal-migrations/059-revoke-anon-sensitive-reads.sql` (new); merged block appended to `db/portal-standalone.sql`; `db/portal-tests/35_anon_hardening.sql` (new); `db/portal-tests/run.sh` (wired, count → 171).
- **Migration:** 059 (idempotent). Applied live to `mwbjoysuybgbrvfrprex` via `apply_migration`.
- **Tests added:** `35_anon_hardening.sql` — AH1 (anon has no SELECT on users/payments/suppliers/beneficiaries), AH2 (authenticated retains SELECT; no regression).
- **Commands executed:** `bash db/portal-tests/run.sh` → EXIT 0 (AH1/AH2 PASS); `apply_migration`; `execute_sql` verification.
- **Test results:** local suite EXIT 0; live verify `anon_*=false`, `auth_*=true` on all four tables.
- **Regression risk:** none — verified `authenticated` does not inherit `anon` (`pg_auth_members`) and holds direct grants; the migration re-affirms the authenticated grant explicitly.
- **Rollback guidance:** `GRANT SELECT ON portal_users, portal_payments, portal_suppliers, portal_beneficiaries TO anon;` (restores prior state). RLS would still deny rows.
- **Remaining limitations:** does not change RLS (already correct). `portal_settings` intentionally left with its authenticated read (used pre-scope by UI); revisit under SEC-04 if insider threat is in scope.

## Audit-accuracy defects fixed after Codex review (2026-07-28)
- **Assertion count** — headline "189/194" corrected; per-file breakdown in `run.sh` corrected (11_security 8, 26_disbursement 10). After adding test 36, the suite is **203 assertions (178 SQL + 18 file-guard + 7 endpoint)**.
- **Vacuous AH1 test** — `35_anon_hardening.sql` now **seeds** the four `anon` SELECT grants, applies 059, then asserts removal (AH0/AH1/AH2), so it genuinely pins the revoke. Suite EXIT 0.
- **Documentation honesty** — FINDINGS / FINAL_CERTIFICATION / EXECUTIVE / TECHNICAL / PRODUCTION_BLOCKERS / API_SECURITY_MATRIX / README rewritten to verdict **NOT READY** with the verified findings below.

## Code defects — resolution after owner direction (2026-07-28)
| ID | Severity | Resolution |
|----|----------|-----------|
| AUTHZ-01 direct-expense department binding | HIGH | **FIXED** — migration `060`: department bound to caller (admin any / non-admin own). Test 36 (AZ1–3). Applied live 2026-07-28 + verified (rolled-back proof). |
| SEC-06 reg-doc destructive write | HIGH | **PARTIALLY FIXED** — `reg-doc.js`: destructive cleanup removed (unique filenames), explicit doc-type allowlist. **Residual SEC-06-R (MEDIUM):** credential/token upgrade is a go-live condition (registration-flow change + live test). |
| GOV-01 recurring budget bypass | MEDIUM | **FIXED** — `060`: budget enforced in `portal_recurring_run` (skips over-budget templates when enforce=1). Test 36 (GOV1–2). Applied live 2026-07-28 + verified (rolled-back proof). |
| SEC-07 admin SoD exemption | MEDIUM | **OWNER-ACCEPTED** — admin stays superuser. Documented + recommended compensating controls (≥2 admins, monitoring). No code change. |
| SEC-03 manual-IBAN bypass | MEDIUM | **OWNER-ACCEPTED** — manual IBAN entry retained. Documented. No code change. |
| AUD-01 audit truncation | LOW | OPEN (documented) — add an external head-hash checkpoint; design + owner sign-off. |

## Items NOT auto-remediated (owner/config-gated, unchanged)
| ID | Reason not auto-fixed |
|----|----------------------|
| SEC-02 leaked-password protection | Supabase Dashboard toggle — no code. |
| SEC-04 user/settings directory read | Broad blast radius across the UI; needs owner decision on insider-threat model. |
| OPS-01/OPS-02 dormant flags | Intentional gradual-enforcement; owner flips per launch plan. |
| SEC-05 System-1 storage policies | Owner-run SQL. **Correction (2nd Codex pass):** the frontend does **not** fail safe — `register.html` falls back to a direct anonymous Storage upload (bypassing the guard) when the server endpoint is unconfigured/unreachable. This anon write path is live until the SEC-06 consolidated gate (set key + remove fallback + revoke anon Storage writes + credential) is done. Tightly coupled with SEC-06. |

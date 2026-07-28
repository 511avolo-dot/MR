# CODEX HANDOFF — Independent Review Package

> **STATUS (2026-07-28): the Codex source-code review is COMPLETE.** Codex reviewed PR #74 and filed 11 findings; each
> was re-verified against the source and incorporated (see `FINDINGS.md`). Confirmed: 2 HIGH (AUTHZ-01 cross-department
> expense, SEC-06 unauthenticated `reg-doc`), 4 MEDIUM/LOW (SEC-07 admin-SoD, SEC-03 manual-IBAN, GOV-01 recurring
> budget, AUD-01 audit truncation), plus test/inventory accuracy fixes. **The verdict is now NOT READY.** What remains
> for a second reviewer is the **dynamic** work below (PostgREST replay, financial-boundary probing, concurrency,
> flag-flip in a scratch DB, and browser E2E) — none of which has passed yet. The "claims requiring verification" list
> below is retained as the static-review checklist Codex used; items 1–7 are now **confirmed by Codex's source review**,
> so treat them as the dynamic re-test targets, not open questions.

## Repository state
- **Branch:** `audit/enterprise-certification-2026-07-27`
- **Base commit:** `b9d9d6d` (merged `main`, includes portal migrations 022→058)
- **Audit changes on top:** migration `059` + test `35_anon_hardening.sql` + `run.sh` wiring + `standalone` merge + this `audit-output/` package.
- **Files added:** `db/portal-migrations/059-revoke-anon-sensitive-reads.sql`, `db/portal-tests/35_anon_hardening.sql`, `audit-output/*`.
- **Files modified:** `db/portal-standalone.sql` (059 block), `db/portal-tests/run.sh`.
- **Files deleted:** none.
- **Migrations added:** `059` (applied live, idempotent, reversible).

## Commands to reproduce
```bash
# DB assertion suite (PostgreSQL 16). Local cluster on socket dir /home/postgres/pt:5455, or a CI postgres container:
PGHOST=/home/postgres/pt PGPORT=5455 PGUSER=postgres bash db/portal-tests/run.sh      # expect EXIT 0
#   CI form: PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres bash db/portal-tests/run.sh
# File-guard + reg-doc endpoint tests (Node):
node db/portal-tests/file-guard.test.mjs
# JS integrity:
for f in functions/api/*.js; do node --check "$f"; done
```
No frontend build system (static HTML + Cloudflare Pages Functions). No `package.json` test runner; validation is the SQL assertion suite + node `--check` + the mjs guard test. CI workflow: `.github/workflows/portal-tests.yml`.

## Claims requiring independent verification
1. **Write deny-by-default holds for every open-write table.** I verified guard *triggers exist* live and that the local suite proves guards *deny* non-privileged writes. Codex should independently attempt direct PostgREST writes as a low-priv `authenticated` JWT against `portal_payments`, `portal_award`, `portal_requests`, `portal_offers` and confirm rejection.
2. **Financial read-gating.** `portal_payments`/`portal_suppliers` IBANs are gated to finance/procurement with request visibility (policy text inspected). Codex should confirm a plain `can_create` user cannot read another department's payment IBANs via PostgREST.
3. **SEC-01 fix.** anon SELECT revoked live on 4 tables; authenticated retained. Reproduce with `has_table_privilege`.
4. **Audit hash-chain (057).** `portal_audit_verify()` detects DBA-level tampering (test HC3 uses `session_replication_role=replica`). Codex should independently tamper a row and confirm detection, and confirm the chain is per-global-order with an advisory lock (no fork under concurrency).
5. **SoD triple-separation on disbursement** (requester ≠ approver(s) ≠ executor) — tests 26/27/32; challenge with same-user-holds-multiple-perms cases.
6. **Payment ≤ award caps, split per-supplier caps, installment caps** — tests 24/26/27 and standalone; challenge rounding edges.
7. **Supplier public-link scope** — `portal_supplier_rfq` returns only the caller's own offer; token single-purpose, phase-gated, upload-capped (049). Challenge for competitor-offer leakage and post-closure submission.

## High-risk / late changes
- **Migration 059** (authorization grant change) — applied live this audit. Reversible.
- Everything under 049→058 was applied live in prior sessions; 058 (`txn_notifications`) and the enforcement flags are **dormant** (flag=0) — verify they do not change behavior until flipped.
- Converter UI panels (beneficiary/supplier-IBAN/reports/voucher/recurring) are **syntax-verified only**, not browser-tested — a likely place for real defects (rendering, event wiring, permission gating in the UI). **Prioritize a browser E2E pass here.**

## Unresolved questions
- Backup/PITR tier, RTO/RPO — not in repo.
- Actual email deliverability + no-double-send when `txn_notifications` is activated — needs a live Resend run.
- Performance at scale (indexes exist per 041; no load test executed).
- Full System-2 (`index.html`/`proc_*`) was treated as out-of-scope/unchanged; not re-audited here beyond isolation confirmation.

## Suggested Codex attack plan (where to challenge me)
- **Authorization:** replay each portal RPC with a JWT that has *no* relevant permission and with a *different-department* identity; assert deny. Focus on `portal_payment_transition`, `portal_pr_transition`, `portal_bulk_transition`, `portal_award_split`, `portal_create_expense`, `portal_recurring_run` (service-only).
- **Financial edges:** thresholds at `25000 / 150000 / 250000 / 500000` exactly and ±1; split awards where line sums vs dominant offer diverge; installment sum == award ± rounding; three-way tolerance boundary.
- **Concurrency:** two approvers on the same stage; double `disburse` with and without `p_idem_key`; concurrent audit inserts (chain fork).
- **Supplier links:** brute-force token space (43 chars), expired token, cross-request key upload, post-`pricing` submission.
- **UI-vs-backend drift:** any action the new converter panels expose that the backend does *not* actually enforce (dead controls) — historically a real defect class in this repo (e.g., prior `confirmDeleteUser`, `p_return_to='award'`).
- **Dormant-flag correctness:** flip each enforcement flag in a scratch DB and confirm the guard actually blocks.

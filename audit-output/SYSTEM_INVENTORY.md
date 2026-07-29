# SYSTEM INVENTORY — audited surface (System 3 primary)

> **Freshness:** updated at head `0316c68` (Stage 0). Supersedes the earlier "022→059 / 203 assertions / ~40 tables"
> snapshot. Authoritative status/reconciliation lives in `MASTER_DELIVERY_LEDGER.md`.

## Deployment topology
- **Frontend:** static HTML on Cloudflare Pages (`purchase-portal.html` ~6.2k LOC; `register.html`, `index.html`,
  `requests.html`, `rfq.html`, `supplier-quote.html`, `register-portal.html`, invite pages). No Node build system.
- **Backend:** Cloudflare Pages Functions `functions/api/*` — **19 endpoints + 3 shared modules** (`_portal-shared.js`,
  `_pr-shared.js`, `_file-guard.js`). System-3-specific: `portal-notify/action/invite/supplier-invite/doc/quote/
  supplier-doc/users/config/outbox-drain`, `reg-doc`. See `API_SECURITY_MATRIX.md`. **`portal-config.js` is new**
  (env-aware fail-closed config; production project no longer embedded in `purchase-portal.html`).
- **Database:** Supabase Postgres — System 3 project `mwbjoysuybgbrvfrprex` (`portal_*`); Systems 1&2 project
  `yofcaxvstjcrmbgciwym` (`proc_*`/`pr_*`). Physically isolated (separate projects + `PORTAL_SUPABASE_*` vs `SUPABASE_*`).
- **Email:** Resend, domain `suppliers.aldeyabi.com`. **All three systems currently share `RESEND_API_KEY`/
  `NOTIFY_FROM`/`NOTIFY_REPLY_TO`/`PUBLIC_ORIGIN`** (see `EMAIL_ARCHITECTURE_AND_CUTOVER.md`; isolation = E1+).
- **Scheduling:** Cloudflare Cron Worker → `portal-outbox-drain` (outbox delivery **+ SLA + recurring, coupled** —
  E2 decoupling pending; owner keeps email legacy for now, `txn_notifications=0`).

## Data model (portal_*, **35 tables**)
Core: `portal_requests`, `portal_request_items`, `portal_approvals` (cycle-aware), `portal_po_approvals`,
`portal_offers`/`portal_offer_items`, `portal_award`/`portal_award_lines`, `portal_payments`, `portal_receipts`,
`portal_returns`, `portal_supplier_invoices`. Governance: `portal_budgets`, `portal_contracts`, `portal_currencies`,
`portal_beneficiaries`, `portal_recurring_expenses`. Identity/config: `portal_users`, `portal_jobs`,
`portal_departments`, `portal_doa`, `portal_workflows`, `portal_settings`, `portal_suppliers`. Integrity/infra:
`portal_audit` (hash-chained), `portal_outbox`, `portal_idempotency`, `portal_notifications`, `portal_email_tokens`,
`portal_invitations`, `portal_supplier_tokens`, IBAN-change tables. RLS enabled on all; write model deny-by-default.

## Migrations
`db/portal-migrations/*` through **062**, all merged into `db/portal-standalone.sql` for clean install (next free
number = **063**). **Live-apply status — G0-01 CLOSED (live `list_migrations` on `mwbjoysuybgbrvfrprex`, 2026-07-29):** **059, 060, 061
applied live; 062 absent (NOT applied)**; next free 063. See `MIGRATION_HISTORY_RECONCILIATION.md`. 062 verified to
apply cleanly + idempotently over `portal-standalone.sql` locally. No apply without separate owner authorization on
isolated staging. Objects in standalone at this head: **35 tables · 171 functions · 27 triggers · 30 policies.**
New subsystem (062): `portal_request_documents` (normalized, immutable, versioned supporting evidence).

## Tests / CI
`db/portal-tests/`: `run.sh` orchestrates `00_roles.sql` + assertion files `10`→`37` (SQL) + `file-guard.test.mjs`
(Node) + reg-doc endpoint assertions. **222 assertions (197 SQL + 18 file-guard + 7 endpoint), EXIT 0** (incl.
`37_request_documents.sql` DD1–DD19). `.github/workflows/portal-tests.yml` on every
portal-touching PR (PostgreSQL 16 container).

## Environment variables (names only)
`PORTAL_SUPABASE_URL`, `PORTAL_SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
`RESEND_API_KEY`, `NOTIFY_FROM`, `PUBLIC_ORIGIN`, `CRON_SECRET`. No values recorded; anon keys are public by design.

## Trust boundaries
1. Browser ↔ Supabase (anon key + RLS) — reads only, row-scoped.
2. Browser ↔ Pages Functions (JWT/admin/token) — privileged actions.
3. Pages Functions ↔ Supabase (service key) — server-only writes/tokens.
4. Public supplier links (DB-verified tokens) — upload-only, scope from DB.
5. Cron ↔ drain endpoint (`CRON_SECRET`).

## Operations & release
- Release: feature branch → PR (CI green) → owner approval → cherry-pick to `main`. Migrations applied live via MCP +
  `list_migrations`/`get_advisors` verification. This audit did **not** touch `main`.
- Observability: `/api/notify` + `/api/portal-notify` GET health (boolean checks), loud misconfig logs, hash-chain
  verify RPC, outbox dead-letter. **Backup/PITR + RTO/RPO not in repo (NV-05).**
- Rollback: migrations idempotent; 059 reversible (`GRANT … TO anon`). Standalone kept in sync for clean rebuild.

_For architecture and control evidence see `TECHNICAL_REPORT.md`; for scenarios see `BUSINESS_SCENARIO_MATRIX.md`._

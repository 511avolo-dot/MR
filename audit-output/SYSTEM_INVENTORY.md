# SYSTEM INVENTORY — audited surface (System 3 primary)

## Deployment topology
- **Frontend:** static HTML on Cloudflare Pages (`purchase-portal.html` ~6.0k LOC; `register.html`, `index.html`,
  `supplier-quote.html`, `register-portal.html`, others). No Node build system.
- **Backend:** Cloudflare Pages Functions in `functions/api/*` (20 endpoints). See `API_SECURITY_MATRIX.md`.
- **Database:** Supabase Postgres — System 3 project `mwbjoysuybgbrvfrprex` (`portal_*`); Systems 1&2 project
  `yofcaxvstjcrmbgciwym` (`proc_*`/`pr_*`). Physically isolated (separate projects + env vars).
- **Email:** Resend, domain `suppliers.aldeyabi.com`.
- **Scheduling:** Cloudflare Cron Worker → `portal-outbox-drain` (outbox delivery + SLA + recurring).

## Data model (portal_*, ~40 tables)
Core: `portal_requests`, `portal_request_items`, `portal_approvals` (cycle-aware), `portal_po_approvals`,
`portal_offers`/`portal_offer_items`, `portal_award`/`portal_award_lines`, `portal_payments`, `portal_receipts`,
`portal_returns`, `portal_supplier_invoices`. Governance: `portal_budgets`, `portal_contracts`, `portal_currencies`,
`portal_beneficiaries`, `portal_recurring_expenses`. Identity/config: `portal_users`, `portal_jobs`,
`portal_departments`, `portal_doa`, `portal_workflows`, `portal_settings`, `portal_suppliers`. Integrity/infra:
`portal_audit` (hash-chained), `portal_outbox`, `portal_idempotency`, `portal_notifications`, `portal_email_tokens`,
`portal_invitations`, `portal_supplier_tokens`, IBAN-change tables. RLS enabled on all; write model deny-by-default.

## Migrations
59 files `db/portal-migrations/*` (022→059 relevant to this audit), all merged into `db/portal-standalone.sql` for
clean install. 059 is new this audit (SEC-01). Live migration list verified via `list_migrations`.

## Tests / CI
`db/portal-tests/`: `run.sh` orchestrates `00_roles.sql` + assertion files `10`→`35` (SQL) + `file-guard.test.mjs`
(Node) + reg-doc endpoint assertions. 195 assertions (172 SQL + 18 file-guard + 5 endpoint), EXIT 0. `.github/workflows/portal-tests.yml` on every
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

# ARTIFACT INVENTORY (Gate-0 blocker G0-03)

One row per concrete artifact, source-verified at head `bdf0972`. Columns: **Artifact/path · System (1/2/3/shared) · Purpose · Caller/entry · AuthN/AuthZ boundary · Data touched · R/W · Env/binding dependency · Test coverage · Gaps/ledger IDs.**
Counts: **11 HTML pages · 19 API endpoints + 3 shared modules · 35 `portal_*` tables · 171 functions · 27 triggers · 30 policies · 2 storage buckets · 1 scheduled job.**

> Test-type codes: SRC=static · SQL=assertion · EP=endpoint/Node · E2E=browser(none) · CONC=concurrency(none) · LIVE=live config.

## A. Frontend pages (11)
| Path | Sys | Purpose | Entry | AuthN/AuthZ | Data | R/W | Binding | Tests | Gaps |
|---|---|---|---|---|---|---|---|---|---|
| `purchase-portal.html` | 3 | portal SPA (requests/approvals/procurement/payments/documents/admin) | browser | Supabase Auth (portal_users) | all `portal_*` via RLS/RPC | R/W | `/api/portal-config` (env-aware) | SRC (script parse) | S10-* UI mandate; BOOT-STATES |
| `supplier-quote.html` | 3 | supplier RFQ quote (token identity) | token link | anon + token RPC | `portal_supplier_*`, offers | R/W | **embeds prod ref (SUPPLIER-ENV open)** | SRC | SUPPLIER-ENV |
| `register-portal.html` | 3 | portal user self-register (invite token) | invite link | token | `portal_invitations`, users | W | `PORTAL_SUPABASE_*` | SRC | — |
| `register.html` | 1 | supplier registration | public | anon | `proc_supplier_registrations`, Storage | R/W | `SUPABASE_*`, `supplier-docs` | SRC | **SEC-06 anon Storage fallback (P0)** |
| `index.html`,`requests.html`,`rfq.html` | 2 | procurement main | browser | Supabase Auth | `proc_*`/`pr_*` | R/W | `SUPABASE_*` | — | isolation only |
| `invite.html`,`portal-quote-suite.html`,`supplier-invitation-*.html` | 2/3 | invite/quote helper pages | link | varies | varies | R | varies | — | inventory-only |

## B. API endpoints (Cloudflare Pages Functions, 19 + 3 shared)
| Path | Sys | Purpose | Method/entry | AuthN/AuthZ | Data | R/W | Binding | Tests | Gaps |
|---|---|---|---|---|---|---|---|---|---|
| `portal-config.js` | 3 | env-aware config (fail-closed) | GET | public (anon key only) | none | R | `PORTAL_SUPABASE_URL/ANON`, `CF_PAGES_BRANCH`/`PORTAL_ENV` | SRC (guard self-test) | — |
| `portal-notify.js` | 3 | immediate workflow email | POST (same-origin+JWT) | portal user; mode gate (target) | `portal_requests`/approvals | R | `RESEND_API_KEY`(shared), `PORTAL_SUPABASE_*` | SRC | E3 mode enforcement |
| `portal-action.js` | 3 | one-click email approval | GET (token) | email token | approvals | R/W | `RESEND_API_KEY`, `PUBLIC_ORIGIN` | SRC | ROUTE-EMAIL-PARITY |
| `portal-doc.js` | 3 | upload/preview evidence (pay/grn/inst/inv/ret/disb/reqdoc) | POST/GET (JWT) | perm per kind + `portal_can_see_request` + reqdoc ownership | `portal_request_documents`, R2 | R/W | `QUOTES_BUCKET`, `PORTAL_SUPABASE_*` | EP (file-guard) | **DOC-RECEIPT (P0)** |
| `portal-doc.js` GET | 3 | inline blob preview | GET | JWT + row-exists + can_see | R2 | R | `QUOTES_BUCKET` | EP | — |
| `portal-users.js` | 3 | admin user mgmt (create/delete/suspend) | POST (JWT admin) | admin + last-admin guard | `portal_users` | R/W | `PORTAL_SUPABASE_*` | SRC | S4-* |
| `portal-invite.js` | 3 | portal invite email | POST (JWT admin) | admin | `portal_invitations` | W | `RESEND_API_KEY` | SRC | E1 bindings |
| `portal-supplier-invite.js` | 3 | RFQ supplier invite | POST (JWT) | `can_manage_procurement` | `portal_supplier_tokens` | W | `RESEND_API_KEY`, `PUBLIC_ORIGIN` | SRC | S7-RFQ |
| `portal-supplier-doc.js` | 3 | supplier upload (token) | POST (token) | server token verify; reqId from DB | R2 `quotes/…` | W | `QUOTES_BUCKET` | EP (file-guard) | — |
| `portal-quote.js` | 3 | quote PDF upload/view | POST/GET (JWT) | request visibility (fail-closed) | R2 | R/W | `QUOTES_BUCKET` | EP | — |
| `portal-outbox-drain.js` | 3 | **scheduled: SLA + recurring + email drain** | GET/POST (CRON_SECRET) | shared secret (query+header) | `portal_outbox`, run_sla, recurring | R/W | `CRON_SECRET`, `RESEND_API_KEY` | SRC | **SCHED-DECOUPLE**, CRON-SECRET |
| `portal-register.js`,`portal-signup.js` | 3 | portal register/signup backend | POST | token/gate | `portal_users` | W | `PORTAL_SUPABASE_*` | SRC | naming (portal-signup) |
| `reg-doc.js` | 1 | server-side registration upload (file-guard) | POST | origin + reg_id allowlist | `supplier-docs` | W | `SUPABASE_SERVICE_ROLE_KEY` | EP (7 assertions) | depends SEC-06 |
| `notify.js`,`verify.js`,`invite-supplier.js`,`admin-users.js`,`pr-action.js` | 1/2 | legacy email/verify/admin/PR-action | POST/GET | legacy | `proc_*`/`pr_*` | R/W | `SUPABASE_*`, `RESEND_API_KEY` | SRC | preserve (OWN-SYS12) |
| `ai.js` | ? | (inventory: verify usage/ownership) | — | — | — | — | — | — | **classify (unknown owner — flag)** |
| `_portal-shared.js` | 3 | portal email/util module | import | — | — | — | `NOTIFY_FROM/REPLY_TO/PUBLIC_ORIGIN/RESEND_API_KEY`(shared) | SRC | E1 |
| `_pr-shared.js` | 2 | legacy PR email module | import | — | — | — | `SUPABASE_*`, `RESEND_*` | — | preserve |
| `_file-guard.js` | shared | magic-byte/polyglot/active-content guard | import | — | — | — | — | EP (18) | — |

## C. Database tables (35)
Transaction: `portal_requests` · `portal_request_items` · `portal_request_documents`(062) · `portal_approvals`(cycle) · `portal_po_approvals` · `portal_award` · `portal_award_approvals` · `portal_award_lines` · `portal_offers` · `portal_offer_items` · `portal_payments` · `portal_receipts` · `portal_returns` · `portal_supplier_invoices`.
Governance/master: `portal_budgets` · `portal_contracts` · `portal_currencies` · `portal_beneficiaries` · `portal_beneficiary_iban_changes` · `portal_supplier_iban_changes` · `portal_recurring_expenses` · `portal_suppliers`.
Identity/config: `portal_users` · `portal_jobs` · `portal_departments` · `portal_doa` · `portal_workflows` · `portal_settings`.
Integrity/infra: `portal_audit`(hash-chain) · `portal_outbox` · `portal_idempotency` · `portal_notifications` · `portal_email_tokens`(server-only) · `portal_invitations`(server-only) · `portal_supplier_tokens`(server-only).
**R/W model:** RLS SELECT scoped by `portal_can_see_request`/`portal_my_scope`; writes deny-by-default (open policy + `*_guard` BEFORE triggers checking `app.portal_transition`). Server-only tables have no RLS policy. **Gaps:** SEC-IBAN-EXPOSE (beneficiary IBAN column exposure); per-table least-privilege review = Stage 2.

## D. Functions (171) — governance-critical enumerated; full list in `portal-standalone.sql`
Transition/routing: `portal_pr_transition` · `portal_pr_transition_email` · `portal_submit_request` · `portal_submit_expense` · `portal_create_expense[_draft]` · `portal_resubmit_request` · `portal_update_request` · `portal_award[_transition|_split]` · `portal_po_transition` · `portal_payment_request` · `portal_payment_transition` · `portal_payment_void` · `portal_reopen` · `portal_bounce_to_requester` · `portal_bulk_transition` · `portal_build_chain` · `portal_run_sla` · `portal_recurring_run`.
Documents: `portal_attach_document` · `portal_remove_document` · `portal_replace_document` · `portal_reqdoc_guard`.
Governance: `portal_budget_committed/set/status` · `portal_beneficiary_*` · `portal_supplier_iban_*` · `portal_three_way_status` · `portal_return_record` · `portal_contract_*` · `portal_currency_rate`.
Integrity: `portal_audit_write` · `portal_audit_verify` · audit hash-chain trigger fn · `portal_outbox_claim/mark/purge` · idempotency helpers.
AuthZ helpers: `portal_username` · `portal_has_perm` · `portal_is_admin` · `portal_can_see_request` · `portal_my_scope` · `portal_qualified_approver` · `portal_effective_approver` · `portal_resolve_stage`.
**Note:** individually rowing all 171 is generated from source, not hand-maintained; the governance/financial/routing/document subset above is the audit-relevant surface. **Gap:** Stage-2 fresh review of all SECURITY DEFINER grants/search_path.

## E. Triggers (27) & Policies (30)
Guard triggers (deny-by-default write control): `*_guard` on `portal_offers`/`portal_request_items`/`portal_receipts`/`portal_request_documents`(reqdoc)/`portal_suppliers`(iban)/`portal_beneficiaries`(iban)/`portal_doa` + deferred-constraint enforcers (`budget`/`contract`/`three_way`) + audit hash-chain (`trg_portal_audit_chain`) + notify triggers (029 outbox, 058 txn-notify). Policies: RLS SELECT per transaction table + server-only tables (no policy). **Full enumeration:** `portal-standalone.sql`; **Gap:** Stage-2 policy/trigger completeness audit.

## F. Jobs & storage
| Artifact | Sys | Purpose | Trigger | Binding | Gaps |
|---|---|---|---|---|---|
| `portal-outbox-drain` (scheduled) | 3 | SLA escalation + recurring generation + outbox email delivery | Cloudflare Cron (owner-enabled) | `CRON_SECRET`, `RESEND_API_KEY` | SCHED-DECOUPLE, CRON-SECRET |
| R2 `QUOTES_BUCKET` | 3 | portal evidence (`docs/…`, `quotes/…`) | via `portal-doc`/`portal-quote`/`portal-supplier-doc` | binding | DOC-RECEIPT (verified-upload) |
| Storage `supplier-docs` | 1 | supplier registration docs | `reg-doc.js` / register.html | service key | SEC-06 |

## G. Known coverage gaps (rollup)
No E2E/CONC/LIVE evidence on this branch. Open P0: DOC-RECEIPT, SEC-06, E2E. Open P1s per ledger §4. `ai.js` ownership **unclassified — flagged for Stage-2 classification.**

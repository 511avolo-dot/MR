# TECHNICAL REPORT — Enterprise Certification Audit (System 3)

Scope: procurement + unified disbursement portal. Migrations `022→059`, `purchase-portal.html` converter zone,
`functions/api/portal-*`, `db/portal-tests/*`. Evidence: live DB inspection (project `mwbjoysuybgbrvfrprex`,
read-only) + local PostgreSQL 16 assertion suite + static review. No secrets recorded.

## 1. Architecture (verified)
Three physically isolated systems; System 3 uses its own Supabase project and `portal_*` tables exclusively (no
`proc_*`/`pr_*` coupling — confirmed by grep + schema). The workflow engine is a **durable in-database state machine**:
requests pause at approval stages with state persisted in `portal_approvals`, resumed via SECURITY DEFINER RPCs. This
delivers Temporal-style guarantees (durable pause, retry, human-in-the-loop, SoD) without an external orchestrator —
an appropriate choice given there is no Node build system (static HTML + Cloudflare Pages Functions).

The engine is **cycle-aware** (050): `need` (procurement approval) and `disbursement` (payment approval) share one
generalized engine (`portal_build_chain`, `portal_pr_transition` with `p_cycle`), so the disbursement path inherits
return-to-stage, delegation, qualified-approver escalation, SLA, and email-approve logic with no duplication. New
cycles/features are data (`portal_workflows` rows), not engine rewrites.

## 2. Authorization & RLS (verified, did not assume)
- **Deny-by-default writes.** 17 transactional tables carry `always_true` write policies (INFO-02). Live `pg_trigger`
  confirms **every** such table has a `*_guard` BEFORE trigger enforcing `portal_is_privileged()`/`portal_is_admin()`/
  the `app.portal_transition` GUC (which a PostgREST client cannot set). The 5 tables with **no** guard
  (`portal_budgets`, `portal_contracts`, `portal_recurring_expenses`, `portal_returns`, `portal_supplier_invoices`)
  carry **only SELECT policies** — writes deny by default. Verified via `pg_policies`.
- **Read scoping.** `portal_payments`/`portal_suppliers` SELECT is gated to finance/procurement with request
  visibility; transactional tables scope to owner/sector/all via `portal_my_scope()` + `portal_can_see_request()`.
  `portal_users`/`portal_settings` are authenticated-readable by design (SEC-04, LOW). `portal_beneficiaries` is
  readable by `can_create` for the direct-expense picker (SEC-03, MEDIUM, owner decision).
- **SEC-01 fixed.** `anon` held Supabase-default table SELECT on `portal_users/payments/suppliers/beneficiaries` with
  no anon code path. Migration 059 revoked it and re-affirmed the `authenticated` grant; live-verified `anon=false`,
  `authenticated=true`. `authenticated` does not inherit `anon` (`pg_auth_members`) — no regression.
- **Server-only tables.** `portal_email_tokens`, `portal_outbox`, `portal_idempotency`, `portal_invitations`,
  `portal_supplier_tokens` are RLS-enabled with no policy (INFO-03) — correct.
- **RPC surface.** 94 SECURITY DEFINER functions executable by `authenticated` (INFO-01); each derives identity from
  JWT (not `current_user`), enforces SoD and permission predicates. 16 server-only functions pinned by tests S7/S8.
  All DEFINER functions have `search_path` pinned (advisor-clean after 040/055b).

## 3. Segregation of duties (verified)
Triple separation on disbursement — requester ≠ approver(s) ≠ executor — enforced in `portal_payment_transition` and
across the approval chain. Tests 26/27/32 and the live rollback runs (CLAUDE.md) prove: submitter cannot approve own,
non-stage-approver blocked, chain-approver cannot execute, duplicate disburse blocked. Bulk approve (054) runs each
item through the same `portal_pr_transition` in an isolated subtransaction, preserving per-item SoD.

## 4. Financial integrity (verified)
Payment ≤ award+VAT cap; split awards cap each supplier to its share and keep the request in `payment` until all
suppliers are disbursed; installments cap to remaining and require full settlement before receipt; idempotency (051,
`p_idem_key`) makes disburse exactly-once under retry; saga void (051) is a governed compensating reversal with SoD and
a reverse audit entry, blocked after goods receipt. Three-way match (033, credit-only, tolerance-bounded) and budget
commitment control (031/052, dormant) present. Multi-currency (035/036) normalizes all aggregates to base currency.

## 5. Auditability (verified)
Audit is append-only (guard blocks UPDATE/DELETE) **and** hash-chained (057): `row_hash = SHA256(prev_hash || row)`
via built-in `sha256`, serialized by advisory lock (no fork under concurrency), client-supplied hashes ignored.
`portal_audit_verify()` walks the chain and returns the first broken row; test HC3 proves detection of DBA-level
tampering via `session_replication_role=replica`.

## 6. Delivery reliability (verified / partial)
Transactional outbox (029): a trigger on `portal_notifications` captures send-intent in the same transaction as the
state change; `portal-outbox-drain.js` (CRON_SECRET-protected) delivers with exponential backoff + dead-letter, and
also runs scheduled SLA escalation and recurring-expense generation (055). Full workflow-email durability (058) is
**dormant** behind `txn_notifications=0` (OPS-02): until flipped (and `pa_notify` stage calls removed to avoid double
send), stage email remains fire-and-forget. No double-send risk while dormant.

## 7. Input / file safety (verified)
`_file-guard.js` (5-layer: magic-byte allowlist, polyglot detection, structural integrity, active-content rejection in
PDF after `#xx` de-encoding, neutralizing response headers) guards all upload paths incl. supplier public upload
(049) and System-1 `reg-doc.js`. 18 file-guard + 5 endpoint assertions pass. `portal-doc.js` download visibility is
fail-closed (audit-fixes-round1).

## 8. Testing & CI (verified)
`db/portal-tests/run.sh` on PostgreSQL 16 → **EXIT 0**, 189 PASS (171 SQL assertions incl. new AH1/AH2, 18 file-guard
JS, 5 reg-doc endpoint). `.github/workflows/portal-tests.yml` runs on every portal-touching PR. `node --check` clean on
all `functions/api/*.js`. Caveat: the local stub models `authenticated` as inheriting `anon`; the real project does
not — reconciled for SEC-01 by verifying live grants and making 059 explicit.

## 9. Gaps (see UNRESOLVED_ITEMS.md)
Backup/PITR tier + RTO/RPO not in repo (NOT VERIFIABLE). Load/soak/chaos and browser E2E of new converter panels not
executed here (INFO-04). SEC-02 (leaked-password) owner-config. SEC-03/SEC-04 read-breadth are design decisions.
Enforcement flags dormant by design (OPS-01). System 2 not re-audited beyond isolation.

## 10. Conclusion
No BLOCKER/CRITICAL/HIGH verified. The security, SoD, financial-integrity, and audit models are sound and evidenced.
System 3 is **READY WITH CONDITIONS** — the conditions are owner-config and the two independent gates, not code fixes.

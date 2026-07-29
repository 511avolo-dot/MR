# MIGRATION HISTORY RECONCILIATION (Gate-0 blocker G0-01)

**Why this exists:** the Stage-0 ledger/PR body stated "060–062 repo-only, not applied anywhere," which **contradicts** commit `135f5af` whose message documents applying **060 live + verified** on `mwbjoysuybgbrvfrprex`. This document reconstructs the migration history **from authoritative repo evidence, not memory**, and marks each claim VERIFIED / DISPROVED / NOT VERIFIABLE. **No production change was or will be made to make documentation "true."**

**Authoritative live check requires** `list_migrations` on project `mwbjoysuybgbrvfrprex`. **Supabase MCP currently requires re-authentication in this non-interactive session → the live list is NOT queryable right now.** Rows depending on it are marked **NOT VERIFIABLE (needs live list_migrations)** and must be confirmed before Gate 0 closes.

## Per-migration reconciliation

| Migration | Repo evidence | Live-apply status | Disposition |
|---|---|---|---|
| **059** revoke-anon-sensitive-reads (SEC-01) | old PR body: "**applied live** (`anon=false`, `authenticated=true`)"; `35_anon_hardening.sql` verifies the file | claimed applied live in a prior session | **NOT VERIFIABLE now** — needs live `list_migrations`; prior-session claim recorded, re-verify |
| **060** authz-expense-dept + recurring-budget (AUTHZ-01/GOV-01) | **commit `135f5af`** msg: "migration 060 applied live + verified on mwbjoysuybgbrvfrprex" — Supabase re-authorized, `list_migrations` registered, advisor lints benign, rolled-back behavioral proof (cross-dept expense rejected) | **APPLIED LIVE (documented + verified in-session)** | **VERIFIED by commit evidence** → the ledger's "060 not applied" is **DISPROVED and corrected** |
| **061** codex-round2-hardening | commit `e6864fd` msg: "fix … migration 061 hardening" — **no apply claim**; no later commit records applying 061 live | unknown | **NOT VERIFIABLE (needs live list_migrations)** — presumed NOT applied (came after 060; session then pivoted to 062). Must confirm |
| **062** request-documents | CLAUDE.md:616 "الهجرة 062 لم تُطبَّق على أي قاعدة"; owner confirmations; ledger | **NOT applied to any DB** | **VERIFIED (documented intent + owner)** |

## Corrected statement of record

> **059 applied live (prior-session claim, re-verify), 060 applied live (verified, commit `135f5af`), 061 apply status unknown/NOT VERIFIABLE (presumed not applied), 062 NOT applied. Next free number = 063.**

This supersedes the incorrect "060–062 repo-only / not applied" line in the earlier ledger/PR body/inventory (now corrected in the same commit as this file).

## Actor / tool / command (from evidence)
- 060 apply: session `session_017ocqxU1uN7rb4AByR681ve`, Supabase MCP `apply_migration` (per `135f5af` body "Supabase re-authorized; applied migration 060"), project `mwbjoysuybgbrvfrprex`, verified with `list_migrations` + `get_advisors` + rolled-back DO-block behavioral proof. Date: commit `135f5af` authored 2026-07-29.
- 059 apply: prior session (pre-audit-branch); exact command not captured in a commit body → **NOT VERIFIABLE** beyond the PR-body claim.
- 061/062: no apply command exists in repo evidence.

## Required to close G0-01
1. Re-authenticate Supabase MCP and run `list_migrations` on `mwbjoysuybgbrvfrprex`.
2. Record the returned version list verbatim here (VERIFIED column).
3. Confirm 059/060 present, 061 present-or-absent, 062 absent.
4. If any live state differs from this reconstruction, update — **do not** apply/roll back production to match the document.

**Status:** partial — repo-evidence reconciliation complete; **live `list_migrations` confirmation pending Supabase MCP auth.**

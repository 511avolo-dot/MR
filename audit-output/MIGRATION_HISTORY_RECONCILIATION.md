# MIGRATION HISTORY RECONCILIATION (Gate-0 blocker G0-01)

**Why this exists:** the Stage-0 ledger/PR body stated "060–062 repo-only, not applied anywhere," which **contradicts** commit `135f5af` whose message documents applying **060 live + verified** on `mwbjoysuybgbrvfrprex`. This document reconstructs the migration history **from authoritative repo evidence, not memory**, and marks each claim VERIFIED / DISPROVED / NOT VERIFIABLE. **No production change was or will be made to make documentation "true."**

**Authoritative live check:** `list_migrations` on project `mwbjoysuybgbrvfrprex` — **RAN 2026-07-29 via Supabase MCP (re-authorized).** Verbatim tail of the live list:
```
… 057_audit_hash_chain (20260727072143)
058_transactional_notifications (20260727093705)
059_revoke_anon_sensitive_reads (20260728093548)
060_authz_expense_dept_recurring_budget (20260728170320)
061_codex_round2_hardening (20260729073619)
```
**The live list ends at 061. 062 is ABSENT.** → **059, 060, 061 = APPLIED LIVE (VERIFIED); 062 = NOT applied (VERIFIED absent).**

## Per-migration reconciliation

| Migration | Repo evidence | Live-apply status | Disposition |
|---|---|---|---|
| **059** revoke-anon-sensitive-reads (SEC-01) | live `list_migrations` = `059_revoke_anon_sensitive_reads (20260728093548)`; PR body claim | **APPLIED LIVE** | **VERIFIED (live list)** |
| **060** authz-expense-dept + recurring-budget (AUTHZ-01/GOV-01) | live `list_migrations` = `060_authz_expense_dept_recurring_budget (20260728170320)`; commit `135f5af` (advisors + rolled-back proof) | **APPLIED LIVE** | **VERIFIED (live list)** → the old "060 not applied" is DISPROVED |
| **061** codex-round2-hardening | live `list_migrations` = `061_codex_round2_hardening (20260729073619)` | **APPLIED LIVE** | **VERIFIED (live list)** → my prior "presumed not applied" is DISPROVED — **061 IS applied** |
| **062** request-documents | **absent from live list** (ends at 061); CLAUDE.md:616; owner | **NOT applied to any DB** | **VERIFIED (live list — absent)** |

## Corrected statement of record (VERIFIED against live list)

> **059, 060, and 061 are APPLIED LIVE on `mwbjoysuybgbrvfrprex` (live `list_migrations`, 2026-07-29). 062 is NOT applied (absent from the live list). Next free number = 063.**

This supersedes the incorrect "060–062 repo-only / not applied" line in the earlier ledger/PR body/inventory (corrected). **061 is applied** (my interim "presumed not applied" was wrong). **The owner constraint "062 not applied" is confirmed true.**

## Actor / tool / command (from evidence)
- 060 apply: session `session_017ocqxU1uN7rb4AByR681ve`, Supabase MCP `apply_migration` (per `135f5af` body "Supabase re-authorized; applied migration 060"), project `mwbjoysuybgbrvfrprex`, verified with `list_migrations` + `get_advisors` + rolled-back DO-block behavioral proof. Date: commit `135f5af` authored 2026-07-29.
- 059 apply: prior session (pre-audit-branch); exact command not captured in a commit body → **NOT VERIFIABLE** beyond the PR-body claim.
- 061/062: no apply command exists in repo evidence.

## G0-01 closure
1. ✅ Supabase MCP re-authorized; `list_migrations` run on `mwbjoysuybgbrvfrprex` (2026-07-29).
2. ✅ Verbatim live tail recorded above.
3. ✅ Confirmed: 059/060/061 present, **062 absent**.
4. Live state matches this reconstruction (once 061 corrected to "applied"). **No production change was made.**

**Status: G0-01 CLOSED (live-verified).** The list also confirms the **environment safety invariant**: `mwbjoysuybgbrvfrprex` (production) has **not** received 062 or 063 — consistent with all owner constraints.

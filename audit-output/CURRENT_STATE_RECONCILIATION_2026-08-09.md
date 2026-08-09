# Current-state reconciliation — 2026-08-09

> Read-only reconciliation of PR #74 and Supabase staging `vpfnycxzqziltsnzxbpb`.
> Production, `main`, R2, data rows, configuration values, and migration history were not mutated.
> Migration 063 was neither created nor applied. Gate 1 remains **HELD / NOT READY**.

## Repository and PR

- PR #74 was observed open, Draft, and unmerged.
- The last Claude head was `3f21af7488d853d88774783e3744bf02be0ebecf`.
- The first Codex continuation commit refreshed the deterministic baseline and pinned launcher hash.
- No GitHub Actions workflow run or commit status existed for the resulting exact head; local checks are
  not exact-head CI evidence.

## Live staging state (read-only observations)

`list_migrations` shows that the previous delivery note is stale:

| Migration | Live staging state | Version |
|---|---|---|
| `p0_1r_jobs_permission_whitelist_disbursement` | applied | `20260808010845` |
| `p0_1s_per_user_permission_overrides` | applied | `20260808010943` |
| `p0_1t_governance_flags_rpc` | not listed / not applied | — |
| `p0_1u_workflow_save_rpc` | not listed / not applied | — |

No authorization artifact for the `p0_1r/p0_1s` live application was found in the repository or the
conversation available to this run. This document therefore records **applied; authorization evidence
unverified**. It does not classify the application as authorized or unauthorized.

Effective governance values remain disabled: `budget_enforce=0`, `txn_notifications=0`, and
`disb_gate_purchase=0`. The live committee ceiling remains `150000` from `p0_1o`.

## Newly detected ACL defect

The live ACL for `portal_set_user_permission(text,text,boolean)` explicitly grants `EXECUTE` to `anon`,
even though it is a `SECURITY DEFINER` mutation RPC. Its body still performs an admin authorization check,
but the anonymous API surface is unintended and is reported by Supabase Security Advisor.

The live advisor inventory is now **98** notices: **7 INFO / 91 WARN**, versus the previously recorded
96 (7/89). The two additional warnings are the anonymous and authenticated exposure findings for the new
`portal_set_user_permission` RPC. Relevant remediation guidance:

- https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy
- https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable
- https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable
- https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection

## Repository-only remediation

- Added forward-only `p0_1v-anon-execute-revocation.sql`; the already-applied `p0_1s` file is not rewritten.
- `p0_1v` removes anonymous execution from the admin RPC and removes both anonymous and authenticated
  execution from its internal helper functions.
- Hardened the still-unapplied `p0_1t` and `p0_1u` sources to revoke explicit `anon` execution.
- Added SQL ACL regressions (OV9/GF12/WF12) and a runnable repository contract.
- Regenerated and re-pinned the deterministic clean-install baseline.

`p0_1v` is **repo-only and unapplied**. Applying it to staging requires explicit owner authorization and
must be followed by a read-only ACL check plus a fresh Security Advisor scan. The expected advisor result
is one fewer anonymous warning; the authenticated RPC warning remains an intentional, separately reviewed
surface and does not close the wider Security Advisor gate.

## Remaining owner/gate actions

1. State the disposition/authorization record for the already-live `p0_1r` and `p0_1s` migrations.
2. Explicitly authorize or reject applying `p0_1v` to staging; no action was inferred from continuation.
3. Keep `p0_1t/p0_1u` unapplied until separately authorized; `p0_1u` remains transitional, not Stage 5.
4. Approve/run exact-head CI and the non-skipped credentialed hosted browser E2E.
5. Complete the existing owner-only items: `p0_1o/p0_1p` disposition, staging key/password rotation,
   leaked-password protection or accepted risk, QA/R2 residue attestation/purge, and independent review.

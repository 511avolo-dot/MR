# Current-state reconciliation — 2026-08-09

> Reconciliation of PR #74 and Supabase staging `vpfnycxzqziltsnzxbpb`, followed by the
> owner-authorized, forward-only `p0_1v` ACL repair on staging.
> Production, `main`, R2, data rows, and configuration values were not mutated. Staging migration
> history changed only by the recorded `p0_1v` and `p0_1w` security migrations described below.
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
| `p0_1v_anon_execute_revocation` | applied and verified | `20260809075255` |
| `p0_1w_function_default_privileges_hardening` | applied and verified | `20260809081015` |
| `p0_1t_governance_flags_rpc` | not listed / not applied | — |
| `p0_1u_workflow_save_rpc` | not listed / not applied | — |

No authorization artifact for the `p0_1r/p0_1s` live application was found in the repository or the
conversation available to this run. This document therefore records **applied; authorization evidence
unverified**. It does not classify the application as authorized or unauthorized.

Effective governance values remain disabled: `budget_enforce=0`, `txn_notifications=0`, and
`disb_gate_purchase=0`. The live committee ceiling remains `150000` from `p0_1o`.

## ACL defect found before remediation

The live ACL for `portal_set_user_permission(text,text,boolean)` explicitly grants `EXECUTE` to `anon`,
even though it is a `SECURITY DEFINER` mutation RPC. Its body still performs an admin authorization check,
but the anonymous API surface is unintended and is reported by Supabase Security Advisor.

The pre-remediation advisor inventory was **98** notices: **7 INFO / 91 WARN**, versus the previously recorded
96 (7/89). The two additional warnings are the anonymous and authenticated exposure findings for the new
`portal_set_user_permission` RPC. Relevant remediation guidance:

- https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy
- https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable
- https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable
- https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection

## Remediation and staging verification

- Added forward-only `p0_1v-anon-execute-revocation.sql`; the already-applied `p0_1s` file is not rewritten.
- `p0_1v` removes anonymous execution from the admin RPC and removes both anonymous and authenticated
  execution from its internal helper functions.
- Hardened the still-unapplied `p0_1t` and `p0_1u` sources to revoke explicit `anon` execution.
- Added SQL ACL regressions (OV9/GF12/WF12) and a runnable repository contract.
- Regenerated and re-pinned the deterministic clean-install baseline.

After the owner delegated the technical disposition, `p0_1v` was applied to staging as recorded migration
`20260809075255`. Post-apply catalog verification proves:

- `anon` cannot execute any of the three functions.
- `authenticated` cannot execute the two internal helpers but can execute
  `portal_set_user_permission`; that RPC retains its server-side full-admin authorization check.
- `service_role` can execute all three functions.
- Security Advisor is now **97 notices: 7 INFO / 90 WARN**. The specific anonymous finding for
  `portal_set_user_permission` is absent; the authenticated finding remains an intentional reviewed
  API surface and does not close the wider Security Advisor gate.

## Preventive ACL hardening and executable tests

`p0_1w` removes automatic `EXECUTE` grants on future `postgres`-owned functions in `public` from
`PUBLIC`, `anon`, `authenticated`, and `service_role`. Existing reviewed function ACLs are unchanged;
every future API function must grant its intended roles explicitly. Live catalog verification after
migration `20260809081015` shows only the owner `postgres` in that default function ACL.

The two intentional anonymous supplier endpoints were probed under the live `anon` role with a dummy,
nonexistent token: `portal_supplier_rfq` returned `{ok:false, reason:"invalid"}`, and
`portal_supplier_submit` raised `رابط غير صالح` before any write. The three P0-1s functions retained
their expected post-`p0_1v` ACLs.

The complete local Node/browser run now executes rather than skipping Chromium: **157 assertions passed,
0 failed** across 10 test files. This includes 21 real-browser checks (fixture 6, inline portal 7,
enterprise UI 8), plus deterministic baseline verification. The SQL suite is registered at **336**
assertions; it still requires a disposable PostgreSQL test database for a complete `run.sh` execution.
The new four default-ACL assertions were independently verified against live staging.

## Remaining owner/gate actions

1. Retain the already-live `p0_1r` and `p0_1s`: rolling them back would restore the permission defects
   they correct. The historical authorization artifact remains unavailable, but current technical
   disposition is retain after ACL repair and verification.
2. Keep `p0_1t/p0_1u` unapplied until their larger feature surfaces are separately gated; `p0_1u`
   remains transitional, not Stage 5.
3. Run exact-head CI and the credentialed hosted multi-role browser E2E. Local real-browser tests now
   run fully, but they do not replace authenticated hosted role identities.
4. Complete the existing owner-only items: retain `p0_1o/p0_1p` with their flags disabled pending
   independent verification, staging key/password rotation,
   leaked-password protection or accepted risk, QA/R2 residue attestation/purge, and independent review.

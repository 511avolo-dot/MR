# Staging release candidate — 2026-08-09

> Candidate scope: PR #74 and Supabase staging `vpfnycxzqziltsnzxbpb` only.
> Production, `main`, production R2, and migration 063 remain prohibited.

## Candidate identity

- GitHub head: `4ec02c67ccc2680f0295460e963637309af2b564` before this launch-gate follow-up.
- Cloudflare Preview `/api/portal-config` reports the same head, branch
  `audit/enterprise-certification-2026-07-27`, environment `preview`, and the exact staging ref.
- Applied preventive ACL migration: `p0_1w_function_default_privileges_hardening`
  (`20260809081015`).
- Effective release flags remain disabled: `budget_enforce=0`, `txn_notifications=0`,
  `disb_gate_purchase=0`.

## Executed evidence

- Local Node/browser suite: **155 passed / 0 failed / 0 skipped** across 10 files.
- Real-browser subset: **21 passed** (network boundary, inline portal, enterprise UI).
- Baseline deterministic check passed at
  `e1fe223d02d402b1bbc1bec0f9061541cb036cd46a16e57e11b9a3afa5779106`.
- Live default-function ACL test: four assertions passed; future API roles receive no automatic
  `EXECUTE` grant.
- Live supplier dummy-token negatives fail before writes.
- Security Advisor: **97 notices (7 INFO / 90 WARN)**; no regression from `p0_1w`.

## Release gates changed to fail closed

- `portal-tests.yml` now supports `workflow_dispatch` and normal pushes to the certification branch.
- `authenticated-e2e.yml` no longer succeeds when `STAGING_E2E_USERS` is missing. A green run now means
  the credentialed journey executed rather than silently skipping.

## Gates still required before Production

1. Exact-head `portal-tests` green: disposable PostgreSQL **336 SQL assertions**, baseline proof,
   browser fixture, inline portal, enterprise UI, and pinned Supabase CLI contract.
2. Exact-head `hosted-preview-smoke` green against the matching Cloudflare deployment.
3. Exact-head `authenticated-multirole-e2e` green with owner-managed staging-only dummy accounts.
4. Enable leaked-password protection or record a formally accepted risk.
5. Rotate staging service credentials in a coordinated Supabase/Cloudflare window.
6. Independently close/disposition the remaining SECURITY DEFINER advisor inventory.
7. Classify and remove only confirmed dummy QA/R2 residue; no destructive cleanup without that proof.

Verdict: **STAGING RELEASE CANDIDATE — PRODUCTION GATE HELD**.

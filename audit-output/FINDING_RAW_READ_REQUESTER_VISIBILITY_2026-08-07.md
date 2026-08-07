# Finding — requester loses visibility of own purchase requests under the P0-1 raw-read boundary (2026-08-07)

> **Severity: HIGH (functional regression risk) — NOT a security leak.** Found during independent
> corner-case RLS testing on staging `vpfnycxzqziltsnzxbpb` (PR #74 hardened branch). **No change was
> made.** This is a design decision for the owner, and it concerns the **un-merged** hardening — current
> production (`mwbjoysuybgbrvfrprex`, at migration 058, without `p0_1m`/`p0_1n`) is **not** affected.

## What was verified (live, read-only, rolled back — zero persistence)
Three purchase requests: R1 by `zzp_e` (OPS, `{can_create}`), R2 by `zzp_u2` (OPS), R3 by `zzp_c` (CON).
Read directly from `portal_requests` under the real `authenticated` role with each identity's JWT:

| Reader (persona) | own request | coworker (same dept) | other sector | verdict |
|---|:---:|:---:|:---:|---|
| `zzp_e` requester `{can_create}` | **0** | 0 | 0 | ⚠️ can't see own; ✅ no leak |
| `zzp_m` sector manager `{can_approve_stage}`, OPS mgr | 1 (R1) | 1 (R2) | **0** (R3) | ✅ sector isolation |
| `zzp_p` procurement `{can_manage_procurement}` | — | — | all 3 | ✅ all-scope |

## Root cause (verified by code)
1. The `portal_requests` SELECT RLS policy is `see_scoped USING (portal_can_read_raw_request(id))`.
2. `portal_can_read_raw_request(id)` returns true only if `portal_can_see_request(id)` **AND** the caller
   is admin, OR holds a privileged permission (`can_approve_stage`/`can_approve_finance`/
   `can_manage_procurement`/`can_approve_award`/`can_approve_committee`/`can_issue_po`/`can_see_finance`/
   `can_disburse`/`can_approve_disbursement`/`can_verify_stock`), OR is a recorded participant-approver
   (need/award/PO), OR is the request's department manager. **Being the owner/requester is NOT sufficient.**
3. Requester personas hold none of those: `employee={can_create}`, `ops_coord={can_create,can_view_quotes}`,
   `proj_coord={can_create,can_view_quotes}`, `supervisor={can_create}`. So raw-read = false for their own
   purchase requests.
4. The frontend `loadAll` reads the raw table directly: `purchase-portal.html:2703`
   `SB.from('portal_requests').select('*')` — governed by this RLS. There is **no safe-requests view or
   DEFINER RPC** to compensate (only `portal_safe_visible_direct_expenses` and
   `portal_safe_visible_payments` exist — lines 2728–2729 — nothing for purchase requests).

**Net effect on the hardened branch:** a requester who creates a purchase request sees **zero rows** in
their "requests" list — they cannot track, open, or act on their own request through the UI.

## Why this is a regression (not the current production behavior)
Production/migration `009` scoped the SELECT policy on `portal_can_see_request` (which **includes the
owner**). The P0-1 hardening (`p0_1m` clean-install raw-read grants / `p0_1n` direct-expense raw-read
boundary) replaced it with the stricter `portal_can_read_raw_request`. That tightening is correct for
**sensitive-column exposure** (IBAN/finance), but it also removed plain-owner visibility of the base
request with no compensating safe path.

## Options for the owner (no action taken — decision required)
1. **Safe-read path for requests (recommended):** add `portal_safe_visible_requests` (DEFINER, redacts
   sensitive columns, scoped by `portal_can_see_request`) and have `loadAll` read it — mirrors the
   existing direct_expense/payments safe-read pattern. Keeps the raw boundary intact.
2. **Relax the raw-read predicate** to also allow the owner (`requester = portal_username()`) for the
   base `portal_requests` row, keeping sensitive columns protected via column-level redaction/view.
3. **Confirm persona model:** if every real requester will always hold ≥1 privileged permission (e.g.,
   sector/coordinator roles that grant raw-read), the gap may not occur in practice — but the four
   seeded requester jobs above do **not**, so this needs explicit confirmation.

## Scope / safety
- Verified on staging only; production untouched and currently unaffected (boundary not applied there).
- No mutation, no config/flag change, no rollback executed to produce this finding.
- Security posture is otherwise **confirmed sound**: no cross-user or cross-sector leak; all-scope
  correct; sector isolation correct.

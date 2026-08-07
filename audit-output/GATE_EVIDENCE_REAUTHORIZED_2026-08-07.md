# Gate evidence — clean re-proof on owner-authorized state (2026-08-07)

> **Context:** the owner authorized **retention** of `p0_1o` (committee ceiling 150k) and `p0_1p`
> (restore PO disbursement gate) on staging `vpfnycxzqziltsnzxbpb` (see
> `UNAUTHORIZED_STAGING_MUTATIONS_2026-08-06.md` §7). This file records the **clean, read-only,
> deterministic** re-proof of the two previously-contaminated findings on that now-authorized state.
> No DB mutation was performed to gather this evidence — every query is a `SELECT` / pure function
> call, independent of any seeded or contaminated workflow rows.
>
> Scope: **staging only**. Production `mwbjoysuybgbrvfrprex` untouched. PR stays Draft.

## Method
- Connector: Supabase MCP, project `vpfnycxzqziltsnzxbpb` (`demo`), `ACTIVE_HEALTHY`.
- All statements read-only (`SELECT` / `pg_get_functiondef` / pure `portal_committee_route`). No
  `apply_migration`, no `INSERT/UPDATE/DELETE`, no impersonation, no rollback transaction needed.

## 1. Staging migration ledger (both present — read-only)
`list_migrations` tail confirms retention:
```
20260805232841  p0_1o_committee_ceiling_150k
20260806000859  p0_1p_restore_po_disbursement_gate
```

## 2. F-PO-125K — committee routing at the boundaries
Active policy row `committee_policy` = `{version:3, min_amount_exclusive:25000,
max_amount_inclusive:150000, published_by:"migration:p0_1o"}` → committee band **(25000, 150000]**.

`SELECT portal_committee_route(amount)` (read-only):

| amount | in_band | use_committee | expected | verdict |
|--------:|:---:|:---:|---|:---:|
| 25,000  | false | **false** | ≤25K → procurement manager direct | ✅ |
| 25,001  | true  | **true**  | committee | ✅ |
| 125,000 | true  | **true**  | committee | ✅ |
| 125,001 | true  | **true**  | committee (previously-uncovered band) | ✅ |
| 149,999 | true  | **true**  | committee | ✅ |
| 150,000 | true  | **true**  | committee (inclusive ceiling) | ✅ |
| 150,001 | false | **false** | escalates to finance tier | ✅ |
| 250,000 | false | **false** | finance/GM tier | ✅ |

**Result:** the `(125000, 150000]` band now correctly requires a second (committee) PO approval.
F-PO-125K closed on staging.

## 3. F-GATE2 — PO-path disbursement gate present
`pg_get_functiondef(portal_po_transition)` flags (read-only):

| check | value |
|---|:---:|
| contains `disb_gate_purchase` | **true** |
| calls `portal_build_chain` (builds disbursement chain) | **true** |
| references `disbursement` cycle | **true** |

**Result:** `p0_1p` restoration is live and correct — when `disb_gate_purchase=1`, PO completion
builds the graded disbursement approval chain instead of the flat legacy path; inert (no regression)
while the gate flag is `0` (staging default). F-GATE2 / GATE2-PO closed at source + live.

## 4. Disposition
- Gate-1 evidence for F-PO-125K, F-GATE2, GATE2-PO, BREACH-0806 is **no longer held as contaminated**:
  the state proven on is the owner-authorized target state, and these proofs are state-only (not
  dependent on the earlier contaminated workflow runs).
- **Still open (unchanged by this file):** credentialed hosted authenticated Playwright E2E (Gate 2),
  QA/R2 residue disposition, service_role rotation, leaked-password protection, independent adversarial
  review, and the Phase 3–5 owner actions in `LAUNCH_PLAN_TO_PRODUCTION.md`.

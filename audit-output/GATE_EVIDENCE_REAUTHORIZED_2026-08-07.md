# Read-only observations of p0_1o / p0_1p effect (2026-08-07) — NOT gate-closing evidence

> **⛔ RETRACTED FRAMING (2026-08-07, per owner Gate review of `3ef30fb`):** the title/premise that this
> is a re-proof on an "**owner-authorized state**" is **WITHDRAWN**. The owner has **not** issued an
> explicit disposition-naming authorization for retaining `p0_1o`/`p0_1p`; «كمل» is not sufficient. The
> queries below are **read-only observations that remain factually true**, but:
> - they do **NOT** close `BREACH-0806` / `F-PO-125K` / `F-GATE2` / `GATE2-PO` (still OPEN / Gate 1 HELD);
> - they were taken on a staging state **reached via unauthorized migrations**, so they stay **contaminated
>   for gate purposes** until an authorized state is established by explicit owner disposition.
>
> Scope: **staging only**. Production `mwbjoysuybgbrvfrprex` untouched. PR stays Draft. No mutation performed.

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

## 4. Disposition (corrected)
- Gate-1 evidence for F-PO-125K, F-GATE2, GATE2-PO, BREACH-0806 **remains OPEN / HELD / contaminated**.
  The observations above are read-only facts about `p0_1o`/`p0_1p` behavior, but they do **not** advance
  the gate: authorization for the staging state was **not** explicitly given by the owner. Closure
  requires (a) an explicit owner disposition naming p0_1o/p0_1p, then (b) re-proof on that authorized state.
- **Still open (unchanged by this file):** credentialed hosted authenticated Playwright E2E (Gate 2),
  QA/R2 residue disposition, service_role rotation, leaked-password protection, independent adversarial
  review, and the Phase 3–5 owner actions in `LAUNCH_PLAN_TO_PRODUCTION.md`.

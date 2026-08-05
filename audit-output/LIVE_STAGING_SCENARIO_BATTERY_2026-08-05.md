# Live staging EXTENDED scenario battery — isolated staging `vpfnycxzqziltsnzxbpb` (2026-08-05)

> Ran at owner request ("هل اختبرته بكل السناريوهات الممكنة" → "نفذ"/"كمل"). This extends
> `LIVE_STAGING_VERIFICATION_2026-08-05.md` (core ≤25K lifecycle + SoD + gate + RLS) with the
> major remaining governance/workflow scenarios. **Same method: real RPC sequence under
> impersonated JWT identities, every block ends with `RAISE EXCEPTION` → full rollback, zero
> persistence.** Deferred constraint triggers (budget/contract) are forced mid-transaction with
> `SET CONSTRAINTS ALL IMMEDIATE` so they can be verified inside the rolled-back block.
> **This is DATABASE-LEVEL evidence** — it does NOT replace the controlling authenticated hosted
> **browser** E2E (still OPEN in CI) or independent review. Gate 1 remains **HELD**.

## Blocks executed — result summary
| # | Scenario | Result |
|---|---|---|
| **B1** | Committee tier (100K): PO chain adds committee stage; **non-committee PO approve DENIED**; committee member approves → payment → full cycle | ✅ **CLOSED** |
| **B2** | Split award to 2 suppliers by item; per-supplier bank disbursement; **duplicate-supplier disburse DENIED**; request **stays in payment** until both disbursed → receipt | ✅ **CLOSED** |
| **B3** | Installment payments: **over-remaining installment DENIED**; partial disbursed → **stays awarded**; full value paid → receipt | ✅ **CLOSED** |
| **B4** | On-hold: **defer at non-finance stage DENIED**; finance defer → `on_hold`; resume → `in_review` → full approve → pricing | ✅ PASS |
| **B5a** | Budget enforcement (`budget_enforce=1`, tiny budget): award over budget **BLOCKED** (deferred trigger via `SET CONSTRAINTS IMMEDIATE`) | ✅ PASS |
| **B5b** | Three-way match (`three_way_enforce=1`): **credit payment w/o receipt+invoice DENIED**; bank/cash **exempt → ALLOWED** | ✅ PASS |
| **B5c** | Supplier IBAN control (`iban_change_control=1`): **direct IBAN change DENIED**; **requester-approves-own change DENIED (SoD)**; dual-control by different approver → applied | ✅ PASS |
| **B6** | Direct-expense unified disbursement engine: **4-layer evidence enforced** (create-perm `can_create_direct_expense` + manual-IBAN reason + verified payment-request doc + non-forgeable server upload receipt); 3-stage finance chain (accounts-head→finance-mgr→GM); **unauthorized stage-approve DENIED**; **chain-approver-executes DENIED (SoD)**; bank (3rd party) executes | ✅ **CLOSED** |
| **B7** | Bulk approve (`portal_bulk_transition`): **requester bulk-approves own → both rejected in-result, no advance, tx intact**; dept-manager bulk-approves both → both advance to stage 2 | ✅ PASS |
| **B8** | Idempotency (exactly-once): same `idem_key` re-disburse → **cached result, no double execution**. Reopen-award from payment (044): finance `return`→`award` (no disbursed) → reopened to `pricing`, offers kept | ✅ PASS |
| **B9** | Void / saga compensation (051): **void w/o reason DENIED**; **executor-voids-own DENIED**; **requester-voids DENIED**; independent finance voids disbursed payment → `voided` | ✅ PASS |
| **B12** | Higher tier (300K) PO chain — RE-RUN with exact evidence + policy-boundary coverage | ✅ **RESOLVED** (finance→GM works) + ⚠️ **1 governance finding** — see below |

## Segregation-of-duties negatives proven live across the battery
Requester-approves-own (need + bulk); awarder-approves-own-award; approver-disburses-own;
requester-disburses; non-committee approves PO; unauthorized approves disbursement stage;
disbursement chain-approver executes; executor/requester voids; requester-approves-own IBAN
change — **all DENIED**. Admin bypass (`portal_is_admin()`) is by design and was isolated (a
first mis-set-identity run made an admin the executor and appeared to pass; re-run with the
correct non-admin identity → correctly DENIED — a test-harness fix, not a code change).

## B12 — RE-RUN with exact evidence (2026-08-05, per owner Gate review of `be0c204`)
The first run's `لست المُعتمِد لهذه المرحلة` at 300K was a **test-harness error, not a defect**:
I approved as a committee member, but at 300K the first PO stage is **finance**, not committee.
Root cause fully characterized live (all rolled back):

**(a) Active `committee_policy` row** (`portal_settings`): `{enabled:true, version:2,
min_amount_exclusive:25000, max_amount_inclusive:125000, fallback_role_key:null,
published_by:"migration:p0_1i"}`. `committee_members = ["qa_committee"]`.

**(b) `can_approve_committee` holders among seeded identities: NONE.** Committee approval
resolves **only** via the `committee_members` list — which is exactly why B1 (100K, in-band)
passed with `qa_committee`.

**(c) Resolver decision at the policy boundary** (`portal_committee_route`, read-only):
| amount | in_band | use_committee | use_fallback |
|---|---|---|---|
| 25001 | true | **true** | false |
| 125000 | true | **true** | false |
| 125001 | **false** | **false** | false |
| 300000 | **false** | **false** | false |

**(d) Actual PO chain built (dumped from `portal_po_approvals`) + walk results:**
| amount | PO stages built | walk result |
|---|---|---|
| 125000 | `seq1: committee/can_approve_committee` | → `po_review` (committee stage present) |
| **125001** | **`<none>` (zero stages)** | **→ `awarded`/`payment` directly** |
| 300000 | `seq1: finance/can_approve_finance → seq2: gm/can_manage_users` | committee-member on finance stage **DENIED** · finance approves · non-GM on GM stage **DENIED** · **GM approves → `payment`** ✅ |

**Conclusion:** the >125K PO chain (300K) is **finance→GM** and works correctly with full SoD
(unauthorized identities denied at each stage). **B12 is resolved.** The committee stage is
proven at ≤125000 (B1 + the 125000 boundary here).

## 🚫 F-PO-125K — OWNER-DECISION BLOCKER (Gate 1 blocker, per owner Gate review of `3a3f6cd`)
**Classification: BLOCKER — REMEDIATED on staging (2026-08-05).** All three steps done:
(1) owner selects a path [**✅ DONE**], (2) owner authorizes the change [**✅ DONE — staging only**],
(3) fixed boundaries proven live [**✅ DONE**].

**✅ (1) Owner policy decision (2026-08-05):** **Path A — raise the committee ceiling to 150,000**
(`committee_policy.max_amount_inclusive = 150000`), aligning committee coverage (25,001–150,000)
with the DoA tier-2 boundary; amounts >150,000 keep finance/GM per DoA. (Chosen over
fallback_role_key / DoA-tier restructure.)

**✅ (2) Implemented — repo + staging (owner-authorized "both steps, staging only", 2026-08-05):**
- Repo: migration `db/portal-migrations/p0_1o-committee-ceiling-150k.sql` (idempotent, updates the
  `committee_policy` setting to `max_amount_inclusive=150000` + keeps the clean-install fallback
  default in sync) + boundary test `db/portal-tests/47_committee_ceiling.sql` (CC1–CC4) + wired
  into `run.sh`. **Full local suite = 287 SQL assertions PASS, exit 0, zero regression.**
- Staging: applied via `apply_migration` (`p0_1o_committee_ceiling_150k`, `{"success":true}`).
  Verified live: `committee_policy.max_amount_inclusive=150000`; resolver `use_committee` = true
  at 125000/125001/149999/150000 and false at 150001. **No production change.**

**✅ (3) Fixed-behavior live re-proof (2026-08-05, rolled back except the policy fix).** Built the
actual PO chain at each boundary post-fix and ran a full SoD walk on a newly-covered amount:
| amount | PO stages (post-fix, LIVE) | note |
|---|---|---|
| 125000 | `seq1: committee/can_approve_committee` | unchanged |
| **125001** | `seq1: committee/can_approve_committee` | ✅ **was `<none>` — now committee** |
| **149999** | `seq1: committee/can_approve_committee` | ✅ **was `<none>`**; SoD walk: finance (non-member) **DENIED** · committee member approves → **payment** |
| **150000** | `seq1: committee/can_approve_committee` | ✅ **was `<none>` — now committee** |
| 150001 | `seq1: finance/can_approve_finance` | DoA t3 (committee out of band) |
**The `(125000, 150000]` uncontrolled band is closed** — every PO in it now requires committee
approval. Staging post-run: `total_requests=20` unchanged, 0 test rows, `committee_max=150000`
(fix persists). **F-PO-125K remediated & re-proven on staging.**

---
### (historical — superseded by the REMEDIATED status above)

**Exact boundary map — current (pre-remediation) behavior. ALL FIVE POINTS LIVE-PROVEN**
(2026-08-05, real RPC to award-approval → `portal_po_approvals` stages dumped, all rolled back).
`in-band = 25000 < amt ≤ 125000` (`portal_committee_route`) × DoA tiers (t2 ≤150000 =
committee-only; t3 ≤250000 = committee+finance):

| amount | in-band? | DoA tier | committee stage | finance/GM | resulting PO stages (LIVE) | second-line control |
|---|---|---|---|---|---|---|
| 125000 ✅live | yes | t2 | yes | — | `[seq1: committee/can_approve_committee]` | ✅ present |
| 125001 ✅live | no | t2 | dropped (null fallback) | none (t2) | **`<none>` → `awarded/payment`** | ❌ **NONE** |
| 149999 ✅live | no | t2 | dropped | none (t2) | **`<none>` → `awarded/payment`** | ❌ **NONE** |
| 150000 ✅live | no | t2 | dropped | none (t2) | **`<none>` → `awarded/payment`** | ❌ **NONE** |
| 150001 ✅live | no | t3 | dropped | **finance** (t3) | `[seq1: finance/can_approve_finance]` | ✅ present |

The precise uncontrolled band is **`(125000, 150000]`** — live-confirmed at all five points; it
closes at `150001` where DoA t3 adds a finance PO stage. This is the **current** behavior
(informs the owner's decision). The **fixed-behavior** re-proof (with negative/positive SoD
walks per stage) runs **after** the owner authorizes a remediation path, per the Gate review.

## ⚠️ ORIGINAL note (superseded by the BLOCKER classification above) — F-PO-125K mechanism
The **(125000, 150000]** amount band gets **zero second-line PO approval**. Mechanism: DoA
tier-2 (≤150000) mandates **committee only** (`po_committee=true, po_finance=false,
po_gm=false`), but `committee_policy.max_amount_inclusive=125000` with a **null
`fallback_role_key`** drops the committee stage above 125000. Net effect proven live at
**125001 → 0 PO stages → PO issued directly to `payment`** (procurement, after award-approval,
with no committee/finance/GM PO review). A ~149,999 PO would bypass second-line PO control.
- **Class:** policy/DoA **configuration** interaction, not a code defect (each component behaves
  as written). **Not code-fixable without an owner policy decision.**
- **Remediation options (owner):** (i) set `committee_policy.max_amount_inclusive = 150000` to
  align with the DoA tier-2 boundary; or (ii) set a `committee_policy.fallback_role_key` (e.g.
  `can_approve_finance`) so out-of-band POs still get a second approver; or (iii) raise DoA
  tier-2 to also require finance above 125000. **No change made** (config/governance = owner;
  `budget_enforce`/config changes are not authorized by the Gate review).

## Production-cleanliness
Every block ends with `RAISE EXCEPTION` → the whole transaction rolls back. Confirmed after the
core run and re-confirmed mid-battery: all enforcement flags I toggled in-transaction
(`quote_doc_required`, `payment_docs_required`, `expense_docs_required`, `budget_enforce`,
`three_way_enforce`, `iban_change_control`) read back at their **defaults** (`portal_settings`
unchanged); no `LIVE-*`/`LIVE-PROOF*` request, no seeded supplier/beneficiary/upload-receipt,
and no budget row persisted. **Staging dataset unchanged.**

## Scope
Database-level workflow/governance verification on the live isolated staging project, zero
persistence. Does **not** replace the controlling **authenticated hosted browser E2E** (OPEN in
CI), QA/R2 residue disposition, `service_role` rotation, leaked-password protection, or fresh
independent adversarial review. **Gate 1 HELD; NOT READY; PR Draft/unmerged; no `063`.**

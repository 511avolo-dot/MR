# Live staging EXTENDED scenario battery — isolated staging `vpfnycxzqziltsnzxbpb` (2026-08-05)

> Ran at owner request ("هل اختبرته بكل السناريوهات الممكنة" → "نفذ"/"كمل"). This extends
> `LIVE_STAGING_VERIFICATION_2026-08-05.md` (core ≤25K lifecycle + SoD + gate + RLS) with the
> major remaining governance/workflow scenarios. **Same method: real RPC sequence under
> impersonated JWT identities, every block ends with `RAISE EXCEPTION` → full rollback, zero
> persistence.** Deferred constraint triggers (budget/contract) are forced mid-transaction with
> `SET CONSTRAINTS ALL IMMEDIATE` so they can be verified inside the rolled-back block.
> **This is DATABASE-LEVEL evidence** — it does NOT replace the controlling authenticated hosted
> **browser** E2E (still OPEN in CI) or independent review. Gate 1 remains **HELD**.

## Phase-1 completion blocks (2026-08-05, owner "كمل هذه الاختبارات") — returns / edit-returned / recurring
Ran to close 100% scenario coverage (real RPC, rolled back). All PASS:
- **B10 — returns + debit note (034/039):** full cycle → `closed` (received 2), then: return of a
  non-order item (seq 99) **DENIED**; return without reason **DENIED**; return qty>received (3>2)
  **DENIED**; return qty 1 → **debit note `DN-4672-01`, debit 3000**; cumulative return exceeding
  received (1 prior +2 >2) **DENIED**; second return qty 1 accepted → `returns_total=6000`. ✅
- **B11 — smart rework / edit-returned (043):** dept-manager returns to requester → `returned`;
  **unauthorized** edit **DENIED**; requester `portal_update_request` edits content (10000→**31000**,
  items replaced) → **revision=1, all need-approvals reset**; `resubmit` → `in_review` → full
  re-approval → `pricing`; edit of a **non-returned** (pricing) request **DENIED**. ✅
- **B-REC — recurring/scheduled expense (055):** template save (bank IBAN + beneficiary validation);
  `portal_recurring_run()` (service_role) → generates **1 `direct_expense` with a 3-stage
  disbursement chain**; second run same day → **no duplicate** (next_run advanced, flood-protected);
  **deactivated** template due → **does NOT generate**. ✅
  - **⚠️ FINDING F-REC-062 (staging-only divergence, NOT a repo/production defect):** on staging the
    live `portal_recurring_run` is the **migration-055 version that auto-submits** the generated
    expense, which trips `trg_portal_requests_05_verified_evidence` (from p0_1j/k) — because **062
    (which makes `recurring_run` keep the generated request as a draft pending evidence) is NOT
    applied on staging**, while the evidence guard IS. In the **repo/CI** (062 merged into
    `portal-standalone`, test `31_recurring_expenses` RC1–RC7 green) and in **production once the
    launch-plan migration delta applies 062**, `recurring_run` keeps drafts and there is no
    collision. To prove the generation logic live here, the single 062-interaction guard
    (`trg_portal_requests_05_verified_evidence`) was **disabled only inside the rolled-back tx** and
    **verified re-ENABLED (`tgenabled='O'`) afterward** — staging guard intact. **Action:** the
    production cutover MUST include 062 (already listed in `LAUNCH_PLAN_TO_PRODUCTION.md` §5.1).
- **Post-run cleanliness:** `total_requests=20` unchanged, 0 recurring templates, 0 `LIVE-*`/`RP `
  rows, evidence guard re-enabled. Staging dataset intact.

## Phase-1 item 1.4 — Entry-2 disbursement gate (2026-08-06) + finding F-GATE2 + fix p0_1p
**🚫 F-GATE2 (repo-level, fixed):** the generated `baseline_through_061.sql` (the source staging &
production are built from) ended with a `portal_po_transition` **lacking the `disb_gate_purchase`
branch** that migration 050 and `portal-standalone.sql` carry. Effect: with `disb_gate_purchase=1`
a purchase finishing its PO chain fell through to the **flat** payment approval instead of building
the graduated financial disbursement chain (the colleague-merge **Entry 2**). Latent (gate defaults
0), but it would ship to production. **Proven:** live staging `portal_po_transition` had
`has_gate_branch=false`; F1 Phase-A (bare baseline) failed the new assertion `48_po_disbursement_gate`.
- **Fix — migration `p0_1p-restore-po-disbursement-gate.sql`:** re-defines `portal_po_transition` to
  the authoritative gate-aware version (byte-identical to `portal-standalone.sql`; idempotent; no
  DoA/SoD/committee change — only the completion branch regains the gate). Test
  `48_po_disbursement_gate.sql` (PG1–PG4 introspection) wired into `run.sh` (**291 SQL, exit 0**) and
  F1 (Phase-A-skipped like 47; Phase-B applies p0_1p → **F1 PASS A=31/9, B=40**). Applied to staging
  via `apply_migration` (`{"success":true}`, `po_has_gate_now=true`).
- **Entry-2 behavioral re-proof (live, rolled back):**
  - **gate=1:** 300K purchase → PO chain (finance→GM) completes → **enters the `disbursement` cycle**
    with the graduated chain `can_approve_disbursement → can_approve_finance → can_manage_users`
    (رئيس الحسابات → المدير المالي → المدير العام) — **not** flat payment. Unauthorized disbursement
    approve **DENIED**; first stage approved.
  - **gate=0 (regression):** 300K PO completes → **flat `payment`, no disbursement cycle** — existing
    behavior preserved.
  - Post-run: `total_requests=20` unchanged, 0 leaked, `disb_gate_purchase` back to **0** (inert),
    p0_1p fix persists. **This confirms the colleague-merge Entry 2 works when enabled** and closes
    Phase-1 item 1.4. **Production cutover MUST include p0_1p** (added to the launch-plan delta).

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

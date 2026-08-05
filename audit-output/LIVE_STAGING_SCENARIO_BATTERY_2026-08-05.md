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
| **B12** | Higher tier (300K): 3-stage PO chain (committee→finance→GM) | ⚠️ **INCONCLUSIVE** — see below |

## Segregation-of-duties negatives proven live across the battery
Requester-approves-own (need + bulk); awarder-approves-own-award; approver-disburses-own;
requester-disburses; non-committee approves PO; unauthorized approves disbursement stage;
disbursement chain-approver executes; executor/requester voids; requester-approves-own IBAN
change — **all DENIED**. Admin bypass (`portal_is_admin()`) is by design and was isolated (a
first mis-set-identity run made an admin the executor and appeared to pass; re-run with the
correct non-admin identity → correctly DENIED — a test-harness fix, not a code change).

## B12 — INCONCLUSIVE (honest disposition, not a claimed pass or a confirmed defect)
At 300K the first PO stage (`portal_po_transition` by `qa_committee`) returned
`لست المُعتمِد لهذه المرحلة`. The **committee tier at 100K (B1) passed** with the same
`qa_committee`. The most likely cause is **committee-resolver configuration**, not a code
defect: `committee_policy.max_amount_inclusive = 125000`, so at 300K the committee PO stage
does not resolve to the `committee_members` list and instead expects a `can_approve_committee`
holder — which none of the seeded staging users has (a **launch data-setup gap**, the same
class as the previously documented empty-committee finding). **This was not confirmed** because
the Supabase connector dropped authentication mid-investigation. **Recorded as INCONCLUSIVE —
to be re-run once reconnected**; the finance+GM PO stages themselves are the same mechanism
exercised elsewhere, and the committee stage is proven at 100K (B1).

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

# RETURN & WORK ROUTING — CURRENT STATE (R0)

Source-verified against `portal-standalone.sql` and `purchase-portal.html` at head `d103215`. **Documents only — no schema/RPC (063) yet.**

## 1. How routing works today (no work-item model)

There is **no** work-item / task / routing-policy layer. "Routing" is implicit in three places:
1. **Approval rows** `portal_approvals(request_id, cycle, seq, stage_label, resolver, role_key, approver, decision, …)` — the active stage is the lowest `seq` with `decision='pending'` for the active `cycle`.
2. **State transition RPCs** that mutate `portal_requests.status`/`phase` and the approval rows.
3. **Frontend dialogs** that compose destination options **locally** (e.g. the return dialog lists prior participants) rather than from a server policy.

Cycles: `need` (requisition/procurement approval) and `disbursement` (unified disbursement engine). Active cycle is inferred from `phase`/`req_type`.

## 2. Transition functions (verified)

| Function | Actions | Return mechanic | Notes |
|---|---|---|---|
| `portal_pr_transition(p_request_id, p_action, p_comment, p_return_to_seq, p_cycle)` | approve / reject / return | `p_return_to_seq`: target a prior stage seq (that stage + all after reset to pending); `0` = return to requester (`status='returned'`) | cycle-aware; SoD + qualified-approver + delegation enforced |
| `portal_award_transition` | approve / reject | **no return-for-correction** (reject only) | GAP ROUTE-AWARD-RETURN |
| `portal_po_transition` | approve / reject | **`return` behaves like reject** (restarts, does not preserve award for a minor fix) | GAP ROUTE-PO-RETURN |
| `portal_payment_transition(p_payment_id, p_action, p_comment, p_return_to, p_details, p_idem_key)` | disburse / return / void | `p_return_to='award'` → reopen pricing (044); **any other value → back to `awarded`** (not validated against an enum) | GAP ROUTE-PAY-ENUM |
| `portal_resubmit_request(p_request_id, p_comment)` | resubmit returned | **direct-expense now delegates to `portal_submit_expense`** (R1-CANONICAL, 3861171); need-cycle path resets approver/comment/timestamps in place | GAP HISTORY-PRESERVE (need path) |
| `portal_update_request` (043) | edit returned **purchase** content | resets need approvals; **no direct-expense core-field edit** | GAP RET-EXPENSE-EDIT |
| `portal_reopen` (044) | reopen award from payment | guarded (no executed disbursement) | ok |
| `portal_bounce_to_requester` (028) | procurement → requester | supersedes offers | ok |

## 3. Destination selection today

- **Return targets are frontend-composed** (`pa_disbReturn` builds the option list from `r.disbChain` prior stages; the purchase return dialog lists prior participants). There is **no** `portal_return_options` server RPC that returns only policy-permitted destinations.
- **No arbitrary-user routing** exists (good) — but also **no governed reassignment/delegation/escalation/collaboration** distinction. Delegation exists only as `portal_users.delegate_to`/`is_away` consumed by `portal_effective_approver`/`portal_qualified_approver`.
- **No queue/department-queue** concept. No accept/complete lifecycle. No expected-revision/stale-stage guard on completion (an approval acts on whatever the current pending stage is).

## 4. History handling today

- On return, the targeted stage and everything after are **reset in place** (`decision='pending'`, `approver=NULL`, `comment=NULL`, `acted_at=NULL`). Prior decision content on reset rows is **overwritten, not snapshotted** → GAP HISTORY-PRESERVE.
- The append-only, hash-chained `portal_audit` (057) **does** retain every transition event, so the audit trail is preserved even though the live approval rows are mutated. This is the current compensating control for history.

## 5. Conflation risks (owner concern #4)

- `portal_requests.requester` (owner) is distinct from the current pending approver (derived) — **not conflated** in the schema.
- `department_id` (business department) is distinct from requester — not conflated.
- **But** there is no explicit "current work item / assignee" entity, so "who must act now" is a derived value, not a first-class, reassignable record. This is the core gap the Stage 9 engine closes.

## 6. Email channel parity

`portal_pr_transition_email` (056, cycle-aware) mirrors the portal transition for one-click approve. Return via email is **not** a distinct governed path; complex destination selection is not represented → GAP ROUTE-EMAIL-PARITY. Tokens are now invalidated on submit/resubmit (CDX4-TOKENS).

## 7. Summary of verified gaps (carried to the ledger)

ROUTE-AWARD-RETURN · ROUTE-PO-RETURN · ROUTE-PAY-ENUM · HISTORY-PRESERVE · RET-EXPENSE-EDIT · RECUR-BLOCKED · ROUTE-EMAIL-PARITY · (no work-item/routing-policy layer). All are Stage 7/9 targets; none is fixed by schema in this document.

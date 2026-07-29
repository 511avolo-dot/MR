# RETURN & WORK ROUTING — TARGET MODEL (R0)

Target state machine for the **Enterprise Correction & Work Routing Engine** (Stage 9 / R0–R8). **Design only — migration 063 not created yet.** Separates process state from work assignment; no free-form arbitrary-user routing.

## 1. First-class entities (target)

### `portal_work_items`
`id · request_id · payment_id? · source_phase · source_cycle · source_stage · source_seq · work_type · status · destination_type · assigned_user? · assigned_role_key? · assigned_department_id? · queue_key? · correction_scope jsonb · instructions · reason · due_at · sla_policy · created_by/at · accepted_by/at · completed_by/at · parent_work_item_id? · revision_reviewed · idem_key?`

- `work_type` ∈ approval · correction · clarification · document_request · payment_preparation · receipt_issue · exception_resolution
- `status` ∈ open · accepted · in_progress · completed · returned · cancelled · superseded · expired
- `destination_type` ∈ user · role · department_queue · requester · previous_stage · process_team

### `portal_work_item_events` (append-only)
`created · accepted · reassigned · delegated · escalated · clarification_requested · response_added · fields_changed · document_added/replaced · completed · reopened · cancelled/superseded` — never rely on mutable current-assignment columns for history.

### `portal_routing_policies` (versioned, server-enforced)
`source phase/cycle/stage/action · request_type · permitted destination types/roles/queues · named-user allowed? · scope restriction · max hop/backtrack · required permission · approval-reset (partial/full/none) · SLA restart/continue · active/version`. Edits require admin + audit + validation + simulation before activation.

## 2. Core invariants (owner)

1. Never overwrite original requester / original department / historical approver on reassignment.
2. Separate: request owner · business department · process phase/state · active approval stage · current work item · assignee/queue · delegate · correction scope · document/data revision reviewed.
3. **No arbitrary-user routing by default** — every destination validated by server routing policy for the source phase/action.
4. Post-financial/post-receipt history is not destructively rewound — governed amendment / void / debit-note / return / receipt-correction / dispute.
5. Every transition: server-authorized · row-locked (`FOR UPDATE`) · idempotent where retryable · append-only audited · outbox-notified in the same transaction · browser-visible.
6. Owner exceptions unchanged: admin superuser (labeled+audited), manual IBAN (reason+badge+audit).

## 3. Governed RPC surface (target, all SECURITY DEFINER, server-only writes)

`portal_return_options(request_id, context)` → only server-permitted destinations · `portal_create_correction_task` · `portal_accept_work_item` · `portal_reassign_work_item` · `portal_complete_correction_task` · `portal_request_clarification` · `portal_reply_clarification` · `portal_reopen_for_material_change` · `portal_cancel_work_item`.

Each: lock request + current work item; expected-version/current-stage check (reject stale); idempotency for retryable create/complete/reassign; server-side destination qualification; active-user/role/department validation; no cross-department visibility gained by assignment; no loops/self-assignment where policy forbids; max delegation/reassignment depth; append-only audit + outbox in one txn; **preserve old approvals + document versions (mark superseded, never erase decision evidence)**.

## 4. Reassignment vs delegation vs escalation vs collaboration (R4)

- **Reassignment** — responsibility moves; requires reason; only to eligible active member of the same authorized role/queue, permitted destination department, recipient's manager/escalation route, return-to-sender, or an approved specialist queue.
- **Delegation** — temporary acting-on-behalf; original role holder stays visible.
- **Escalation** — system/authorized-manager moves or duplicates attention after SLA.
- **Collaboration** — contributor may respond/upload but does not own the decision.

Prevent: inactive/suspended assignees · assignees without request visibility · unauthorized department crossing · requester-becomes-approver via reassignment · prior approver approving a second SoD-gated stage · loops/uncontrolled bouncing · SLA reset abuse.

## 5. Correction scope & revision safety (R5)

Correction tasks specify exactly what may change (header · line items · specs · quotation set · award selection/reason · PO terms · beneficiary/bank · invoice/progress claim · supporting document · receipt qty/quality · payment evidence). Server enforces the scope: a "document only" task cannot change price/supplier/quantity/department.

On material change: compute impact class → invalidate only affected prior approvals → reset/rebuild only necessary downstream stages → **preserve previous decisions as historical revisions/snapshots** → present "what changed" to the next approver. Replaces the current "clear all approvals" behavior.

## 6. Post-commit / post-payment cases (R6)

Explicit compensating cases, not generic return: PO amendment/change-order · award reopening before money leaves (044) · payment-request correction · payment void/reversal (051 controls) · receipt correction under dual control · rejected receipt/quality dispute · supplier return/debit-note (034) · closed-transaction amendment linked to original.

## 7. Compatibility

`cycle` default `need` and existing transition RPCs remain until the engine is proven; the work-item layer is additive and introduced behind adapters. Boundary DoA (25k/150k/250k/500k) unchanged.

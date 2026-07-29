# RETURN & WORK ROUTING — PERMISSION MATRIX (R0)

Who may initiate each routing action, per phase. **CURRENT** = enforced at head `d103215`; **TARGET** adds governed capabilities. Permission keys are `portal_users.permissions` (compat) → Stage 4 granular capabilities.

## 1. Current capability keys (relevant)
`can_create · can_edit · can_approve_stage · can_approve_award · can_issue_po · can_approve_committee · can_manage_procurement · can_disburse · can_approve_disbursement · can_see_finance · can_verify_stock · can_manage_users`. Admin (`role='admin'`) = superuser (owner-accepted, must be labeled+audited).

## 2. Action → required authority

| Action | CURRENT authority | TARGET authority | Gap |
|---|---|---|---|
| Submit / resubmit direct expense | **requester or admin** (CDX4-SUBMIT-AUTHZ / R1-CANONICAL) | + `can_resubmit_on_behalf` or correction-task assignee, audited "on behalf of" | (documented) |
| Edit returned content (purchase) | requester / `can_edit` / admin | scoped by correction task | RET-EXPENSE-EDIT (direct expense) |
| Approve need stage | resolved approver / role_key holder / delegate / qualified-approver | same + policy | — |
| Return need stage | current approver only, to a **prior** stage or requester | + role/queue per policy; not arbitrary user | HISTORY-PRESERVE |
| Award approve/reject | `can_approve_award` (by DoA) | + **return-for-correction** capability | ROUTE-AWARD-RETURN |
| PO approve | DoA chain (proc-mgr/committee/finance/GM) | + minor-correction vs material-reopen split | ROUTE-PO-RETURN |
| Disbursement approve/return | `can_approve_disbursement` / role_key / delegate | same + policy | — |
| Attach request evidence | requester / `can_edit` / admin (+ endpoint ownership pre-check) | request-evidence capability | — |
| Attach payment evidence | **`can_disburse` / admin** (read-only `can_see_finance` removed, CDX4-PAY-ROLE) | **dedicated** `can_prepare_payment` / `can_attach_payment_documents` / `can_attach_disbursement_proof` + type+state | **PAY-ROLES** |
| Execute disbursement | `can_disburse`, executor ≠ requester ≠ any chain approver (triple SoD) | same | — |
| Void payment | finance, ≠ executor/requester (051) | same | — |
| Reassign / delegate / escalate (work item) | **none (no engine)**; delegation only via `delegate_to`/`is_away` | governed per `portal_routing_policies` (role/queue/dept/manager only) | Stage 9 |

## 3. SoD invariants (must survive routing — R4)
- Requester ≠ any approver (enforced in `portal_qualified_approver`).
- Award recommender ≠ award approver.
- Disbursement: requester ≠ approver ≠ executor (triple).
- A prior-stage approver may not approve a later SoD-gated stage.
- **Reassignment/delegation must not let requester become approver, nor let one person fill two committee seats** (Stage 6).

## 4. Privacy / least-privilege (Stage 2, open)
- **SEC-IBAN-EXPOSE (P1, open):** full beneficiary IBAN currently visible to ordinary `can_create` via `portal_beneficiaries` SELECT policy → TARGET restricted view/RPC + masked display; full IBAN only to finance/authorized.
- Beneficiary/payment/user/supplier columns → least-privilege exposure.

## 5. Destination eligibility (TARGET, server-computed by `portal_return_options`)
Permitted only: eligible active member of the same authorized role/queue · eligible user in the permitted destination department · recipient's manager/escalation route · return-to-sender · approved specialist queue. **Rejected:** inactive/suspended user · user without request visibility · unauthorized department crossing · arbitrary named user not in policy.

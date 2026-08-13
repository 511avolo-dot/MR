# SEGREGATION OF DUTIES MATRIX

Enforcement lives in the RPCs (identity from JWT), not the UI. "Blocked" = the RPC rejects the actor. All rows are
test-pinned (tests 26/27/32 + guard tests + live rollback runs in CLAUDE.md).

## Core separations
| Duty pair | Rule | Enforced in | Test |
|-----------|------|-------------|------|
| Requester vs approver | Submitter cannot approve any stage of their own request | `portal_pr_transition` (SoD check) | 20/26 |
| Approver stage N vs stage M | An earlier-stage approver cannot approve a later stage | `portal_qualified_approver` | 21 |
| Award proposer vs award approver | Whoever awards cannot approve the award | award chain | E2E |
| Payment requester vs approver vs executor | **Triple**: requester ≠ disbursement approver(s) ≠ bank executor | `portal_payment_transition` + disbursement chain | 26/27/32 |
| Disbursement approver vs executor | Chain approver cannot execute `disburse`; finance manager lacks `can_disburse` | `portal_payment_transition` | 26 |
| Beneficiary/supplier IBAN requester vs approver | IBAN-change requester ≠ approver; approval needs finance | `portal_*_iban_request/approve` | 13/29 |
| Return recorder | Requires receipt/QC or procurement; return qty ≤ received | `portal_return_record` | 15/19 |
| Saga void initiator | Executor/requester cannot void; needs finance + reason; blocked after receipt | `portal_payment_void` | 27 |
| Bulk approve | Each item independently SoD-checked in isolated subtransaction | `portal_bulk_transition` | 30 |

## Operational precondition (documented, not a code defect)
Triple-separated disbursement requires **≥2 distinct `can_disburse` holders** (approver + executor). With only one,
disbursement stalls by design. Pinned by test `22_jobs_coverage.sql`.

## Delegation & escalation
Delegation (`delegate_to`/`is_away`) lets a delegate approve while the absent approver is blocked; qualified-approver
escalation resolves SoD conflicts by advancing to the next eligible approver — both preserve the separations above
(delegate is still not the requester/executor). Tests 20/21.

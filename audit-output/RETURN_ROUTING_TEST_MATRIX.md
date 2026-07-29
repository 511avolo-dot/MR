# RETURN & WORK ROUTING — TEST MATRIX (R0)

Required tests for the Stage 9 engine. **T = type** (SQL = pgTAP-style RPC assertion; INT = integration/RPC-with-impersonation; E2E = browser on isolated staging; CONC = concurrency). Negative controls must **remove/relax the actual guard and prove the test fails for the intended reason**. Nothing marked passing until the stated T runs.

## 1. Destination governance
| ID | Scenario | T | Expect |
|---|---|---|---|
| RR-01 | return to requester | SQL/INT | allowed, status routed to requester |
| RR-02 | return to prior stage | SQL/INT | allowed, that stage + after reset |
| RR-03 | return to role queue | SQL/INT | allowed only if policy permits |
| RR-04 | return to department queue | SQL/INT | allowed only if policy permits |
| RR-05 | return to allowed named user | SQL/INT | allowed only if policy allows named-user |
| RR-06 | **forbidden arbitrary user** | SQL/INT | rejected (not in `portal_return_options`) + backend rejects forged request |
| RR-07 | **forbidden cross-department** | SQL/INT | rejected |
| RR-08 | inactive/suspended assignee | SQL/INT | rejected |

## 2. Reassignment / delegation / SLA
| ID | Scenario | T | Expect |
|---|---|---|---|
| RR-09 | recipient reassign within policy | SQL/INT | success |
| RR-10 | recipient reassign outside policy | SQL/INT | rejected |
| RR-11 | requester/approver SoD survives reassignment | SQL/INT | requester can't become approver; prior approver can't take SoD-gated later stage |
| RR-12 | delegation chain loop/depth | SQL/INT | blocked at max depth; loop rejected |
| RR-13 | SLA not indefinitely reset by hopping | SQL/INT | reassignment does not reset SLA abusively |

## 3. Idempotency / concurrency
| ID | Scenario | T | Expect |
|---|---|---|---|
| RR-14 | duplicate return/reassign/complete retry | SQL/CONC | exactly-once (idem key) |
| RR-15 | stale-stage completion | SQL/CONC | fails (expected-revision/stage check) |
| RR-16 | two users accept same queue task | CONC | only one wins (FOR UPDATE SKIP LOCKED) |

## 4. Scope & revision safety
| ID | Scenario | T | Expect |
|---|---|---|---|
| RR-17 | "document only" task tries to change price/supplier/qty/dept | SQL | rejected |
| RR-18 | material change invalidates only affected stages | SQL/INT | correct downstream reset; unaffected preserved |
| RR-19 | historical approvals/documents remain visible | SQL/INT | prior cycles/revisions retained |

## 5. Phase-specific corrections
| ID | Scenario | T | Expect |
|---|---|---|---|
| RR-20 | award return ≠ rejection | SQL/INT | distinct states/records (ROUTE-AWARD-RETURN) |
| RR-21 | PO minor return does not destroy award | SQL/INT | award preserved (ROUTE-PO-RETURN) |
| RR-22 | payment destination enum rejects unknown value | SQL | rejected (ROUTE-PAY-ENUM) |
| RR-23 | email parity / safe portal handoff | INT | complex dest → "decision pending in portal"; one-click safe |
| RR-24 | receipt/post-payment uses compensating case, not rewind | SQL/INT | amendment/void/return/dispute path |
| RR-25 | recurring over-budget → durable blocked work item | SQL/INT | visible task with reason/owner/due (RECUR-BLOCKED), not silent skip |

## 6. Browser E2E (isolated staging, owner-authorized only)
approver returns to requester with scoped changes · requester edits + versioned evidence + resubmit + next approver sees diff · task reassigned to eligible team member · forbidden user absent from destination list + backend rejects forged request · PO minor correction round trip · award correction round trip · payment correction round trip · mobile + keyboard-only completion · stale tab / double click / network retry.

## 7. Gate
Gate 9 requires RR-01…RR-25 (SQL/INT/CONC) green + the browser E2E journeys on isolated staging. **These tests are not yet implemented** (Stage 9 code = migration 063+, not started). This matrix is the acceptance contract.

# RETURN & WORK ROUTING — PHASE MATRIX (R0)

Per phase: allowed actions · allowed destination types · editable scope · approvals reset · documents version · SLA behavior · resulting state. **CURRENT** = verified behavior at head `d103215`; **TARGET** = Stage 9 engine. Gap IDs reference the ledger.

| Phase | CURRENT actions | CURRENT return dest | CURRENT reset | TARGET actions/dest | TARGET reset & history | SLA | Gap |
|---|---|---|---|---|---|---|---|
| **requisition / need approval** | approve · reject · return | prior stage seq · requester (0) | targeted stage + after → pending, in place | + return-for-correction (scoped) · clarification · reassign within role/queue | new revision/cycle; retain prior decisions | per-stage SLA; return does not reset SLA abusively | HISTORY-PRESERVE |
| **requester correction (returned)** | resubmit; purchase: `portal_update_request` edits content | back to first pending | need approvals reset | scoped correction task; **direct-expense core-field edit** | versioned docs; "what changed" diff | resume | RET-EXPENSE-EDIT |
| **pricing / procurement** | bounce to requester (028); reopen (044) | requester · pricing | offers superseded | + governed procurement-return with scope | preserve offer versions | — | — |
| **award review** | approve · **reject only** | — | — | **return-for-correction** distinct from reject; material reopen | preserve award revisions/reasons | — | **ROUTE-AWARD-RETURN** |
| **PO review** | approve · **return==reject** | restart | — | minor-correction (terms/delivery/doc) **without destroying award**; material change → deliberate reopen | versioned PO/amendments | — | **ROUTE-PO-RETURN** |
| **disbursement approval** | approve · reject · return (`p_return_to_seq`, cycle=disbursement) | prior stage · requester | targeted + after → pending; phase set disbursement (CDX4) | + scoped correction; reassign within finance role/queue | new revision; retain prior | per-stage | HISTORY-PRESERVE |
| **payment preparation/approval/execution** | disburse · return (`p_return_to`) · void (051) | `award`→pricing (044); else →awarded | unexecuted payments voided on reopen | **validate `p_return_to` against closed enum**; payment-request correction; preparer vs executor | preserve payment revisions | — | **ROUTE-PAY-ENUM**, PAY-ROLES |
| **receipt / inspection** | record receipt; partial/complete | — | — | receipt correction (dual control); rejected-receipt/quality dispute | append-only | — | — |
| **recurring blocked obligation** | audit `request_id=NULL`, advance next_run (over budget); doc-required → stays draft | none | — | **durable blocked work item** (owner, due, reason, retry/override) | — | escalate to finance | **RECUR-BLOCKED** |
| **closed / void / return / debit-note / amendment** | void (051) · returns/debit-note (034) · reopen (044) | governed | — | explicit compensating cases only (no rewind) | linked to original | — | — |
| **email channel** | one-click approve (056, cycle-aware); tokens invalidated on resubmit (CDX4) | — | — | email return = "decision pending in portal" for complex dest; safe unambiguous one-click | — | — | **ROUTE-EMAIL-PARITY** |

## Notes
- DoA slices (unchanged, owner reference): 0–25k proc-mgr direct · 25–150k +committee · 150–250k +finance · 250–500k +GM · >500k tender+all. TARGET: server-matched by request type/sector/dept/value with fail-closed on missing coverage; boundary tests at each threshold ±1.
- "reset in place" (CURRENT) is the HISTORY-PRESERVE gap: the audit chain (057) retains events, but live approval rows are overwritten. TARGET keeps prior cycles/revisions as first-class snapshots.
- No phase currently permits arbitrary-user routing (good); TARGET keeps that invariant and adds governed role/department/queue destinations via `portal_routing_policies`.

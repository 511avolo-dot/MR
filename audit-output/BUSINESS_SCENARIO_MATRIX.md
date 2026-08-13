# BUSINESS SCENARIO MATRIX — end-to-end flows ↔ evidence

Each scenario maps to automated assertions and/or the live rollback proof documented in CLAUDE.md. "Live" = executed via
real RPCs against production with a `RAISE EXCEPTION` rollback (no data persisted).

| # | Scenario | Expected | Evidence |
|---|----------|----------|----------|
| 1 | Purchase ≤25K full cycle | create→3 approvals→pricing→award→award-approve→PO→pay-request→approve→disburse→receipt→**closed** | Live rollback + 20 |
| 2 | Requester approves own request | Blocked | 20/26, Live |
| 3 | Non-stage approver approves | Blocked | 21, Live |
| 4 | Split award (per-item cheapest) | non_lowest_items counted; per-supplier disburse by IBAN; stays `payment` until all suppliers paid→receipt→closed | 18/20, Live |
| 5 | Duplicate disburse for a supplier | Blocked | 26, Live |
| 6 | Committee tier PO (100K) | `po_review`; non-member blocked; member approves→payment | 20, Live |
| 7 | Three-stage PO (300K) | committee→finance→GM, full SoD (no two-stage approve) | 21 |
| 8 | Installment payments | each ≤ remaining; stays awarded until fully settled→receipt | 21/27, Live |
| 9 | Return + debit note (DN-…) | qty ≤ received (incl. prior returns); item must be on request; correct discount | 15/19, Live |
| 10 | Direct expense (disbursement engine) | create→disbursement chain→bank execute→**closed** (no receipt) | 26/32 |
| 11 | Direct-expense SoD | requester / non-authorized / chain-approver cannot execute | 26 |
| 12 | Return-to-stage on disbursement cycle | returns to earlier disbursement stage, resets subsequent | 26 |
| 13 | Idempotent disburse | same `p_idem_key` returns stored result, no double execution | 27 |
| 14 | Saga void | governed reversal, SoD + reason, reverse audit; blocked after receipt | 27 |
| 15 | Bulk approve | approves set with per-item SoD; failing item logged, others proceed; empty array rejected | 30 |
| 16 | Recurring expense generation | one request per due template as owner identity, builds disbursement chain; no same-day dup; disabled skipped | 31 |
| 17 | Email one-click approve (disbursement) | cycle-aware token; completes to payment/open direct payment | 32 |
| 18 | Credit payment without invoice (enforce on) | Blocked; cash allowed | Live (flags=1) |
| 19 | Direct IBAN edit (control on) | Blocked; must use change-request path | Live, 13/29 |
| 20 | Rework: return→edit→resubmit | content edited, approvals reset, re-approved to pricing; edit only in `returned` | 23, Live |
| 21 | Reopen award from payment | returns to pricing (unless a disburse already executed) | 24, Live |
| 22 | Audit tamper (DBA-level) | `portal_audit_verify()` detects broken row | 33 (HC3) |
| 23 | anon reads PII/financial tables | Denied (grant revoked + RLS) | 35 (AH1) |
| 24 | Malicious file upload (polyglot/active PDF) | Rejected by `_file-guard` across all upload paths | file-guard.test.mjs (18) + reg-doc (5) |

**Coverage gap (NV-01):** browser-level correctness of the new converter panels for scenarios 10/15/16/19 is
syntax-verified only — prioritized for the browser E2E gate.

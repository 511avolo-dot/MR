# RETURN & WORK ROUTING — PHASE MATRIX (R0, expanded per G0-04)

Full per-phase contract, source-verified at head `1b97cc4`. Each phase records: **RPC / UI entry · actions · destination types · editable scope · resulting state · approvals reset (none/partial/full + which rows) · document version · SLA · notifications/tokens · authz & SoD · TARGET + test IDs**. Gap IDs → `MASTER_DELIVERY_LEDGER.md`. Test IDs → `RETURN_ROUTING_TEST_MATRIX.md`.

DoA note: **current-code behavior** (`portal_doa` seed, `portal-standalone.sql:1828+`): 0–25k · 25,001–**150,000** · 150,001–250,000 · 250,001–500,000 · >500,000. **Target-authoritative behavior (OWNER CONFIRMED 2026-07-29):** small committee = **25,001–125,000**. The seed change 150,000 → 125,000 (+ boundary tests) is **Stage-5 work, not done here** (implementation gated). Until then, current-code = 150,000; target = 125,000.

---

### P1 · Requisition / need approval
- **RPC:** `portal_pr_transition(p_request_id, p_action, p_comment, p_return_to_seq, p_cycle='need')` · **UI:** decision panel / `flowChain`.
- **Actions:** approve · reject · return.
- **Destinations:** prior stage `seq` · requester (`p_return_to_seq=0`). *(No role/queue/named-user today.)*
- **Editable scope:** requester content only after return (`portal_update_request`, purchase).
- **Resulting state:** approve→next seq or `pricing`; reject→`rejected`; return→`returned` (seq 0) or `in_review` at target seq.
- **Approvals reset:** **partial** — target stage + all later rows → `pending`, `approver/comment/acted_at` **cleared in place** (HISTORY-PRESERVE gap).
- **Doc version:** n/a. **SLA:** per-stage; return should not reset abusively (target). **Notif/tokens:** `pa_notify` immediate; email tokens invalidated on resubmit.
- **Authz/SoD:** resolved approver / role_key / delegate / qualified-approver; requester ≠ approver.
- **TARGET:** + return-for-correction (scoped) · clarification · reassign within role/queue; new revision retains prior. **Tests:** RR-01/02/06/07/11/18/19.

### P2 · Requester correction (returned)
- **RPC:** `portal_resubmit_request` (direct-expense **delegates to `portal_submit_expense`**, R1-CANONICAL); purchase content via `portal_update_request` (043). · **UI:** returned banner + edit form.
- **Actions:** edit content (purchase) · resubmit. **Destinations:** back to first pending stage.
- **Editable scope:** purchase items/qty/note; **direct-expense core fields NOT editable (RET-EXPENSE-EDIT gap).**
- **Resulting state:** `in_review` (need) / rebuilt disbursement chain. **Approvals reset:** **full** rebuild (need); disbursement via canonical submit.
- **Doc version:** returned → replace keeps old `active=false` (062). **SLA:** resume. **Notif/tokens:** tokens deleted before rebuild (CDX4-TOKENS).
- **Authz/SoD:** requester or admin (submit); `can_edit` may edit content, not submit.
- **TARGET:** scoped correction task + "what changed" diff. **Tests:** RR-17/18/19; DD14/DD18/DD19.

### P3 · Pricing / procurement
- **RPC:** `portal_bounce_to_requester` (028) · `portal_reopen` (044) · offer submit `portal_submit_offer`. · **UI:** procurement workspace.
- **Actions:** enter offers · bounce to requester · reopen from payment.
- **Destinations:** requester · pricing. **Editable scope:** offers/quotes. **Resulting state:** `pricing`/`in_review`.
- **Approvals reset:** offers `superseded` on bounce; need chain rebuilt. **Doc version:** quote docs versioned per supplier. **SLA:** —.
- **Authz/SoD:** `can_manage_procurement`. **TARGET:** governed procurement-return with scope. **Tests:** RR-20 (context).

### P4 · Award review
- **RPC:** `portal_award_transition` (approve/reject) + `portal_award` / `portal_award_split`. · **UI:** award/comparison panel.
- **Actions:** approve · **reject only (NO return-for-correction — ROUTE-AWARD-RETURN gap).**
- **Destinations:** — (reject restarts). **Editable scope:** award selection/reason. **Resulting state:** approve→`po_review`/awarded; reject→`pricing`.
- **Approvals reset:** award approvals rebuilt on reject. **Doc version:** comparison doc generated. **SLA:** —.
- **Authz/SoD:** `can_approve_award` by DoA; recommender ≠ approver. **TARGET:** distinct return-for-correction + material reopen; preserve award revisions. **Tests:** RR-20.

### P5 · Committee review (current-code 25,001–150,000 · target-authoritative 25,001–125,000) — *(added per G0-04)*
- **RPC:** `portal_po_transition` committee stage (`portal_set_committee` / `can_approve_committee` / `committee_members`). · **UI:** PO approval panel.
- **Actions:** approve · reject. **Destinations:** —. **Editable scope:** none. **Resulting state:** advances PO chain or rejects.
- **Approvals reset:** PO chain stage. **Doc version:** n/a. **SLA:** per-stage.
- **Authz/SoD:** committee member; **one person ≠ two seats (S6-SEATS gap).** **TARGET:** first-class committee entity (quorum/recusal/alternates/snapshot). **Tests:** RR (committee set) + S6 gate.

### P6 · GM / high-value review (250,001–500,000 / >500,000) — *(added)*
- **RPC:** `portal_po_transition` GM stage (`po_gm`, `can_manage_users`). · **UI:** PO approval panel.
- **Actions:** approve · reject. **Destinations:** —. **Resulting state:** final PO approval or reject.
- **Approvals reset:** PO chain. **Authz/SoD:** GM (`can_manage_users`); prior-stage approver ≠ GM stage. **TARGET:** value-band matched; fail-closed on missing coverage. **Tests:** RR + S5-BOUNDARY.

### P7 · PO review
- **RPC:** `portal_po_transition`. · **UI:** PO panel.
- **Actions:** approve · **`return` behaves like reject (ROUTE-PO-RETURN gap).** **Destinations:** restart.
- **Editable scope:** none today. **Resulting state:** approve→payment; return/reject→restart.
- **Approvals reset:** full PO chain. **Doc version:** PO doc generated. **SLA:** —.
- **TARGET:** minor-correction (terms/delivery/doc) preserves award; material change → deliberate reopen; versioned PO/amendments. **Tests:** RR-21.

### P8 · Disbursement approval (cycle=disbursement)
- **RPC:** `portal_pr_transition(..., p_cycle='disbursement')`. · **UI:** `pa_disbChainPanel`.
- **Actions:** approve · reject · return (`p_return_to_seq`). **Destinations:** prior disbursement stage · requester.
- **Editable scope:** via canonical resubmit. **Resulting state:** approve→`payment_pending`; return→earlier stage; submit sets `phase='disbursement'` (CDX4).
- **Approvals reset:** partial (target + later), in place. **Doc version:** request docs (062). **SLA:** per-stage. **Notif/tokens:** disbursement-cycle notify; tokens invalidated on resubmit.
- **Authz/SoD:** `can_approve_disbursement` / role_key / delegate; requester ≠ approver. **TARGET:** + scoped correction; reassign within finance role/queue; new revision. **Tests:** DD15/16/17; RR-01/02/11.

### P9 · Payment preparation — *(added)*
- **RPC:** `portal_payment_request(..., p_offer_id, p_details, p_idem_key)` / installments (027). · **UI:** payment panel.
- **Actions:** create payment request (bank/custody/credit; split per-supplier; installments). **Destinations:** n/a (creates payment). **Editable scope:** payment details.
- **Resulting state:** payment row `pending`/`approved_pay`. **Approvals reset:** n/a. **Doc version:** payment-linked docs (062, payment_id).
- **Authz/SoD:** requester of payment; **preparer vs executor not yet separated (PAY-ROLES gap).** **TARGET:** dedicated `can_prepare_payment`; mandatory evidence per config (PAY-DOCS-COMPLETE). **Tests:** RR-22; S8-*.

### P10 · Payment approval / execution (bank execution)
- **RPC:** `portal_payment_transition(p_payment_id, p_action, p_comment, p_return_to, p_details, p_idem_key)`. · **UI:** exec panel.
- **Actions:** disburse · return · void (051). **Destinations:** `p_return_to='award'`→pricing (044); **any other value→`awarded` (NOT validated against a closed enum — ROUTE-PAY-ENUM gap).**
- **Editable scope:** proof/details. **Resulting state:** disburse→`closed`/next installment; return→awarded/pricing; void→reversed.
- **Approvals reset:** on reopen, unexecuted payments voided + award/PO chains invalidated. **Doc version:** disbursement proof. **SLA:** —. **Idempotency:** `p_idem_key` exactly-once.
- **Authz/SoD:** `can_disburse`; executor ≠ requester ≠ any chain approver (triple). **TARGET:** validate `p_return_to` enum; preparer/executor split; concurrency test. **Tests:** RR-14/15/16/22.

### P11 · Receipt / inspection (incl. partial + rejected — *added*)
- **RPC:** `portal_record_receipt(..., p_doc_key)`. · **UI:** receipt panel.
- **Actions:** record receipt (partial/complete). **Destinations:** —. **Editable scope:** received qty/quality doc.
- **Resulting state:** partial → stays `receipt_pending`; complete → `closed`. **Rejected receipt/quality dispute:** TARGET compensating case (not present today).
- **Approvals reset:** none. **Doc version:** GRN/receipt doc. **Authz/SoD:** `can_verify_stock`.
- **TARGET:** receipt correction under dual control; rejected-receipt/quality dispute case. **Tests:** RR-24.

### P12 · Supplier return / debit note — *(added)*
- **RPC:** `portal_return_record` (034) → auto `DN-…` debit note; `portal_three_way_status` nets returns. · **UI:** returns panel (backend only; UI pending).
- **Actions:** record return + debit note. **Destinations:** —. **Editable scope:** return lines/qty (≤ received, 039). **Resulting state:** debit note recorded; net due reduced.
- **Approvals reset:** none. **Doc version:** return memo (`ret`). **Authz/SoD:** receipt/quality or procurement. **TARGET:** governed compensating case. **Tests:** RR-24; SQL 15/19.

### P13 · Recurring blocked obligation — *(added)*
- **RPC:** `portal_recurring_run()` (server). · **UI:** recurring panel + (target) blocked queue.
- **Actions:** generate occurrence. **Resulting state:** over-budget → audit `request_id=NULL` + advance `next_run` (silent); doc-required → stays `draft`.
- **Gap RECUR-BLOCKED:** TARGET = durable blocked work item (owner/due/reason/retry/override), not a null-request audit event. **Tests:** RR-25.

### P14 · Cancellation / amendment / closed — *(added)*
- **RPC:** `portal_cancel_request` (005/006) · `portal_payment_void` (051) · `portal_return_record` (034) · closed-txn amendment (target). · **UI:** cancel action.
- **Actions:** cancel (pre-award/procurement) · void · amend. **Destinations:** —. **Resulting state:** `cancelled`/reversed/amended.
- **Rule:** post-payment/receipt uses governed amendment/void/return/dispute — **not destructive rewind.** **Doc version:** preserved. **Authz/SoD:** per action. **TARGET:** explicit compensating cases linked to original. **Tests:** RR-24.

### P15 · Email channel
- **RPC:** `portal_pr_transition_email` (056, cycle-aware) + tokens `portal_create_token`. · **Entry:** one-click links.
- **Actions:** approve (one-click). **Return via email:** not a distinct governed path (ROUTE-EMAIL-PARITY gap). **Tokens:** invalidated on submit/resubmit; one-time; expiry.
- **TARGET:** complex destination → "decision pending in portal"; one-click stays safe/unambiguous; **legacy email only (OWN-EMAIL).** **Tests:** RR-23.

---
**Invariant across all phases:** no arbitrary-user routing today (preserved as target invariant); audit chain (057) retains every event even where live approval rows are overwritten (the HISTORY-PRESERVE compensating control until Stage 5/9 snapshots land).

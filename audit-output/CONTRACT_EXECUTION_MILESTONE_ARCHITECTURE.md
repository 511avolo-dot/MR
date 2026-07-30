# CONTRACT EXECUTION & MILESTONE-PAYMENT ENGINE — ARCHITECTURE (CEM)

> **Status: DESIGN / DOCUMENTATION ONLY.** Owner architecture mandate registered against PR #74.
> **Nothing in this document is implemented.** No SQL, UI, Functions, migration, or test is created by the
> commit that adds this file. Implementation is **gated**: it does not begin until Gate 1 is cleared and the
> relevant later stages (3, 4, 5, 7, 8, 9, 10, 13) are explicitly authorized. No migration number is assigned
> here (`063` is already reserved in the ledger for Stage-9 work-items; CEM tables allocate the next contiguous
> numbers **after** all earlier authorized work, at implementation time). Applied migrations `023`, `027`, `037`
> and every earlier migration are **never edited in place**.

This document is the controlling design for governed **milestone-based contract execution and payment**. It is
purely **additive**: a new domain that sits beside — and never repurposes — the existing single-payment,
split-award, legacy-installment, direct-expense, framework/blanket-contract, receipt, and return flows, all of
which continue unchanged.

> **⏩ CEM v2 DESIGN FREEZE (owner-queued 2026-07-30) — read §15 first.** The owner queued a refined plan (CEM v2)
> with **five mandatory corrections** to the v1 model below and an expanded structured domain + implementation
> package plan (CEM-P0…P9). **§15 is the authoritative freeze**; where it differs from §§1–14 (v1), **§15 wins**.
> This is the **CEM-P0 docs-only design-freeze** deliverable. Binding sequence (owner §0): clear Gate 1 → Stage 2
> → Stage 3 trusted documents → this freeze → implement only in authorized stages, small reviewable commits. **No
> migration number allocated; no DB/config/storage mutation authorized.**

---

## 1. Business outcome & governing principle

Support contracts paid by **governed milestones**:

```
approved award/PO → signed contract + appendices → payment schedule →
site visit / delivery / partial or final acceptance → evidence verification →
certified claim → payment preparation → financial approval → bank execution →
next milestone → final acceptance / retention release → closure
```

**Governing invariant (the reason the module exists):** a payment is **never** created because a user typed an
amount. Every payable amount is **derived server-side** from:

> **approved contract version  +  eligible milestone  +  accepted evidence/quantity/value  +  certified claim.**

When a request has an active milestone-based execution contract, the legacy free-form payment path
(`portal_payment_request`) **fails closed** and the claim-based RPC is required.

---

## 2. Non-breaking boundary (what must NOT change)

| Existing object | Existing meaning — preserved as-is |
|---|---|
| `portal_contracts` / `portal_requests.contract_id` | framework / blanket contract + call-off (037) |
| `portal_requests.pay_installments` | legacy free-form installment mode (027) |
| `portal_receipts` | request-level goods-receipt history (023) |
| `portal_payments` (existing columns) | single / split / installment / direct-expense payments |
| Applied migrations `023`, `027`, `037` (+ earlier) | **immutable — never edited in place** |

The awarded **execution contract** is a **separate additive domain** (`portal_execution_*`,
`portal_contract_milestones`, `portal_acceptance_*`, `portal_milestone_claims`, new nullable columns on
`portal_payments`). Existing rows are **classified**, never converted:
`legacy_single · legacy_split · legacy_installments · framework_legacy`. **No automatic migration** of history
into milestone contracts.

---

## 3. Domain model

### 3.A Execution contract & immutable versions

**`portal_execution_contracts`** — one active execution contract per awarded request.
- `id`, `request_id` (FK, one active per request), `award_ref` (approved award/`winner_offer_id` snapshot),
  `framework_contract_id` (nullable FK → `portal_contracts`), supplier/beneficiary **snapshot**
  (name/IBAN/tax-id captured at creation, not a live pointer), `execution_mode`
  (`supply | service | works | mixed`), `state` (`draft | active | suspended | terminated | closed`), audit cols.

**`portal_execution_contract_versions`** — the legal & financial snapshot; **immutable after publication.**
- `id`, `execution_contract_id`, `version_no` / `amendment_no`, `effective_from`/`effective_to`, `currency`,
  `vat_basis`/`vat_rate` snapshot, `approved_value` (base currency + original currency + `fx_rate` snapshot),
  `start_date`/`end_date`, `retention_policy` (pct/cap/release-condition), `advance_policy`
  (pct/cap/recovery-rule), `status` (`draft → under_review → published → superseded | terminated`).
- An **amendment creates a new version**; it never rewrites prior milestones, claims, receipts, payments, or
  approvals. `published` and any version referenced by a certified/paid claim are **immutable**.

**`portal_execution_contract_documents`** — signed contract, scope, BOQ, payment schedule, guarantees,
insurance, appendices, amendments.
- Immutable / versioned; **supersession, never overwrite/delete**. **No raw client-provided storage key** — every
  link is a trusted document object from the Stage-3 upload-receipt mechanism (see §8).

### 3.B Payment schedule

**`portal_contract_milestones`**
- `id`, `contract_version_id`, `seq` / `code` / `title`.
- `trigger_type`: `award | advance | delivery | site_visit | progress | partial_acceptance | final_acceptance | retention_release | custom`.
- `allocation_method`: `fixed_amount | percentage`; `scheduled_amount` / `scheduled_pct`.
- `due_rule` / `due_date`, `grace_sla`, retention/advance rules, `allow_partial_claim` (bool), `state`.

**`portal_contract_milestone_dependencies`** — **explicit** dependency graph (`milestone_id`,
`depends_on_milestone_id`). No implicit "previous row" assumption.

**`portal_milestone_evidence_requirements`** — per milestone: required document `role`/`type`, `min_count`,
mandatory `issuer`/`verifier`, quantity/value requirement, `acceptance_required` (bool).

**Schedule validation before publication (server-side, one transaction):**
1. no duplicate `seq`/`code`;
2. valid dependency graph, **no cycle** (topological check);
3. allocated earned value **equals** the approved contract basis within the **exact configured tolerance**;
4. no negative values;
5. advance/retention treatment **explicitly** defined;
6. **no milestone exceeds the remaining contract value.**

### 3.C Execution evidence & acceptance (generic, not "every doc is a goods receipt")

**`portal_acceptance_records`**
- `type`: `site_visit | delivery_note | goods_receipt | service_acceptance | progress_certificate | handover | final_acceptance | defect | return`.
- Links: `request_id`, `execution_contract_id` / `contract_version_id`, `milestone_id`, optional `claim_id`.
- `state`: `draft → submitted → accepted_partial | accepted | rejected | returned | superseded`.
- `accepted_qty`, `accepted_value`, `period`, `location`, `verifier`, timestamps, reason.

**`portal_acceptance_lines`** — `acceptance_id`, item/BOQ line, delivered/inspected/accepted/rejected qty & value.

**Evidence-document links** — every uploaded PDF/image is bound through the Stage-3 trusted
document-object / upload-receipt mechanism (§8).

> A **site visit** may be evidence **without** creating a payable amount. A receipt or progress certificate
> creates **eligibility only when the milestone policy says it does.**

### 3.D Certified claims

**`portal_milestone_claims`**
- `id`, `milestone_id`, `contract_version_id`; **multiple claims per milestone** when partial claims allowed.
- `claimed_amount`/`qty`/`period`; `certified_amount`; `deductions`; `retention`; `advance_recovery`; `vat`;
  `net_payable`; currency + `fx_rate` snapshot.
- `state`: `draft → submitted → returned | rejected → certified → payment_created → paid | voided`.
- Claim evidence links + **append-only claim events**.

> Partial acceptance → **certified partial claim**; the remainder stays open. A **correction** creates a new
> revision/claim and **preserves** the old record (actors/comments/timestamps intact).

### 3.E Payment integration

Add **nullable** links/snapshots to `portal_payments` (additive columns only — existing rows unaffected):
`milestone_claim_id`, `execution_contract_version_id`, and snapshots of `certified_gross`, `deductions`,
`retention`, `advance_recovery`, `vat`, `net_payable`, `currency`/`fx_rate`.

**New server RPC `portal_create_payment_from_claim(claim_id, …)`** — the **only** way to create a
milestone-contract payment:
1. `FOR UPDATE` locks on contract, milestone, claim, and relevant payments;
2. derives the amount **server-side** (never from client input);
3. verifies the claim is `certified` and unpaid;
4. verifies **all mandatory evidence is trusted and accepted**;
5. enforces contract / milestone / claim **remaining balances**;
6. creates **at most one active payment per claim** via unique constraint + idempotency key.

`portal_payment_request` remains the **legacy** path. With an active milestone-based execution contract,
direct/free-form payment creation **fails closed** and requires the claim-based RPC. Existing payment SoD is
kept: **preparer ≠ approver ≠ bank executor**, except the owner-accepted **audited admin override**.

---

## 4. Parent-request compatibility

Do **not** drive the whole request through `receipt_pending` after every installment. Keep the parent request
compatible with current status consumers; the **execution-contract / milestone tables are the canonical
sub-ledger**. A non-final milestone payment:
- marks **only** that claim / payment / milestone paid;
- unlocks dependent milestones;
- does **not** close the request or force final receipt.

**Parent request closes only when ALL hold** (computed server-side):
1. final acceptance approved; 2. no required milestone open; 3. no certified payable amount unpaid;
4. retention released or formally waived; 5. no unresolved return/defect/dispute/work item;
6. contract total, payments, debit notes and amendments **reconcile**.

Expose a **computed execution-status view/RPC** (`portal_execution_status(request_id)`) for the UI — no scattered
client-side status inference.

---

## 5. Financial invariants (server-side, one transaction, row/advisory locking)

- active/pending/approved/disbursed payments **cannot exceed** certified net payable;
- cumulative certified earned value **cannot exceed** active contract version + approved amendments;
- cumulative cash, after debit notes/refunds, **cannot exceed** contract cap;
- a claim cannot exceed the **milestone remainder**; a milestone cannot exceed the **contract remainder**;
- returns / debit notes **reduce** future payable balance;
- published versions and certified/paid claims are **immutable**;
- final settlement uses **exact numeric values**; rounding policy is **explicit and tested**;
- **no duplicate payment** from double-click, retry, concurrent tab, or API replay (idempotency + unique
  constraint, reusing the Stage-2 `portal_idempotency` pattern from 051).

**Retention = a ledger balance**, not a hidden extra percentage. **Advance payment/recovery is explicit**, so
total cash can never accidentally exceed the contract. Both are tracked as running balances on the contract
version, reconciled at closure.

---

## 6. Capabilities & Segregation of Duties (Stage 4 — versioned, NOT reuse of broad keys)

New granular capabilities (added in Stage 4, **not** broad reuse of `can_manage_procurement`/`can_disburse`):

`can_manage_execution_contract · can_define_payment_schedule · can_publish_execution_contract ·
can_submit_milestone_evidence · can_verify_site_visit · can_record_acceptance · can_certify_milestone_claim ·
can_prepare_payment · can_approve_payment · can_execute_payment · can_release_retention · can_amend_contract ·
can_close_execution_contract`.

**Required SoD:**
- submitter/claimant **cannot** be the sole verifier/certifier;
- payment **preparer** cannot approve or execute the same payment;
- payment **approver** cannot execute it.

Admin override remains possible **only** with an explicit override label + reason + immutable audit
(hash-chained, 057).

---

## 7. RPC boundary (no direct table writes)

Direct writes to the new tables are **not** exposed. Planned RPC families:

| Family | RPCs (planned names) |
|---|---|
| Contract | `portal_ec_create_draft · portal_ec_update_draft · portal_ec_submit_version · portal_ec_publish_version · portal_ec_return_version · portal_ec_terminate` |
| Schedule | `portal_ms_define · portal_ms_validate · portal_ms_publish_schedule · portal_ec_create_amendment` |
| Acceptance | `portal_acc_create · portal_acc_submit · portal_acc_return · portal_acc_accept` |
| Claim | `portal_claim_create · portal_claim_submit · portal_claim_return · portal_claim_certify` |
| Payment | `portal_create_payment_from_claim` (+ reuse existing approve/execute transitions) |
| Retention | `portal_retention_release · portal_retention_waive` |
| Lifecycle | `portal_ec_suspend · portal_ec_resume · portal_ec_close` |
| Read-only | `portal_ec_dossier · portal_execution_status · portal_ec_simulate` |

Every mutating RPC validates: **current version/state · capability · SoD · expected revision number · evidence ·
amount ceilings · idempotency**, then writes the **domain event + audit in the same transaction**.

---

## 8. Document architecture (depends on Stage-3 DOC-RECEIPT)

**Hard dependency:** no contract, acceptance, claim, or payment evidence may be registered from an arbitrary
storage key. This requires the Stage-3 trusted-document layer (ledger `S3-RECEIPT` / `DOC-RECEIPT`, P0,
release-blocking) to land first.

Shared layer:
- trusted document object produced by a **server-issued single-use upload receipt**;
- verified object metadata / checksum / MIME / size / owner / purpose;
- **immutable links** from that object to request, execution-contract version, milestone, acceptance, claim, or
  payment;
- **supersession** instead of overwrite/delete;
- orphan cleanup + negative tests.

The **unified dossier** shows: signed contract + every version/amendment, schedule, site visits,
delivery/acceptance records, invoices, claims, payment approvals, transfer proofs, returns/debit notes, and the
final closure trail.

---

## 9. Corrections, amendments & routing (integrate with Stage-9 engine)

Do **not** implement ad-hoc `return_to` strings. All corrections route through the Stage-9 work-routing engine
(`portal_work_items` / `portal_routing_policies`). Governed routes:

| Route | From → To | Guard |
|---|---|---|
| CEM-RT-CONTRACT | contract → contract author | `can_manage_execution_contract`; version `draft`/`returned` only |
| CEM-RT-EVIDENCE | evidence → submitter | `can_submit_milestone_evidence`; acceptance not yet accepted |
| CEM-RT-ACCEPT | acceptance → receiver/verifier | `can_record_acceptance`/`can_verify_site_visit` |
| CEM-RT-CLAIM | claim → claimant/procurement | `can_certify_milestone_claim` returns; claim not certified |
| CEM-RT-PAYMENT | payment → preparer / certified-claim correction | `can_prepare_payment`; payment not executed |
| CEM-RT-AMEND | amendment → procurement/legal/finance/DoA | `can_amend_contract` + workflow |
| CEM-RT-DEFECT | defect/dispute/suspension work item | `can_record_acceptance`/procurement |

Prior approvals and evidence remain visible. A correction creates a **new revision/cycle** and never clears
historical actors/comments/timestamps.

---

## 10. Migration & rollout safety

- **Never** edit applied migrations `023`, `027`, `037`, or any earlier migration.
- **No migration number assigned in this design.** At implementation, allocate the next contiguous number
  **after** all earlier authorized work (`063` is already reserved for Stage-9 work-items).
- Additive tables, **nullable** FKs, views, and RPCs first.
- Existing rows classified `legacy_single | legacy_split | legacy_installments | framework_legacy`; **no automatic
  conversion**.
- Feature **disabled by default** (settings flag, default 0) until isolated staging + migrations + roles + E2E
  are ready.
- Rollback **disables new creation** while preserving read-only history; **never** drops evidence/payment tables
  containing data.

---

## 11. Stage placement (ledger rows added now; implementation gated)

| Stage | CEM scope |
|---|---|
| **3** | trusted document objects / upload receipts for all contract evidence |
| **4** | dedicated capabilities / role scopes (§6) |
| **5** | versioned approval workflows, snapshots, amendment approvals |
| **7** | execution-contract / version / schedule / PO integration |
| **8** | acceptance, claims, retention/advance ledgers, claim-based payments |
| **9** | returns / corrections / work items (§9) |
| **10** | contract dossier, timeline, schedule & payment-monitor UI |
| **13** | full staging E2E / concurrency / regression |

---

## 12. Mandatory regression & acceptance suite (implementation-time)

| # | Test | Expect |
|---|---|---|
| 1 | legacy single payment | unchanged |
| 2 | legacy `pay_installments` | unchanged |
| 3 | split-award supplier payments | unchanged |
| 4 | framework call-off contract | unchanged |
| 5 | direct expense | unchanged |
| 6 | signed contract publish w/o mandatory trusted docs | **rejected** |
| 7 | invalid schedule sum / cycle | **rejected** |
| 8 | site visit alone | does **not** pay unless policy allows |
| 9 | partial acceptance → partial claim → partial payment | remainder stays open |
| 10 | rejected/returned acceptance | **cannot** create payment |
| 11 | certified claim under concurrent retries | **one** payment only |
| 12 | payment > certified net / milestone / contract remaining | **rejected** |
| 13 | amendment | preserves prior version/claims/payments; changes only future eligibility |
| 14 | retention release before condition | **rejected** |
| 15 | debit note / return | reduces payable balance |
| 16 | preparer/approver/executor SoD | positive + negative |
| 17 | forged/unverified document object | **rejected** |
| 18 | non-final payment | does **not** move parent to final receipt/closed |
| 19 | final close with any milestone/payment/retention/dispute open | **rejected** |
| 20 | full award→contract→milestones→evidence→acceptance→claims→payments→final-close | browser journey passes on staging |

---

## 13. Honest current-state gaps (why this module is needed)

- **Existing contract record (`portal_contracts`, 037)** has **no attachments and no versions** — it is a cap +
  period + call-off link, not a signed, versioned, milestone-scheduled execution contract.
- **Existing installments (`pay_installments`, 027)** accept **arbitrary amounts** with **optional** evidence —
  there is no certified-claim gate, no earned-value ceiling beyond the award total, no retention/advance ledger.
- **Current receipt (`portal_receipts`, 023)** is **request-level** and **final-payment-driven** — it is not a
  per-milestone, typed acceptance record with accepted quantity/value and partial-acceptance semantics.
- There is **no** claim object, **no** retention/advance ledger, **no** amendment/version immutability, and **no**
  server RPC that derives a payment from an accepted, certified milestone.

CEM closes these gaps **additively**, behind capability + settings gates, without touching any of the flows above
until each stage is authorized.

---

## 14. Cross-references

- Ledger rows: `MASTER_DELIVERY_LEDGER.md` → **CEM-\*** (feature block + per-stage requirements register).
- Routing: `RETURN_ROUTING_PHASE_MATRIX.md` / `_PERMISSION_MATRIX.md` / `_TEST_MATRIX.md` → **CEM-RT-\*** rows.
- Planned artifacts: `ARTIFACT_INVENTORY_APPENDIX.md` → **CEM planned artifacts** (all marked *planned/open*).
- Dependencies: `DOC-RECEIPT`/`S3-RECEIPT` (Stage 3, P0), Stage-9 routing engine (`S9-*`), Stage-4 capabilities.

---

## 15. CEM v2 — DESIGN FREEZE (owner-queued 2026-07-30; authoritative over §§1–14 where they differ)

**Status: design freeze / implementation queue only. Not implemented; no migration number allocated; no DB/UI/
config/storage mutation authorized.** This is the **CEM-P0** deliverable (docs-only). Based on the real current
boundaries in migrations 023/027/037/050/051 and the v1 design at `e3f50d7`. Goal: enterprise-grade without
breaking single-payment, split-award, legacy-installment, framework-contract, direct-expense, receipt, return, or
payment-approval paths (all remain byte-for-byte behaviorally unchanged unless a later authorized migration says
otherwise).

### 15.0 Binding sequence (owner §0)
1. Finish + independently clear **Gate 1**. 2. Complete **Stage 2** security boundaries. 3. Complete **Stage 3**
trusted document-object/upload-receipt layer. 4. Freeze CEM v2 (this section). 5. Implement only in authorized
stages, in small independently-reviewable commits. 6. No migration number now; no mutation authorized by this.

### 15.1 Five mandatory corrections to the v1 model
- **CEM-V2-01 — contract cardinality supports split awards.** Do **not** enforce "one execution contract per
  request." Canonical: **one execution contract per awarded party / PO slice** — single award =
  `request_id + award_offer_id=NULL`; split award = one contract per `request_id + award_offer_id`. A request-level
  **dossier aggregates** all its execution contracts; the parent request closes only when **every required
  execution contract is closed**. Schema must not block future split-award milestone contracts even if the first
  release enables single-award only. *(Supersedes v1 §3.A "one active execution contract per request".)*
- **CEM-V2-02 — separate earned value from cash-only events.** The schedule distinguishes `earned_value` (supply/
  service/work actually earned) · `advance` (cash before earning) · `retention_release` (release of withheld
  money) · `adjustment` (approved change/debit/credit). **Sum of published `earned_value` allocations = contract
  net value.** Advances tracked in an **advance balance** and recovered later; retention withheld from claims and
  released from a **retention balance**; cash events may **never** inflate earned value or the contract ceiling.
- **CEM-V2-03 — balances come from an append-only ledger.** Add authoritative append-only
  **`portal_contract_financial_events`**; do **not** rely on mutable running-balance columns as source of truth.
  Event classes: `contract_value · amendment_delta · advance_paid · earned_certified · retention_withheld ·
  advance_recovered · deduction · penalty · debit_note · credit_note · payment_created · payment_disbursed ·
  refund · retention_released · writeoff`. A computed status RPC/view derives approved value · earned/certified ·
  invoiced · paid · retained balance · advance balance + recovered · deductions/debit-notes/refunds · remaining
  value · remaining cash exposure.
- **CEM-V2-04 — invoice, guarantee, amendment are structured records** (documents alone insufficient):
  `portal_contract_amendments` (reason/delta/effective date/affected future milestones/approval state/old↔new
  version linkage) · `portal_contract_guarantees` (advance guarantee/performance bond/retention guarantee/
  insurance; issuer/amount/issue+expiry/state/trusted doc) · `portal_supplier_invoices` (supplier/invoice
  no+date/taxable base/VAT/total/currency/claim link/trusted doc/duplicate prevention) · `portal_claim_adjustments`
  (explicit retention/advance-recovery/penalty/deduction/debit+credit/rounding rows). A version reduction **below
  already certified/paid exposure fails closed** unless an approved recovery/debit plan exists.
- **CEM-V2-05 — never call the legacy receipt closure path for milestone acceptance.** `portal_record_receipt`
  may close the parent request; the CEM acceptance engine must **not** call it. Goods: the acceptance RPC may
  update `portal_request_items.received_qty` via a **dedicated internal compatibility helper** but must **not** move
  the parent to `closed`/`receipt_pending` after a non-final milestone (CEM sub-ledger stays canonical).
  Services/works: acceptance by period/quantity/BOQ line/progress %/certified value, not stock quantity.

### 15.2 Canonical data model (v2 — additive, planned/open)
- **Identity/versioning:** `portal_execution_contracts` (request + **awarded-party** linkage, framework linkage,
  supplier/beneficiary/legal/tax/bank snapshots, mode `supply|service|works|mixed`, state
  `draft|under_review|active|suspended|terminated|closed`, `current_version_id`/revision/audit) ·
  `portal_execution_contract_versions` (immutable after publish; contract+base currency, exact FX snapshot policy,
  net value, VAT policy/rate, dates, retention+advance policies, version/amendment nos, state
  `draft|under_review|published|superseded|terminated`) · `portal_execution_contract_documents` (trusted IDs only,
  supersession never overwrite/delete).
- **Milestones:** `portal_contract_milestones` (+ **`economic_type`**: earned_value|advance|retention_release|
  adjustment; `trigger_type`; fixed/pct; due/SLA; partial-claim; retention/advance treatment; state/revision) ·
  `portal_contract_milestone_dependencies` (explicit **DAG** + server cycle detection pre-publish) ·
  `portal_milestone_evidence_requirements` (doc role/type/count; issuer/verifier; whether acceptance/quantity/value/
  invoice/guarantee mandatory).
- **Acceptance:** `portal_acceptance_records` (types site_visit…final_acceptance/defect/return; states
  `draft→submitted→returned|rejected|accepted_partial|accepted|superseded`) · `portal_acceptance_lines`
  (request/BOQ/item line; delivered/inspected/accepted/rejected qty+value; reject reason; period/location/verifier).
- **Claims/invoices:** `portal_milestone_claims` (multi only where partial allowed; claimed/accepted/certified;
  state `draft→submitted→returned|rejected→certified→payment_created→paid|voided`; immutable after certify except
  governed void) · `portal_supplier_invoices` (unique supplier+invoice no; date/currency/base/VAT/total; claim
  link; trusted doc; duplicate + over-invoicing checks) · `portal_claim_adjustments` (typed rows; **no opaque
  client-calculated JSON total**).
- **Payment integration:** nullable CEM refs/snapshots on `portal_payments` only (contract/version, claim,
  certified gross, VAT, retention, advance recovery, deductions/penalties, net payable, currency/FX).
  `portal_create_payment_from_claim` is the **only** creation path for an active CEM contract;
  `portal_payment_request` **fails closed** for that awarded party.

### 15.3 Financial calculation contract (server-side, one txn, exact `numeric`, explicit rounding)
`accepted earned value + approved taxable additions = certified gross before VAT; + VAT (contract/invoice
snapshot) − retention withheld − advance recovery − penalties/deductions − debit notes/prior overpayments ±
approved rounding = net payable.` **Hard invariants:** certified earned ≤ accepted evidence value · claim ≤
milestone earned-value remainder · Σ certified earned ≤ current approved contract value · invoice ≤ certified
(per policy) · active/pending/approved/disbursed payment ≤ certified net payable · cumulative cash net of
refunds/debit-notes ≤ legal exposure · advance balance never negative · retention released ≤ retained balance ·
one active payment per claim · retries/concurrent tabs exactly-once (idempotency + unique) · published versions,
accepted records, certified/paid claims immutable. **Snapshot each claim's tax basis — never reuse the global
current VAT for historic claims.**

### 15.4 State/workflow rules
Every mutating RPC takes **expected revision/version**, **idempotency key** (retryable ops), explicit action/reason
(return/reject/suspend/terminate/waive/override); validates capability + state + **SoD** + trusted evidence +
financial ceilings + revision, then writes domain event + audit in the same txn. Contract/amendment approval uses
the **Stage-5 versioned subject-aware workflow engine** — do not create a second weaker `request_id`-only engine.
**SoD:** contract author ≠ sole publisher · evidence submitter ≠ sole acceptance verifier · claimant ≠ sole
certifier · payment preparer ≠ approver ≠ bank executor · admin override needs reason + label + immutable audit.

### 15.5 Parent-request compatibility
Explicit execution classification `legacy | milestone` (no existing-row change). CEM request: non-final milestone
payments do **not** move parent to `receipt_pending`/`closed`; parent stays compatible with existing consumers
while `portal_execution_status(request_id)` supplies detail; dependent milestones unlock from the DAG. **Final
parent closure requires:** all awarded-party contracts closed · final acceptance · no unpaid certified claim ·
retention released/waived · no unresolved defect/dispute/work item · full financial reconciliation. Legacy single/
split/installment/direct-expense/framework flows remain byte-for-byte behaviorally unchanged.

### 15.6 Implementation packages & review gates (each = separate focused commit/series, independently reviewed)
| Pkg | Scope | Gate |
|---|---|---|
| **CEM-P0** | design freeze (this §15), ERD/state/financial/capability/RPC/migration-map matrices, sample scenarios; all planned/open | docs-only (**this deliverable**) |
| **CEM-P1** | foundation schema (additive types/tables/indexes/guards/events), **feature disabled**, no UI, no direct authenticated writes, RLS read + service/RPC boundaries, flags default off, install/rollback + schema tests | Stage 7 |
| **CEM-P2** | contract/version/document/guarantee RPCs (create/update/submit/return/publish/supersede/suspend/terminate; trusted docs only; guarantee expiry/activation gates; optimistic-concurrency + immutability tests) | Stage 7 |
| **CEM-P3** | milestone schedule engine (define milestones/deps/evidence; economic-type rules; cycle detection + exact allocation validation; simulation + publication; amendment limited to future/open exposure) | Stage 7 |
| **CEM-P4** | acceptance engine (typed records/lines; partial/reject/return/defect/supersede; goods compat helper **no parent closure**; service/works value-period acceptance; evidence enforcement) | Stage 8 |
| **CEM-P5** | claims/invoices/adjustments + **append-only financial ledger**; invoice uniqueness + tax snapshots; advance/retention/deduction/debit-note balances; computed status views | Stage 8 |
| **CEM-P6** | claim-derived payment RPC; legacy path fail-closed only for active CEM awarded party; reuse approval/execution transitions + exactly-once; no premature parent closure; reconciliation + concurrency tests | Stage 8 |
| **CEM-P7** | amendments/returns via **Stage-9 governed routes** (no free-form `return_to`); contract/acceptance/claim/payment/defect/amendment work items; preserve every prior actor/comment/timestamp/revision; no destructive reset | Stage 9 |
| **CEM-P8** | UI dossier (tabs: Overview·Versions/Documents·Milestones·Visits/Acceptance·Claims/Invoices·Payments·Guarantees·Amendments·Audit) + role queues; UI shows source amounts + server-derived totals, **never computes authoritative payable** | Stage 10 |
| **CEM-P9** | isolated-staging acceptance + controlled rollout (full migrations + trusted storage; browser E2E by role; concurrency/stale-revision/retry; legacy regression; disabled→allowlist pilot→enforce only after owner approval) | Stage 13 |

### 15.7 Minimum test suite (v1's 20 + these ≥24; every report separates PASS/FAIL/SKIPPED/NOT RUN — green CI alone ≠ release evidence)
1 single-award · 2 split-award separate supplier contracts · 3 framework call-off → execution contract · 4 advance
with missing/expired guarantee rejected · 5 advance excluded from earned-value allocation · 6 full advance recovery
across later claims · 7 retention withheld + released only after condition · 8 partial goods acceptance updates
quantities without closing parent · 9 service/progress-value acceptance · 10 duplicate supplier invoice rejected ·
11 invoice/claim/VAT mismatch rejected · 12 amendment increase changes only future capacity · 13 amendment decrease
below paid/certified exposure rejected · 14 concurrent claim certification · 15 concurrent payment → one payment ·
16 stale expected revision rejected · 17 forged/unverified document rejected · 18 returned acceptance cannot be
claimed · 19 site visit alone does not pay unless policy permits · 20 debit note reduces future payable · 21
refund/void updates ledger without rewriting history · 22 parent cannot close with open contract/claim/retention/
defect/dispute · 23 all legacy payment modes unchanged · 24 full browser journey award→final account→closure.

### 15.8 Rollout / rollback / definition of done
Staged flags default off: CEM read/dossier visibility · CEM new-contract creation · CEM payment-path enforcement.
Rollback disables new actions + enforcement while preserving all contract/evidence/claim/payment/ledger history
read-only; **never** drop populated tables or rewrite paid history. **Done only when:** all dependencies (trusted
documents, capabilities, versioned workflow, routing) live in isolated staging · schema/RLS/RPC/financial/
concurrency tests pass · browser journeys pass per role · split-award cardinality + legacy compatibility proven ·
totals reconcile in original + base currency · no Blocker/Critical/High remains · independent review on the exact
final SHA · owner explicitly authorizes rollout.

### 15.9 Name-collision & source review (REQUIRED before CEM-P1 — owner "final names only after a collision/source review")
Honest gaps found against the live schema — resolve at CEM-P1, do **not** reuse a name that already means something else:
- **`portal_supplier_invoices` COLLIDES** with the **existing** table from migration **033** (three-way match:
  `request_id`, `invoice_no`, `doc_key`, cross-request duplicate detection). CEM v2 §3.4 must **either** extend
  033's table additively (nullable `milestone_claim_id`/`execution_contract_version_id` + tax-basis snapshot cols)
  **or** use a distinct CEM name (e.g. `portal_contract_invoices`). **Decision deferred to CEM-P1** with owner sign-off.
- **`portal_returns`/debit-note** already exist (034); CEM adjustments (`portal_claim_adjustments`) must reconcile
  with — not duplicate — 034's debit-note numbering/ledger.
- **`portal_beneficiaries`/beneficiary IBAN control** (053) is the canonical bank-detail source; execution-contract
  supplier/bank **snapshots** reference it, they do not create a parallel master.
- **`portal_idempotency`** (051) is the exactly-once substrate — CEM payment creation reuses it, no new mechanism.
- Existing `portal_contracts` (037) = framework/blanket; the new `portal_execution_contracts` is distinct — the
  `framework_contract_id` link is the only bridge. Naming must keep the two visibly separate in every artifact.

---

## 16. CEM multi-party operating model (owner requirement 2026-07-30 — CEM-P0 docs-only; planned/open)

**Design requirement only; no SQL/UI/migration authorized until Gate 1 + prerequisite stages cleared.** Extends
§15. Preserves a clear **source of truth by lane** — the module must not put every field in one shared editable form.

### 16.1 Three accountable operating lanes (RACI)
| Lane | Owns (source of truth) | May do | May NOT do |
|---|---|---|---|
| **Sector / service-recipient (technical owner)** | execution %, delivered/accepted/rejected qty, technical completion, visit/acceptance notes, defect observations, technical evidence | see only its dept/sector-scoped contracts/milestones/visits/acceptances/claims/deductions; create site-visit/delivery/service-completion/partial+final acceptance/defect records; upload trusted docs (Stage-3 receipt); enter accepted/rejected qty+value, technical deductions, recommended payable; draft claim when assigned | certify financially; create/execute own payment; alter contract price/schedule/tax/retention/advance; edit already accepted/certified records |
| **Procurement / contract admin (contractual owner)** | contract version, milestone rules, BOQ entitlement, amendments, contractual deductions, retention/advance policy, guarantees | create/administer contract/versions/amendments/BOQ/schedule/guarantees/evidence-reqs; operational prep on sector delegation (records acting lane+actor); review sector acceptance vs terms; confirm entitlement/variation/LD/retention/advance/balance; **return to a named prior work item with reason** (no silent edit of sector's version); submit validated claim to Finance | silently edit the sector's submitted version |
| **Finance (financial/payment owner)** | invoice validation, tax/accounting classification, financial deduction confirmation, payment-prep data, payment transition fields | read-only dossier + controlled financial work form; validate invoice/tax/budget(info)/beneficiary/arithmetic; **return to exact responsible lane** (sector/procurement/claimant/preparer) with mandatory reason+corrections; create/approve/execute payment per capability+SoD (amount **server-derived**) | rewrite accepted qty/contract terms/prior certified records (correction = new revision/cycle) |
| **Server** | derived payable, cumulative balances, remaining milestone/contract value, eligibility, current state, routing owner, close readiness | — | — |

### 16.2 Shared dossier + role queues (server-authoritative)
**One unified dossier** per contract/request: summary + supplier/beneficiary snapshot · versions/amendments ·
milestone schedule+deps · visits/deliveries/acceptance · claims/invoice versions · deductions/penalties/retention/
advance-recovery · payment requests/approvals/bank proofs/balances · returns/comments/defects/work-items ·
immutable timeline/audit. **Queues** (a server work-item/status RPC returns authoritative current owner + due/SLA +
allowed actions + why): Sector `awaiting_visit|awaiting_delivery_confirmation|awaiting_acceptance|returned_to_sector|
defect_followup` · Procurement `contract_draft|schedule_review|awaiting_contractual_validation|returned_to_procurement|
amendment_review|guarantee_expiry` · Finance `awaiting_financial_review|returned_from_finance|
ready_for_payment_preparation|awaiting_payment_approval|ready_for_bank_execution|retention_ready`. **No queue
inferred only in the browser.**

### 16.3 Governed return & correction (no free-text `return_to`)
Versioned routing policies + append-only work items (Stage-9). Destinations: Finance→sector (acceptance/qty/visit/
evidence) · Finance→procurement (term/amendment/milestone/retention/advance/contractual deduction) · Finance→payment
preparer (bank/payment/doc) · Procurement→sector (incomplete evidence/qty/acceptance reason) · Procurement→claimant/
preparer (claim/invoice mismatch/attachment) · Sector/Procurement→supplier-facing follow-up (internal work item until
an external portal is designed). Every return requires: target lane + work-item type · reason code + mandatory
comment · required fields/docs to correct · actor/timestamp/expected revision · SLA/due + escalation · immutable link
to the returned revision.

### 16.4 Editing rules (no destructive overwrite)
Drafts editable only by current assignee within field-level capability · submission **freezes** the revision · return
creates a **new revision** copied from last submitted (prior stays visible) · accepted/certified/paid immutable ·
post-certification correction = adjustment claim / debit-credit note / amendment / reversal (never direct UPDATE) ·
concurrent/stale needs `expected_revision` (mismatch fails closed, shows newer) · every mutation writes domain event +
audit in the same txn.

### 16.5 State flow (multi-lane)
`milestone_open → evidence_draft → evidence_submitted → technical_review → (accepted_partial|accepted|
returned_technical|rejected) → claim_draft → claim_submitted → contractual_review → (returned_contractual|
contractually_validated) → financial_review → (returned_financial|financially_validated) → certified →
payment_created → payment_approved → disbursed → reconciled`. A return goes to a **new revision** in the relevant
earlier lane; never resets/deletes prior approvals/comments/timestamps.

### 16.6 Controls
Dept/sector-scoped RLS + explicit cross-sector assignment/delegation · **field-level write boundary enforced in RPCs**
(not only hidden UI) · sector submitter ≠ sole technical acceptor/certifier · technical acceptor ≠ sole contractual
validator (two-lane policy) · preparer ≠ approver ≠ bank executor (admin override audited) · no claim to Finance
without required trusted evidence + accepted technical record · Finance cannot pay from returned/unaccepted/
uncertified revision · return/revision cycles retain all docs+comments, never duplicate payable.

### 16.7 Finance UI acceptance (reconciliation summary at top)
contract value / amendments / current cap · milestone scheduled/previously-certified/remaining · accepted value ·
gross claim, VAT, retention, advance recovery, deductions, net payable · prior paid/pending + contract remaining ·
document-completeness + discrepancy flags. Action panel shows only authorized actions with plain-language reason:
`اعتماد · إرجاع للقطاع · إرجاع للمشتريات · إرجاع لمُعدّ الصرف · رفض · تعليق · إنشاء صرف`. Sector/procurement see the
same timeline + financial consequences; **sensitive bank data restricted to authorized finance/procurement** per the
Stage-2 privacy design.

### 16.8 Multi-party tests (added to CEM acceptance suite)
1 Sector A cannot see/mutate Sector B records · 2 sector visit+partial-acceptance+docs → procurement validates →
Finance sees full dossier · 3 Finance returns to sector, old revision immutable, corrected revision resumes at right
step · 4 Finance returns to procurement without reopening accepted technical qty · 5 unauthorized lane cannot edit
another lane's fields via direct table/API · 6 missing technical doc blocks claim submission/financial review · 7
returned/retried/concurrent claim → no duplicate payment · 8 partial acceptance+deductions → correct net payable,
remainder open · 9 post-certification correction uses adjustment/debit/credit, preserves original certified claim ·
10 full sector→procurement→finance→bank browser journey on isolated staging incl one return-and-resubmit.

**CEM-P0 doc updates delivered by §§15–16:** RACI/lane matrix · field-ownership matrix · work-item/routing state
machine · return reason/destination rules · per-lane capability outline · revision/concurrency model · finance
reconciliation layout · positive/negative tests. **All planned/open until independently reviewed.**

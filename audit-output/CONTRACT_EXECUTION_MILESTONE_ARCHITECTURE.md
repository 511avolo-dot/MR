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

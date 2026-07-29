# MASTER DELIVERY LEDGER — PR #74 (System 3)

**Authoritative controlling ledger** for the owner MASTER EXECUTION PROGRAM (Stages 0–15).
Every requirement/finding has a stable ID and a status. **No item disappears silently**; scope may only grow by adding explicit rows.
**Rule:** `verified` requires the stated test type actually run — never from static inspection or code comments alone.

- **Branch:** `audit/enterprise-certification-2026-07-27` · **PR #74 (Draft, do not merge)** · **Head at ledger creation:** `d103215`
- **Binding constraints:** no production/DB/storage/config change; `budget_enforce=0`; `txn_notifications=0`; Systems 1/2 unchanged; manual IBAN allowed (reason+badge+audit); admin superuser accepted (labeled+audited).

Status vocabulary: `open` · `implemented` (code merged, not yet independently test-verified) · `verified` (test type run) · `accepted-risk` (owner-approved) · `deferred-with-approval`.

---

## 1. Reconciliation (supersedes stale certification language)

| Item | Stale claim (old PR body) | **Current truth (head d103215)** |
|---|---|---|
| Verdict | "READY WITH CONDITIONS" | **NOT READY (WIP)** |
| Findings | "0 HIGH" | Multiple owner/Codex P1 open (see §4) |
| Migrations | "059 only" | 059 applied live; **060–062 repo-only, NOT applied** |
| Assertions | "194" | **222** (197 SQL + 18 file-guard + 7 endpoint) |
| PR body | stale | **Updated d103215** (NOT READY, 060–062, 222) |

**Inventory of record:** `audit-output/SYSTEM_INVENTORY.md` (updated counts below). System-3 objects in `portal-standalone.sql` at this head: **35 tables · 171 functions · 27 triggers · 30 policies**; **29 test files** (222 assertions); migrations through **062**; **next free migration number = 063**.

---

## 2. Migration dependency map (059 → next)

| Migration | Purpose | Live-applied? |
|---|---|---|
| 059 | SEC-01 revoke anon sensitive reads | **YES (verified live)** |
| 060 | AUTHZ-01 expense dept binding + recurring budget | repo-only |
| 061 | Codex round-2 hardening | repo-only |
| 062 | Supporting documents (round-3/4 + R1 folded in-place) | **repo-only — NOT applied anywhere** |
| **063 (next free)** | reserved — Stage 9 work-items / routing policies (not yet created) | — |

Ordering rule: 059→060→061→062 then 063+. 062 verified to apply cleanly + idempotently on top of `portal-standalone.sql` locally. **No apply without separate owner authorization on isolated staging first.**

---

## 3. Binding owner decisions → accepted-risk register

| ID | Decision | Compensating control | Status |
|---|---|---|---|
| OWN-BUDGET | `budget_enforce=0` at launch | feature available; budget views must be labeled "غير مفعّلة/معلوماتية فقط"; no blocking when budget absent | accepted-risk |
| OWN-EMAIL | Email stays legacy immediate; `txn_notifications=0`; no E1–E6 cutover now | verify current email in staging/canary (Stage 11); E0 documented | accepted-risk |
| OWN-IBAN-MANUAL | Manual IBAN allowed | mandatory reason + prominent badge + actor/time/source audit + restricted visibility | accepted-risk |
| OWN-ADMIN | Admin superuser exception | explicit override labeling + immutable audit | accepted-risk |
| OWN-MOD97 | IBAN MOD-97 out of scope | Saudi `SA\d{22}` shape validation retained | accepted-risk |
| OWN-DRAFT | PR stays Draft; no merge/ready/auto-merge/apply without separate final authorization | — | binding |
| OWN-SYS12 | Preserve Systems 1/2 (no shared email/key/storage break) | dedicated `PORTAL_*` bindings when email work proceeds | binding |

---

## 4. Requirement / finding ledger

Severity: P0 (release-blocking) · P1 (high) · P2 (medium) · P3 (low). Source: O=owner, C=Codex, K=Claude/static.

### Implemented + locally test-verified (this branch)
| ID | Sev | Subsystem | Item | Commit | Evidence | Status |
|---|---|---|---|---|---|---|
| SEC-01 | P1 | RLS | revoke anon SELECT on users/payments/suppliers/beneficiaries | 059 | `35_anon_hardening.sql` (AH0–AH2) + live verify | verified |
| DOC-DB | P0 | documents | 062 normalized immutable versioned model + draft→submit | ca5c7ba | `37` DD1–DD19 | implemented |
| DOC-API | P1 | documents | reqdoc endpoint (internal preview, ownership pre-check) | 8cd7890/b43ae88 | node --check; DD8/DD12 | implemented |
| DOC-UI | P1 | UI | draft→upload→submit + Document Center + manual-IBAN + dept lock | b3d949f | script parse; visual pending | implemented |
| CFG-ENV | P1 | deploy | env-aware config fail-closed + env-guard | 8cd7890 | guard self-test; canonical URL parse | implemented |
| CDX3-ATTACH-PAY | P1 | documents | attach payment-doc authz + payment/request match | 8cd7890 | DD11 | implemented |
| CDX3-KEY-NS | P1 | documents | storage_key namespace binding | 8cd7890 | DD12 | implemented |
| CDX3-REPLACE | P1 | documents | replace returned-only + atomic claim | 8cd7890 | DD10/DD10b/DD13 | implemented |
| CDX3-BUDGET-DRAFT | P1 | budget | exclude drafts from committed | 8cd7890 | `28`/DD19 | implemented |
| CDX3-RECURRING-GATE | P1 | recurring | generated occurrences stay doc-required drafts | 8cd7890 | recurring path | implemented |
| CDX4-SUBMIT-AUTHZ | P1 | authz | submit requires requester/admin (not can_edit) | b43ae88 | DD15 | implemented |
| CDX4-PHASE-CYCLE | P1 | workflow | submit/resubmit set phase=disbursement + cycle by req_type | b43ae88 | DD16 | implemented |
| CDX4-TOKENS | P1 | email/token | invalidate email tokens on submit/resubmit | b43ae88 | DD17 | implemented |
| CDX4-BENEF-REVAL | P1 | payments | beneficiary revalidated at submission | b43ae88 | `submit_expense` | implemented |
| CDX4-FY | P2 | budget | fiscal year from created_at | b43ae88 | — | implemented |
| CDX4-PAY-EVID | P1 | documents | remove/replace reject payment-linked rows | b43ae88 | code | implemented |
| CDX4-PAY-ROLE | P1/P2 | payments | payment-doc attach requires can_disburse (not can_see_finance) | b43ae88 | code | implemented |
| CDX4-CONCURRENCY | P2 | documents | remove_document FOR UPDATE + DELETE RETURNING | b43ae88 | code | implemented |
| CDX4-NOTIFY-DUP | P1 | email | UI sends only cycle-aware disbursement notification | b43ae88 | code | implemented |
| CDX4-DOCS0 | P2 | UI | submit honors expense_docs_required=0 rollback | b43ae88 | code | implemented |
| R1-CANONICAL | P1 | workflow | resubmit delegates direct-expense to submit_expense (one path) | 3861171 | DD18/DD19 | implemented |
| E0 | P1 | email | email architecture inventory + isolation proof | d103215 | `EMAIL_ARCHITECTURE_AND_CUTOVER.md` | implemented |

### Open (owner/Codex) — must be dispositioned before release
| ID | Sev | Subsystem | Item | Target stage | Status |
|---|---|---|---|---|---|
| DOC-RECEIPT | **P0** | documents | fabricated in-namespace key: server-issued single-use upload receipt (verify R2 object/metadata, consume once, verified_at, orphan cleanup) — **release-blocking** | Stage 3 | open |
| E2E | P0 | verification | browser E2E on isolated staging with 062 applied (owner-authorized) | Stage 1/13 | open |
| SEC-06 | **P0** | System 1 | `register.html` anon Storage fallback → signed registration-bound upload + revoke anon writes | Stage 2 | open |
| SEC-IBAN-EXPOSE | P1 | privacy | full beneficiary IBAN exposed to ordinary can_create — restricted view/RPC + masking | Stage 2 | open |
| PAY-ROLES | P1 | payments | dedicated capabilities (`can_prepare_payment`/`can_attach_payment_documents`/`can_attach_disbursement_proof`) + type+state+role | Stage 4/8 | open |
| RET-EXPENSE-EDIT | P1 | correction | editable core fields on returned direct expense (scoped) | Stage 8/9 | open |
| ROUTE-AWARD-RETURN | P1 | workflow | award review lacks true return-for-correction (distinct from reject) | Stage 7/9 | open |
| ROUTE-PO-RETURN | P1 | workflow | PO `return` behaves like `reject`; minor correction must not destroy award | Stage 7/9 | open |
| ROUTE-PAY-ENUM | P1 | workflow | `p_return_to` not validated against closed enum (non-`award` → procurement silently) | Stage 9 | open |
| ROUTE-EMAIL-PARITY | P1 | workflow/email | email return parity / safe portal handoff | Stage 9/11 | open |
| RECUR-BLOCKED | P1 | recurring | over-budget/no-doc recurring → durable blocked work item (not `request_id=NULL` audit) | Stage 8/9 | open |
| HISTORY-PRESERVE | P1 | workflow | resubmit clears approver/comment/timestamps — target: new revision/cycle, retain prior | Stage 5/9 | open |
| FISCAL-POLICY | P2 | budget | document + freeze `budget_period` at submit (not inferred from created_at forever) | Stage 8 (doc) | open |
| SUPPLIER-ENV | P1 | deploy | `supplier-quote.html` still embeds prod project — route via `/api/portal-config` | Stage 1 | open |
| PAGES-DEPLOY | P1 | deploy | GitHub Pages publishes System-3 portal that needs `/api/portal-config` (404 there) — exclude or disable | Stage 1 | open |
| BOOT-STATES | P2 | UI | accessible bootstrap states (aria-busy/timeout/retry/offline/fatal focus) | Stage 10 | open |
| PAY-DOCS-COMPLETE | P1 | payments | configurable payment-document completeness (H) enforcing migration | Stage 8 | open |
| SCHED-DECOUPLE | P1 | ops | outbox-drain returns before SLA/recurring on missing Resend key (E2) | Stage 11/12 (deferred by OWN-EMAIL) | deferred-with-approval |
| CRON-SECRET | P2 | ops | cron secret via query string + non-constant-time compare | Stage 12 | open |

### Program stages (documents/implementation not yet started)
| ID | Stage | Scope | Status |
|---|---|---|---|
| S0 | 0 | this ledger + 5 routing docs + inventory reconciliation | **in progress (this commit)** |
| S1 | 1 | isolated staging + deployment safety (guards, manifest, Pages fix) | open |
| S2 | 2 | security/RLS/privacy/service-boundary review + SEC-06 | open |
| S3 | 3 | trusted document lifecycle (upload receipt, doc capabilities) | open |
| S4 | 4 | governed users/jobs/roles/departments/sectors model | open |
| S5 | 5 | versioned workflow/approval-design engine | open |
| S6 | 6 | committee engine | open |
| S7 | 7 | procurement lifecycle (RFQ/comparison/award/PO) | open |
| S8 | 8 | disbursement/payment/financial integrity | open |
| S9 | 9 | Correction & Work Routing Engine (R0–R8) | R0 docs in progress |
| S10 | 10 | UI/UX modernization (U0–U7) | open |
| S11 | 11 | current-email validation only (legacy) | open |
| S12 | 12 | reliability/perf/observability/ops | open |
| S13 | 13 | full staging acceptance + regression | open |
| S14 | 14 | independent adversarial review on final SHA | open |
| S15 | 15 | merge + release rehearsal (owner sign-off) | open |

---

## 5. Unresolved review threads (deduplicated to canonical items)

Codex posted repeated findings across `3b1bfc4`/`135f5af`/`79f4e2c`/`5975f2f`. Canonicalized:
- **Draft/submit mismatch** (×6) → CDX (fixed b3d949f/8cd7890).
- **Manual-IBAN reason not collected** (×3) → fixed b3d949f.
- **Department picker** (×2) → fixed b3d949f.
- **Payment-doc authz / can_see_finance** (×2) → CDX4-PAY-ROLE (fixed) + PAY-ROLES (open, dedicated caps).
- **Fabricated key** (×3) → **DOC-RECEIPT (open P0)**.
- **replace/remove/resubmit bypass** (×4) → CDX3-REPLACE/CDX4-PAY-EVID/R1-CANONICAL (fixed).
- **recurring bypass** (×2) → CDX3-RECURRING-GATE (fixed) + RECUR-BLOCKED (open, work item).
- **config/guard** (×4) → CFG-ENV (fixed) + SUPPLIER-ENV/PAGES-DEPLOY (open).
Owner senior reviews → captured as OWN-* + the open rows in §4.

---

## 6. Release-gate checklist (Gate 0 → Gate 15)

- [ ] G0 every prior comment/finding represented here (this commit)
- [ ] G1 Preview cannot reach production under malformed inputs; Pages cannot expose System-3; isolated staging exists
- [ ] G2 no unresolved Critical/High authz/privacy/storage; dynamic negative-authz tests pass; SEC-06 closed
- [ ] G3 zero fake evidence satisfies submission; inline evidence viewable by every approver in staging
- [ ] G4 each role positive+negative caps dynamically tested
- [ ] G5 DoA boundary tests at 25k/150k/250k/500k ±1; deterministic or fail-closed
- [ ] G6 committee quorum/recusal/alternate/concurrency tests pass
- [ ] G7 full purchase path scenarios pass
- [ ] G8 financial invariants + concurrency pass; disabled controls honest
- [ ] G9 routing phase matrix + browser journeys incl. forged destinations + concurrent queue
- [ ] G10 screenshots + visual regression + keyboard/mobile E2E per role
- [ ] G11 current email proven with test recipients; best-effort limits documented
- [ ] G12 SLOs, restore evidence, no unbounded query, runbooks
- [ ] G13 zero Blocker/Critical/High; no unexplained skipped test
- [ ] G14 independent verdict (not CI-only)
- [ ] G15 merge rehearsal + owner sign-off

**Gate 0 status:** items consolidated above; pending owner acceptance of Stage 0.

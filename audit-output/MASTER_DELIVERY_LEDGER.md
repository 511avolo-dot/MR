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
| Migrations | "059 only" | **G0-01 CLOSED (live-verified `list_migrations` 2026-07-29):** 059/060/061 **applied live**; **062 absent (not applied)**; next free = 063 |
| Assertions | "194" | **222** (197 SQL + 18 file-guard + 7 endpoint) |
| PR body | stale | **Updated** (live-verified migration state) |

> **G0-01 CLOSED:** the earlier "060–062 not applied" line is DISPROVED — live `list_migrations` on `mwbjoysuybgbrvfrprex` (2026-07-29, Supabase MCP re-authorized) shows **059, 060, 061 applied; 062 absent**. Verbatim list + labels: `MIGRATION_HISTORY_RECONCILIATION.md`. **No production change was made to reconcile documentation** (read-only `list_migrations`).

**Inventory of record:** `audit-output/SYSTEM_INVENTORY.md` (updated counts below). System-3 objects in `portal-standalone.sql` at this head: **35 tables · 171 functions · 27 triggers · 30 policies**; **29 test files** (222 assertions); migrations through **062**; **next free migration number = 063**.

---

## 2. Migration dependency map (059 → next)

| Migration | Purpose | Live-applied? (evidence) |
|---|---|---|
| 059 | SEC-01 revoke anon sensitive reads | **YES — applied live (VERIFIED, live `list_migrations` `20260728093548`)** |
| 060 | AUTHZ-01 expense dept binding + recurring budget | **YES — applied live (VERIFIED, `20260728170320`; commit `135f5af` proof)** |
| 061 | Codex round-2 hardening | **YES — applied live (VERIFIED, `20260729073619`)** |
| 062 | Supporting documents (round-3/4 + R1 folded in-place) | **NO — NOT applied (VERIFIED absent from live list)** |
| **063 (next free)** | reserved — Stage 9 work-items / routing policies (not yet created) | — |

Ordering rule: 059→060→061→062 then 063+. 062 verified to apply cleanly + idempotently on top of `portal-standalone.sql` locally. **No further apply (062/063) without separate owner authorization on isolated staging first.** **G0-01 CLOSED — live `list_migrations` (2026-07-29) confirms 059/060/061 applied, 062 absent** (`MIGRATION_HISTORY_RECONCILIATION.md`).

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

### Implemented (this branch) — evidence type per row (G0-09)

**Evidence legend:** `SRC`=static source verification · `SQL`=SQL assertion test · `EP`=endpoint/Node test · `E2E`=browser (none yet) · `CONC`=concurrency (none yet) · `LIVE`=live configuration verification. **No row is `verified` unless its evidence type actually ran; `implemented` = code merged, dynamic verification pending.** No browser/concurrency/live evidence exists yet on this branch.

| ID | Sev | Subsystem | Item | Commit | Evidence type | Status |
|---|---|---|---|---|---|---|
| SEC-01 | P1 | RLS | revoke anon SELECT on users/payments/suppliers/beneficiaries | 059 | SQL (`35_anon_hardening.sql` AH0–AH2) · LIVE claimed prior session (re-verify) | implemented (SQL-verified; LIVE re-verify pending) |
| DOC-DB | P0 | documents | 062 normalized immutable versioned model + draft→submit | ca5c7ba | SQL (`37` DD1–DD19) | implemented |
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
| SCHED-DECOUPLE | P1 | ops | **(G0-07)** `portal-outbox-drain.js:109` returns on missing/invalid Resend key **before** SLA (`:116`) + recurring (`:119`) → **SLA escalation + recurring generation stop.** This is separable from the email freeze: decoupling `portal-scheduler` (SLA+recurring) from `portal-email-drain` changes **no email delivery behavior**. Owner froze email; owner did **not** accept loss of SLA/recurring execution | Stage 12 (scheduler split, email-neutral) — else record launch impact + request explicit owner risk acceptance | **open (not deferred)** |
| DOA-THRESHOLD-CONFLICT | P1 | workflow/config | **(G0-05)** small-committee upper bound: **owner business matrix = 25,000–125,000**; **code/seed `portal_doa` = 25,001–150,000** (`portal-standalone.sql:1832`); test values follow code. Do NOT implement/certify thresholds until owner confirms authoritative matrix; threshold tests must use confirmed values exactly ±1 | Stage 5 (blocked on owner confirmation) | open |
| CRON-SECRET | P2 | ops | cron secret via `?key=` query string + non-constant-time compare | Stage 12 | open |

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

---

## 7. Requirements register — one row per requirement/mandate (G0-02)

Every prior owner requirement / Codex finding / design mandate has its own stable ID. Source: O=owner, C=Codex, K=Claude. Ev = evidence type when done (SRC/SQL/EP/E2E/CONC/LIVE). Status: open / implemented / verified / accepted-risk / deferred-with-approval.

### Stage 4 — users / jobs / roles / departments / sectors
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S4-JOBVER | O | P2 | job catalog with versioned permission bundles | 4 | open |
| S4-GRAN | O | P2 | granular capabilities (not overloaded permission keys) | 4 | open |
| S4-ASSIGN | O | P2 | user assignment with effective date/expiry | 4 | open |
| S4-SCOPE | O | P2 | sector/department + optional project/cost-center scope | 4 | open |
| S4-HIER | O | P2 | manager hierarchy + eligible substitutes | 4 | open |
| S4-AUTHTYPE | O | P1 | explicit collaboration vs ownership vs approval authority | 4 | open |
| S4-SOD-CAT | O | P1 | role conflict/SoD rule catalog | 4 | open |
| S4-SIM | O | P2 | permission impact preview + simulation | 4 | open |
| S4-EXPLAIN | O | P3 | "why does this user have access?" | 4 | open |
| S4-NOINACTIVE | O | P2 | no inactive dept/job/user in new assignments | 4 | open |
| S4-REVIEW | O | P3 | periodic access review/export | 4 | open |
| S4-ADAPTER | O | P1 | safe compatibility adapter from `portal_users.permissions` | 4 | open |
| S4-MATRIX | O | P1 | exact positive+negative capability matrix per role (12 roles) | 4 | open (partial in PERMISSION_MATRIX) |

### Stage 5 — versioned workflow / approval-design engine
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S5-VER | O | P1 | draft/published/retired workflow versions + effective dates | 5 | open |
| S5-SNAPSHOT | O | P1 | immutable workflow-version snapshot bound to each request | 5 | open |
| S5-MATCH | O | P1 | server-side matching by type/sector/dept/project/value/exception | 5 | open |
| S5-PARALLEL | O | P2 | sequential + parallel stages; all/any/quorum voting | 5 | open |
| S5-RESOLVER | O | P2 | named user / job role / dept manager / committee / queue / dynamic resolver | 5 | open |
| S5-FALLBACK | O | P2 | fallback + escalation rules; per-stage SLA | 5 | open |
| S5-VALIDATE | O | P1 | validation: empty approvers, unreachable, loops, dup, requester-as-approver, missing high-value coverage | 5 | open |
| S5-SIMPUB | O | P1 | simulation before publish (named resulting approvers) + impact preview + rollback | 5 | open |
| S5-NO-CLEAR | O | P1 | do not delete/rewrite prior approvals on resubmission — new revision/cycle (=HISTORY-PRESERVE) | 5 | open |
| S5-BOUNDARY | O | P1 | boundary tests at 25k/150k(→125k?)/250k/500k ±1 (blocked by DOA-THRESHOLD-CONFLICT) | 5 | open |

### Stage 6 — committee engine
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S6-ENTITY | O | P1 | committee first-class versioned entity (type/purpose/rules) | 6 | open |
| S6-ROLES | O | P1 | chair/secretary/members/alternates + effective dates | 6 | open |
| S6-QUORUM | O | P1 | quorum + majority/unanimous/custom threshold | 6 | open |
| S6-RECUSAL | O | P1 | conflict-of-interest declaration + recusal | 6 | open |
| S6-SNAPSHOT | O | P1 | immutable membership snapshot per decision | 6 | open |
| S6-SEATS | O | P1 | one person with multiple perms ≠ multiple committee seats | 6 | open |
| S6-WORKSPACE | O | P2 | dedicated committee workspace + decision record | 6 | open |
| S6-TIMEOUT | O | P2 | timeout/escalation + incomplete-quorum handling | 6 | open |

### Stage 7 — procurement lifecycle
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S7-STARTPRICING | O | P1 | explicit "authorization to start pricing/RFQ" decision | 7 | open |
| S7-RFQ | O | P1 | secure expiring supplier links + save/continue + confirmation ref + duplicate-submit protection | 7 | open (partial: `supplier-quote.html`) |
| S7-COMPARE | O | P1 | interactive item-level comparison (price/tech/VAT/lead/warranty/lowest/variance) | 7 | open |
| S7-NONLOWEST | O/C | P1 | mandatory reason when not choosing lowest (038 flags; UI reason field pending) | 7 | open |
| S7-SPLIT | O | P2 | split-award support + reconciliation (024–026 backend exists) | 7 | implemented (backend, SQL) |
| S7-HISTPRICE | O | P3 | historical price comparison | 7 | open |
| S7-AWARD-RET | O/C | P1 | award: approve/reject/**return-for-correction**/clarification/material reopen (=ROUTE-AWARD-RETURN) | 7 | open |
| S7-PO-RET | O/C | P1 | PO minor-correction vs reject/material-reopen; versioned PO/amendments (=ROUTE-PO-RETURN) | 7 | open |
| S7-PO-QR | O | P3 | PO print/version/QR/authenticated link | 7 | open |

### Stage 8 — disbursement / payment / financial integrity
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S8-EXPENSE-EDIT | O/C | P1 | editable core fields on returned direct expense (scoped) (=RET-EXPENSE-EDIT) | 8 | open |
| S8-PAY-ROLES | O/C | P1 | payment-preparer vs bank-executor capabilities (=PAY-ROLES) | 8 | open |
| S8-PAY-EVID | O | P1 | mandatory evidence per configurable request type/state (=PAY-DOCS-COMPLETE) | 8 | open |
| S8-BENEF | O/C | P1 | beneficiary status/IBAN refresh at submission/payment | 8 | implemented (submission; SQL DD-none yet for payment) |
| S8-MANUAL-IBAN | O | accepted | manual IBAN warning/reason/audit/restricted visibility | 8 | implemented (SRC) |
| S8-CAPS | O | P1 | cumulative caps / split caps / installment precision / idempotent + concurrent-safe execution | 8 | implemented (SQL 025–027/051; CONC pending) |
| S8-VOID | O | P1 | payment request/approval/execution/void/reversal states | 8 | implemented (SQL 051) |
| S8-3WAY | O | P2 | three-way match + contract controls OFF/advisory unless owner activates; honest labels | 8 | implemented (backend 033/037); labels pending |
| S8-RECUR-BLOCK | O/C | P1 | recurring → durable blocked work item, not silent skip (=RECUR-BLOCKED) | 8/9 | open |
| S8-BUDGET-OFF | O | accepted | `budget_enforce=0`; no blocking; budget views labeled "غير مفعّلة/معلوماتية فقط"; retain activation tests | 8 | open (UI labeling) |
| S8-FISCAL | O | P2 | document + freeze fiscal period at submit (=FISCAL-POLICY) | 8 | open |

### Stage 10 — UI/UX (U0–U7)
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S10-SHELL | O | P1 | role-aware App Shell + nav | 10 | open |
| S10-MYWORK | O | P1 | My Work / task inbox | 10 | open |
| S10-DASH | O | P1 | role-specific dashboards | 10 | open |
| S10-SEARCH | O | P2 | permission-aware global search + saved views | 10 | open |
| S10-TXN | O | P1 | transaction workspace: sticky header + URL-addressable tabs | 10 | open |
| S10-MODE | O | P1 | Work Mode vs Official Dossier/Print Mode | 10 | open |
| S10-ACTIONBAR | O | P1 | approval workspace + sticky action bar + compact timeline | 10 | open |
| S10-DOCCTR | O | P1 | Document Center (reusable) | 10 | implemented (expense only, SRC) |
| S10-DIFF | O | P1 | returned-request correction mode + "what changed" diff | 10 | open |
| S10-DOSSIER | O | P1 | unified procurement→payment dossier | 10 | open |
| S10-QUEUE | O | P2 | exception/risk center + recurring-obligation queue | 10 | open |
| S10-DESIGNERS | O | P1 | workflow/committee/permission designers (validation/simulation/impact/rollback) | 10 | open |
| S10-STATES | O | P1 | loading/empty/offline/timeout/expired/denied/stale/partial/duplicate-click/fatal states | 10 | open (BOOT-STATES) |
| S10-MOBILE | O | P1 | tables→cards, mobile approval/viewer, sticky bar | 10 | open |
| S10-A11Y | O | P1 | WCAG 2.2 AA; keyboard; RTL/LTR isolation; reduced motion; focus/live regions; contrast/targets | 10 | open |
| S10-MODULAR | O | P2 | incremental modularization + design-system tokens + API client/state/error/formatters | 10 | open |

### Stage 11 — current email validation (legacy only)
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S11-CANARY | O | P1 | canary all events (submitted/stage/returned/rejected/award/committee/PO/payment states/receipt/invite/login/one-click token success+expiry+replay+stale-revision) | 11 | open |
| S11-NODUP | O | P1 | no duplicate email from a single UI action | 11 | implemented (CDX4-NOTIFY-DUP, SRC) |
| S11-NOROLLBACK | O | P1 | email failure does not roll back business transaction | 11 | implemented (SRC) |
| S11-VISIBLE | O | P2 | failed-notification indication/logging where practical | 11 | open |

### Stage 12 — reliability / perf / observability / ops
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S12-PAGE | O | P1 | server-side pagination/filtering (no fixed broad dataset into one page) | 12 | open |
| S12-PERF | O | P2 | performance budgets + load tests | 12 | open |
| S12-CONC | O | P1 | concurrency tests (approvals/queue/supplier/payment/audit/uploads) | 12 | open |
| S12-LOGS | O | P2 | structured logs + correlation IDs + redaction | 12 | open |
| S12-HEALTH | O | P2 | health/readiness validating bindings without secrets | 12 | partial (portal-config readiness) |
| S12-DR | O | P1 | backup/PITR status + restore rehearsal + RTO/RPO + runbooks | 12 | open |
| S12-EXPORT | O | P2 | audit export/package for a transaction | 12 | open |
| S12-SCHED | O | P1 | scheduler/business-job decoupling (=SCHED-DECOUPLE) | 12 | open |

### Stage 13/14/15 — acceptance / independent review / release
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S13-SEED | O | P1 | realistic staging seed (roles/sectors/committees/values/cases/docs/installments/returns/voids/disputes/recurring) | 13 | open |
| S13-REGRESS | O | P1 | full suite + clean-install + upgrade-from-baseline + rollback rehearsal + browser/mobile/keyboard E2E + visual regression + forged-auth + concurrency + perf + email canary + Systems 1/2 smoke | 13 | open |
| S14-INDEP | O | P1 | independent adversarial review on final SHA + fresh Codex pinned once | 14 | open |
| S15-MERGE | O | P1 | merge rehearsal + release manifest + backup checkpoint + owner sign-off | 15 | open |

---

## 8. Review-thread traceability (G0-08)

Every top-level/inline review thread mapped to a canonical ID. (Codex inline threads are grouped by their canonical finding; owner reviews are dated.) Full inline-comment IDs are retrievable via `pull_request_read get_review_comments`; this table maps content→disposition.

| Thread (commit reviewed) | Canonical ID | Duplicate-of | State | Fixing commit / disposition |
|---|---|---|---|---|
| Codex `3b1bfc4` (baseline) | (pre-supporting-docs findings) | — | addressed earlier in PR | 02d4b2a…135f5af |
| Codex `135f5af` | round-2 set | — | resolved | e6864fd (061) |
| Owner `79f4e2c` review request | (directs Codex) | — | n/a | — |
| Codex `79f4e2c` (stage-2) round-3 (×~20 inline) | CDX3-* (attach/key/replace/remove/resubmit/recurring/budget/config/URL/anon-key/readiness/pages/size) | collapsed | mostly resolved | 8cd7890/b3d949f; **DOC-RECEIPT open**, SUPPLIER-ENV/PAGES-DEPLOY open |
| Codex `5975f2f` round-4 (×15 inline) | CDX4-* (submit-authz/phase/tokens/benef/fy/pay-evid/pay-role/concurrency/notify-dup/docs0) + DOC-RECEIPT | collapsed | resolved except DOC-RECEIPT | b43ae88 |
| Owner senior review `b43ae88` | R1-CANONICAL + PAY-ROLES + DOC-RECEIPT(P0) + FISCAL-POLICY + RECUR-BLOCKED + HISTORY-PRESERVE + PR-body accuracy | — | R1 fixed; rest open | 3861171; PR body updated |
| Owner "@codex review" workflow-routing (`8cd7890`) | ROUTE-* (award/PO/pay-enum/email-parity) | — | documented (R0) | Stage 7/9 |
| Owner UX mandate v1/v2 | S10-* | — | documented (R0/ledger) | Stage 10 |
| Owner email mandate E0–E6 | E0 (done) + E1–E6 | — | E0 implemented; rest deferred (OWN-EMAIL) | d103215 |
| Owner MASTER PROGRAM | S0–S15 | — | S0 in progress | 0316c68 + this commit |
| Owner Stage-0 review | G0-01…G0-09 | — | this commit | (SHA below) |

**No thread dropped:** any Codex inline not individually rowed above is subsumed by its CDX3-*/CDX4-* canonical ID; the `verified`-vs-`implemented` labeling (G0-09) applies.

---

## 9. G0-06 — email-freeze compatibility clarification

`RETURN_ROUTING_TARGET_MODEL.md` invariant "outbox-notified in the same transaction" is clarified (also patched in that file):
- **Durable internal notification** (`portal_notifications` row via the 058 trigger / work-item events → `portal_outbox`) **may be transactional** — this is DB state, not email.
- **No email delivery behavior changes:** `txn_notifications=0`, legacy `portal-notify` immediate path stays authoritative, **no outbox-authoritative email**, no Resend/Cloudflare binding change — until separate authorization (E1–E6).
- **Stage-9 must not create duplicate emails:** correction/reassignment/delegation events notify users via the **existing legacy `pa_notify`/`portal-notify`** path while email remains legacy; the durable outbox intent stays unsent (`shadow`-equivalent) until cutover.

---

## 10. G0-01…G0-09 closure table

| Gate item | Action taken (this commit) | Status |
|---|---|---|
| G0-01 migration history | `MIGRATION_HISTORY_RECONCILIATION.md` + corrected §1/§2; **live `list_migrations` (2026-07-29) confirms 059/060/061 applied, 062 absent** — no production change (read-only) | **CLOSED (live-verified)** |
| G0-02 per-requirement rows | §7 requirements register (S4–S15, one row per mandate) | **done** |
| G0-03 complete artifact inventory | `ARTIFACT_INVENTORY.md` (one row per artifact) | **done** |
| G0-04 phase-matrix contract | `RETURN_ROUTING_PHASE_MATRIX.md` expanded (all columns + committee/GM/payment-prep/approval/execution/partial-receipt/rejected-receipt/return-debit/cancellation/amendment rows) | **done** |
| G0-05 DoA threshold conflict | DOA-THRESHOLD-CONFLICT row (owner 125k vs code 150k); not certified pending owner confirmation | **done (awaiting owner value)** |
| G0-06 email-freeze compat | §9 above + patch in `RETURN_ROUTING_TARGET_MODEL.md` | **done** |
| G0-07 scheduler ≠ email freeze | SCHED-DECOUPLE reclassified **open (not deferred)**, email-neutral split | **done** |
| G0-08 thread traceability | §8 above | **done** |
| G0-09 evidence labels | heading renamed + evidence-type legend + SEC-01 downgraded to implemented | **done** |

**Gate 0 remains NOT PASSED** until: (a) ~~live `list_migrations` confirms G0-01~~ **✅ DONE (059/060/061 applied, 062 absent)**; (b) owner confirms the authoritative DoA matrix (G0-05); and (c) owner independently rechecks this commit. Only (b) and (c) remain.


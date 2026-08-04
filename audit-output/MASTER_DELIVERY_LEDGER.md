# MASTER DELIVERY LEDGER — PR #74 (System 3)

**Authoritative controlling ledger** for the owner MASTER EXECUTION PROGRAM (Stages 0–15).
Every requirement/finding has a stable ID and a status. **No item disappears silently**; scope may only grow by adding explicit rows.
**Rule:** `verified` requires the stated test type actually run — never from static inspection or code comments alone.

- **Branch:** `audit/enterprise-certification-2026-07-27` · **PR #74 (Draft, do not merge)** · **Source snapshot used for generation:** `1e44e33` (the head the owner independently rechecked; the G0-F fixes in this commit are applied on top of it — this line names the snapshot, it is not auto-updated each commit)
- **Binding constraints:** no production/DB/storage/config change; `budget_enforce=0`; `txn_notifications=0`; Systems 1/2 unchanged; manual IBAN allowed (reason+badge+audit); admin superuser accepted (labeled+audited).

> **2026-08-04 exact-head reconciliation (docs-only; no code/DB/production change):**
> **code-under-test head = `33fbc33d73edfc0cc1467ce54a9cd84465cb1e97`** (last
> commit that changed code/DB objects; the two P0-1n-block findings on `f8254fb134`
> were remediated and shipped in the complete P0 chain there). **Current exact PR
> head = `2d7ab0c4eef180709d6cdecc9ddc4af4e16a8739`** — this docs-only reconciliation
> commit; it changes no code/DB, so `33fbc33`'s functional evidence still applies.
> Exact-head CI/CD evidence: on `2d7ab0c`, **`portal-tests` run #199 SUCCESS** and
> **`hosted-preview-smoke` run #30 SUCCESS** (re-run over the docs commit, proving
> no regression). Code-under-test evidence at `33fbc33`: **`portal-tests` run
> `30816735558` (#198) SUCCESS** — clean baseline lineage with **273 SQL
> assertions** (+ 18 file-guard + 7 registration-endpoint), Stage-1 61/61, upload
> cleanup 9/9, document authorization 7/7, functional security 18/18; **`hosted-
> preview-smoke` run `30816735482` (#29) SUCCESS** bound to `33fbc33`;
> **Cloudflare Preview `dae0016e` SUCCESS** at `33fbc33` reporting Preview +
> Staging ref `vpfnycxzqziltsnzxbpb` bound. **Staging-applied migrations (only on
> `vpfnycxzqziltsnzxbpb`):** baseline(061) → 062 → the SHA-pinned ordered
> P0-1b…P0-1n chain, latest `20260803125546_p0_1n_direct_expense_raw_read_boundary`
> (rollback-tested before apply). **Trusted-document status:** the §1 reconciliation
> table and §10–14 closure tables below are **historical snapshots** (source snapshot
> `1e44e33`, and the read-only production `list_migrations` fact dated 2026-07-29);
> they are not rewritten and do **not** override this update. **Remaining gaps (all
> still open — Gate 1 HELD):** authenticated multi-role hosted Playwright E2E;
> disposition of the one missing R2 quote object and pre-existing QA-shaped staging
> rows; staging `service_role` key rotation/disablement evidence; leaked-password
> protection (or recorded risk acceptance); signature-by-signature Security Advisor
> `SECURITY DEFINER` disposition (**96 entries: 7 INFO / 89 WARN**); and fresh
> independent review — **Codex returned "code-review usage limit reached" for this
> head, so independent review remains externally blocked.** **NOT READY**; Draft,
> unmerged, `main`/Production untouched, migration `063` absent.

> **2026-08-03 P0-1n controlling update:** the fresh review of exact head
> `f8254fb134` raised two additional current findings after the prior seven.
> P0-1l is implemented and transaction-tested, and Staging migrations
> `20260803121401_p0_1l_final_independent_review_remediation` and
> `20260803123153_p0_1m_clean_install_raw_read_grants` are applied only on
> `vpfnycxzqziltsnzxbpb`; P0-1n migration
> `20260803125546_p0_1n_direct_expense_raw_read_boundary` is also applied only
> there after a rollback transaction passed. The remediation adds actual-binding R2 sentinel attestation,
> requester-safe purchase routing/RLS, unconditional direct-expense evidence,
> pre-P0-1i duplicate-key quarantine, receipt lifecycle cleanup, exact-SHA hosted
> smoke, shared-helper workflow coverage, and explicit clean-install RLS read
> grants. P0-1n restores the finance-only raw direct-expense boundary and the
> guarded launcher now carries the complete versioned, SHA-pinned P0 chain.
> Corrected exact-head CI/Preview and another
> independent review are still pending. Security Advisor remains open (96
> entries: 7 INFO / 89 WARN), as do authenticated hosted multi-role E2E,
> credential rotation, leaked-password protection, legacy QA/missing-object
> disposition and explicit owner release authorization. **NOT READY**; Draft,
> unmerged, Production untouched, migration 063 absent.

> **2026-08-03 controlling update:** starting exact head `a7d770a`; verdict
> **NOT READY**. P0-1j (not 063) is implemented and staging-verified on
> `vpfnycxzqziltsnzxbpb`. Exact-head CI and the final Preview deployment passed;
> the explicit cleanup path is configured and five proven R2 orphans were
> removed. Production remains untouched. Open gates: authenticated hosted E2E,
> missing legacy quote evidence/pre-existing QA residue, advisor/password and
> credential evidence, and fresh independent review. The old migration/live-
> state narrative below is historical and does not override this update.

Status vocabulary: `open` · `implemented` (code merged, not yet independently test-verified) · `verified` (test type run) · `accepted-risk` (owner-approved) · `deferred-with-approval`.

---

## 1. Reconciliation (supersedes stale certification language)

| Item | Stale claim (old PR body) | **Current truth (source snapshot `1e44e33`)** |
|---|---|---|
| Verdict | "READY WITH CONDITIONS" | **NOT READY (WIP)** |
| Findings | "0 HIGH" | Multiple owner/Codex P1 open (see §4) |
| Migrations | "059 only" | **G0-01 CLOSED (live-verified `list_migrations` 2026-07-29):** 059/060/061 **applied live**; **062 absent (not applied)**; next free = 063 |
| Assertions | "194" | **222** (197 SQL + 18 file-guard + 7 endpoint) |
| PR body | stale | **Updated** (live-verified migration state) |

> **G0-01 CLOSED:** the earlier "060–062 not applied" line is DISPROVED — live `list_migrations` on `mwbjoysuybgbrvfrprex` (2026-07-29, Supabase MCP re-authorized) shows **059, 060, 061 applied; 062 absent**. Verbatim list + labels: `MIGRATION_HISTORY_RECONCILIATION.md`. **No production change was made to reconcile documentation** (read-only `list_migrations`).

**Inventory of record:** `audit-output/SYSTEM_INVENTORY.md` (updated counts below). System-3 objects in `portal-standalone.sql` at this head: **35 tables · 120 functions (distinct; 171 = raw CREATE-OR-REPLACE occurrences across merged migrations) · 27 triggers · 12 policies (distinct)**; **29 test files** (222 assertions); migrations through **062**; **next free migration number = 063**.

---

## 2. Migration dependency map (059 → next)

| Migration | Purpose | Live-applied? (evidence) |
|---|---|---|
| 059 | SEC-01 revoke anon sensitive reads | **YES — applied live (VERIFIED, live `list_migrations` `20260728093548`)** |
| 060 | AUTHZ-01 expense dept binding + recurring budget | **YES — applied live (VERIFIED, `20260728170320`; commit `135f5af` proof)** |
| 061 | Codex round-2 hardening | **YES — applied live (VERIFIED, `20260729073619`)** |
| 062 | Supporting documents (round-3/4 + R1 folded in-place) | **NO — NOT applied (VERIFIED absent from live list)** |
| **063 (next free)** | reserved — Stage 9 work-items / routing policies (not yet created) | — |
| **CEM (post-063)** | Contract Execution & Milestone engine — additive tables/views/RPCs; **no number assigned in design**, allocate next contiguous after all earlier authorized work (`CONTRACT_EXECUTION_MILESTONE_ARCHITECTURE.md`); 023/027/037 never edited | — (design only) |

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

**Canonical-ID aliases (G0-F3/G0-F3C — the `REVIEW_THREAD_TRACEABILITY.md` appendix uses these forms; each resolves to one ledger row or accepted-risk item):** `S8-PAY-EVID` = `PAY-DOCS-COMPLETE` · `S8-RECUR-BLOCK` = `RECUR-BLOCKED` · `S8-EXPENSE-EDIT` = `RET-EXPENSE-EDIT` · `S10-STATES` = `BOOT-STATES` · `AUTHZ-EXPENSE-DEPT (060)` (incl. recurring-budget / precision / serialize / inactive-dept / dept-lock) = live authz item **implemented @135f5af** · `BENEF-MASTER (053)` = beneficiary-master feature **implemented (053, live)** — but the *"bank IBAN must derive from an approved beneficiary" exclusivity* finding is **`OWN-IBAN-MANUAL` accepted-risk, NOT fixed** (G0-H1) · `CDX-BENEF-RECUR (061)` = recurring beneficiary refresh **implemented @061 (NOT `SEC-IBAN-EXPOSE`)** · `DOC-RESUBMIT-GATE (062)` = resubmit evidence gate (062, not applied) · `CFG-ENV` (config URL parse / verified-branch / privileged-key reject / boot-bindings / env-guard) = **fixed @8cd7890** · `CDX3-*`/`CDX4-*`/`DOC-UI`/`DOC-API`/`R1-CANONICAL` = implemented rows in this §4 · `DOC-SIZE-LIMIT`/`DOC-ROLLBACK-FLAG` = implemented 062 doc-config items · `SEC-FINANCE-READONLY` = **open Stage-2** (can_see_finance must not grant write) · `TEST-COVERAGE`/`DOC-ACCURACY`/`MIG-ROLLBACK-DOC` = open Stage-2 test/doc items. **Owner accepted-risk (documentation acceptance only):** `OWN-ADMIN` (administrator SoD) · `OWN-IBAN-MANUAL` (manual-IBAN reason rule; reason UI/RPC implemented) · `OWN-MOD97` (MOD-97 out of scope; SA+22 shape retained). **G0-F3C fixes: 059-regression → `TEST-COVERAGE` (not SEC-06); manual-IBAN → `OWN-IBAN-MANUAL` (not SEC-IBAN-EXPOSE); recurring beneficiary refresh → `CDX-BENEF-RECUR` (not SEC-IBAN-EXPOSE); admin SoD → `OWN-ADMIN` (not PAY-ROLES); MOD-97 → `OWN-MOD97` (not test coverage); Supabase URL parse & replacement-fork → `CFG-ENV`/`CDX3-REPLACE` (not AI-PROXY-ABUSE); `CDX3-ATTACH-PAY` (fixed) ≠ `PAY-DOCS-COMPLETE` (open); verified-branch `CFG-ENV` (fixed) ≠ GitHub-Pages boot `PAGES-DEPLOY` (open).** `SEC-IBAN-EXPOSE` now maps to **only** the "Disclose requester access to beneficiary IBANs" finding.

### Implemented (this branch) — evidence type per row (G0-09)

**Evidence legend:** `SRC`=static source verification · `SQL`=SQL assertion test · `EP`=endpoint/Node test · `E2E`=browser Playwright · `CONC`=concurrency (none yet) · `LIVE`=live configuration verification. **No row is `verified` unless its evidence type actually ran; `implemented` = code merged, dynamic verification pending.**
**Browser E2E (truthfulness reconciliation, owner recheck 574f1e5):** two distinct kinds — (1) **repo-side real-Chromium fixture E2E = VERIFIED at `574f1e5`** (`scripts/e2e/browser-fixture.test.mjs`: real System-3 `#pa-*` login contract + HTTP/WebSocket/Service-Worker context boundary with exact per-host outcomes; runs in CI job `browser-e2e-fixture`); (2) **external isolated-staging browser E2E against a real staging project = NOT RUN / owner-gated** (Section 2). Concurrency (`CONC`) evidence: still none yet on this branch.

| ID | Sev | Subsystem | Item | Commit | Evidence type | Status |
|---|---|---|---|---|---|---|
| SEC-01 | P1 | RLS | revoke anon SELECT on users/payments/suppliers/beneficiaries | 059 | SQL (`35_anon_hardening.sql` AH0–AH2) · **LIVE verified by Claude session** (059 present in live `list_migrations`) | implemented (SQL + LIVE-by-Claude) |
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
| E2E | P0 | verification | **external** browser E2E on isolated staging with 062 applied (owner-authorized) — distinct from the repo-side real-Chromium fixture E2E which is **VERIFIED at `574f1e5`** | Stage 1/13 | open (Section 2, owner-gated) |
| SEC-06 | **P0** | System 1 | `register.html` anon Storage fallback → signed registration-bound upload + revoke anon writes | Stage 2 | open |
| SEC-IBAN-EXPOSE | P1 | privacy | full beneficiary IBAN exposed to ordinary can_create — restricted view/RPC + masking | Stage 2 | open |
| SEC-FINANCE-READONLY | P2 | authz | **(G0-F3C)** `can_see_finance` must remain read-only — verify it grants no write path on finance-scoped tables/RPCs | Stage 2 | open |
| AUDIT-TAIL-ANCHOR | P2 | integrity | **(G0-H5)** 057 hash-chain detects **middle-row mutation** but not **suffix/entire-chain deletion** — needs an external anchor/checkpoint (e.g. periodic signed head export) + test | Stage 2/6 | open |
| SEC-06 (allowlist sub-item) | — | System 1 | **(G0-H2)** reg-doc form↔server allowlist mismatch — **FIXED @e6864fd** (cr/vat/gosi/chamber/natl_addr/iban_cert/municipal/quality/safety/clients/brochure). Parent **SEC-06 stays P0 open** for caller auth + signed registration-bound authz + anon fallback removal + rate/quota + Storage-policy closure | Stage 2 | fixed (sub-item) |
| PAY-ROLES | P1 | payments | dedicated capabilities (`can_prepare_payment`/`can_attach_payment_documents`/`can_attach_disbursement_proof`) + type+state+role | Stage 4/8 | open |
| RET-EXPENSE-EDIT | P1 | correction | editable core fields on returned direct expense (scoped) | Stage 8/9 | open |
| ROUTE-AWARD-RETURN | P1 | workflow | award review lacks true return-for-correction (distinct from reject) | Stage 7/9 | open |
| ROUTE-PO-RETURN | P1 | workflow | PO `return` behaves like `reject`; minor correction must not destroy award | Stage 7/9 | open |
| ROUTE-PAY-ENUM | P1 | workflow | `p_return_to` not validated against closed enum (non-`award` → procurement silently) | Stage 9 | open |
| ROUTE-EMAIL-PARITY | P1 | workflow/email | email return parity / safe portal handoff | Stage 9/11 | open |
| RECUR-BLOCKED | P1 | recurring | over-budget/no-doc recurring → durable blocked work item (not `request_id=NULL` audit) | Stage 8/9 | open |
| HISTORY-PRESERVE | P1 | workflow | resubmit clears approver/comment/timestamps — target: new revision/cycle, retain prior | Stage 5/9 | open |
| FISCAL-POLICY | P2 | budget | document + freeze `budget_period` at submit (not inferred from created_at forever) | Stage 8 (doc) | open |
| S1-GUARD-COUPLE | P1 | deploy | command-coupled environment guard — validated target must be the target the command uses | Stage 1 | ⚠️ **REPO-SIDE PASS; clean external rebuild NOT RUN.** F1 honest lineage: baseline(061) → 062 → SHA-pinned ordered P0-1b…P0-1n through three explicit launcher modes; `verify-baseline.sh` covers the same chain on clean PG16. F2/F3 browser fixture PASS. F4 one runner. CLI pinned `2.110.0`. Live clean rebuild + authenticated hosted E2E remain owner-gated. |
| MIG-IDEMPOTENCY-P01B | INFO | deploy | **(2026-08-04 independent re-run scan)** of the whole P0-1b…P0-1n chain on the clean-install suite DB: **11/12 migrations are idempotent; `p0_1b` alone is not** — line 29 `DROP VIEW IF EXISTS portal_user_directory` raises `"is not a view"` on a second apply, because p0_1b converts that object from a view to the synchronized RLS table it creates | Stage 1 | **tracked / accepted-inert.** Provably never applied twice in any real path (Supabase records migrations = apply-once · CI builds a fresh DB · guarded launcher applies only the *pending* chain once); already applied once to staging and SHA-pinned in the launcher. Deliberately **not** rewritten in place — editing a shipped, applied, SHA-pinned migration would diverge the certified chain (the forbidden "migration repair"). Full-suite still **EXIT 0 / 273 SQL** with the chain applied once. Conforming fix, only if the owner wants it: a guarded forward-safe edit (`DROP TABLE IF EXISTS` + `DROP VIEW IF EXISTS`) + launcher SHA re-pin + re-verify. |
| SUPPLIER-ENV | P1 | deploy | `supplier-quote.html` embedded prod project — route via `/api/portal-config` | Stage 1 | **implemented (Stage 1, repo-only) — runtime `/api/portal-config` fail-closed; pending Gate 1** |
| PAGES-DEPLOY | P1 | deploy | GitHub Pages published Function-dependent pages (404 on `/api/*`) | Stage 1 | **implemented + G1-03/G1-R2-04-hardened (Stage 1, repo-only) — per-page `needs_functions` manifest + set-equality `--check` + query+hash-preserving stub (script at end of body, actual-DOM test); `invite.html`/`register-portal.html` added; pending Gate 1** |
| CFG-ENV-G1-02 | P1 | deploy | env identity self-asserted (`PORTAL_PROD_BRANCH`/`PORTAL_ENV`); no-ref JWT unbound; preview→prod bypass | Stage 1 | **implemented + G1-R2-02/03-hardened (Stage 1, repo-only) — production branch is a code invariant (`main`), branch-absent ⇒ 503, production requires main+PROD_REF, preview requires ≠main+≠PROD_REF; no-ref JWT treated as unbound (needs expected-ref); exp/iss checks; pending Gate 1** |
| CFG-KEY-STRUCTURAL | P2 | deploy | **(G1-R3-04)** anon-key check is structural (no signature/authenticity) | Stage 1 | **relabeled honestly (Stage 1, repo-only) — `portal-config.js`/docs say "structural configuration validation"; opt-in live readiness = `scripts/deploy/probe-anon.mjs` (non-data endpoint, key never logged); runtime fail-closed; pending Gate 1** |
| STAGING-PROVISION | — | ops | **(G1-05)** isolated staging Supabase project + R2 + users/data + Preview bindings + cross-env isolation proof | Stage 1 (owner external) | **partially provisioned — Gate 1 still HELD.** **Verified:** Supabase staging project `vpfnycxzqziltsnzxbpb` provisioned and carrying the applied chain baseline(061)→062→P0-1b…P0-1n (latest `20260803125546_p0_1n…`, rollback-tested); and the Preview branch/runtime → Staging Supabase ref binding, verified by the hosted smoke (`portal-config` reports Preview + Staging ref at `dae0016e`). **Still unverified for full G1-05:** authenticated multi-role browser/RLS journeys against hosted Preview/Staging; R2 binding/sentinel/seed; representative role identities and data; and full cross-environment negative (isolation) proof — all owner-external. Gate 1 cannot fully pass until these are done. |
| PREVIEW-DEPLOY-FACT | — | deploy | **(G1-R2-05)** a public Cloudflare Preview deploys per commit (independent of `main`-only workflows) | Stage 1 | **recorded honestly — Preview `/api/portal-config` verified read-only = 503 fail-closed, never returns production ref; no production/config change** |
| BOOT-STATES | P2 | UI | accessible bootstrap states (aria-busy/timeout/retry/offline/fatal focus) | Stage 10 | open |
| PAY-DOCS-COMPLETE | P1 | payments | configurable payment-document completeness (H) enforcing migration | Stage 8 | open |
| SCHED-DECOUPLE | P1 | ops | **(G0-07)** `portal-outbox-drain.js:109` returns on missing/invalid Resend key **before** SLA (`:116`) + recurring (`:119`) → **SLA escalation + recurring generation stop.** This is separable from the email freeze: decoupling `portal-scheduler` (SLA+recurring) from `portal-email-drain` changes **no email delivery behavior**. Owner froze email; owner did **not** accept loss of SLA/recurring execution | Stage 12 (scheduler split, email-neutral) — else record launch impact + request explicit owner risk acceptance | **open (not deferred)** |
| DOA-THRESHOLD-CONFLICT | P1 | workflow/config | **(G0-05) OWNER CONFIRMED 2026-07-29: authoritative small-committee band = 25,001–125,000.** Code/seed `portal_doa` currently uses **150,000** (`portal-standalone.sql:1832`) → **must be changed 150,000 → 125,000** in Stage 5 (seed edit + migration 063+ region), with boundary tests at **125,000 ±1**. **Not changed now** — implementation is gated (owner chose "hold for recheck") | Stage 5 | **owner-confirmed (125,000); implementation gated** |
| CRON-SECRET | P2 | ops | cron secret via `?key=` query string + non-constant-time compare | Stage 12 | open |
| AI-PROXY-ABUSE | P1 | deploy/security | **(G0-F4)** `functions/api/ai.js` shared Gemini **OCR** proxy for System 1 (`register.html`) + System 2 (`index/requests/rfq.html`) — **not** System 3. Key concealed server-side + model allowlist, **but abuse controls incomplete**: GET has no auth/origin check and calls the provider; POST relies only on forgeable Origin/Referer; no JWT/Turnstile/rate-limit/per-user quota/cost cap; 16 MiB body; size check only fires when `Content-Length` present (chunked bypass). Publicly-deployable quota/cost-abuse surface (no procurement data). **Actions:** add auth/rate/quota + deployment ownership; determine per-deployment need and **disable/exclude where unused**; tests for unauthenticated GET/POST, forged Origin, body limit without Content-Length, rate limiting, allowed deployment ownership | Stage 2/12 | open |

### Program stages (documents/implementation not yet started)
| ID | Stage | Scope | Status |
|---|---|---|---|
| S0 | 0 | ledger + 5 routing docs + inventory + G0/G0-R remediation | **✅ Gate 0 PASSED (owner independent recheck at `9a62890`, 2026-07-30) — documentation gate only; Stage 1 authorized repo-only** |
| S1 | 1 | isolated staging + deployment safety (guards, manifest, Pages fix) | open |
| S2 | 2 | security/RLS/privacy/service-boundary review + SEC-06 | open |
| S3 | 3 | trusted document lifecycle (upload receipt, doc capabilities) | open |
| S4 | 4 | governed users/jobs/roles/departments/sectors model | open |
| S5 | 5 | versioned workflow/approval-design engine | open |
| S6 | 6 | committee engine | open |
| S7 | 7 | procurement lifecycle (RFQ/comparison/award/PO) | open |
| S8 | 8 | disbursement/payment/financial integrity | open |
| S9 | 9 | Correction & Work Routing Engine (R0–R8) | **R0 docs delivered**; R2+ implementation gated |
| S10 | 10 | UI/UX modernization (U0–U7) | open |
| S11 | 11 | current-email validation only (legacy) | open |
| S12 | 12 | reliability/perf/observability/ops | open |
| S13 | 13 | full staging acceptance + regression | open |
| S14 | 14 | independent adversarial review on final SHA | open |
| S15 | 15 | merge + release rehearsal (owner sign-off) | open |
| CEM | 3–13 | Contract Execution & Milestone-Payment engine (owner mandate 2026-07-30) — additive; spans S3 (docs) · S4 (caps) · S5 (workflow) · S7 (contract/schedule) · S8 (acceptance/claims/payment/ledgers) · S9 (routing) · S10 (dossier UI) · S13 (E2E) | **docs delivered (`CONTRACT_EXECUTION_MILESTONE_ARCHITECTURE.md`, CEM-* register); implementation gated** |

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

- [x] **G0 PASSED — owner independent recheck cleared at exact SHA `9a62890189d12d6ae685b3dcf0a1e417714f037f` (2026-07-30, CI run 85 green). Documentation gate only — does NOT certify the product, close any P0/P1 implementation item, or authorize deployment. Stage 1 authorized repo-only; all open ledger items + accepted-risk decisions preserved; no historical evidence rewritten.**
- [ ] G1 Preview cannot reach production under malformed inputs; Pages cannot expose System-3; isolated staging exists
- [ ] G2 no unresolved Critical/High authz/privacy/storage; dynamic negative-authz tests pass; SEC-06 closed
- [ ] G3 zero fake evidence satisfies submission; inline evidence viewable by every approver in staging
- [ ] G4 each role positive+negative caps dynamically tested
- [ ] G5 DoA boundary tests at 25k/**125k (owner-confirmed)**/250k/500k ±1; deterministic or fail-closed
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

**Gate 0 status: ✅ PASSED at SHA `9a62890` (owner independent recheck, 2026-07-30).** Scope of this pass: **Stage-0 documentation gate only.** It does **not** certify the product, close the open P0/P1 implementation items (DOC-RECEIPT, SEC-06, E2E, etc. remain open), or authorize deployment/DB/config change. **Stage 1 is authorized repo-only.** G1 remains unchecked until Stage-1 evidence is independently reviewed (Gate 1). Restrictions still binding: PR Draft/unmerged · no migration 062/063 apply · no production/Storage/Cloudflare/Supabase/Resend change · DoA seed 150→125 is Stage-5 · `txn_notifications=0` · `budget_enforce=0` · Stage 2 does not begin until Gate 1.

---

## 7. Requirements register — one row per requirement/mandate (G0-02)

Every prior owner requirement / Codex finding / design mandate has its own stable ID. Source: O=owner, C=Codex, K=Claude. Ev = evidence type when done (SRC/SQL/EP/E2E/CONC/LIVE). Status: open / implemented / verified / accepted-risk / deferred-with-approval.

### Stage 1 — isolated staging & deployment safety
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S1-STAGING | O | P0 | separate Supabase project + separate R2 bucket/bindings + Preview-only vars + test users + non-prod email recipients | 1 | open (design: `STAGING_SETUP_PLAN.md`) |
| S1-GUARD-COUPLE | O | P1 | environment validation **coupled to the exact migrate/E2E command** (impossible to validate one target, execute another) | 1 | open (`env-guard.mjs` exists but not command-coupled) |
| S1-PAGES-EXCL | O | P1 | GitHub Pages must not publish a broken/misleading System-3 portal that needs `/api/portal-config` — exclude entry points or disable workflow (=PAGES-DEPLOY) | 1 | open |
| S1-SUPPLIER-ENV | O | P1 | `supplier-quote.html` env-aware config (remove embedded prod ref) (=SUPPLIER-ENV) | 1 | open |
| S1-MANIFEST | O | P2 | deployment manifest mapping files/routes → Systems 1/2/3 | 1 | open (partial: `ARTIFACT_INVENTORY*`) |
| S1-NOSECRET | O | P1 | no secrets in static output/logs; validate anon key role/project + server bindings | 1 | implemented (portal-config; SRC) |

### Stage 2 — security / identity / RLS / privacy / service boundaries
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S2-LEASTCOL | O | P1 | least-privilege column exposure (beneficiaries/payments/users/suppliers) | 2 | open |
| S2-IBAN-MASK | O | P1 | do not expose full beneficiary IBAN to ordinary can_create; restricted view/RPC + masking (=SEC-IBAN-EXPOSE) | 2 | open |
| S2-XDEPT | O | P1 | cross-department/cross-role denial tests with real JWT/PostgREST | 2 | open |
| S2-ADMIN-LABEL | O | accepted | admin override explicitly labeled/audited | 2 | open (UI labeling) |
| S2-USERSTATE | O | P1 | active/suspended/deleted user behavior; role revocation immediate for new actions | 2 | open |
| S2-TOKEN | O | P1 | token expiry/one-time/replay/brute-force controls + invalidation on state/revision change | 2 | partial (email-token invalidation done) |
| S2-DEFINER | O | P1 | strict search_path + explicit execute grants; no direct mutable-table write bypassing guards | 2 | partial (040/030 hardening) |
| S2-REDACT | O | P2 | secrets/log redaction | 2 | open |
| S2-AUDIT-VERIFY | O | P1 | audit-chain full-history verification + truncation/gap detection | 2 | implemented (057 `portal_audit_verify`, SQL) |
| SEC-06 | O/C | P0 | System-1 `register.html` anon Storage fallback → signed registration-bound upload + revoke anon writes; recoverable, never insecure fallback | 2 | open |

### Stage 3 — trusted document/evidence lifecycle
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S3-RECEIPT | O/C | P0 | server-issued single-use upload receipt: server key + bind user/request/payment/type/MIME/size/checksum/state/expiry + verify R2 object + consume once + compensate on failure + submit counts only verified docs (=DOC-RECEIPT) | 3 | open |
| S3-DOCCAPS | O | P1 | dedicated doc capabilities (request/payment-prep/disbursement-proof/receipt-quality/procurement-quote) | 3 | open |
| S3-LINK | O | P1 | enforce request/payment linkage, state, ownership, scope, immutable/versioned replacement | 3 | partial (062 request-scope; payment linkage pending) |
| S3-REMOVED | O | P1 | removed docs unreadable; superseded viewable only in authorized version history | 3 | implemented (reqdoc GET row-exists, SRC) |
| S3-SIZE | O | P2 | unified size policy + magic-byte/content validation + rate limit + checksums + no public URLs | 3 | partial (file-guard EP; rate-limit open) |
| S3-ORPHAN | O | P2 | orphan reconciliation + auditable cleanup | 3 | open |
| S3-DOSSIER | O | P1 | full dossier continuity request→payment | 3/10 | open |
| S3-NEGTESTS | O | P0 | negative tests: fabricated key, missing object, reused/expired/mismatched receipt, wrong request/payment/user, post-submit mutation, cross-dept, partial upload, DB-fail-after-upload | 3 | open |

### Stage 9 — Correction & Work Routing Engine (R0–R8)
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| S9-WORKITEMS | O | P1 | `portal_work_items` table (source phase/cycle/stage/seq, work_type, status, destination_type, assignee/role/dept/queue, scope, SLA, lineage) | 9 | open (R0 design) |
| S9-EVENTS | O | P1 | append-only `portal_work_item_events` | 9 | open |
| S9-POLICIES | O | P1 | versioned `portal_routing_policies` (server-enforced permitted destinations) | 9 | open |
| S9-RPCS | O | P1 | governed RPCs (`portal_return_options`/create/accept/reassign/complete/clarify/reopen/cancel) with locks + expected-version + idempotency | 9 | open |
| S9-DEST | O | P1 | user/role/dept/queue destinations only when policy permits; no arbitrary user | 9 | open |
| S9-DELEG | O | P1 | reassignment/delegation/escalation/collaboration distinct; loop/depth/SLA-reset abuse prevention | 9 | open |
| S9-SCOPE | O | P1 | scoped editable fields/documents; material-change impact class resets only affected downstream | 9 | open |
| S9-HISTORY | O/C | P1 | preserve requester/department/approval-history/document versions (=HISTORY-PRESERVE) | 9 | open |
| S9-COMPENSATE | O | P1 | post-payment/receipt via amendment/void/return/debit-note/dispute, not rewind | 9 | partial (void 051, returns 034) |
| S9-AWARD-RET | O/C | P1 | award return-for-correction ≠ reject (=ROUTE-AWARD-RETURN) | 9 | open |
| S9-PO-RET | O/C | P1 | PO minor-correction ≠ reject/material-reopen (=ROUTE-PO-RETURN) | 9 | open |
| S9-PAY-ENUM | O/C | P1 | validate `p_return_to` closed enum (=ROUTE-PAY-ENUM) | 9 | open |
| S9-EMAIL-PARITY | O/C | P1 | email return parity / safe portal handoff, legacy-email-only (=ROUTE-EMAIL-PARITY) | 9 | open |
| S9-TESTS | O | P1 | RR-01…RR-25 + browser journeys incl. forged destinations + concurrent queue acceptance | 9 | open (`RETURN_ROUTING_TEST_MATRIX.md`) |

### CEM — Contract Execution & Milestone-Payment Engine (owner mandate 2026-07-30, cross-stage 3–13)
Additive governed milestone-payment domain. **Design/docs only now; implementation gated per stage.** Full model:
`CONTRACT_EXECUTION_MILESTONE_ARCHITECTURE.md`. Non-breaking: does **not** repurpose `portal_contracts`(037)/
`pay_installments`(027)/`portal_receipts`(023); those + migrations 023/027/037 stay immutable.
| ID | Src | Sev | Requirement | Stage | Status |
|---|---|---|---|---|---|
| CEM-DOCS | O | P1 | architecture doc + ledger/routing/inventory registration | 3–13 | **done (docs)** |
| CEM-P0 | O | P1 | **CEM v2 design freeze** (arch doc §15: 5 mandatory corrections + expanded domain + P0–P9 packages + ≥24 tests + rollout/DoD) — docs-only | 3–13 | **done (docs, design freeze)** |
| CEM-V2-01 | O | P1 | contract cardinality = one per **awarded party/PO slice** (single: award_offer_id=NULL; split: per offer); request dossier aggregates; parent closes when all contracts closed | 7 | open (planned; supersedes v1 one-per-request) |
| CEM-V2-02 | O | P1 | separate earned_value vs advance vs retention_release vs adjustment; Σ earned_value = net value; cash events never inflate value/ceiling | 8 | open (planned) |
| CEM-V2-03 | O | **P0** | append-only `portal_contract_financial_events` ledger (16 event classes) as source of truth; computed status RPC/view; no mutable running-balance authority | 8 | open (planned) |
| CEM-V2-04 | O | P1 | structured `portal_contract_amendments`/`_guarantees`/`portal_supplier_invoices`/`portal_claim_adjustments`; version reduction below certified/paid fails closed absent recovery plan | 7/8 | open (planned) |
| CEM-V2-05 | O | **P0** | acceptance engine must NOT call `portal_record_receipt` closure; goods via internal compat helper (no parent close on non-final); services/works by period/value | 8 | open (planned) |
| CEM-P1..P9 | O | P1 | staged packages: P1 schema-disabled · P2 contract/version/doc/guarantee RPC · P3 schedule engine · P4 acceptance · P5 claims/invoices/adjustments/ledger · P6 claim-payment · P7 amendments/routing · P8 dossier UI · P9 staging acceptance/rollout | 7–13 | open (planned) |
| CEM-EC-TABLES | O | P1 | `portal_execution_contracts` + immutable `portal_execution_contract_versions` (draft→under_review→published→superseded/terminated) + `portal_execution_contract_documents` (versioned, trusted-object links only) | 7 | open (planned) |
| CEM-SCHEDULE | O | P1 | `portal_contract_milestones` + explicit `..._dependencies` (acyclic) + `portal_milestone_evidence_requirements`; publish-time validation (dup/cycle/sum=basis±tol/non-neg/advance+retention defined/≤remaining) | 7 | open (planned) |
| CEM-ACCEPT | O | P1 | `portal_acceptance_records` (typed: site_visit…final_acceptance/defect/return) + `portal_acceptance_lines`; evidence-only vs eligibility-creating per milestone policy | 8 | open (planned) |
| CEM-CLAIM | O | P1 | `portal_milestone_claims` (multi/partial) + certified amount/deductions/retention/advance/VAT/net-payable + append-only claim events | 8 | open (planned) |
| CEM-PAY | O | **P0** | nullable `portal_payments` links/snapshots + `portal_create_payment_from_claim` (locks, server-derived, certified+unpaid, evidence accepted, balances, one active payment/claim); legacy free-form path fails closed when active EC exists | 8 | open (planned) |
| CEM-INVARIANTS | O | **P0** | server-side one-transaction financial invariants (§5): earned-value/cash/claim/milestone ceilings, retention & advance as ledger balances, immutability, exact rounding, no duplicate payment | 8 | open (planned) |
| CEM-CAPS | O | P1 | 13 versioned capabilities (§6) + SoD (submitter≠certifier, preparer≠approver≠executor); admin override labeled+audited | 4 | open (planned) |
| CEM-RPC | O | P1 | RPC-only boundary (§7): every mutating RPC validates state/capability/SoD/expected-revision/evidence/ceilings/idempotency + writes event+audit in same txn | 5/7/8 | open (planned) |
| CEM-DOCLAYER | O | **P0** | all contract/acceptance/claim/payment evidence via Stage-3 trusted document objects (upload receipt) — **hard dependency on `DOC-RECEIPT`/`S3-RECEIPT`** | 3 | open (blocked by S3-RECEIPT) |
| CEM-PARENT | O | P1 | parent-request compatibility: non-final milestone does not close/force final receipt; close only when §4 (1–6) all hold; computed `portal_execution_status` view/RPC | 8/10 | open (planned) |
| CEM-ROUTING | O | P1 | corrections/amendments via Stage-9 engine (CEM-RT-* routes), no ad-hoc return_to; history preserved | 9 | open (planned) |
| CEM-DOSSIER | O | P1 | unified contract dossier + timeline + schedule + payment-monitor UI | 10 | open (planned) |
| CEM-MIGRATE | O | P1 | additive-first; classify legacy rows (single/split/installments/framework) with **no** auto-conversion; disabled-by-default flag; safe rollback (disable-create, preserve history) | 7–8 | open (planned) |
| CEM-TESTS | O | **P0** | 20-case regression+acceptance suite (§12): 5 legacy-unchanged + 15 governance/financial/SoD/dossier/closure + full browser journey | 13 | open (planned) |

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
| S5-BOUNDARY | O | P1 | boundary tests at 25k/**125k (owner-confirmed)**/250k/500k ±1; seed currently 150k → change to 125k in Stage 5 | 5 | open |

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

## 8. Review-thread traceability (G0-08 / G0-R6)

**The complete one-row-per-thread appendix (all 102 inline threads with thread ID, reviewed commit, file:line, severity, finding, GitHub state, canonical disposition) is `REVIEW_THREAD_TRACEABILITY.md`** — generated from `get_review_comments`. Summary: all 102 threads captured; every CDX3/CDX4 finding fixed except the tracked open IDs (DOC-RECEIPT P0, SUPPLIER-ENV, PAGES-DEPLOY, SEC-06). (Threads were deliberately not mass-resolved on GitHub to avoid hiding genuinely-open items.) The theme-level table below remains as the summary map.

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
| Owner MASTER PROGRAM | S0–S15 | — | S0 ✅ Gate 0 PASSED (`9a62890`); Stage 1 open/HELD (Gate 1 in review) | 0316c68…this commit |
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
| G0-03 complete artifact inventory | **`ARTIFACT_INVENTORY_APPENDIX.md`** (one row per artifact — the actual enumeration; `ARTIFACT_INVENTORY.md` is the narrative companion) | **done** |
| G0-04 phase-matrix contract | `RETURN_ROUTING_PHASE_MATRIX.md` expanded (all columns + committee/GM/payment-prep/approval/execution/partial-receipt/rejected-receipt/return-debit/cancellation/amendment rows) | **done** |
| G0-05 DoA threshold conflict | **Owner confirmed authoritative = 125,000 (2026-07-29).** Recorded; seed change 150k→125k + boundary tests deferred to Stage 5 (owner chose hold-for-recheck) | **resolved (value confirmed; impl gated)** |
| G0-06 email-freeze compat | §9 above + patch in `RETURN_ROUTING_TARGET_MODEL.md` | **done** |
| G0-07 scheduler ≠ email freeze | SCHED-DECOUPLE reclassified **open (not deferred)**, email-neutral split | **done** |
| G0-08 thread traceability | §8 above | **done** |
| G0-09 evidence labels | heading renamed + evidence-type legend + SEC-01 downgraded to implemented | **done** |

**Gate 0 ✅ PASSED (2026-07-30, SHA `9a62890`):** (a) ~~live `list_migrations` confirms G0-01~~ **✅ DONE (059/060/061 applied, 062 absent)**; (b) ~~owner confirms the authoritative DoA matrix (G0-05)~~ **✅ DONE (owner confirmed 125,000, 2026-07-29)**; (c) ~~owner independently rechecks the Stage-0 commits~~ **✅ DONE — owner independent recheck cleared G0-R/G0-F/G0-F2A/G0-F3A-C/G0-H1…H5 at `9a62890`, CI run 85 green.** **Stage 1 authorized repo-only** (see §6 restrictions). Documentation gate only — product not certified; P0/P1 items stay open.

---

## 11. G0-R1…G0-R8 closure table (owner independent recheck)

| Item | Action taken | Status |
|---|---|---|
| G0-R1 PR body contradicts DoA decision | PR body updated — DoA no longer "awaiting confirmation"; records owner-confirmed 125,000 | done |
| G0-R2 stale/contradictory ledger | Head → `1b97cc4`; SEC-01 → LIVE-verified-by-Claude; S0/R0 → delivered; G5 & S5-BOUNDARY → 125k; counts corrected (120 functions / 12 policies distinct) | done |
| G0-R3 phase matrix superseded 150k | Head → `1b97cc4`; labeled current-code 150k vs target-authoritative 125k; removed "unresolved" | done |
| G0-R4 artifact inventory not one-row-per | **Generated `ARTIFACT_INVENTORY_APPENDIX.md`** (every page/API/table/function/trigger/policy/job/bucket); `ai.js` classified (shared Gemini proxy) | done |
| G0-R5 per-requirement register incomplete | Added Stage-1/2/3/9 per-requirement sections to §7 (incl. SEC-06 sub-controls, upload-receipt invariants + negative tests, R0–R8 items) | done |
| G0-R6 thread traceability | **Generated `REVIEW_THREAD_TRACEABILITY.md`** — all 102 threads (ID/commit/file:line/sev/finding/state/disposition) | done |
| G0-R7 G0-01 independent-verification label | Reconciliation doc: **LIVE verified by Claude session; independent reviewer NOT re-executed** (needs Supabase read/export) — no two-party claim | done |
| G0-R8 closure mechanics | Gate checklist → 125k; this single closure commit; closure table returned; PR draft; no Stage-1/063; no DB/config/storage change | done |

**Remaining to clear Gate 0:** owner's independent recheck of this commit. G0-01/G0-05 resolved; all G0-R consistency items corrected. Implementation (Stage 1 / migration 063 / DoA seed 150→125) stays gated per owner "hold for recheck."

## 12. G0-F1…G0-F4 closure table (owner recheck of `1e44e33`)

Documentation-accuracy corrections from the owner's independent recheck of `1e44e33`. **The G0 gate/closure checklist is NOT flipped to passed — per owner, it is updated only after this recheck is accepted.**

| ID | Recheck note | Correction (this commit) | State |
|---|---|---|---|
| G0-F1 | Ledger head `1b97cc4`/"updated each commit" vs reviewed head `1e44e33`; G0-03 pointed at narrative not appendix | Head line → **source snapshot `1e44e33`** (not auto-updated); §1 truth header → `1e44e33`; appendix intro snapshot → `1e44e33`; **G0-03 closure now points at `ARTIFACT_INVENTORY_APPENDIX.md`** (the one-row enumeration). Gate/closure table intentionally left un-flipped pending acceptance | corrected — awaiting recheck |
| G0-F2 | Appendix asserted the same "RLS on; SELECT scoped / writes deny-by-default via guards" for **every** table (false for server-only/service-role tables); functions got placeholder "authenticated (or per REVOKE/GRANT)" | **Source-derived** per-table access class (verified from RLS-enable loop `:1680`, auth_all loop `:1696`, each policy/REVOKE/GRANT): server-only no-policy (`portal_email_tokens`/`portal_idempotency`/`portal_supplier_tokens`), service-role-only (`portal_invitations`/`portal_outbox`), own-row (`portal_notifications`), append-only (`portal_audit`), scoped/perm-gated/auth_all for the rest — guard claimed only where source confirms. **Per-function grant class** from `REVOKE … FROM …`: service_role-only (14) / authenticated+service_role / trigger-only / PUBLIC-default. Exhaustive per-signature + Stage-2 least-privilege review kept explicitly open | corrected — awaiting recheck |
| G0-F3 | Thread appendix: commit blank on ~100/102, findings truncated, generic "CDX3/CDX4 fixed" bucket misclassified known-open items | Regenerated: **reviewed commit = `not returned by API`** (the review API does not return it — honest, never blank); **findings preserved** (title + explanation, badge/markup stripped); **one stable canonical ID per thread** with owner-named opens carrying exact IDs (`S1-GUARD-COUPLE`, `BOOT-STATES/S10-STATES`, `PAY-DOCS-COMPLETE/S8-PAY-EVID`, `RECUR-BLOCKED/S8-RECUR-BLOCK`, `RET-EXPENSE-EDIT/S8-EXPENSE-EDIT`, `PAY-ROLES` → **open**); `fixed @<sha>` carries the fixing commit; **0 untriaged**. Alias table added to §4 so every ID resolves | corrected — awaiting recheck |
| G0-F4 | `ai.js` classified too positively ("secure … NOT wired") | Reclassified: **System-1/2 OCR proxy** (`register.html` + `index/requests/rfq.html`), **not** System 3; **"key concealed, abuse controls incomplete"** (GET unauth; POST forgeable Origin/Referer; no JWT/Turnstile/rate-limit/quota/cost cap; 16 MiB; Content-Length-gated size check → chunked bypass). New ledger risk item **`AI-PROXY-ABUSE` (Stage 2/12)** with actions: add auth/rate/quota + deployment ownership, disable/exclude where unused, and the owed tests (unauth GET/POST, forged Origin, body-limit-without-Content-Length, rate limit, deployment ownership) | corrected — awaiting recheck |

**Gate 0 remains HELD.** No Stage 1, no migration 063, no DoA seed change, no production/DB/config/storage change. One focused documents-only commit closes G0-F1…G0-F4; the gate flips only when the owner accepts this recheck.

## 13. G0-F2A / G0-F3A–C closure table (owner recheck of `7abc624`)

Owner accepted **G0-F1** and **G0-F4** (documentation acceptance only for F4). Remaining factual corrections, one documents-only commit; **gate still HELD (not flipped)**.

| ID | Note | Correction | State |
|---|---|---|---|
| G0-F2A | Table rows conflated SQL grants with effective RLS visibility (e.g. `portal_supplier_iban_changes`/`portal_recurring_expenses`/`portal_supplier_invoices`/`portal_returns`/`portal_beneficiaries` mislabeled "SELECT authenticated") | Every one of the 35 table rows now states **three separate facts**: (1) SQL `GRANT`/`REVOKE`; (2) RLS policy target + **exact effective predicate** (admin/finance/procurement(/stock)/can_create/request-scoped/own-row/server-only — verbatim from source); (3) write path + guard/RPC. `GRANT SELECT TO authenticated` is **no longer** equated with unrestricted visibility. Function wording changed to **"PUBLIC/default execute; body authorization NOT independently verified in Gate 0; Stage-2 review required."** | corrected — awaiting recheck |
| G0-F3A | Thread IDs removed | **`Thread ID` column restored** (`PRRT_…`) + **comment URL** per row (resolves to full GitHub text) | corrected — awaiting recheck |
| G0-F3B | Findings truncated but labeled "preserved" | **Full comment body** now included per row (only the badge image + "Useful?" footer stripped); no truncation. Reviewed-commit column dropped (API does not return it) rather than left blank | corrected — awaiting recheck |
| G0-F3C | Several canonical dispositions wrong; "0 untriaged" unreliable | Rebuilt from a **79-title exact map** (no greedy keywords). Fixes: 059-regression → `TEST-COVERAGE` (not SEC-06) · manual-IBAN → `OWN-IBAN-MANUAL` (not SEC-IBAN-EXPOSE) · recurring beneficiary refresh → `CDX-BENEF-RECUR (061)` (not SEC-IBAN-EXPOSE) · admin SoD → `OWN-ADMIN` (not PAY-ROLES) · MOD-97 → `OWN-MOD97` (not test coverage) · Supabase URL parse & replacement-fork → `CFG-ENV`/`CDX3-REPLACE` (not AI-PROXY-ABUSE) · `CDX3-ATTACH-PAY` (fixed) separated from `PAY-DOCS-COMPLETE` (open) · verified-branch `CFG-ENV` (fixed) separated from GitHub-Pages `PAGES-DEPLOY` (open). `SEC-IBAN-EXPOSE` now maps to **only** the "Disclose requester access to beneficiary IBANs" finding | corrected — awaiting recheck |
| G0-F3 (item 6) | validation/generation report | Added to the appendix header: **102 threads · 102 unique thread IDs · 0 blank IDs · 0 unknown canonical IDs · 102 dispositions**, GitHub-state counts, and the owner accepted-risk mapping list | corrected — awaiting recheck |

**Gate 0 remains HELD.** No Stage 1, no migration 063, no DoA seed change, no production/DB/config/storage change. PR body will note G0-F1…F4 as accepted **only after** this correction is independently accepted (owner instruction 7).

## 14. G0-H1…G0-H5 closure table (owner recheck of `e6bfaf8`)

Owner accepted G0-F2A and G0-F3A/B. Five traceability disposition corrections; one documents-only commit; **gate still HELD (not flipped)**.

| ID | Note | Correction | State |
|---|---|---|---|
| G0-H1 | Threads #9/#12 "vetted/approved beneficiary for bank expenses" mapped to `BENEF-MASTER (053) implemented` — conflicts with owner's manual-IBAN decision | Remapped to **`OWN-IBAN-MANUAL` / accepted-risk**: beneficiary master exists (053) **but manual non-master IBAN remains allowed** with required reason+badge+audit; the requested **exclusivity was deliberately NOT implemented** — no longer described as fixed | corrected — awaiting recheck |
| G0-H2 | Thread #18 (allowlist mismatch) shown `SEC-06 open (P0)` as if unfixed | **Allowlist sub-item marked FIXED @e6864fd** (form↔server list reconciled); **parent `SEC-06` P0 kept OPEN** as separate items (caller auth · signed registration-bound authz · anon fallback removal · rate/quota · Storage-policy). Allowlist closure does **not** imply SEC-06 closure | corrected — awaiting recheck |
| G0-H3 | Thread #79 (department picker UI) marked only `implemented @135f5af` (backend) | Disposition now references **backend `135f5af` + UI `b3d949f`**, consistent with thread #89 | corrected — awaiting recheck |
| G0-H4 | Threads #101/#102 had blank Comment URL while header claims a URL per row | **URLs recovered** (`…#discussion_r3674479022` / `…_r3674479034`); validation report extended with **blank/`not returned by API` comment URLs = 0**; thread ID remains the primary stable key | corrected — awaiting recheck |
| G0-H5 | Thread #4 audit-tail disposition began "addressed via 057" (could read as closed) | Restated unambiguously: **middle-row mutation detection implemented (057); suffix/entire-chain deletion detection remains OPEN** until an external anchor/checkpoint is implemented + tested. New ledger item **`AUDIT-TAIL-ANCHOR`** (Stage 2/6, open) | corrected — awaiting recheck |

**Gate 0 remains HELD.** No Stage 1, no migration 063, no DoA seed change, no production/DB/config/storage change.


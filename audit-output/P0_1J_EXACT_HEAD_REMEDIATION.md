# P0-1j exact-head remediation evidence

Date: 2026-08-03  
PR: #74 (Draft; never merge or mark ready in this work)  
Starting reviewed head: `a7d770aefda6cc2a1b04ef1351b3a5de863a03f5`  
Verdict: **NOT READY**

## Safety boundary

- Supabase writes were restricted to staging `vpfnycxzqziltsnzxbpb`.
- Cloudflare review was restricted to the Preview configuration and staging R2
  bucket `aldeyabi-quotes-staging`.
- Production Supabase `mwbjoysuybgbrvfrprex` was not queried or mutated.
- Migration 063 was neither created nor applied.

## Fresh findings and disposition

| Finding | Remediation | Evidence |
|---|---|---|
| Raw IBAN in direct-expense/payment rows | Base RLS blocks requester raw rows; JWT-scoped safe RPCs redact bank/proof fields while retaining masked IBAN and manual-exception audit markers | P0J-04…07 |
| Invoice/return amounts visible to requester | Request scope plus finance/procurement/stock capability required | P0J-08/09 |
| Payment documents downloadable by requester | Document-table RLS and `/api/portal-doc` require normalized reference, request scope, and effective financial/stock capability | P0J-10 + JS contract |
| Expired receipts/orphan R2 objects | New staging-locked, secret-protected, bounded cleanup; two list pages × 100, one-hour grace, all active/inactive references preserved | 5 dynamic cleanup tests |
| Quote capability crossed request scope | `portal_can_view_quotes` now requires scope **and** capability, except service role | P0J-01/02 |
| Direct-expense capability not job-aware | `fin_accountant` backfill plus job/user OR merge in portal; all server checks use `portal_effective_perm` | P0J-03 + JS contract |
| Pre-P0-1i document metadata trusted | Exact consumed-receipt reconciliation; unmatched rows quarantined and excluded from evidence gates | P0J-11/12 |
| Legacy pending/approved payments lacked normalized evidence | Rows are quarantined and status transitions fail closed until verified `payment_request` evidence exists | P0J-13 |

## Staging application and tests

Applied through the Supabase migration API:

- `20260803093553_p0_1j_exact_head_review_remediation`
- `20260803093756_p0_1j_upload_receipt_fk_index`

The P0-1j SQL regression ran inside `BEGIN/ROLLBACK` on staging and completed
without an exception: 13 assertions. Post-test verification showed both safe
RPCs present, the accountant capability present, and zero leaked `p0j_%` test
users. Local evidence:

- Stage-1 deployment safety: 60/60.
- Browser fixture/auth/network boundary: 6/6.
- Functional security contract: 14/14.
- Document authorization endpoint: 5/5.
- Upload cleanup: 5/5.
- File guard: 18/18; registration endpoint guard: 7/7.

Exact-head GitHub Actions evidence on code head `b478cc25a5130904e2f73c8e8a7028449e2e5cda`:

- `portal-tests` run `30806576478`: all three jobs passed.
- 256 SQL assertions + 18 file-guard + 7 registration-endpoint assertions passed.
- Baseline proof passed: phase A 30 files with 5 correctly deferred; phase B
  35 files on 061 + 062 + P0-1b…P0-1j.
- `hosted-preview-smoke` run `30806576369` passed.

The first exact-head CI attempt exposed a real legacy-row migration defect: the
backfill was blocked by `portal_payments_guard`. The final migration confines
`app.portal_transition=1` to a single transactional `DO` block. A staging
transaction proved a pre-existing pending payment is quarantined and then
rolled back; residue count was zero.

## Advisor and operational residuals

Supabase advisor after P0-1j reports 93 security entries (7 INFO, 86 WARN) and
30 performance INFO entries. Most function warnings are generic notices for
intentional, body-authorized `SECURITY DEFINER` RPCs; they still require a
signature-by-signature disposition. Leaked-password protection remains disabled.
New indexes appear unused immediately after creation, which is expected on the
fresh staging database. The missing upload-receipt foreign-key index was fixed.

Cloudflare deployment `1e7d27e2-9dc5-4124-9fe7-632de145dc0e` succeeded from
`b478cc25…` and owns the branch alias. Preview now has the exact staging bucket
marker, an encrypted cleanup secret, and `QUOTES_BUCKET` bound to
`aldeyabi-quotes-staging`. The endpoint is an explicit, bounded cleanup path;
no production configuration changed.

R2 reconciliation listed all 12 staging objects without exposing their keys.
Five canonical `reqdoc` objects were older than the grace window and had no
database reference; they were deleted by exact SHA-256 match. Seven referenced
objects were preserved. One active, test-like legacy offer references a missing
R2 object, and staging still contains pre-existing QA-shaped rows (13 users,
20 requests, 4 payments, 1 offer). Those records predate this transaction-safe
test run and were not deleted; they remain an evidence/reconciliation blocker.

## Rollback / fail-closed guidance

Restore a pre-P0-1j staging snapshot. Do not manually drop verification or
quarantine columns, and do not delete quarantined documents/payment rows: they
are audit evidence. If Preview must be rolled back, keep the cleanup endpoint
disabled by removing its scheduler; the endpoint itself fails closed without
the exact staging ref, bucket identity, binding, and secret.

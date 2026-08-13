# Staging QA/R2 cleanup — 2026-08-09

Scope was restricted to Supabase Staging `vpfnycxzqziltsnzxbpb` and Cloudflare R2 bucket
`aldeyabi-quotes-staging`. Production, `main`, production R2, and migration 063 were not touched.

## Guarded classification

- Preflight found exactly **20** operational requests.
- Every requester had an explicit test prefix: `qa_`, `stg_`, or `e2e_`; the guarded
  non-dummy count was **0**.
- The staging R2 bucket contained eight objects: one `_system/` cleanup attestation and seven
  small `qa-*` payment/receipt/quotation fixtures.
- All seven QA objects were referenced only by the classified dummy requests. No key had a
  reference from a non-dummy request.

## Executed cleanup

1. Deleted the seven exact QA object keys individually from `aldeyabi-quotes-staging`.
2. Re-listed the bucket using the strongly consistent object API; the only remaining object is
   `_system/staging-cleanup-attestation-v1.txt`.
3. In one guarded database transaction, required `request_count = 20` and
   `non_dummy_request_count = 0`, then reset `portal_requests` and its FK-dependent operational
   tables plus the five dummy idempotency rows. The cascade deliberately reset the staging audit
   chain because every operational row was classified as a fixture; master/configuration tables
   were not included.

## Post-cleanup verification

- Requests, items, approvals, award approvals, PO approvals, awards, offers, offer items,
  payments, receipts, request documents, supplier tokens, idempotency rows, and audit rows: **0**.
- Preserved configuration/master data: **23 portal profiles**, **22 active jobs**, and
  **3 settings rows**. Staging Auth users were not deleted or modified.
- R2 staging: **1** preserved `_system/` attestation object; **0** QA payment/receipt/quote objects.

Status: **QA/R2 operational residue gate closed for the classified 2026-08-02 fixtures.** This
does not establish Production readiness and does not close Auth E2E, leaked-password protection,
credential rotation, or independent security review.

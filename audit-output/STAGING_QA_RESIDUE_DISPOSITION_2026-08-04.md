# Staging QA residue + R2 object disposition — `vpfnycxzqziltsnzxbpb` (2026-08-04)

> Investigated live via the owner-authorized connector (read-only). **Characterization
> only — this item stays OPEN / owner-action-required.** No purge/reset was authorized
> or executed, and no rows were modified.

## What is on staging
All content **appears to be QA / E2E test fixtures created on 2026-08-02** (the staging
bootstrap + QA day). The naming patterns and single-day creation are strong *indicators*
of test data, **not proof** — the real-vs-test classification is **UNVERIFIED pending
explicit owner attestation** for this staging dataset (naming alone does not classify data).

- **20 `portal_requests`** — every title is a test marker, e.g. `QA-Q-DOA-25000-PR74`,
  `QA-Q-DOA-25001-PR74`, `QA-Q-DOA-125000/125001-PR74`, `QA-V-FULL-E2E-75000-PR74`,
  `Mandatory document gate test`, `Cross department visibility`, `QA confidential quote
  test`, `QA direct expense allowed`, and a deliberate XSS-probe title
  `<img src=x onerror=alert(1)>` (a stored-XSS negative-test row). Requesters are all
  `qa_*` / `stg_*` / `e2e_*` accounts.
- **5 `portal_offers`** — suppliers `QA Supplier One/A/B/C` and `QA Confidential Supplier`.
- **4 `portal_payments`**, **0 `portal_request_documents`**, **0 `portal_upload_receipts`**.

## The "missing R2 quote object"
- Offer **`99000001`** on `REQ-P0D-QUOTE` has `quote_pdf_key = qa/test.pdf` — a
  **synthetic, out-of-namespace key** (the real upload flow always writes
  `quotes/<request_id>/<random>`), pointing at an R2 object that **does not exist**.
- The other four offers use proper-namespace keys (`quotes/REQ-…/…pdf`) but are equally
  **seeded fixtures** whose R2 objects were never actually uploaded.

## Disposition
1. **Not evidence.** None of these rows may be counted as real workflow/financial
   evidence. The live workflow proof used **create-and-rollback** fixtures
   (`LIVE_STAGING_VERIFICATION_2026-08-04.md`) precisely to avoid depending on seeded QA rows.
2. **No leak risk.** A missing R2 object cannot expose anything: `portal-doc.js` /
   `portal-quote.js` **fail closed** — a download for a key with no backing object (or no
   visibility) returns an error, never data. The out-of-namespace `qa/test.pdf` also cannot
   be minted by the real upload path (which is server-key-namespaced).
3. **Purge before go-live.** These QA fixtures should be **purged** (or the staging project
   re-seeded clean) before launch so no test artifact is mistaken for real data. This is a
   **data-cleanup task on isolated staging**, not a code defect, and carries **no production
   risk** (production `mwbjoysuybgbrvfrprex` is untouched and unreachable from this connector).

**Status: OPEN — owner action required.** Gate 1 keeps this item open until the owner
(1) attests the real-vs-test classification, and (2) purges the `PR74` / `QA-*` / `qa_*`
fixtures (or resets staging) prior to sign-off. No repo change required; no leak/production
risk in the meantime.

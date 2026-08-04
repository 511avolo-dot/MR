# Live staging verification — isolated staging `vpfnycxzqziltsnzxbpb` (2026-08-04)

> **Executed directly against the isolated staging Supabase project** (name `demo`,
> region ap-south-1, `ACTIVE_HEALTHY`) via the owner-authorized Supabase connector.
> The connector lists **only** `vpfnycxzqziltsnzxbpb`; the production project
> `mwbjoysuybgbrvfrprex` is not reachable through it.
>
> **Method — zero-persistence:** every workflow assertion runs the **real RPC
> sequence** under impersonated identities (`request.jwt.claims.email` → native
> `auth.jwt()` → `portal_username()`), inside a block that ends with
> `RAISE EXCEPTION` so the whole transaction **rolls back — nothing is written to
> staging**. RLS checks additionally `SET LOCAL ROLE authenticated` so row policies
> actually enforce (the connection is `postgres`, which otherwise bypasses RLS).
> **Post-run cleanliness was confirmed** (see §8). No production, no `main`, no
> migration `063`, no persisted data, no secrets logged.

## 1. Schema / migration parity (read-only)
- Migrations present: the full `p0_1 … p0_1n` chain (20 rows) — matches the PR.
- `portal_user_directory` is a **table** (`relkind='r'`) — `p0_1b` applied.
- `portal_can_read_raw_request` present — `p0_1n` applied.
- **134** `SECURITY DEFINER` portal functions; **0** without a pinned `search_path`.
  → **exactly matches** `SECURITY_ADVISOR_DEFINER_DISPOSITION.md` (repo-derived).

## 2. Security Advisor — live, reconciled exactly with the repo disposition
Live `get_advisors(security)` = **96 entries (7 INFO / 89 WARN)**:

| Advisor name | Count | Level | Disposition |
|---|---|---|---|
| `authenticated_security_definer_function_executable` | 86 | WARN | Category B — authz enforced inside each body |
| `anon_security_definer_function_executable` | 2 | WARN | Category C — supplier self-service, token-gated |
| `rls_enabled_no_policy` | 7 | INFO | server-only deny-all tables (intended) |
| `auth_leaked_password_protection` | 1 | WARN | **owner toggle — genuinely open** |
| `function_search_path_mutable` | 0 | — | ✓ |
| `security_definer_view` | 0 | — | ✓ |

Every category maps 1:1 to the repo disposition. The only actionable live item is
**leaked-password protection** (an Auth setting the owner enables).

## 3. Approval workflow — full multi-role chain (rolled back)
A ≤25K OPS purchase, driven by the real seeded org:
- `portal_create_request` → `in_review`, **3-stage** `need` chain built.
- Chain walked by the correct resolved approver per stage:
  `dept_manager (qa_dept_manager)` → `can_approve_finance (stg_finance)` →
  `can_manage_procurement (stg_procurement)` → phase **pricing**.
- Offers → `portal_award` → **award-review** approval → **po-review** approval →
  phase **payment**. (need + award + PO cycles all exercised end-to-end.)

## 4. Segregation of duties — negatives all DENIED (rolled back)
- Requester approves **own** request → denied.
- Unauthorized user (warehouse, no approve perm) approves → denied.
- Payment **requester** attempts disburse → denied.
- Payment **approver (finance)** attempts to also disburse → denied.
- Disburse succeeds only as a third party (accountant): **requester ≠ approver ≠
  executor** triple enforced live.

## 5. Financial evidence gate (p0_1i) — enforced live
- `portal_payment_request` on a purchase is **blocked** unless `details.proof_key`
  is a **valid server-issued upload receipt** (kinds inst/inv/pay/disb) — an
  anti-forgery control, correctly enforced (`payment_docs_required=1` on staging).
- With the gate isolated (flag relaxed inside the rolled-back tx only), the disburse
  SoD triple and goods-receipt recording complete (§4).

## 6. RLS / privacy (P0-1 remediations) — enforced under real `authenticated` role
- R1: requester sees own request row.
- R2: unrelated other-department employee **cannot** see the request (RLS).
- R3: `portal_can_read_raw_request` (p0_1n) — finance = **true**, unrelated = **false**.
- R4: a non-admin **cannot** read another `portal_users` row (email/permissions).
- R5: `portal_user_directory` exposes only `active, department_id, display_name, username`.

## 7. Audit tamper-evidence (057)
- `portal_audit_verify()` → `ok = true` (hash-chain intact) for an admin identity;
  correctly **denied** for a caller without finance/admin permission.

## 7b. Per-role authorization probe matrix (2026-08-04, real `authenticated` role, rolled back)
The exact probe set the browser scaffold runs (P-RLS / P-DIR / P-PERM / P-AUDIT), executed
server-side for **four real role identities** under `SET LOCAL ROLE authenticated` + JWT
impersonation. All PASS with error-specific outcomes:

| Role (identity) | other `portal_users` visible (RLS) | `can_manage_users` | `portal_audit_verify` |
|---|---|---|---|
| requester (`stg.requester`) | **0** (blocked) | false | **denied — SQLSTATE `P0001`** |
| finance (`stg.finance`) | 0 | false | ok |
| procurement (`stg.procurement`) | 0 | false | ok |
| admin (`stg.admin`) | **22** (all) | true | ok |

`portal_user_directory` exposed exactly `active, department_id, display_name, username`.
The negative `audit_verify` case is a **specific permission denial (`P0001`)**, not an
arbitrary error — satisfying the evidence-quality bar. **Browser-transport note:** the
hosted **browser** run of this same matrix could not be executed from the agent sandbox —
Node egress works but Chromium's tunnel is reset by the egress proxy — so the browser layer
must run in **CI** (`authenticated-e2e` workflow + the owner's `STAGING_E2E_USERS` secret);
the authorization evidence above is the DB-level equivalent.

## 8. Production-cleanliness after the run (all tests rolled back)
`requests=20` (unchanged) · `LIVE %` test requests = **0** · `b3_%` test users = **0**
· `payment_docs_required` back to **1** (the in-tx relax reverted) · OPS manager
unchanged (`qa_dept_manager`). **The staging dataset is exactly as before.**

## Observations (not governance defects)
1. **Receipt auto-close — RESOLVED, not a defect.** An earlier ad-hoc test left the
   request at `receipt_pending`; root cause was a **test-harness error** — the test passed
   `{"seq":…}` while `portal_record_receipt` matches items by **`item_id`**
   (`portal-standalone.sql:3038`), and the frontend correctly passes `{item_id: it._id, qty}`
   (`purchase-portal.html:3324`). Re-run with the correct `item_id`: the **full cycle reaches
   `closed`** live (create → 3 approvals → pricing → offers → award → award-approval → PO →
   payment → disburse SoD triple → receipt → **closed**), rolled back. No code change needed.
2. **Leaked-password protection** is off (owner Auth toggle) — the one live-actionable
   advisor item.
3. **`payment_docs_required` enforcement lives in `p0_1i`** (applied on staging and in
   CI), while `portal-standalone.sql:7948` still carries a stale "unenforced" comment.
   Behaviour is correct; the standalone comment should be refreshed for accuracy.

## Scope note
This is **database-level** verification of authorization, SoD, RLS/privacy, financial
governance, evidence gating, and audit integrity on the live isolated staging project.
It does **not** replace the **authenticated hosted browser E2E** (the ready-to-run
`scripts/e2e/authenticated-multirole-journey.mjs` covers that once staging login
credentials are provided) or the fresh independent adversarial review. **Gate 1 remains
HELD; verdict NOT READY.**

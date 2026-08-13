# Live staging re-verification — isolated staging `vpfnycxzqziltsnzxbpb` (2026-08-05)

> Re-run at owner request ("نفذ") after the Supabase connector was re-attached. Executed
> **directly** against the isolated staging project (name `demo`, ap-south-1,
> `ACTIVE_HEALTHY`). The connector lists **only** `vpfnycxzqziltsnzxbpb`; the production
> project `mwbjoysuybgbrvfrprex` is **not reachable** through it.
>
> **Method — zero-persistence.** Every workflow assertion runs the **real RPC sequence**
> under impersonated identities (`request.jwt.claims.email` → native `auth.jwt()` →
> `portal_username()`), inside a block that ends with `RAISE EXCEPTION` so the whole
> transaction **rolls back — nothing is written**. RLS/authorization probes additionally
> `SET LOCAL ROLE authenticated` so row policies actually enforce (the connection is
> `postgres`, which otherwise bypasses RLS). No production, no `main`, no migration `063`,
> no persisted data, no secrets logged.

## 0. Environment parity (read-only)
- Migrations: full `p0_1 … p0_1n` chain (20 rows) — matches PR head `635bf4d`.
- Security advisor = **96** findings, all pre-dispositioned:
  86 `authenticated_security_definer_function_executable` (WARN, authz enforced in-body) ·
  2 `anon_security_definer_function_executable` (WARN, token-gated supplier self-service) ·
  7 `rls_enabled_no_policy` (INFO, server-only deny-all tables) ·
  **1 `auth_leaked_password_protection` (WARN — owner Auth toggle, owner-owned).**
  Zero new/unexpected. Zero `function_search_path_mutable`, zero `security_definer_view`.

## 1. Full lifecycle ≤25K — real RPC chain to CLOSED (rolled back)
Driven by the real seeded org identities; every step asserted:

| # | Step | Result |
|---|---|---|
| L1 | `portal_create_request` (OPS, single-source, 2×3000) | → `in_review` **PASS** |
| L2 | need chain: `dept_manager (qa_dept_manager)` → `can_approve_finance (stg_finance)` → `can_manage_procurement (stg_procurement)` | → `pricing` **PASS** |
| L3 | 2 offers + `portal_award` (cheapest 6000) | → `award_review` **PASS** |
| L4 | award approval by a **different** `can_approve_award` holder (`qa_procurement`) | → `awarded`/`payment` (≤25K direct PO, 0 committee) **PASS** |
| L5 | `portal_payment_request` (bank, IBAN `SA`+22, account name) | → `payment_pending` **PASS** |
| L6 | disburse by a **third party** (`stg_accountant`) | → `receipt_pending` **PASS** |
| L7 | `portal_record_receipt` full qty (matched by `item_id`) | → **`closed`** **PASS** |

## 2. Segregation-of-duties negatives — all DENIED (rolled back)
| # | Attempt | Result |
|---|---|---|
| N1 | requester approves **own** need request | **DENIED** |
| N2 | awarder (`stg_procurement`) approves **own** award | **DENIED** |
| N3 | payment approver (`stg_finance`) also **disburses** it | **DENIED** |
| — | disburse succeeds only as a third party → **requester ≠ approver ≠ executor** triple enforced live |

## 3. Financial evidence gate — ENFORCED live
- **G1:** `portal_payment_request` on a purchase is **BLOCKED** without a valid
  server-issued proof document — live error: *"مستند الدفع مطلوب قبل إنشاء طلب الصرف"*
  (`payment_docs_required=1`). The happy path completed only after the flag was relaxed
  **inside the rolled-back transaction** (reverted on rollback).

## 4. RLS / least-privilege on `portal_users` — enforced under real `authenticated`
| Probe | requester | finance | procurement | admin |
|---|---|---|---|---|
| other `portal_users` rows visible (RLS) | **0** | 0 | 0 | **23 (all)** |
| `portal_audit_verify()` | **DENIED** (`P0001`, finance/admin only) | ok=true | — | — |
- `portal_user_directory` exposed **exactly** `active, department_id, display_name, username`
  (no email / role / permissions / job_key / delegation).
- **Escalation negative (quality-checked):** a non-admin (`stg_requester`) direct
  `UPDATE portal_users SET role='admin', permissions||…` under RLS affected
  **`ROW_COUNT = 0`**; role read back as `user`, `can_manage_users = null`; authoritative
  postgres-view role still `user`. **RLS blocked the write with real effect** — verified by
  row-count + read-back, not merely by absence of error (avoids the 0-row false-pass).

## 5. Production-cleanliness after the run (everything rolled back)
`total_requests = 20` (unchanged) · `total_users = 23` (unchanged) ·
`stg_requester.role = user` (unchanged) · `quote_doc_required = 1` and
`payment_docs_required = 1` (both reverted) · `LIVE-PROOF%` requests = **0**.
**The staging dataset is exactly as before.**

## Scope note
Database-level verification of authorization, SoD, RLS/privacy, the financial evidence gate,
and full workflow-to-close on the live isolated staging project — freshly re-run 2026-08-05,
zero persistence. It does **not** replace fresh independent adversarial review. The single
live-actionable advisor item (leaked-password protection) and all account/service-role/
staging→production operational steps are **owner-owned** (owner's explicit instruction).
PR #74 stays **Draft**; **Gate 1 HELD**.

# Security Advisor — `SECURITY DEFINER` signature-by-signature disposition (System 3)

> **Repo-side disposition. No credentials, no live mutation.** This document is the
> code-derived authorization disposition for the Supabase Security Advisor
> `SECURITY DEFINER` family of warnings on the portal (`portal_*`) schema. It is
> produced by loading the deterministic clean baseline + the full `062` + P0-1b…P0-1n
> chain on a fresh PostgreSQL 16 database and querying the catalog — it does **not**
> read or change any live project. The **live re-scan against staging
> `vpfnycxzqziltsnzxbpb` to confirm the exact advisor counts remains owner-gated.**

- **Code-under-test head:** `279f62d95dad` (branch `audit/enterprise-certification-2026-07-27`, PR #74 Draft).
- **Method:** `bash db/portal-tests/run.sh` (clean PG16, chain applied once, **EXIT 0 / 273 SQL**), then `pg_proc`/`pg_class`/`has_function_privilege` catalog queries. Every figure below is reproducible from the built DB.
- **Scope:** `public.portal_*` objects only. Systems 1/2 are out of scope (isolation is a separate gate).

---

## 1. Global invariants (why `SECURITY DEFINER` is safe here)

| Invariant | Measured | Advisor relevance |
|---|---|---|
| Total `portal_*` `SECURITY DEFINER` functions | **134** | the population the advisor flags |
| …missing a pinned `search_path` | **0** | closes `function_search_path_mutable` (enforced by test `11_security.sql` S5) |
| …executable by `PUBLIC` | **0** | no anonymous world-execute |
| …executable by `anon` | **2** (intended, token-gated — category C) | closes the anonymous-execute concern for all but the documented supplier self-service |
| `portal_*` `SECURITY DEFINER` **views** (not `security_invoker`) | **0** | closes `security_definer_view` — the former `portal_user_directory` definer view was replaced by an RLS table in `p0_1b` |
| Actor identity source in DEFINER bodies | **JWT** (`portal_username()` / `auth.jwt()`), never `current_user` | neutralizes the classic DEFINER privilege-confusion pitfall — a caller can never act as the function owner's identity |
| Direct client writes to guarded tables | **deny-by-default** trigger guards | DEFINER RPCs are the *only* sanctioned write path; guards reject everything else |

**Disposition of the two non-function advisor items:**
- `function_search_path_mutable` → **fully dispositioned (0 offenders).**
- `security_definer_view` → **fully dispositioned (0 offenders).**

The remaining `SECURITY DEFINER` **function** warnings are generic (the advisor flags the *property*, not a defect). Each of the 134 is dispositioned below by execution boundary.

---

## 2. Disposition by execution boundary

### Category A — server-only (48 functions): **INTENDED, not client-reachable**
`EXECUTE` is revoked from `anon` **and** `authenticated`; these run only when a **trigger fires** or when **`service_role`** (server / Edge / cron) calls them. They are guards (`*_guard`), the transactional outbox (`portal_outbox_*`), token minting (`portal_create_token`, `portal_supplier_token_request`), SLA/notification/chain internals (`portal_run_sla`, `portal_requests_notify`, `portal_build_chain`, …), and financial aggregation helpers (`portal_award_total`, `portal_budget_committed`, …). A logged-in user cannot invoke any of them over PostgREST. **Disposition: benign — the advisor flags the DEFINER property; the functions are not part of the client attack surface.** (Set pinned by test `11_security.sql` S7/S8.)

| # | Function signature |
|---|---|
| 1 | `portal_approvals_guard()` |
| 2 | `portal_audit_write(p_request_id text, p_event text, p_actor text, p_channel text, p_detail jsonb)` |
| 3 | `portal_award_approvals_guard()` |
| 4 | `portal_award_guard()` |
| 5 | `portal_award_total(p_request_id text)` |
| 6 | `portal_beneficiary_iban_guard()` |
| 7 | `portal_budget_committed(p_dept text, p_year integer)` |
| 8 | `portal_budget_enforce()` |
| 9 | `portal_build_chain(p_request_id text, p_cycle text)` |
| 10 | `portal_build_po_chain(p_request_id text, p_total numeric)` |
| 11 | `portal_config_guard()` |
| 12 | `portal_contract_consumed(p_contract_id bigint)` |
| 13 | `portal_contract_enforce()` |
| 14 | `portal_create_token(p_request_id text, p_kind text, p_seq integer, p_approver text, p_ttl_hours numeric, p_cycle text)` |
| 15 | `portal_direct_expense_document_stage()` |
| 16 | `portal_direct_expense_verified_evidence_guard()` |
| 17 | `portal_direct_payment_evidence_after()` |
| 18 | `portal_direct_payment_evidence_before()` |
| 19 | `portal_effective_approver(p_user text)` |
| 20 | `portal_enqueue_stage_notifications(p_request_id text, p_cycle text)` |
| 21 | `portal_invoiced_total(p_request_id text)` |
| 22 | `portal_locked_guard()` |
| 23 | `portal_open_direct_payment(p_request_id text, p_last_approver text)` |
| 24 | `portal_outbox_claim(p_limit integer)` |
| 25 | `portal_outbox_enqueue()` |
| 26 | `portal_outbox_mark(p_id bigint, p_ok boolean, p_error text)` |
| 27 | `portal_outbox_purge(p_days integer)` |
| 28 | `portal_payment_evidence_after()` |
| 29 | `portal_payment_evidence_before()` |
| 30 | `portal_payment_legacy_quarantine_guard()` |
| 31 | `portal_payments_guard()` |
| 32 | `portal_po_approvals_guard()` |
| 33 | `portal_pr_transition_email(p_token text, p_action text, p_comment text)` |
| 34 | `portal_qualified_approver(p_base text, p_requester text)` |
| 35 | `portal_recurring_run()` |
| 36 | `portal_reqdoc_guard()` |
| 37 | `portal_request_document_receipt_guard()` |
| 38 | `portal_request_status_guard()` |
| 39 | `portal_requests_notify()` |
| 40 | `portal_resolve_stage(p_request_id text, p_stage portal_approvals)` |
| 41 | `portal_returns_total(p_request_id text)` |
| 42 | `portal_run_sla()` |
| 43 | `portal_supplier_iban_guard()` |
| 44 | `portal_supplier_token_request(p_token text)` |
| 45 | `portal_sync_user_directory()` |
| 46 | `portal_three_way_guard()` |
| 47 | `portal_users_guard()` |
| 48 | `portal_validate_upload_receipt(p_storage_key text, p_request_id text, p_expected_uploader text, p_allowed_kinds text[], p_consume boolean)` |

### Category B — authenticated RPC (84 functions): **INTENDED, safety by internal authorization**
`EXECUTE` for `authenticated`. `SECURITY DEFINER` is **required** so a controlled, audited write can proceed past the deny-by-default RLS guards — that is the design. Safety does **not** rest on the SQL role; each function: (1) resolves the actor from the **JWT**, (2) enforces the specific **capability / role** and **segregation-of-duties** for the action, (3) pins `search_path=public`, and (4) writes through the append-only audit trail. These properties are exercised by the negative assertions across `10`–`45` (self-approval, non-approver, cross-department, duplicate-disbursement, cap, and privilege-escalation attempts all rejected). **Disposition: benign — DEFINER is the mechanism; authorization is enforced inside every body.**

| # | Function signature |
|---|---|
| 1 | `portal_apply_job(p_username text, p_job_key text)` |
| 2 | `portal_attach_document(p_request_id text, p_document_type text, p_storage_key text, p_mime_type text, p_title text, p_description text, p_original_file_name text, p_size_bytes bigint, p_checksum text, p_payment_id bigint, p_source_stage text)` |
| 3 | `portal_audit_verify()` |
| 4 | `portal_award(p_request_id text, p_winner_offer_id bigint, p_reason text)` |
| 5 | `portal_award_split(p_request_id text, p_lines jsonb, p_reason text)` |
| 6 | `portal_award_transition(p_request_id text, p_action text, p_comment text)` |
| 7 | `portal_beneficiary_delete(p_id bigint)` |
| 8 | `portal_beneficiary_iban_approve(p_change_id bigint)` |
| 9 | `portal_beneficiary_iban_reject(p_change_id bigint, p_note text)` |
| 10 | `portal_beneficiary_iban_request(p_beneficiary_id bigint, p_new_iban text, p_reason text)` |
| 11 | `portal_beneficiary_save(p_id bigint, p_name text, p_type text, p_iban text, p_account_name text, p_tax_no text, p_contact text, p_note text)` |
| 12 | `portal_bounce_to_requester(p_request_id text, p_reason text)` |
| 13 | `portal_budget_delete(p_id bigint)` |
| 14 | `portal_budget_set(p_dept text, p_year integer, p_amount numeric, p_note text)` |
| 15 | `portal_budget_status(p_dept text, p_year integer)` |
| 16 | `portal_bulk_transition(p_request_ids text[], p_action text, p_comment text, p_cycle text)` |
| 17 | `portal_can_read_raw_document(p_request_id text, p_payment_id bigint)` |
| 18 | `portal_can_read_raw_request(p_request_id text)` |
| 19 | `portal_can_see_request(p_id text)` |
| 20 | `portal_can_see_request(p_id text, p_requester text, p_dept text)` |
| 21 | `portal_can_view_quotes(p_request_id text)` |
| 22 | `portal_cancel_request(p_request_id text, p_reason text)` |
| 23 | `portal_committee_route(p_total numeric)` |
| 24 | `portal_contract_close(p_id bigint)` |
| 25 | `portal_contract_set(p_id bigint, p_title text, p_supplier text, p_ceiling numeric, p_start date, p_end date, p_no text, p_currency text, p_note text)` |
| 26 | `portal_contract_status(p_contract_id bigint)` |
| 27 | `portal_create_expense(p_beneficiary text, p_amount numeric, p_kind text, p_purpose text, p_department_id text, p_need_by date, p_details jsonb, p_note text, p_beneficiary_id bigint)` |
| 28 | `portal_create_expense_draft(p_beneficiary text, p_amount numeric, p_kind text, p_purpose text, p_department_id text, p_need_by date, p_details jsonb, p_note text, p_beneficiary_id bigint, p_iban_reason text)` |
| 29 | `portal_create_request(p_title text, p_department_id text, p_priority text, p_items jsonb, p_project text, p_need_by date, p_proc_type text, p_justification text, p_note text)` |
| 30 | `portal_currency_delete(p_code text)` |
| 31 | `portal_currency_rate(p_code text)` |
| 32 | `portal_currency_set(p_code text, p_name text, p_rate numeric, p_active boolean)` |
| 33 | `portal_delete_department(p_id text)` |
| 34 | `portal_delete_job(p_key text)` |
| 35 | `portal_delete_supplier(p_id bigint)` |
| 36 | `portal_delete_user(p_username text)` |
| 37 | `portal_effective_perm(p_key text)` |
| 38 | `portal_email_allowed(p_email text)` |
| 39 | `portal_get_committee_policy()` |
| 40 | `portal_has_perm(p_key text)` |
| 41 | `portal_invoice_record(p_request_id text, p_invoice_no text, p_amount numeric, p_supplier_name text, p_invoice_date date, p_doc_key text, p_note text)` |
| 42 | `portal_is_admin()` |
| 43 | `portal_link_request_contract(p_request_id text, p_contract_id bigint)` |
| 44 | `portal_my_purchase_dossiers()` |
| 45 | `portal_my_scope()` |
| 46 | `portal_my_sector()` |
| 47 | `portal_payment_request(p_request_id text, p_kind text, p_amount numeric, p_custody_to text, p_details jsonb, p_offer_id bigint)` |
| 48 | `portal_payment_transition(p_payment_id bigint, p_action text, p_comment text, p_return_to text, p_details jsonb, p_idem_key text)` |
| 49 | `portal_payment_void(p_payment_id bigint, p_reason text)` |
| 50 | `portal_po_transition(p_request_id text, p_action text, p_comment text)` |
| 51 | `portal_pr_transition(p_request_id text, p_action text, p_comment text, p_hold_until date, p_return_to_seq integer, p_cycle text)` |
| 52 | `portal_record_receipt(p_request_id text, p_lines jsonb, p_note text, p_doc_key text)` |
| 53 | `portal_recover_legacy_payment_evidence(p_payment_id bigint, p_storage_key text)` |
| 54 | `portal_recurring_delete(p_id bigint)` |
| 55 | `portal_recurring_save(p_id bigint, p_title text, p_department_id text, p_amount numeric, p_kind text, p_details jsonb, p_frequency text, p_next_run date, p_beneficiary_id bigint)` |
| 56 | `portal_recurring_set_active(p_id bigint, p_active boolean)` |
| 57 | `portal_remove_document(p_doc_id bigint)` |
| 58 | `portal_replace_document(p_doc_id bigint, p_storage_key text, p_mime_type text, p_title text, p_description text, p_original_file_name text, p_size_bytes bigint, p_checksum text)` |
| 59 | `portal_resubmit_request(p_request_id text, p_comment text)` |
| 60 | `portal_resume_hold(p_request_id text, p_comment text)` |
| 61 | `portal_return_record(p_request_id text, p_lines jsonb, p_reason text, p_supplier_name text, p_doc_key text)` |
| 62 | `portal_return_status(p_request_id text)` |
| 63 | `portal_safe_visible_direct_expenses()` |
| 64 | `portal_safe_visible_payments()` |
| 65 | `portal_save_department(p_id text, p_name text, p_sector text, p_manager text, p_active boolean)` |
| 66 | `portal_save_job(p_key text, p_title text, p_category text, p_scope text, p_permissions jsonb, p_description text)` |
| 67 | `portal_set_committee(p_members jsonb)` |
| 68 | `portal_set_committee_policy(p_policy jsonb)` |
| 69 | `portal_set_installments(p_request_id text, p_on boolean)` |
| 70 | `portal_set_request_currency(p_request_id text, p_code text)` |
| 71 | `portal_setting_bool(p_key text, p_default boolean)` |
| 72 | `portal_setting_num(p_key text, p_default numeric)` |
| 73 | `portal_sla_hours()` |
| 74 | `portal_sla_tick()` |
| 75 | `portal_submit_expense(p_request_id text)` |
| 76 | `portal_submit_offer(p_request_id text, p_supplier text, p_total numeric, p_delivery_days integer, p_quality integer, p_payment_days integer, p_note text, p_quote_pdf_key text, p_items jsonb)` |
| 77 | `portal_submit_request(p_request_id text)` |
| 78 | `portal_supplier_iban_approve(p_change_id bigint)` |
| 79 | `portal_supplier_iban_reject(p_change_id bigint, p_note text)` |
| 80 | `portal_supplier_iban_request(p_supplier_id bigint, p_new_iban text, p_reason text)` |
| 81 | `portal_supplier_invite(p_request_id text, p_supplier text, p_email text, p_ttl_days integer)` |
| 82 | `portal_three_way_status(p_request_id text)` |
| 83 | `portal_update_request(p_request_id text, p_title text, p_items jsonb, p_project text, p_priority text, p_need_by date, p_proc_type text, p_justification text, p_note text)` |
| 84 | `portal_username()` |

### Category C — supplier self-service (2 functions): **INTENDED & documented (migration 047)**
`EXECUTE` for `anon`, by design: an external supplier has no account, so a **43-character random single-use token** is the identity. Both functions are `SECURITY DEFINER`, verify the token in-database, and expose **only that one request's line items** — never competitor offers, budgets, approvers, or bank data. **Disposition: accepted, documented; test `11_security.sql` S8 pins this to exactly these two names — any third anon-executable function fails the build.**

| # | Function signature |
|---|---|
| 1 | `portal_supplier_rfq(p_token text)` |
| 2 | `portal_supplier_submit(p_token text, p_items jsonb, p_delivery_days integer, p_payment_days integer, p_note text, p_quote_pdf_key text)` |

---

## 3. Residual / owner-gated

- **Live advisor re-scan — DONE (2026-08-04).** `get_advisors(security)` against staging `vpfnycxzqziltsnzxbpb` returned **96 entries (7 INFO / 89 WARN)** and matches this disposition **exactly**: 86 `authenticated_security_definer_function_executable`, 2 `anon_security_definer_function_executable`, 7 `rls_enabled_no_policy` (INFO), 1 `auth_leaked_password_protection`, 0 `function_search_path_mutable`, 0 `security_definer_view`. Evidence: `audit-output/LIVE_STAGING_VERIFICATION_2026-08-04.md`.
- **INFO items and `leaked-password protection`.** Separate owner decisions (Auth configuration), not part of the DEFINER disposition.

## 4. Closure bar — this table does NOT close the blocker by itself

Per the owner Gate review, the Security Advisor blocker is **not** closed from the disposition table alone. What is done vs. what remains:

- **Done:** every signature is enumerated against the **current** live SQL catalog (134 fns), each with a pinned `search_path` (0 offenders) and its exact caller boundary (48 server-only / 84 authenticated / 2 anon); the live re-scan matches; and **build-failing negative controls exist** — `11_security.sql` **S7** pins the exact server-only set and **S8** pins the exact anon-executable set (any drift fails CI), plus the live RLS/RPC negatives in `LIVE_STAGING_VERIFICATION_2026-08-04.md` (cross-department read denied, raw-vs-safe boundary, self/unauthorized approve denied, SoD triple).
- **Live per-signature attestation (2026-08-04, catalog-queried):**
  - **Owner:** all 134 owned uniformly by **`postgres`** (no lower-privilege or unexpected owner).
  - **`search_path`:** all fixed / non-mutable — **133 = `search_path=public`**, **1 = `search_path=public, extensions`** (the lone extension-using function); advisor `function_search_path_mutable = 0`.
  - **Grants:** **48** `service_role`-only · **84** `authenticated`+`service_role` · **2** `anon`+`authenticated`+`service_role` (the token-gated supplier pair); `service_role` can execute all; `PUBLIC` executes none.
- **Per-signature negative-execution tests (added):** `db/portal-tests/46_definer_authz_negatives.sql` (10 build-failing assertions) proves a **bare `authenticated` caller is rejected** by each security-critical DEFINER write RPC — `portal_save_job`, `portal_delete_user`, `portal_set_committee`, `portal_set_committee_policy`, `portal_budget_set`, `portal_currency_set`, `portal_beneficiary_save`, `portal_save_department`, `portal_recurring_save`, `portal_delete_department`. Verified locally in the full suite (EXIT 0).
- **Remaining for closure:** extend negative-execution coverage to the rest of the authenticated write surface (the 10 above are the highest-risk admin/finance mutations; more can be added on the same pattern), and the **fresh independent adversarial review** (externally blocked — Codex usage limit). Until both land, this blocker stays **OPEN**.

**Gate 1 remains HELD; verdict NOT READY. No code/DB/production change was made to produce this document.**

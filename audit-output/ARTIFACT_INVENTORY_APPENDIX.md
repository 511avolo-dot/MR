# ARTIFACT INVENTORY — MACHINE-DERIVED APPENDIX (G0-R4 · access classes G0-F2)

> Generated from `db/portal-standalone.sql` + `functions/api/` + repo root; source snapshot used for generation = head `1e44e33`. One row per concrete artifact. Companion to `ARTIFACT_INVENTORY.md` (narrative). Ownership: all `portal_*` = System 3 unless noted.

**Totals:** 35 tables · 120 functions · 27 triggers · 12 policies · endpoints/pages enumerated below.

**Access-class methodology (G0-F2 correction).** The earlier uniform line "RLS on; SELECT scoped / writes deny-by-default via guards" was **inaccurate for server-only / service-role-only tables and for functions** and has been replaced with **source-derived** classes:
- **Tables** (verified from the RLS-enable loop `portal-standalone.sql:1680-1687`, the `auth_all` loop `:1696-1703`, and each `CREATE POLICY` / `REVOKE` / `GRANT`): `auth_all` (13, incl. `portal_po_approvals`) · scoped SELECT via `portal_can_see_request` (5) · perm-gated / anon-revoked SELECT + service-role writes (10) · own-row (`portal_notifications`) · SELECT-only append-only (`portal_audit`) · **server-only, RLS on with NO policy** (`portal_email_tokens`, `portal_idempotency`, `portal_supplier_tokens`) · **service-role-only** (`portal_invitations`, `portal_outbox`). A guard trigger is **only** claimed where source confirms one (see Triggers section) — not for every table.
- **Functions** (from `REVOKE ALL ON FUNCTION … FROM …` in source): **service_role/server-only** (14; revoked from anon+authenticated) · **authenticated+service_role** (anon/PUBLIC revoked) · **trigger-only** (`*_guard`/`*_chain`, invoked by triggers) · **PUBLIC default execute** (no REVOKE — SECURITY DEFINER with identity/authz enforced in the body). Full per-signature overload enumeration + a fresh Stage-2 least-privilege review of every SECURITY DEFINER grant/`search_path` remains **open** (ledger Stage-2); the classes here are facts, not the closure of that review.

## Pages (one row each)
| # | Page | System | Boundary |
|--|--|--|--|
| 1 | `index.html` | 2 | browser; Supabase Auth/anon-token |
| 2 | `invite.html` | 2 | browser; Supabase Auth/anon-token |
| 3 | `portal-quote-suite.html` | 3 | browser; Supabase Auth/anon-token |
| 4 | `purchase-portal.html` | 3 | browser; Supabase Auth/anon-token |
| 5 | `register-portal.html` | 3 | browser; Supabase Auth/anon-token |
| 6 | `register.html` | 1 | browser; Supabase Auth/anon-token |
| 7 | `requests.html` | 2 | browser; Supabase Auth/anon-token |
| 8 | `rfq.html` | 2 | browser; Supabase Auth/anon-token |
| 9 | `supplier-invitation-bilingual.html` | 2 | browser; Supabase Auth/anon-token |
| 10 | `supplier-invitation-two-boxes.html` | 2 | browser; Supabase Auth/anon-token |
| 11 | `supplier-quote.html` | 3 | browser; Supabase Auth/anon-token |

## API endpoints / modules (one row each)
| # | File | System | Auth boundary |
|--|--|--|--|
| 1 | `_file-guard.js` | shared | see ARTIFACT_INVENTORY.md §B |
| 2 | `_portal-shared.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 3 | `_pr-shared.js` | 2 | see ARTIFACT_INVENTORY.md §B |
| 4 | `admin-users.js` | 1 | see ARTIFACT_INVENTORY.md §B |
| 5 | `ai.js` | shared | see ARTIFACT_INVENTORY.md §B |
| 6 | `invite-supplier.js` | 1 | see ARTIFACT_INVENTORY.md §B |
| 7 | `notify.js` | 1 | see ARTIFACT_INVENTORY.md §B |
| 8 | `portal-action.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 9 | `portal-config.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 10 | `portal-doc.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 11 | `portal-invite.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 12 | `portal-notify.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 13 | `portal-outbox-drain.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 14 | `portal-quote.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 15 | `portal-register.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 16 | `portal-signup.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 17 | `portal-supplier-doc.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 18 | `portal-supplier-invite.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 19 | `portal-users.js` | 3 | see ARTIFACT_INVENTORY.md §B |
| 20 | `pr-action.js` | 2 | see ARTIFACT_INVENTORY.md §B |
| 21 | `reg-doc.js` | 1 | see ARTIFACT_INVENTORY.md §B |
| 22 | `verify.js` | 1 | see ARTIFACT_INVENTORY.md §B |

## Tables (one row each, System 3)
| # | Table | Access class (source-derived: access class · write mechanism) |
|--|--|--|
| 1 | `portal_users` | auth_all (FOR ALL authenticated); writes governed by admin/can_manage_users + config guard |
| 2 | `portal_departments` | auth_all; writes governed by config/admin guard |
| 3 | `portal_jobs` | auth_all; writes governed by config/admin guard (self-escalation blocked) |
| 4 | `portal_doa` | auth_all; writes governed by portal_doa guard + admin |
| 5 | `portal_workflows` | auth_all; writes governed by config/admin guard |
| 6 | `portal_requests` | SELECT scoped (see_scoped→portal_can_see_request); INSERT/UPDATE/DELETE authenticated, governed by status guard + transition GUC |
| 7 | `portal_request_items` | auth_all; writes governed by portal_locked_guard + transition GUC |
| 8 | `portal_approvals` | auth_all; writes governed by portal_approvals_guard + transition GUC |
| 9 | `portal_offers` | auth_all; writes governed by portal_locked_guard |
| 10 | `portal_award` | auth_all; writes governed by portal_award_guard |
| 11 | `portal_award_approvals` | auth_all; writes governed by portal_award_approvals_guard |
| 12 | `portal_payments` | SELECT request/finance-scoped (see_by_request); writes guarded |
| 13 | `portal_receipts` | auth_all; writes governed by portal_locked_guard |
| 14 | `portal_audit` | SELECT-only authenticated (audit_read); NO client write policy → append-only via portal_audit_write (service) + hash-chain trigger; immutable |
| 15 | `portal_email_tokens` | server-only — RLS on, NO policy → zero client access (service_role bypass only) |
| 16 | `portal_notifications` | own-row — FOR ALL authenticated USING recipient=portal_username() |
| 17 | `portal_settings` | auth_all; writes governed by portal_config_guard (admin/privileged) |
| 18 | `portal_po_approvals` | auth_all (explicit, line 931); writes authenticated + guard |
| 19 | `portal_invitations` | service-role-only — RLS on + REVOKE anon/authenticated/PUBLIC + GRANT service_role |
| 20 | `portal_suppliers` | SELECT perm-gated (manage_procurement/see_finance/manage_users/admin); write authenticated + IBAN guard |
| 21 | `portal_offer_items` | SELECT scoped (offer_items_read→portal_can_see_request); writes service_role-only + portal_locked_guard |
| 22 | `portal_award_lines` | SELECT scoped (award_lines_read→portal_can_see_request); writes service_role-only |
| 23 | `portal_outbox` | service-role-only — RLS on + REVOKE anon/authenticated/PUBLIC + GRANT service_role |
| 24 | `portal_budgets` | SELECT perm-gated (admin/see_finance/manage_procurement); anon revoked; writes service_role-only |
| 25 | `portal_supplier_iban_changes` | SELECT authenticated (anon revoked); writes service_role-only |
| 26 | `portal_supplier_invoices` | SELECT authenticated (anon revoked); writes service_role-only |
| 27 | `portal_returns` | SELECT authenticated (anon revoked); writes service_role-only |
| 28 | `portal_currencies` | SELECT authenticated (anon revoked from writes); writes service_role-only |
| 29 | `portal_contracts` | SELECT authenticated (anon revoked from writes); writes service_role-only + contract enforce trigger |
| 30 | `portal_supplier_tokens` | server-only — RLS on, NO policy → zero client access (service_role bypass only) |
| 31 | `portal_idempotency` | server-only — RLS on, NO policy → zero client access (service_role bypass only) |
| 32 | `portal_beneficiaries` | SELECT authenticated (anon revoked); writes service_role-only + IBAN guard |
| 33 | `portal_beneficiary_iban_changes` | SELECT authenticated (anon revoked); writes service_role-only |
| 34 | `portal_recurring_expenses` | SELECT authenticated (anon revoked); writes service_role-only |
| 35 | `portal_request_documents` | SELECT scoped (portal_reqdoc_read); GRANT SELECT authenticated, writes service_role-only + portal_reqdoc_guard |

## Functions (one row each, System 3)
| # | Function | Execute grant (source-derived) |
|--|--|--|
| 1 | `portal_username` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 2 | `portal_is_admin` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 3 | `portal_is_service` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 4 | `portal_is_privileged` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 5 | `portal_has_perm` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 6 | `portal_effective_approver` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 7 | `portal_approvals_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 8 | `portal_request_status_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 9 | `portal_award_approvals_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 10 | `portal_award_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 11 | `portal_payments_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 12 | `portal_users_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 13 | `portal_config_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 14 | `portal_audit_immutable` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 15 | `portal_locked_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 16 | `portal_audit_write` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 17 | `portal_resolve_stage` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 18 | `portal_create_request` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 19 | `portal_submit_request` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 20 | `portal_pr_transition` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 21 | `portal_submit_offer` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 22 | `portal_po_approvals_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 23 | `portal_build_po_chain` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 24 | `portal_award` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 25 | `portal_award_transition` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 26 | `portal_po_transition` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 27 | `portal_payment_request` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 28 | `portal_payment_transition` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 29 | `portal_record_receipt` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 30 | `portal_cancel_request` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 31 | `portal_gen_token` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 32 | `portal_create_token` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 33 | `portal_pr_transition_email` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 34 | `portal_resubmit_request` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 35 | `portal_setting_bool` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 36 | `portal_setting_num` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 37 | `portal_qualified_approver` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 38 | `portal_resume_hold` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 39 | `portal_sla_hours` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 40 | `portal_set_due` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 41 | `portal_run_sla` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 42 | `portal_sla_tick` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 43 | `portal_my_scope` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 44 | `portal_my_sector` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 45 | `portal_can_see_request` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 46 | `portal_email_allowed` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 47 | `portal_set_committee` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 48 | `portal_delete_user` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 49 | `portal_apply_job` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 50 | `portal_save_job` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 51 | `portal_delete_job` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 52 | `portal_save_department` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 53 | `portal_delete_department` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 54 | `portal_delete_supplier` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 55 | `portal_award_split` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 56 | `portal_set_installments` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 57 | `portal_bounce_to_requester` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 58 | `portal_outbox_enqueue` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 59 | `portal_outbox_claim` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 60 | `portal_outbox_mark` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 61 | `portal_outbox_purge` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 62 | `portal_budget_committed` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 63 | `portal_budget_status` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 64 | `portal_budget_set` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 65 | `portal_budget_delete` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 66 | `portal_budget_enforce` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 67 | `portal_supplier_iban_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 68 | `portal_supplier_iban_request` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 69 | `portal_supplier_iban_approve` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 70 | `portal_supplier_iban_reject` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 71 | `portal_award_total` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 72 | `portal_invoiced_total` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 73 | `portal_three_way_status` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 74 | `portal_invoice_record` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 75 | `portal_three_way_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 76 | `portal_returns_total` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 77 | `portal_return_record` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 78 | `portal_return_status` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 79 | `portal_currency_rate` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 80 | `portal_currency_set` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 81 | `portal_currency_delete` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 82 | `portal_set_request_currency` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 83 | `portal_contract_consumed` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 84 | `portal_contract_status` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 85 | `portal_contract_set` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 86 | `portal_contract_close` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 87 | `portal_link_request_contract` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 88 | `portal_contract_enforce` | PUBLIC default execute — no REVOKE in source; SECURITY DEFINER, identity/authz enforced in body |
| 89 | `portal_update_request` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 90 | `portal_supplier_invite` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 91 | `portal_supplier_rfq` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 92 | `portal_supplier_submit` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 93 | `portal_supplier_token_request` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 94 | `portal_build_chain` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 95 | `portal_create_expense` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 96 | `portal_open_direct_payment` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 97 | `portal_payment_void` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 98 | `portal_beneficiary_iban_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 99 | `portal_beneficiary_save` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 100 | `portal_beneficiary_delete` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 101 | `portal_beneficiary_iban_request` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 102 | `portal_beneficiary_iban_approve` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 103 | `portal_beneficiary_iban_reject` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 104 | `portal_bulk_transition` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 105 | `portal_recurring_next` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 106 | `portal_recurring_save` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 107 | `portal_recurring_set_active` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 108 | `portal_recurring_delete` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 109 | `portal_recurring_run` | service_role/server-only (REVOKE from anon+authenticated; GRANT service_role) |
| 110 | `portal_audit_hash` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 111 | `portal_audit_chain` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 112 | `portal_audit_verify` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 113 | `portal_enqueue_stage_notifications` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 114 | `portal_requests_notify` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 115 | `portal_reqdoc_guard` | trigger-only — invoked by BEFORE/AFTER trigger; not a callable API |
| 116 | `portal_create_expense_draft` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 117 | `portal_attach_document` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 118 | `portal_remove_document` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 119 | `portal_replace_document` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |
| 120 | `portal_submit_expense` | authenticated + service_role (anon/PUBLIC revoked); SECURITY DEFINER |

## Triggers (one row each)
| # | Trigger | Table |
|--|--|--|
| 1 | `trg_portal_approvals_guard` | `portal_approvals` |
| 2 | `trg_portal_req_status_guard` | `portal_requests` |
| 3 | `trg_portal_award_appr_guard` | `portal_award_approvals` |
| 4 | `trg_portal_award_guard` | `portal_award` |
| 5 | `trg_portal_payments_guard` | `portal_payments` |
| 6 | `trg_portal_users_guard` | `portal_users` |
| 7 | `trg_portal_depts_guard` | `portal_departments` |
| 8 | `trg_portal_jobs_guard` | `portal_jobs` |
| 9 | `trg_portal_doa_guard` | `portal_doa` |
| 10 | `trg_portal_wf_guard` | `portal_workflows` |
| 11 | `trg_portal_settings_guard` | `portal_settings` |
| 12 | `trg_portal_audit_immutable` | `portal_audit` |
| 13 | `trg_portal_offers_guard` | `portal_offers` |
| 14 | `trg_portal_items_guard` | `portal_request_items` |
| 15 | `trg_portal_receipts_guard` | `portal_receipts` |
| 16 | `trg_portal_po_appr_guard` | `portal_po_approvals` |
| 17 | `trg_portal_set_due` | `portal_requests` |
| 18 | `trg_portal_suppliers_guard` | `portal_suppliers` |
| 19 | `trg_portal_offer_items_lock` | `portal_offer_items` |
| 20 | `trg_portal_award_lines_lock` | `portal_award_lines` |
| 21 | `trg_portal_outbox_enqueue` | `portal_notifications` |
| 22 | `trg_portal_supplier_iban_guard` | `portal_suppliers` |
| 23 | `trg_portal_three_way_guard` | `portal_payments` |
| 24 | `trg_portal_beneficiary_iban_guard` | `portal_beneficiaries` |
| 25 | `trg_portal_audit_chain` | `portal_audit` |
| 26 | `trg_portal_requests_notify` | `portal_requests` |
| 27 | `trg_portal_reqdoc_guard` | `portal_request_documents` |

## Policies (one row each)
| # | Policy | Table | Cmd |
|--|--|--|--|
| 1 | `offer_items_read` | `portal_offer_items` | SELECT |
| 2 | `award_lines_read` | `portal_award_lines` | SELECT |
| 3 | `portal_budgets_read` | `portal_budgets` | SELECT |
| 4 | `portal_iban_chg_read` | `portal_supplier_iban_changes` | SELECT |
| 5 | `portal_invoices_read` | `portal_supplier_invoices` | SELECT |
| 6 | `portal_returns_read` | `portal_returns` | SELECT |
| 7 | `portal_currencies_read` | `portal_currencies` | SELECT |
| 8 | `portal_contracts_read` | `portal_contracts` | SELECT |
| 9 | `portal_beneficiaries_read` | `portal_beneficiaries` | SELECT |
| 10 | `portal_ben_iban_chg_read` | `portal_beneficiary_iban_changes` | SELECT |
| 11 | `portal_recurring_read` | `portal_recurring_expenses` | SELECT |
| 12 | `portal_reqdoc_read` | `portal_request_documents` | SELECT |

## Jobs & storage
| Artifact | System | Notes |
|--|--|--|
| `portal-outbox-drain` (Cron) | 3 | SLA + recurring + outbox email (SCHED-DECOUPLE, CRON-SECRET) |
| R2 `QUOTES_BUCKET` | 3 | portal evidence (DOC-RECEIPT gate) |
| Storage `supplier-docs` | 1 | registration docs (SEC-06) |
| `ai.js` (Gemini OCR proxy) | **System 1 + 2** | Used by `register.html` (Sys-1 OCR) and `index.html`/`requests.html`/`rfq.html` (Sys-2 OCR); **not** used by System 3. Keeps `GEMINI_API_KEY` server-side + model allowlist, **but abuse controls incomplete** (see G0-F4 / ledger `AI-PROXY-ABUSE`): GET has no auth/origin check; POST relies only on forgeable Origin/Referer; no JWT/Turnstile/rate-limit/quota/cost cap; 16 MiB body; size check only fires when Content-Length present (chunked bypass). **Classify: key concealed, abuse controls incomplete — NOT simply "secure".** |

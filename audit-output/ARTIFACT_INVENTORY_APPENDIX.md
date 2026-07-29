# ARTIFACT INVENTORY — MACHINE-DERIVED APPENDIX (G0-R4)

> Generated from `db/portal-standalone.sql` + `functions/api/` + repo root at head `1b97cc4`. One row per concrete artifact. Companion to `ARTIFACT_INVENTORY.md` (narrative). Ownership: all `portal_*` = System 3 unless noted.

**Totals:** 35 tables · 120 functions · 27 triggers · 12 policies · endpoints/pages enumerated below.

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
| # | Table | RLS |
|--|--|--|
| 1 | `portal_users` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 2 | `portal_departments` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 3 | `portal_jobs` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 4 | `portal_doa` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 5 | `portal_workflows` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 6 | `portal_requests` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 7 | `portal_request_items` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 8 | `portal_approvals` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 9 | `portal_offers` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 10 | `portal_award` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 11 | `portal_award_approvals` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 12 | `portal_payments` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 13 | `portal_receipts` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 14 | `portal_audit` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 15 | `portal_email_tokens` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 16 | `portal_notifications` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 17 | `portal_settings` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 18 | `portal_po_approvals` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 19 | `portal_invitations` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 20 | `portal_suppliers` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 21 | `portal_offer_items` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 22 | `portal_award_lines` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 23 | `portal_outbox` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 24 | `portal_budgets` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 25 | `portal_supplier_iban_changes` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 26 | `portal_supplier_invoices` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 27 | `portal_returns` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 28 | `portal_currencies` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 29 | `portal_contracts` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 30 | `portal_supplier_tokens` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 31 | `portal_idempotency` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 32 | `portal_beneficiaries` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 33 | `portal_beneficiary_iban_changes` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 34 | `portal_recurring_expenses` | RLS on; SELECT scoped / writes deny-by-default via guards |
| 35 | `portal_request_documents` | RLS on; SELECT scoped / writes deny-by-default via guards |

## Functions (one row each, System 3)
| # | Function | Exec grant |
|--|--|--|
| 1 | `portal_username` | authenticated (or per REVOKE/GRANT in source) |
| 2 | `portal_is_admin` | authenticated (or per REVOKE/GRANT in source) |
| 3 | `portal_is_service` | authenticated (or per REVOKE/GRANT in source) |
| 4 | `portal_is_privileged` | authenticated (or per REVOKE/GRANT in source) |
| 5 | `portal_has_perm` | authenticated (or per REVOKE/GRANT in source) |
| 6 | `portal_effective_approver` | authenticated (or per REVOKE/GRANT in source) |
| 7 | `portal_approvals_guard` | authenticated (or per REVOKE/GRANT in source) |
| 8 | `portal_request_status_guard` | authenticated (or per REVOKE/GRANT in source) |
| 9 | `portal_award_approvals_guard` | authenticated (or per REVOKE/GRANT in source) |
| 10 | `portal_award_guard` | authenticated (or per REVOKE/GRANT in source) |
| 11 | `portal_payments_guard` | authenticated (or per REVOKE/GRANT in source) |
| 12 | `portal_users_guard` | authenticated (or per REVOKE/GRANT in source) |
| 13 | `portal_config_guard` | authenticated (or per REVOKE/GRANT in source) |
| 14 | `portal_audit_immutable` | authenticated (or per REVOKE/GRANT in source) |
| 15 | `portal_locked_guard` | authenticated (or per REVOKE/GRANT in source) |
| 16 | `portal_audit_write` | service_role only (server) |
| 17 | `portal_resolve_stage` | authenticated (or per REVOKE/GRANT in source) |
| 18 | `portal_create_request` | authenticated (or per REVOKE/GRANT in source) |
| 19 | `portal_submit_request` | authenticated (or per REVOKE/GRANT in source) |
| 20 | `portal_pr_transition` | authenticated (or per REVOKE/GRANT in source) |
| 21 | `portal_submit_offer` | authenticated (or per REVOKE/GRANT in source) |
| 22 | `portal_po_approvals_guard` | authenticated (or per REVOKE/GRANT in source) |
| 23 | `portal_build_po_chain` | authenticated (or per REVOKE/GRANT in source) |
| 24 | `portal_award` | authenticated (or per REVOKE/GRANT in source) |
| 25 | `portal_award_transition` | authenticated (or per REVOKE/GRANT in source) |
| 26 | `portal_po_transition` | authenticated (or per REVOKE/GRANT in source) |
| 27 | `portal_payment_request` | authenticated (or per REVOKE/GRANT in source) |
| 28 | `portal_payment_transition` | authenticated (or per REVOKE/GRANT in source) |
| 29 | `portal_record_receipt` | authenticated (or per REVOKE/GRANT in source) |
| 30 | `portal_cancel_request` | authenticated (or per REVOKE/GRANT in source) |
| 31 | `portal_gen_token` | authenticated (or per REVOKE/GRANT in source) |
| 32 | `portal_create_token` | service_role only (server) |
| 33 | `portal_pr_transition_email` | service_role only (server) |
| 34 | `portal_resubmit_request` | authenticated (or per REVOKE/GRANT in source) |
| 35 | `portal_setting_bool` | authenticated (or per REVOKE/GRANT in source) |
| 36 | `portal_setting_num` | authenticated (or per REVOKE/GRANT in source) |
| 37 | `portal_qualified_approver` | authenticated (or per REVOKE/GRANT in source) |
| 38 | `portal_resume_hold` | authenticated (or per REVOKE/GRANT in source) |
| 39 | `portal_sla_hours` | authenticated (or per REVOKE/GRANT in source) |
| 40 | `portal_set_due` | authenticated (or per REVOKE/GRANT in source) |
| 41 | `portal_run_sla` | authenticated (or per REVOKE/GRANT in source) |
| 42 | `portal_sla_tick` | authenticated (or per REVOKE/GRANT in source) |
| 43 | `portal_my_scope` | authenticated (or per REVOKE/GRANT in source) |
| 44 | `portal_my_sector` | authenticated (or per REVOKE/GRANT in source) |
| 45 | `portal_can_see_request` | authenticated (or per REVOKE/GRANT in source) |
| 46 | `portal_email_allowed` | authenticated (or per REVOKE/GRANT in source) |
| 47 | `portal_set_committee` | authenticated (or per REVOKE/GRANT in source) |
| 48 | `portal_delete_user` | authenticated (or per REVOKE/GRANT in source) |
| 49 | `portal_apply_job` | authenticated (or per REVOKE/GRANT in source) |
| 50 | `portal_save_job` | authenticated (or per REVOKE/GRANT in source) |
| 51 | `portal_delete_job` | authenticated (or per REVOKE/GRANT in source) |
| 52 | `portal_save_department` | authenticated (or per REVOKE/GRANT in source) |
| 53 | `portal_delete_department` | authenticated (or per REVOKE/GRANT in source) |
| 54 | `portal_delete_supplier` | authenticated (or per REVOKE/GRANT in source) |
| 55 | `portal_award_split` | authenticated (or per REVOKE/GRANT in source) |
| 56 | `portal_set_installments` | authenticated (or per REVOKE/GRANT in source) |
| 57 | `portal_bounce_to_requester` | authenticated (or per REVOKE/GRANT in source) |
| 58 | `portal_outbox_enqueue` | authenticated (or per REVOKE/GRANT in source) |
| 59 | `portal_outbox_claim` | authenticated (or per REVOKE/GRANT in source) |
| 60 | `portal_outbox_mark` | service_role only (server) |
| 61 | `portal_outbox_purge` | service_role only (server) |
| 62 | `portal_budget_committed` | authenticated (or per REVOKE/GRANT in source) |
| 63 | `portal_budget_status` | authenticated (or per REVOKE/GRANT in source) |
| 64 | `portal_budget_set` | authenticated (or per REVOKE/GRANT in source) |
| 65 | `portal_budget_delete` | authenticated (or per REVOKE/GRANT in source) |
| 66 | `portal_budget_enforce` | authenticated (or per REVOKE/GRANT in source) |
| 67 | `portal_supplier_iban_guard` | authenticated (or per REVOKE/GRANT in source) |
| 68 | `portal_supplier_iban_request` | authenticated (or per REVOKE/GRANT in source) |
| 69 | `portal_supplier_iban_approve` | authenticated (or per REVOKE/GRANT in source) |
| 70 | `portal_supplier_iban_reject` | authenticated (or per REVOKE/GRANT in source) |
| 71 | `portal_award_total` | authenticated (or per REVOKE/GRANT in source) |
| 72 | `portal_invoiced_total` | authenticated (or per REVOKE/GRANT in source) |
| 73 | `portal_three_way_status` | authenticated (or per REVOKE/GRANT in source) |
| 74 | `portal_invoice_record` | authenticated (or per REVOKE/GRANT in source) |
| 75 | `portal_three_way_guard` | authenticated (or per REVOKE/GRANT in source) |
| 76 | `portal_returns_total` | authenticated (or per REVOKE/GRANT in source) |
| 77 | `portal_return_record` | authenticated (or per REVOKE/GRANT in source) |
| 78 | `portal_return_status` | authenticated (or per REVOKE/GRANT in source) |
| 79 | `portal_currency_rate` | authenticated (or per REVOKE/GRANT in source) |
| 80 | `portal_currency_set` | authenticated (or per REVOKE/GRANT in source) |
| 81 | `portal_currency_delete` | authenticated (or per REVOKE/GRANT in source) |
| 82 | `portal_set_request_currency` | authenticated (or per REVOKE/GRANT in source) |
| 83 | `portal_contract_consumed` | authenticated (or per REVOKE/GRANT in source) |
| 84 | `portal_contract_status` | authenticated (or per REVOKE/GRANT in source) |
| 85 | `portal_contract_set` | authenticated (or per REVOKE/GRANT in source) |
| 86 | `portal_contract_close` | authenticated (or per REVOKE/GRANT in source) |
| 87 | `portal_link_request_contract` | authenticated (or per REVOKE/GRANT in source) |
| 88 | `portal_contract_enforce` | authenticated (or per REVOKE/GRANT in source) |
| 89 | `portal_update_request` | authenticated (or per REVOKE/GRANT in source) |
| 90 | `portal_supplier_invite` | authenticated (or per REVOKE/GRANT in source) |
| 91 | `portal_supplier_rfq` | authenticated (or per REVOKE/GRANT in source) |
| 92 | `portal_supplier_submit` | authenticated (or per REVOKE/GRANT in source) |
| 93 | `portal_supplier_token_request` | service_role only (server) |
| 94 | `portal_build_chain` | authenticated (or per REVOKE/GRANT in source) |
| 95 | `portal_create_expense` | authenticated (or per REVOKE/GRANT in source) |
| 96 | `portal_open_direct_payment` | authenticated (or per REVOKE/GRANT in source) |
| 97 | `portal_payment_void` | authenticated (or per REVOKE/GRANT in source) |
| 98 | `portal_beneficiary_iban_guard` | authenticated (or per REVOKE/GRANT in source) |
| 99 | `portal_beneficiary_save` | authenticated (or per REVOKE/GRANT in source) |
| 100 | `portal_beneficiary_delete` | authenticated (or per REVOKE/GRANT in source) |
| 101 | `portal_beneficiary_iban_request` | authenticated (or per REVOKE/GRANT in source) |
| 102 | `portal_beneficiary_iban_approve` | authenticated (or per REVOKE/GRANT in source) |
| 103 | `portal_beneficiary_iban_reject` | authenticated (or per REVOKE/GRANT in source) |
| 104 | `portal_bulk_transition` | authenticated (or per REVOKE/GRANT in source) |
| 105 | `portal_recurring_next` | authenticated (or per REVOKE/GRANT in source) |
| 106 | `portal_recurring_save` | authenticated (or per REVOKE/GRANT in source) |
| 107 | `portal_recurring_set_active` | authenticated (or per REVOKE/GRANT in source) |
| 108 | `portal_recurring_delete` | authenticated (or per REVOKE/GRANT in source) |
| 109 | `portal_recurring_run` | service_role only (server) |
| 110 | `portal_audit_hash` | authenticated (or per REVOKE/GRANT in source) |
| 111 | `portal_audit_chain` | authenticated (or per REVOKE/GRANT in source) |
| 112 | `portal_audit_verify` | authenticated (or per REVOKE/GRANT in source) |
| 113 | `portal_enqueue_stage_notifications` | authenticated (or per REVOKE/GRANT in source) |
| 114 | `portal_requests_notify` | authenticated (or per REVOKE/GRANT in source) |
| 115 | `portal_reqdoc_guard` | authenticated (or per REVOKE/GRANT in source) |
| 116 | `portal_create_expense_draft` | authenticated (or per REVOKE/GRANT in source) |
| 117 | `portal_attach_document` | authenticated (or per REVOKE/GRANT in source) |
| 118 | `portal_remove_document` | authenticated (or per REVOKE/GRANT in source) |
| 119 | `portal_replace_document` | authenticated (or per REVOKE/GRANT in source) |
| 120 | `portal_submit_expense` | authenticated (or per REVOKE/GRANT in source) |

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
| `ai.js` (Gemini proxy) | shared | server-only `GEMINI_API_KEY`, model allowlist; NOT wired to System-1/2/3 data or governance workflow |

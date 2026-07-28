# PERMISSION MATRIX — permission keys → jobs → workflow use

Permission keys are boolean columns in a job's `perms` JSON; a user inherits its job's keys. Live coverage was checked
against the 18 active jobs (see CLAUDE.md job-coverage audit + migration 042 fixing empty `gm`/`qc`).

## Keys and what they gate
| Key | Gates | Held by (representative jobs) |
|-----|-------|------|
| `can_create` | Create a purchase request / direct expense | requesters; procurement |
| `can_edit` | Edit a returned request on behalf | procurement |
| `can_approve_stage` | Approve a `need`-cycle stage | sector managers, finance, procurement per DoA |
| `can_approve_award` | Approve the award (تعميد) | procurement manager |
| `can_approve_committee` | Committee tier of PO approval | committee members / `committee_members` list |
| `can_manage_procurement` | Manage RFQ/offers/invoices | procurement |
| `can_issue_po` | Issue purchase order | procurement |
| `can_approve_disbursement` | Approve a `disbursement`-cycle stage | fin_accountant, fin_accounts_mgr, fin_manager |
| `can_disburse` | **Execute** the payment (bank) | fin_accountant + accounts (≥2 holders required for SoD) |
| `can_see_finance` | Read financial data/reports | finance, procurement, admin |
| `can_verify_stock` | Receipt / returns / QC | warehouse, `qc` |
| `can_manage_users` | User admin + GM PO-approval identity | admin, `gm` |
| `can_manage_company` | Settings/DoA/workflow designer | admin |

## Critical invariants (test-pinned)
- **Every workflow-critical key is granted by ≥1 active job** — test `22_jobs_coverage.sql`.
- **`gm` = `can_manage_users`, `qc` = `can_verify_stock`** — no active job left with empty perms (042).
- **`can_disburse` is held by ≥2 jobs** so disbursement's approver≠executor separation is satisfiable — pinned by test 22.
- **Finance manager does NOT hold `can_disburse`** (approver-vs-executor separation) — by design (050).
- Sensitive keys (`can_manage_users`/`can_manage_company`/`can_disburse`/`can_approve_*`) cannot be self-granted via
  `portal_save_job`/`portal_apply_job` (anti-escalation allowlist, 004/019).

## DoA (approval thresholds, SAR) — award always procurement manager; PO approval grows by value
| Tier | Award | PO approval chain |
|---|---|---|
| 0–25,000 | Procurement mgr | Procurement mgr (direct issue) |
| 25,001–150,000 | Procurement mgr | + committee |
| 150,001–250,000 | Procurement mgr | + finance manager |
| 250,001–500,000 | Procurement mgr | + general manager |
| >500,000 | Procurement mgr | Formal tender — all + GM |

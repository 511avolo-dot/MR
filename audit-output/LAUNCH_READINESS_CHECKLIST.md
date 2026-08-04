# Launch-readiness checklist — System 3 (as of `ec8a1e0`, 2026-08-04)

The engineering/logic work is complete and **proven error-free live** on isolated staging
`vpfnycxzqziltsnzxbpb` (see `LIVE_STAGING_VERIFICATION_2026-08-04.md`). What remains to
close Gate 1 and launch is a short list of **owner actions** that cannot be performed from
the agent environment (secrets, dashboard toggles, external review). This is the path.

## ✅ Proven green (no action needed)
- Repo CI on every head: `portal-tests` (283 SQL + 18 file-guard + 7 endpoint assertions), `hosted-preview-smoke`, `supabase-contract`, Cloudflare Preview.
- **Full purchase lifecycle to `closed`** live: create → 3-stage approval → pricing → offers → award → award-approval → PO → payment → **disburse SoD triple** → receipt → **closed** (rolled back, staging unchanged).
- SoD negatives (self-approve, unauthorized, requester-disburse, approver-disburse) all denied.
- RLS/privacy R1–R5 + 4-role probe matrix (cross-dept hidden, p0_1n boundary, `portal_users` least-privilege, safe directory), with specific `P0001` denials.
- Security Advisor 96 entries reconciled exactly with the disposition; per-signature owner/grants attestation + 10 build-failing negative-authz tests (test 46).
- Audit hash-chain `portal_audit_verify() = ok`. Payment evidence gate (`p0_1i`) enforced.
- Migrations `p0_1b…p0_1n` applied on staging; production untouched/unreachable.

## ☐ Owner actions to close Gate 1 (only you can do these)

| # | Action | Where | Note |
|---|---|---|---|
| 1 | **Run the authenticated browser E2E** | GitHub Actions | Set repo secret `STAGING_E2E_USERS` (JSON from the PR comment, `stg.*` passwords) → Actions → `authenticated-multirole-e2e` → **Re-run**. It then executes real logins + the error-specific server probes. (The bot can't set secrets/dispatch; the browser can't egress the agent sandbox.) |
| 2 | **Enable leaked-password protection** | Supabase → Auth → Policies | Or record explicit risk acceptance. The one live-actionable advisor item. |
| 3 | **Rotate the staging `service_role` key** | Supabase → Settings → API | The key was exposed earlier in the program; rotate + confirm. |
| 4 | **Attest + purge QA residue** | Supabase (staging data) | Confirm the 20 requests / 5 offers / 4 payments are test fixtures (they are `QA-*-PR74` / `qa_*`-owned), then purge or reset staging before launch. Classification is yours to attest. |
| 5 | **Independent adversarial review** | External reviewer | Codex hit its usage limit; a fresh non-author review is the certification gate. |

## ☐ Production cutover (after Gate 1, owner-run, staged)
- Enforcement flags per policy: `budget_enforce`, `iban_change_control`, `three_way_enforce` (+tolerance), `contract_enforce`, `disb_gate_purchase`, `txn_notifications` (all default 0 — flip deliberately).
- Real organization data: committee members, GM/finance/procurement identities, jobs, departments, DoA.
- Apply the `p0_1b…p0_1n` chain to production via the guarded launcher (owner-authorized, **not** from here); never migration `063`.

**Until items 1–5 are done and independently reviewed, Gate 1 stays HELD and the verdict is
NOT READY. No production/`main`/`063` change has been made.**

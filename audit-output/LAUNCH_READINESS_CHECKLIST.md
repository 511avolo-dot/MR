# Launch-readiness checklist — System 3 (as of `ec8a1e0`, 2026-08-04)

**Scope of this document:** the listed repository and staging checks **passed for the
tested paths**. **Overall production readiness remains UNVERIFIED until all Gate-1 items
below close** (notably: no non-skipped credentialed browser E2E; negative-execution tests
cover only a selected high-risk subset of the authenticated write surface; QA/R2 residue,
key rotation, leaked-password protection, and independent review all open). Nothing here is
a completion or "error-free" claim. Evidence: `LIVE_STAGING_VERIFICATION_2026-08-04.md`.

## Passed checks — tested paths only (not a readiness claim)
- Repo CI on every head: `portal-tests` (283 SQL + 18 file-guard + 7 endpoint assertions), `hosted-preview-smoke`, `supabase-contract`, Cloudflare Preview.
- A **single** happy-path purchase lifecycle reached `closed` live (create → 3-stage approval → pricing → offers → award → award-approval → PO → payment → disburse SoD triple → receipt → closed), rolled back — one traversal, not exhaustive path coverage.
- The SoD negatives exercised (self-approve, unauthorized, requester-disburse, approver-disburse) were denied.
- RLS/privacy R1–R5 + a 4-role probe matrix passed, with specific `P0001` denials.
- Security Advisor 96 entries reconcile with the disposition; **negative-execution tests cover 10 selected high-risk write RPCs only** — the item stays **OPEN** until the remaining authenticated write surface is covered or explicitly risk-dispositioned **and** independently reviewed.
- Audit hash-chain `portal_audit_verify() = ok` for the tested chain. Payment evidence gate (`p0_1i`) enforced on the tested path.
- Migrations `p0_1b…p0_1n` applied on staging; production untouched/unreachable.

## ☐ Owner actions to close Gate 1 (only you can do these)

| # | Action | Where | Note |
|---|---|---|---|
| 1 | **Run the authenticated browser E2E** | GitHub Actions | Create **fresh, disposable, Staging-only** role identities + passwords **out-of-band** (not from any PR/issue text). Store them **only** in the `STAGING_E2E_USERS` Actions secret (matching the JSON *shape* the script documents — never paste passwords into logs/comments). Actions → `authenticated-multirole-e2e` → **Re-run**; it executes real logins + the error-specific server probes. **Disable/remove those identities after the run.** (The bot can't set secrets/dispatch; the browser can't egress the agent sandbox.) |
| 2 | **Enable leaked-password protection** | Supabase → Auth → Policies | Or record explicit risk acceptance. The one live-actionable advisor item. |
| 3 | **Rotate staging `service_role` key + `stg.*` test-account passwords** | Supabase → Settings → API + Auth | The `service_role` key was exposed earlier in the program. Separately, `stg.*` test-account passwords were transiently set to a known value during E2E attempts and then restored to their original hashes (verified) — rotate them anyway as a precaution. Record rotation as a Gate artifact. |
| 4 | **Attest + purge QA residue** | Supabase (staging data) | Confirm the 20 requests / 5 offers / 4 payments are test fixtures (they are `QA-*-PR74` / `qa_*`-owned), then purge or reset staging before launch. Classification is yours to attest. |
| 5 | **Independent adversarial review** | External reviewer | Codex hit its usage limit; a fresh non-author review is the certification gate. |

## ☐ Production cutover (after Gate 1, owner-run, staged)
- Enforcement flags per policy: `budget_enforce`, `iban_change_control`, `three_way_enforce` (+tolerance), `contract_enforce`, `disb_gate_purchase`, `txn_notifications` (all default 0 — flip deliberately).
- Real organization data: committee members, GM/finance/procurement identities, jobs, departments, DoA.
- Apply the `p0_1b…p0_1n` chain to production via the guarded launcher (owner-authorized, **not** from here); never migration `063`.

**Until items 1–5 are done and independently reviewed, Gate 1 stays HELD and the verdict is
NOT READY. No production/`main`/`063` change has been made.**

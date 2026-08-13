# UNRESOLVED ITEMS — not verifiable in this environment / owner-gated

Each item states why it is unresolved, its confidence, and who must close it.

## NOT VERIFIABLE here (environment limits) — hand to Codex / dynamic review
| ID | Item | Why unresolved | Who closes |
|----|------|----------------|-----------|
| NV-01 | Browser E2E of new converter panels (beneficiary picker, supplier-IBAN, reports, PDF voucher, recurring, bulk-approve) | No browser automation; panels are **syntax-verified only**. Highest-value place for real UI defects (rendering, event wiring, permission gating). | Codex + manual browser pass |
| NV-02 | Dynamic web pen-test (PostgREST replay as low-priv/different-department JWT) | Requires a live low-priv JWT and network probing not run here; guards verified by structure + local suite (privilege-based). | Codex / pen-test |
| NV-03 | Load / soak / chaos at scale (1M rows, provider outage) | No load infra; indexes exist (041) but no measured latency. | SRE |
| NV-04 | Email deliverability + no-double-send when `txn_notifications=1` | Needs a live Resend run and the two-step activation. | Owner + live run |
| NV-05 | Backup/PITR tier, RTO/RPO | Not expressed in repo. | Owner (Supabase) |
| NV-06 | System 2 (`index.html`/`proc_*`) full audit | Out of scope; only isolation from System 3 confirmed. | Separate engagement |

## Owner-config / decision-gated (not code)
| ID | Item | Confidence | Action |
|----|------|-----------|--------|
| SEC-02 | Leaked-password protection disabled; MFA/SSO not enforced | VERIFIED (advisor) | Supabase Dashboard → Auth |
| SEC-03 | Beneficiary IBANs readable by `can_create` | VERIFIED | Owner: adopt names-only UI + server-side IBAN, or accept |
| SEC-04 | `portal_users`/`portal_settings` authenticated-readable | VERIFIED | Owner: scope directory read if insider threat in model |
| SEC-05 | System-1 storage hardening pending apply | HIGHLY LIKELY | Owner SQL + confirm `/api/reg-doc` `{ok:true}` |
| OPS-01 | Enforcement flags dormant (`budget/iban/three_way/contract/disb_gate/txn_notifications`) | VERIFIED | Owner flips per launch plan |
| OPS-02 | Transactional-notification full activation is two-step | VERIFIED | Owner: `txn_notifications=1` + remove `pa_notify` stage calls |
| CFG-01 | Enterprise data (committee, GA/LOG managers, jobs, users) | VERIFIED (live: `committee_members=[]`, demo users) | Owner setup — required for >250K PO chains |

## Resolved this audit (for completeness)
- **SEC-01** residual anon SELECT grants — **FIXED & live-verified** (migration 059, test 35). See `REMEDIATION_REGISTER.md`.

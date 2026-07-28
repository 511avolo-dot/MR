# Enterprise Certification Audit — System 3 (Procurement & Disbursement Portal)

Branch `audit/enterprise-certification-2026-07-27` (base `main` @ `b9d9d6d`). Evidence-based audit; no `main` changes,
no PR merge. One code remediation this audit: migration `059` (SEC-01, applied live + test 35).

## Read in this order
1. **FINAL_CERTIFICATION.md** — verdict (`NOT READY`, revised 2026-07-28 after Codex), category scores, must-fix list, sign-off.
2. **EXECUTIVE_REPORT.md** — plain-language summary for the owner.
3. **FINDINGS.md** — every finding, severity, confidence, evidence (0 BLOCKER/CRITICAL/HIGH; 3 MEDIUM / 4 LOW / 4 INFO).
4. **TECHNICAL_REPORT.md** — architecture + control-by-control evidence.
5. **PRODUCTION_BLOCKERS.md** — no code blockers; owner conditions before real go-live.
6. **REMEDIATION_REGISTER.md** — SEC-01 fix detail + items intentionally not auto-fixed.
7. **UNRESOLVED_ITEMS.md** — not-verifiable-here + owner-gated items.
8. **CODEX_HANDOFF.md** — independent second-review package + attack plan.
9. **EXECUTION_LOG.md** — chronology + commands (reproducible).

## Matrices
- **PERMISSION_MATRIX.md** — keys → jobs → workflow use + DoA thresholds.
- **SEGREGATION_OF_DUTIES_MATRIX.md** — duty pairs, rules, tests.
- **API_SECURITY_MATRIX.md** — every endpoint, auth, controls.
- **BUSINESS_SCENARIO_MATRIX.md** — end-to-end scenarios ↔ tests/evidence.

## Verdict at a glance (revised 2026-07-28 after independent Codex review)
| | |
|---|---|
| Status | **NOT READY** (2 HIGH code defects verified) |
| BLOCKER/CRITICAL/HIGH | **0 / 0 / 2** (AUTHZ-01 cross-dept expense; SEC-06 unauth reg-doc) |
| Fixed this audit | SEC-01 (059, live-verified) + audit-accuracy defects (assertion count; vacuous AH1 test) |
| Automated suite | **EXIT 0** — 195 assertions (172 SQL + 18 file-guard + 5 endpoint) |
| Live migrations | `022→059` applied & verified on `mwbjoysuybgbrvfrprex` |
| Must-fix (code) | AUTHZ-01, SEC-06, + MEDIUM: SEC-07 admin-SoD, SEC-03 beneficiary IBAN, GOV-01 recurring budget |
| Remaining gates | owner config (SEC-02/05, data setup, flag flips, DR) + browser E2E (Codex review done) |

## Reproduce
```bash
PGHOST=/home/postgres/pt PGPORT=5455 PGUSER=postgres bash db/portal-tests/run.sh   # EXIT 0
node db/portal-tests/file-guard.test.mjs
for f in functions/api/*.js; do node --check "$f"; done
```

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

## Verdict at a glance (rev 2 — 2026-07-28, after Codex review + owner-directed remediation)
| | |
|---|---|
| Status | **READY WITH CONDITIONS** (System-3 code 0 open HIGH; **System-1 registration has 1 open HIGH — SEC-06**) |
| BLOCKER/CRITICAL/HIGH | **0 / 0 / 1** open — SEC-06 (System-1 registration anon-upload fallback); AUTHZ-01 & GOV-01 fixed+live |
| Fixed this audit | SEC-01 (059) · AUTHZ-01 (060) · GOV-01 (060) · SEC-06 destructive+allowlist (reg-doc.js) · accuracy defects |
| Owner-accepted | SEC-07 (admin superuser) · SEC-03 (manual IBAN retained) |
| Automated suite | **EXIT 0** — 203 assertions (178 SQL + 18 file-guard + 7 endpoint) |
| Live migrations | `022→060` applied & verified on `mwbjoysuybgbrvfrprex` (060 applied 2026-07-28) |
| Conditions | apply 060 live · SEC-06-R credential upgrade · SEC-02/05 · data setup · flags · DR · browser E2E |

## Reproduce
```bash
PGHOST=/home/postgres/pt PGPORT=5455 PGUSER=postgres bash db/portal-tests/run.sh   # EXIT 0
node db/portal-tests/file-guard.test.mjs
for f in functions/api/*.js; do node --check "$f"; done
```

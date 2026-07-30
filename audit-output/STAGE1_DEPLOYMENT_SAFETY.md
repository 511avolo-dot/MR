# STAGE 1 — Isolated staging & deployment-safety foundation (repo-only)

**Authorization:** owner cleared Gate 0 at SHA `9a62890` and authorized Stage 1 repo-only (2026-07-30). **Gate 1 remains HELD.**
**Scope discipline:** repo files only. **No** migration 062/063 apply, **no** production/Storage/Cloudflare/Supabase/Resend
change. PR stays Draft.

## Section 1 — Repo-side Gate 1 (F5) — PASS/FAIL with commands + machine results
> This branch proves **repo-side** logic + real local execution. External isolated-staging execution is **Section 2 (NOT RUN)**.

| Item | Command | Result |
|---|---|---|
| F1 · staging baseline lineage — **two-phase** (G1-FINAL-01) | `bash db/staging-bootstrap/verify-baseline.sh` | **PASS** (local PG16 + CI): **Phase A** empty DB → baseline(061) → suite on 061 = **27 pass** (+2 deferred: `37`=062 feature, `11_security`=post-062 server-surface); incremental 062 apply ✓; **Phase B** baseline+062 → **29/29** pass. Separate phases/counts; both exit 0 |
| F1 · baseline determinism (drift guard) | `node scripts/deploy/build-baseline.mjs --check` | **PASS** — sha256 `e690edfe…` reproducible from `portal-standalone.sql` |
| F1 · launcher two-mode + mode-confusion + checksum drift | `node scripts/stage1-tests.mjs` | **PASS — 57 assertions** (bootstrap/apply-062 dry-run, no-`--mode` fails closed, prod-ref rejected, pinned baseline+062 sha == files) |
| F2/F3 · real browser E2E + **exact-host boundary** (G1-FINAL-02) | `node scripts/e2e/browser-fixture.test.mjs` | **PASS — 6 assertions** (real Chromium, CI): `#pa-*` login → `#pa-login` hidden + `.topbar`/`.wrap` visible; **prod HTTP blocked · other-ref HTTP blocked · staging HTTP allowed · prod WSS blocked · other-ref WSS blocked · staging WSS allowed · `swRegistrations=0`**; no LEAK/DENIED; invalid creds fail closed |
| F4 · one authoritative command path | `node scripts/stage1-tests.mjs` (env-guard group) | **PASS** — `env-guard browser-e2e` → `scripts/e2e/browser-run.mjs`; `run.mjs` delegates to it; docs/adapter/tests name the same runner |
| CLI contract (pinned, real) | dedicated CI job `supabase-contract` | **PASS** — installs exact `2.110.0`, asserts installed==pin, verifies `--help` |
| portal SQL suite (full schema) | `bash db/portal-tests/run.sh` | **PASS** |
| upload file-guard | `node db/portal-tests/file-guard.test.mjs` | **PASS — 18** |

**Read-only Preview (per-head, Claude-observed).** Invariant every head: `GET …/api/portal-config` → **HTTP 503, `env:preview`, fails closed, never the production ref**. Recorded per commit in the PR thread; the current-head result is posted on push. (No current-head Preview proof is implied from an older deploy — G1-R6-05.)

## Section 2 — External isolated-staging proof (F5) — NOT RUN until explicit owner authorization
The following require an **owner-authorized, isolated Supabase staging project + bindings**; none are run or claimed closed:
- **Live `supabase db push`** — `--mode bootstrap` (apply baseline) then `--mode apply-062` (assert exactly 062 pending, apply) against isolated staging. **NOT RUN.**
- **Full read-only `schema_migrations` export** mapping real live versions for 001–056. **NOT RUN** (057/058/059/060/061 recorded as documentary only in `db/staging-bootstrap/verified-live-versions.md`).
- **Real browser E2E** against the live staging URL with staging-only users (the fixture proves the runner + boundary; the live workflow is external). **NOT RUN.**
- **Cross-environment isolation proof** (staging never reaches production Supabase/R2/email). **NOT RUN.**

**Constraints (binding):** PR Draft/unmerged · no migration 062/063 apply · no `migration repair`/manual history INSERT · no Supabase/Cloudflare/R2/production/email/budget mutation · `budget_enforce=0` · `txn_notifications=0` · Systems 1/2 unchanged.


## Appendix — remediation history (rounds R1–R6; context, not the Section-1/2 evidence taxonomy)

> **R7 superseded by the FINAL Gate-1 convergence contract (F1–F6, owner 2026-07-30).** The consolidated
> remediation is evidenced in **Section 1** (repo-side PASS/FAIL) and **Section 2** (external NOT RUN):
> **F1** honest staging baseline lineage (invented full-history manifest removed; `verify-baseline.sh` PASS on
> local PG16) · **F2** real System-3 login selectors + pinned Playwright · **F3** Service-Worker-blocked +
> WebSocket boundary + 6 probes · **F4** single runner `browser-run.mjs` · **F5** two-section evidence taxonomy.
> Earlier round tables below are historical context.
### Gate-1 review findings (owner recheck of `a9b7b21`, then `5bea893`) → corrections
Two review rounds. Round 1 (G1-01…G1-05); the deeper round 2 (G1-R2-01…G1-R2-06) superseded the round-1 approaches where
they were still bypassable. Current state below. **Gate 1 remains HELD.**

| ID | Finding | Fix + proof |
|---|---|---|
| **G1-R2-01** (P0) | Token-heuristic `--exec` was bypassable (`sh -c '… --project-ref <prod>'`, `db.<ref>.supabase.co`, pooler URL, nested script text); `migrate`/`e2e` without `--exec` still exited 0 | **No arbitrary passthrough.** Named **adapters** (`supabase-db-push` / `psql-migration` / `browser-e2e`) construct the target argument internally from the validated ref. `migrate`/`e2e` **require** `--command`; `--purpose check` is validation-only (authorizes nothing); `--exec`, unknown commands, and unknown flags are rejected. Negatives: `--exec`+`sh -c` rejected · `--project-ref <prod>` rejected (unknown flag) · `--db-url postgresql://…@db.<prod>…` rejected · adapter/purpose mismatch rejected · `--dry-run` proves the constructed command uses the validated ref, never prod, with the DB password redacted. |
| **G1-R2-02** (P1) | Deployment identity self-asserted: configurable `PORTAL_PROD_BRANCH`, and branch-absent `PORTAL_ENV=production`+`PORTAL_ENV_IDENTITY` (which only repeated the DB ref) | Trusted production branch is a **code invariant** (`main`), not env-overridable. Public endpoint **fails closed when `CF_PAGES_BRANCH` is absent**. Production requires `branch===main` **and** `parsed.ref===PROD_REF`; preview requires `branch!==main` **and** `parsed.ref!==PROD_REF`. `PORTAL_ENV`/`PORTAL_ENV_IDENTITY` removed from the public endpoint. Negatives: `PORTAL_PROD_BRANCH=<preview>` ignored; branch-absent ⇒ 503; main+non-prod ⇒ 409; preview+prod ⇒ 409. |
| **G1-R2-03** (P1) | No-ref JWT (`role:anon`, no `ref`) accepted as bound, bypassing `PORTAL_SUPABASE_EXPECTED_REF` | A JWT anon key **with no `ref` is treated as unbound** (like opaque `sb_publishable_*`) and requires `PORTAL_SUPABASE_EXPECTED_REF === parsed ref`. Stable claims validated where present (`iss==='supabase'`, `exp` not past). Negatives: no-ref JWT without/with-mismatched expected-ref ⇒ 500; expired JWT ⇒ 500; ref-mismatch ⇒ 500. |
| **G1-R2-04** (P2) | Clickable fallback ran in `<head>` before `<a>` existed, so the link kept the base URL without query/hash | Redirect script moved to **end of `<body>`** (after `<a id="go">`); sets the anchor href to `base + location.search + location.hash` then `location.replace`. Tested by **executing the stub script against a fake DOM** and asserting `a.href` contains `?t=…` and `#hash`. |
| **G1-R2-05** (P1) | "Zero live effect / no Cloudflare deployment" was inaccurate | Corrected above: no production/config change, **but** a public Cloudflare **Preview** exists; read-only `/api/portal-config` check recorded (503 fail-closed, never the production ref). |
| **G1-R2-06** (P2) | Stale Stage-1 docs (E2E without coupling; `github_pages_exclude.pages` vs `derived_pages`; "17 assertions") | `STAGING_SETUP_PLAN.md` updated to the adapter model + coupled E2E + `derived_pages`; this doc updated to 44 assertions and the current mechanisms. |
| **G1-05 / STAGING-PROVISION** | Isolated staging not provisioned | **Owner external action + separate authorization still required** — no staging Supabase project/R2/users/bindings provisioned or verified. Gate 1 cannot be represented as fully passed until that provisioning + cross-environment isolation proof + browser E2E occur. |

## Gate-1 round-3 findings (owner recheck of `bb89277`) → corrections
| ID | Finding | Fix + proof |
|---|---|---|
| **G1-R3-01** (P0) | `supabase db push --project-ref` is not a valid CLI contract (that flag is on `supabase link`); adapter was string-tested only, and inheriting an existing link reintroduces target ambiguity | New fixed launcher `scripts/deploy/supabase-push.mjs`: **isolated workdir (no inherited repo link)** → `supabase link --project-ref <validated ref>` (password via `SUPABASE_DB_PASSWORD` env) → **verify the linked ref == validated ref** (fail-closed on mismatch — a prod-linked repo cannot cause a staging command to target prod) → `supabase db push --linked`. Real CLI-contract check `scripts/deploy/verify-supabase-contract.mjs` parses actual `--help` (asserts `db push --linked` without `--project-ref`; `link --project-ref`) and **skips honestly if the pinned CLI is absent** — no false claim. Negatives: launcher rejects `GUARDED_REF=prod` and missing password; `--dry-run` shows the isolated plan. |
| **G1-R3-02** (P0) | `browser-e2e` accepted arbitrary JS and only injected an env var (spec could ignore it and hit prod); path regex allowed `../` | One **fixed launcher** `scripts/e2e/run.mjs` (no `--spec`). It installs a **network allowlist** (`scripts/e2e/net-allow.mjs`) that **blocks every Supabase host except the validated ref, and always production**, before any action; when `E2E_BASE_URL` is set it asserts `/api/portal-config` reports the validated ref first. Negative: a **malicious scenario** calling production directly is **blocked before any request is sent** (proven by installing the allowlist over a recording `fetch` and asserting zero calls). |
| **G1-R3-03** (P1) | psql adapter put the DB password (unescaped) in `argv` | Password now via **`PGPASSWORD` env**, never argv; host/port/user/db passed separately (host built only from the validated ref); `sslmode=require`. Negative: a password with `@:/#% ` and spaces works and appears in **neither argv nor stdout**. |
| **G1-R3-04** (P2) | anon-key check presented as validity, but it is structural (no signature verification) | Re-labeled in `portal-config.js` and docs as **structural configuration validation** (shape/claims/consistency), not authenticity. Added an **opt-in readiness probe** `scripts/deploy/probe-anon.mjs` that calls a non-data Supabase endpoint with the public key and verifies the project response **without logging the key**; not wired into the request path. Runtime stays fail-closed. |
| **G1-R3-05** (P2) | Stale docs (unsupported push command; "runs the given spec"; "no live deployment") | `STAGING_SETUP_PLAN.md` corrected to the link+verify+push flow, PGPASSWORD, the fixed E2E launcher + network denial, and the Preview reality (Claude-observed read-only). |
| **G1-R3-06** | Operational staging prerequisite still open | Unchanged — **owner-authorized external provisioning + isolation proof + browser E2E** still required; not silently waived. |

> **Status correction (G1-R4):** G1-R3-01 and G1-R3-02 are **NOT** "closed/verified." Their **design + local logic** is in
> place, but real CLI migration apply and real browser E2E are **not run** (see the evidence-types table). They are
> **partial — gated on staging + tooling**.

## Gate-1 round-4 findings (owner recheck of `2c2a552`) → corrections
| ID | Finding | Fix + honest state |
|---|---|---|
| **G1-R4-01** (P0) | `supabase-push` created an **empty** workdir → no migration payload to push; 062 never referenced | Launcher now builds a deterministic isolated workdir with a **SHA-256-verified copy of 062** under `supabase/migrations/<ts>_062_*.sql` (pinned `7b56d64…`; drift aborts before any connection), and the live path runs `supabase init` → `link --project-ref` → **verify linked ref** → **`db push --dry-run --linked` (assert 062 discovered, nothing else pending)** → `db push --linked`. **Tested locally:** payload build + pinned-SHA match + 062-drift guard (SHA in launcher == file). **NOT run:** live `db push` (needs CLI + staging). |
| **G1-R4-02** (P0) | raw `psql` adapter non-atomic + bypassed `supabase_migrations` history | **Raw-psql apply path removed.** One authoritative executor = Supabase CLI (registers history via `db push`). Test asserts `psql-migration` is now an unknown command. |
| **G1-R4-03** (P0) | `net-allow` only wraps Node `globalThis.fetch`; no browser runs | Relabeled honestly as a **Node-harness fetch guard, NOT a browser boundary**. Added the real Playwright context-route runner `scripts/e2e/browser-run.mjs` (installs allow/deny at `context.route` before any page; blocks every Supabase host ≠ validated ref and always prod) that **fails closed** without the `playwright` package + `E2E_BASE_URL`. **Browser E2E is NOT implemented/run here** (no package, no staging) — result **open**. |
| **G1-R4-04** (P1) | CI "contract verification" was green because it **skipped**; CLI not installed/pinned | New dedicated CI job **`supabase-contract`** installs the CLI via `supabase/setup-cli` (version from repo var `SUPABASE_CLI_VERSION`) and runs the verifier with `REQUIRE_SUPABASE_CLI=1` → **fails if the CLI is absent/mismatched**. The main-job step now prints **SKIPPED** and is explicitly **not** Gate evidence. |
| **G1-R4-05** (P2) | Evidence/ledger overstated closure | This doc rewritten with the **evidence-types table** (pass/skip/not-run), exact-head timestamped Preview check, and the G1-R3-01/02 downgrade. |
| **G1-R4-06** | Staging still not provisioned | Unchanged — owner external action; real CLI migration + browser E2E stay gated on it. |

## Gate-1 round-5 findings (owner recheck of `2c2a552`) → corrections
| ID | Finding | Fix |
|---|---|---|
| **G1-R5-01** (P1) | CLI installed a moving `latest`, not pinned | CI job pins **exact `2.110.0`** + asserts installed==pin (run 93 log: `installed=2.110.0 pin=2.110.0`). |
| **G1-R5-02** (P0) | dry-run only checked `stdout.includes('062')` | `mig-parse.mjs` parses the pending set deterministically; asserts **exactly `{062}`**; unit-tested negatives (062+extra/empty/other). |
| **G1-R5-03** (P1) | browser runner didn't verify config identity | `browser-run.mjs` parses `/api/portal-config`, fails closed unless `ok/env≠prod/ref==GUARDED_REF`. |
| **G1-R5-04** (P2) | ledger Stage-0 contradiction | ledger corrected to "Gate 0 PASSED (`9a62890`)"; Stage 1 stays HELD. |

## Gate-1 round-6 findings (owner recheck of `e3f50d7`) → corrections
| ID | Finding | Fix |
|---|---|---|
| **G1-R6-01** (P0) | single-062 workdir is not a valid history (would mismatch `schema_migrations`) | **`db/portal-migrations/manifest.json`** — canonical full-history map (62 migrations, semantic→version + SHA-256). Launcher builds the **complete** local history bundle, verifies every checksum; staging is **bootstrapped from the manifest through 061** so local+remote align and only `{062}` is pending. Deterministic generator `build-migration-manifest.mjs` (+`--check` in CI). No `migration repair`, no SQL apply, no staging/prod mutation. |
| **G1-R6-02** (P0) | 062 version `20260728000000` predated live 059/060/061 | 062 reassigned to **`20260730120000`**, strictly after the verified live 061 `20260729073619`; 059/060/061 pinned to real live versions; monotonic+unique asserted in the manifest test. |
| **G1-R6-03** (P0) | `browser-e2e` adapter ran `run.mjs`, which never reached the Playwright runner | Adapter now invokes **`browser-run.mjs`** directly; `run.mjs` **delegates** to it unconditionally after validation. Test proves the adapter reaches the browser runner and it fails closed without Playwright/staging. |
| **G1-R6-04** (P0) | browser runner was a config probe, not an E2E scenario | Added a real smoke journey: open System-3 page → **in-page production fetch must be aborted at BrowserContext level** → staging login → protected state → re-assert staging ref. Fails closed without `playwright`+`E2E_BASE_URL`+`STAGING_TEST_*`. Execution stays gated (G1-R6-06). |
| **G1-R6-05** (P1) | exact-head Preview evidence was stale | Preview block rewritten: invariant re-verified **per head**, recorded in the PR thread for that head; no current-head proof implied from an older deploy. |
| **G1-R6-06** | staging/E2E/db-push still external | Unchanged — owner-gated; real `db push --dry-run`, isolated staging, and browser E2E remain not run. |

## Changed / new files
- **new (F1–F5)** `db/staging-bootstrap/{baseline_through_061.sql, verify-baseline.sh, verified-live-versions.md, README.md}` · `scripts/deploy/build-baseline.mjs` · `scripts/e2e/browser-fixture.test.mjs` · `package.json` + `package-lock.json` (Playwright pinned). **removed** `db/portal-migrations/manifest.json` + `scripts/deploy/build-migration-manifest.mjs` (invented history, G1-R7-02).
- **new** `deploy/system3-manifest.json` · `scripts/pages-exclude.mjs` · `scripts/stage1-tests.mjs` · `scripts/deploy/supabase-push.mjs` (full-history bundle, G1-R6-01) · **`scripts/deploy/build-migration-manifest.mjs`** + **`db/portal-migrations/manifest.json`** (canonical history, G1-R6-01/02) · **`scripts/deploy/mig-parse.mjs`** (exactly-062, G1-R5-02) · `scripts/deploy/verify-supabase-contract.mjs` (REQUIRE+pin, G1-R4-04/R5-01) · `scripts/deploy/probe-anon.mjs` · `scripts/e2e/net-allow.mjs` (Node-harness) + **`scripts/e2e/browser-run.mjs`** (real Playwright runner + smoke journey, G1-R4-03/R5-03/R6-04) · `audit-output/STAGE1_DEPLOYMENT_SAFETY.md`.
- **edit** `scripts/env-guard.mjs` (**psql adapter removed** G1-R4-02; `browser-e2e`→`browser-run.mjs` G1-R6-03) · `scripts/e2e/run.mjs` (**delegates to browser-run** G1-R6-03) · `functions/api/portal-config.js` · `supplier-quote.html` · `.github/workflows/pages.yml` · **`.github/workflows/portal-tests.yml`** (`supabase-contract` pinned job + manifest `--check`) · `audit-output/STAGING_SETUP_PLAN.md` · `audit-output/MASTER_DELIVERY_LEDGER.md`.

## Tests / negative controls (`node scripts/stage1-tests.mjs` — 44/44, exit 0)
- **env-guard (14):** prod ref rejected · missing `STAGING` confirm rejected · `migrate`/`e2e` without `--command` rejected · `--exec` (`sh -c`) rejected · unknown command rejected · `--project-ref` smuggle rejected · `--db-url` direct (unknown flag) rejected · adapter/purpose mismatch rejected · `--purpose check` runs no command · `supabase-db-push` dry-run calls the launcher with the validated ref · `browser-e2e` runs the fixed launcher and **rejects `--spec`** · **(G1-R4-02)** `psql-migration` is now an unknown command (removed).
- **launchers + net-allow (9):** `supabase-push` dry-run **builds the SHA-verified 062 payload** + isolated `link→verify→push --linked` plan (never prod) · rejects `GUARDED_REF=prod` · **(G1-R4-01)** pinned-SHA in launcher == 062 file (drift guard) · live path rejects missing password · live path **fails closed without the CLI** (no false success) · `e2e-run` installs the Node-fetch guard and **declares "not a browser boundary"** · rejects a prod target · `net-allow` host allowlist · **(G1-R3-02)** a malicious direct Node call to production is **blocked before any request** (zero calls).
- **pages-exclude (5):** set-equality `--check` on the real tree · **actual-DOM** test proving the stub link preserves `?t=…`+hash · omitted `needs_functions` page detected · stale excluded entry detected · path-traversal name rejected.
- **portal-config (16):** branch-absent ⇒ 503 · `PORTAL_PROD_BRANCH=<preview>` ignored ⇒ 409 · main+non-prod ⇒ 409 · preview+prod ⇒ 409 · service_role ⇒ 500 · user@host ⇒ 503 · missing bucket ⇒ 503 · no-ref JWT unbound (no/mismatched expected-ref ⇒ 500; matching ⇒ ok) · JWT ref mismatch ⇒ 500 · expired JWT ⇒ 500 · opaque publishable (no expected ⇒ 500; matching ⇒ ok) · preview+staging bound ⇒ ok · production+prod bound ⇒ ok.

## Explicit no-production-change confirmation
No migration applied to any project (production `list_migrations` still ends at `061`). No Supabase/Cloudflare/R2-Storage/Resend
configuration changed. No secret printed or committed (DB password redacted in guard dry-run; anon key is public by design; service
key never returned). Repo files take effect on a future owner-approved merge to `main`; the existing public Cloudflare Preview
fails closed (verified read-only above). **Gate 1** (independent review of this evidence + owner-authorized staging provisioning) is
**not** self-claimed.

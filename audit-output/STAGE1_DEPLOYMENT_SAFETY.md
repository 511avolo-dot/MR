# STAGE 1 — Isolated staging & deployment-safety foundation (repo-only)

**Authorization:** owner cleared Gate 0 at SHA `9a62890` and authorized Stage 1 repo-only (2026-07-30). **Gate 1 remains HELD.**
**Scope discipline:** repo files only. **No** migration 062/063 apply, **no** production/Storage/Cloudflare/Supabase/Resend
change. PR stays Draft.

## Deployment reality (G1-R2-05 — accurate)
- The GitHub Actions deploy workflows (`pages.yml`, `deploy.yml`) run **only on push to `main`**, so they do not run on this branch.
- **However, Cloudflare's GitHub integration independently builds a public PR Preview** for each commit. So "no production
  deployment or config mutation" is true, but "a public Cloudflare Preview deployment occurred" is **also** true — stated plainly here.
- **Read-only Preview verification (no secrets):** `GET https://audit-enterprise-certificati.aldeyabi-procurement.pages.dev/api/portal-config`
  → **HTTP 503**, body `{ ok:false, env:"preview", checks:{ url:false, anonKey:false, serviceRole:false, bucket:true } }`.
  The Preview scope has **no** Supabase URL/anon configured, so the endpoint **fails closed** and **never returns the
  production ref**. (Re-verify on each new head; the invariant to hold is: Preview resolves to a non-production staging ref or fails closed.)

## Owner Stage-1 checklist → status
| # | Authorized item | Status | Evidence |
|---|---|---|---|
| 1 | Isolated staging design | ✅ documented | `STAGING_SETUP_PLAN.md` + `deploy/system3-manifest.json` `isolation` block |
| 2 | Fail-closed Preview/production detection (malformed URL/key/branch) | ✅ implemented + tested | `portal-config.js` — branch is a code invariant (`main`), canonical URL parse, key↔project binding; `stage1-tests.mjs` portal-config group (16) |
| 3 | Command-coupled environment guard | ✅ implemented + tested | `env-guard.mjs` — named adapters build the target internally; `migrate`/`e2e` require `--command`; env-guard group (15) |
| 4 | System-3 deployment manifest + route/file ownership | ✅ implemented | `deploy/system3-manifest.json` (per-page `needs_functions`) |
| 5 | Remove GitHub Pages ambiguity | ✅ implemented + tested | `pages-exclude.mjs` set-equality + query/hash-preserving stub in `pages.yml`; pages-exclude group (5) |
| 6 | `supplier-quote.html` → env-aware config | ✅ implemented | fetches `/api/portal-config`; hardcoded prod project removed |
| 7 | anon-key role/project + server-binding validation, no secret exposure | ✅ implemented + tested | **Structural** config validation (`keyKind`: rejects service_role/`sb_secret_`, expiry/issuer where present, project binding) — not signature/authenticity; opt-in live readiness = `scripts/deploy/probe-anon.mjs`; service key never returned |
| 8 | Automated tests + negative controls | ✅ implemented | `scripts/stage1-tests.mjs` (**44 assertions, exit 0**) wired into `portal-tests.yml` |

## Gate-1 review findings (owner recheck of `a9b7b21`, then `5bea893`) → corrections
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

## Changed / new files
- **new** `deploy/system3-manifest.json` (per-page `needs_functions`) · `scripts/pages-exclude.mjs` · `scripts/stage1-tests.mjs` · `scripts/deploy/supabase-push.mjs` (G1-R3-01) · `scripts/deploy/verify-supabase-contract.mjs` (G1-R3-01) · `scripts/deploy/probe-anon.mjs` (G1-R3-04) · `scripts/e2e/run.mjs` + `scripts/e2e/net-allow.mjs` (G1-R3-02) · `audit-output/STAGE1_DEPLOYMENT_SAFETY.md`.
- **edit** `scripts/env-guard.mjs` (adapters → fixed launchers; PGPASSWORD) · `functions/api/portal-config.js` (code-invariant env + key binding + structural-validation wording) · `supplier-quote.html` (env-aware) · `.github/workflows/pages.yml` · `.github/workflows/portal-tests.yml` · `audit-output/STAGING_SETUP_PLAN.md` · `audit-output/MASTER_DELIVERY_LEDGER.md`.

## Tests / negative controls (`node scripts/stage1-tests.mjs` — 44/44, exit 0)
- **env-guard (16):** prod ref rejected · missing `STAGING` confirm rejected · `migrate`/`e2e` without `--command` rejected · `--exec` (`sh -c`) rejected · unknown command rejected · `--project-ref` smuggle rejected · `--db-url` direct rejected · adapter/purpose mismatch rejected · `--purpose check` runs no command · `supabase-db-push` dry-run calls the launcher with the validated ref · **(G1-R3-03)** `psql-migration` builds host from the validated ref with the password via env (special chars; absent from argv+stdout) · `browser-e2e` runs the fixed launcher and **rejects `--spec`** · `psql-migration` without/with-traversal `--file` rejected.
- **launchers + net-allow (7):** `supabase-push` dry-run shows the isolated `link → verify==ref → db push --linked` plan (never prod) · rejects `GUARDED_REF=prod` · rejects missing `SUPABASE_DB_PASSWORD` · `e2e-run` installs the network guard for the target · rejects a prod target · `net-allow` host allowlist (prod & other refs blocked, target & non-Supabase allowed) · **(G1-R3-02)** a malicious direct call to production is **blocked before any request** (zero calls reach the recording `fetch`).
- **pages-exclude (5):** set-equality `--check` on the real tree · **actual-DOM** test proving the stub link preserves `?t=…`+hash · omitted `needs_functions` page detected · stale excluded entry detected · path-traversal name rejected.
- **portal-config (16):** branch-absent ⇒ 503 · `PORTAL_PROD_BRANCH=<preview>` ignored ⇒ 409 · main+non-prod ⇒ 409 · preview+prod ⇒ 409 · service_role ⇒ 500 · user@host ⇒ 503 · missing bucket ⇒ 503 · no-ref JWT unbound (no/mismatched expected-ref ⇒ 500; matching ⇒ ok) · JWT ref mismatch ⇒ 500 · expired JWT ⇒ 500 · opaque publishable (no expected ⇒ 500; matching ⇒ ok) · preview+staging bound ⇒ ok · production+prod bound ⇒ ok.

## Explicit no-production-change confirmation
No migration applied to any project (production `list_migrations` still ends at `061`). No Supabase/Cloudflare/R2-Storage/Resend
configuration changed. No secret printed or committed (DB password redacted in guard dry-run; anon key is public by design; service
key never returned). Repo files take effect on a future owner-approved merge to `main`; the existing public Cloudflare Preview
fails closed (verified read-only above). **Gate 1** (independent review of this evidence + owner-authorized staging provisioning) is
**not** self-claimed.

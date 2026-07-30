# STAGE 1 — Isolated staging & deployment-safety foundation (repo-only)

**Authorization:** owner cleared Gate 0 at SHA `9a62890` and authorized Stage 1 repo-only (2026-07-30).
**Scope discipline:** repo files only. **No** migration 062/063 apply, **no** production/Storage/Cloudflare/Supabase/Resend
change. PR stays Draft. The two deploy workflows (`pages.yml`, `deploy.yml`) run **only on push to `main`** — they do not
run on this branch, so nothing here changes any live deployment until the owner merges.

## Owner Stage-1 checklist → status

| # | Authorized item | Status | Evidence |
|---|---|---|---|
| 1 | Isolated staging design (separate Supabase project, R2 bucket/bindings, test users/data, non-production recipients) | ✅ documented | `STAGING_SETUP_PLAN.md` (owner-action checklist) + `deploy/system3-manifest.json` `isolation` block |
| 2 | Fail-closed Preview/production detection incl. malformed URL/key/branch | ✅ implemented + tested | `functions/api/portal-config.js` (positive env detection, canonical URL parse, `409` preview→prod, `503` unknown-env/binding) + `stage1-tests.mjs` (6 assertions) |
| 3 | Command-coupled environment guard (validated target = target actually used) | ✅ implemented + tested | `scripts/env-guard.mjs` `--exec` mode injects `GUARDED_REF`; refuses to spawn on rejected target + missing command |
| 4 | System-3 deployment manifest + explicit route/file ownership | ✅ implemented | `deploy/system3-manifest.json` (systems 1/2/3 pages ↔ required Functions; prod ref as deny target) |
| 5 | Remove GitHub Pages ambiguity for Function-dependent pages | ✅ implemented + tested | `scripts/pages-exclude.mjs` + `pages.yml` step (redirect-stub before upload) + `stage1-tests.mjs` (4 assertions) |
| 6 | Move every System-3 frontend (incl. `supplier-quote.html`) to env-aware config | ✅ implemented | `supplier-quote.html` now fetches `/api/portal-config`; hardcoded prod project removed (`purchase-portal.html` already done) |
| 7 | Validate public anon/publishable key role/project + server-binding readiness without exposing secrets | ✅ implemented + tested | `portal-config.js` `isAnonKey` (rejects `service_role`/`sb_secret_`), ref check, boolean-only binding checks; service key never returned |
| 8 | Automated tests + negative controls for all above | ✅ implemented | `scripts/stage1-tests.mjs` (**28 assertions, exit 0**, incl. G1-01…G1-04 negatives) wired into `portal-tests.yml` |

## Gate-1 review findings (owner recheck of `a9b7b21`) → corrections
All four code defects fixed with negative controls; the operational prerequisite is recorded honestly. **Gate 1 remains HELD.**

| ID | Finding | Fix + proof |
|---|---|---|
| **G1-01** (P0) | `--exec` only injected env vars; a child command with an explicit `--project-ref <prod>` still targeted production | `env-guard.mjs` now **replaces `{GUARDED_REF}`** with the validated ref and **rejects any explicit target arg** (`--project-ref`/`--url`/`--db-url`/bare ref/supabase URL) that ≠ validated ref, **before spawning**. Negatives: explicit prod ref → rejected + command **not** spawned (marker-file proof); explicit prod URL → rejected; sentinel substitution runs with the correct target; matching staging target allowed. |
| **G1-02** (P1) | `PORTAL_ENV` overrode `CF_PAGES_BRANCH`, letting a preview claim production and skip the preview→prod guard; key project not bound to URL | `portal-config.js`: **branch is authoritative**; `PORTAL_ENV` inconsistent with branch ⇒ 409; branch-absent override requires explicit `PORTAL_ENV_IDENTITY == parsed ref`; **key project-ref binding** — JWT `ref` ≠ URL ref ⇒ 500, opaque `sb_publishable_*` requires `PORTAL_SUPABASE_EXPECTED_REF == parsed ref`. 7 new assertions. |
| **G1-03** (P1) | Manifest claimed all pages Function-dependent but exclusion omitted `invite.html`/`register-portal.html`; `--check` only verified listed pages exist | Manifest rebuilt **per page** (`needs_functions`); exclusion set **derived** and enforced by **set-equality** — CI fails if any `needs_functions` page is not excluded or any excluded page is stale/missing. `invite.html`+`register-portal.html` added; `portal-quote-suite.html`+`supplier-invitation-*.html` confirmed static (0 `/api`/supabase) and correctly **not** excluded. Negatives: omitted page detected; stale entry detected. |
| **G1-04** (P1) | Redirect stub dropped `?t=` token (query/hash), breaking supplier links | Stub now `location.replace(base + location.search + location.hash)` + a clickable fallback built with the same, preserving all params. Tested for `purchase-portal.html` and `supplier-quote.html`. |
| **G1-05** | Isolated staging is planned, not provisioned | **Recorded honestly:** no staging Supabase project/R2/users/bindings provisioned or verified — that is **owner external action + separate authorization** (correct under the no-config-change restriction). Gate 1 is **not** representable as fully passed until that provisioning + cross-environment isolation proof occur. |

## Changed / new files
- **new** `deploy/system3-manifest.json` — deployment manifest (route/file ownership, Functions dependency, exclusion list).
- **new** `scripts/pages-exclude.mjs` — GitHub Pages exclusion (redirect-stub; `--check` fails on manifest↔tree drift).
- **new** `scripts/stage1-tests.mjs` — 17 assertions incl. negative controls.
- **new** `audit-output/STAGE1_DEPLOYMENT_SAFETY.md` — this evidence doc.
- **edit** `scripts/env-guard.mjs` — `--exec` command-coupling mode.
- **edit** `supplier-quote.html` — env-aware `/api/portal-config` bootstrap (fail-closed); removed hardcoded prod project.
- **edit** `.github/workflows/pages.yml` — run `pages-exclude` before artifact upload.
- **edit** `.github/workflows/portal-tests.yml` — run `stage1-tests.mjs`; trigger on `scripts/**`, `deploy/**`, `supplier-quote.html`, `pages.yml`.
- **edit** `audit-output/STAGING_SETUP_PLAN.md` — command-coupling + Pages-exclusion + supplier-quote sections.

## Tests / negative controls (`node scripts/stage1-tests.mjs` — 28/28, exit 0)
- **env-guard (9):** rejects prod ref · rejects missing `STAGING` confirm · rejects `user@host` spoof · accepts confirmed staging · **(G1-01)** rejects explicit prod `--project-ref` and does **not** spawn the command (marker-file proof) · rejects explicit prod URL in the command · `{GUARDED_REF}` substituted + runs with the validated target · matching explicit staging target allowed · `--exec` without a command rejected.
- **pages-exclude (7):** `--check` set-equality passes on the real tree · replaces a page with a **query+hash-preserving** stub · `supplier-quote.html` stub preserves `?t=` · **(G1-03)** detects a `needs_functions` page omitted from exclusion · detects a stale/non-`needs_functions` excluded entry · rejects path-traversal page name · rejects invalid `canonical_origin`.
- **portal-config fail-closed (12):** no env signal ⇒ 503 · preview→production ref ⇒ 409 · `service_role` key ⇒ 500 · `user@host` URL ⇒ 503 · missing server binding ⇒ 503 · **(G1-02)** `PORTAL_ENV` conflicting with branch ⇒ 409 · JWT key project ≠ URL ⇒ 500 · opaque publishable without expected-ref ⇒ 500 · opaque with matching expected-ref ⇒ ok · branch-absent `PORTAL_ENV` without identity ⇒ 409 · with matching identity ⇒ ok · production-on-`main` ⇒ `ok:true`.

## Deployment-compatibility impact
- **Cloudflare Pages (canonical):** unchanged behavior — Functions serve `/api/*`; `portal-config` gates env; pages fetch config at runtime. `supplier-quote.html` now uses the same runtime-config path as the rest of System 3.
- **GitHub Pages:** Function-dependent pages are replaced by redirect stubs to `canonical_origin` at build time, so GitHub Pages no longer serves a broken System-3 page. Static assets are unaffected. **Effective only on the next `main` deploy** (owner-gated).
- **This branch:** neither deploy workflow triggers (both are `push: main` only); Draft PR; zero live effect.

## Explicit no-production-change confirmation
No database migration was applied to any project (production `list_migrations` still ends at `061`). No Supabase, Cloudflare,
R2/Storage, or Resend configuration was changed. No secret is printed or committed. All changes are repo files that take
effect only on a future owner-approved merge to `main`. **Gate 1** (independent review of this Stage-1 evidence) is not
claimed — this document is the submission for it.

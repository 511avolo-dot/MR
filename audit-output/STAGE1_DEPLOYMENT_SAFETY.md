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
| 8 | Automated tests + negative controls for all above | ✅ implemented | `scripts/stage1-tests.mjs` (**17 assertions, exit 0**) wired into `portal-tests.yml` |

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

## Tests / negative controls (`node scripts/stage1-tests.mjs` — 17/17, exit 0)
- **env-guard (7):** rejects prod ref · rejects missing `STAGING` confirm · rejects `user@host` spoof · accepts confirmed staging · `--exec` injects the validated `GUARDED_REF` into the command · `--exec` does **not** run the command when the target is rejected · `--exec` without a command is rejected.
- **pages-exclude (4):** `--check` passes on the real tree · replaces a System-3 page with a redirect stub · rejects a page name containing path traversal · rejects an invalid `canonical_origin`.
- **portal-config fail-closed (6):** no env signal ⇒ 503 · preview→production ref ⇒ 409 · `service_role` key ⇒ 500 · `user@host` URL ⇒ 503 · missing server binding ⇒ 503 · production-on-`main` + anon + service + bucket ⇒ `ok:true`.

## Deployment-compatibility impact
- **Cloudflare Pages (canonical):** unchanged behavior — Functions serve `/api/*`; `portal-config` gates env; pages fetch config at runtime. `supplier-quote.html` now uses the same runtime-config path as the rest of System 3.
- **GitHub Pages:** Function-dependent pages are replaced by redirect stubs to `canonical_origin` at build time, so GitHub Pages no longer serves a broken System-3 page. Static assets are unaffected. **Effective only on the next `main` deploy** (owner-gated).
- **This branch:** neither deploy workflow triggers (both are `push: main` only); Draft PR; zero live effect.

## Explicit no-production-change confirmation
No database migration was applied to any project (production `list_migrations` still ends at `061`). No Supabase, Cloudflare,
R2/Storage, or Resend configuration was changed. No secret is printed or committed. All changes are repo files that take
effect only on a future owner-approved merge to `main`. **Gate 1** (independent review of this Stage-1 evidence) is not
claimed — this document is the submission for it.

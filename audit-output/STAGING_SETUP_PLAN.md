# STAGING ENVIRONMENT SETUP PLAN — required before any migration-062 apply / browser E2E

**Why this exists:** `purchase-portal.html` previously hardcoded the **production** Supabase project
(`mwbjoysuybgbrvfrprex`), so the Cloudflare branch preview talked to production. Applying migration 062 "to the preview
DB" would therefore be a **production** change. This PR removes the hardcode (runtime env-aware config, fail-closed) and
adds an environment guard. Browser E2E and any 062 apply must happen on a **genuinely separate** staging project — never
production — and only with explicit owner authorization.

## Owner actions to create an isolated staging environment
1. **Create a separate Supabase project** (new project ref, e.g. `stg-aldeyabi-portal`). It must NOT be
   `mwbjoysuybgbrvfrprex`. Record its project ref: `STAGING_PROJECT_REF=<new_ref>`.
2. **Separate credentials:** copy the staging project's own **anon** key and **service-role** key. Do not reuse
   production keys. Never commit either key.
3. **Separate test users:** create staging-only auth users + matching `portal_users` rows (requester, disbursement
   approver, finance, GM, bank officer, admin). No production identities.
4. **Isolated test data:** seed staging with synthetic departments/beneficiaries/budgets only. No production rows.
5. **Separate storage namespace:** a distinct R2 bucket (or a distinct `QUOTES_BUCKET` binding) for staging so no
   production object is readable/writable from staging.
6. **Cloudflare Preview-only environment variables** (Pages → Settings → Environment variables → **Preview** scope):
   - `PORTAL_SUPABASE_URL` = `https://<staging_ref>.supabase.co`
   - `PORTAL_SUPABASE_ANON_KEY` = staging anon key
   - `PORTAL_SUPABASE_SERVICE_ROLE_KEY` = staging service-role key
   - `QUOTES_BUCKET` binding → staging bucket
   - (Production scope keeps the production values; on merge to `main`, add `PORTAL_SUPABASE_ANON_KEY` = the current
     production anon key so `/api/portal-config` can serve it — it is no longer embedded in the HTML.)
7. **Confirm production isolation:** from the staging anon/service keys, verify you cannot read or write any production
   table or bucket (different project ref ⇒ different credentials ⇒ no cross-access). `/api/portal-config` on the
   preview must return `env:"preview"` with the **staging** ref (never `mwbjoysuybgbrvfrprex`), or fail closed.

## Migration 062 apply (staging only) — guarded, command-coupled
The guard uses **command-specific adapters (Stage-1 item 3; hardened per G1-R2-01)** — it does **not** accept an arbitrary
passthrough command (token heuristics were bypassable via `sh -c '… --project-ref <prod>'`, `db.<ref>.supabase.co`, etc.).
Each named adapter **constructs the target argument internally** from the validated ref; the caller cannot supply a target
URL/ref. `migrate`/`e2e` **require** `--command`; `--purpose check` is validation-only and authorizes nothing. Unknown
flags, unknown commands, and the old `--exec` are rejected (fail-closed).
```bash
# migrate — Supabase CLI adapter (builds `supabase db push --project-ref <validated ref>` internally):
node scripts/env-guard.mjs --purpose migrate --ref "$STAGING_PROJECT_REF" --confirm STAGING --command supabase-db-push
# migrate — psql adapter (builds postgresql://postgres:<SUPABASE_DB_PASSWORD>@db.<validated ref>.supabase.co:5432/postgres):
node scripts/env-guard.mjs --purpose migrate --ref "$STAGING_PROJECT_REF" --confirm STAGING \
  --command psql-migration --file db/portal-migrations/062-request-documents.sql       # + SUPABASE_DB_PASSWORD in env
# e2e — builds E2E_SUPABASE_URL=https://<validated ref>.supabase.co and runs the given spec under scripts/|tests/:
node scripts/env-guard.mjs --purpose e2e --ref "$STAGING_PROJECT_REF" --confirm STAGING --command browser-e2e --spec scripts/e2e/portal.mjs
# Preview the constructed command without running it (no secrets printed):
node scripts/env-guard.mjs --purpose migrate --ref "$STAGING_PROJECT_REF" --confirm STAGING --command supabase-db-push --dry-run
```
An explicit production target can no longer be smuggled in: `--project-ref mwbjoysuybgbrvfrprex`, `--db-url postgresql://…@db.<prod>…`,
and `sh -c` wrappers are all rejected (proven by `scripts/stage1-tests.mjs` negatives). The guard also hard-blocks
`mwbjoysuybgbrvfrprex` as the target ref.

## GitHub Pages ambiguity removed (Stage-1 items 4–5; hardened per G1-R2-04)
- **`deploy/system3-manifest.json`** models Cloudflare-Functions dependency **per page** (`pages[].needs_functions`). The
  exclusion set is **derived** into `github_pages_exclude.derived_pages` = { pages where `needs_functions === true` }.
- **`scripts/pages-exclude.mjs`** runs in `.github/workflows/pages.yml` **before** the Pages artifact upload; it replaces
  each Function-dependent page with a redirect stub to `canonical_origin` **preserving `location.search` + `location.hash`**
  (so a supplier `?t=…` link survives). `--check` enforces **set-equality**: the build fails if any `needs_functions` page
  is not excluded, or any excluded entry is stale/missing, or `canonical_origin` is invalid (fail-closed).
- This changes **no live deployment now**: `pages.yml`/`deploy.yml` run only on push to `main`, and this PR is Draft.

## supplier-quote.html env-config (Stage-1 item 6)
`supplier-quote.html` no longer embeds the production project; it fetches `/api/portal-config` at runtime (fail-closed:
on any config error it shows a visible config-error state and does not connect), matching `purchase-portal.html`.

## Rollback (staging)
- Fail-closed: `UPDATE portal_settings SET value = value || '{"expense_docs_required":0}' WHERE key='portal_settings';`
  (stops the block) and/or `REVOKE EXECUTE ON FUNCTION portal_create_expense_draft(...)/portal_submit_expense(text) FROM authenticated;`
- Do not drop `portal_request_documents` if it holds rows. Full rollback detail is in the header of
  `db/portal-migrations/062-request-documents.sql`.

## Cleanup after E2E
- Delete staging test requests/documents; empty the staging R2 namespace; optionally pause/delete the staging Supabase
  project. Production is never touched.

## Browser E2E gating (enforced, command-coupled)
- E2E must run **through the guard's coupled adapter**: `node scripts/env-guard.mjs --purpose e2e --ref "$STAGING_PROJECT_REF"
  --confirm STAGING --command browser-e2e --spec <spec>`. The guard builds `E2E_SUPABASE_URL=https://<validated ref>.supabase.co`
  itself and refuses `mwbjoysuybgbrvfrprex`. Running E2E as a separate command after a bare validation is no longer a
  supported path (`migrate`/`e2e` require `--command`). E2E completion will NOT be claimed until a genuinely isolated
  staging project exists and 062 has been applied there with explicit owner authorization.

## Proof that production is untouched by this PR
- No migration was applied to any database in this PR (062 is repo-only). `list_migrations` on production still ends at
  `061`. No Storage policy changed. The only production-facing behavior change (removing the hardcoded project) is inert
  until merge, and even then is fail-closed + guarded.

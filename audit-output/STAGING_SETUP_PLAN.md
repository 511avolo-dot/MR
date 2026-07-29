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

## Migration 062 apply (staging only) — guarded
```bash
# 1) Guard refuses production ref / missing confirmation, and prints the target ref:
node scripts/env-guard.mjs --purpose migrate --ref "$STAGING_PROJECT_REF" --confirm "$STAGING_CONFIRM"   # STAGING_CONFIRM=STAGING
# 2) Only if the guard exits 0, apply to STAGING via the Supabase CLI/MCP against the staging project:
#    supabase db push --project-ref "$STAGING_PROJECT_REF"   (or apply db/portal-migrations/062-request-documents.sql)
```
Do **not** run any apply command without the guard passing first. The guard hard-blocks `mwbjoysuybgbrvfrprex`.

## Rollback (staging)
- Fail-closed: `UPDATE portal_settings SET value = value || '{"expense_docs_required":0}' WHERE key='portal_settings';`
  (stops the block) and/or `REVOKE EXECUTE ON FUNCTION portal_create_expense_draft(...)/portal_submit_expense(text) FROM authenticated;`
- Do not drop `portal_request_documents` if it holds rows. Full rollback detail is in the header of
  `db/portal-migrations/062-request-documents.sql`.

## Cleanup after E2E
- Delete staging test requests/documents; empty the staging R2 namespace; optionally pause/delete the staging Supabase
  project. Production is never touched.

## Browser E2E gating (enforced)
- E2E must call `node scripts/env-guard.mjs --purpose e2e --url "$E2E_SUPABASE_URL" --confirm STAGING` first; it refuses
  when the ref equals `mwbjoysuybgbrvfrprex`. E2E completion will NOT be claimed until a genuinely isolated staging
  project exists and 062 has been applied there with explicit owner authorization.

## Proof that production is untouched by this PR
- No migration was applied to any database in this PR (062 is repo-only). `list_migrations` on production still ends at
  `061`. No Storage policy changed. The only production-facing behavior change (removing the hardcoded project) is inert
  until merge, and even then is fail-closed + guarded.

# API SECURITY MATRIX — Cloudflare Pages Functions (`functions/api/*`)

Auth model: portal endpoints authenticate via Supabase JWT (Bearer) or a server-only secret; admin endpoints require an
admin JWT + active check; server-role writes use the service key. Public/token endpoints derive the request scope from
the **database**, never from client input. All upload paths pass `_file-guard.js`.

> **Inventory-completeness note (Codex, INFO-05).** The first issue of this matrix omitted several handlers and listed a
> helper (`_pr-shared.js`) as if a route. It is corrected below to inventory **every** `functions/api/*` handler; helpers
> are marked `(helper — not a route)`. Handlers marked **⚠ not independently auth-reviewed** are inventoried but were
> **not** verified in depth here and must be reviewed before certification (they include service-role user admin, an AI
> proxy, and public/invite flows).

| Endpoint | Auth | Sensitive action | Key controls / status |
|----------|------|------------------|--------------|
| `portal-notify.js` | server / JWT | Send workflow email | Recipients computed from approval chain; kinds incl. `disbursement` |
| `portal-action.js` | email token | One-click approve from email | Token single-use; origin from `PUBLIC_ORIGIN` (not attacker Host); cycle-aware (056) |
| `portal-users.js` | admin JWT | Portal user CRUD | Self/last-admin guards **fail-closed**; delete→disable when user has requests; domain/whitelist server-side |
| `portal-invite.js` | admin JWT | Invitations / whitelist | One-time token, 7-day expiry, RLS-locked table; email-policy enforced |
| `portal-register.js` | invite token | Create account+profile | Token-verified; orphan Auth cleanup on profile-insert failure |
| `portal-doc.js` | JWT + perm | Upload/serve docs | Per-type perm (`disb`=can_disburse, `inv`, `ret`, `grn`, `pay`…); **download visibility fail-closed**; `_file-guard` |
| `portal-supplier-doc.js` | supplier token | Supplier quote upload | Request id **from DB via token**; per-token upload cap (049); `_file-guard`; upload-only |
| `portal-quote.js` | JWT + visibility | Serve quote files | Visibility check **fail-closed**; images allowed |
| `portal-outbox-drain.js` | `CRON_SECRET` | Deliver outbox + SLA + recurring | Bearer/`?key=`; `401` without secret; `FOR UPDATE SKIP LOCKED`; backoff + dead-letter |
| `portal-signup.js` | ⚠ not independently auth-reviewed | Public/portal signup | **Review before certification** |
| `portal-supplier-invite.js` | ⚠ not independently auth-reviewed | Supplier invitation flow | **Review before certification** |
| `reg-doc.js` (System 1) | forgeable same-origin (no credential) | Supplier-registration upload | **SEC-06 (HIGH, open):** server path improved (destructive cleanup removed, explicit allowlist) — **but NOT inert**: `register.html` falls back to a **direct anonymous Storage upload** on 503/404/network-error, which is the **live** path while the key is unset and **bypasses the allowlist + `_file-guard`**. Go-live blocker (**credential-first, atomic**): add+verify credential (SEC-06-R) → cutover (deploy authed endpoint + set key + remove anon fallback + revoke anon Storage writes) → verify. Allowlist corrected to real form doc IDs this round. |
| `admin-users.js` (System 2) | ⚠ not independently auth-reviewed | Service-role user administration | Isolated from portal; **review before certification** |
| `ai.js` (System 2) | ⚠ not independently auth-reviewed | Server-key-backed AI proxy | **Review before certification** (abuse/cost/prompt-injection surface) |
| `invite-supplier.js` (System 2) | ⚠ not independently auth-reviewed | Supplier invitation email | **Review before certification** |
| `verify.js` (System 2) | ⚠ not independently auth-reviewed | Verification flow | **Review before certification** |
| `notify.js` / `pr-action.js` (System 2) | server / token | System-2 email + approve | Isolated from portal; health endpoint returns boolean `checks{}` (no values) |
| `_pr-shared.js` / `_portal-shared.js` / `_file-guard.js` | (helper — not a route) | — | Shared modules (email templates, tokens, upload guard) |

## Cross-cutting
- **No secrets in code**; service keys read from Cloudflare env (`PORTAL_SUPABASE_*`, `SUPABASE_SERVICE_ROLE_KEY`,
  `RESEND_API_KEY`, `CRON_SECRET`).
- **Identity never trusted from the client** on privileged paths — derived from JWT/`session_user` or DB-verified token.
- **Server-only DB functions** (16, pinned by tests S7/S8) are not `anon`/`PUBLIC`-executable.
- **Health endpoints** (`/api/notify`, `/api/portal-notify` GET) return presence booleans only (anti-oracle), and log
  loudly on misconfiguration.

## Residual / to verify (Codex)
Dynamic replay of each endpoint with a wrong-permission / different-department JWT (NV-02); competitor-offer leakage and
post-closure submission on supplier links (CODEX_HANDOFF §7); dead-control drift between new UI panels and backend
enforcement (historically a real class here).

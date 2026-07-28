# API SECURITY MATRIX — Cloudflare Pages Functions (`functions/api/*`)

Auth model: portal endpoints authenticate via Supabase JWT (Bearer) or a server-only secret; admin endpoints require an
admin JWT + active check; server-role writes use the service key. Public/token endpoints derive the request scope from
the **database**, never from client input. All upload paths pass `_file-guard.js`.

| Endpoint | Auth | Sensitive action | Key controls |
|----------|------|------------------|--------------|
| `portal-notify.js` | server / JWT | Send workflow email | Recipients computed from approval chain; kinds incl. `disbursement` |
| `portal-action.js` | email token | One-click approve from email | Token single-use; origin from `PUBLIC_ORIGIN` (not attacker Host); cycle-aware (056) |
| `portal-users.js` | admin JWT | User CRUD | Self/last-admin guards **fail-closed**; delete→disable when user has requests; domain/whitelist server-side |
| `portal-invite.js` | admin JWT | Invitations / whitelist | One-time token, 7-day expiry, RLS-locked table; email-policy enforced |
| `portal-register.js` | invite token | Create account+profile | Token-verified; orphan Auth cleanup on profile-insert failure |
| `portal-doc.js` | JWT + perm | Upload/serve docs | Per-type perm (`disb`=can_disburse, `inv`, `ret`, `grn`, `pay`…); **download visibility fail-closed**; `_file-guard` |
| `portal-supplier-doc.js` | supplier token | Supplier quote upload | Request id **from DB via token**; per-token upload cap (049); `_file-guard`; upload-only |
| `portal-quote.js` | JWT + visibility | Serve quote files | Visibility check **fail-closed**; images allowed |
| `portal-outbox-drain.js` | `CRON_SECRET` | Deliver outbox + SLA + recurring | Bearer/`?key=`; `401` without secret; `FOR UPDATE SKIP LOCKED`; backoff + dead-letter |
| `reg-doc.js` (System 1) | server key | Supplier-registration upload | `reg_id`/`doc` allowlist, server-generated name, `_file-guard`, 503 fallback until service key set |
| `notify.js` / `_pr-shared.js` / `pr-action.js` (System 2) | server / token | System-2 email + approve | Isolated from portal; health endpoint returns boolean `checks{}` (no values) |

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

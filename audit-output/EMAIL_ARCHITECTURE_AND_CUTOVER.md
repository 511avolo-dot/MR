# EMAIL ARCHITECTURE & CUTOVER — System-3 email isolation (E0)

**Status:** E0 (inventory + proof of isolation). **Repo-only. No binding/DB/config changed.** `txn_notifications` stays `0`.
**Method:** read every email endpoint/helper in `functions/api/` at head `3861171` and record actual `env.*` reads and send paths. Facts marked **NOT VERIFIED** require the Resend/Cloudflare dashboards (not inspectable from the repo).

---

## 0. Executive summary

- **Database/application isolation is real:** System 3 uses `PORTAL_SUPABASE_*`; Systems 1/2 use `SUPABASE_*`. Confirmed in source.
- **Email isolation is NOT real yet:** all three systems read the **same** Cloudflare bindings — `RESEND_API_KEY`, `NOTIFY_FROM`, `NOTIFY_REPLY_TO`, `PUBLIC_ORIGIN`. There is no System-3-specific email key, from-address, reply-to, origin, or throttle.
- **Scheduled business jobs are coupled to email:** `portal-outbox-drain.js` runs **SLA escalation + recurring generation + outbox delivery** in one handler, and **returns early on a missing Resend key before the SLA/recurring jobs run** (line 109 precedes lines 116/119). A Resend outage or missing key therefore blocks SLA escalation and recurring-expense generation.
- **Duplicate risk on `txn_notifications=1`:** workflow email today flows through the immediate UI path (`pa_notify` → `portal-notify.js`). The 058 trigger (behind `txn_notifications`, default `0`) would enqueue the same approver notifications into the outbox; with the immediate path still active and unsuppressed server-side, enabling it produces duplicate System-3 emails.
- **Cron secret weaknesses:** `portal-outbox-drain.js` accepts the secret via `?key=` query string and compares non-constant-time.

**Conclusion:** the E1–E6 plan below is required before `txn_notifications=1`. It is implementable repo-only without touching Systems 1/2 by adding dedicated portal bindings, server-enforced delivery mode, a throttled outbox, decoupled schedulers, and a staged shadow→outbox cutover.

---

## 1. Email endpoints & helpers by system (source-verified)

### System 1 — supplier registration (`register.html`, project `yofcaxvstjcrmbgciwym`)
| File | Purpose | `env.*` read (email-relevant) |
|---|---|---|
| `functions/api/notify.js` | "request received" + admin notifications | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `RESEND_API_KEY` |
| `functions/api/verify.js` | email verification | `SUPABASE_*` (service) |
| `functions/api/admin-users.js` | admin user mgmt | `SUPABASE_SERVICE_ROLE_KEY` |
| `functions/api/invite-supplier.js` | supplier invite email | `RESEND_API_KEY`, `NOTIFY_FROM`, `NOTIFY_REPLY_TO`, `INVITE_TOKEN` |

### System 2 — procurement main (`index.html`/`requests.html`/`rfq.html`, same legacy project)
| File | Purpose | `env.*` read (email-relevant) |
|---|---|---|
| `functions/api/_pr-shared.js` | shared PR email module (templates + tokens) | `RESEND_API_KEY`, `NOTIFY_FROM`, `NOTIFY_REPLY_TO`, `PUBLIC_ORIGIN`, `SUPPLIERS_ORIGIN`, `SUPABASE_SERVICE_ROLE_KEY`, `PR_TOKEN_TTL_HOURS` |
| `functions/api/pr-action.js` | one-click PR approval from email | `RESEND_API_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` |

### System 3 — portal (`purchase-portal.html`, project `mwbjoysuybgbrvfrprex`)
| File | Purpose | `env.*` read (email-relevant) | Trigger type |
|---|---|---|---|
| `functions/api/_portal-shared.js` | shared portal email module | `NOTIFY_FROM`, `NOTIFY_REPLY_TO`, `PUBLIC_ORIGIN`, `RESEND_API_KEY`, `PORTAL_SUPABASE_*` | helper |
| `functions/api/portal-notify.js` | immediate per-event workflow email | `PORTAL_SUPABASE_*`, `RESEND_API_KEY` (`emailConfigured = portalConfigured && RESEND_API_KEY`) | **UI-triggered (immediate)** |
| `functions/api/portal-action.js` | one-click email approval | `RESEND_API_KEY`, `PORTAL_SUPABASE_*` | email link |
| `functions/api/portal-invite.js` | portal user invite | `RESEND_API_KEY`, `PORTAL_SUPABASE_*` | UI (admin) |
| `functions/api/portal-supplier-invite.js` | portal→supplier RFQ invite | `RESEND_API_KEY`, `PUBLIC_ORIGIN`, `PORTAL_SUPABASE_*` | UI |
| `functions/api/portal-outbox-drain.js` | **SLA + recurring + outbox delivery** | `CRON_SECRET`, `RESEND_API_KEY`, `PORTAL_SUPABASE_*` | **scheduled (cron)** |

---

## 2. Binding / project / domain map

| Concern | System 1 | System 2 | System 3 (portal) |
|---|---|---|---|
| Supabase project | `yofcaxvstjcrmbgciwym` | `yofcaxvstjcrmbgciwym` | `mwbjoysuybgbrvfrprex` |
| Supabase URL/key bindings | `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` | `SUPABASE_*` | `PORTAL_SUPABASE_URL` / `PORTAL_SUPABASE_SERVICE_ROLE_KEY` (**isolated ✓**) |
| Resend API key binding | `RESEND_API_KEY` | `RESEND_API_KEY` | `RESEND_API_KEY` (**SHARED ✗**) |
| From address | `NOTIFY_FROM` (`noreply@suppliers.aldeyabi.com`) | `NOTIFY_FROM` | `NOTIFY_FROM` (**SHARED ✗**) |
| Reply-to | `NOTIFY_REPLY_TO` (`supply@aldeyabi.com`) | `NOTIFY_REPLY_TO` | `NOTIFY_REPLY_TO` (**SHARED ✗**) |
| Public origin | `PUBLIC_ORIGIN` / `SUPPLIERS_ORIGIN` | `PUBLIC_ORIGIN` | `PUBLIC_ORIGIN` (**SHARED ✗**) |
| Cron secret | — | — | `CRON_SECRET` (portal-only, but see §5) |
| Sending domain | `suppliers.aldeyabi.com` | `suppliers.aldeyabi.com` | `suppliers.aldeyabi.com` (**SHARED ✗**) |
| Resend team / plan / rate & quota | **NOT VERIFIED** | **NOT VERIFIED** | **NOT VERIFIED** — separate keys in one Resend team still share the team rate pool |

Cloudflare project/environment (Pages `aldeyabi-procurement`, Production + Preview) is **shared** across all three systems (one repo, one Pages project). **NOT VERIFIED:** whether any per-environment override exists.

---

## 3. Immediate (UI) vs DB/outbox sends — System 3

**Immediate (UI-triggered), active today:** `purchase-portal.html` `pa_notify(kind, requestId, event)` → `POST /api/portal-notify` → `portal-notify.js` sends synchronously via Resend. Kinds seen in source/converter: `request`, `award`, `payment`, `receipt`, `disbursement`, `reminder`, plus invites (`portal-invite`, `portal-supplier-invite`) and one-click (`portal-action`).

**DB/outbox-triggered:** migration 029 trigger on `portal_notifications` INSERT → `portal_outbox` → `portal-outbox-drain.js`. **Today `portal_notifications` is inserted only by `portal_run_sla()` (SLA escalation).** Migration 058 adds an `AFTER UPDATE` trigger on `portal_requests` that enqueues the next-approver notification, **gated by `txn_notifications` (default `0`)** — inert until enabled.

So today the two paths do **not** overlap: workflow email = immediate `pa_notify`; SLA-escalation email = outbox. **Enabling `txn_notifications=1` makes them overlap** for approval-stage notifications ⇒ duplicates unless the immediate path is suppressed **server-side**.

---

## 4. Duplicate / missing-email matrix (by event)

Legend: **I** = immediate (`pa_notify`→`portal-notify`), **O(058)** = outbox if `txn_notifications=1`, **O(SLA)** = outbox via `portal_run_sla`.

| Event | Today | After naive `txn_notifications=1` | Risk |
|---|---|---|---|
| submitted / stage advanced (approver) | I | I **+** O(058) | **DUPLICATE** |
| returned / rejected | I | I | (058 covers approver-entry only) missing outbox intent |
| award / PO / committee | I | I | not in outbox → no durable delivery |
| payment / disbursement stage | I | I | not in outbox |
| receipt | I | I | not in outbox |
| SLA escalation | O(SLA) | O(SLA) | ok |
| recurring blocked obligation | none (audit `request_id=NULL`) | none | **MISSING** (finance never emailed) |
| correction / reassignment / delegation (future engine) | n/a | n/a | must be designed into outbox |

**Interpretation:** the target end state is `outbox` authoritative for **all** System-3 automated events (not just approval-entry), with the immediate path suppressed server-side, and a durable intent for currently-missing events (award/PO/payment/receipt/recurring-blocked).

---

## 5. Confirmed defects to fix in E2–E4 (source line refs)

1. **Scheduled jobs coupled to email + fail-blocked:** `portal-outbox-drain.js:109` `if (!env.RESEND_API_KEY) return … 500` executes **before** `runSla` (`:116`) and `runRecurring` (`:119`). Missing/invalid Resend key ⇒ **SLA escalation and recurring generation both stop.** → E2 split into `portal-scheduler` (SLA + recurring) and `portal-email-drain` (delivery only).
2. **Query-string cron secret:** `:40` accepts `?key=<secret>`; `:41` compares with `===` (not constant-time). → E2 header-only + constant-time.
3. **Shared Resend key/domain/from/reply-to/origin** (§2). → E1 dedicated `PORTAL_*` bindings, fail-closed (no fallback to `RESEND_API_KEY`).
4. **No server-enforced delivery mode:** suppression of the immediate path depends on removing frontend `pa_notify` calls; a stale browser tab still POSTs `/api/portal-notify`. → E3 `PORTAL_EMAIL_MODE` enforced in `portal-notify.js` (return `skipped: outbox_authoritative` in `outbox` mode).
5. **Broad `EXCEPTION WHEN OTHERS` around notification enqueue** (029/058 helpers) can swallow intent-insert failures. → E4 must not swallow in authoritative mode; intent insert atomic with the transition.
6. **No throttle:** nothing enforces a System-3 RPS ceiling below the shared Resend team rate. → E1/E4 `PORTAL_EMAIL_MAX_RPS`.
7. **No operator visibility** into pending/processing/retry/dead. → E5 admin Email Operations page.

---

## 6. Target bindings (E1) — additive, no legacy change

New (System 3 only): `PORTAL_RESEND_API_KEY` (sending-only, domain-restricted), `PORTAL_NOTIFY_FROM`, `PORTAL_NOTIFY_REPLY_TO`, `PORTAL_PUBLIC_ORIGIN`, `PORTAL_CRON_SECRET`, `PORTAL_EMAIL_MODE` (`off|legacy|shadow|outbox`), `PORTAL_EMAIL_MAX_RPS` (+ batch/claim limits).
Legacy unchanged: `RESEND_API_KEY`, `NOTIFY_FROM`, `NOTIFY_REPLY_TO`, `PUBLIC_ORIGIN`/`SUPPLIERS_ORIGIN`, existing System-1/2 endpoints.
**Fail-closed:** portal helpers read `PORTAL_RESEND_API_KEY` etc.; **no fallback** to `RESEND_API_KEY` in production. Missing portal email config disables the portal sender only, never Systems 1/2.
Preferred: dedicated sending subdomain (`procurement.` or `notifications.aldeyabi.com`); maximum isolation = separate Resend team/account. If the team is shared, rate/quota remain shared → enforce `PORTAL_EMAIL_MAX_RPS` below the team limit (**team limit NOT VERIFIED**).

---

## 7. Delivery-mode state machine (E3, server-enforced)

- `off` — no intent, no send.
- `legacy` — current immediate `portal-notify` only (no outbox intents).
- `shadow` — create outbox intents **but do not send**; immediate path still sends. Used to prove "exactly one intent per intended email" without customer impact.
- `outbox` — outbox authoritative; `portal-notify` automated sends return `skipped: outbox_authoritative` (stale tabs cannot duplicate).

Invariant: **never a window where both paths send, never a window where neither records an intent.** Mode is read server-side (setting/binding), not inferred from the client.

---

## 8. Cutover sequence (E6) — repo + owner steps, isolated staging first

1. Deploy code in `legacy` mode, `PORTAL_*` email vars absent → confirm Systems 1/2 byte/contract unchanged.
2. Owner: create sending-only Resend key restricted to portal domain → add as `PORTAL_RESEND_API_KEY` (Preview first).
3. Owner: set `PORTAL_NOTIFY_FROM/REPLY_TO/PUBLIC_ORIGIN/CRON_SECRET` in Preview.
4. Isolated **staging** Supabase (see `STAGING_SETUP_PLAN.md`) → `shadow` → exercise all events → verify exactly one intent per intended email while legacy still sends.
5. Canary drain to approved internal test recipients only → verify links, Arabic/RTL, sender, reply-to, SPF/DKIM/DMARC, bounce, 429/Retry-After backoff.
6. Switch atomically to `outbox`; server-side immediate endpoint suppresses automated sends.
7. Monitor ≥1 full workflow cycle before any production authorization.
8. Rollback to `legacy` without deleting queued intents (queued rows → `suppressed`/paused to avoid later duplicates).

**No step in this PR applies a DB/config change.** `txn_notifications` remains `0`; production authorization is a separate explicit owner decision.

---

## 9. Test matrix (E-tests) — to implement alongside E2–E4

Systems 1/2 endpoints byte/contract-compatible before/after · portal key absent/invalid does not affect legacy · portal Resend outage does not block approval/SLA/recurring · `shadow` creates intents + sends zero portal emails · `outbox` sends exactly one + immediate sends zero · stale-tab `portal-notify` in `outbox` cannot duplicate · repeated transition/retry = one intent · two drain workers do not double-send · worker crash after claim recovers lease · 429 honors Retry-After without starving legacy · missing email visible as skipped/error (not sent) · dead-letter retry audited + idempotent · all events (submitted/stage/returned/rejected/award/PO+committee/payment/disbursement/receipt/correction+reassignment+delegation/recurring-blocked) · staging browser E2E + production canary only after explicit owner authorization.

---

## 10. Open / NOT VERIFIED

- Resend plan, team membership, and per-team rate/quota for the current `RESEND_API_KEY` — dashboard only.
- Whether any Cloudflare per-environment (Preview vs Production) email override already exists.
- SPF/DKIM/DMARC posture for a new portal subdomain.
- Exact recipient-resolution parity between `pa_notify` recipients and the 058 trigger's computed recipients (must match before `outbox` cutover so no recipient is dropped).

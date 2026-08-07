# Finding — requester purchase-request visibility — ⛔ WITHDRAWN / FALSE ALARM (2026-08-07)

> **STATUS: WITHDRAWN. This was my error, corrected the same day.** I initially reported that the P0-1
> raw-read boundary (`portal_can_read_raw_request`) left requesters unable to see their own purchase
> requests. That conclusion was **wrong**: I judged from the raw `portal_requests` read alone and did
> **not** trace the full `loadAll` merge. The frontend already has a dedicated **safe requester feed**,
> `portal_my_purchase_dossiers()` (migration `p0_1h`, "requester safe purchase dossier"), which
> `loadAll` calls and merges (`purchase-portal.html:2730` and the merge at lines 2749–2771). No fix is
> needed; **no code/DB change was made** (a proposed `p0_1q` safe-view migration was discarded before commit).

## Live verification of the correction (rolled back, zero persistence)
As requester `zzk_e` (`{can_create}`, no privileged permission), after creating request `R-check`:
- `portal_my_purchase_dossiers()` → `requester=zzk_e`, `total_dossiers=1`, **`includes_own_r1=true`**.

So the requester **does** see their own purchase request through the app's safe path. The raw-table
restriction is defense-in-depth (protects sensitive columns / direct table access); the safe dossier
feed provides the requester's scoped, redacted view — exactly the "option 1" pattern, already implemented.

## What remains TRUE and validated (the security-positive part of VI)
The RLS isolation itself is sound (verified live under the real `authenticated` role):
- plain employee sees **0** of a coworker's and of another sector's requests (no leak);
- sector manager sees own sector only (OPS R1,R2; CON R3 = 0);
- procurement (all-scope) sees all.

## Lesson
Trace the **entire** client read/merge path before classifying a restrictive RLS predicate as a
functional gap. A stricter raw-table policy paired with a safe DEFINER feed is the intended pattern
here, not a regression. (Same verify-before-claim discipline applied to V4 budget and VF email token.)

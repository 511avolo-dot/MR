# Verified live migration versions — DOCUMENTARY ONLY (not executable history)

> **F1 / G1-R7-02 correction.** We do **NOT** invent timestamps for production migrations 001–058, and we do **NOT**
> present any generated bundle as "canonical production history." Staging uses a **separate baseline lineage**
> (`baseline_through_061.sql` + migration `062`), proven by `verify-baseline.sh`. The values below are the
> **verified live Supabase `schema_migrations` versions** recorded during earlier owner-run applications — kept
> here as **evidence**, never as an executable migration history.

| Semantic | Verified live version (Supabase `schema_migrations`) | Source |
|---|---|---|
| 057 | `20260727072143` | owner review G1-R7-02 |
| 058 | `20260727093705` | owner review G1-R7-02 |
| 059 | `20260728093548` | ledger MIGRATION_HISTORY_RECONCILIATION |
| 060 | `20260728170320` | ledger (commit 135f5af proof) |
| 061 | `20260729073619` | ledger MIGRATION_HISTORY_RECONCILIATION |
| 062 | `20260730120000` (pending — NOT applied live) | assigned strictly after 061 |

The full real versions of 001–056 require an **owner-authorized read-only export** of live `schema_migrations` and are
**not reconstructed here**. Until that export exists, the executable path is the staging **baseline** — a single
checksum-pinned artifact — not a per-migration invented timeline.

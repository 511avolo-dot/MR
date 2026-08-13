# Enterprise UI Release Notes — Draft PR #74

## Included

- New Arabic-first enterprise visual system and responsive interaction layer.
- Full-screen authenticated preview for uploaded PDF/image documents.
- Full-screen preview for generated purchase requests, purchase orders, receipts, and vouchers before print/save-PDF.
- Side-by-side quotation-document comparison with supplier totals and delivery duration.
- Server-side quotation-file confidentiality gate using `portal_can_view_quotes`.
- Version-aware Committee Policy Studio using existing authorized RPCs.
- Read-only Effective Access Inspector with separation-of-duties warnings.
- New static, endpoint, and Playwright browser contracts in `portal-tests`.
- Execution record and owner acceptance checklist.

## Verification

Code head `563de07a901f2bf19533427f49d61ae8c4ed858b` passed `portal-tests` run 165:

- `test`: passed.
- `browser-e2e-fixture`: passed.
- `supabase-contract`: passed.

The current branch head adds documentation only after that tested code head.

## Not included / not authorized

- No production deployment.
- No change to `main`.
- No merge and no Ready-for-review transition.
- No application of migration `063`.
- No hosted Preview certification yet.
- No owner authorization to publish a policy change or change production configuration.

## Next release gate

Deploy the branch through the existing Cloudflare PR Preview process, prove the Preview is connected only to isolated staging, then execute the owner acceptance checklist with dummy users and dummy documents.

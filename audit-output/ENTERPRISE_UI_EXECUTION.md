# Enterprise UI Execution Record — System 3

**Branch:** `audit/enterprise-certification-2026-07-27`  
**PR:** Draft PR #74  
**Execution date:** 2026-08-02  
**Release state:** Branch implementation only — not production authorization

## 1. Purpose

This record describes the implemented enterprise user-experience layer for the procurement and unified-disbursement portal. The goal is to improve clarity, document review, policy administration, and permission explainability without replacing the existing authorization model or weakening the database/API security boundary.

Design direction: **Quiet Authority** — Arabic-first, calm, precise, information-dense, and suitable for a financial/procurement environment.

## 2. Implemented surfaces

### 2.1 Enterprise design system

Files:

- `assets/enterprise-ui.css`
- `assets/enterprise-ui.js`

Implemented:

- Unified design tokens for surfaces, type hierarchy, spacing, borders, states, focus, and motion.
- Refined top bar, navigation, cards, tables, forms, buttons, filters, modals, and responsive layouts.
- RTL-first behavior rather than mirroring an English layout.
- Skip navigation, main/navigation landmarks, accessible table headings, live announcements, focus-visible treatment, and reduced-motion support.
- A transaction context strip showing the current request, department, requester, and stage.

### 2.2 Uploaded Document Studio

Files:

- `assets/document-studio.js`
- document styles in `assets/enterprise-ui.css`

Implemented:

- Authenticated, same-origin preview for supporting documents through `/api/portal-doc`.
- PDF and image preview without exposing an R2 public URL.
- Document sidebar, zoom, fit modes, rotation, keyboard close, download, and object-URL cleanup.
- Legacy `pa_docView` and `pa_reqdocView` calls are bridged to the new viewer.

### 2.3 Generated Document Studio

Files:

- `assets/generated-document-studio.css`
- `assets/generated-document-studio.js`

Implemented:

- Legacy `printEl` actions now open a full in-portal preview before printing or saving as PDF.
- Applies to generated purchase requests, purchase orders, receipt minutes, vouchers, and other portal-rendered forms that use the shared print function.
- A4-oriented paper view, zoom, fit-page/fit-width, keyboard controls, and print/save-PDF action.
- Removes controls and non-document UI from the preview.
- Adds a defensive UI privacy pass that removes financial columns for users whose effective interface access does not include financial or quotation capabilities.

The UI privacy pass is not the security boundary. Sensitive data must still be excluded by RLS/RPC/API and by the source document renderer.

### 2.4 Quotation Comparison Studio

Files:

- `assets/quote-document-studio.css`
- `assets/quote-document-studio.js`
- `functions/api/portal-quote.js`

Implemented:

- Replaces the legacy quotation modal via the existing `openQuoteViewer` entry point.
- Side-by-side comparison of two quotation documents.
- Supplier navigation, single-document mode, totals, delivery days, lowest-price indicator, authenticated same-origin loading, and object-URL cleanup.
- No public R2 URL and no external-tab dependency.

Security correction:

- Quotation-file GET now requires both request visibility and `portal_can_view_quotes(request_id)`.
- Request ownership alone no longer permits retrieval of a confidential quotation file.
- Permission RPC failures are fail-closed.

### 2.5 Committee Policy Studio

File:

- `assets/policy-studio.js`

Implemented against existing server-authorized RPCs:

- `portal_get_committee_policy`
- `portal_committee_route`
- `portal_set_committee_policy`

Capabilities:

- Enable or disable the committee.
- Set minimum and maximum financial range.
- Choose a fallback approval capability when the committee is disabled.
- Preview the route.
- Simulate a purchase-order amount before publishing.
- Compare draft values with the published version.
- Two-step review and publish.
- Show version, publisher, and publication time.

The studio does not write `portal_settings` directly. Existing policy versioning and per-transaction policy snapshots remain authoritative.

### 2.6 Effective Access Inspector

Files:

- `assets/access-inspector.css`
- `assets/access-inspector.js`

Implemented:

- Admin-only, read-only permission explanation using the existing `USERS`, `JOBS`, `DEPTS`, and `accessOf` model.
- Search by user, job, or department.
- Displays effective capabilities, organizational scope, department, sector, delegation, and source of access.
- Differentiates direct grants from job inheritance where the current client model exposes that source.
- Flags visible separation-of-duties combinations, including approval plus execution of disbursement.
- Does not call mutation RPCs or write tables.

This inspector is a diagnostic aid. Database tests and server authorization remain the final authority.

## 3. Integration approach

`functions/_middleware.js` injects the enterprise CSS and JavaScript only into:

- `/purchase-portal`
- `/purchase-portal.html`

This avoids a large, risky rewrite of the legacy single-file portal and preserves the current operational entry points. The integration is reversible by removing the injected asset references from the middleware.

The existing middleware permission guard remains in place. It hides unauthorized quotation/award and direct-expense affordances, while RLS/RPC/API remains authoritative.

## 4. Automated verification

Added or extended:

- `scripts/e2e/enterprise-ui-contract.test.mjs`
- `scripts/e2e/enterprise-ui-browser.test.mjs`
- `scripts/e2e/portal-quote-authz.test.mjs`
- `.github/workflows/portal-tests.yml`

Coverage includes:

- Middleware asset injection.
- No production project reference, service-role material, or JWT-like key in the new assets.
- Accessibility landmarks, skip navigation, table semantics, focus behavior, and reduced-motion contract.
- Policy load and route simulation.
- Read-only access inspection and separation-of-duties warning.
- Generated document preview replacing the legacy print action.
- Authenticated supporting-document preview.
- Side-by-side quotation comparison.
- Same-origin document traffic.
- Confidential quotation retrieval denied when the user can see the request but lacks quote visibility.
- Quote permission RPC failure denied closed.

## 5. Changes intentionally not made

- No change to `main`.
- No merge and no conversion of PR #74 from Draft to Ready.
- No production deployment.
- No production environment or storage change.
- No application of migration `063`.
- No replacement of the existing permission keys or job model.
- No direct grant of operational approval powers to the portal administrator.
- No direct write from the new policy or access UI to protected tables.

## 6. Remaining release gates

Before production authorization, the following remain mandatory:

1. Confirm the latest code is deployed to the Cloudflare PR Preview only.
2. Prove `/api/portal-config` resolves only to isolated staging and fails closed on bad configuration.
3. Run hosted browser E2E with real staging users for requester, sector manager, procurement, committee, finance, receiver, and admin views.
4. Verify PDF and image rendering using real dummy R2 staging documents.
5. Verify generated purchase request, PO, receipt, comparison, and voucher layouts with owner-approved branding and realistic Arabic content.
6. Confirm no ordinary requester can retrieve quotation documents through direct endpoint calls.
7. Complete staging key rotation and the remaining release blockers already listed in PR #74.
8. Obtain independent final review and explicit owner release authorization.

## 7. Recommended acceptance walkthrough

Use dummy data only and perform this walkthrough on the hosted Preview:

1. Open the same purchase request as requester, procurement, finance, and admin.
2. Compare visible navigation, transaction context, tabs, values, and documents.
3. Open a supporting document and verify keyboard, fit, zoom, download, and close behavior.
4. Open three dummy quotations and compare two side by side.
5. Attempt the quotation-file URL as a requester and confirm HTTP 403.
6. Preview a generated purchase request, PO, and receipt; print each to PDF and compare the result to the preview.
7. Open Policy Studio, simulate values around every threshold, review the diff, but do not publish unless the owner explicitly authorizes the staging policy change.
8. Open Access Inspector and review all high-risk combinations before user acceptance.

## 8. Rollback

Presentation rollback:

- Remove enterprise CSS/JS injection from `functions/_middleware.js`.
- The legacy portal remains underneath and no core table migration is required for the visual rollback.

Quotation endpoint rollback must not remove the `portal_can_view_quotes` authorization check, because that check closes a confidentiality gap rather than being a visual feature.

## 9. Current certification statement

The enterprise UI implementation is present on the PR branch and covered by repository-level contract/browser tests. It is **not yet certified against the latest hosted Cloudflare Preview** and does not authorize Ready-for-review, merge, production deployment, or migration execution.

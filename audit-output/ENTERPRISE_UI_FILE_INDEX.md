# Enterprise UI File Index

## Runtime assets

- `assets/enterprise-ui.css` — visual system, responsive layout, common document/policy surfaces.
- `assets/enterprise-ui.js` — accessibility and transaction-context enhancement.
- `assets/document-studio.js` — uploaded PDF/image preview.
- `assets/generated-document-studio.css` — generated document preview styling.
- `assets/generated-document-studio.js` — purchase request/PO/receipt/voucher preview and print bridge.
- `assets/quote-document-studio.css` — quotation comparison styling.
- `assets/quote-document-studio.js` — side-by-side quotation preview.
- `assets/policy-studio.js` — versioned committee policy administration.
- `assets/access-inspector.css` — effective access inspector styling.
- `assets/access-inspector.js` — read-only permission explanation and SoD warnings.

## Integration and security

- `functions/_middleware.js` — branch portal asset injection and existing UI permission guard.
- `functions/api/portal-quote.js` — confidential quotation-file authorization.

## Automated verification

- `scripts/e2e/enterprise-ui-contract.test.mjs`
- `scripts/e2e/enterprise-ui-browser.test.mjs`
- `scripts/e2e/portal-quote-authz.test.mjs`
- `.github/workflows/portal-tests.yml`

## Evidence and owner review

- `audit-output/ENTERPRISE_UI_EXECUTION.md`
- `audit-output/ENTERPRISE_UI_ACCEPTANCE_CHECKLIST.md`
- `audit-output/ENTERPRISE_UI_RELEASE_NOTES.md`

All runtime changes are limited to the PR branch. This index does not authorize merge, production deployment, or migration execution.

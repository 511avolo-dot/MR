#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const middleware = readFileSync('functions/_middleware.js', 'utf8');
const functionalCss = readFileSync('assets/portal-functional-studios.css', 'utf8');
const generatedCss = readFileSync('assets/generated-document-studio.css', 'utf8');
const quoteCss = readFileSync('assets/quote-document-studio.css', 'utf8');
const accessCss = readFileSync('assets/access-inspector.css', 'utf8');
const docs = readFileSync('assets/document-studio.js', 'utf8');
const generated = readFileSync('assets/generated-document-studio.js', 'utf8');
const quotes = readFileSync('assets/quote-document-studio.js', 'utf8');
const policies = readFileSync('assets/policy-studio.js', 'utf8');
const access = readFileSync('assets/access-inspector.js', 'utf8');
const paymentEvidence = readFileSync('assets/payment-evidence-guard.js', 'utf8');
const portalDoc = readFileSync('functions/api/portal-doc.js', 'utf8');
const quoteEndpoint = readFileSync('functions/api/portal-quote.js', 'utf8');
const hardening = readFileSync('db/portal-migrations/p0_1i-final-release-blocker-hardening.sql', 'utf8');
const remediation = readFileSync('db/portal-migrations/p0_1j-exact-head-review-remediation.sql', 'utf8');
const independentRemediation = readFileSync('db/portal-migrations/p0_1k-independent-review-remediation.sql', 'utf8');
const cleanup = readFileSync('functions/api/portal-upload-cleanup.js', 'utf8');
const portal = readFileSync('purchase-portal.html', 'utf8');

let passed = 0;
function ok(message){ passed += 1; console.log('  ✓ ' + message); }

console.log('▶ Portal functional security contract');
assert.match(middleware, /portal-functional-studios\.css/);
assert.match(middleware, /document-studio\.js/);
assert.match(middleware, /generated-document-studio\.js/);
assert.match(middleware, /quote-document-studio\.js/);
assert.match(middleware, /policy-studio\.js/);
assert.match(middleware, /access-inspector\.js/);
assert.match(middleware, /payment-evidence-guard\.js/);
assert.doesNotMatch(middleware, /href="\/assets\/enterprise-ui\.css/);
assert.doesNotMatch(middleware, /src="\/assets\/enterprise-ui\.js/);
assert.match(functionalCss, /\.eps-launcher/);
assert.match(functionalCss, /\.eds-root/);
ok('middleware preserves the owner-approved legacy design and injects scoped functional/security tools only');

assert.match(generatedCss, /\.gds-root/);
assert.match(quoteCss, /\.qds-pane/);
assert.match(accessCss, /\.eai-shell/);
ok('functional studios retain scoped styles without replacing the portal visual shell');

assert.match(docs, /\/api\/portal-doc\?key=/);
assert.match(docs, /Authorization: 'Bearer '/);
assert.match(docs, /cache: 'no-store'/);
assert.match(docs, /URL\.revokeObjectURL/);
assert.match(docs, /aria-modal/);
assert.doesNotMatch(docs, /target=["']_blank/);
ok('document studio fetches authenticated blobs, stays in portal and revokes object URLs');

assert.match(generated, /window\.printEl = function/);
assert.match(generated, /privacySanitize/);
assert.match(generated, /طباعة \/ حفظ PDF/);
assert.match(generated, /iframe\.srcdoc/);
assert.doesNotMatch(generated, /window\.open\(/);
ok('generated documents remain in-portal and privacy-sanitized');

assert.match(quotes, /\/api\/portal-quote\?key=/);
assert.match(quotes, /window\.openQuoteViewer = open/);
assert.match(quotes, /eds-compare/);
assert.match(quotes, /URL\.revokeObjectURL/);
assert.doesNotMatch(quotes, /window\.open\(/);
assert.match(quoteEndpoint, /portal_can_view_quotes/);
assert.match(quoteEndpoint, /if \(!\(await canViewQuotes/);
ok('quotation viewer and endpoint retain confidential quote authorization');

assert.match(policies, /portal_get_committee_policy/);
assert.match(policies, /portal_committee_route/);
assert.match(policies, /portal_set_committee_policy/);
assert.doesNotMatch(policies, /\.from\(['"]portal_settings/);
ok('policy studio uses authorized RPCs and never writes settings directly');

assert.match(access, /window\.USERS/);
assert.match(access, /window\.JOBS/);
assert.match(access, /window\.accessOf/);
assert.match(access, /فصل المهام/);
assert.doesNotMatch(access, /window\.SB/);
assert.doesNotMatch(access, /\.rpc\(/);
assert.doesNotMatch(access, /\.from\(/);
ok('access inspector remains read-only');

assert.match(paymentEvidence, /portal_payment_request/);
assert.match(paymentEvidence, /portal_payment_transition/);
assert.match(paymentEvidence, /p_action==='disburse'/);
assert.match(paymentEvidence, /proof_key/);
assert.match(paymentEvidence, /pa_docUpload\('pay'/);
assert.match(paymentEvidence, /application\/pdf,image\/jpeg,image\/png/);
ok('payment request and execution RPCs are intercepted until fresh evidence is uploaded');

assert.match(portalDoc, /portal_upload_receipts/);
assert.match(portalDoc, /SHA-256/);
assert.match(portalDoc, /QUOTES_BUCKET\.delete\(key\)/);
assert.match(portalDoc, /verified_magic_bytes/);
assert.match(portalDoc, /expires_at/);
assert.match(portalDoc, /portal_effective_perm/);
assert.match(portalDoc, /loadDocumentReference/);
assert.match(portalDoc, /PAYMENT_READ_PERMS/);
assert.match(portalDoc, /RETURN_READ_PERMS/);
ok('Cloudflare upload/download requires effective permission, request scope and a normalized document reference');

assert.match(hardening, /portal_validate_upload_receipt/);
assert.match(hardening, /portal_request_document_receipt_guard/);
assert.match(hardening, /portal_payment_evidence_before/);
assert.match(hardening, /portal_payment_evidence_after/);
assert.match(hardening, /REVOKE EXECUTE ON FUNCTION public\.portal_build_po_chain/);
assert.match(hardening, /max_amount_inclusive',125000/);
assert.doesNotMatch(hardening, /mwbjoysuybgbrvfrprex/);
ok('P0-1i closes RPC, document, payment, privacy and 125k boundary blockers without production references');

assert.match(remediation, /portal_can_see_request\(p_request_id\)/);
assert.match(remediation, /portal_safe_visible_direct_expenses/);
assert.match(remediation, /portal_safe_visible_payments/);
assert.match(remediation, /verification_status = 'quarantined'/);
assert.match(remediation, /legacy_evidence_quarantined/);
assert.doesNotMatch(remediation, /\b063[_-]/);
ok('P0-1j combines scope and capability, redacts requester feeds, and quarantines untrusted legacy evidence');

assert.match(independentRemediation, /portal_direct_payment_evidence_before/);
assert.match(independentRemediation, /source_stage = 'payment_request'/);
assert.match(independentRemediation, /portal_recover_legacy_payment_evidence/);
assert.doesNotMatch(independentRemediation, /'amount', p\.amount/);
assert.doesNotMatch(independentRemediation, /\b063[_-]/);
ok('P0-1k enforces distinct verified direct-payment evidence, status-only feeds and controlled legacy recovery');

assert.match(cleanup, /vpfnycxzqziltsnzxbpb/);
assert.match(cleanup, /aldeyabi-quotes-staging/);
assert.match(cleanup, /MAX_EXPIRED_RECEIPTS = 50/);
assert.match(cleanup, /MAX_LIST_PAGES = 2/);
assert.match(cleanup, /page\.truncated/);
assert.match(cleanup, /page\.cursor/);
assert.match(cleanup, /nextCursor/);
assert.match(cleanup, /normalizeCursor/);
assert.doesNotMatch(cleanup, /mwbjoysuybgbrvfrprex/);
ok('cleanup is bounded, paginated and hard-locked to the approved staging resources');

assert.match(portal, /createDirect:!!p\.can_create_direct_expense/);
assert.match(portal, /pa_mergePerms/);
assert.match(portal, /portal_safe_visible_direct_expenses/);
assert.match(portal, /portal_safe_visible_payments/);
assert.match(portal, /d\.verification==='verified'/);
assert.match(portal, /pa_recoverLegacyEvidence/);
ok('portal consumes job-aware direct permission, safe requester feeds and verified-document state');

const combined = [middleware, functionalCss, generatedCss, quoteCss, accessCss, docs, generated, quotes, policies, access, paymentEvidence, portalDoc, hardening, remediation, independentRemediation, cleanup].join('\n');
assert.doesNotMatch(combined, /mwbjoysuybgbrvfrprex/);
assert.doesNotMatch(combined, /eyJ[a-zA-Z0-9_-]{20,}\./);
ok('changed runtime/security assets contain no production project reference or JWT-like secret');

console.log(`\nPortal functional security contract: ${passed} checks passed.`);

#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const middleware = readFileSync('functions/_middleware.js', 'utf8');
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

let passed = 0;
function ok(message){ passed += 1; console.log('  ✓ ' + message); }

console.log('▶ Portal functional security contract');
assert.match(middleware, /document-studio\.js/);
assert.match(middleware, /generated-document-studio\.js/);
assert.match(middleware, /quote-document-studio\.js/);
assert.match(middleware, /policy-studio\.js/);
assert.match(middleware, /access-inspector\.js/);
assert.match(middleware, /payment-evidence-guard\.js/);
assert.doesNotMatch(middleware, /href="\/assets\/enterprise-ui\.css/);
assert.doesNotMatch(middleware, /src="\/assets\/enterprise-ui\.js/);
ok('middleware preserves the owner-approved legacy design and injects functional/security tools only');

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
assert.match(paymentEvidence, /proof_key/);
assert.match(paymentEvidence, /pa_docUpload/);
assert.match(paymentEvidence, /application\/pdf,image\/jpeg,image\/png/);
ok('every legacy UI payment request is intercepted until evidence is uploaded');

assert.match(portalDoc, /portal_upload_receipts/);
assert.match(portalDoc, /SHA-256/);
assert.match(portalDoc, /QUOTES_BUCKET\.delete\(key\)/);
assert.match(portalDoc, /verified_magic_bytes/);
assert.match(portalDoc, /expires_at/);
ok('Cloudflare registers a short-lived trusted receipt only after an R2 write and cleans up on DB failure');

assert.match(hardening, /portal_validate_upload_receipt/);
assert.match(hardening, /portal_request_document_receipt_guard/);
assert.match(hardening, /portal_payment_evidence_before/);
assert.match(hardening, /portal_payment_evidence_after/);
assert.match(hardening, /REVOKE EXECUTE ON FUNCTION public\.portal_build_po_chain/);
assert.match(hardening, /max_amount_inclusive',125000/);
assert.doesNotMatch(hardening, /mwbjoysuybgbrvfrprex/);
ok('P0-1i closes RPC, document, payment, privacy and 125k boundary blockers without production references');

const combined = [middleware, generatedCss, quoteCss, accessCss, docs, generated, quotes, policies, access, paymentEvidence, portalDoc, hardening].join('\n');
assert.doesNotMatch(combined, /mwbjoysuybgbrvfrprex/);
assert.doesNotMatch(combined, /eyJ[a-zA-Z0-9_-]{20,}\./);
ok('changed runtime/security assets contain no production project reference or JWT-like secret');

console.log(`\nPortal functional security contract: ${passed} checks passed.`);

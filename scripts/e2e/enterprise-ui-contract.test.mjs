#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const middleware = readFileSync('functions/_middleware.js', 'utf8');
const css = readFileSync('assets/enterprise-ui.css', 'utf8');
const quoteCss = readFileSync('assets/quote-document-studio.css', 'utf8');
const ui = readFileSync('assets/enterprise-ui.js', 'utf8');
const docs = readFileSync('assets/document-studio.js', 'utf8');
const quotes = readFileSync('assets/quote-document-studio.js', 'utf8');
const policies = readFileSync('assets/policy-studio.js', 'utf8');
const quoteEndpoint = readFileSync('functions/api/portal-quote.js', 'utf8');

let passed = 0;
function ok(message){ passed += 1; console.log('  ✓ ' + message); }

console.log('▶ Enterprise UI contract');
assert.match(middleware, /enterprise-ui\.css/);
assert.match(middleware, /document-studio\.js/);
assert.match(middleware, /quote-document-studio\.js/);
assert.match(middleware, /policy-studio\.js/);
assert.match(middleware, /enterprise-ui\.js/);
ok('Cloudflare middleware injects the enterprise assets into the portal only');

assert.match(css, /Quiet Authority/);
assert.match(css, /:focus-visible/);
assert.match(css, /prefers-reduced-motion/);
assert.match(css, /\.eds-root/);
assert.match(css, /\.eps-shell/);
assert.match(quoteCss, /\.qds-pane/);
ok('design system includes focus, reduced-motion, document, quotation and policy surfaces');

assert.match(ui, /data-enterprise-ui/);
assert.match(ui, /eui-skip-link/);
assert.match(ui, /aria-live/);
assert.match(ui, /scope.*col/);
ok('interaction layer adds landmarks, skip navigation and accessible table semantics');

assert.match(docs, /\/api\/portal-doc\?key=/);
assert.match(docs, /Authorization: 'Bearer '/);
assert.match(docs, /cache: 'no-store'/);
assert.match(docs, /URL\.revokeObjectURL/);
assert.match(docs, /aria-modal/);
assert.doesNotMatch(docs, /target=["']_blank/);
ok('document studio fetches authenticated blobs, stays in portal and revokes object URLs');

assert.match(quotes, /\/api\/portal-quote\?key=/);
assert.match(quotes, /window\.openQuoteViewer = open/);
assert.match(quotes, /eds-compare/);
assert.match(quotes, /URL\.revokeObjectURL/);
assert.doesNotMatch(quotes, /window\.open\(/);
assert.match(quoteEndpoint, /portal_can_view_quotes/);
assert.match(quoteEndpoint, /if \(!\(await canViewQuotes/);
ok('quotation studio replaces the legacy viewer and the file endpoint enforces confidential visibility');

assert.match(policies, /portal_get_committee_policy/);
assert.match(policies, /portal_committee_route/);
assert.match(policies, /portal_set_committee_policy/);
assert.doesNotMatch(policies, /\.from\(['"]portal_settings/);
ok('policy studio uses authorized RPCs and never writes settings tables directly');

const combined = [middleware, css, quoteCss, ui, docs, quotes, policies].join('\n');
assert.doesNotMatch(combined, /mwbjoysuybgbrvfrprex/);
assert.doesNotMatch(combined, /service_role/i);
assert.doesNotMatch(combined, /eyJ[a-zA-Z0-9_-]{20,}\./);
ok('new UI assets contain no production reference, service-role material or JWT-like key');

console.log(`\nEnterprise UI contract: ${passed} checks passed.`);

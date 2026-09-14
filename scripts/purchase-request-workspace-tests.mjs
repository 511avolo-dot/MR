import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
const redirect = fs.readFileSync(path.join(ROOT, 'requests.html'), 'utf8');
const sql = fs.readFileSync(path.join(ROOT, 'db/system2-purchase-request-workspace.sql'), 'utf8');
const invite = fs.readFileSync(path.join(ROOT, 'functions/api/staff-invite.js'), 'utf8');
const usersApi = fs.readFileSync(path.join(ROOT, 'functions/api/admin-users.js'), 'utf8');
const docsApi = fs.readFileSync(path.join(ROOT, 'functions/api/pr-doc.js'), 'utf8');
let passed = 0;
function test(name, condition) { if (!condition) throw new Error(`FAIL: ${name}`); passed++; console.log(`✓ ${name}`); }

// The launch module lives in the main system and the historical URL only redirects.
test('purchase request workspace is integrated in index', /async function renderPRPortal\(\)/.test(html) && /id="pr-root"/.test(html));
test('standalone request page redirects into the main system', /location\.replace\('\/'\+location\.search\+location\.hash\)/.test(redirect));
test('email deep link opens a request detail in the main module', /function openDeepLink\(\)/.test(html) && /prGoView\('track', pr\)/.test(html));
test('two approval gates are visible in the module', /مسار الاعتماد والقرارات/.test(html) && /بانتظار اعتمادي/.test(html));
test('approval actions use the guarded decision RPC', /async function prAct[\s\S]{0,900}rpc\('pr_decide'/.test(html));
test('request save is one atomic RPC', /async function prSaveCloud[\s\S]{0,900}rpc\('pr_save_request'/.test(html));
test('main module has no direct request-table mutation', !/from\('proc_purchase_requests'\)[\s\S]{0,120}\.(?:insert|update|delete|upsert)\(/.test(html));
test('main module has no direct item-table mutation', !/from\('proc_pr_items'\)[\s\S]{0,120}\.(?:insert|update|delete|upsert)\(/.test(html));
test('RFQ relation uses a guarded RPC', /rpc\('pr_attach_rfq'/.test(html));
test('award approval compatibility uses guarded RPCs', /rpc\('pr_submit_award_request'/.test(html) && /rpc\('pr_decide_award_request'/.test(html));
test('PO relation supports allocations and many links', /rpc\('pr_link_purchase_order'/.test(html) && /data-pralloc/.test(html) && /pr\.po_links/.test(html));
test('registered documents and audit are loaded with the request', /proc_pr_attachments/.test(html) && /proc_pr_audit/.test(html) && /p\.attachments=/.test(html));
test('new attachments are registered by the R2 endpoint only', /X-File-Name/.test(html) && !/rpc\('pr_set_doc'/.test(html));
test('staff onboarding is a personal profile invitation', /id="si-department"/.test(html) && /id="si-profile"/.test(html) && /profile_key:profileKey/.test(html));
test('user management exposes module profile and department', /id="uf-pr-profile"/.test(html) && /id="uf-pr-department"/.test(html) && /adminUsersCall\('setProfile'/.test(html));
test('profile permissions are reflected in the live session', /proc_pr_permission_profiles/.test(html) && /legacyFromModule/.test(html) && /prProfileKey/.test(html));
test('financial values still pass through central masking', /fmtPrice\(p\.est_total\)/.test(html) && /function canViewAmounts/.test(html));

// Database safety and behavior contracts.
test('migration defines five permission profiles', ['requester','maintenance_manager','procurement_officer','procurement_manager','module_admin'].every(x => sql.includes(`('${x}'`)));
test('migration defines the two required approval gates', /'maintenance_need'/.test(sql) && /'procurement_pricing'/.test(sql));
test('server generates request numbers inside atomic save', /v_id := pr_next_number\(\)/.test(sql));
test('canonical project validation fails closed', /WHEN NOT EXISTS \(SELECT 1 FROM registry\) THEN false/.test(sql));
test('many-to-many PO model and over-allocation guard exist', /CREATE TABLE IF NOT EXISTS proc_pr_po_links/.test(sql) && /CREATE TABLE IF NOT EXISTS proc_pr_item_allocations/.test(sql) && /الكمية الموزّعة تتجاوز/.test(sql));
test('direct request mutations are revoked', /REVOKE INSERT, UPDATE, DELETE ON proc_purchase_requests/.test(sql));
test('restrictive lockdown policies are preserved', /permissive='PERMISSIVE'/.test(sql));
test('existing unscoped office amount visibility is preserved', /jsonb_array_length\(CASE WHEN jsonb_typeof\(scope_sectors\)/.test(sql) && /pr_view_financials":true/.test(sql));
test('legacy permission helpers map into module profiles', /WHEN 'can_create_pr'\s+THEN pr_has_module_perm\('pr_create'\)/.test(sql) && /WHEN 'can_comment'\s+THEN pr_has_module_perm\('pr_comment'\)/.test(sql));
test('award and RFQ compatibility mutations are server guarded', /CREATE OR REPLACE FUNCTION pr_attach_rfq/.test(sql) && /CREATE OR REPLACE FUNCTION pr_submit_award_request/.test(sql) && /CREATE OR REPLACE FUNCTION pr_decide_award_request/.test(sql));
test('helper RPCs are not anonymous', /REVOKE ALL ON FUNCTION pr_effective_permissions\(text\)[\s\S]*FROM PUBLIC, anon/.test(sql));

test('v3 office invitations do not create a field scope', /Number\(p\.v\) >= 3 \? \[\]/.test(invite));
test('invite profile is server allowlisted', /INVITE_PROFILES\.has\(profileKey\)/.test(invite));
test('admin API allowlists module permissions and profiles', /MODULE_PERMISSIONS/.test(usersApi) && /MODULE_PROFILES/.test(usersApi));
test('document endpoint compensates a failed registration', /await registerAttachment/.test(docsApi) && /await bucket\.delete\(key\)/.test(docsApi));

console.log(`\n${passed} integrated purchase-request workspace checks passed.`);

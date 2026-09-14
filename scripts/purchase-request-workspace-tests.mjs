import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const html = fs.readFileSync(path.join(ROOT, 'requests.html'), 'utf8');
const sql = fs.readFileSync(path.join(ROOT, 'db/system2-purchase-request-workspace.sql'), 'utf8');
const invite = fs.readFileSync(path.join(ROOT, 'functions/api/staff-invite.js'), 'utf8');
const usersApi = fs.readFileSync(path.join(ROOT, 'functions/api/admin-users.js'), 'utf8');
const docsApi = fs.readFileSync(path.join(ROOT, 'functions/api/pr-doc.js'), 'utf8');
let passed = 0;

function test(name, condition) {
  if (!condition) throw new Error(`FAIL: ${name}`);
  passed += 1;
  console.log(`✓ ${name}`);
}

const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
test('inline application script exists', scripts.length === 1 && scripts[0].length > 1000);
new vm.Script(scripts[0], { filename: 'requests.inline.js' });
test('purchase request UI JavaScript parses', true);

test('workspace is the default module view', /VIEW='workspace'/.test(html));
test('workspace keeps a visible route back to the core procurement system', /العودة إلى نظام المشتريات الأساسي/.test(html) && /location\.href='index\.html'/.test(html));
test('enterprise work queue and request pane exist', /class="workbench"/.test(html) && /class="queue-pane"/.test(html) && /class="request-pane"/.test(html));
test('request detail exposes collaboration and PO relations', /المناقشات/.test(html) && /أوامر الشراء/.test(html) && /proc_pr_po_links/.test(html));
test('request dossier exposes registered multi-document history', /المستندات/.test(html) && /proc_pr_attachments/.test(html) && /uploadAttachment/.test(html));
test('legacy R2 request documents remain visible in the dossier', /p\.doc_key&&!p\.attachments\.some/.test(html) && /id:'legacy:'\+p\.id/.test(html));
test('financial values are permission masked', /can\('pr_view_financials'\)\?fmt\(po\.total\).*'••••••'/.test(html));
test('project is selected from the canonical registry', /projects_registry/.test(html) && /id="f-project"><select/.test(html) === false && /<select class="select" id="f-project">/.test(html));
test('request save is one atomic RPC', /rpc\('pr_save_request'/.test(html) && !/from\('proc_purchase_requests'\)\.upsert\(pr\)/.test(html));
test('decisions use the launch state machine RPC', /rpc\('pr_decide'/.test(html));
test('staff onboarding uses a personal invitation', /\/api\/staff-invite/.test(html) && /profile_key/.test(html) && !/id="u-pass"|id="nu-pass"/.test(html));
test('public self-registration stays removed', !/portal-signup|\?signup|showSignup|id="signup"/.test(html));
test('reference sources fail independently', /Promise\.allSettled/.test(html) && /settled\[i\]\.status==='fulfilled'/.test(html));

test('migration defines five permission profiles', ['requester','maintenance_manager','procurement_officer','procurement_manager','module_admin'].every((x) => sql.includes(`('${x}'`)));
test('migration defines the two required approval gates', /'maintenance_need'/.test(sql) && /'procurement_pricing'/.test(sql));
test('server generates request numbers inside atomic save', /v_id := pr_next_number\(\)/.test(sql));
test('canonical project validation fails closed without a registry', /WHEN NOT EXISTS \(SELECT 1 FROM registry\) THEN false/.test(sql) && /jsonb_array_length[\s\S]*THEN false/.test(sql));
test('server derives department sector and requester identity', /SELECT d\.name_ar,d\.sector INTO v_department,v_sector/.test(sql) && /SELECT coalesce\(nullif\(btrim\(u\.display_name\)/.test(sql));
test('request payload size and text fields are bounded', /jsonb_array_length\(coalesce\(p_items/.test(sql) && />200/.test(sql) && /length\(v_title\)>200/.test(sql));
test('procurement visibility does not permit editing another requester draft', /pr_has_module_perm\('pr_manage_users'\) OR pr_is_admin\(\)/.test(sql) && !/v_existing\.requester[\s\S]{0,160}pr_view_all/.test(sql));
test('many-to-many PO link has no unique constraint on PO alone', /CREATE TABLE IF NOT EXISTS proc_pr_po_links/.test(sql) && !/UNIQUE\s*\(po_number\)/i.test(sql));
test('line allocations prevent over-allocation', /الكمية الموزّعة تتجاوز الكمية المطلوبة/.test(sql));
test('replacing an allocation excludes its previous quantities', /v_link IS NULL OR l\.id<>v_link/.test(sql) && /FOR UPDATE/.test(sql));
test('R2 attachment registration is permissioned and append-only', /CREATE OR REPLACE FUNCTION pr_register_attachment/.test(sql) && /pr_upload_attachments/.test(sql));
test('module tables deny direct mutations', /REVOKE INSERT, UPDATE, DELETE ON proc_purchase_requests/.test(sql) && /pr_request_update_deny/.test(sql));
test('department and workflow deletion is denied in favor of deactivation', /pr_department_delete_deny/.test(sql) && /pr_rule_delete_deny/.test(sql) && /update\(\{active:false\}\)/.test(html));
test('department and workflow writes require workflow administration', /pr_department_insert[\s\S]*pr_has_module_perm\('pr_manage_workflows'\)/.test(sql) && /pr_rule_update[\s\S]*pr_has_module_perm\('pr_manage_workflows'\)/.test(sql));
test('request visibility is enforced server-side', /CREATE OR REPLACE FUNCTION pr_can_view_request/.test(sql) && /pr_request_select/.test(sql));
test('decision delegation requires an active delegate with the stage permission', /EXISTS\(SELECT 1 FROM proc_users d[\s\S]*pr_effective_permissions\(d\.username\)->>v_step\.role_key/.test(sql));
test('requester cannot approve their own request', /لا يجوز لمقدم الطلب اعتماد طلبه/.test(sql));
test('helper RPCs are not executable by anonymous callers', /REVOKE ALL ON FUNCTION pr_effective_permissions\(text\)[\s\S]*FROM PUBLIC, anon/.test(sql));

test('invite token signs department and profile', /d: departmentId/.test(invite) && /pk: profileKey/.test(invite));
test('invite profile is validated by a server allowlist', /INVITE_PROFILES\.has\(profileKey\)/.test(invite));
test('admin API allowlists module permission keys', /MODULE_PERMISSIONS/.test(usersApi) && /cleanPermissionObject/.test(usersApi));
test('module administration never promotes an invited user to system admin', /role: 'user', permissions: \{\}/.test(invite) && /mayGrantModuleAdmin/.test(invite));
test('user management enforces caller and target privilege hierarchy', /callerIsSystemAdmin/.test(usersApi) && /mayMutateTarget/.test(usersApi));
test('user creation validates privilege before creating an Auth account', usersApi.indexOf("if (role === 'admin'") < usersApi.indexOf('const r = await api.createAuthUser'));
test('document API compensates failed database registration', /await registerAttachment/.test(docsApi) && /await bucket\.delete\(key\)/.test(docsApi));
test('document download requires an authoritative database reference', /attachmentIsRegistered/.test(docsApi) && /المرفق غير مسجّل على الطلب/.test(docsApi));
test('document API rejects declared oversized bodies before buffering', /headers\.get\('content-length'\)/.test(docsApi) && /declaredLength > MAX_UPLOAD_BYTES/.test(docsApi));

console.log(`\n${passed} purchase-request workspace checks passed.`);

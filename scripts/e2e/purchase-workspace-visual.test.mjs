import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { pathToFileURL, fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const playwrightPath = 'C:/Users/mo_al/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs';
const { chromium } = await import(pathToFileURL(playwrightPath).href);
const outDir = path.join(os.tmpdir(), 'aldeyabi-purchase-workspace-visual-qa');
fs.mkdirSync(outDir, { recursive: true });

const profiles = [
  {profile_key:'requester',name_ar:'مقدّم طلب',sort_order:10,active:true,permissions:{pr_create:true,pr_view_own:true,pr_comment:true,pr_upload_attachments:true,pr_print:true}},
  {profile_key:'maintenance_manager',name_ar:'مدير الصيانة والتشغيل',sort_order:20,active:true,permissions:{pr_view_department:true,pr_approve_maintenance:true,pr_comment:true,pr_upload_attachments:true,pr_print:true}},
  {profile_key:'procurement_officer',name_ar:'موظف مشتريات',sort_order:30,active:true,permissions:{pr_view_all:true,pr_manage_pricing:true,pr_link_purchase_orders:true,pr_view_financials:true,pr_comment:true,pr_upload_attachments:true,pr_print:true}},
  {profile_key:'procurement_manager',name_ar:'مدير المشتريات',sort_order:40,active:true,permissions:{pr_view_all:true,pr_authorize_pricing:true,pr_manage_pricing:true,pr_link_purchase_orders:true,pr_view_financials:true,pr_comment:true,pr_upload_attachments:true,pr_print:true}},
  {profile_key:'module_admin',name_ar:'مدير موديل طلبات الشراء',sort_order:50,active:true,permissions:{pr_create:true,pr_view_own:true,pr_view_department:true,pr_view_all:true,pr_comment:true,pr_upload_attachments:true,pr_print:true,pr_approve_maintenance:true,pr_authorize_pricing:true,pr_manage_pricing:true,pr_link_purchase_orders:true,pr_view_financials:true,pr_manage_users:true}}
];
const now = new Date().toISOString();
const fixtures = {
  proc_users:[{username:'qa.admin',display_name:'مدير المشتريات',email:'qa.admin@aldeyabi.com',role:'admin',active:true,department_id:'DEP-MAINT',mobile:'0500000000',pr_profile_key:'module_admin',pr_permission_overrides:{},permissions:{}}],
  proc_departments:[{id:'DEP-MAINT',name_ar:'إدارة الصيانة والتشغيل',manager_user:'maint.manager',sector:'الصيانة والتشغيل',active:true}],
  proc_approval_rules:[],proc_pr_permission_profiles:profiles,
  proc_settings:[{key:'projects_registry',value:{version:1,projects:[{id:'PRJ-HQ',name:'مشروع المقر الرئيسي',code:'HQ',active:true}]}},{key:'portal_settings',value:{sla_days:3,email_on:true}}],
  proc_purchase_orders:[{po_number:'PO-2026-0142',project:'مشروع المقر الرئيسي',supplier:'شركة الإمداد المتقدم',status:'صادر',total:18450,created_at:now}],
  proc_purchase_requests:[
    {id:'PR-DG2026-0148',title:'قطع غيار وحدات التكييف',department_id:'DEP-MAINT',department:'إدارة الصيانة والتشغيل',project:'مشروع المقر الرئيسي',requester:'ops.employee',requester_name:'خالد العتيبي',requester_mobile:'0501234567',priority:'عالي',needed_by:'2026-09-20',status:'in_review',workflow_state:'procurement_review',current_seq:2,revision:2,created_at:'2026-09-10T08:00:00Z',updated_at:now},
    {id:'PR-DG2026-0147',title:'مواد صيانة كهربائية',department_id:'DEP-MAINT',department:'إدارة الصيانة والتشغيل',project:'مشروع المقر الرئيسي',requester:'ops.employee',requester_name:'سالم الحربي',priority:'متوسط',status:'approved',workflow_state:'partially_ordered',revision:1,created_at:'2026-09-08T08:00:00Z',updated_at:now}
  ],
  proc_pr_items:[
    {id:101,pr_id:'PR-DG2026-0148',seq:1,description:'فلتر تكييف مركزي',unit:'حبة',requested_qty:12},{id:102,pr_id:'PR-DG2026-0148',seq:2,description:'سير ضاغط',unit:'حبة',requested_qty:6},
    {id:103,pr_id:'PR-DG2026-0147',seq:1,description:'قاطع كهربائي 63 أمبير',unit:'حبة',requested_qty:10}
  ],
  proc_pr_approvals:[
    {id:1,pr_id:'PR-DG2026-0148',seq:1,stage_key:'maintenance_need',stage_label:'اعتماد الحاجة — مدير الصيانة والتشغيل',approver:'maint.manager',decision:'approved',acted_at:'2026-09-11T09:10:00Z',comment:'الحاجة معتمدة'},
    {id:2,pr_id:'PR-DG2026-0148',seq:2,stage_key:'procurement_pricing',stage_label:'إذن بدء التسعير — مدير المشتريات',approver:'qa.admin',decision:'pending'}
  ],
  proc_pr_messages:[{id:1,pr_id:'PR-DG2026-0148',author:'maint.manager',author_name:'مدير الصيانة',body:'يرجى التأكد من توافق السير مع الوحدة رقم 4.',created_at:'2026-09-11T09:12:00Z'}],
  proc_pr_attachments:[{id:11,pr_id:'PR-DG2026-0148',object_key:'docs/pr/PR-DG2026-0148/spec.png',file_name:'المخطط الفني.png',kind:'technical',content_type:'image/png',size_bytes:64211,uploaded_by:'ops.employee',created_at:'2026-09-11T09:20:00Z',deleted_at:null}],
  proc_pr_po_links:[{id:21,pr_id:'PR-DG2026-0147',po_number:'PO-2026-0142',note:'توريد جزئي',linked_by:'buyer1',linked_at:'2026-09-12T10:00:00Z',active:true}],
  proc_pr_item_allocations:[{id:31,link_id:21,pr_item_id:103,allocated_qty:6,created_by:'buyer1'}],
  proc_pr_audit:[{id:1,pr_id:'PR-DG2026-0148',event:'submitted',actor:'خالد العتيبي',channel:'portal',detail:{},created_at:'2026-09-10T08:00:00Z',seq:1}]
};

const init = ({ fixtures, profiles }) => {
  const clone = (x) => JSON.parse(JSON.stringify(x));
  class Query {
    constructor(table){this.table=table;this.filters=[];this.one=false;}
    select(){return this;} order(){return this;} limit(){return this;} range(){return this;}
    eq(k,v){this.filters.push([k,v]);return this;} is(k,v){this.filters.push([k,v]);return this;} ilike(k,v){this.filters.push([k,String(v).toLowerCase()]);return this;}
    in(k,v){this.filters.push([k,new Set(v)]);return this;}
    maybeSingle(){this.one=true;return this._run();}
    _rows(){return clone(fixtures[this.table]||[]).filter(r=>this.filters.every(([k,v])=>v instanceof Set?v.has(r[k]):v===null?r[k]==null:String(r[k]??'').toLowerCase()===String(v).toLowerCase()));}
    _run(){const rows=this._rows();return Promise.resolve({data:this.one?(rows[0]||null):rows,error:null});}
    then(ok,bad){return this._run().then(ok,bad);}
  }
  const client={
    auth:{getSession:async()=>({data:{session:{access_token:'fixture',user:{email:'qa.admin@aldeyabi.com'}}}}),signOut:async()=>({})},
    from:(t)=>new Query(t),
    rpc:async(name)=>name==='pr_effective_permissions'?{data:profiles.find(x=>x.profile_key==='module_admin').permissions,error:null}:{data:{ok:true},error:null}
  };
  window.supabase={createClient:()=>client};
};

const browser = await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});
try {
  const page = await browser.newPage({viewport:{width:1440,height:1000},deviceScaleFactor:1});
  const errors=[];page.on('pageerror',(e)=>errors.push(e.message));
  await page.addInitScript(init,{fixtures,profiles});
  await page.goto(pathToFileURL(path.join(ROOT,'requests.html')).href,{waitUntil:'domcontentloaded'});
  await page.waitForSelector('.workbench');
  assert.equal(errors.length,0,errors.join('\n'));
  const desktop = await page.locator('.workbench').boundingBox();
  assert.ok(desktop.width>1200 && desktop.height>600,'desktop workspace does not use available space');
  assert.equal(await page.locator('.queue-card').count(),2);
  assert.match(await page.locator('.request-pane').innerText(),/إذن بدء التسعير/);
  await page.getByRole('button',{name:/المستندات/}).click();
  assert.match(await page.locator('.request-pane').innerText(),/المخطط الفني/);
  await page.getByRole('button',{name:/أوامر الشراء/}).click();
  assert.match(await page.locator('.request-pane').innerText(),/علاقة متعدد إلى متعدد/);
  await page.screenshot({path:path.join(outDir,'purchase-workspace-desktop.png'),fullPage:true});

  await page.setViewportSize({width:390,height:844});
  await page.getByRole('button',{name:/الملخص والبنود/}).click();
  const overflow = await page.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth);
  assert.ok(overflow<=1,`mobile horizontal overflow: ${overflow}px`);
  assert.ok((await page.locator('.queue-pane').boundingBox()).height<=400,'mobile queue should stay compact');
  await page.screenshot({path:path.join(outDir,'purchase-workspace-mobile.png'),fullPage:true});
  console.log('✓ desktop workspace layout');
  console.log('✓ request document and PO relation tabs');
  console.log('✓ mobile layout has no page overflow');
  console.log(`✓ screenshots: ${outDir}`);
} finally {
  await browser.close();
}

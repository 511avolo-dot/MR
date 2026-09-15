import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { resolveChromiumExecutable } from './chromium-path.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const playwrightPath = 'C:/Users/mo_al/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs';
let chromium;
try{
  ({chromium}=await import('playwright'));
}catch(primaryError){
  if(!fs.existsSync(playwrightPath)) throw primaryError;
  ({chromium}=await import(pathToFileURL(playwrightPath).href));
}
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
    {id:'PR-DG2026-0147',title:'مواد صيانة كهربائية',department_id:'DEP-MAINT',department:'إدارة الصيانة والتشغيل',project:'مشروع المقر الرئيسي',requester:'ops.employee',requester_name:'سالم الحربي',priority:'متوسط',status:'approved',workflow_state:'partially_ordered',revision:1,created_at:'2026-09-08T08:00:00Z',updated_at:now},
    // مؤرشَف: أُقفِل باستلام كامل لأمر شرائه — يخرج من الطابور ويظهر في وضع «الأرشيف»
    {id:'PR-DG2026-0140',title:'أدوات سباكة',department_id:'DEP-MAINT',department:'إدارة الصيانة والتشغيل',project:'مشروع المقر الرئيسي',requester:'ops.employee',requester_name:'ماجد الشمري',priority:'عادي',status:'closed',workflow_state:'closed',proc_status:'closed',revision:1,closed_at:'2026-09-13T08:00:00Z',archived_at:'2026-09-13T08:00:00Z',created_at:'2026-09-01T08:00:00Z',updated_at:'2026-09-13T08:00:00Z'}
  ],
  proc_pr_items:[
    {id:101,pr_id:'PR-DG2026-0148',seq:1,description:'فلتر تكييف مركزي',unit:'حبة',requested_qty:12},{id:102,pr_id:'PR-DG2026-0148',seq:2,description:'سير ضاغط',unit:'حبة',requested_qty:6},
    {id:103,pr_id:'PR-DG2026-0147',seq:1,description:'قاطع كهربائي 63 أمبير',unit:'حبة',requested_qty:10}
  ],
  /* ⚠️ الإصدار 1 محفوظ عمداً: بعد إصلاح 2026-09-15 لم تعُد إعادة الإرسال تمحو
     صفّ الإعادة، فالسلسلة تحمل تاريخ الدورة السابقة إلى جانب الدورة الجارية.
     و`approver_name` مخزَّن على الصفّ — هو ما يجعل سير العمل والمحضر يعرضان
     اسم الشخص لا اسم المستخدم (بلاغ المالك). */
  proc_pr_approvals:[
    {id:9,pr_id:'PR-DG2026-0148',revision:1,seq:1,stage_key:'maintenance_need',stage_label:'اعتماد الحاجة — مدير الصيانة والتشغيل',approver:'maint.manager',approver_name:'م. فهد القحطاني',decision:'returned',acted_at:'2026-09-10T12:00:00Z',comment:'الكميات تحتاج مراجعة'},
    {id:1,pr_id:'PR-DG2026-0148',revision:2,seq:1,stage_key:'maintenance_need',stage_label:'اعتماد الحاجة — مدير الصيانة والتشغيل',approver:'maint.manager',approver_name:'م. فهد القحطاني',decision:'approved',acted_at:'2026-09-11T09:10:00Z',comment:'الحاجة معتمدة'},
    {id:2,pr_id:'PR-DG2026-0148',revision:2,seq:2,stage_key:'procurement_pricing',stage_label:'إذن بدء التسعير — مدير المشتريات',approver:'qa.admin',approver_name:'مدير المشتريات',decision:'pending'}
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
  window.__visualClient=client;
  window.supabase={createClient:()=>client};
};

const mime={'.html':'text/html; charset=utf-8','.js':'application/javascript; charset=utf-8','.mjs':'application/javascript; charset=utf-8','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.webmanifest':'application/manifest+json'};
const server=http.createServer((req,res)=>{
  const rel=decodeURIComponent(new URL(req.url,'http://localhost').pathname).replace(/^\/+/, '')||'index.html';
  const file=path.resolve(ROOT,rel);
  if(!file.startsWith(ROOT+path.sep)){res.writeHead(403);res.end('forbidden');return;}
  fs.readFile(file,(error,data)=>{
    if(error){res.writeHead(404);res.end('not found');return;}
    res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream','Cache-Control':'no-store'});
    res.end(data);
  });
});
await new Promise((resolve,reject)=>server.listen(0,'127.0.0.1',resolve).once('error',reject));
const origin=`http://127.0.0.1:${server.address().port}`;

const executablePath=resolveChromiumExecutable();
const browser = await chromium.launch(executablePath?{headless:true,executablePath}:{headless:true});
try {
  const page = await browser.newPage({viewport:{width:1440,height:1000},deviceScaleFactor:1});
  const errors=[];page.on('pageerror',(e)=>errors.push(e.message));
  await page.addInitScript(init,{fixtures,profiles});
  await page.goto(`${origin}/index.html`,{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>typeof window.renderPRPortal==='function');
  await page.evaluate(async ({fixtures})=>{
    STATE.currentUser={username:'qa.admin',displayName:'مدير المشتريات',role:'admin',permissions:{},prProfileKey:'module_admin'};
    STATE.purchaseOrders=fixtures.proc_purchase_orders;
    CLOUD.enabled=true; CLOUD.client=window.__visualClient;
    try{ hideLoginScreen(); }catch(_){}
    try{ navigate('pr'); }catch(_){}
    __prLoaded=false; STATE.prView='list';
    await renderPRPortal();
  },{fixtures});
  await page.waitForSelector('.pr-workspace');
  assert.equal(errors.length,0,errors.join('\n'));
  const desktop = await page.locator('#page-pr').boundingBox();
  assert.ok(desktop.width>800 && desktop.height>450,`integrated workspace is unexpectedly small: ${JSON.stringify(desktop)}`);
  assert.equal(await page.locator('.pr-work-grid').count(),1);
  assert.equal(await page.locator('.pr-work-rail').count(),1);
  assert.equal(await page.locator('.pr-work-request').count(),2);
  assert.equal(await page.locator('.pr-work-stat').count(),6);// +المشروع/الجهة

  // ── اسم المشروع في البطاقة الجانبية (بلاغ المالك 2026-09-15) ──
  const cardProj = await page.locator('.pr-work-request-proj').first().innerText();
  assert.match(cardProj,/مشروع المقر الرئيسي/,'البطاقة الجانبية بلا اسم المشروع');

  await page.locator('.pr-work-request',{hasText:'PR-DG2026-0148'}).click();
  assert.match(await page.locator('#pr-root').innerText(),/إذن بدء التسعير/);
  assert.match(await page.locator('#pr-root').innerText(),/المخطط الفني/);

  // ── الأسماء: سير العمل يعرض اسم الشخص لا اسم المستخدم ──
  const flowText = await page.locator('.prw-flow').innerText();
  assert.match(flowText,/م\. فهد القحطاني/,'سير العمل يعرض اسم المستخدم بدل الاسم');
  assert.ok(!/maint\.manager/.test(flowText),'اسم المستخدم ما زال يتسرّب لسير العمل');
  // و«المسؤول الحالي» يُسمّى بشخصه
  assert.match(await page.locator('.pr-work-next').innerText(),/مدير المشتريات/,'المسؤول الحالي بلا اسم');
  // ولا يعرض المسار قرار دورة منتهية: الإصدار الجاري وحده (returned من إصدار 1 مستبعَد)
  assert.ok(!/أُعيد للاستكمال/.test(flowText),'مسار الإصدار الجاري يعرض قرار دورة سابقة');
  // وشريط الملخّص يحمل المشروع
  assert.match(await page.locator('.pr-work-summary').innerText(),/مشروع المقر الرئيسي/,'شريط الملخّص بلا المشروع');

  // ── الاتجاه: مسار سير العمل يبدأ من اليمين فعلاً (لا من نهايته) ──
  // ⚠️ اصطلاح `scrollLeft` في حاوية RTL يختلف بين المحرّكات؛ القياس هنا على
  //    **موضع أوّل عقدة** لا على قيمة scrollLeft، فيصحّ على أي محرّك.
  const flowStart = await page.evaluate(()=>{
    const el=document.querySelector('.prw-flow'); if(!el) return null;
    const first=el.firstElementChild; if(!first) return null;
    return { dir:getComputedStyle(el).direction,
             gap:Math.round(first.getBoundingClientRect().right - el.getBoundingClientRect().right),
             scrollable: el.scrollWidth > el.clientWidth + 1 };
  });
  assert.ok(flowStart,'مسار سير العمل غير موجود');
  assert.equal(flowStart.dir,'rtl','مسار سير العمل ليس RTL');
  assert.ok(Math.abs(flowStart.gap)<=3,`أوّل مرحلة ليست عند الحافة اليمنى (فرق ${flowStart.gap}px)`);

  await page.screenshot({path:path.join(outDir,'purchase-workspace-overview.png'),fullPage:true});
  await page.locator('.pr-work-tab',{hasText:'محضر الطلب'}).click();
  assert.match(await page.locator('.pr-work-report').innerText(),/محضر طلب شراء/);
  assert.match(await page.locator('.pr-work-report').innerText(),/فلتر تكييف مركزي/);
  await page.screenshot({path:path.join(outDir,'purchase-workspace-report.png'),fullPage:true});

  // ── المطبوعة الفعليّة: محضر طلب الشراء (بلاغ المالك 2026-09-15) ──
  // ⚠️ القاعدة 3: المطبوعة تُبنى بمعجم `.print-*` وتُمرَّر لـ`printDocOpen`.
  //    كان الإصدار السابق جداول `border="1"` بأنماط سطريّة — وهو سبب رداءة
  //    العرض. الحارس أدناه يمنع الانحدار إليها ويُثبِت أنّ المحضر يحمل
  //    **سلسلة القرارات وتواقيع المعتمِدين الفعليّين** لا مسمّيات ثابتة.
  await page.evaluate(()=>prPrint('PR-DG2026-0148'));
  await page.waitForSelector('#pp-content .print-table');
  const doc = page.locator('#pp-content');
  const docHtml = await doc.innerHTML();
  const docText = await doc.innerText();
  assert.equal((docHtml.match(/border="1"/g)||[]).length,0,'المطبوعة عادت لجداول border="1" الخام');
  assert.ok(!/style="width:100%;border-collapse/.test(docHtml),'المطبوعة تحمل أنماط جدول سطريّة مخترَعة');
  assert.ok(await doc.locator('.print-parties').count()>0,'المطبوعة بلا كتلة الأطراف');
  assert.ok(await doc.locator('.print-signatures .print-sign').count()>=3,'المطبوعة بلا تواقيع');
  assert.match(docText,/سلسلة القرارات المسجّلة/,'المحضر بلا سلسلة قرارات — فهو طلب لا محضر');
  assert.match(docText,/خالد العتيبي/,'المحضر لا يذكر مقدّم الطلب الفعليّ');
  // ⚠️ التأكيد مُنطَّق بكتلة التواقيع عمداً: الاسم يرد في جدول القرارات أيضاً،
  //    فمطابقته على نصّ المستند كلّه تمرّ حتى لو عادت التواقيع مسمّياتٍ ثابتة
  //    (تأكيد فراغيّ — أُمسِك بالبيت-بروف).
  const signText = await doc.locator('.print-signatures').innerText();
  assert.match(signText,/خالد العتيبي/,'كتلة التواقيع لا تحمل مقدّم الطلب الفعليّ');
  assert.match(signText,/م\. فهد القحطاني/,'كتلة التواقيع لا تحمل المعتمِد الفعليّ — عادت مسمّيات ثابتة');
  assert.ok(!/maint\.manager/.test(signText),'التواقيع تعرض اسم المستخدم بدل الاسم');
  assert.match(signText,/اعتُمد إلكترونياً/,'كتلة التواقيع بلا تاريخ اعتماد فعليّ');
  assert.match(docText,/فلتر تكييف مركزي/,'المحضر بلا بنود');
  // ⚠️ جوهر بلاغ «تُحفظ كامل المعلومات عند الإرجاع وعند عودته»: المحضر يحمل
  //    **السجل الكامل** — قرار الإعادة من الإصدار السابق باقٍ بعد إعادة الإرسال.
  assert.match(docText,/أُعيد للاستكمال/,'المحضر فقد قرار الإعادة بعد إعادة الإرسال');
  assert.match(docText,/الكميات تحتاج مراجعة/,'المحضر فقد سبب الإعادة');
  await page.screenshot({path:path.join(outDir,'purchase-request-printed-record.png'),fullPage:true});

  // ── نسخة المورّد: بنود وكميات بلا أي مبلغ أو رصيد (بلاغ المالك 2026-09-15) ──
  await page.evaluate(()=>{ try{ closePrintPreview(); }catch(e){} });
  await page.evaluate(()=>prPrintSupplier('PR-DG2026-0148'));
  await page.waitForSelector('#pp-content .print-table');
  const supDoc = page.locator('#pp-content');
  const supText = await supDoc.innerText();
  const supHtml = await supDoc.innerHTML();
  assert.match(supText,/طلب توريد/,'مستند المورّد بلا عنوان');
  assert.match(supText,/فلتر تكييف مركزي/,'مستند المورّد بلا البنود');
  assert.match(supText,/البنود والكميات المطلوبة/,'مستند المورّد بلا جدول الكميات');
  assert.match(supText,/تعليمات للمورّد/,'مستند المورّد بلا تعليمات');
  assert.ok(!/ر\.س/.test(supText),'تسرّبت وحدة العملة إلى مستند المورّد');
  assert.ok(!/سعر الوحدة|الإجمالي\s*$/m.test(supText),'تسرّب عمود سعر إلى مستند المورّد');
  assert.ok(!/رصيد مستودعي/.test(supText),'تسرّب الرصيد المستودعيّ إلى مستند المورّد');
  assert.ok(!/class="[^"]*price/.test(supHtml),'خليّة سعر في مستند المورّد');
  assert.ok(!/سلسلة القرارات/.test(supText),'سلسلة الاعتماد الداخلية ظهرت للمورّد');
  await page.screenshot({path:path.join(outDir,'purchase-request-supplier-copy.png'),fullPage:true});
  await page.evaluate(()=>{ try{ closePrintPreview(); }catch(e){ document.getElementById('modal-print-preview')?.classList.remove('active'); } });
  await page.locator('.pr-work-tab',{hasText:'الموافقات'}).click();
  assert.match(await page.locator('.pr-work-canvas').innerText(),/مدير المشتريات/);
  await page.locator('.pr-work-request',{hasText:'PR-DG2026-0147'}).click();
  await page.locator('.pr-work-tab',{hasText:'الارتباطات'}).click();
  assert.match(await page.locator('#pr-root').innerText(),/أوامر الشراء والتوزيع على البنود/);
  assert.match(await page.locator('#pr-root').innerText(),/PO-2026-0142/);
  await page.screenshot({path:path.join(outDir,'purchase-workspace-desktop.png'),fullPage:true});

  // ── دورة الطلب حتى نهايتها: الأرشفة والإلغاء (طلب المالك 2026-09-14) ──
  // الطابور الافتراضيّ لا يحمل المؤرشَف (طلبان حيّان فقط رغم وجود ثالث مُقفَل).
  await page.evaluate(async ()=>{ STATE.prWorkspaceFilter='all'; STATE.prWorkspaceSearch=''; prGoView('list'); await renderPRPortal(); });
  await page.waitForSelector('.pr-workspace');
  assert.equal(await page.locator('.pr-work-request').count(),2,'الطابور الافتراضيّ يجب أن يُخلى من المؤرشَف');
  // زرّ «الأرشيف» موجود في التنقّل وبعدّاد حيّ = 1
  const archiveBtn = page.locator('.pr-work-navbtn',{hasText:'الأرشيف'});
  assert.equal(await archiveBtn.count(),1,'زرّ الأرشيف يجب أن يظهر في التنقّل');
  assert.match(await archiveBtn.innerText(),/1/,'عدّاد الأرشيف يجب أن يكون 1');
  await archiveBtn.click();
  await page.waitForFunction(()=>document.querySelectorAll('.pr-work-request').length===1);
  const arRows = await page.locator('.pr-work-request').allInnerTexts();
  assert.equal(arRows.length,1,'وضع الأرشيف يعرض المؤرشَف وحده');
  assert.match(arRows.join('\n'),/PR-DG2026-0140/,'وضع الأرشيف يعرض الطلب المُقفَل');
  assert.ok(!arRows.join('\n').includes('PR-DG2026-0148'),'ووضع الأرشيف لا يعرض الطلبات الحيّة');
  await page.screenshot({path:path.join(outDir,'purchase-workspace-archive.png'),fullPage:true});
  // تفاصيل المؤرشَف: شارة «مؤرشف» ظاهرة، ولا زرّ إلغاء (مُقفَل لا يُلغى)
  await page.locator('.pr-work-request',{hasText:'PR-DG2026-0140'}).click();
  const head = await page.locator('.pr-work-headbuttons').innerText();
  assert.match(await page.locator('.pr-work-detailhead').innerText(),/مؤرشف/,'شارة «مؤرشف» في رأس التفاصيل');
  assert.ok(!/إلغاء الطلب/.test(head),'طلب مُقفَل مؤرشَف لا يحمل زرّ إلغاء');
  assert.match(head,/إعادة من الأرشيف/,'وله زرّ إعادة من الأرشيف (مشتريات + حالة نهائية)');
  await page.screenshot({path:path.join(outDir,'purchase-workspace-archived-detail.png'),fullPage:true});
  // تفاصيل طلب حيّ: زرّ الإلغاء ظاهر (المشتريات يُلغي قبل الإقفال)
  await page.evaluate(async ()=>{ STATE.prWorkspaceMode='requests'; STATE.prWorkspaceFilter='all'; prGoView('list'); await renderPRPortal(); });
  await page.waitForFunction(()=>[...document.querySelectorAll('.pr-work-request')].some(el=>el.textContent.includes('PR-DG2026-0148')));
  await page.locator('.pr-work-request',{hasText:'PR-DG2026-0148'}).click();
  const liveHead = await page.locator('.pr-work-headbuttons').innerText();
  assert.match(liveHead,/إلغاء الطلب/,'الطلب الحيّ يحمل زرّ الإلغاء للمشتريات');
  assert.match(liveHead,/نسخة المورّد/,'زرّ نسخة المورّد غائب عن المشتريات');

  // ── حقول التاريخ: نصّ المتصفّح كان ينعكس في RTL («ةنس/رهش/موي») ──
  // ويجب ألّا يقبل الحقل تاريخاً سابقاً لليوم (`min`).
  await page.evaluate(async ()=>{ prGoView('create'); await renderPRPortal(); });
  await page.waitForSelector('#pr-needed');
  const dateState = await page.evaluate(()=>{
    const els=[...document.querySelectorAll('#page-pr input[type="date"]')];
    const today=new Date().toISOString().slice(0,10);
    return { count:els.length,
             allLtr:els.every(e=>e.getAttribute('dir')==='ltr'),
             computedLtr:els.every(e=>getComputedStyle(e).direction==='ltr'),
             neededMin:document.getElementById('pr-needed')?.min||'',
             today };
  });
  assert.ok(dateState.count>=3,`حقول التاريخ غير موجودة (${dateState.count})`);
  assert.ok(dateState.allLtr,'حقل تاريخ بلا dir="ltr" — نصّ المتصفّح ينعكس');
  assert.ok(dateState.computedLtr,'اتجاه حقل التاريخ المحسوب ليس ltr');
  assert.equal(dateState.neededMin,dateState.today,'تاريخ التوريد يقبل الماضي (لا min)');
  await page.screenshot({path:path.join(outDir,'purchase-request-date-fields.png'),fullPage:false});
  console.log('✓ دورة الطلب حتى نهايتها: أرشفة تُخلي الطابور · وضع أرشيف · شارة مؤرشف · بوّابة إلغاء');

  await page.setViewportSize({width:390,height:844});
  await page.evaluate(()=>{ navDrawer(false); prGoView('list'); });
  await page.waitForSelector('.pr-workspace');
  await page.locator('#sidebar').waitFor({state:'hidden'});
  const drawer=await page.locator('#sidebar').evaluate(el=>({className:el.className,transform:getComputedStyle(el).transform,visibility:getComputedStyle(el).visibility}));
  assert.ok(!drawer.className.includes('open') && drawer.visibility==='hidden',`mobile drawer stayed open: ${JSON.stringify(drawer)}`);
  const overflow = await page.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth);
  assert.ok(overflow<=1,`mobile horizontal overflow: ${overflow}px`);
  assert.equal(await page.locator('.pr-work-navbtn').count(),7);// +الأرشيف
  assert.equal(await page.locator('.pr-work-summary').evaluate(el=>getComputedStyle(el).gridTemplateColumns.split(' ').length),2);
  assert.ok((await page.locator('.pr-work-list').boundingBox()).height<180,'mobile queue should remain compact');
  await page.screenshot({path:path.join(outDir,'purchase-workspace-mobile.png'),fullPage:true});
  console.log('✓ integrated desktop workspace, queue and request cockpit');
  console.log('✓ approval, document and purchase-order relations');
  console.log('✓ mobile layout has no page overflow');
  console.log(`✓ screenshots: ${outDir}`);
} finally {
  await browser.close();
  await new Promise(resolve=>server.close(resolve));
}

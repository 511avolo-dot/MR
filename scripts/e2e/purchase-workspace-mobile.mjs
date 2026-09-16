/* قياس مساحة طلبات الشراء على الجوال — تحت CSP الإنتاج.
   ⚠️ يتطلّب خادم المعاينة: node scripts/csp-preview-server.mjs  (المنفذ 8812)

   لماذا قياس لا قراءة: كتلة `@media(max-width:900px)` موجودة في الملف، لكن
   وجود القاعدة لا يعني أنّها تُطبَّق ولا أنّ النتيجة صالحة للاستعمال. سوابق
   هذا المشروع: قواعد على أسماء أصناف غير موجودة (`.modal-box`) مرّت صامتة،
   ومحاذاة ضربت الصندوق لا الغلاف فقلّصت رؤوس النوافذ.

   الاستعمال:  node scripts/e2e/purchase-workspace-mobile.mjs [--shots]
*/
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { resolveChromiumExecutable } from './chromium-path.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const ORIGIN = process.env.PREVIEW_ORIGIN || 'http://127.0.0.1:8812';
const SHOTS = process.argv.includes('--shots');
const outDir = path.join(os.tmpdir(), 'aldeyabi-pr-workspace-mobile');
fs.mkdirSync(outDir, { recursive: true });

const playwrightPath = 'C:/Users/mo_al/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs';
let chromium;
try { ({ chromium } = await import('playwright')); }
catch (e) { if (!fs.existsSync(playwrightPath)) throw e; ({ chromium } = await import(pathToFileURL(playwrightPath).href)); }

const now = new Date().toISOString();
const profiles = [
  { profile_key:'requester', name_ar:'مقدّم طلب', sort_order:10, active:true, permissions:{pr_create:true,pr_view_own:true,pr_comment:true,pr_upload_attachments:true,pr_print:true} },
  { profile_key:'module_admin', name_ar:'مدير موديل طلبات الشراء', sort_order:50, active:true, permissions:{pr_create:true,pr_view_own:true,pr_view_department:true,pr_view_all:true,pr_comment:true,pr_upload_attachments:true,pr_print:true,pr_approve_maintenance:true,pr_authorize_pricing:true,pr_manage_pricing:true,pr_link_purchase_orders:true,pr_view_financials:true,pr_manage_users:true} }
];
const fixtures = {
  proc_users:[{username:'qa.admin',display_name:'مدير المشتريات',email:'qa.admin@aldeyabi.com',role:'admin',active:true,department_id:'DEP-MAINT',pr_profile_key:'module_admin',pr_permission_overrides:{},permissions:{}}],
  proc_departments:[{id:'DEP-MAINT',name_ar:'إدارة الصيانة والتشغيل',manager_user:'maint.manager',sector:'الصيانة والتشغيل',active:true}],
  proc_approval_rules:[], proc_pr_permission_profiles:profiles,
  proc_settings:[{key:'projects_registry',value:{version:1,projects:[{id:'PRJ-HQ',name:'مشروع المقر الرئيسي',code:'HQ',active:true}]}}],
  proc_purchase_orders:[{po_number:'PO-2026-0142',project:'مشروع المقر الرئيسي',supplier:'شركة الإمداد المتقدم',status:'صادر',total:18450,created_at:now}],
  proc_purchase_requests:[
    {id:'PR-DG2026-0148',title:'قطع غيار وحدات التكييف المركزي للمبنى الإداري',department_id:'DEP-MAINT',department:'إدارة الصيانة والتشغيل',project:'مشروع المقر الرئيسي',requester:'ops.employee',requester_name:'خالد العتيبي',requester_mobile:'0501234567',priority:'عالي',needed_by:'2026-09-20',status:'in_review',workflow_state:'procurement_review',current_seq:2,revision:2,created_at:'2026-09-10T08:00:00Z',updated_at:now},
    {id:'PR-DG2026-0147',title:'مواد صيانة كهربائية',department_id:'DEP-MAINT',department:'إدارة الصيانة والتشغيل',project:'مشروع المقر الرئيسي',requester:'ops.employee',requester_name:'سالم الحربي',priority:'متوسط',status:'approved',workflow_state:'partially_ordered',revision:1,created_at:'2026-09-08T08:00:00Z',updated_at:now}
  ],
  proc_pr_items:[
    {id:101,pr_id:'PR-DG2026-0148',seq:1,description:'فلتر تكييف مركزي عالي الكفاءة',unit:'حبة',requested_qty:12},
    {id:102,pr_id:'PR-DG2026-0148',seq:2,description:'سير ضاغط',unit:'حبة',requested_qty:6},
    {id:103,pr_id:'PR-DG2026-0147',seq:1,description:'قاطع كهربائي 63 أمبير',unit:'حبة',requested_qty:10}
  ],
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
    constructor(t){this.table=t;this.filters=[];this.one=false;}
    select(){return this;} order(){return this;} limit(){return this;} range(){return this;}
    eq(k,v){this.filters.push([k,v]);return this;} is(k,v){this.filters.push([k,v]);return this;}
    ilike(k,v){this.filters.push([k,String(v).toLowerCase()]);return this;}
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
  window.__mobClient=client; window.supabase={createClient:()=>client};
};

let pass=0, fail=0;
const T=(name,ok,detail='')=>{ if(ok)pass++; else fail++; console.log(`${ok?'  ✓':'  ✗'} ${name}${ok?'':`  — ${detail}`}`); };

/* ⚠️ `html{overflow-x:clip}` يجعل scrollWidth==clientWidth فيقيس القناعُ نفسه.
   يُرفَع قبل القياس ثمّ يُعاد — درس متكرّر في هذا المشروع. */
const measureOverflow = (page) => page.evaluate(() => {
  const de = document.documentElement;
  const prev = de.style.overflowX;
  de.style.overflowX = 'visible';
  const over = de.scrollWidth - de.clientWidth;
  const wide = [...document.querySelectorAll('#page-pr *')]
    .map(el => ({ el, r: el.getBoundingClientRect() }))
    .filter(({ r }) => r.width > 0 && (r.right > de.clientWidth + 1 || r.left < -1))
    .slice(0, 8)
    .map(({ el, r }) => `${el.tagName.toLowerCase()}.${(el.className||'').toString().split(' ').filter(Boolean).slice(0,2).join('.')} w=${Math.round(r.width)} right=${Math.round(r.right)}`);
  de.style.overflowX = prev;
  return { over, wide };
});

const executablePath = resolveChromiumExecutable();
const browser = await chromium.launch(executablePath ? { headless:true, executablePath } : { headless:true });
const report = {};
try {
  for (const vp of [{w:393,h:852,name:'iphone-393'},{w:360,h:740,name:'android-360'}]) {
    const page = await browser.newPage({ viewport:{width:vp.w,height:vp.h}, deviceScaleFactor:2, isMobile:true, hasTouch:true });
    const errors=[], csp=[];
    page.on('pageerror',e=>errors.push(e.message));
    page.on('console',m=>{ const t=m.text(); if(/Content Security Policy|Refused to/i.test(t)) csp.push(t); });
    await page.addInitScript(init,{fixtures,profiles});
    await page.goto(`${ORIGIN}/index.html`,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(()=>typeof window.renderPRPortal==='function');
    await page.evaluate(async ({fixtures})=>{
      STATE.currentUser={username:'qa.admin',displayName:'مدير المشتريات',role:'admin',permissions:{},prProfileKey:'module_admin'};
      STATE.purchaseOrders=fixtures.proc_purchase_orders;
      CLOUD.enabled=true; CLOUD.client=window.__mobClient;
      try{ hideLoginScreen(); }catch(_){}
      try{ navigate('pr'); }catch(_){}
      __prLoaded=false; STATE.prView='list';
      await renderPRPortal();
    },{fixtures});
    await page.waitForSelector('.pr-workspace');
    await page.waitForTimeout(250);

    console.log(`\n── ${vp.name} (${vp.w}×${vp.h}) ──`);
    const o1 = await measureOverflow(page);
    T(`قائمة الطلبات: صفر انزلاق أفقيّ`, o1.over<=1, `انزلاق ${o1.over}px · ${o1.wide.join(' | ')}`);

    // الطبقات الثابتة: الشريط العلويّ للنظام + شريط التبويبات السفليّ
    const chrome = await page.evaluate(()=>{
      const g=(s)=>{const e=document.querySelector(s); if(!e) return null; const r=e.getBoundingClientRect(); const cs=getComputedStyle(e); return {h:Math.round(r.height),top:Math.round(r.top),disp:cs.display,pos:cs.position,z:cs.zIndex};};
      return { mnav:g('.mnav'), topbar:g('.topbar'), workTop:g('.pr-work-top'), rail:g('.pr-work-rail') };
    });
    report[vp.name]={chrome};

    // تداخل: هل يغطّي الشريط السفليّ محتوى مساحة العمل؟
    /* ⚠️ يُقاس **بعد التمرير إلى نهاية الصفحة**: زرٌّ يقع تحت الشريط وهو ساكن
       ثمّ تُظهره تمريرة واحدة ليس محجوباً — سلوك صفحة عاديّ. المحجوب حقّاً هو
       ما يبقى تحت الشريط ولا يمكن تمريره فوقه إطلاقاً. (قياس سابق فرّق بينهما:
       3 أزرار تحت الشريط عند السكون · صفر بعد التمرير.) */
    const clash = await page.evaluate(async ()=>{
      const nav=document.querySelector('.mnav'); if(!nav) return {nav:false};
      if(getComputedStyle(nav).display==='none') return {nav:false};
      const prev=window.scrollY;
      window.scrollTo(0,document.documentElement.scrollHeight);
      await new Promise(r=>setTimeout(r,220));
      const nr=nav.getBoundingClientRect();
      const hidden=[...document.querySelectorAll('.pr-work-canvas .btn, .pr-work-headbuttons .btn, .pr-work-editor .btn')]
        .map(b=>({t:(b.innerText||'').trim().slice(0,22), r:b.getBoundingClientRect()}))
        .filter(x=>x.r.height>0 && x.r.bottom>nr.top && x.r.top<nr.bottom)
        .map(x=>x.t);
      window.scrollTo(0,prev); await new Promise(r=>setTimeout(r,120));
      return {nav:true, navTop:Math.round(nr.top), hidden};
    });
    T(`لا زرّ محجوب دائماً تحت الشريط السفليّ (بعد التمرير للنهاية)`, !clash.nav || clash.hidden.length===0, `محجوب: ${(clash.hidden||[]).join(' · ')}`);

    // أهداف اللمس داخل مساحة الطلبات
    const small = await page.evaluate(()=>{
      const sel='#page-pr button, #page-pr a[href], #page-pr [role="button"], #page-pr input, #page-pr select';
      return [...document.querySelectorAll(sel)].map(e=>({t:(e.innerText||e.getAttribute('aria-label')||e.tagName).trim().slice(0,20),r:e.getBoundingClientRect()}))
        .filter(x=>x.r.width>0&&x.r.height>0&&(x.r.height<36||x.r.width<28))
        .map(x=>`${x.t} ${Math.round(x.r.width)}×${Math.round(x.r.height)}`);
    });
    T(`أهداف اللمس ≥36px ارتفاعاً`, small.length===0, `${small.length}: ${small.slice(0,6).join(' | ')}`);

    /* حقول الإدخال 16px فأكثر (دونها يُقرّب iOS الصفحة تلقائياً).
       ⚠️ حقول الملفّات مستثناة هنا كما هي مستثناة في CSS: النقر عليها يفتح
       مُنتقي النظام ولا يُدخِل المستخدم فيها نصّاً، فلا تقريب. الثابت المحروس
       هو **حقول إدخال النصّ**؛ توسيعه لكل `input` يُنتج إخفاقاً كاذباً. */
    const tiny = await page.evaluate(()=>[...document.querySelectorAll('#page-pr input,#page-pr select,#page-pr textarea')]
      .filter(e=>e.getBoundingClientRect().height>0)
      .filter(e=>!['file','checkbox','radio','range'].includes((e.type||'').toLowerCase()))
      .map(e=>({t:e.id||e.name||e.placeholder||e.tagName,fs:parseFloat(getComputedStyle(e).fontSize)}))
      .filter(x=>x.fs<16).map(x=>`${x.t} ${x.fs}px`));
    T(`حقول الإدخال ≥16px (لا تقريب iOS)`, tiny.length===0, `${tiny.length}: ${tiny.slice(0,6).join(' | ')}`);

    if (SHOTS) await page.screenshot({path:path.join(outDir,`${vp.name}-01-queue.png`),fullPage:true});

    // ── فتح طلب: التفاصيل ──
    await page.locator('.pr-work-request').first().click();
    await page.waitForTimeout(300);
    const o2 = await measureOverflow(page);
    T(`تفاصيل الطلب: صفر انزلاق أفقيّ`, o2.over<=1, `انزلاق ${o2.over}px · ${o2.wide.join(' | ')}`);
    if (SHOTS) await page.screenshot({path:path.join(outDir,`${vp.name}-02-detail.png`),fullPage:true});

    // هل القائمة ما زالت تحتلّ الشاشة فوق التفاصيل؟ (المشكلة الكلاسيكية للتخطيط ثلاثيّ الأعمدة)
    const stack = await page.evaluate(()=>{
      const q=document.querySelector('.pr-work-queue'), d=document.querySelector('.pr-work-detail');
      if(!q||!d) return null;
      const qr=q.getBoundingClientRect(), dr=d.getBoundingClientRect();
      return { queueH:Math.round(qr.height), detailTop:Math.round(dr.top), vh:window.innerHeight,
               queueVisible:getComputedStyle(q).display!=='none' };
    });
    report[vp.name].stack=stack;
    T(`التفاصيل تبدأ داخل الشاشة الأولى بعد الاختيار`, stack && stack.detailTop < stack.vh,
      stack?`رأس التفاصيل عند ${stack.detailTop}px والشاشة ${stack.vh}px (القائمة ${stack.queueH}px فوقه)`:'تعذّر القياس');

    // ── التبويبات ──
    const tabs = await page.$$eval('.pr-work-tab', els=>els.map(e=>e.innerText.trim()));
    report[vp.name].tabs=tabs;
    for (const label of ['محضر الطلب','المرفقات','النقاش']) {
      const t = page.locator('.pr-work-tab',{hasText:label});
      if (await t.count()) {
        await t.first().click(); await page.waitForTimeout(250);
        const o = await measureOverflow(page);
        T(`تبويب «${label}»: صفر انزلاق`, o.over<=1, `انزلاق ${o.over}px · ${o.wide.join(' | ')}`);
        if (SHOTS) await page.screenshot({path:path.join(outDir,`${vp.name}-03-${label}.png`),fullPage:true});
      }
    }

    // ── نموذج طلب جديد ──
    await page.evaluate(()=>{ try{ prGoView('create'); }catch(_){} });
    await page.waitForTimeout(400);
    const o3 = await measureOverflow(page);
    T(`نموذج طلب جديد: صفر انزلاق أفقيّ`, o3.over<=1, `انزلاق ${o3.over}px · ${o3.wide.join(' | ')}`);
    const tiny2 = await page.evaluate(()=>[...document.querySelectorAll('#page-pr input,#page-pr select,#page-pr textarea')]
      .filter(e=>e.getBoundingClientRect().height>0)
      .filter(e=>e.type!=='file')   /* لا إدخال نصّيّ ⇒ لا تقريب؛ مستثنى من القاعدة عمداً */
      .map(e=>({t:e.id||e.name||e.placeholder||e.tagName,fs:parseFloat(getComputedStyle(e).fontSize)}))
      .filter(x=>x.fs<16).map(x=>`${x.t} ${x.fs}px`));
    T(`حقول النموذج ≥16px`, tiny2.length===0, `${tiny2.length}: ${tiny2.slice(0,8).join(' | ')}`);
    // جدول البنود: هل يفيض؟
    const itemsTbl = await page.evaluate(()=>{
      const t=document.querySelector('#pr-items-body')?.closest('table'); if(!t) return null;
      const r=t.getBoundingClientRect(); const w=t.closest('.table-scroll,.pr-work-surface,.pr-work-editor');
      return { tableW:Math.round(r.width), wrapW:w?Math.round(w.getBoundingClientRect().width):null,
               wrapped:!!t.closest('.table-scroll'), vw:window.innerWidth };
    });
    report[vp.name].itemsTbl=itemsTbl;
    T(`جدول البنود ملفوف أو ضمن العرض`, !itemsTbl || itemsTbl.wrapped || itemsTbl.tableW<=itemsTbl.vw+1,
      itemsTbl?`عرض الجدول ${itemsTbl.tableW}px والشاشة ${itemsTbl.vw}px وملفوف=${itemsTbl.wrapped}`:'');
    if (SHOTS) await page.screenshot({path:path.join(outDir,`${vp.name}-04-create.png`),fullPage:true});

    T(`صفر خطأ صفحة`, errors.length===0, errors.slice(0,3).join(' | '));
    T(`صفر انتهاك CSP`, csp.length===0, csp.slice(0,3).join(' | '));
    await page.close();
  }
} finally { await browser.close(); }

console.log('\n── قياسات ──');
console.log(JSON.stringify(report,null,1));
console.log(`\n${fail?'❌':'✅'} مساحة الطلبات على الجوال: ${pass} ناجح · ${fail} فاشل`);
if (SHOTS) console.log(`لقطات: ${outDir}`);
process.exit(fail?1:0);

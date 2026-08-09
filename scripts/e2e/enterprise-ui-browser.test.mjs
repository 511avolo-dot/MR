#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { chromium } from 'playwright';
import { resolveChromiumExecutable } from './chromium-path.mjs';

const rootFiles = new Map([
  ['/assets/portal-functional-studios.css', ['text/css; charset=utf-8', readFileSync('assets/portal-functional-studios.css')]],
  ['/assets/generated-document-studio.css', ['text/css; charset=utf-8', readFileSync('assets/generated-document-studio.css')]],
  ['/assets/quote-document-studio.css', ['text/css; charset=utf-8', readFileSync('assets/quote-document-studio.css')]],
  ['/assets/access-inspector.css', ['text/css; charset=utf-8', readFileSync('assets/access-inspector.css')]],
  ['/assets/document-studio.js', ['text/javascript; charset=utf-8', readFileSync('assets/document-studio.js')]],
  ['/assets/generated-document-studio.js', ['text/javascript; charset=utf-8', readFileSync('assets/generated-document-studio.js')]],
  ['/assets/quote-document-studio.js', ['text/javascript; charset=utf-8', readFileSync('assets/quote-document-studio.js')]],
  ['/assets/policy-studio.js', ['text/javascript; charset=utf-8', readFileSync('assets/policy-studio.js')]],
  ['/assets/access-inspector.js', ['text/javascript; charset=utf-8', readFileSync('assets/access-inspector.js')]],
  ['/assets/payment-evidence-guard.js', ['text/javascript; charset=utf-8', readFileSync('assets/payment-evidence-guard.js')]],
]);

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n0sAAAAASUVORK5CYII=', 'base64');

const html = `<!doctype html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="/assets/portal-functional-studios.css"><link rel="stylesheet" href="/assets/generated-document-studio.css"><link rel="stylesheet" href="/assets/quote-document-studio.css"><link rel="stylesheet" href="/assets/access-inspector.css"></head><body>
<header class="topbar" data-legacy-shell="true"><div class="ttl">بوابة المشتريات</div><nav class="nav"><button class="active">الرئيسية</button></nav></header>
<div class="wrap"><div class="pagehead"><div><h1>مركز العمل</h1><div class="sub">اختبار متصفح معزول</div></div></div><div class="card"><div class="sec-title">طلبات تحتاج إجراء</div><table><thead><tr><th>الطلب</th><th>الحالة</th></tr></thead><tbody><tr><td>REQ-1</td><td>قيد الإجراء</td></tr></tbody></table></div>
<div id="generated-purchase-request" class="doc-sheet" style="margin-top:20px"><div class="doc-body"><h2>طلب شراء تجريبي</h2><table><thead><tr><th>الصنف</th><th>الكمية</th><th>السعر</th><th>الإجمالي</th></tr></thead><tbody><tr><td>مادة اختبار</td><td>2</td><td>500</td><td>1000</td></tr></tbody></table><div class="doc-words">الإجمالي كتابةً: ألف ريال</div><div class="doc-actions"><button>طباعة</button></div></div></div></div>
<script>
window.ME='admin'; window.CURRENT='REQ-1'; window.VIEW='detail';
window.SUPPLIERS={s1:{n:'المورد الأول'},s2:{n:'المورد الثاني'},s3:{n:'المورد الثالث'}};
window.DEPTS={ops:{n:'التشغيل',sector:'العمليات'},fin:{n:'المالية',sector:'الإدارة'}};
window.JOBS={admin_job:{title:'مدير البوابة',scope:'all',acc:{can:{manageUsers:true,manageCompany:true},see:{finance:true}}},fin_job:{title:'محاسب',scope:'all',acc:{can:{approveDisb:true,disburse:true},see:{finance:true}}}};
window.USERS={admin:{n:'مدير البوابة',r:'مدير البوابة',job:'admin_job',admin:true,deptId:'ops',sector:'العمليات',active:true,perms:{can_manage_users:true,can_manage_company:true}},finance_user:{n:'محاسب الاختبار',r:'محاسب',job:'fin_job',deptId:'fin',sector:'الإدارة',active:true,perms:{can_disburse:true}}};
window.REQS=[{id:'REQ-1',title:'توريد مواد اختبار',dept:'التشغيل',requester:'student',phase:'pricing',docs:[{id:1,key:'docs/reqdoc/REQ-1/testdoc.png',title:'مستند داعم تجريبي',type:'memo',active:true,size:68}],proc:{supplierList:['s1','s2','s3'],offers:{s1:{quotePdfKey:'quotes/REQ-1/quote-one.png',total:12000,deliveryDays:4},s2:{quotePdfKey:'quotes/REQ-1/quote-two.png',total:11500,deliveryDays:8},s3:{quotePdfKey:'quotes/REQ-1/quote-three.png',total:13000,deliveryDays:2}}}}];
window.uName=(u)=>window.USERS[u]?.n||(u==='student'?'طالب الاختبار':u);
window.isAdmin=()=>true;
window.accessOf=(username)=>username==='finance_user'?{scope:'all',can:{approveDisb:true,disburse:true},see:{finance:true}}:{scope:'all',can:{viewQuotes:true,manageUsers:true,manageCompany:true},see:{finance:true}};
window.render=()=>{};
window.printEl=()=>{ document.body.dataset.legacyPrint='called'; };
window.toast=(message,kind)=>{ document.body.dataset.toast=kind+':'+message; };
window.pa_docValidate=()=>true;
window.pa_docUpload=async(kind,reqId,file)=>{ window.__upload={kind,reqId,name:file.name}; return 'docs/inst/'+reqId+'/fixture-evidence.pdf'; };
window.pa_rpc=async(name,args)=>{ window.__lastRpc={name,args}; return {ok:true}; };
const policy={enabled:true,min_amount_exclusive:25000,max_amount_inclusive:125000,fallback_role_key:null,version:3,published_at:'2026-08-02T12:00:00Z',published_by:'admin'};
window.SB={
 auth:{getSession:async()=>({data:{session:{access_token:'fixture-token'}}})},
 rpc:async(name,args)=>{
  if(name==='portal_get_committee_policy') return {data:{...policy},error:null};
  if(name==='portal_committee_route') return {data:{in_band:Number(args.p_total)>25000&&Number(args.p_total)<=125000,use_committee:true,use_fallback:false,fallback_role_key:null},error:null};
  if(name==='portal_set_committee_policy') return {data:{ok:true,policy:{...policy,...args.p_policy,version:4,published_by:'admin'}},error:null};
  return {data:null,error:{message:'unexpected rpc '+name}};
 }
};
</script>
<script src="/assets/document-studio.js"></script><script src="/assets/generated-document-studio.js"></script><script src="/assets/quote-document-studio.js"></script><script src="/assets/policy-studio.js"></script><script src="/assets/access-inspector.js"></script><script src="/assets/payment-evidence-guard.js"></script>
</body></html>`;

const requests = [];
const server = createServer((req, res) => {
  requests.push(req.url || '');
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  if (url.pathname === '/') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end(html);
    return;
  }
  if (url.pathname === '/api/portal-doc' || url.pathname === '/api/portal-quote') {
    assert.equal(req.headers.authorization, 'Bearer fixture-token');
    res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'no-store' });
    res.end(png);
    return;
  }
  const file = rootFiles.get(url.pathname);
  if (file) {
    res.writeHead(200, { 'content-type': file[0], 'cache-control': 'no-store' });
    res.end(file[1]);
    return;
  }
  res.writeHead(404); res.end('not found');
});

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const address = server.address();
const base = `http://127.0.0.1:${address.port}`;
let browser;
try {
  const chromiumPath = resolveChromiumExecutable();
  browser = await chromium.launch({ headless: true, ...(chromiumPath ? { executablePath: chromiumPath } : {}) });
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(base, { waitUntil: 'networkidle' });

  assert.equal(await page.locator('[data-legacy-shell="true"]').count(), 1);
  assert.equal(await page.locator('.eui-skip-link').count(), 0);
  assert.equal(await page.evaluate(() => document.documentElement.dataset.enterpriseUi || ''), '');
  console.log('  ✓ owner-approved legacy portal shell remains active without the rejected redesign');

  const policyLauncher = page.locator('.eps-launcher');
  await policyLauncher.waitFor({ state: 'visible' });
  await policyLauncher.click();
  await page.locator('.eps-shell').waitFor({ state: 'visible' });
  assert.match(await page.locator('.eps-panel').innerText(), /الإصدار الحالي:\s*3/);
  await page.locator('#eps-sim-amount').fill('87500');
  await page.locator('[data-eps-action="simulate"]').click();
  await page.waitForFunction(() => document.querySelector('#eps-simulation')?.textContent.includes('ستُضاف مرحلة اللجنة'));
  console.log('  ✓ policy studio loaded an authorized policy and simulated routing');
  await page.locator('.eps-close').click();

  const accessLauncher = page.locator('.eai-launcher');
  await accessLauncher.waitFor({ state: 'visible' });
  await accessLauncher.click();
  await page.locator('.eai-shell').waitFor({ state: 'visible' });
  await page.locator('[data-eai-user="finance_user"]').click();
  assert.match(await page.locator('[data-eai-detail]').innerText(), /محاسب الاختبار/);
  assert.match(await page.locator('[data-eai-detail]').innerText(), /يجمع بين اعتماد الصرف وتنفيذه/);
  await page.locator('[data-eai-search]').fill('محاسب');
  assert.equal(await page.locator('.eai-user').count(), 1);
  console.log('  ✓ access inspector explained effective permissions and flagged a separation-of-duties conflict');
  await page.locator('.eai-close').click();

  await page.evaluate(() => window.printEl('generated-purchase-request','طلب شراء','REQ-1'));
  await page.locator('.gds-root').waitFor({ state: 'visible' });
  assert.match(await page.locator('.gds-title').innerText(), /طلب شراء/);
  const frame = page.locator('.gds-frame');
  await frame.waitFor({ state: 'visible' });
  await page.waitForFunction(() => document.querySelector('.gds-frame')?.contentDocument?.body?.innerText.includes('طلب شراء تجريبي'));
  assert.equal(await page.evaluate(() => document.body.dataset.legacyPrint || ''), '');
  console.log('  ✓ legacy print action opens the in-portal generated-document preview');
  await page.keyboard.press('Escape');
  await page.locator('.gds-root').waitFor({ state: 'detached' });

  await page.evaluate(() => window.AldeyabiDocumentStudio.openRequestDocument('REQ-1', 1));
  await page.locator('.eds-root').waitFor({ state: 'visible' });
  await page.locator('.eds-image').waitFor({ state: 'visible' });
  assert.match(await page.locator('.eds-title').innerText(), /مستند داعم تجريبي/);
  assert.equal(await page.locator('.eds-root').getAttribute('aria-modal'), 'true');
  console.log('  ✓ authenticated in-portal document studio rendered a supporting document');
  await page.keyboard.press('Escape');
  await page.locator('.eds-root').waitFor({ state: 'detached' });

  await page.evaluate(() => window.openQuoteViewer('REQ-1'));
  await page.locator('.qds-root').waitFor({ state: 'visible' });
  await page.locator('.qds-pane').first().waitFor({ state: 'visible' });
  assert.equal(await page.locator('.qds-pane').count(), 2);
  assert.equal(await page.locator('.qds-card').count(), 3);
  assert.match(await page.locator('.qds-root').innerText(), /المورد الثاني · الأقل سعراً/);
  await page.locator('[data-qds-action="single"]').click();
  assert.equal(await page.locator('.qds-pane').count(), 1);
  await page.locator('[data-qds-index="2"]').click();
  assert.match(await page.locator('.qds-pane__supplier').innerText(), /المورد الثالث/);
  console.log('  ✓ quotation studio compared two suppliers and switched to a selected single offer');
  await page.keyboard.press('Escape');
  await page.locator('.qds-root').waitFor({ state: 'detached' });

  const fileChooserPromise = page.waitForEvent('filechooser');
  const rpcPromise = page.evaluate(() => window.pa_rpc('portal_payment_request', {
    p_request_id: 'REQ-1', p_kind: 'bank', p_amount: 1000,
    p_details: { iban: 'SA1234567890123456789012', account_name: 'Fixture' },
  }));
  const chooser = await fileChooserPromise;
  await chooser.setFiles({ name: 'payment-evidence.pdf', mimeType: 'application/pdf', buffer: Buffer.from('%PDF-1.4\n%%EOF') });
  await rpcPromise;
  const evidenceState = await page.evaluate(() => ({ upload: window.__upload, rpc: window.__lastRpc }));
  assert.deepEqual(evidenceState.upload, { kind: 'inst', reqId: 'REQ-1', name: 'payment-evidence.pdf' });
  assert.equal(evidenceState.rpc.name, 'portal_payment_request');
  assert.equal(evidenceState.rpc.args.p_details.proof_key, 'docs/inst/REQ-1/fixture-evidence.pdf');
  console.log('  ✓ payment request could not reach its RPC until verified evidence was uploaded');

  assert.equal(requests.filter((url) => url.startsWith('/api/portal-quote')).length, 3);
  assert.equal(requests.some((url) => url.includes('mwbjoysuybgbrvfrprex')), false);
  console.log('  ✓ document traffic stayed same-origin and made no production-reference request');
} finally {
  if (browser) await browser.close();
  await new Promise((resolve) => server.close(resolve));
}

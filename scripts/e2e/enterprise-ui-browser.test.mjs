#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { chromium } from 'playwright';

const rootFiles = new Map([
  ['/assets/enterprise-ui.css', ['text/css; charset=utf-8', readFileSync('assets/enterprise-ui.css')]],
  ['/assets/document-studio.js', ['text/javascript; charset=utf-8', readFileSync('assets/document-studio.js')]],
  ['/assets/policy-studio.js', ['text/javascript; charset=utf-8', readFileSync('assets/policy-studio.js')]],
  ['/assets/enterprise-ui.js', ['text/javascript; charset=utf-8', readFileSync('assets/enterprise-ui.js')]]
]);

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n0sAAAAASUVORK5CYII=', 'base64');

const html = `<!doctype html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="/assets/enterprise-ui.css"></head><body>
<header class="topbar"><div class="ttl">بوابة المشتريات</div><nav class="nav"><button class="active">الرئيسية</button></nav></header>
<div class="wrap"><div class="pagehead"><div><h1>مركز العمل</h1><div class="sub">اختبار متصفح معزول</div></div></div><div class="card"><div class="sec-title">طلبات تحتاج إجراء</div><table><thead><tr><th>الطلب</th><th>الحالة</th></tr></thead><tbody><tr><td>REQ-1</td><td>قيد الإجراء</td></tr></tbody></table></div></div>
<script>
window.ME='admin'; window.CURRENT='REQ-1'; window.VIEW='detail';
window.REQS=[{id:'REQ-1',title:'توريد مواد اختبار',dept:'التشغيل',requester:'student',phase:'pricing',docs:[{id:1,key:'test.png',title:'عرض سعر تجريبي',type:'quotation',active:true,size:68}]}];
window.uName=(u)=>u==='student'?'طالب الاختبار':'مدير البوابة';
window.isAdmin=()=>true;
window.accessOf=()=>({can:{},see:{}});
window.render=()=>{};
window.toast=(message,kind)=>{ document.body.dataset.toast=kind+':'+message; };
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
<script src="/assets/document-studio.js"></script><script src="/assets/policy-studio.js"></script><script src="/assets/enterprise-ui.js"></script>
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
  if (url.pathname === '/api/portal-doc') {
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
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(base, { waitUntil: 'networkidle' });

  await page.waitForFunction(() => document.documentElement.dataset.enterpriseUi === 'true');
  assert.equal(await page.locator('.eui-skip-link').count(), 1);
  assert.equal(await page.locator('main,[role="main"]').count() > 0, true);
  assert.equal(await page.locator('thead th[scope="col"]').count(), 2);
  console.log('  ✓ enterprise layout and accessibility enhancement loaded');

  const launcher = page.locator('.eps-launcher');
  await launcher.waitFor({ state: 'visible' });
  await launcher.click();
  await page.locator('.eps-shell').waitFor({ state: 'visible' });
  assert.match(await page.locator('.eps-panel').innerText(), /الإصدار الحالي:\s*3/);
  await page.locator('#eps-sim-amount').fill('87500');
  await page.locator('[data-eps-action="simulate"]').click();
  await page.waitForFunction(() => document.querySelector('#eps-simulation')?.textContent.includes('ستُضاف مرحلة اللجنة'));
  console.log('  ✓ policy studio loaded an authorized policy and simulated routing');
  await page.locator('.eps-close').click();

  await page.evaluate(() => window.AldeyabiDocumentStudio.openRequestDocument('REQ-1', 1));
  await page.locator('.eds-root').waitFor({ state: 'visible' });
  await page.locator('.eds-image').waitFor({ state: 'visible' });
  assert.match(await page.locator('.eds-title').innerText(), /عرض سعر تجريبي/);
  assert.equal(await page.locator('.eds-root [aria-modal="true"]').count(), 0);
  assert.equal(await page.locator('.eds-root').getAttribute('aria-modal'), 'true');
  console.log('  ✓ authenticated in-portal document studio rendered the uploaded image');

  await page.keyboard.press('Escape');
  await page.locator('.eds-root').waitFor({ state: 'detached' });
  assert.equal(requests.some((url) => url.includes('mwbjoysuybgbrvfrprex')), false);
  console.log('  ✓ keyboard close works and fixture made no production-reference request');
} finally {
  if (browser) await browser.close();
  await new Promise((resolve) => server.close(resolve));
}

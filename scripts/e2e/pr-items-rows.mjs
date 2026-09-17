/* ══════════════════════════════════════════════════════════════════════
   بنود طلب الشراء — تحقّق على الجدول الحقيقيّ تحت CSP الإنتاج
   ----------------------------------------------------------------------
   بلاغ المالك: القراءة الذكية تسجّل البنود بعد صفوف فارغة، وحذف الصفّ الفارغ
   يحذف آخر بند بدلاً منه. العلّة كانت `prRenderItems` تجمع من DOM قديم.

   هنا نُشغّل الدوال على **DOM حقيقيّ** لا مُقلَّد — فالكعب أخطأ مرّة في ترتيب
   السمات وأنتج إخفاقاً وهميّاً؛ المتصفّح لا يخطئ في ترميزه هو.

     node scripts/csp-preview-server.mjs &
     node scripts/e2e/pr-items-rows.mjs
   ══════════════════════════════════════════════════════════════════════ */
import { chromium } from 'playwright';
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';

const ORIGIN = 'http://127.0.0.1:8812';
const checks = [];
const ok = (n, p, d) => checks.push({ n, p, d });

const browser = await chromium.launch({ executablePath: resolveChromiumExecutable() });
const ctx = await browser.newContext({ viewport: { width: 1280, height: 950 }, locale: 'ar-SA' });
const page = await ctx.newPage();
const errors = [], csp = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await blockSupabase(ctx);   // انظر app-boot.mjs — لا فحص يلمس الإنتاج
await page.goto(`${ORIGIN}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.prRenderItems === 'function', { timeout: 15000 });
await enterApp(page);   // إقلاع حتميّ — انظر app-boot.mjs

/* شاشة إنشاء الطلب بسحابة مُقلَّدة — لا اتصال بالإنتاج. */
await page.evaluate(() => {
  STATE.currentUser = { username:'saleh', display_name:'صالح', role:'user',
    permissions:{ can_receive_po:true, can_view_amounts:false }, scope_sectors:['الصيانة والتشغيل'] };
  try { hideLoginScreen(); } catch (e) {}
  try { hydSettle('ready'); } catch (e) {}
  CLOUD.enabled = true; CLOUD.dataLoaded = true;
  CLOUD.client = { auth:{ getSession: async () => ({ data:{ session:null } }) },
    from: () => ({ select: () => ({ order: async () => ({ data:[], error:null }) }) }),
    channel: () => ({ on(){ return this; }, subscribe(){ return this; } }) };
  window.__prLoaded = true; try { __prLoaded = true; } catch (e) {}
  STATE.purchaseRequests = []; STATE.departments = [];
  navigate('pr'); prGoView('create');
});
await page.waitForSelector('#pr-items-body tr[data-row]', { timeout: 8000 });

const names = () => page.evaluate(() =>
  [...document.querySelectorAll('#pr-items-body tr[data-row]')]
    .map((tr) => tr.querySelector('[data-f=description]').value || '(فارغ)').join('|'));

ok('شاشة الطلب تفتح بصفّ بند واحد فارغ', (await names()) === '(فارغ)', await names());

/* ── ١) القراءة الذكية بعد صفّ فارغ افتراضيّ ── */
await page.evaluate(() => prApplyParsed({ title:'مواد نظافة', items:[
  { description:'أكياس نفايات 50 جالون', unit:'شوال', requested_qty:60 },
  { description:'صابون سائل 441 لتر',   unit:'حبة',  requested_qty:130 },
  { description:'منظف للزجاج 21*1',      unit:'كرتون', requested_qty:21 },
] }));
ok('القراءة الذكية تبدأ من الصفّ الأوّل ولا تفقد بنداً',
  (await names()) === 'أكياس نفايات 50 جالون|صابون سائل 441 لتر|منظف للزجاج 21*1', await names());
/* لقطة الجدول نفسه لا أعلى الصفحة — أوّل صياغة قصّت فوق البنود فلم تُظهر شيئاً. */
/* ⚠️ كان هنا `scrollIntoViewIfNeeded` فيتوقّف السكربت دائماً بمهلة 30 ثانية:
   الجدول **مرئيّ فعلاً** (قِيس: 518×195 عند y=800)، لكنّ الدالّة تنتظر
   استقرار الصندوق بين إطارين، وفي الصفحة حركةٌ دائمة فلا يستقرّ أبداً.
   واللقطة تُمرّر بنفسها، و`animations:'disabled'` تُثبّت الإطار.
   (عطلٌ سابق لهذه الدفعة — مُثبَت بتشغيله على `index.html` قبلها.) */
await page.locator('.pr-items-table').screenshot({ path: '/tmp/pr-items-after-ai.png', animations: 'disabled' });

/* ── ٢) حذف صفّ من الوسط يُصيبه هو ── */
await page.evaluate(() => prRemoveDraftItem(1));
ok('وحذف صفّ من الوسط يحذفه هو لا آخر بند',
  (await names()) === 'أكياس نفايات 50 جالون|منظف للزجاج 21*1', await names());

/* ── ٣) ➕ لا يفقد ما كُتِب، والحذف يحفظ تعديلاً لم يُغادر الحقل ── */
await page.evaluate(() => {
  document.querySelector('#pr-items-body tr[data-row="0"] [data-f=description]').value = 'أكياس معدَّلة';
  prAddItemRow();
});
ok('و➕ إضافة بند يحفظ ما كُتِب في الصفوف الظاهرة',
  (await names()) === 'أكياس معدَّلة|منظف للزجاج 21*1|(فارغ)', await names());

await page.evaluate(() => prRemoveDraftItem(2));
ok('وحذف الصفّ الفارغ يحذفه هو',
  (await names()) === 'أكياس معدَّلة|منظف للزجاج 21*1', await names());

/* ── ٤) قراءة ذكية ثانية: تُبقي المكتوب يدويّاً وتُلحِق الجديد ── */
await page.evaluate(() => prApplyParsed({ items:[{ description:'ملمع أثاث', unit:'كرتون', requested_qty:8 }] }));
ok('وقراءة ثانية تُلحِق ولا تمحو ما كتبه المستخدم',
  (await names()) === 'أكياس معدَّلة|منظف للزجاج 21*1|ملمع أثاث', await names());

/* ── ٥) حذف كل الصفوف يُبقي صفّاً فارغاً واحداً (لا جدول بلا صفوف) ── */
await page.evaluate(() => { prRemoveDraftItem(2); prRemoveDraftItem(1); prRemoveDraftItem(0); });
ok('وحذف الجميع يُبقي صفّاً فارغاً واحداً', (await names()) === '(فارغ)', await names());

ok('صفر خطأ صفحة', errors.length === 0, errors[0]);
ok('صفر انتهاك CSP', csp.length === 0, csp[0]);

await browser.close();
let bad = 0;
for (const c of checks) { if (!c.p) bad++; console.log(`${c.p ? '✓' : '✗ FAIL'}  ${c.n}${c.d ? '  → ' + c.d : ''}`); }
if (bad) { console.error(`\n❌ ${bad} فحص فشل`); process.exit(1); }
console.log(`\n✅ ${checks.length}/${checks.length} فحصاً نجحت`);

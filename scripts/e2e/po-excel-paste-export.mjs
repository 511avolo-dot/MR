/**
 * po-excel-paste-export.mjs — لصق بنود أمر الشراء من إكسل، وتصدير الأمر بنموذج
 * الشركة نفسه، في متصفّح حقيقيّ تحت **ترويسات الإنتاج**
 * (scripts/csp-preview-server.mjs يخدم `_headers` حرفيّاً).
 *
 * لماذا متصفّح لا تأكيدات نصّية: الميزتان كلتاهما أحداثُ منصّة لا تُقاس بقراءة
 * الشيفرة — `ClipboardEvent` بحمولتَي `text/plain` و`text/html`، و`fetch` لأصل
 * الصفحة، و`DecompressionStream`، وتنزيل Blob. وCSP الإنتاج هو الحَكَم: سبق في
 * هذا المشروع أن نجح مسارٌ محليّاً وسقط تحت `connect-src` (سابقة `blob:` في pdf.js).
 *
 * ⚠️ كل فحص يبدأ بـ`blockSupabase` — لا فحص يلمس قاعدة الإنتاج (app-boot.mjs).
 * ⚠️ استيراد **نسبيّ**: مسار المستودع على العدّاء `/home/runner/work/MR/MR`.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const URL_ = 'http://127.0.0.1:8812/index.html';
let pass = 0, fail = 0;
const T = (name, cond, detail) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (detail ? '  → ' + detail : '')); }
};

/* لصقة إكسل حقيقية: النصّ TSV والـHTML جدولٌ كما يضعه إكسل في الحافظة. */
const TSV = [
  'م\tالصنف\tالوحدة\tالكمية\tالسعر الإفرادي\tالسعر الإجمالي',
  '1\tمطهر ديتول ( 1 لتر الأصلي )\tكرتون\t2\t250\t500',
  '2\tممسحة رطبة ( موب باكستاني )\tحبه\t15\t17\t255',
  '3\tمعطر جو ( كوتاج )\tكرتون\t3\t١٩٠٫٥٠ ر.س\t571.5',
  'الإجمالي (قبل الضريبة)\t\t\t\t\t1326.5',
].join('\n');
const HTML_CLIP = `<table><tr><td>م</td><td>الصنف</td><td>الوحدة</td><td>الكمية</td><td>السعر الإفرادي</td></tr>`
  + `<tr><td>1</td><td>كابل نحاس 3×2.5</td><td>متر</td><td>100</td><td>12.5</td></tr>`
  + `<tr><td>2</td><td>قاطع كهربائي 32A</td><td>حبة</td><td>8</td><td>45</td></tr></table>`;

const PO = {
  po_number: 'P.O-DG26-3301', supplier: 'شركة الاعمال الذهبية التجارية', project: 'برج الشمال',
  sector: 'الصيانة والتشغيل', payment_method: 'اجل ( 45 يوم )', officer: 'مصطفى خليل احمد',
  status: 'قيد المراجعة', issue_date: '2026-09-16', expected_delivery: '2026-09-18', subtotal: 1089,
  items: [{ desc: 'مطهر ديتول ( 1 لتر الأصلي )', unit: 'كرتون', qty: 1, price: 250 },
          { desc: 'ممسحة رطبة ( موب باكستاني )', unit: 'حبه', qty: 15, price: 17 },
          { desc: 'معطر جو ( كوتاج )', unit: 'كرتون', qty: 3, price: 190 },
          { desc: 'فرشاه سجاد ', unit: 'حبه', qty: 4, price: 3.5 }],
  status_history: [],
};
const SUPPLIER = { name: 'شركة الاعمال الذهبية التجارية', city: 'الرياض', address: 'الرياض',
  tax_id: '310298126400003', contact: 'علي الزينى', mobile: '0554772274', commercial_reg: '', email: '', phone: '' };

const FULL = { can_create_po: true, can_edit_po: true, can_export: true, can_view_amounts: true };
const NOMONEY = { can_create_po: true, can_edit_po: true, can_export: true, can_view_amounts: false };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, acceptDownloads: true });
await blockSupabase(ctx);
const page = await ctx.newPage();
const errs = [], csp = [];
page.on('pageerror', (e) => errs.push(String(e)));
page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await page.goto(URL_, { waitUntil: 'domcontentloaded' });
await enterApp(page);

/* ⚠️ `enterApp` يُظهِر التطبيق لكنّه **لا يُشغّل `startApp()`** — ومنها
   `setupPOEvents()` التي تربط مستمعات اللصق. مُقاس: `__APP_STARTED` يبقى
   `undefined` بعد الإقلاع في الحزمة، فلا فحص متصفّح في المستودع كان يمرّ على
   أيّ مستمع تربطه تلك الدالّة — ومستمعٌ يسقط منها يمرّ أخضرَ في كل الفحوص.
   فنُشغّلها هنا كما يفعل التطبيق بعد الدخول، ثمّ نُعيد إنهاء الترطيب. */
/* ⚠️ و`__APP_STARTED` يُقرأ اسماً **مجرّداً**: `let` على المستوى الأعلى ارتباطٌ
   معجميّ لا خاصيّة على `window` (سابقة `let SB` الموثّقة) — و`window.__APP_STARTED`
   يعود `undefined` دائماً فيبدو الإقلاع فاشلاً وهو ناجح. */
await page.evaluate(() => { try { startApp(); } catch (_) {} });
await page.waitForFunction(() => __APP_STARTED === true, { timeout: 15000 });
await page.evaluate(() => {
  try { window.hideLoginScreen(); } catch (_) {}
  try { window.hydSettle('ready'); } catch (_) {}
  document.body.classList.remove('data-loading');
});

async function seed(perms) {
  await page.evaluate(([po, sup, p]) => {
    STATE.currentUser = { username: 'proc.mgr', displayName: 'محمود العامودي', role: 'user',
      permissions: p, scopeSectors: [] };
    STATE.suppliers = [sup];
    STATE.purchaseOrders = [po].map((o) => { const c = JSON.parse(JSON.stringify(o)); recomputePOderived(c); return c; });
    try { applyUserRoleToUI(); } catch (_) {}
    navigate('purchase-orders');
  }, [PO, SUPPLIER, perms]);
  await page.waitForTimeout(120);
}
/* لصقٌ حقيقيّ: حدث `paste` بحمولة حافظة، على الهدف الذي يلمسه المستخدم. */
async function paste(selector, text, html) {
  return page.evaluate(([sel, t, h]) => {
    const dt = new DataTransfer();
    if (t) dt.setData('text/plain', t);
    if (h) dt.setData('text/html', h);
    const el = document.querySelector(sel);
    el.focus();
    const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
    el.dispatchEvent(ev);
    return ev.defaultPrevented;
  }, [selector, text || '', html || '']);
}
const rows = () => page.evaluate(() => [...document.querySelectorAll('#po-items-rows .po-item-row')]
  .map((r) => { const o = {}; r.querySelectorAll('input').forEach((i) => { o[i.dataset.k] = i.value; }); return o; }));

console.log('\n① اللصق داخل صفوف البنود مباشرةً');
await seed(FULL);
await page.evaluate(() => openPOModal(null));
await page.waitForSelector('#modal-po.active, #modal-po', { timeout: 5000 });
await page.evaluate(() => { if (!document.querySelector('#po-items-rows .po-item-row')) addPOItemRow({}); });

const prevented = await paste('#po-items-rows .po-item-row input[data-k="desc"]', TSV, '');
const r1 = await rows();
T('اللصق داخل حقل البند يُخطَف ويُدرِج الجدول كلّه', prevented && r1.length === 3, JSON.stringify(r1));
T('ورأس الجدول يُسنِد الأعمدة صحيحاً (الوحدة قبل الكمية كما في النموذج)',
  r1[0] && r1[0].desc === 'مطهر ديتول ( 1 لتر الأصلي )' && r1[0].unit === 'كرتون'
  && r1[0].qty === '2' && r1[0].price === '250', JSON.stringify(r1[0]));
T('وسعرٌ بأرقام هندية ورمز «ر.س» يُقرأ صحيحاً',
  r1[2] && r1[2].price === '190.5', JSON.stringify(r1[2]));
T('وصفّ الإجمالي لا يصير بنداً', !r1.some((r) => /الإجمالي/.test(r.desc)));
const subtotal = await page.evaluate(() => document.getElementById('po-f-subtotal').value);
T('والإجمالي يُحسب تلقائياً من البنود الملصوقة', Number(subtotal) === 2 * 250 + 15 * 17 + 3 * 190.5, subtotal);

console.log('\n② اللصق عبر الزرّ وصندوقه — وحمولة HTML كما يضعها إكسل');
await page.evaluate(() => document.getElementById('po-paste-items').click());
const boxShown = await page.evaluate(() => !document.getElementById('po-paste-box').hidden);
T('زرّ «لصق من إكسل» يفتح صندوق اللصق', boxShown);
await paste('#po-paste-box', 'كابل نحاس 3×2.5\tمتر\t100\t12.5', HTML_CLIP);
const r2 = await rows();
T('وجدول HTML يُقرأ (أدقّ من TSV) ويُلحَق بعد البنود القائمة لا يمحوها',
  r2.length === 5 && r2[3].desc === 'كابل نحاس 3×2.5' && r2[3].unit === 'متر'
  && r2[3].qty === '100' && r2[3].price === '12.5'
  && r2[0].desc === 'مطهر ديتول ( 1 لتر الأصلي )', JSON.stringify(r2.map((r) => r.desc)));
T('والصندوق ينغلق بعد اللصق', await page.evaluate(() => document.getElementById('po-paste-box').hidden));

/* ⚠️ لصقة خليّة واحدة يجب أن تبقى لصقاً عاديّاً داخل الحقل — لا تُخطَف. */
const single = await paste('#po-items-rows .po-item-row input[data-k="desc"]', 'صنف واحد', '');
T('ولصقة خليّة واحدة تبقى لصقاً عاديّاً (لا تُخطَف ولا تُنشئ صفوفاً)',
  single === false && (await rows()).length === 5);

/* ⚠️ الكاسر الحقيقيّ للأعمدة: لصقة **بلا رأس**. ترتيب نموذج الإكسل (وحدة ثمّ
   كمية) عكس ترتيب الشاشة (كمية ثمّ وحدة)، فافتراض أحدهما يقلب العمودين بصمت —
   والتمييز بالمحتوى هو ما يُنقذ. (لصقةٌ برأسٍ لا تمرّ بهذا المسار إطلاقاً.) */
await page.evaluate(() => { openPOModal(null); });
await page.waitForTimeout(120);
await page.evaluate(() => { if (!document.querySelector('#po-items-rows .po-item-row')) addPOItemRow({}); });
await paste('#po-items-rows .po-item-row input[data-k="desc"]',
  '1\tمطهر ديتول\tكرتون\t2\t250\t500\n2\tممسحة رطبة\tحبه\t15\t17\t255', '');
const r3 = await rows();
T('وبلا رأس بترتيب الإكسل (وحدة ثمّ كمية) يُقرأ صحيحاً',
  r3.length === 2 && r3[0].unit === 'كرتون' && r3[0].qty === '2' && r3[0].price === '250'
  && r3[1].unit === 'حبه' && r3[1].qty === '15' && r3[1].price === '17', JSON.stringify(r3));

/* ⚠️ والترتيب المعاكس (كمية ثمّ وحدة) هو ما يكشف افتراض الترتيب: `after[0]`
   هناك عمودٌ رقميّ لا الوحدة، فيسكن الرقم خانة الوحدة وتضيع الكمية. */
await page.evaluate(() => { document.getElementById('po-items-rows').innerHTML = ''; addPOItemRow({}); });
await paste('#po-items-rows .po-item-row input[data-k="desc"]',
  'مطهر ديتول\t2\tكرتون\t250\nممسحة رطبة\t15\tحبه\t17', '');
const r4 = await rows();
T('وبالترتيب المعاكس (كمية ثمّ وحدة) كذلك — التمييز بالمحتوى لا بالترتيب',
  r4.length === 2 && r4[0].unit === 'كرتون' && r4[0].qty === '2' && r4[0].price === '250'
  && r4[1].unit === 'حبه' && r4[1].qty === '15', JSON.stringify(r4));
await page.evaluate(() => closeModal('modal-po'));

console.log('\n③ التصدير بنموذج الشركة — ملفّ حقيقيّ يُقرأ ويُقارَن بالنموذج');
await page.evaluate((n) => openPODrawer(n), PO.po_number);
await page.waitForTimeout(150);
const btn = await page.evaluate(() => {
  const b = [...document.querySelectorAll('#po-drawer .po-drawer-actions button')]
    .find((x) => /نموذج إكسل/.test(x.textContent));
  return b ? { text: b.textContent.trim() } : null;
});
T('زرّ «نموذج إكسل» ظاهر في درج الأمر', !!btn, JSON.stringify(btn));

const [download] = await Promise.all([
  page.waitForEvent('download', { timeout: 20000 }),
  page.evaluate(() => [...document.querySelectorAll('#po-drawer .po-drawer-actions button')]
    .find((x) => /نموذج إكسل/.test(x.textContent)).click()),
]);
T('والتنزيل يحمل رقم الأمر اسماً', download.suggestedFilename() === `${PO.po_number}.xlsx`,
  download.suggestedFilename());
const saved = await download.path();
const bytes = new Uint8Array(fs.readFileSync(saved));
T('والملفّ المنزَّل أرشيف ZIP صالح بحجم معقول',
  bytes.length > 200000 && bytes[0] === 0x50 && bytes[1] === 0x4b, String(bytes.length));

/* ⚠️ المحكّ النهائيّ: أجزاء الشكل في الملفّ المنزَّل **بايتاتها** بايتات النموذج
   الذي رفعه المالك — لا مُعاد بناءً. يُقارَن داخل الصفحة بالدوال نفسها. */
const tplB64 = fs.readFileSync(path.join(ROOT, 'assets', 'po-template.xlsx')).toString('base64');
const outB64 = Buffer.from(bytes).toString('base64');
const cmp = await page.evaluate(([a, b]) => {
  const un = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const A = poZipRead(un(a)), B = poZipRead(un(b));
  const find = (l, n) => l.find((e) => e.name === n);
  const same = (n) => { const x = find(A, n), y = find(B, n);
    if (!x || !y || x.crc !== y.crc || x.csize !== y.csize) return false;
    for (let i = 0; i < x.data.length; i++) if (x.data[i] !== y.data[i]) return false;
    return true; };
  const COPIED = ['xl/styles.xml', 'xl/theme/theme1.xml', 'xl/media/image1.jpeg',
    'xl/printerSettings/printerSettings1.bin', 'xl/drawings/vmlDrawing1.vml',
    '[Content_Types].xml', 'xl/_rels/workbook.xml.rels', 'xl/worksheets/_rels/sheet1.xml.rels'];
  const sheet = new TextDecoder().decode(find(B, 'xl/worksheets/sheet1.xml').data);
  const sst = [...new TextDecoder().decode(find(B, 'xl/sharedStrings.xml').data)
    .matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map((m) => m[1]);
  const val = (ref) => { const m = new RegExp(`<c r="${ref}"[^>]*t="s"><v>(\\d+)</v>`).exec(sheet);
                         return m ? sst[+m[1]] : null; };
  return { copied: COPIED.filter((n) => !same(n)),
           parts: A.length === B.length,
           po: val('B4'), supplier: val('E12'), vat: val('E17'), contact: val('E18'),
           item1: val('B24'), item4: val('B27'), unit1: val('C24'),
           sum: /SUM\(F24:F27\)/.test(sheet), merges: (sheet.match(/<mergeCell /g) || []).length };
}, [tplB64, outB64]);
T('وأجزاء الشكل (الأنماط · الثيم · الشعار · إعداد الطابعة) بايتاتها بايتات نموذج المالك',
  cmp.copied.length === 0 && cmp.parts, cmp.copied.join(','));
T('وبيانات الأمر في خلاياها الصحيحة من النموذج',
  cmp.po === PO.po_number && cmp.supplier === PO.supplier
  && cmp.item1 === PO.items[0].desc && cmp.unit1 === 'كرتون' && cmp.item4 === PO.items[3].desc,
  JSON.stringify(cmp));
T('وبيانات المورد تُسحَب من دليل الموردين',
  cmp.vat === SUPPLIER.tax_id && cmp.contact === SUPPLIER.contact, JSON.stringify([cmp.vat, cmp.contact]));
T('والصيغ والدمج كما في النموذج', cmp.sum && cmp.merges === 47, String(cmp.merges));

console.log('\n④ بوّابة المبالغ');
await page.evaluate(() => closePODrawer && closePODrawer());
await seed(NOMONEY);
await page.evaluate((n) => openPODrawer(n), PO.po_number);
await page.waitForTimeout(150);
const gated = await page.evaluate(async (n) => {
  const shown = [...document.querySelectorAll('#po-drawer .po-drawer-actions button')]
    .some((x) => /نموذج إكسل/.test(x.textContent));
  const toasts = []; const real = window.toast;
  window.toast = (k, t, m) => toasts.push(`${k}|${t}|${m}`);
  await poExportTemplate(n);                       // استدعاء مباشر كما من الطرفية
  window.toast = real;
  return { shown, denied: toasts.some((t) => /صلاحية مرفوضة/.test(t)) };
}, PO.po_number);
T('الزرّ محجوب عمّن لا يرى المبالغ', !gated.shown);
T('والاستدعاء المباشر مرفوض لا مكشوف — النموذج مستندٌ مسعَّر', gated.denied, JSON.stringify(gated));

T('صفر خطأ صفحة', errs.length === 0, errs.join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.join(' | '));

console.log(`\n${'─'.repeat(46)}\nالنتيجة: ${pass} ناجح · ${fail} فاشل`);
await browser.close();
process.exit(fail ? 1 : 0);

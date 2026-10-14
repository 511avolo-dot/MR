/* وجهات الكتالوج على الشاشة الحقيقية تحت CSP الإنتاج: بحث مُطبَّع · سنّ السعر ·
   إسكات الأرقام المكرّرة · مرشّح الحالات · إعلان البتر · دقّة الإدخال.
   ⚠️ كتابةٌ في الحقول الحقيقية ونقرٌ حقيقيّ — لا استدعاء مباشر للدوال: علّة هذه
   الدفعة كانت في **المستمعين وفي نسخة ثانية من المرشّح**، لا في دالّة نقيّة.

     node scripts/csp-preview-server.mjs &
     node scripts/e2e/catalog-views.mjs                                        */
import { resolveChromiumExecutable } from './chromium-path.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');
import { blockSupabase, enterApp } from './app-boot.mjs';

const ORIGIN = 'http://127.0.0.1:8812';
const checks = [];
const ok = (n, p, d) => checks.push({ n, p, d });

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 950 }, locale: 'ar-SA' });
const page = await ctx.newPage();
const errors = [], csp = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await blockSupabase(ctx);
await page.goto(`${ORIGIN}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.itemsVisibleList === 'function', { timeout: 15000 });
await enterApp(page);

const days = (n) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);
const seed = async () => page.evaluate((d) => {
  STATE.currentUser = { username:'abdullah', display_name:'عبدالله', role:'admin', permissions:{} };
  try { hideLoginScreen(); } catch (e) {}
  try { hydSettle('ready'); } catch (e) {}
  CLOUD.enabled = false; CLOUD.client = null;
  STATE.items = [
    { code:'A-1', name:'عربة قمامة، Baiyun، بعجلات', category:'أدوات', unit:'قطعة',
      last_price:50, avg_price:60, min_price:40, max_price:80, offers:3, last_date:d.fresh, last_supplier:'مورد أ' },
    { code:'B-1', name:'كفوف فينيل أسود شد 10', category:'مواد نظافة', unit:'علبة',
      last_price:12, avg_price:12, min_price:12, max_price:12, offers:1, last_date:d.old, last_supplier:'مورد ب' },
    { code:'C-1', name:'صابون سائل معطّر 4 لتر', category:'مواد نظافة', unit:'جالون',
      last_price:null, avg_price:null, min_price:null, max_price:null, offers:0, last_date:null },
  ];
  STATE.history = [
    { num:1, code:'A-1', name:'عربة قمامة، Baiyun، بعجلات', category:'أدوات', price:50, unit:'قطعة', supplier:'شركة النظافة المتقدمة', date:d.fresh, reference:'PO:3101#1' },
    { num:2, code:'A-1', name:'عربة قمامة، Baiyun، بعجلات', category:'أدوات', price:44, unit:'قطعة', supplier:'مؤسسة الرياض', date:d.mid, reference:'يدوي' },
    { num:3, code:'A-1', name:'عربة قمامة، Baiyun، بعجلات', category:'أدوات', price:80, unit:'قطعة', supplier:'مورد ثالث', date:d.old, reference:'يدوي' },
    { num:4, code:'A-1', name:'عربة قمامة، Baiyun، بعجلات', category:'أدوات', price:40, unit:'قطعة', supplier:'مورد رابع', date:d.older, reference:'يدوي' },
  ];
  STATE.suppliers = [{ id:'s1', name:'شركة النظافة المتقدمة' }];
  SI_ALIASES_BY_CODE = {};
  STATE.itemsFilter = { q:'', category:'', flag:'', sort:'code' };
  STATE.histFilter = { q:'', category:'', supplier:'', from:'', to:'', sort:'num', dir:'desc' };
}, { fresh: days(10), mid: days(60), old: days(500), older: days(900) });

await seed();
await page.evaluate(() => { try { startApp(); } catch (_) {} });
await seed();                                  // الإقلاع يُعيد الرسم — نُعيد البذر بعده
await page.evaluate(() => navigate('items'));
await page.waitForSelector('#items-tbody tr', { timeout: 8000 });

/* ── ١) بحث الأصناف: كتابةٌ حقيقية بالكتابة البديلة ── */
const typeItems = async (q) => {
  await page.fill('#items-search', '');
  await page.type('#items-search', q, { delay: 5 });
  await page.waitForTimeout(90);
  return page.evaluate(() => [...document.querySelectorAll('#items-tbody tr[data-code]')].map(t => t.dataset.code));
};
ok('⚠️ «عربه» تجد «عربة» على الشاشة (كانت صفراً)', (await typeItems('عربه')).includes('A-1'));
ok('و«اسود» تجد «أسود»', (await typeItems('اسود')).includes('B-1'));
ok('ورموز بأي ترتيب: «اسود كفوف»', (await typeItems('اسود كفوف')).includes('B-1'));
ok('والكود يعمل', (await typeItems('C-1')).includes('C-1'));
ok('وبحثٌ لا وجود له يُفرغ الجدول', (await typeItems('زززز')).length === 0);
await page.fill('#items-search', '');
await page.waitForTimeout(90);

/* ── ٢) الأرقام المكرّرة تُسكَت · «غير مُقارَن» · شارة القِدَم ── */
const row = async (code) => page.evaluate((c) => {
  const tr = document.querySelector(`#items-tbody tr[data-code="${c}"]`);
  if (!tr) return null;
  const td = [...tr.querySelectorAll('td')].map(x => x.textContent.trim());
  return { cells: td, cls: tr.className, html: tr.innerHTML };
}, code);
const rA = await row('A-1'), rB = await row('B-1');
ok('صنفٌ بثلاثة عروض يُظهر متوسطه وأدناه وأعلاه', rA && !/^—$/.test(rA.cells[5]) && !/^—$/.test(rA.cells[6]) && !/^—$/.test(rA.cells[7]),
  rA && rA.cells.slice(5, 8).join('|'));
ok('⚠️ وصنفٌ بعرض واحد يُسكِت الأرقام الثلاث المكرّرة',
  rB && rB.cells[5] === '—' && rB.cells[6] === '—' && rB.cells[7] === '—', rB && rB.cells.slice(5, 8).join('|'));
ok('ويُعلَن أنّ سعره غير مُقارَن', rB && /غير مُقارَن/.test(rB.html));
ok('والمُقارَن لا يحمل ذلك الوسم', rA && !/غير مُقارَن/.test(rA.html));
ok('⚠️ وسعرٌ أقدم من سنة يحمل شارة عمره', rB && /منذ \d+ شهراً/.test(rB.html) && /row-stale-price/.test(rB.cls), rB && rB.cls);
ok('وسعرٌ حديث بلا شارة قِدَم', rA && !/منذ/.test(rA.html) && !/row-stale-price/.test(rA.cls));

/* ── ٣) مرشّح الحالات: اختيارٌ حقيقيّ من القائمة ── */
const flag = async (v) => { await page.selectOption('#items-flag', v); await page.waitForTimeout(90);
  return page.evaluate(() => [...document.querySelectorAll('#items-tbody tr[data-code]')].map(t => t.dataset.code)); };
ok('مرشّح «أسعار قديمة» يُرجع القديم وحده', JSON.stringify(await flag('stale')) === JSON.stringify(['B-1']));
ok('ومرشّح «غير مُقارَن» يُرجع صاحب العرض الواحد', JSON.stringify(await flag('single')) === JSON.stringify(['B-1']));
ok('ومرشّح «بلا سعر» يُرجع ما لا سعر له', JSON.stringify(await flag('noprice')) === JSON.stringify(['C-1']));
ok('و«كل الحالات» تُعيد الثلاثة', (await flag('')).length === 3);

/* ── ٤) «تحديد الكل» يُحدِّد المعروض نفسه لا غيره (العيب الذي أمسكه الحارس) ── */
const selected = await page.evaluate(async () => {
  STATE.itemsFilter.flag = 'stale'; STATE.itemsPage = 1;
  document.getElementById('items-flag').value = 'stale';
  renderItems();
  if (!STATE.itemsSelectMode) document.getElementById('select-mode-btn').click();
  await new Promise(r => setTimeout(r, 60));
  document.getElementById('sel-all').click();
  await new Promise(r => setTimeout(r, 60));
  return [...STATE.itemsSelected];
});
ok('⚠️ «تحديد الكل» مع مرشّح نشط يُحدِّد الصفّ المعروض وحده',
  JSON.stringify(selected) === JSON.stringify(['B-1']), JSON.stringify(selected));

/* ── ٥) السجل السعريّ: مورد بكتابة مختلفة ── */
await page.evaluate(() => { STATE.itemsFilter.flag=''; STATE.itemsSelectMode=false; STATE.itemsSelected.clear(); navigate('history'); });
await page.waitForSelector('#hist-tbody tr', { timeout: 8000 });
const typeHist = async (q) => { await page.fill('#hist-search', ''); await page.type('#hist-search', q, { delay: 5 });
  await page.waitForTimeout(90);
  return page.evaluate(() => [...document.querySelectorAll('#hist-tbody tr[data-num]')].map(t => t.dataset.num)); };
ok('⚠️ «شركه» تجد «شركة النظافة» في السجل (كانت صفراً)', (await typeHist('شركه')).includes('1'));
ok('و«عربه قمامه» تجد صفوف الصنف', (await typeHist('عربه قمامه')).length === 4);
ok('والمرجع حرفيّاً', (await typeHist('PO:3101')).includes('1'));
await page.fill('#hist-search', '');

/* ── ٦) التسعير الذكيّ: بحث مُطبَّع + إعلان البتر ── */
await page.evaluate(() => navigate('pricing'));
await page.waitForSelector('#sp-search', { timeout: 8000 });
/* ⚠️ مربّع التسعير مخنوق 180ms — أي انتظار أقلّ يقيس **الحالة السابقة**، والمعالِج
   المتأخّر ينقض أي استدعاء مباشر بعده. (أسقط هذا الفحصَ مرّتين قبل أن يُقاس.) */
const SP_DEBOUNCE_WAIT = 320;
const typeSp = async (q) => { await page.fill('#sp-search', ''); await page.type('#sp-search', q, { delay: 5 });
  await page.waitForTimeout(SP_DEBOUNCE_WAIT);
  return page.evaluate(() => [...document.querySelectorAll('#sp-results [data-sp-add]')].map(e => e.getAttribute('data-sp-add'))); };
ok('⚠️ «عربه» تجد الصنف في التسعير (كانت صفراً)', (await typeSp('عربه')).includes('A-1'));
/* البتر يُقاس عبر المسار الحقيقيّ (كتابة في الحقل) لا باستدعاء مباشر. */
await page.evaluate(() => {
  STATE.items = Array.from({ length: 120 }, (_, k) => ({ code:'Z-'+k, name:'صنف اختبار '+k, category:'أدوات', unit:'حبة', last_price:10+k, offers:1, last_date:new Date().toISOString().slice(0,10) }));
});
await page.fill('#sp-search', '');
await page.type('#sp-search', 'صنف اختبار', { delay: 5 });
await page.waitForTimeout(SP_DEBOUNCE_WAIT);
const trunc = await page.evaluate(() => {
  const box = document.getElementById('sp-results');
  return { shown: box.querySelectorAll('[data-sp-add]').length, notice: /عرض أول 80 من/.test(box.textContent) };
});
ok('⚠️ وبتر النتائج يُعلَن لا يقع صامتاً', trunc.shown === 80 && trunc.notice, JSON.stringify(trunc));

/* ── ٧) دقّة الإدخال: آخر الأسعار الفعلية + تنبيه الانحراف أثناء الكتابة ── */
await seed();
await page.evaluate(() => navigate('entry'));
await page.waitForSelector('#f-code', { timeout: 8000 });
await page.fill('#f-code', '');
await page.type('#f-code', 'عربه', { delay: 6 });
await page.waitForTimeout(140);
const pick = await page.evaluate(() => !!document.querySelector('#suggest-box .suggest-item[data-code="A-1"]'));
ok('البحث المُطبَّع يعمل في مربّع الإدخال أيضاً', pick);
if (pick) await page.click('#suggest-box .suggest-item[data-code="A-1"]');
await page.waitForTimeout(120);
const recent = await page.evaluate(() => {
  const b = document.getElementById('pv-recent');
  return { rows: [...b.querySelectorAll('.pv-recent-row')].map(r => r.textContent.replace(/\s+/g,' ').trim()),
           title: /آخر الأسعار المسجَّلة/.test(b.textContent) };
});
ok('⚠️ معاينة الإدخال تعرض آخر الأسعار **المسجَّلة فعلاً** (مورد · تاريخ · سعر)',
  recent.title && recent.rows.length === 3 && /شركة النظافة/.test(recent.rows[0]), JSON.stringify(recent.rows));
ok('وثلاثة لا أكثر، الأحدث أولاً', recent.rows.length === 3 && /50/.test(recent.rows[0]) && /80/.test(recent.rows[2]));

const devOf = async (v) => { await page.fill('#f-price', ''); await page.type('#f-price', String(v), { delay: 5 });
  await page.waitForTimeout(80);
  return page.evaluate(() => { const el = document.getElementById('f-price-hint');
    return { shown: el.style.display !== 'none' && !!el.textContent.trim(), txt: el.textContent.replace(/\s+/g,' ').trim() }; }); };
const d100 = await devOf(100), d55 = await devOf(55), d10 = await devOf(10);
ok('⚠️ سعرٌ أعلى بـ100% يُنبَّه **أثناء الكتابة**', d100.shown && /أعلى بـ100%/.test(d100.txt), d100.txt);
ok('وانحرافٌ دون العتبة لا يُنبَّه', !d55.shown, d55.txt);
ok('وانخفاضٌ كبير يُنبَّه باتجاهه', d10.shown && /أقل بـ80%/.test(d10.txt), d10.txt);
/* ⚠️ يُستدعى `clearPreview` نفسها لا `clearForm`: الثانية تُصفّر `selectedItem`
   بنفسها فيصير التأكيد عليها **فراغيّاً** (أمسكه البيت-بروف: حذف التصفير من
   `clearPreview` لم يُفشِل شيئاً). وclearPreview هي من يملك الثلاثة. */
const cleared = await page.evaluate(() => { clearPreview();
  const el = document.getElementById('f-price-hint');
  return { hint: el.textContent.trim(), rec: document.getElementById('pv-recent').textContent.trim(), sel: STATE.selectedItem }; });
ok('⚠️ وإخفاء المعاينة يُصفّر التلميح وآخر الأسعار والصنف المختار',
  !cleared.hint && !cleared.rec && cleared.sel === null, JSON.stringify(cleared).slice(0, 80));
const clearedForm = await page.evaluate(() => { showPreview(STATE.items.find(i => i.code === 'A-1')); clearForm();
  return { hint: document.getElementById('f-price-hint').textContent.trim(), sel: STATE.selectedItem, price: document.getElementById('f-price').value }; });
ok('وتفريغ النموذج كذلك', !clearedForm.hint && clearedForm.sel === null && !clearedForm.price, JSON.stringify(clearedForm).slice(0, 80));

/* ── ٨) دقّة السجل: الملاحظة الواحدة · التمايز · ما يحتاج مراجعة ──
   ⚠️ النمط الحقيقيّ من بيانات الإنتاج: مرجعان مختلفان لنفس أمر الشراء
   (`PO-101` / `P.O-DG26-3101`) — 116 من 127 مجموعة مكرّرة على هذا الشكل. */
await page.evaluate((d) => {
  STATE.items = [
    { code:'A-1', name:'عربة قمامة، Baiyun، بعجلات', category:'أدوات', unit:'قطعة' },
    { code:'B-1', name:'كفوف فينيل أسود شد 10', category:'مواد نظافة', unit:'علبة' },
    { code:'D-1', name:'صابون سائل معطّر 4 لتر', category:'مواد نظافة', unit:'جالون' },
  ];
  const row = (o) => Object.assign({ name:'صنف', category:'أدوات', unit:'حبة', supplier:'شركة النظافة المتقدمة', price:50, date:d.fresh, reference:'' }, o);
  STATE.history = [
    row({ num:1, code:'A-1', name:'عربة قمامة، Baiyun، بعجلات', reference:'PO-101' }),
    row({ num:2, code:'A-1', name:'عربة قمامة، Baiyun، بعجلات', reference:'P.O-DG26-3101' }),
    row({ num:3, code:'B-1', name:'كفوف فينيل أسود شد 10', price:40 }),
    row({ num:4, code:'B-1', name:'كفوف فينيل أسود شد 10', price:80, supplier:'مؤسسة الرياض' }),
    row({ num:5, code:'D-1', name:'صابون سائل معطّر 4 لتر', price:30 }),
    row({ num:6, code:'D-1', name:'صابون سائل معطّر 4 لتر', price:30, supplier:'مؤسسة الرياض' }),
    row({ num:7, code:'NEW', name:'بند غير مُكوَّد من الإكسل', price:17 }),
  ];
  STATE.itemsFilter = { q:'', category:'', flag:'', sort:'code' };
  STATE.histFilter = { q:'', category:'', supplier:'', from:'', to:'', flag:'', sort:'num', dir:'desc' };
  recomputeItemStats();
  navigate('items');
}, { fresh: days(10) });
await page.waitForSelector('#items-tbody tr[data-code]', { timeout: 8000 });
const cells = await page.evaluate(() => {
  const out = {};
  for (const tr of document.querySelectorAll('#items-tbody tr[data-code]')) {
    const td = tr.querySelectorAll('td');
    out[tr.dataset.code] = {
      avg: td[5].textContent.trim(), min: td[6].textContent.trim(), max: td[7].textContent.trim(),
      offers: td[8].textContent.trim(), title: (td[8].querySelector('[title]') || {}).title || '',
    };
  }
  return out;
});
ok('⚠️ مرجعان لنفس أمر الشراء ⇒ «غير مُقارَن» لا «عرضان» (كان يُقرأ مُقارَناً)',
  /غير مُقارَن/.test(cells['A-1'].offers), JSON.stringify(cells['A-1']));
ok('وأرقامه الثلاث مُسكَتة',
  cells['A-1'].avg === '—' && cells['A-1'].min === '—' && cells['A-1'].max === '—', JSON.stringify(cells['A-1']));
ok('والتلميح يقول إنّ سجلّاً مكرّراً لم يُحتسَب — بصيغة عدد عربية صحيحة',
  /سجلّ واحد مكرّر لم يُحتسَب/.test(cells['A-1'].title) && !/^1 سجلّاً/.test(cells['A-1'].title), cells['A-1'].title);
ok('وسعران متمايزان: الأرقام تظهر والعدّاد عددٌ مجرّد',
  cells['B-1'].avg !== '—' && cells['B-1'].min !== '—' && /^2$/.test(cells['B-1'].offers) && /ملاحظات سعرية متمايزة: 2/.test(cells['B-1'].title), JSON.stringify(cells['B-1']));
ok('⚠️ وعرضان بنفس السعر من موردين: «أسعار متطابقة» لا رقمٌ مكرّر ثلاثاً',
  /أسعار متطابقة/.test(cells['D-1'].offers) && cells['D-1'].avg === '—'
  && /ملاحظتان بنفس السعر/.test(cells['D-1'].title), JSON.stringify(cells['D-1']));
const flagCount = await page.evaluate(() => {
  STATE.itemsFilter.flag = 'single';
  document.getElementById('items-flag').value = 'single';
  renderItems();
  return [...document.querySelectorAll('#items-tbody tr[data-code]')].map(t => t.dataset.code);
});
ok('ومرشّح «غير مُقارَن» يشمل العروض المتطابقة لا العرض الواحد وحده',
  flagCount.includes('A-1') && flagCount.includes('D-1') && !flagCount.includes('B-1'), JSON.stringify(flagCount));
await page.evaluate(() => { STATE.itemsFilter.flag = ''; document.getElementById('items-flag').value = ''; renderItems(); navigate('history'); });
await page.waitForSelector('#hist-tbody tr', { timeout: 8000 });
const note = await page.evaluate(() => {
  const box = document.getElementById('hist-flag-note');
  return { shown: box.style.display !== 'none', text: box.textContent.replace(/\s+/g, ' ').trim(),
    links: [...box.querySelectorAll('[data-hist-flag]')].map(a => a.getAttribute('data-hist-flag')) };
});
ok('⚠️ سطر «يحتاج مراجعة» يُعلِن المكرّر والمنفصل بالأرقام',
  note.shown && /مجموعة واحدة مكرّرة/.test(note.text) && /سجلّ واحد لم يُحتسَب/.test(note.text)
  && /سجلّ واحد بلا صنف مرتبط/.test(note.text), note.text);
/* ⚠️ الرابطان يُتحقَّق من وجودهما **قبل** النقر: بلا ذلك يسقط الفحص باستثناء
   خامّ (`null.click`) فلا يقول أيّ ثابت انكسر — أمسكه البيت-بروف على رصد المنفصل. */
ok('ورابطا التصفية موجودان فعلاً في السطر',
  note.links.includes('dup') && note.links.includes('orphan'), JSON.stringify(note.links));
const clickFlag = (f) => page.evaluate(async (flag) => {
  const a = document.querySelector(`#hist-flag-note [data-hist-flag="${flag}"]`);
  if (!a) return { missing: true, nums: [], sel: '' };
  a.click();
  await new Promise(r => setTimeout(r, 60));
  return { missing: false, nums: [...document.querySelectorAll('#hist-tbody tr[data-num]')].map(t => +t.dataset.num), sel: document.getElementById('hist-flag').value };
}, f);
const dupRows = await clickFlag('dup');
ok('ونقر الرقم يُصفّي إلى **طرفَي** المجموعة معاً (المراجعة تحتاجهما)',
  !dupRows.missing && dupRows.nums.length === 2 && dupRows.nums.includes(1) && dupRows.nums.includes(2) && dupRows.sel === 'dup',
  JSON.stringify(dupRows));
const orphanRows = await clickFlag('orphan');
ok('و«بلا صنف مرتبط» يُصفّي إلى الصفّ الذي لا يصل أيّ صنف',
  !orphanRows.missing && orphanRows.nums.length === 1 && orphanRows.nums[0] === 7, JSON.stringify(orphanRows));
const cleanState = await page.evaluate(async () => {
  STATE.history = STATE.history.filter(h => h.num === 3 || h.num === 4);
  STATE.histFilter.flag = ''; document.getElementById('hist-flag').value = '';
  renderHistory(); await new Promise(r => setTimeout(r, 40));
  const box = document.getElementById('hist-flag-note');
  return { shown: box.style.display !== 'none', html: box.innerHTML };
});
ok('وسجلٌّ نظيف يُخفي السطر (سطرٌ صفريّ ضجيج)', !cleanState.shown && !cleanState.html, JSON.stringify(cleanState));

/* ── ١٠) ربط صفٍّ منفصل بصنف — نقرٌ حقيقيّ على الزرّ الحقيقيّ ──
   ⚠️ العلّة التي استدعت هذا: الرمز النائب `NEW` كان يدمج صنفين مختلفين في
   «نسخة واحدة»، و«بلا صنف مرتبط» كان عدّاداً بلا علاج في النظام كلّه. */
await page.setViewportSize({ width: 1440, height: 950 });
await page.evaluate(async () => {
  STATE.items = [
    { code:'IT-050', name:'حبر طابعة HP 953XL، سيان', category:'تقنية', unit:'حبة' },
    { code:'IT-051', name:'حبر طابعة HP 953XL، ماجنتا', category:'تقنية', unit:'حبة' }
  ];
  /* الحالة الحقيقية من الإنتاج: بندان على الفاتورة 2538 نفسها بنفس السعر. */
  STATE.history = [
    { num:670, code:'NEW', name:'حبر طابعة HP 953XL، سيان',   supplier:'مؤسسة ارتباط التكنولوجيا', price:139.13, date:'2025-11-19', reference:'2538', unit:'حبة', _user:true, _cloud:true },
    { num:671, code:'NEW', name:'حبر طابعة HP 953XL، ماجنتا', supplier:'مؤسسة ارتباط التكنولوجيا', price:139.13, date:'2025-11-19', reference:'2538', unit:'حبة', _user:true, _cloud:true }
  ];
  STATE.histFilter = { q:'', category:'', supplier:'', from:'', to:'', sort:'date-desc', flag:'' };
  STATE.histPage = 1;
  navigate('history'); recomputeItemStats(); renderHistory();
  await new Promise(r => setTimeout(r, 120));
});

const banner = await page.evaluate(() => {
  const b = document.getElementById('hist-flag-note');
  return { shown: b.style.display !== 'none', text: b.textContent || '' };
});
ok('⚠️ صنفان مختلفان برمز نائب لا يُبلَّغان مكرّرَين',
  banner.shown && !/مكرّرة/.test(banner.text), JSON.stringify(banner));
ok('ويُبلَّغان «بلا صنف مرتبط»', /بلا صنف مرتبط/.test(banner.text), banner.text);

const btns = await page.evaluate(() =>
  [...document.querySelectorAll('#hist-tbody [data-action="link-entry"]')].map(b => +b.dataset.num));
ok('وزرّ الربط معروضٌ لكلا الصفّين المنفصلَين', btns.length === 2 && btns.includes(670) && btns.includes(671), JSON.stringify(btns));

await page.click('#hist-tbody [data-action="link-entry"][data-num="671"]');
await page.waitForSelector('#modal-link-entry', { timeout: 4000 });
const proposal = await page.evaluate(() => {
  const m = document.getElementById('modal-link-entry');
  const rows = [...m.querySelectorAll('#le-results tbody tr')].map(tr => tr.querySelector('.mono')?.textContent?.trim());
  return { head: m.querySelector('#le-results .muted')?.textContent || '', rows, open: !!m };
});
ok('⚠️ والمُحلِّل يقترح الصنف الصحيح (ماجنتا لا سيان)',
  proposal.rows[0] === 'IT-051', JSON.stringify(proposal));

await page.click('#modal-link-entry [data-link-code="IT-051"]');
await page.waitForTimeout(260);
const after = await page.evaluate(() => {
  const h = STATE.history.find(x => x.num === 671);
  const other = STATE.history.find(x => x.num === 670);
  const b = document.getElementById('hist-flag-note');
  return { code: h.code, name: h.name, otherCode: other.code,
           modal: !!document.getElementById('modal-link-entry'),
           lock: document.body.style.overflow || '',
           banner: b.textContent || '' };
});
ok('والربط يضبط الرمز', after.code === 'IT-051', after.code);
ok('⚠️ ولا يستبدل وصف المورّد', after.name === 'حبر طابعة HP 953XL، ماجنتا', after.name);
ok('ولا يمسّ الصفّ الآخر', after.otherCode === 'NEW', after.otherCode);
ok('والنافذة تُزال ويُفَكّ قفل التمرير', !after.modal && after.lock === '', JSON.stringify(after));
ok('والعدّاد ينقص بعد الربط', /سجلّ واحد بلا صنف مرتبط/.test(after.banner), after.banner);

/* ── ٩) الجوال والسلامة ── */
await page.setViewportSize({ width: 393, height: 852 });
const mob = await page.evaluate(async () => {
  const r = {};
  for (const p of ['items','history','pricing','entry']) {
    navigate(p); await new Promise(x => setTimeout(x, 120));
    document.documentElement.style.overflowX = 'visible';
    r[p] = Math.max(0, document.documentElement.scrollWidth - document.documentElement.clientWidth);
    document.documentElement.style.overflowX = '';
  }
  return r;
});
ok('صفر انزلاق أفقيّ على 393px في الشاشات الأربع',
  Object.values(mob).every(v => v === 0), JSON.stringify(mob));
ok('صفر خطأ صفحة', errors.length === 0, errors[0]);
ok('صفر انتهاك CSP', csp.length === 0, csp[0]);

await browser.close();
let bad = 0;
for (const c of checks) { if (!c.p) bad++; console.log(`${c.p ? '✓' : '✗ FAIL'}  ${c.n}${c.d ? '  → ' + c.d : ''}`); }
if (bad) { console.error(`\n❌ ${bad} فحص فشل`); process.exit(1); }
console.log(`\n✅ ${checks.length}/${checks.length} فحصاً نجحت`);

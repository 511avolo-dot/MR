/* ══════════════════════════════════════════════════════════════════════
   التسعير الذكيّ — حارس التكرار والبحث الذكيّ على الشاشة الحقيقيّة تحت CSP الإنتاج
   ----------------------------------------------------------------------
   توجيه المالك: «ولا يكررها أو يربطها في بند خاطئ». الحزمة تُثبت المنطق؛
   هذا يُثبت أنّ **الشاشة** تفعل ما يقوله المنطق: مربّع البحث الحقيقيّ يُرسَم
   بنتائجه، ونافذة التأكيد تمنع التكرار فعلاً، والطريق الآخر يبقى متاحاً.

   ⚠️ كتابة في الحقول الحقيقية ونقرٌ حقيقيّ — لا استدعاء مباشر للدوال: علّة
   هذه الدفعة (بحث substring خامّ) كانت في المستمع لا في الدالّة.

     node scripts/csp-preview-server.mjs &
     node scripts/e2e/smart-pricing.mjs
   ══════════════════════════════════════════════════════════════════════ */
import { resolveChromiumExecutable } from './chromium-path.mjs';
/* ⚠️ استيراد نسبيّ: مسار المستودع على العدّاء /home/runner/work/MR/MR،
   فـ`import 'playwright'` يفشل بـERR_MODULE_NOT_FOUND هناك. */
const { chromium } = await import('../../node_modules/playwright/index.mjs');
import { blockSupabase, enterApp } from './app-boot.mjs';

const ORIGIN = 'http://127.0.0.1:8812';
const checks = [];
const ok = (n, p, d) => checks.push({ n, p, d });

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const ctx = await browser.newContext({ viewport: { width: 1280, height: 950 }, locale: 'ar-SA' });
const page = await ctx.newPage();
const errors = [], csp = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await blockSupabase(ctx);   // انظر app-boot.mjs — لا فحص يلمس الإنتاج
await page.goto(`${ORIGIN}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.siResolveItem === 'function', { timeout: 15000 });
await enterApp(page);

/* كتالوج صغير من أسماء **حقيقية** في الكتالوج (بذرة الملف) + مرادف معتمد. */
await page.evaluate(() => {
  STATE.currentUser = { username:'abdullah', display_name:'عبدالله', role:'admin', permissions:{} };
  try { hideLoginScreen(); } catch (e) {}
  try { hydSettle('ready'); } catch (e) {}
  CLOUD.enabled = false; CLOUD.client = null;          // الحفظ محليّ — لا كتابة سحابية
  STATE.items = [
    { code:'CLN-Q0101', name:'منظف أرضيات Green Seal، 3.78 لتر', category:'مواد نظافة', unit:'جالون', last_price:38, offers:3 },
    { code:'CLN-Q0102', name:'كفوف فينيل أسود شد 10',            category:'مواد نظافة', unit:'علبة',  last_price:12, offers:2 },
    { code:'ELE-Q0103', name:'مكنسة كهربائية رطب/جاف، CRS1625',  category:'أجهزة',      unit:'قطعة',  last_price:4200, offers:1 },
  ];
  STATE.history = []; STATE.suppliers = [{ id:'s1', name:'شركة النظافة المتقدمة' }];
  SI_ALIASES_BY_CODE = { 'CLN-Q0101': ['floor cleaner green seal 1 gallon'] };
  window.__audits = [];
});
/* ⚠️ `enterApp` يُظهِر التطبيق ولا يُشغّل `startApp()` — ومنها `setupEntry()`
   التي تربط مستمع `input` على #f-code. وعلّة هذه الدفعة كانت في **المستمع**
   (بحث substring خامّ)، فاختبارٌ لا يُقلع التطبيق يمرّ أخضرَ على الدوام. */
await page.evaluate(() => { try { startApp(); } catch (_) {} });
await page.evaluate(() => {
  CLOUD.enabled = false; CLOUD.client = null;
  STATE.items = [
    { code:'CLN-Q0101', name:'منظف أرضيات Green Seal، 3.78 لتر', category:'مواد نظافة', unit:'جالون', last_price:38, offers:3 },
    { code:'CLN-Q0102', name:'كفوف فينيل أسود شد 10',            category:'مواد نظافة', unit:'علبة',  last_price:12, offers:2 },
    { code:'ELE-Q0103', name:'مكنسة كهربائية رطب/جاف، CRS1625',  category:'أجهزة',      unit:'قطعة',  last_price:4200, offers:1 },
  ];
  STATE.history = []; STATE.suppliers = [{ id:'s1', name:'شركة النظافة المتقدمة' }];
  SI_ALIASES_BY_CODE = { 'CLN-Q0101': ['floor cleaner green seal 1 gallon'] };
  const realLog = window.logAudit;
  window.logAudit = (a, t, id, p) => { window.__audits.push({ a, t, id, p }); try { realLog(a, t, id, p); } catch (e) {} };
  navigate('entry');
});
await page.waitForSelector('#f-code', { timeout: 8000 });

/* ── ١) البحث: تسمية المورد بكتابة مختلفة تجد الصنف المسجَّل ── */
const suggestNames = async (q) => {
  await page.fill('#f-code', '');
  await page.type('#f-code', q, { delay: 8 });
  await page.waitForTimeout(120);
  return page.evaluate(() => [...document.querySelectorAll('#suggest-box .suggest-item')]
    .map((el) => el.dataset.code).join(','));
};

ok('البحث بالهمزة/التاء المختلفة يجد الصنف (تطبيع لا substring خامّ)',
  (await suggestNames('كفوف فينيل اسود')).includes('CLN-Q0102'), await suggestNames('كفوف فينيل اسود'));
ok('والبحث بالكود يجد الصنف', (await suggestNames('ELE-Q0103')).includes('ELE-Q0103'));
ok('⚠️ والبحث بالاسم الإنجليزيّ المعتمد مرادفاً يجد الصنف العربيّ',
  (await suggestNames('floor cleaner')).includes('CLN-Q0101'), await suggestNames('floor cleaner'));
ok('والبحث بما لا وجود له لا يُرجع شيئاً', (await suggestNames('زززز لا يوجد')) === '');

/* ── ٢) النقر على نتيجة يُعبّئ النموذج ويحفظ نصّ البحث (أساس التعلُّم) ── */
await page.fill('#f-code', '');
await page.type('#f-code', 'كفوف فينيل اسود', { delay: 8 });
await page.waitForTimeout(150);
/* ⚠️ لا نقر أعمى: غياب النتيجة يجب أن يُبلَّغ إخفاقاً لا أن يُسقِط السكربت
   بـTimeout قبل طباعة بقيّة الفحوص (سقوطٌ يُخفي ما نجح وما فشل معاً). */
const pickable = await page.evaluate(() =>
  !!document.querySelector('#suggest-box .suggest-item[data-code="CLN-Q0102"]'));
ok('نتيجة البحث قابلة للنقر فعلاً في الـDOM', pickable);
if (pickable) await page.click('#suggest-box .suggest-item[data-code="CLN-Q0102"]');
const picked = await page.evaluate(() => ({
  code: document.getElementById('f-code').value,
  name: document.getElementById('f-name').value,
  q: STATE.selectedItemQuery || '',
}));
ok('نقر النتيجة يُعبّئ الصنف', picked.code === 'CLN-Q0102' && /كفوف/.test(picked.name), JSON.stringify(picked));
ok('ويحفظ نصّ البحث ليُتعلَّم مرادفاً بنطاق المورد', picked.q === 'كفوف فينيل اسود', picked.q);

/* ── ٣) حارس التكرار: تسمية أخرى لصنف قائم ⇒ حوار، والموافقة تستعمل القائم ── */
const newItemFlow = async (name, accept) => {
  await page.evaluate(() => { setEntryMode('new'); window.__audits = []; });
  await page.evaluate(() => { document.getElementById('f-category-select').value = 'مواد نظافة'; });
  await page.fill('#f-code-new', 'CLN-Q9999');
  await page.fill('#f-name', name);
  await page.fill('#f-unit', 'جالون');
  await page.fill('#f-price', '41');
  await page.fill('#f-supplier', 'شركة النظافة المتقدمة');
  let dialogText = '';
  page.once('dialog', async (d) => { dialogText = d.message(); accept ? await d.accept() : await d.dismiss(); });
  await page.click('#btn-submit');
  await page.waitForTimeout(250);
  return { dialogText, ...(await page.evaluate(() => ({
    count: STATE.items.length,
    mode: STATE.entryMode,
    code: document.getElementById('f-code').value,
    audits: window.__audits.map((x) => x.a + ':' + x.t).join(','),
  }))) };
};

const accepted = await newItemFlow('منظف ارضيات جرين سيل 3.78 لتر — عبوة جالون', true);
ok('⚠️ تسمية أخرى لصنف قائم تُوقِف الإنشاء بحوارٍ يسمّي الصنف',
  /CLN-Q0101/.test(accepted.dialogText), accepted.dialogText.slice(0, 90));
ok('والحوار يشرح الطريقين (استعمال القائم / إنشاء جديد)',
  /استعمال الصنف القائم/.test(accepted.dialogText) && /إنشاء صنف جديد/.test(accepted.dialogText));
ok('والموافقة تُحوِّل لوضع الصنف القائم ولا تُنشئ مكرّراً',
  accepted.count === 3 && accepted.mode === 'existing' && accepted.code === 'CLN-Q0101',
  `${accepted.count}/${accepted.mode}/${accepted.code}`);

/* ── ٤) والإلغاء يُبقي القدرة: الصنف الجديد يُنشأ ويُسجَّل التجاوز في التدقيق ── */
const declined = await newItemFlow('منظف ارضيات جرين سيل 3.78 لتر — عبوة جالون', false);
ok('والإلغاء يُنشئ الصنف الجديد (لا منع أعمى)', declined.count === 4, String(declined.count));
ok('ويُسجَّل التجاوز في التدقيق', /duplicate_override:item/.test(declined.audits), declined.audits);

/* ── ٥) وصنف جديد فعلاً لا يُعترَض ── */
await page.evaluate(() => { STATE.items = STATE.items.filter((i) => i.code !== 'CLN-Q9999'); });
const fresh = await newItemFlow('شفرة قصّ سجاد صناعية مقاس 18 مم', true);
ok('وصنف جديد فعلاً يُنشأ بلا أي حوار', fresh.dialogText === '' && fresh.count === 4,
  `${fresh.dialogText.slice(0, 40)}|${fresh.count}`);

/* ── ٦) حالة بلاغ المالك (2026-10-15): اسمٌ إنجليزيّ يجد صنفه العربيّ ──
   كانت «LADDER 3STEPS» تُنشئ بطاقة ثانية لسلّمٍ مسجَّل بالعربية، لأنّ الاسمين
   لا يشتركان في محرف واحد فلا يجمعهما أيّ قياس تشابه نصّيّ. النقر والكتابة
   حقيقيّان هنا لأنّ المسار يمرّ بمستمع `#f-code` لا باستدعاء مباشر. */
await page.evaluate(() => {
  STATE.items = [
    { code:'B-SLM023', name:'سلم مزايا 3 درج مزدوج', category:'أدوات التنظيف', unit:'حبة', last_price:156.52, offers:1 },
    { code:'B-SLM026', name:'سلم مزايا 6 درج مزدوج', category:'أدوات التنظيف', unit:'حبة', last_price:247.83, offers:1 },
  ];
  SI_ALIASES_BY_CODE = {};
  /* ⚠️ المسار السابق تركنا في وضع «صنف جديد» فيُخفى #f-code — نعود للوضع
     القائم وإلّا انتهت المهلة على حقلٍ غير مرئيّ (لا على عيبٍ في الكود). */
  try { setEntryMode('existing'); } catch (_) { navigate('entry'); }
});
await page.waitForSelector('#f-code', { state: 'visible', timeout: 8000 });
const ladder = await suggestNames('LADDER 3STEPS');
ok('⚠️ حالة البلاغ: اسمٌ إنجليزيّ يجد السلّم العربيّ في البحث الحقيقيّ',
  ladder.split(',').includes('B-SLM023'), ladder || '(لا نتائج)');
/* ⚠️ البحث صندوقُ عرضٍ للبشر فيُرجع السلّمين معاً — وهو الصواب. الضمانة التي
   تمنع البطاقة المكرّرة في **المُحلِّل** الذي يستدعيه الاستيراد، فهو ما يُقاس. */
const pick = await page.evaluate(() => {
  const a = siResolveItem('LADDER 3STEPS', {});
  const b = siResolveItem('LADDER 6STEPS', {});
  return { a3: a.item && a.item.code, s3: a.state, b6: b.item && b.item.code };
});
ok('⚠️ والمُحلِّل يُسنِد كلّ سلّم لصاحبه (6 درج ≠ 3 درج)',
  pick.a3 === 'B-SLM023' && pick.b6 === 'B-SLM026', `${pick.a3}|${pick.b6}`);
ok('وبحالة «اقتراح» فالقرار البشريّ محفوظ لا دمج تلقائيّ', pick.s3 === 'suggest', pick.s3);
const cat = await page.evaluate(() => siInferCategory('LADDER 8STEPS').category);
ok('⚠️ والتصنيف يُستنتَج من أقرب الأصناف لا يُكتب «مستورد»',
  cat === 'أدوات التنظيف', cat || '(فارغ)');
const far = await page.evaluate(() => siInferCategory('زززز قققق ططط ككك').category);
ok('وما لا يقارب شيئاً يُترَك فارغاً', far === '', far || '(فارغ)');

ok('صفر خطأ صفحة', errors.length === 0, errors[0]);
ok('صفر انتهاك CSP', csp.length === 0, csp[0]);

await browser.close();
let bad = 0;
for (const c of checks) { if (!c.p) bad++; console.log(`${c.p ? '✓' : '✗ FAIL'}  ${c.n}${c.d ? '  → ' + c.d : ''}`); }
if (bad) { console.error(`\n❌ ${bad} فحص فشل`); process.exit(1); }
console.log(`\n✅ ${checks.length}/${checks.length} فحصاً نجحت`);

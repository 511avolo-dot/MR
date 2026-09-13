/* ══════════════════════════════════════════════════════════════════════
   لقطات شاشة حقيقية لما يراه موظّف الصيانة المُنطَّق — تحت CSP الإنتاج
   ----------------------------------------------------------------------
   لماذا متصفّح حقيقيّ وليس وصفاً: إخفاء الشاشات والمبالغ يقع في ثلاث
   طبقات (CSS ذات `!important` · `navigate` · RLS على القاعدة)، وسبق أن
   مرّت عيوب من الفحص النصّيّ وأمسكها المتصفّح وحده.

   يُشغَّل بعد رفع خادم المعاينة:
     node scripts/csp-preview-server.mjs &      # منفذ 8812، ترويسات _headers حرفيّاً
     node scripts/e2e/scoped-staff-screens.mjs

   ⚠️ لا اتصال بالإنتاج إطلاقاً: عميل السحابة مُقلَّد بالكامل، والصفوف
   مصنوعة محليّاً (القاعدة في الواقع هي من يُصفّيها — هنا نُحاكي نتيجتها).
   ══════════════════════════════════════════════════════════════════════ */
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';
import { resolveChromiumExecutable } from './chromium-path.mjs';

const OUT = process.env.SHOT_DIR || '/tmp/scoped-staff';
const URL_ = 'http://127.0.0.1:8812/index.html';
mkdirSync(OUT, { recursive: true });

const checks = [];
const notes = [];
const ok = (name, pass, detail) => { checks.push({ name, pass, detail }); };
/* ملاحظة مرصودة: واقعٌ يُسجَّل ويُبلَّغ، لا فحص يُفشِل التشغيل. تُستعمَل لعيبٍ
   قائم قبل هذا السكربت — حجبُ اللقطات بسببه يمنع المالك من رؤية ما طلبه. */
const note = (name, detail) => { notes.push({ name, detail }); };

/* ── حالة مصنوعة: أوامر قطاع «الصيانة والتشغيل» + طلبان ── */
const SEED = `(() => {
  const now = Date.now();
  const d = n => new Date(now - n*86400000).toISOString().slice(0,10);
  window.__SEED_POS = [
    { po_number:'P.O-DG26-3209', issue_date:d(21), sector:'الصيانة والتشغيل', project:'برج الشمال',
      supplier:'مؤسسة ركن القهوة', officer:'أحمد', payment_method:'آجل', priority:'عالي',
      expected_delivery:d(4), status:'تسليم جزئي', category:'مستهلكات', notes:'',
      items:[{desc:'فلتر هواء مركزي',unit:'حبة',qty:20,price:180,received_qty:12},
             {desc:'زيت تشحيم 20 لتر',unit:'عبوة',qty:6,price:420,received_qty:6}],
      receipts:[{by:'صالح الميداني',at:d(3),note:'وصل جزء من الفلاتر'}],
      comments:[{by:'أحمد — المشتريات',at:d(2),text:'المورد وعد ببقية الكمية خلال أسبوع.'}],
      status_history:[] },
    { po_number:'P.O-DG26-3207', issue_date:d(34), sector:'الصيانة والتشغيل', project:'فرع الرياض 3',
      supplier:'شركة العوبثاني', officer:'أحمد', payment_method:'كاش', priority:'عادي',
      expected_delivery:d(9), status:'لدى الإدارة المالية', category:'قطع غيار', notes:'',
      items:[{desc:'مضخة مياه 2 بوصة',unit:'حبة',qty:2,price:3400,received_qty:0}],
      receipts:[], comments:[], status_history:[] },
    { po_number:'P.O-DG26-3204', issue_date:d(48), sector:'الصيانة والتشغيل', project:'برج الشمال',
      supplier:'مؤسسة منزل الياقوت', officer:'مصطفى', payment_method:'آجل', priority:'عاجل',
      expected_delivery:d(12), status:'اعتماد مدير الشراء', category:'كهرباء', notes:'',
      items:[{desc:'كابل نحاس 4×16',unit:'متر',qty:300,price:38,received_qty:0}],
      receipts:[], comments:[], status_history:[] },
    { po_number:'P.O-DG26-3198', issue_date:d(70), sector:'الصيانة والتشغيل', project:'مستودع الدمام',
      supplier:'شركة الراشد للإطارات', officer:'أحمد', payment_method:'كاش', priority:'عادي',
      expected_delivery:d(40), actual_delivery:d(38), status:'مغلق', category:'إطارات', notes:'',
      items:[{desc:'إطار شاحنة 1200R20',unit:'حبة',qty:8,price:1450,received_qty:8}],
      receipts:[{by:'صالح الميداني',at:d(38),note:'استلام كامل'}], comments:[], status_history:[] }
  ];
  window.__SEED_PRS = [
    { id:'PR-DG2026-0002', title:'مستلزمات صيانة برج الشمال', sector:'الصيانة والتشغيل',
      project:'برج الشمال', requester:'saleh', requester_name:'صالح الميداني',
      status:'submitted', proc_status:'in_progress', priority:'عالي',
      created_at:new Date(now-9*86400000).toISOString(), updated_at:new Date(now-6*86400000).toISOString(),
      proc_started_by:'أحمد — المشتريات', proc_started_at:new Date(now-3*86400000).toISOString(),
      est_total:4600, currency:'SAR', doc_key:'docs/pr/PR-DG2026-0002/signed.pdf',
      doc_name:'طلب-موقّع-من-المدير.pdf',
      items:[{seq:1,description:'فلتر هواء مركزي',unit:'حبة',requested_qty:20,unit_price:180,line_total:3600},
             {seq:2,description:'زيت تشحيم',unit:'عبوة',requested_qty:2,unit_price:500,line_total:1000}],
      messages:[{id:1,kind:'question',body:'هل الكمية 20 فلتر أم 20 كرتون؟',author:'proc1',
                 author_name:'أحمد — المشتريات',created_at:new Date(now-2*86400000).toISOString()}] },
    { id:'PR-DG2026-0003', title:'قطع غيار مضخات', sector:'الصيانة والتشغيل', project:'فرع الرياض 3',
      requester:'saleh', requester_name:'صالح الميداني', status:'draft', priority:'عادي',
      created_at:new Date(now-1*86400000).toISOString(), updated_at:new Date(now-1*86400000).toISOString(),
      est_total:0, currency:'SAR', items:[{seq:1,description:'سيل مضخة',unit:'حبة',requested_qty:4}],
      messages:[] },
    { id:'PR-DG2026-0001', title:'أدوات سلامة', sector:'الصيانة والتشغيل', project:'مستودع الدمام',
      requester:'saleh', requester_name:'صالح الميداني', status:'approved', proc_status:'po_issued',
      po_number:'P.O-DG26-3209', priority:'عادي',
      created_at:new Date(now-30*86400000).toISOString(), updated_at:new Date(now-12*86400000).toISOString(),
      proc_started_by:'أحمد — المشتريات', proc_started_at:new Date(now-25*86400000).toISOString(),
      est_total:2100, currency:'SAR', items:[{seq:1,description:'خوذة سلامة',unit:'حبة',requested_qty:15}],
      messages:[] }
  ];
  window.__SEED_TPL = [
    { id:'TPL-A', name:'مستلزمات برج الشمال الشهرية', owner:'saleh', sector:'الصيانة والتشغيل',
      project:'برج الشمال', title:'مستلزمات صيانة شهرية', priority:'عادي',
      items:[{description:'فلتر هواء مركزي',unit:'حبة',requested_qty:20},
             {description:'زيت تشحيم',unit:'عبوة',requested_qty:2}],
      use_count:4, last_used_at:d(30) },
    { id:'TPL-B', name:'مستهلكات فرع الرياض 3', owner:'saleh', sector:'الصيانة والتشغيل',
      project:'فرع الرياض 3', title:'مستهلكات شهرية', priority:'عادي',
      items:[{description:'لمبات LED 18w',unit:'حبة',requested_qty:40}],
      use_count:2, last_used_at:d(12) }
  ];
})()`;

/* ── تسجيل دخول مُقلَّد بهوية محدّدة ──
   ⚠️ يُستدعى عبر `login(page,cfg)` لا `page.evaluate(LOGIN,cfg)`: Playwright يعامل
   الوسيط النصّيّ **تعبيراً** ويتجاهل الوسائط، فتمريره دالةً نصّية لا ينفّذ شيئاً
   (مرّ فعلاً في أوّل تشغيل: كل الفحوص سقطت لأنّ الهوية لم تُضبَط أصلاً). */
const LOGIN = `(cfg) => {
  const stubClient = {
    rpc: async () => ({ data:null, error:null }),
    from: () => ({
      select: () => ({ order: () => ({ range: async () => ({data:[],error:null}) }),
                       eq: () => ({ order: async () => ({data:[],error:null}) }),
                       in: async () => ({data:[],error:null}) }),
      insert: async () => ({ error:null }),
      update: () => ({ eq: async () => ({ error:null }) }),
      delete: () => ({ eq: async () => ({ error:null }) })
    }),
    auth: { getSession: async () => ({ data:{ session:null } }) },
    channel: () => ({ on(){ return this; }, subscribe(){ return this; } })
  };
  STATE.currentUser = cfg.user;
  try { sessionStorage.setItem('proc_session', JSON.stringify(cfg.user)); } catch(e) {}
  hideLoginScreen();
  startApp();
  // السحابة مُقلَّدة: prCloudReady تصير true بلا أي طلب شبكة
  CLOUD.enabled = true; CLOUD.dataLoaded = true; CLOUD.client = stubClient;
  window.__prLoaded = true;
  try { __prLoaded = true; } catch(e) {}
  STATE.purchaseOrders = JSON.parse(JSON.stringify(window.__SEED_POS))
    .map(p => { try { recomputePOderived(p); } catch(e) {} return p; });
  STATE.purchaseRequests = JSON.parse(JSON.stringify(window.__SEED_PRS));
  STATE.prTemplates = JSON.parse(JSON.stringify(window.__SEED_TPL));
  STATE.prRules = []; STATE.departments = [];
  /* ⚠️ بلا هذا يبقى قناع الترطيب (body.data-loading) مُطبَّقاً فتُعرَض كل
     الأرقام خلف هيكل نابض ويعلو الشريط «جارٍ تحميل أحدث البيانات…» — لقطةٌ
     تبدو سليمة تقنيّاً وهي في الحقيقة شاشة نصف مرسومة.
     (لا شرطات مائلة خلفية هنا: النصّ داخل قالب نصّيّ يُنهيه أي backtick.) */
  try { hydSettle('ready'); } catch(e) {}
  applyUserRoleToUI(); applyScopedNav();
  navigate(cfg.page || (isScopedUser() ? SCOPED_HOME : 'dashboard'));
}`;

const SCOPED_USER = {
  username: 'saleh', displayName: 'صالح الميداني', role: 'user',
  scopeSectors: ['الصيانة والتشغيل'],
  permissions: { can_receive_po: true, can_view_amounts: false }
};
const OFFICE_USER = {
  username: 'mostafa', displayName: 'مصطفى — المكتب', role: 'user',
  scopeSectors: [],
  permissions: { can_create_po: true, can_edit_po: true, can_manage_rfq: true }
};

/* ⚠️ يقيس **مبلغاً فعليّاً** لا وحدة عملة: عناوين الأعمدة تحمل «القيمة (ر.س)»
   وتحتها «—»، فالبحث عن `ر.س` وحدها إنذارٌ كاذب. المطلوب: رقم بفواصل آلاف،
   أو رقم يسبق ر.س مباشرةً. (أوّل صياغة سقطت على العنوان — صُحِّحت بالقياس.) */
const MONEY_RX = /\b\d{1,3}(?:,\d{3})+(?:\.\d+)?\b|\d[\d.,]*\s*ر\.س/;

const login = (page, cfg) => page.evaluate(`(${LOGIN})(${JSON.stringify(cfg)})`);

/* ⚠️ حارس اللقطة: طبقةٌ نُسِي إغلاقها تغطّي نصف الصورة، وقناع الترطيب يُعمّي
   كل رقم — واللقطة تبدو ناجحة في السجلّ. `expect` تُسمّي ما يُفترض أن يكون
   مفتوحاً؛ أي طبقة أخرى (أو قناع باقٍ) تُسجَّل ملاحظةً باسم اللقطة. */
async function shoot(page, name, expect = []) {
  const allow = Array.isArray(expect) ? expect : [expect];
  await page.waitForTimeout(350);
  const stray = await page.evaluate((exp) => {
    const open = [];
    if (document.body.classList.contains('data-loading')) open.push('قناع الترطيب');
    if (document.getElementById('po-drawer')?.classList.contains('active')) open.push('po-drawer');
    if (document.body.classList.contains('print-preview-active')) open.push('print-preview');
    document.querySelectorAll('.modal-overlay.active').forEach(m => open.push(m.id || 'modal'));
    return open.filter(o => !exp.includes(o));
  }, allow);
  if (stray.length) note(`طبقة غير متوقّعة في اللقطة ${name}`, stray.join(' · '));
  await page.screenshot({ path: `${OUT}/${name}.png`, fullPage: true });
  return `${OUT}/${name}.png`;
}

const browser = await chromium.launch({ executablePath: resolveChromiumExecutable() });
const errs = [], csp = [];

async function session(viewport, tag) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  page.on('pageerror', e => errs.push(`[${tag}] ${e}`));
  page.on('console', m => {
    const t = m.text();
    if (/Content Security Policy|Refused to/i.test(t)) csp.push(`[${tag}] ${t}`);
  });
  await page.goto(URL_, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(1200);
  await page.evaluate(SEED);
  return { ctx, page };
}

/* ══ ١) الموظّف المُنطَّق — سطح المكتب ══ */
{
  const { ctx, page } = await session({ width: 1440, height: 900 }, 'desktop');
  await login(page, { user: SCOPED_USER });
  await page.waitForTimeout(600);

  const nav = await page.evaluate(() => ({
    side: [...document.querySelectorAll('.nav-item[data-page]')]
      .filter(n => getComputedStyle(n).display !== 'none').map(n => n.dataset.page),
    followup: !!document.getElementById('po-followup-btn') &&
      getComputedStyle(document.getElementById('po-followup-btn')).display !== 'none',
    page: STATE.page
  }));
  ok('الوجهات المرئية = الأوامر + الطلبات',
    nav.side.length === 2 && nav.side.includes('purchase-orders') && nav.side.includes('pr'),
    nav.side.join(' · '));
  ok('المهبط بعد الدخول = أوامر الشراء', nav.page === 'purchase-orders', nav.page);
  ok('زرّ تقرير المتابعة ظاهر له', nav.followup === true, String(nav.followup));

  await shoot(page, '01-desktop-orders');

  let txt = await page.evaluate(() => document.getElementById('page-purchase-orders').innerText);
  ok('شاشة الأوامر بلا مبالغ', !MONEY_RX.test(txt), (txt.match(MONEY_RX) || ['—'])[0]);

  /* البوّابة الوحيدة: أي مبلغ يمرّ بـfmtPrice/tafqitSAR. نُثبِت أنّها تُرجع «—»
     فعلاً — لا نكتفي بغياب الرقم من النصّ (قد يغيب لأنّ الشاشة لم تُرسَم). */
  const gate = await page.evaluate(() => ({
    price: fmtPrice(3600), words: tafqitSAR(3600), can: canViewAmounts(),
    kpis: [...document.querySelectorAll('#po-kpi-strip .po-kpi-value')].map(e => e.textContent.trim())
  }));
  ok('بوّابة المبالغ تُرجع «—»', gate.price === '—' && gate.can === false, `${gate.price} · ${gate.can}`);
  ok('لا تفقيط بالحروف', gate.words === '—' || gate.words === '', `«${gate.words}»`);

  // درج الأمر
  await page.evaluate(() => openPODrawer('P.O-DG26-3209'));
  await shoot(page, '02-desktop-drawer', 'po-drawer');
  const drawer = await page.evaluate(() => {
    const el = document.getElementById('po-drawer');
    return { text: el ? el.innerText : '', recv: !!el?.querySelector('[onclick*="poReceiveOpen"]'),
             comment: !!el?.querySelector('[onclick*="poAddComment"]'),
             edit: !!el?.querySelector('[onclick*="openPOModal"]') };
  });
  ok('درج الأمر بلا مبالغ', !MONEY_RX.test(drawer.text), (drawer.text.match(MONEY_RX) || ['—'])[0]);
  ok('زرّ الاستلام في الدرج', drawer.recv === true, String(drawer.recv));
  ok('خانة ملاحظة المتابعة في الدرج', drawer.comment === true, String(drawer.comment));
  /* كان عيباً: `hasPermission` تسقط لافتراضيّ الدور حين يغيب المفتاح، ورابط
     الدعوة يكتب مفتاحين فقط — فمفاتيح الكتابة تصير true فتظهر أزرارها
     والخادم يرفضها (po_update/po_insert = NOT proc_is_scoped()).
     أُصلح: للمُنطَّق **المنح صريح أو لا شيء**. */
  const writeBtns = await page.evaluate(() => {
    const vis = el => el && getComputedStyle(el).display !== 'none' && !el.classList.contains('perm-hidden');
    const ids = ['po-add-btn', 'po-import-btn', 'po-projects-btn', 'po-export-btn']
      .filter(i => vis(document.getElementById(i)));
    const dr = [...document.querySelectorAll('#po-drawer button')].filter(vis)
      .map(b => b.textContent.trim()).filter(t => /تعديل|إلغاء|تغيير|تسليم كامل/.test(t));
    return { ids, dr,
      perms: ['can_edit_po','can_create_po','can_import','can_export','can_use_ai']
               .map(k => hasPermission(k)),
      keeps: hasPermission('can_receive_po') };
  });
  ok('لا زرّ كتابة يطرق باباً مغلقاً', writeBtns.ids.length === 0 && writeBtns.dr.length === 0,
    `${writeBtns.ids.join(' · ') || 'لا شيء'} | الدرج: ${writeBtns.dr.join(' · ') || 'لا شيء'}`);
  ok('مفاتيح الكتابة الغائبة = false، والممنوح صراحةً باقٍ',
    writeBtns.perms.every(v => v === false) && writeBtns.keeps === true,
    `perms=${writeBtns.perms.join(',')} receive=${writeBtns.keeps}`);

  const floats = await page.evaluate(() =>
    ['ai-fab', 'wf-bell'].map(id => {
      const el = document.getElementById(id);
      return el ? getComputedStyle(el).display : 'مفقود';
    }));
  ok('الزرّان العائمان مخفيّان عنه', floats.every(d => d === 'none' || d === 'مفقود'), floats.join(' · '));

  /* عناوين المجموعات الفارغة — ولا يُخفى عنوانٌ تحته وجهة مرئيّة. */
  const labels = await page.evaluate(() => {
    const nav = document.querySelector('.nav');
    return {
      shown: [...nav.querySelectorAll('.nav-label')]
        .filter(l => getComputedStyle(l).display !== 'none').map(l => l.textContent.trim()),
      items: [...nav.querySelectorAll('.nav-item[data-page]')]
        .filter(a => getComputedStyle(a).display !== 'none').map(a => a.dataset.page) };
  });
  ok('لا عنوان مجموعة فارغ في الشريط الجانبي',
    labels.shown.length === 1 && labels.shown[0] === 'المشتريات',
    labels.shown.join(' · ') || 'لا شيء');
  ok('والوجهتان تحته لم تُخفَيا معه', labels.items.length === 2, labels.items.join(' · '));

  /* ⚠️ أداء: `hasPermission` صارت تستدعي `isScopedUser()` التي تُطبّع مصفوفة
     القطاعات، و`fmtPrice` تمرّ بها في **كل** خلية نقدية. نقيس ولا نفترض. */
  const perf = await page.evaluate(() => {
    const t0 = performance.now();
    for (let i = 0; i < 20000; i++) fmtPrice(1234.5);
    return Math.round(performance.now() - t0);
  });
  ok('لا كلفة أداء محسوسة من فحص النطاق داخل fmtPrice', perf < 400, `${perf}ms / 20k نداء`);

  /* بطاقةٌ قيمتها «—» دائماً، ومؤشّر إداريّ، وشريط فجوات كاذب على قائمة
     مُصفّاة بطبيعتها — ثلاثتها ضجيج يُبعد أوّل أمر شراء عن أعلى الشاشة. */
  const strip = await page.evaluate(() => ({
    labels: [...document.querySelectorAll('#po-kpi-strip .po-kpi-label')].map(e => e.textContent.trim()),
    seq: (document.getElementById('po-seq-bar') || {}).innerHTML || ''
  }));
  ok('بطاقتا «قيمة المشتريات» و«مؤشر صحة النظام» محذوفتان عنه',
    !strip.labels.includes('قيمة المشتريات') && !strip.labels.includes('مؤشر صحة النظام'),
    `${strip.labels.length} بطاقة: ${strip.labels.join(' · ')}`);
  ok('ولا إنذار فجوات كاذب على قائمة مُصفّاة بالقطاع',
    strip.seq.trim() === '', strip.seq ? 'الشريط ظاهر' : 'فارغ');

  // نافذة الاستلام
  await page.evaluate(() => poReceiveOpen('P.O-DG26-3209'));
  await shoot(page, '03-desktop-receive', ['modal-po-receive', 'po-drawer']);
  const rcv = await page.evaluate(() => {
    const m = document.getElementById('modal-po-receive');
    return { open: !!m, text: m ? m.innerText : '', rows: m ? m.querySelectorAll('[data-rcv]').length : 0 };
  });
  ok('نافذة الاستلام تفتح ببنودها', rcv.open && rcv.rows === 2, `rows=${rcv.rows}`);
  ok('نافذة الاستلام بلا مبالغ', !MONEY_RX.test(rcv.text), (rcv.text.match(MONEY_RX) || ['—'])[0]);
  await page.evaluate(() => { poReceiveClose(); closePODrawer(); });
  await page.waitForTimeout(400);

  // تقرير المتابعة الميدانيّ
  await page.evaluate(() => document.getElementById('po-followup-btn').click());
  await page.waitForTimeout(900);
  await shoot(page, '04-desktop-followup-report', 'print-preview');
  const rep = await page.evaluate(() => {
    const el = document.getElementById('pp-content');
    return { open: !!el && el.innerText.length > 100, text: el ? el.innerText : '' };
  });
  ok('تقرير المتابعة الميدانيّ يُطبع', rep.open === true, String(rep.open));
  ok('تقرير المتابعة بلا مبالغ', !MONEY_RX.test(rep.text), (rep.text.match(MONEY_RX) || ['—'])[0]);
  await page.evaluate(() => { try { closePrintPreview(); } catch (e) {} });

  // شاشة الطلبات — ⚠️ أغلق الدرج أوّلاً وإلّا غطّى نصف كل لقطة تالية
  await page.evaluate(() => { closePODrawer(); navigate('pr'); prGoView('create'); });
  await page.waitForTimeout(500);
  await shoot(page, '05-desktop-pr-new');
  const prNew = await page.evaluate(() => ({
    tabs: [...document.querySelectorAll('.pr-tab')].map(b => b.textContent.trim()),
    priceCol: !!document.querySelector('#pr-items-body [data-f=unit_price]'),
    docField: !!document.getElementById('pr-doc-input') ||
      /سند|موقّع|موقع/.test(document.getElementById('pr-root').innerText),
    text: document.getElementById('pr-root').innerText
  }));
  ok('تبويبات الطلبات ثلاثة (لا «الوارد للمشتريات»)',
    prNew.tabs.length === 3 && !prNew.tabs.some(t => t.includes('الوارد')), prNew.tabs.join(' | '));
  ok('نموذج الطلب بلا عمود سعر', prNew.priceCol === false, String(prNew.priceCol));
  ok('نموذج الطلب يطلب السند الموقَّع', prNew.docField === true, String(prNew.docField));
  ok('نموذج الطلب بلا مبالغ', !MONEY_RX.test(prNew.text), (prNew.text.match(MONEY_RX) || ['—'])[0]);

  await page.evaluate(() => prGoView('templates'));
  await shoot(page, '06-desktop-pr-templates');

  await page.evaluate(() => prGoView('list'));
  await shoot(page, '07-desktop-pr-list');

  await page.evaluate(() => prGoView('track', 'PR-DG2026-0002'));
  await shoot(page, '08-desktop-pr-track');
  const track = await page.evaluate(() => document.getElementById('pr-root').innerText);
  ok('شاشة المتابعة تُظهر المسار', /أين وصل طلبك|المرحلة|قيد التنفيذ/.test(track), 'ok');
  ok('شاشة المتابعة بلا مبالغ', !MONEY_RX.test(track), (track.match(MONEY_RX) || ['—'])[0]);

  await page.evaluate(() => prGoView('track', 'PR-DG2026-0001'));
  await page.waitForTimeout(300);
  const poLink = await page.evaluate(() => document.getElementById('pr-root').innerText);
  ok('الطلب المُنفَّذ يقول «صدر أمر الشراء»',
    poLink.includes('P.O-DG26-3209'), poLink.includes('P.O-DG26-3209') ? 'ok' : 'مفقود');
  await shoot(page, '09-desktop-pr-track-po');

  await ctx.close();
}

/* ══ ٢) الموظّف المُنطَّق — الجوال 393×852 ══ */
{
  const { ctx, page } = await session({ width: 393, height: 852 }, 'mobile');
  await login(page, { user: SCOPED_USER });
  await page.waitForTimeout(700);
  await shoot(page, '10-mobile-orders');
  /* لقطة بحجم الشاشة (لا الصفحة كاملة): هي ما يراه فعلاً أوّل ما يفتح هاتفه. */
  await page.screenshot({ path: `${OUT}/10b-mobile-first-screen.png` });

  const mnav = await page.evaluate(() => [...document.querySelectorAll('.mnav-item[data-mpage]')]
    .filter(n => getComputedStyle(n).display !== 'none').map(n => n.dataset.mpage));
  ok('الشريط السفليّ = وجهتان فقط',
    mnav.length === 2 && mnav.includes('purchase-orders') && mnav.includes('pr'), mnav.join(' · '));

  const slide = await page.evaluate(() => {
    const de = document.documentElement, prev = de.style.overflowX;
    de.style.overflowX = 'visible';
    const v = de.scrollWidth - de.clientWidth;
    de.style.overflowX = prev; return v;
  });
  ok('صفر انزلاق أفقيّ على 393px (الأوامر)', slide === 0, `${slide}px`);

  await page.evaluate(() => openPODrawer('P.O-DG26-3209'));
  await shoot(page, '11-mobile-drawer', 'po-drawer');
  await page.evaluate(() => closePODrawer());

  await page.evaluate(() => { navigate('pr'); prGoView('create'); });
  await page.waitForTimeout(500);
  await shoot(page, '12-mobile-pr-new');
  const slide2 = await page.evaluate(() => {
    const de = document.documentElement, prev = de.style.overflowX;
    de.style.overflowX = 'visible';
    const v = de.scrollWidth - de.clientWidth;
    de.style.overflowX = prev; return v;
  });
  ok('صفر انزلاق أفقيّ على 393px (الطلبات)', slide2 === 0, `${slide2}px`);

  await page.evaluate(() => prGoView('list'));
  await shoot(page, '13-mobile-pr-list');

  await page.evaluate(() => { navDrawer(true); });
  await shoot(page, '14-mobile-drawer-menu');
  /* ⚠️ فرضية خطر مقيسة: `hideEmptyNavLabels` تعتمد `getComputedStyle` — فلو
     كان الشريط الجانبي على الجوال مخفيّاً بـ`display:none` (لا بـtransform)
     لحُسبت كل الوجهات مخفيّةً فتُخفى **كل** العناوين، وتُفتَح القائمة بلا
     عنوان واحد. نُشغّل الممرّ والدرج مفتوح ونتحقّق. */
  const mLabels = await page.evaluate(() => {
    applyScopedNav();
    const nav = document.querySelector('.nav');
    return {
      shown: [...nav.querySelectorAll('.nav-label')]
        .filter(l => getComputedStyle(l).display !== 'none').map(l => l.textContent.trim()),
      items: [...nav.querySelectorAll('.nav-item[data-page]')]
        .filter(a => getComputedStyle(a).display !== 'none').map(a => a.dataset.page) };
  });
  ok('على الجوال: عنوان المشتريات باقٍ ووجهتاه تحته',
    mLabels.shown.length === 1 && mLabels.shown[0] === 'المشتريات' && mLabels.items.length === 2,
    `${mLabels.shown.join(' · ') || 'لا شيء'} | ${mLabels.items.join(' · ')}`);
  await page.evaluate(() => { navDrawer(false); });

  await ctx.close();
}

/* ══ ٣) موظّف المكتب — إثبات صفر انحدار ══ */
{
  const { ctx, page } = await session({ width: 1440, height: 900 }, 'office');
  await login(page, { user: OFFICE_USER, page: 'purchase-orders' });
  await page.waitForTimeout(700);
  await shoot(page, '15-office-orders');

  const off = await page.evaluate(() => ({
    side: [...document.querySelectorAll('.nav-item[data-page]')]
      .filter(n => getComputedStyle(n).display !== 'none').map(n => n.dataset.page),
    money: fmtPrice(3600),
    scoped: isScopedUser(),
    followup: getComputedStyle(document.getElementById('po-followup-btn')).display
  }));
  ok('موظّف المكتب: أكثر من وجهتين', off.side.length > 2, `${off.side.length} وجهة`);
  ok('موظّف المكتب: المبالغ ظاهرة', off.money !== '—', off.money);
  ok('موظّف المكتب غير مُنطَّق', off.scoped === false, String(off.scoped));
  ok('زرّ المتابعة الميدانيّ مخفيّ عنه', off.followup === 'none', off.followup);

  /* ⚠️ أهمّ فحص في الملف: الصرامة **للمُنطَّق وحده**. موظّف المكتب هنا يحمل
     مفتاحين فقط في صفّه — كحال الأربعة القائمين — فلو تسرّبت إليه الصرامة
     فقد أدواته كلّها لحظة النشر. */
  const offKeep = await page.evaluate(() => {
    const vis = el => el && getComputedStyle(el).display !== 'none' && !el.classList.contains('perm-hidden');
    return {
      perms: ['can_edit_po','can_create_po','can_import','can_export','can_use_ai',
              'can_manage_suppliers','can_view_amounts'].map(k => hasPermission(k)),
      btns: ['po-add-btn','po-import-btn','po-export-btn','po-projects-btn']
              .filter(i => vis(document.getElementById(i))).length,
      labels: [...document.querySelectorAll('.nav .nav-label')]
                .filter(l => getComputedStyle(l).display !== 'none').length,
      fab: getComputedStyle(document.getElementById('ai-fab')).display };
  });
  ok('موظّف المكتب: كل مفاتيحه الافتراضية باقية (صفر انحدار)',
    offKeep.perms.every(v => v === true), offKeep.perms.join(','));
  ok('وأزرار شاشة الأوامر الأربعة ظاهرة له', offKeep.btns === 4, `${offKeep.btns}/4`);
  ok('وعناوين مجموعاته لم تُخفَ', offKeep.labels >= 4, String(offKeep.labels));
  ok('وزرّ المساعد الذكيّ باقٍ له', offKeep.fab !== 'none', offKeep.fab);
  /* ⚠️ المقارنة بالمِثل: شريط التسلسل لا يُرسَم إلّا في عرض «القائمة»
     (`renderPurchaseOrders`)، وموظّف المكتب يهبط على «لوحة التحكم» — فقياسه
     هناك يُظهره فارغاً ويبدو انحداراً وهو سلوك قائم. */
  const offStrip = await page.evaluate(() => {
    STATE.poView = 'list'; renderPurchaseOrders();
    return {
      labels: [...document.querySelectorAll('#po-kpi-strip .po-kpi-label')].map(e => e.textContent.trim()),
      seq: (document.getElementById('po-seq-bar') || {}).innerHTML || '' };
  });
  ok('وبطاقاته السبع وشريط التسلسل كما كانا (صفر انحدار)',
    offStrip.labels.length === 7 && offStrip.labels.includes('قيمة المشتريات')
    && offStrip.labels.includes('مؤشر صحة النظام') && offStrip.seq.trim() !== '',
    `${offStrip.labels.length} بطاقة · شريط=${offStrip.seq.trim() ? 'ظاهر' : 'فارغ'}`);

  await page.evaluate(() => { navigate('reports'); });
  await page.waitForTimeout(500);
  await shoot(page, '16-office-reports');

  await ctx.close();
}

await browser.close();

/* ══ الخلاصة ══ */
ok('صفر خطأ صفحة', errs.length === 0, errs.join(' | ') || 'لا شيء');
ok('صفر انتهاك CSP', csp.length === 0, csp.join(' | ') || 'لا شيء');

let failed = 0;
for (const c of checks) {
  if (!c.pass) failed++;
  console.log(`${c.pass ? '✅' : '❌'} ${c.name}${c.detail ? ' — ' + c.detail : ''}`);
}
if (notes.length) {
  console.log('\n── ملاحظات مرصودة (لا تُفشِل التشغيل) ──');
  for (const n of notes) console.log(`⚠️  ${n.name}\n    ${n.detail}`);
}
console.log(`\nاللقطات في: ${OUT}`);
console.log(`النتيجة: ${checks.length - failed}/${checks.length}`);
if (failed) { console.error('⛔️ فحص ساقط — لا تُسلَّم اللقطات'); process.exit(1); }

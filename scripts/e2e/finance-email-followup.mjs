/**
 * finance-email-followup.mjs — «متابعة المالية عبر الإيميل» في متصفّح حقيقيّ
 * تحت **ترويسات الإنتاج** (scripts/csp-preview-server.mjs يخدم `_headers` حرفيّاً).
 *
 * لماذا متصفّح لا تأكيدات نصّية: الميزة كلّها **لصقٌ في بريد** — والحافظة
 * وواجهة `ClipboardItem` والتنزيل ونافذة تُلحَق وقت التشغيل، لا يُقاس أيٌّ
 * منها بقراءة الشيفرة. والقياس هنا على المُخرَج الفعليّ: ما الذي دخل الحافظة.
 *
 * ⚠️ كل فحص يبدأ بـ`blockSupabase` — لا فحص يلمس قاعدة الإنتاج (app-boot.mjs).
 */
/* ⚠️ استيراد **نسبيّ**: مسار المستودع على العدّاء `/home/runner/work/MR/MR`
   لا مسار بيئة التطوير — ومسارٌ مطلق ينجح هنا ويسقط هناك بـERR_MODULE_NOT_FOUND. */
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const URL_ = 'http://127.0.0.1:8812/index.html';
let pass = 0, fail = 0;
const T = (name, cond, detail) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (detail ? '  → ' + detail : '')); }
};

const D = (n) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);
const ORDERS = [
  { po_number: 'P.O-DG26-3301', supplier: 'شركة الوفاء التجارية', project: 'برج الشمال',
    sector: 'الإنشاءات', payment_method: 'تحويل بنكي', status: 'تسليم للإدارة المالية',
    issue_date: D(60), expected_delivery: D(-5), subtotal: 10000,
    status_history: [{ at: D(20) + 'T09:00:00Z', to: 'تسليم للإدارة المالية' }] },
  { po_number: 'P.O-DG26-3302', supplier: 'مؤسسة النخبة', project: 'فرع الرياض 3',
    sector: 'الصيانة والتشغيل', payment_method: 'شيك', status: 'تسليم للإدارة المالية',
    issue_date: D(10), expected_delivery: D(-20), subtotal: 2000,
    status_history: [{ at: D(3) + 'T09:00:00Z', to: 'تسليم للإدارة المالية' }] },
  { po_number: 'P.O-DG26-3303', supplier: 'الأفق للمقاولات', project: 'برج الشمال',
    sector: 'الإنشاءات', payment_method: 'تحويل بنكي', status: 'تم التحويل',
    issue_date: D(30), expected_delivery: D(-2), subtotal: 5000,
    status_history: [{ at: D(4) + 'T09:00:00Z', to: 'تم التحويل' }] },
  { po_number: 'P.O-DG26-3304', supplier: 'مورد خارج المالية', project: 'برج الشمال',
    sector: 'النقليات', payment_method: 'نقدي', status: 'قيد المراجعة',
    issue_date: D(2), expected_delivery: D(-30), subtotal: 9999, status_history: [] },
];

const PROC = { can_view_amounts: true, can_export: true, can_use_ai: false };
/* موظّف مكتب **بلا** رؤية مالية: يصل مركز التقارير فعلاً — فالبطاقة تُختبَر
   بالتصفية لا بتعذّر الوصول. (والمُنطَّق لا يبلغ الشاشة أصلاً — يُختبَر بعده.) */
const NOMONEY = { can_export: true, can_view_amounts: false };
const FIELD = { can_create_pr: true, can_receive_po: true, can_print_followup: true, can_view_amounts: false };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: 'http://127.0.0.1:8812' });
await blockSupabase(ctx);
const page = await ctx.newPage();
const errs = [], csp = [];
page.on('pageerror', (e) => errs.push(String(e)));
page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await page.goto(URL_, { waitUntil: 'domcontentloaded' });
await enterApp(page);

async function seed(perms, scoped) {
  await page.evaluate(([orders, p, sc]) => {
    STATE.currentUser = { username: 'proc.mgr', displayName: 'محمود العامودي', role: 'user',
      permissions: p, scopeSectors: sc ? ['الصيانة والتشغيل'] : [] };
    STATE.purchaseOrders = orders.map((o) => { const c = JSON.parse(JSON.stringify(o)); recomputePOderived(c); return c; });
    try { applyUserRoleToUI(); } catch (_) {}
  }, [ORDERS, perms, !!scoped]);
}

console.log('\n① بطاقة التقرير → النافذة');
await seed(PROC);
await page.evaluate(() => navigate('reports'));
await page.waitForTimeout(150);

const card = await page.evaluate(() => {
  const c = [...document.querySelectorAll('.rep-card')]
    .find((x) => (x.querySelector('.rep-card-title') || {}).textContent?.includes('متابعة المالية عبر الإيميل'));
  if (!c) return null;
  return { idx: c.getAttribute('data-rep-idx'), locked: c.classList.contains('rep-locked'),
           hasSet: !!c.querySelector('[data-rep-field="set"]'), hasProject: !!c.querySelector('[data-rep-field="project"]') };
});
T('البطاقة موجودة في مركز التقارير بمرشّحَيها', !!card && card.hasSet && card.hasProject && !card.locked);

await page.evaluate((i) => document.querySelector(`.rep-card[data-rep-idx="${i}"] .rep-card-foot .btn`).click(), card.idx);
await page.waitForSelector('#modal-finance-email', { timeout: 5000 });

const opened = await page.evaluate(() => {
  const m = document.getElementById('modal-finance-email');
  const pv = document.getElementById('fin-mail-preview');
  const txt = pv.innerText;
  return {
    ephemeral: m.dataset.ephemeral === '1',
    inBody: m.parentElement === document.body,
    outsidePage: !m.closest('section.page'),
    locked: getComputedStyle(document.body).overflow === 'hidden',
    subject: (document.getElementById('fin-mail-subject-txt') || {}).textContent || '',
    has3301: txt.includes('P.O-DG26-3301'),
    has3302: txt.includes('P.O-DG26-3302'),
    has3303: txt.includes('P.O-DG26-3303'),
    has3304: txt.includes('P.O-DG26-3304'),
    amounts: txt.includes('11,500') && txt.includes('13,800'),
    masked: txt.includes('—') && !txt.includes('11,500'),
    wait: txt.includes('20 يوماً'),
    tables: pv.querySelectorAll('table').length,
    noFlex: !pv.innerHTML.includes('display:flex') && !pv.innerHTML.includes('display:grid'),
  };
});
T('النافذة تُلحَق بـbody خارج أقسام الصفحات وتقفل التمرير',
  opened.ephemeral && opened.inBody && opened.outsidePage && opened.locked);
T('والمعاينة تعرض أوامر «بانتظار التحويل» وحدها',
  opened.has3301 && opened.has3302 && !opened.has3303 && !opened.has3304);
T('وبمبالغها ومدّة انتظار كل أمر', opened.amounts && !opened.masked && opened.wait);
T('والموضوع جاهز بعدده وقيمته', /بانتظار التحويل/.test(opened.subject) && opened.subject.includes('13,800'));
T('والتخطيط جداول لا flex/grid — يصمد في Outlook', opened.tables >= 2 && opened.noFlex);

console.log('\n② الحافظة: منسّق ونصّ');
await page.evaluate(() => document.querySelector('#modal-finance-email .btn-accent').click());
await page.waitForTimeout(400);
const rich = await page.evaluate(async () => {
  try {
    const items = await navigator.clipboard.read();
    const out = { types: [], html: '', text: '' };
    for (const it of items) {
      out.types.push(...it.types);
      if (it.types.includes('text/html')) out.html = await (await it.getType('text/html')).text();
      if (it.types.includes('text/plain')) out.text = await (await it.getType('text/plain')).text();
    }
    return out;
  } catch (e) { return { error: String(e) }; }
});
T('«نسخ منسّق» يضع HTML ونصّاً في الحافظة معاً',
  !rich.error && rich.types.includes('text/html') && rich.types.includes('text/plain'),
  rich.error);
T('والـHTML المنسوخ جدولٌ فيه الأوامر وإجماليها',
  !!rich.html && /<table/.test(rich.html) && rich.html.includes('P.O-DG26-3301') && rich.html.includes('13,800'));
T('والنصّ المرافق بلا وسوم ويحمل الكشف نفسه',
  !!rich.text && !/<table/.test(rich.text) && rich.text.includes('P.O-DG26-3301'));

await page.evaluate(() => {
  const b = [...document.querySelectorAll('#modal-finance-email .fin-mail-foot .btn')]
    .find((x) => x.textContent.includes('نصّاً بسيطاً'));
  b.click();
});
await page.waitForTimeout(400);
const plain = await page.evaluate(() => navigator.clipboard.readText().catch((e) => 'ERR:' + e));
T('و«نسخ نصّاً بسيطاً» يضع نصّاً قابلاً للّصق في أي مكان',
  !plain.startsWith('ERR:') && plain.includes('السلام عليكم') && plain.includes('P.O-DG26-3302')
  && plain.includes('الإجمالي العام') && !/[<>]/.test(plain));

console.log('\n③ تبديل المجموعة والتصدير');
await page.evaluate(() => { document.getElementById('fin-mail-to').value = 'finance@aldeyabi.com'; });
await page.selectOption('#fin-mail-set', 'transferred');
await page.waitForTimeout(200);
const swapped = await page.evaluate(() => {
  const t = document.getElementById('fin-mail-preview').innerText;
  return { has3303: t.includes('P.O-DG26-3303'), has3301: t.includes('P.O-DG26-3301'),
           subject: document.getElementById('fin-mail-subject-txt').textContent,
           to: document.getElementById('fin-mail-to').value };
});
T('تبديل المجموعة يعيد بناء الكشف والموضوع معاً',
  swapped.has3303 && !swapped.has3301 && /مُحوَّل/.test(swapped.subject));
T('ولا يمحو بريد المالية الذي كُتِب', swapped.to === 'finance@aldeyabi.com');

await page.selectOption('#fin-mail-set', 'all');
await page.waitForTimeout(200);
const dl = page.waitForEvent('download', { timeout: 8000 }).catch(() => null);
await page.evaluate(() => {
  const b = [...document.querySelectorAll('#modal-finance-email .fin-mail-foot .btn')]
    .find((x) => x.textContent.includes('CSV'));
  b.click();
});
const file = await dl;
let csvOk = false, csvName = '';
if (file) {
  csvName = file.suggestedFilename();
  const p = await file.path();
  if (p) {
    const fs = await import('node:fs');
    const body = fs.readFileSync(p, 'utf8');
    csvOk = body.charCodeAt(0) === 0xfeff            // BOM — إكسل العربيّ يقرؤه صحيحاً
      && body.includes('الإجمالي شامل الضريبة (ر.س)')
      && body.includes('P.O-DG26-3301') && body.includes('11500')   // رقم بلا فواصل
      && body.includes('P.O-DG26-3303')
      && !body.includes('P.O-DG26-3304');
  }
}
T('وتصدير CSV يُنزّل ملفاً بأعمدة عربية وأرقام قابلة للجمع', csvOk, csvName);

console.log('\n④ الجوال');
await page.setViewportSize({ width: 393, height: 852 });
await page.waitForTimeout(250);
const mob = await page.evaluate(() => {
  const html = document.documentElement, prev = html.style.overflowX;
  html.style.overflowX = 'visible';                   // القناع يجعل القياس يقيس نفسه
  const overflow = html.scrollWidth - html.clientWidth;
  html.style.overflowX = prev;
  const foot = document.querySelector('#modal-finance-email .fin-mail-foot');
  const btns = [...foot.querySelectorAll('.btn')];
  const rows = new Set(btns.map((b) => Math.round(b.getBoundingClientRect().top)));
  const small = btns.filter((b) => b.getBoundingClientRect().height < 30).length;
  const pv = document.getElementById('fin-mail-preview').getBoundingClientRect();
  return { overflow, wrapped: rows.size > 1, small, inScreen: pv.right <= innerWidth + 1 };
});
T('لا انزلاق أفقيّ على 393px', mob.overflow <= 0, String(mob.overflow));
T('وأزرار الإجراءات تلتفّ بلا اقتطاع', mob.wrapped && mob.small === 0 && mob.inScreen);

console.log('\n⑤ البوّابة: من لا يرى المبالغ');
await page.setViewportSize({ width: 1440, height: 900 });
await page.evaluate(() => poFinanceEmailClose());
await seed(NOMONEY, false);
await page.evaluate(() => navigate('reports'));
await page.waitForTimeout(250);
const gated = await page.evaluate(() => {
  const titles = [...document.querySelectorAll('.rep-card-title')].map((x) => x.textContent);
  const toasts = [];
  const real = window.toast; window.toast = (k, t, m) => toasts.push(`${k}|${t}|${m}`);
  poFinanceEmailOpen({ set: 'awaiting' });                 // استدعاء مباشر كما من الطرفية
  window.toast = real;
  return { page: STATE.page, cards: titles.length,
           visible: titles.some((t) => t.includes('متابعة المالية عبر الإيميل')),
           followup: titles.some((t) => t.includes('بلا مبالغ')),   // شاهد: التصفية عملت ولم تُفرِغ الشاشة
           opened: !!document.getElementById('modal-finance-email'),
           denied: toasts.some((t) => /صلاحية مرفوضة/.test(t)) };
});
T('البطاقة محجوبة عمّن لا يرى المبالغ — والشاشة ليست فارغة (التصفية لا تعذُّر الوصول)',
  gated.page === 'reports' && !gated.visible && gated.followup, JSON.stringify(gated));
T('والاستدعاء المباشر مرفوض لا مكشوف', !gated.opened && gated.denied);

await seed(FIELD, true);
const scopedOut = await page.evaluate(() => { navigate('reports'); return STATE.page; });
T('وموظّف الميدان المُنطَّق لا يبلغ مركز التقارير أصلاً', scopedOut !== 'reports', scopedOut);

T('صفر خطأ صفحة', errs.length === 0, errs.join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.join(' | '));

console.log(`\n${'─'.repeat(46)}\nالنتيجة: ${pass} ناجح · ${fail} فاشل`);
await browser.close();
process.exit(fail ? 1 : 0);

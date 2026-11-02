/* فحص متصفّح تحت **CSP الإنتاج** لدليل الموردين وحملة الدعوة (2026-11-02):
 *   (أ) التصفّح بالتصنيف: شريط تصنيفات بعدد كلٍّ، والنقر يُصفّي البطاقات المرسومة،
 *       والبطاقة تحمل تصنيفاتها مع وسم «مُثبَت» لما سعّره المورد فعلاً، والبحث بما
 *       يورّده يجده ولو لم يكتبه في تخصصه.
 *   (ب) الحملة: حالة كل مورد · مفتاح الإرسال الآليّ يكتب الإعداد **ويستدعي الكنس**
 *       بجلسة الموظّف · طابور الواتساب لا يكرّر ما يتولّاه البريد · ونقر واتساب يقيّد
 *       المرحلة ويُحدّث الحالة فوراً.
 *
 * ⚠️ المحكّ ما يُرسَم ويُكتَب فعلاً (DOM + الكتابات المُعترَضة) لا وجود نصّ في الملف.
 * التشغيل: node scripts/csp-preview-server.mjs &  ثمّ  node scripts/e2e/supplier-directory-invite.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const BASE = process.env.BASE || 'http://127.0.0.1:8812';
const SHOTS = process.env.SUPINV_SHOTS || path.join(os.tmpdir(), 'aldeyabi-supinv');
fs.mkdirSync(SHOTS, { recursive: true });
const results = []; const T = (n, ok, d) => { results.push([n, !!ok, d || '']); };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
await blockSupabase(ctx);
const page = await ctx.newPage();
const pageErrors = [], csp = [], apiCalls = [];
page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });
page.on('dialog', d => d.accept());

/* نقطة الدعوة مُقلَّدة: سكّ الرابط · والكنس (يُسجَّل ما يصله ومعه ترويسة الجلسة) */
await page.route('**/api/supplier-invite-link**', async (route) => {
  const req = route.request();
  const u = new URL(req.url());
  apiCalls.push({ sweep: u.searchParams.get('sweep'), method: req.method(), auth: req.headers()['authorization'] || '' });
  if (u.searchParams.get('sweep') === '1') {
    return route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ ok: true, by: 'staff', candidates: 1, sent: 1, failed: 0, capped: false }) });
  }
  const body = JSON.parse(req.postData() || '{}');
  return route.fulfill({ status: 200, contentType: 'application/json',
    body: JSON.stringify({ ok: true, links: (body.supplier_ids || []).map(id => ({ supplier_id: id, url: `${BASE}/register?s=tok-${id}` })) }) });
});

await page.goto(`${BASE}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.renderSuppliers === 'function'
  && typeof window.loadRegCampaign === 'function' && typeof window.regCampSetAuto === 'function');
await enterApp(page);

/* ── البيانات: ستّة موردين بأحوال مختلفة + كتالوج وسجلّ سعريّ ── */
await page.evaluate(() => {
  STATE.currentUser = Object.assign({}, STATE.currentUser, { username: 'Mahmoud', role: 'admin', permissions: {} });
  STATE.items = [
    { code: 'C1', name: 'مكنسة كهربائية', category: 'معدات التنظيف' },
    { code: 'C2', name: 'لمبة LED 18 واط', category: 'كهربائي' },
  ];
  STATE.history = [
    { num: 1, code: 'C1', name: 'مكنسة كهربائية 1600 واط', supplier: 'شركة النخبة', price: 300, date: '2026-10-01' },
    { num: 2, code: 'C2', name: 'لمبة LED 18 واط', supplier: 'مؤسسة النور', price: 12, date: '2026-10-02' },
  ];
  STATE.suppliers = [
    { id: 'S1', name: 'شركة النخبة', specialty: 'سباكة', mobile: '0501111111', email: 'nukhba@example.com' },
    { id: 'S2', name: 'مؤسسة النور', specialty: 'إضاءة', mobile: '0502222222' },
    { id: 'S3', name: 'مصنع البناء', specialty: 'دهانات، حديد تسليح', phone: '0112223333' },
    { id: 'S4', name: 'مورد بلا تصنيف', specialty: '' },
    { id: 'S5', name: 'مورد مسجَّل', specialty: 'سباكة', commercial_reg: '1010101010', mobile: '0505555555' },
    { id: 'S6', name: 'مولدات الخليج', specialty: 'مولدات ديزل خاصة', mobile: '0506666666' },
  ];
  navigate('suppliers');
});
await page.waitForSelector('#sup-cats .sup-cat-chip');

const dir = () => page.evaluate(() => ({
  chips: [...document.querySelectorAll('#sup-cats .sup-cat-chip')].map(c => ({
    t: c.textContent.replace(/\s+/g, ' ').trim(), on: c.getAttribute('aria-pressed') === 'true' })),
  cards: [...document.querySelectorAll('#supplier-grid .supplier-card, #supplier-grid [onclick*="openSupplier"]')]
    .map(c => c.textContent.replace(/\s+/g, ' ').trim()),
  count: (document.getElementById('sup-count') || {}).textContent || '',
}));

let d = await dir();
const chipOf = (label) => d.chips.find(c => c.t.includes(label));
T('شريط التصنيفات مرسوم بعدد لكل تصنيف', d.chips.length >= 4 && /\d/.test((chipOf('السباكة') || {}).t || ''),
  JSON.stringify(d.chips.map(c => c.t)));
T('«السباكة» تعُدّ اثنين (معلَن نصّاً «سباكة»)', /السباكة والصرف الصحي\s*2/.test((chipOf('السباكة') || {}).t || ''), (chipOf('السباكة') || {}).t);
T('«غير مصنّف» يظهر ويعُدّ من بلا تصنيف ولا دليل', /غير مصنّف\s*2/.test((chipOf('غير مصنّف') || {}).t || ''), (chipOf('غير مصنّف') || {}).t);
T('البطاقة تحمل وسم «مُثبَت» لما سعّره المورد', await page.evaluate(() =>
  [...document.querySelectorAll('.sup-cat-tag.ev')].some(t => /النظافة والمواد الاستهلاكية/.test(t.textContent))));
T('الوسم الحرّ (بلا مقابل معتمد) ظاهر لا مُسقَط', await page.evaluate(() =>
  [...document.querySelectorAll('.sup-cat-tag.free')].some(t => /مولدات ديزل خاصة/.test(t.textContent))));
await page.screenshot({ path: path.join(SHOTS, 'directory-desktop.png') });

/* النقر الحقيقيّ على شريحة تصنيف يُصفّي البطاقات المرسومة */
await page.locator('#sup-cats .sup-cat-chip', { hasText: 'الكهرباء والإنارة' }).click();
d = await dir();
T('نقر «الكهرباء والإنارة» يُبقي «مؤسسة النور» وحدها', d.cards.length === 1 && /مؤسسة النور/.test(d.cards[0]), JSON.stringify(d.cards));
T('والشريحة المختارة مُعلَنة بـaria-pressed', (d.chips.find(c => c.on) || {}).t?.includes('الكهرباء والإنارة'));
await page.locator('#sup-cats .sup-cat-chip', { hasText: 'كل التصنيفات' }).click();

/* البحث بما يورّده فعلاً */
/* ⚠️ `enterApp` لا يُشغّل `startApp()` فمستمع البحث غير مربوط هنا (درس ٣٤) — والمستمع
   نفسه محروس بنيويّاً في الحزمة؛ نرسم صراحةً بعد الكتابة في الحقل الحقيقيّ. */
await page.fill('#sup-search', 'مكنسة');
await page.evaluate(() => renderSuppliers());
d = await dir();
T('البحث «مكنسة» يجد «شركة النخبة» (سعّرها، ولم يكتبها في تخصصه)',
  d.cards.length === 1 && /شركة النخبة/.test(d.cards[0]), JSON.stringify(d.cards));
await page.fill('#sup-search', '');
await page.evaluate(() => renderSuppliers());

/* ── (ب) حملة الدعوة: عميل مُقلَّد بشكل الإنتاج ── */
await page.evaluate(() => {
  window.__w = { upserts: [], audits: [] };
  const regs = [{ commercial_reg: '1010101010', vat_number: '', legal_name_ar: 'أخرى', link_supplier_id: null }];
  const audit = [{ id: 1, entity_id: 'S2', action: 'supplier_invite_wa', new_value: { name: 'مؤسسة النور' },
                   ts: new Date(Date.now() - 9 * 86400000).toISOString() }];
  let setting = null;
  const q = (name) => {
    const st = { name, _ins: null, _ups: null, _range: null, _eq: {} };
    const o = {
      select(){ return o; }, order(){ return o; }, or(){ return o; }, eq(c, v){ st._eq[c] = v; return o; },
      range(a, b){ st._range = [a, b]; return o; }, limit(){ return o; },
      insert(r){ st._ins = r; return o; }, upsert(r){ st._ups = r; return o; },
      maybeSingle(){ return Promise.resolve({ data: setting ? { value: setting } : null, error: null }); },
      then(res){
        if (st._ins) { if (name === 'proc_audit_log') window.__w.audits.push(st._ins); return Promise.resolve({ error: null }).then(res); }
        if (st._ups) { window.__w.upserts.push(st._ups); setting = st._ups.value; return Promise.resolve({ error: null }).then(res); }
        const all = name === 'proc_supplier_registrations' ? regs : name === 'proc_audit_log' ? audit : [];
        const data = st._range ? all.slice(st._range[0], st._range[1] + 1) : all;
        return Promise.resolve({ data, error: null }).then(res);
      },
    };
    return o;
  };
  CLOUD = { enabled: true, client: { from: q,
    auth: { getSession: async () => ({ data: { session: { access_token: 'staff-jwt' } } }) } } };
  window.__opened = [];
  window.open = (u) => { window.__opened.push(String(u)); return {}; };
  try { Object.defineProperty(navigator, 'clipboard', { value: { writeText: async () => {} }, configurable: true }); } catch (_) {}
  navigate('registrations');
});
await page.evaluate(() => loadRegCampaign());
await page.waitForSelector('#regcamp-body table');

const camp = () => page.evaluate(() => {
  const rows = [...document.querySelectorAll('#regcamp-body tbody tr')].map(tr =>
    [...tr.children].map(td => td.textContent.replace(/\s+/g, ' ').trim()));
  const auto = (document.querySelector('#regcamp-body .regcamp-auto') || {}).textContent || '';
  const chips = [...document.querySelectorAll('#regcamp-body button[aria-pressed]')].map(b => b.textContent.replace(/\s+/g, ' ').trim());
  return { rows, auto: auto.replace(/\s+/g, ' ').trim(), chips };
});
let c = await camp();
const rowOf = (n) => c.rows.find(r => r[0].includes(n)) || [];
T('المسجَّل (بالسجل التجاري) لا يظهر في الحملة', !c.rows.some(r => r[0].includes('مورد مسجَّل')), JSON.stringify(c.rows.map(r => r[0])));
T('من دُعي واتساب قبل 9 أيام ⇒ «تذكير مستحقّ»', /تذكير مستحقّ/.test(rowOf('مؤسسة النور')[2] || ''), rowOf('مؤسسة النور')[2]);
T('من لم يُدعَ ⇒ «لم يُدعَ بعد»', /لم يُدعَ بعد/.test(rowOf('مولدات الخليج')[2] || ''), rowOf('مولدات الخليج')[2]);
T('الإرسال الآليّ مُطفأ افتراضاً ويُقال صراحةً', /مُطفأ/.test(c.auto), c.auto);
T('والطابور (الآليّ مُطفأ) يضمّ كل مستحقّ له جوال: 3', /واتساب مستحقّ الآن 3/.test(c.chips.join('|')), c.chips.join('|'));
await page.screenshot({ path: path.join(SHOTS, 'campaign-off.png') });

/* نقر «تفعيل» حقيقيّ: يكتب الإعداد ثمّ يستدعي الكنس بجلسة الموظّف */
await page.locator('#regcamp-body button', { hasText: 'تفعيل الإرسال الآليّ' }).click();
await page.waitForFunction(() => window.__w.upserts.length > 0);
await page.waitForTimeout(400);
const w = await page.evaluate(() => window.__w);
T('التفعيل يكتب supplier_invite_auto بقيمة enabled=true',
  w.upserts.length === 1 && w.upserts[0].key === 'supplier_invite_auto' && w.upserts[0].value.enabled === true, JSON.stringify(w.upserts));
const sw = apiCalls.find(x => x.sweep === '1');
T('ثمّ يستدعي الكنس POST بترويسة جلسة الموظّف', sw && sw.method === 'POST' && sw.auth === 'Bearer staff-jwt', JSON.stringify(apiCalls));
T('والتغيير مُقيَّد في التدقيق', w.audits.some(a => a.action === 'supplier_invite_auto_on'));
await page.waitForSelector('#regcamp-body table');
c = await camp();
T('اللوحة تقول «مُفعَّل» بعد التفعيل', /مُفعَّل/.test(c.auto), c.auto);
T('ومن له بريد خرج من طابور الواتساب (البريد يتولّاه): 2', /واتساب مستحقّ الآن 2/.test(c.chips.join('|')), c.chips.join('|'));
await page.screenshot({ path: path.join(SHOTS, 'campaign-on.png') });

/* نقر «واتساب» على مؤسسة النور: رسالة التذكير + قيد المرحلة + تحديث الحالة فوراً */
await page.locator('#regcamp-body tr', { hasText: 'مؤسسة النور' }).locator('button', { hasText: 'واتساب' }).click();
await page.waitForFunction(() => window.__opened.length > 0);
const opened = await page.evaluate(() => window.__opened[0]);
T('واتساب يفتح wa.me بنصّ «التذكير» لا الدعوة الأولى',
  /wa\.me\/966502222222/.test(opened) && decodeURIComponent(opened).includes('نذكّركم بدعوة'), opened.slice(0, 80));
const wa = await page.evaluate(() => window.__w.audits.filter(a => a.action === 'supplier_invite_wa').map(a => a.new_value));
T('والإرسال مُقيَّد بمرحلته (inv2) وقناته', wa.length === 1 && wa[0].stage === 'inv2' && wa[0].channel === 'wa', JSON.stringify(wa));
c = await camp();
T('والحالة تتحدّث فوراً: «تذكير أخير بعد 14 يوماً»', /تذكير أخير بعد 14 يوماً/.test(rowOf('مؤسسة النور')[2] || ''), rowOf('مؤسسة النور')[2]);

/* ── الجوال ── */
await page.setViewportSize({ width: 393, height: 852 });
await page.waitForTimeout(200);
const over = () => page.evaluate(() => {
  document.documentElement.style.overflowX = 'visible';
  const o = Math.max(0, document.documentElement.scrollWidth - document.documentElement.clientWidth);
  document.documentElement.style.overflowX = '';
  return o;
});
T('حملة الدعوة على 393px: صفر انزلاق أفقيّ', (await over()) === 0);
await page.screenshot({ path: path.join(SHOTS, 'campaign-mobile.png') });
await page.evaluate(() => navigate('suppliers'));
await page.waitForTimeout(200);
T('دليل الموردين على 393px: صفر انزلاق أفقيّ', (await over()) === 0);
await page.screenshot({ path: path.join(SHOTS, 'directory-mobile.png') });

T('صفر خطأ صفحة', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.slice(0, 2).join(' | '));

await browser.close();
const bad = results.filter(r => !r[1]);
for (const [n, ok, dd] of results) console.log(`  ${ok ? '✓' : '✗'} ${n}${dd && !ok ? '  → ' + dd : ''}`);
console.log(`\nدليل الموردين وحملة الدعوة: ${results.length - bad.length}/${results.length} · اللقطات: ${SHOTS}`);
process.exit(bad.length ? 1 : 0);

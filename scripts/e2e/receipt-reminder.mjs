/* فحص متصفّح تحت **CSP الإنتاج** لتذكير الاستلام لصاحب الطلب (2026-11-03):
 *   (أ) الرابط العميق من البريد: `?po=…&act=receive` يفتح نافذة الاستلام، و`act=wait`
 *       يفتح «لم تصل بعد» — **حتى لو وصل الأمر بعد الترطيب**، وقيمة act مجهولة تفتح
 *       الأمر فقط، والمعامل يُنظَّف من الشريط.
 *   (ب) «لم تصل بعد»: نقرة على السبب ⇒ ملاحظة على الأمر (po_add_comment) ثمّ قيد ردّ
 *       يُسكِت التذكير ثمّ بريد للمشتريات (not_arrived). وفشل الملاحظة لا يُسكِت شيئاً.
 *   (ج) لوحة الإنذارات: معاينة من سيصله التذكير وبأيّ أوامر، ومفتاح التفعيل يكتب
 *       الإعداد ثمّ يستدعي الكنس بجلسة الموظّف. والموظّف المُنطَّق لا يرى المفتاح.
 *
 * ⚠️ المحكّ ما يُرسَم ويُكتَب فعلاً (DOM + الكتابات المُعترَضة) لا وجود نصّ في الملف.
 * التشغيل: node scripts/csp-preview-server.mjs &  ثمّ  node scripts/e2e/receipt-reminder.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const BASE = process.env.BASE || 'http://127.0.0.1:8812';
const SHOTS = process.env.RR_SHOTS || path.join(os.tmpdir(), 'aldeyabi-receipt-reminder');
fs.mkdirSync(SHOTS, { recursive: true });
const results = []; const T = (n, ok, d) => { results.push([n, !!ok, d || '']); };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
await blockSupabase(ctx);
const page = await ctx.newPage();
const pageErrors = [], csp = [], api = [];
page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });
page.on('dialog', d => d.accept());

await page.route('**/api/receipt-reminder**', async (route) => {
  const r = route.request();
  api.push({ path: 'rr', url: r.url(), method: r.method(), auth: r.headers()['authorization'] || '' });
  return route.fulfill({ status: 200, contentType: 'application/json',
    body: JSON.stringify({ ok: true, by: 'staff', people: 1, sent: 1, orders: 2, failed: 0 }) });
});
await page.route('**/api/notify**', async (route) => {
  const r = route.request();
  api.push({ path: 'notify', body: JSON.parse(r.postData() || '{}'), auth: r.headers()['authorization'] || '' });
  return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
});

await page.goto(`${BASE}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.openDeepLink === 'function' && typeof window.rrWaitOpen === 'function');
await enterApp(page);

const DAY = 86400000;
const ymd = (n) => new Date(Date.now() + 3 * 3600000 - n * DAY).toISOString().slice(0, 10);

/* عميل مُقلَّد: يلتقط rpc والإدراجات، ويُرجع جداول بشكل الإنتاج */
await page.evaluate(({ late10, late3 }) => {
  window.__w = { rpc: [], audits: [], upserts: [], rpcFail: false };
  let setting = null;
  const tables = {
    proc_pr_po_links: [{ pr_id: 'PR-DG2026-0007', po_number: 'P.O-DG26-3274', active: true },
                       { pr_id: 'PR-DG2026-0008', po_number: 'P.O-DG26-3276', active: true }],
    proc_purchase_requests: [{ id: 'PR-DG2026-0007', requester: 'mostafa.kishk', status: 'approved', archived_at: null },
                             { id: 'PR-DG2026-0008', requester: 'mostafa.kishk', status: 'approved', archived_at: null }],
    proc_users: [{ username: 'mostafa.kishk', display_name: 'مصطفى كشك', active: true }],
    proc_audit_log: [],
  };
  const q = (name) => {
    const st = { ins: null, ups: null, eq: {} };
    const o = {
      select(){ return o; }, eq(c, v){ st.eq[c] = v; return o; }, in(){ return o; }, gte(){ return o; }, limit(){ return o; }, order(){ return o; },
      insert(r){ st.ins = r; return o; }, upsert(r){ st.ups = r; return o; },
      maybeSingle(){ return Promise.resolve({ data: setting ? { value: setting } : null, error: null }); },
      then(res){
        if (st.ins) { if (name === 'proc_audit_log') window.__w.audits.push(st.ins); return Promise.resolve({ error: null }).then(res); }
        if (st.ups) { window.__w.upserts.push(st.ups); setting = st.ups.value; return Promise.resolve({ error: null }).then(res); }
        // يحترم مرشّحات eq كالقاعدة الحقيقية — كعبٌ يتجاهلها يُرجع صفّاً لا يخصّ الاستعلام
        const rows = (tables[name] || []).filter(r => Object.entries(st.eq).every(([c, v]) => !(c in r) || r[c] === v));
        return Promise.resolve({ data: rows, error: null }).then(res);
      },
    };
    return o;
  };
  CLOUD = { enabled: true, client: { from: q,
    rpc: async (fn, args) => { window.__w.rpc.push({ fn, args });
      return window.__w.rpcFail ? { data: null, error: { message: 'تعذّر' } } : { data: { ok: true }, error: null }; },
    auth: { getSession: async () => ({ data: { session: { access_token: 'staff-jwt' } } }) } } };
  // موظّف الصيانة المُنطَّق — صاحب الطلب ومستلِم البضاعة
  STATE.currentUser = Object.assign({}, STATE.currentUser, {
    username: 'mostafa.kishk', displayName: 'مصطفى كشك', role: 'user', scopeSectors: ['الصيانة والتشغيل'],
    permissions: { can_receive_po: true, can_comment: true, can_create_pr: true } });
  const item = (desc, qty) => ({ desc, unit: 'حبة', qty, price: 0, received_qty: 0 });
  STATE.purchaseOrders = [
    { po_number: 'P.O-DG26-3274', status: 'تسليم للإدارة المالية', sector: 'الصيانة والتشغيل', project: 'جامعة الملك سعود',
      supplier: 'شركة روافد الكهرباء', expected_delivery: late10, items: [item('كابل 4 ملي', 10), item('مفتاح بيلانكو', 6)], receipts: [], comments: [] },
    { po_number: 'P.O-DG26-3276', status: 'قيد التوريد', sector: 'الصيانة والتشغيل', project: 'جامعة الملك سعود',
      supplier: 'مؤسسة الاختبار', expected_delivery: late3, items: [item('لمبة LED', 20)], receipts: [], comments: [] },
  ];
  navigate('purchase-orders');
}, { late10: ymd(10), late3: ymd(3) });

const openState = () => page.evaluate(() => ({
  receive: !!document.getElementById('modal-po-receive'),
  wait: !!document.getElementById('modal-rr-wait'),
  drawer: document.getElementById('po-drawer')?.classList.contains('active'),
  search: location.search,
}));
const closeAll = () => page.evaluate(() => {
  ['modal-po-receive', 'modal-rr-wait'].forEach(id => document.getElementById(id)?.remove());
  closePODrawer();
  syncScrollLock();
});

/* ── (أ) الرابط العميق ── */
await page.evaluate(() => { history.replaceState(null, '', '/index.html?po=P.O-DG26-3274&act=receive'); openDeepLink(); });
await page.waitForSelector('#modal-po-receive', { timeout: 5000 }).catch(() => {});
let s = await openState();
T('act=receive يفتح نافذة الاستلام على الأمر نفسه', s.receive && await page.evaluate(() =>
  /P\.O-DG26-3274/.test(document.querySelector('#modal-po-receive h3')?.textContent || '')), JSON.stringify(s));
T('والدرج مفتوح خلفها', s.drawer === true);
T('والمعامل نُظِّف من الشريط (لا يُعاد الفتح مع التحديث)', s.search === '', s.search);
await page.screenshot({ path: path.join(SHOTS, 'deeplink-receive.png') });
await closeAll();

await page.evaluate(() => { history.replaceState(null, '', '/index.html?po=P.O-DG26-3274&act=evil'); openDeepLink(); });
await page.waitForTimeout(500);
s = await openState();
T('قيمة act مجهولة ⇒ يُفتح الأمر فقط', s.drawer && !s.receive && !s.wait, JSON.stringify(s));
await closeAll();

// الأمر يصل بعد الترطيب (كما للموظّف المُنطَّق من proc_po_visible)
await page.evaluate(() => {
  window.__held = STATE.purchaseOrders.find(p => p.po_number === 'P.O-DG26-3276');
  STATE.purchaseOrders = STATE.purchaseOrders.filter(p => p !== window.__held);
  history.replaceState(null, '', '/index.html?po=P.O-DG26-3276&act=wait'); openDeepLink();
  setTimeout(() => STATE.purchaseOrders.push(window.__held), 900);
});
await page.waitForSelector('#modal-rr-wait', { timeout: 6000 }).catch(() => {});
s = await openState();
T('act=wait يفتح «لم تصل بعد» حتى لو وصل الأمر بعد الترطيب بثانية', s.wait, JSON.stringify(s));
// إن أخفق الرابط نفسه نفتح النافذة مباشرةً كي تُقاس بقيّة الحرّاس — الإخفاق مسجَّل أعلاه
// باسمه، والاستثناء الخامّ (مهلة نقرٍ على نافذة غائبة) لا يقول أيّ ثابت انكسر.
if (!s.wait) await page.evaluate(() => { if (!STATE.purchaseOrders.includes(window.__held)) STATE.purchaseOrders.push(window.__held); rrWaitOpen('P.O-DG26-3276'); });

/* ── (ب) «لم تصل بعد» ── */
const reasonBoxes = await page.evaluate(() => [...document.querySelectorAll('#modal-rr-wait .rr-reason')]
  .map(l => Math.round(l.getBoundingClientRect().height)));
T('أربعة أسباب، كلٌّ هدف لمس ≥44px', reasonBoxes.length === 4 && reasonBoxes.every(h => h >= 44), JSON.stringify(reasonBoxes));
await page.locator('#modal-rr-wait .rr-reason', { hasText: 'المورد أبلغ بتأخير' }).click();
await page.fill('#rr-wait-note', 'قال الأحد القادم');
await page.screenshot({ path: path.join(SHOTS, 'wait-modal.png') });
await page.locator('#rr-wait-send').click();
await page.waitForFunction(() => !document.getElementById('modal-rr-wait'), null, { timeout: 4000 }).catch(() => {});
await page.waitForTimeout(400);
let w = await page.evaluate(() => window.__w);
const cm = w.rpc.find(r => r.fn === 'po_add_comment');
T('الملاحظة تُكتب على الأمر بالسبب والتفاصيل', cm && cm.args.p_po === 'P.O-DG26-3276'
  && /المورد أبلغ بتأخير: قال الأحد القادم/.test(cm.args.p_text), JSON.stringify(cm));
const rp = w.audits.find(a => a.action === 'reply' && a.entity_type === 'receipt_reminder');
T('ويُقيَّد ردّاً (يُسكِت التذكير)', rp && rp.entity_id === 'P.O-DG26-3276' && rp.new_value.reason === 'supplier', JSON.stringify(rp));
const nt = api.find(a => a.path === 'notify');
T('ويُرسَل للمشتريات حدث not_arrived على الطلب المربوط', nt && nt.body.kind === 'pr' && nt.body.event === 'not_arrived'
  && nt.body.pr_id === 'PR-DG2026-0008' && /P\.O-DG26-3276/.test(nt.body.comment), JSON.stringify(nt));
T('والنافذة أُغلقت والملاحظة ظاهرة في الدرج', !(await openState()).wait && await page.evaluate(() =>
  /لم تصل البضاعة بعد/.test(document.getElementById('po-drawer')?.textContent || '')));
await closeAll();

// «سبب آخر» بلا كتابة ⇒ لا إرسال
await page.evaluate(() => rrWaitOpen('P.O-DG26-3274'));
await page.locator('#modal-rr-wait .rr-reason', { hasText: 'سبب آخر' }).click();
const before = await page.evaluate(() => window.__w.rpc.length);
await page.locator('#rr-wait-send').click();
await page.waitForTimeout(300);
T('«سبب آخر» بلا كتابة ⇒ لا يُرسَل شيء والنافذة باقية',
  (await page.evaluate(() => window.__w.rpc.length)) === before && (await openState()).wait);

// فشل الملاحظة ⇒ لا قيد ردّ (لا يُسكِت تذكيراً لم يصل للمشتريات)
await page.evaluate(() => { window.__w.rpcFail = true; });
await page.locator('#modal-rr-wait .rr-reason', { hasText: 'لم يصل شيء' }).click();
const aBefore = await page.evaluate(() => window.__w.audits.filter(a => a.action === 'reply').length);
await page.locator('#rr-wait-send').click();
await page.waitForTimeout(400);
T('فشل الملاحظة ⇒ لا قيد ردّ والنافذة باقية للمحاولة',
  (await page.evaluate(() => window.__w.audits.filter(a => a.action === 'reply').length)) === aBefore && (await openState()).wait);
await page.evaluate(() => { window.__w.rpcFail = false; });

/* ── الجوال ── */
await page.setViewportSize({ width: 393, height: 852 });
await page.waitForTimeout(200);
const over = () => page.evaluate(() => {
  document.documentElement.style.overflowX = 'visible';
  const o = Math.max(0, document.documentElement.scrollWidth - document.documentElement.clientWidth);
  document.documentElement.style.overflowX = '';
  return o;
});
T('نافذة «لم تصل بعد» على 393px: صفر انزلاق', (await over()) === 0);
T('وحقل التفاصيل 16px (لا يُقرّب iOS)', await page.evaluate(() =>
  parseFloat(getComputedStyle(document.getElementById('rr-wait-note')).fontSize) >= 16));
await page.screenshot({ path: path.join(SHOTS, 'wait-mobile.png') });
await closeAll();
await page.setViewportSize({ width: 1440, height: 900 });

/* ── (ج) لوحة الإنذارات ── */
// الموظّف المُنطَّق لا يرى المفتاح
await page.evaluate(() => { STATE.poView = 'alerts'; renderPurchaseOrders(); });
await page.waitForTimeout(300);
T('الموظّف المُنطَّق: لا صندوق تذكير', await page.evaluate(() => (document.getElementById('rr-box')?.innerHTML || '').trim() === ''));

await page.evaluate(() => {
  STATE.currentUser = Object.assign({}, STATE.currentUser, { username: 'Abdullah', displayName: 'عبدالله', role: 'admin', scopeSectors: [], permissions: {} });
  renderPurchaseOrders();
});
await page.waitForFunction(() => /الدفعة القادمة|لا أوامر مستحقّة/.test(document.getElementById('rr-box')?.textContent || ''), null, { timeout: 4000 }).catch(() => {});
const box = () => page.evaluate(() => (document.getElementById('rr-box')?.textContent || '').replace(/\s+/g, ' ').trim());
let b = await box();
T('المعاينة: مُطفأ افتراضاً', /مُطفأ/.test(b), b.slice(0, 120));
T('المعاينة تسمّي من يصله وبأيّ أوامر (شخص واحد · أمرا شراء)', /الدفعة القادمة: شخص واحد · أمرا شراء/.test(b) && /مصطفى كشك/.test(b)
  && /P\.O-DG26-3274/.test(b) && /P\.O-DG26-3276/.test(b), b.slice(0, 260));
T('والأمر الأشدّ تأخيراً أوّلاً', b.indexOf('P.O-DG26-3274') < b.indexOf('P.O-DG26-3276'));
await page.screenshot({ path: path.join(SHOTS, 'alerts-off.png') });
await page.locator('#rr-on').click();
await page.waitForFunction(() => window.__w.upserts.length > 0, null, { timeout: 4000 }).catch(() => {});
await page.waitForFunction(() => /مُفعَّل/.test(document.getElementById('rr-box')?.textContent || ''), null, { timeout: 4000 }).catch(() => {});
w = await page.evaluate(() => window.__w);
T('التفعيل يكتب receipt_reminder_auto بقيمة enabled=true',
  w.upserts.length === 1 && w.upserts[0].key === 'receipt_reminder_auto' && w.upserts[0].value.enabled === true, JSON.stringify(w.upserts));
const sw = api.find(a => a.path === 'rr' && /sweep=1/.test(a.url));
T('ثمّ يستدعي الكنس POST بجلسة الموظّف', sw && sw.method === 'POST' && sw.auth === 'Bearer staff-jwt', JSON.stringify(api.filter(a => a.path === 'rr')));
T('والتغيير مُقيَّد في التدقيق', w.audits.some(a => a.action === 'receipt_reminder_on'));
b = await box();
T('الصندوق يقول «مُفعَّل» ويعرض «إيقاف التذكير»', /مُفعَّل/.test(b) && /إيقاف التذكير/.test(b), b.slice(0, 120));
await page.screenshot({ path: path.join(SHOTS, 'alerts-on.png') });

T('صفر خطأ صفحة', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.slice(0, 2).join(' | '));

await browser.close();
const bad = results.filter(r => !r[1]);
for (const [n, ok, dd] of results) console.log(`  ${ok ? '✓' : '✗'} ${n}${dd && !ok ? '  → ' + dd : ''}`);
console.log(`\nتذكير الاستلام: ${results.length - bad.length}/${results.length} · اللقطات: ${SHOTS}`);
process.exit(bad.length ? 1 : 0);

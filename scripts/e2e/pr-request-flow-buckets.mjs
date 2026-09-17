/* فحص متصفّح تحت **CSP الإنتاج** لبلاغ المالك (2026-09-17):
 *
 *   ① «ارجاع الطلبات لمقدم الطلب — عندما يعود له الطلب لا يمكنه اجراء اي تعديل
 *      عليه، فقط عاد اليه. اليوم اضطرينا الغاء طلب تم اعادته للاستكمال.»
 *   ② «عندما يتم استلام الطلب المفروض يذهب لخانة الطلبات المستلمة تحت التنفيذ
 *      وتظهر للمستلم في طلباتي المستلمة.»
 *   ③ «الطلبات بعد التنفيذ تذهب لموظّف الصيانة في خانة الطلبات اللي تبقى لها
 *      الاستلام وتقفل.»
 *   ④ «الطلبات اللي عليها نقاش يظهر تنبيه ومنشن للرد، وليس ما نعرف الرد على ايش.»
 *
 * ⚠️ العيب ① مرّ من كل الفحوص النصّية سنةً كاملة لأنّ الخادم كان يقبل `returned`
 *    والواجهة لا تعرض زرّاً. فالمحكّ هنا **نقرٌ حقيقيّ** يفتح المُحرِّر فعلاً.
 *
 * التشغيل: node scripts/csp-preview-server.mjs &  ثمّ  node scripts/e2e/pr-request-flow-buckets.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const BASE = process.env.BASE || 'http://127.0.0.1:8812';
const SHOTS = process.env.PR_FLOW_SHOTS || path.join(os.tmpdir(), 'aldeyabi-pr-flow-buckets');
fs.mkdirSync(SHOTS, { recursive: true });
const shot = (name) => page.screenshot({ path: path.join(SHOTS, name + '.png'), fullPage: false });
const results = []; const T = (n, ok, d) => { results.push([n, !!ok, d || '']); };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const pageErrors = [], csp = [];
page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await blockSupabase(page);   // انظر app-boot.mjs — لا فحص يلمس قاعدة الإنتاج
await page.goto(`${BASE}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.prWorkspaceHTML === 'function'
  && typeof window.prCanEditRequest === 'function' && typeof window.prQueueGroup === 'function');
await enterApp(page);

/* حالة مصنوعة تغطّي الأطوار الأربعة. المواعيد محسوبة من اليوم لا ثابتة. */
const seed = async (username, displayName, opts = {}) => page.evaluate(async (a) => {
  try { hideLoginScreen(); } catch (e) {}
  CLOUD = window.CLOUD = { enabled: true, client: {
    auth: { getSession: async () => ({ data: { session: { access_token: 'jwt' } } }) },
    from: () => ({ select: () => ({ order: () => ({ range: async () => ({ data: [], error: null }) }) }) }),
  } };
  const mk = (n, o) => Object.assign({
    id: 'PR-DG2026-' + String(n).padStart(4, '0'), request_no: 'PR-DG2026-' + String(n).padStart(4, '0'),
    title: 'طلب ' + n, requester: 'mostafa.kishk', requester_name: 'مصطفى كشك',
    department_id: 'DEP-OPS', department: 'الصيانة والتشغيل', project: 'أمانة الأحساء',
    approvals: [], approvals_current: [], messages: [], audit: [], attachments: [], po_links: [],
    items: [{ id: 1, description: 'صابون سائل', unit: 'حبة', requested_qty: 10 }],
  }, o);
  STATE.currentUser = { username: a.username, displayName: a.displayName, role: a.role || 'user',
    permissions: a.perms || {} };
  STATE.departments = [{ id: 'DEP-OPS', name_ar: 'الصيانة والتشغيل', sector: 'الصيانة والتشغيل', active: true }];
  STATE.purchaseRequests = [
    // ① مُعاد للاستكمال بسبب مكتوب
    mk(21, { status: 'returned', workflow_state: 'returned', return_reason: 'أضف عرض سعر ثالث',
             approvals: [{ seq: 1, stage_key: 'maintenance_need', stage_label: 'اعتماد الحاجة',
                           decision: 'returned', comment: 'أضف عرض سعر ثالث',
                           approver: 'm.elsobky', approver_name: 'م.محمد السبكي', acted_at: '2026-09-16T08:00:00Z' }] }),
    // ② مستلَم تحت التنفيذ باسم مُستلِمه
    mk(22, { status: 'approved', workflow_state: 'pricing', proc_status: 'in_progress',
             proc_started_by: 'proc1', proc_started_at: '2026-09-16T09:00:00Z' }),
    // ② بانتظار من يستلمه
    mk(23, { status: 'approved', workflow_state: 'pricing' }),
    // ③ صدر أمره وينتظر استلام البضاعة
    mk(24, { status: 'approved', workflow_state: 'ordered', proc_status: 'po_issued',
             po_links: [{ po_number: 'P.O-DG26-3210', allocations: [] }] }),
    // ④ استفهام بلا ردّ
    mk(25, { status: 'approved', workflow_state: 'pricing', proc_status: 'in_progress',
             proc_started_by: 'proc1',
             messages: [{ id: 1, kind: 'question', body: 'هل الكمية 10 أم 100؟',
                          author: 'proc1', author_name: 'أحمد المشتريات', created_at: '2026-09-16T10:00:00Z' }] }),
  ];
  STATE.purchaseOrders = [{ po_number: 'P.O-DG26-3210', supplier: 'مورد', status: 'تسليم جزئي', items: [] }];
  STATE.prWorkspaceMode = 'requests'; STATE.prWorkspaceFilter = 'all'; STATE.prWorkspaceSearch = '';
  STATE.prView = 'list'; STATE.prTrackId = a.track || 'PR-DG2026-0021';
  __prLoaded = true;
  navigate('pr');
  await renderPRPortal();
}, Object.assign({ username, displayName }, opts));

const groups = () => page.evaluate(() => [...document.querySelectorAll('.pr-work-queue .pr-work-group span')]
  .map(el => el.textContent.trim()));

/* ═══ ① مقدّم الطلب: المُعاد يُعدَّل فعلاً ═══ */
await seed('mostafa.kishk', 'مصطفى كشك', { perms: { can_create_pr: true, can_comment: true },
  track: 'PR-DG2026-0021' });
await page.waitForSelector('.pr-work-queue .pr-work-list', { timeout: 15000 });

T('لوحة «أُعيد إليك للاستكمال» ظاهرة بسببها واسم من أعادها',
  await page.evaluate(() => {
    const c = document.querySelector('.pr-work-returned');
    return !!c && /أضف عرض سعر ثالث/.test(c.textContent) && /م\.محمد السبكي/.test(c.textContent);
  }));

const editBtn = page.locator('.pr-work-returned button', { hasText: 'تعديل الطلب وإعادة إرساله' });
const hasEdit = await editBtn.count() === 1;
T('  وفيها زرّ تعديل حقيقيّ (كان الطلب بلا أي مخرج غير الإلغاء)', hasEdit);
await shot('1-returned-card');
/* ⚠️ لا نقر على زرٍّ غائب: مهلة `locator.click` الخام تُنهي السكربت بخطأ لا
   بتقرير، فيُخفي أيّ تأكيدٍ بعده بدل أن يسمّي ما سقط. */
if (hasEdit) {
  await editBtn.first().click();
  await page.waitForSelector('#pr-title', { timeout: 15000 });
}
/* ⚠️ `let __prEditId` ارتباطٌ معجميّ لا خاصيّة على `window` — `window.__prEditId`
   يعود `undefined` فيبدو التأكيد فاشلاً وهو ناجح (درس مثبَّت مع `let SB`). */
T('  والنقر يفتح المُحرِّر على الطلب نفسه لا على طلب جديد',
  await page.evaluate(() => __prEditId === 'PR-DG2026-0021' && __prEditStatus === 'returned'));
T('  ومحتوى الطلب مُعبّأ (العنوان والبند) فلا يُعاد إدخاله',
  await page.evaluate(() => (document.getElementById('pr-title')?.value || '') === 'طلب 21'
    && /صابون سائل/.test(document.querySelector('#pr-items-body')?.innerHTML || '')));
T('  ولافتة المُحرِّر تقول إنّه تعديل لطلبٍ مُعاد وتُظهر سببه',
  await page.evaluate(() => {
    const b = document.querySelector('.pr-edit-banner.returned');
    return !!b && /أضف عرض سعر ثالث/.test(b.textContent) && /PR-DG2026-0021/.test(b.textContent);
  }));
await shot('2-edit-returned');
T('  وزرّ الإرسال يقول «إعادة الإرسال بعد التعديل»',
  await page.evaluate(() => /إعادة الإرسال بعد التعديل/.test(
    document.querySelector('.pr-form-acts')?.textContent || '')));

/* ═══ ②③④ خانات الطابور بعين مقدّم الطلب ═══ */
await seed('mostafa.kishk', 'مصطفى كشك', { perms: { can_create_pr: true, can_comment: true },
  track: 'PR-DG2026-0024' });
await page.waitForSelector('.pr-work-queue .pr-work-list', { timeout: 15000 });
{
  const g = await groups();
  T('الطابور يفصل «تحت التنفيذ» عن «بانتظار الاستلام والإقفال» بعناوين',
    g.some(x => /مستلمة — تحت التنفيذ/.test(x)) && g.some(x => /بانتظار استلام البضاعة والإقفال/.test(x)), g.join(' | '));
}
await shot('3-buckets-queue');
T('ولوحة الاستلام تفتح أمر الشراء وتشرح أنّ الإقفال تلقائيّ',
  await page.evaluate(() => {
    const c = document.querySelector('.pr-work-receiving');
    return !!c && /P\.O-DG26-3210/.test(c.textContent) && /أُقفل الطلب وأُرشف تلقائياً/.test(c.textContent);
  }));

/* ④ التنبيه والنداء بالاسم */
await page.evaluate(async () => { STATE.prTrackId = 'PR-DG2026-0025'; await renderPRPortal(); });
await page.waitForSelector('.pr-work-reply', { timeout: 15000 });
T('نداء «بانتظار ردّك» يقتبس السؤال ويسمّي سائله',
  await page.evaluate(() => {
    const c = document.querySelector('.pr-work-reply');
    return !!c && /هل الكمية 10 أم 100؟/.test(c.textContent) && /أحمد المشتريات/.test(c.textContent);
  }));
T('  والطلب يحمل شارة «بانتظار ردّك» في الطابور',
  await page.evaluate(() => [...document.querySelectorAll('.pr-work-request')]
    .some(el => /PR-DG2026-0025/.test(el.textContent) && /بانتظار ردّك/.test(el.textContent))));
await page.click('.pr-work-reply button');
await page.waitForSelector('.pr-reply-to', { timeout: 15000 });
await shot('4-reply-quote');
T('  والنقر ينقل لصندوق الردّ وفوقه اقتباس السؤال — «نعرف الرد على ايش»',
  await page.evaluate(() => {
    const q = document.querySelector('.pr-reply-to');
    const box = document.getElementById('pr-msg-input');
    if (!q || !box) return false;
    // الاقتباس **فوق** الصندوق لا تحته
    return /هل الكمية 10 أم 100؟/.test(q.textContent)
      && q.getBoundingClientRect().top < box.getBoundingClientRect().top;
  }));

/* ═══ ② بعين المشتريات: «طلباتي المستلمة» ═══ */
await seed('proc1', 'أحمد المشتريات', { role: 'user',
  perms: { can_create_pr: true, can_comment: true, can_manage_rfq: true }, track: 'PR-DG2026-0022' });
await page.waitForSelector('.pr-work-queue .pr-work-list', { timeout: 15000 });
T('وضع «تحت التنفيذ» في شريط التنقّل بعدّاده',
  await page.evaluate(() => [...document.querySelectorAll('.pr-work-navbtn')]
    .some(b => /تحت التنفيذ/.test(b.textContent) && /2/.test(b.querySelector('.pr-work-navcount')?.textContent || ''))));
await page.click('.pr-work-navbtn:has-text("تحت التنفيذ")');
await page.waitForSelector('.pr-work-queue .pr-work-list', { timeout: 15000 });
T('  ويعرض المستلَمة وحدها (22 و25 لا 23 ولا 24)',
  await page.evaluate(() => {
    const ids = [...document.querySelectorAll('.pr-work-request-id')].map(e => e.textContent.trim());
    return ids.length === 2 && ids.includes('PR-DG2026-0022') && ids.includes('PR-DG2026-0025');
  }));
T('  ومرشّح «طلباتي المستلمة» معروض للمشتريات',
  await page.locator('.pr-work-chip', { hasText: 'طلباتي المستلمة' }).count() === 1);
await page.click('.pr-work-chip:has-text("طلباتي المستلمة")');
await page.waitForSelector('.pr-work-queue .pr-work-list', { timeout: 15000 });
await shot('5-my-claimed');
T('  وتفعيله يُبقي ما ثبّت عليه اسمه بالاستلام',
  await page.evaluate(() => [...document.querySelectorAll('.pr-work-request-id')]
    .map(e => e.textContent.trim()).every(i => ['PR-DG2026-0022', 'PR-DG2026-0025'].includes(i))));

/* ═══ سلامة عامة ═══ */
await page.setViewportSize({ width: 393, height: 852 });
await page.evaluate(async () => { STATE.prWorkspaceMode = 'requests'; STATE.prWorkspaceFilter = 'all';
  await renderPRPortal(); });
const overflow = await page.evaluate(() => {
  /* ⚠️ `overflow-x:clip` يجعل scrollWidth==clientWidth فيقيس نفسه — يُرفع أوّلاً. */
  const prev = document.documentElement.style.overflowX;
  document.documentElement.style.overflowX = 'visible';
  const v = document.documentElement.scrollWidth - document.documentElement.clientWidth;
  document.documentElement.style.overflowX = prev;
  return v;
});
await shot('6-mobile');
T('صفر انزلاق أفقيّ على 393px', overflow <= 0, String(overflow));
T('صفر خطأ صفحة', pageErrors.length === 0, pageErrors.join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.join(' | '));

await browser.close();
console.log('لقطات: ' + SHOTS);
let fail = 0;
for (const [n, ok, d] of results) { if (!ok) fail++; console.log(`${ok ? '✓' : '✗'} ${n}${ok || !d ? '' : ' — ' + d}`); }
console.log(`\n${results.length - fail}/${results.length} ناجح`);
process.exit(fail ? 1 : 0);

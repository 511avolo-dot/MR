/* فحص متصفّح تحت **CSP الإنتاج** لبند ④ من دراسة النظام (2026-11-01):
 *   شارة التأخّر كانت «هل فات موعد التوريد؟» — وهو سؤالٌ يصحّ على **68% من
 *   الطلبات الحيّة** (25 من 37، مقيس على قاعدة الإنتاج) فلا يسمّي فاعلاً ولا
 *   فعلاً. صارت «كم بقي الطلب في مرحلته» بعتبة p90 لكل مرحلة من توزيعها.
 *
 * ⚠️ المحكّ هنا **ما يُرسَم فعلاً**: الحزمة النصّية تقرأ الدوال، وهذا يقرأ
 *    البطاقة في الـDOM — وصناديق العناصر، لا وجود النصّ في الصفحة.
 * ⚠️ والانعكاس الأهمّ مقيسٌ صراحةً: طلبٌ تجاوز موعده بأربعين يوماً وهو داخل
 *    زمن مرحلته **لا يحمل شارة ولا يدخل مجموعة التعثّر** — وهو بعينه ما كان
 *    يُنتج الضجيج.
 *
 * التشغيل: node scripts/csp-preview-server.mjs &  ثمّ  node scripts/e2e/pr-stage-age.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const BASE = process.env.BASE || 'http://127.0.0.1:8812';
const SHOTS = process.env.PR_STAGE_SHOTS || path.join(os.tmpdir(), 'aldeyabi-pr-stage-age');
fs.mkdirSync(SHOTS, { recursive: true });
const results = []; const T = (n, ok, d) => { results.push([n, !!ok, d || '']); };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const pageErrors = [], csp = [];
page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await blockSupabase(page);
await page.goto(`${BASE}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.prWorkspaceHTML === 'function'
  && typeof window.prStageChip === 'function' && typeof window.prQueueGroup === 'function');
await enterApp(page);

/* ستّة طلبات تغطّي: متجاوزاً بشدّة · متجاوزاً قليلاً · داخل الزمن ·
   **فائت الموعد بأربعين يوماً وداخل زمن مرحلته** · بانتظار بضاعة متجاوزاً ·
   بانتظار بضاعة داخل الزمن (20 يوماً — تعثّرٌ لدى المشتريات وليس تعثّراً هنا). */
await page.evaluate(async () => {
  try { hideLoginScreen(); } catch (e) {}
  CLOUD = window.CLOUD = { enabled: true, client: {
    auth: { getSession: async () => ({ data: { session: { access_token: 'jwt' } } }) },
    from: () => ({ select: () => ({ order: () => ({ range: async () => ({ data: [], error: null }) }) }) }),
  } };
  const ago = n => new Date(Date.now() - n * 86400000).toISOString();
  const isoD = n => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);
  const mk = (n, o) => Object.assign({
    id: 'PR-DG2026-' + String(n).padStart(4, '0'), request_no: 'PR-DG2026-' + String(n).padStart(4, '0'),
    title: 'طلب ' + n, requester: 'mostafa.kishk', requester_name: 'مصطفى كشك',
    department_id: 'DEP-OPS', department: 'الصيانة والتشغيل', project: 'أمانة الأحساء',
    approvals: [], approvals_current: [], messages: [], audit: [], attachments: [], po_links: [],
    items: [{ id: 1, description: 'صابون سائل', unit: 'حبة', requested_qty: 10 }],
  }, o);
  STATE.currentUser = { username: 'Mahmoud', displayName: 'محمود العامودي', role: 'user',
    permissions: { can_manage_rfq: true, can_view_amounts: true } };
  STATE.departments = [{ id: 'DEP-OPS', name_ar: 'الصيانة والتشغيل', sector: 'الصيانة والتشغيل', active: true }];
  STATE.purchaseRequests = [
    mk(1, { status: 'approved', workflow_state: 'pricing', proc_status: 'in_progress',
            proc_started_at: ago(40), needed_by: isoD(5) }),                      // متجاوز بشدّة (33 فوق 7)
    mk(2, { status: 'approved', workflow_state: 'pricing', proc_status: 'in_progress',
            proc_started_at: ago(9),  needed_by: isoD(5) }),                      // متجاوز قليلاً (2 فوق 7)
    mk(3, { status: 'approved', workflow_state: 'pricing', proc_status: 'in_progress',
            proc_started_at: ago(3),  needed_by: isoD(5) }),                      // داخل الزمن
    mk(4, { status: 'approved', workflow_state: 'pricing', proc_status: 'in_progress',
            proc_started_at: ago(2),  needed_by: isoD(-40) }),                    // ⚠️ فائت الموعد وداخل زمن مرحلته
    mk(5, { status: 'approved', workflow_state: 'ordered', proc_status: 'po_issued',
            po_links: [{ po_number: 'P.O-DG26-1', linked_at: ago(40), allocations: [] }] }),  // بضاعة متجاوزة
    mk(6, { status: 'approved', workflow_state: 'ordered', proc_status: 'po_issued',
            po_links: [{ po_number: 'P.O-DG26-2', linked_at: ago(20), allocations: [] }] }),  // بضاعة داخل الزمن
  ];
  /* ⚠️ «جميع الطلبات» هي الخانة الوحيدة التي تجمع الأطوار: «قيد العمل» تستثني
     التنفيذ والاستلام بالتصميم (prInWorkQueue)، وطلبات هذا الفحص كلّها فيهما. */
  STATE.prWorkspaceMode = 'all'; STATE.prWorkspaceFilter = 'all'; STATE.prWorkspaceSearch = '';
  STATE.prView = 'list'; STATE.prTrackId = 'PR-DG2026-0001';
  __prLoaded = true;
  navigate('pr');
  await renderPRPortal();
});
await page.waitForSelector('.pr-work-queue .pr-work-request', { timeout: 15000 });

/* ── ما يُرسَم فعلاً: البطاقات بترتيبها، ونصّ شارة كلٍّ ── */
const cards = await page.evaluate(() => Array.from(document.querySelectorAll('.pr-work-request')).map(el => ({
  id: (el.querySelector('.pr-work-request-id') || {}).textContent || '',
  chip: (el.querySelector('.pr-work-due') || {}).textContent || '',
  cls: (el.querySelector('.pr-work-due') || {}).className || '',
})));
const groups = await page.evaluate(() =>
  Array.from(document.querySelectorAll('.pr-work-group span')).map(e => e.textContent.trim()));
const byId = id => cards.find(c => c.id.includes(String(id).padStart(4, '0'))) || {};

T('الطابور يُرسَم بالطلبات الستّة', cards.length === 6, `العدد ${cards.length}`);
T('المتجاوز بشدّة يحمل شارة حمراء تسمّي مرحلته وعمرها',
  /لدى المشتريات/.test(byId(1).chip) && /40/.test(byId(1).chip) && /danger/.test(byId(1).cls),
  byId(1).chip);
T('والمتجاوز قليلاً كهرمانيّ لا أحمر',
  /لدى المشتريات/.test(byId(2).chip) && /warn/.test(byId(2).cls) && !/danger/.test(byId(2).cls),
  byId(2).chip + ' | ' + byId(2).cls);
T('والسائر في زمن مرحلته بلا شارة إطلاقاً', byId(3).chip === '', byId(3).chip);

/* ⚠️ الانعكاس المُبلَّغ عنه: هذا الطلب كان يحمل «تجاوز موعد التوريد بـ40 يوماً»
   ويتصدّر الطابور، وهو لدى المشتريات يومين فقط — أي ضجيجٌ يزاحم العمل الحقيقيّ. */
T('وفائت الموعد بأربعين يوماً وهو داخل زمن مرحلته: بلا شارة (نهاية ضجيج الـ68%)',
  byId(4).chip === '', byId(4).chip);
T('وبانتظار البضاعة 40 يوماً يحمل شارة، و20 يوماً لا (عتبة 28 لا عتبة المشتريات 7)',
  /بانتظار استلام البضاعة/.test(byId(5).chip) && byId(6).chip === '',
  `5:"${byId(5).chip}" 6:"${byId(6).chip}"`);

/* ── الترتيب المرسوم: الأشدّ تجاوزاً أوّلاً داخل مجموعة التعثّر ── */
const flagged = cards.filter(c => c.chip).map(c => c.id.match(/(\d+)$/)[1]);
T('الأشدّ تجاوزاً يتصدّر المرسوم', flagged[0].endsWith('0001'), flagged.join('|'));
T('وعنوان المجموعة يصف المعيار الجديد لا الموعد',
  groups.some(g => /الزمن المعتاد لمرحلته/.test(g)) && !groups.some(g => /موعد التوريد/.test(g)),
  groups.join(' · '));

/* ── الموعد معلومةٌ لم تُفقَد: تفاصيل الطلب ما زالت تحمله وشارته ── */
await page.evaluate(() => prSelectWorkspaceRequest('PR-DG2026-0004'));
await page.waitForTimeout(250);
const detail = await page.evaluate(() => {
  const dl = document.querySelector('.pr-work-meta');
  return dl ? dl.textContent.replace(/\s+/g, ' ') : '';
});
T('وتاريخ الاحتياج وشارته باقيان في تفاصيل الطلب (لم تُفقَد المعلومة)',
  /تاريخ الاحتياج/.test(detail) && /تجاوز موعد التوريد/.test(detail), detail.slice(0, 150));

await page.screenshot({ path: path.join(SHOTS, 'queue-stage-age.png'), fullPage: false });

/* ── سلامة الصفحة ── */
const hscroll = await page.evaluate(() => {
  const prev = document.documentElement.style.overflowX;
  document.documentElement.style.overflowX = 'visible';   // ⚠️ القناع يقيس نفسه
  const v = document.documentElement.scrollWidth - document.documentElement.clientWidth;
  document.documentElement.style.overflowX = prev; return v;
});
T('صفر انزلاق أفقيّ', hscroll <= 0, `${hscroll}px`);
T('صفر خطأ صفحة', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.slice(0, 2).join(' | '));

await browser.close();
const bad = results.filter(r => !r[1]);
for (const [n, ok, d] of results) console.log(`  ${ok ? '✓' : '✗'} ${n}${d && !ok ? '  → ' + d : ''}`);
console.log(`\nعمر المرحلة: ${results.length - bad.length}/${results.length} · اللقطات: ${SHOTS}`);
process.exit(bad.length ? 1 : 0);

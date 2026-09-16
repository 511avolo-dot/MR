/* فحص متصفّح تحت **CSP الإنتاج** لوضوح مساحة طلبات الشراء.
 *
 * يغطّي بلاغ المالك (2026-09-16، ثلاث لقطات):
 *   «تشتيت في ترتيب الطلبات وطريقة عرضهم» · «المراحل بعد اعتمادي تخصّ مصطفى
 *   ومحمود — لماذا مسجّلة لدى عبدالله؟» · «سجلّ القرارات جميعه عبدالله
 *   والقرارات بالإنجليزي وغير متّزنة» · «قائمة منسدلة بأسماء المشاريع».
 *
 * ⚠️ الاتّزان والاختلاط لا يُقاسان بفحص نصّيّ: نقيس **صناديق العناصر المرسومة**
 *    (سطر واحد · بلا فيض أفقيّ · العنوان يمينَ الوقت) في متصفّح حقيقيّ.
 *
 * التشغيل: node scripts/csp-preview-server.mjs &  ثمّ  node scripts/e2e/pr-workspace-clarity.mjs
 */
import { resolveChromiumExecutable } from './chromium-path.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const BASE = process.env.BASE || 'http://127.0.0.1:8812';
const results = []; const T = (n, ok, d) => { results.push([n, !!ok, d || '']); };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const pageErrors = [], csp = [];
page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await page.goto(`${BASE}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.prWorkspaceHTML === 'function'
  && typeof window.prAuditGroups === 'function' && typeof window.prFillProjectSelect === 'function');

/* حالة مصنوعة تحاكي لقطة المالك: معتمد وقيد اعتماد وتسعير مختلطة. */
await page.evaluate(async () => {
  /* ⚠️ بطاقة الدخول تعترض النقر ولو بدا العنصر «مرئيّاً ومُمكَّناً» (درس سابق)،
     و`renderPRPortal` **لاتزامنيّة** فلا بدّ من انتظارها. */
  try { hideLoginScreen(); } catch (e) {}
  /* `renderPRPortal` تفتح ببوّابة `prCloudReady()` — كعبٌ يكفيها، ولا شبكة:
     `__prLoaded=true` يمنع `prLoadAll` من الجلب. */
  CLOUD = window.CLOUD = { enabled: true, client: {
    auth: { getSession: async () => ({ data: { session: { access_token: 'jwt' } } }) },
    from: () => ({ select: () => ({ order: () => ({ range: async () => ({ data: [], error: null }) }) }) }),
  } };
  /* ⚠️ المواعيد محسوبة من **اليوم** لا ثابتة: تاريخٌ مكتوب بيده يصير ماضياً
     بعد أسابيع فينقلب التأكيد صامتاً. */
  const DUE = (d) => { const t = new Date(); t.setDate(t.getDate() + d);
    return `${t.getFullYear()}-${String(t.getMonth()+1).padStart(2,'0')}-${String(t.getDate()).padStart(2,'0')}`; };
  const mk = (n, o) => Object.assign({
    id: 'PR-DG2026-' + String(n).padStart(4, '0'), request_no: 'PR-DG2026-' + String(n).padStart(4, '0'),
    title: 'طلب ' + n, requester: 'mostafa.kishk', requester_name: 'مصطفى كشك',
    department_id: 'DEP-OPS', project: 'أمانة الأحساء', approvals: [], approvals_current: [],
    messages: [], audit: [], attachments: [], po_links: [],
  }, o);
  STATE.currentUser = { username: 'Abdullah', displayName: 'عبدالله الذيابي', role: 'admin', permissions: {} };
  STATE.purchaseRequests = [
    mk(3,  { status: 'approved',  workflow_state: 'pricing', needed_by: DUE(-4) }),
    mk(12, { status: 'in_review', workflow_state: 'maintenance_review', current_seq: 1 }),
    mk(11, { status: 'in_review', workflow_state: 'maintenance_review', current_seq: 1 }),
    mk(10, { status: 'approved',  workflow_state: 'pricing', needed_by: DUE(1) }),
    mk(9,  { status: 'approved',  workflow_state: 'pricing', needed_by: DUE(45) }),
    mk(2,  { status: 'returned',  workflow_state: 'returned' }),
  ];
  STATE.prWorkspaceMode = 'requests'; STATE.prWorkspaceFilter = 'all'; STATE.prWorkspaceSearch = '';
  STATE.prView = 'list'; STATE.prTrackId = 'PR-DG2026-0009';
  __prLoaded = true;
  navigate('pr');
  await renderPRPortal();
});
await page.waitForSelector('.pr-work-queue .pr-work-list', { timeout: 15000 });

// ── ① ترتيب الطابور + عناوين المجموعات ──
const queue = await page.evaluate(() => {
  const list = document.querySelector('.pr-work-queue .pr-work-list');
  return [...list.children].map(el => el.classList.contains('pr-work-group')
    ? { group: el.querySelector('span')?.textContent.trim(), n: el.querySelector('b')?.textContent.trim() }
    : { id: (el.querySelector('.pr-work-request-id')?.textContent || '').trim() });
});
const order = queue.filter(x => x.id).map(x => x.id.slice(-4)).join(',');
/* الهويّة هنا أدمن/مشتريات، فطلبات التسعير المعلّقة **تحتاج إجراءه** فتتصدّر —
   ثمّ المتعثّر ثمّ ما ينتظر غيره. وداخل كل مجموعة الأحدث أوّلاً. */
T('ترتيب الطابور بالإلحاح لا مبعثراً', order === '0010,0009,0003,0002,0012,0011', order);
T('  وعناوين المجموعات تفصل الحالات بعدّادها',
  queue.filter(x => x.group).length === 3
  && queue[0].group === 'يحتاج إجراءك الآن' && queue[0].n === '3'
  && queue.some(x => x.group && /متعثّر/.test(x.group))
  && queue.some(x => x.group && /قيد الاعتماد/.test(x.group))
  && queue.some(x => x.group && /قيد الاعتماد/.test(x.group)),
  JSON.stringify(queue.filter(x => x.group)));

// ── ② سجلّ القرارات: عربيّ · بالاسم الكامل · مدموج · متّزن ──
await page.evaluate(async () => {
  const pr = STATE.purchaseRequests.find(p => p.id === 'PR-DG2026-0009');
  pr.approvals = pr.approvals_current = [
    { seq: 1, approver: 'm.elsobky', approver_name: 'م.محمد السبكي', decision: 'approved', acted_at: '2026-09-16T11:09:33Z', stage_label: 'اعتماد الحاجة' },
    { seq: 2, approver: 'Abdullah', approver_name: 'عبدالله الذيابي', decision: 'approved', acted_at: '2026-09-16T12:16:41Z', stage_label: 'إذن بدء التسعير' },
  ];
  pr.audit = [
    { event: 'submitted', actor: 'mostafa.kishk', actor_name: 'مصطفى كشك', created_at: '2026-09-16T09:28:05Z' },
    { event: 'attachment_added', actor: 'mostafa.kishk', actor_name: 'مصطفى كشك', created_at: '2026-09-16T09:28:08Z', detail: { file_name: 'عميل.pdf' } },
    { event: 'stage_approved', actor: 'm.elsobky', actor_name: 'م.محمد السبكي', created_at: '2026-09-16T11:09:33Z', detail: { stage_label: 'اعتماد الحاجة' } },
    { event: 'stage_approved', actor: 'Abdullah', actor_name: 'عبدالله الذيابي', created_at: '2026-09-16T12:16:41Z', detail: { stage_label: 'إذن بدء التسعير' } },
    { event: 'approved', actor: 'Abdullah', actor_name: 'عبدالله الذيابي', created_at: '2026-09-16T12:16:41Z' },
    { event: 'proc_in_progress', actor: 'Abdullah', actor_name: 'عبدالله الذيابي', created_at: '2026-09-16T12:16:41Z' },
    /* ⚠️ حدث **غير معروف للخريطة** — هو المسار الذي سرّب الإنجليزية أصلاً
       (كل الأحداث الحقيقية كانت تسقط للبديل). يُدمَج مع دفقة 12:16 نفسها. */
    { event: 'some_future_event', actor: 'Abdullah', actor_name: 'عبدالله الذيابي', created_at: '2026-09-16T12:16:41Z' },
  ];
  STATE.prView = 'track'; STATE.prDetailTab = 'approvals';
  await renderPRPortal();
});
await page.waitForSelector('[data-pr-audit] .pr-work-event', { timeout: 15000 });
const audit = await page.evaluate(() => {
  const box = document.querySelector('[data-pr-audit]');
  const rows = box ? [...box.querySelectorAll('.pr-work-event')] : [];
  return rows.map(r => {
    const b = r.querySelector('.pr-work-eventrow b'), t = r.querySelector('.pr-work-eventrow time');
    const nm = r.querySelector('small');
    const bb = b ? b.getBoundingClientRect() : null, tb = t ? t.getBoundingClientRect() : null;
    return { label: b ? b.textContent.trim() : '', time: t ? t.textContent.trim() : '',
             name: nm ? nm.textContent.trim() : '',
             // RTL: العنوان يمينَ الوقت — نقارن مركزَي الصندوقين
             rightOfTime: bb && tb ? (bb.left + bb.width / 2) > (tb.left + tb.width / 2) : false,
             lines: b ? new Set([...b.getClientRects()].map(x => Math.round(x.top))).size : 0 };
  });
});
T('سجلّ القرارات بلا أي مفتاح إنجليزيّ',
  audit.length > 0 && audit.every(r => r.label && !/[A-Za-z]/.test(r.label)),
  audit.map(r => r.label).join(' | '));
T('  والأحداث المتزامنة لفاعل واحد سطرٌ واحد (كانت ثلاثة)',
  audit.length === 4 && /·/.test(audit[0].label), String(audit.length));
T('  وبالاسم الكامل لا اسم الدخول',
  audit.every(r => !/^[a-z.]+$/i.test(r.name)) && audit.some(r => r.name === 'عبدالله الذيابي')
  && audit.some(r => r.name === 'م.محمد السبكي'), audit.map(r => r.name).join(' | '));
T('  والوقت في عمود مستقلّ يمين… أي يسارَ العنوان في RTL (اتّزان)',
  audit.every(r => r.rightOfTime && r.lines === 1));

// ── ③ مسار المراحل: «التسعير» لفريق المشتريات حتى يبدأ أحدٌ فعلاً ──
const flowBefore = await page.evaluate(async () => {
  STATE.prDetailTab = 'overview'; await renderPRPortal();
  const n = document.querySelectorAll('.prw-node')[3];
  return n ? n.querySelector('.prw-who').textContent.trim() : '';
});
T('مرحلة التسعير تُنسَب لفريق المشتريات قبل أن يبدأ أحد',
  flowBefore === 'فريق المشتريات', flowBefore);
const flowAfter = await page.evaluate(async () => {
  const pr = STATE.purchaseRequests.find(p => p.id === 'PR-DG2026-0009');
  pr.proc_started_by = 'm.elsobky'; pr.proc_started_at = '2026-09-16T13:00:00Z';
  await renderPRPortal();
  const n = document.querySelectorAll('.prw-node')[3];
  return n ? n.querySelector('.prw-who').textContent.trim() : '';
});
T('  وبعد بدء العمل تُنسَب لمن بدأه **باسمه الكامل**',
  flowAfter === 'م.محمد السبكي', flowAfter);

// ── ④ مُنتقي المشروع من السجلّ المعتمد ──
const proj = await page.evaluate(async () => {
  PRJ.list = [
    { id: 'p1', name: 'أمانة الأحساء', aliases: [], active: true },
    { id: 'p2', name: 'برج الابتكار', aliases: [], active: true },
  ];
  PRJ.loaded = true;
  await prGoView('create');
  const sel = document.getElementById('pr-project');
  const opts = sel ? [...sel.options].map(o => o.value) : [];
  let hintNew = '', shown = false;
  if (sel) {
    sel.value = '__new__'; prProjectSelChanged();
    const nw = document.getElementById('pr-project-new');
    shown = !!nw && nw.style.display !== 'none';
    nw.value = 'برج الابتكارر'; prProjectNewTyping();
    hintNew = (document.getElementById('pr-project-hint') || {}).textContent || '';
  }
  return { tag: sel ? sel.tagName : '', opts, shown, hintNew };
});
T('حقل المشروع مُنتقٍ يعرض المشاريع المسجّلة',
  proj.tag === 'SELECT' && proj.opts.includes('أمانة الأحساء') && proj.opts.includes('برج الابتكار')
  && proj.opts.includes('__new__'), JSON.stringify(proj.opts));
T('  و«مشروع جديد» يفتح حقل الاسم ويُنبّه على المشابه قبل إنشاء مكرّر',
  proj.shown && /مشابه|القائم/.test(proj.hintNew), proj.hintNew);

// ── ⑤ سلامة العرض ──
const overflow = await page.evaluate(() => {
  document.documentElement.style.overflowX = 'visible';   // القناع يقيس نفسه
  const w = document.documentElement.scrollWidth - document.documentElement.clientWidth;
  document.documentElement.style.overflowX = '';
  return w;
});
T('صفر فيض أفقيّ على سطح المكتب', overflow <= 0, String(overflow));

await page.setViewportSize({ width: 393, height: 852 });
await page.evaluate(async () => { STATE.prView = 'list'; await renderPRPortal(); });
const mob = await page.evaluate(() => {
  document.documentElement.style.overflowX = 'visible';
  const w = document.documentElement.scrollWidth - document.documentElement.clientWidth;
  document.documentElement.style.overflowX = '';
  const g = document.querySelector('.pr-work-group');
  return { w, group: !!g };
});
T('وصفر فيض على الجوال مع بقاء عناوين المجموعات', mob.w <= 0 && mob.group, String(mob.w));
// ── ⑤ موعد التوريد: شارة مرسومة فعلاً + مجموعة + ترتيب بالاستحقاق ──
/* ⚠️ الهويّة تتبدّل إلى **مقدّم الطلب**: عند المشتريات تكون طلبات التسعير
   «تحتاج إجراءك» فتتصدّر قبل مجموعة الموعد — وهو الصواب، لكنّه يُخفي ما نقيسه. */
await page.setViewportSize({ width: 1440, height: 950 });
await page.evaluate(async () => {
  /* ⚠️ `#app-root` يبدأ مخفيّاً وشاشةُ الدخول فوقه، فكل `getBoundingClientRect`
     يُرجع صفراً ويبدو العنصر غير مرسوم وهو مرسوم. وإظهارُ التطبيق كان يحدث
     بمسار مصادقة لاتزامنيّ — أي **سباق**: القياس ينجح أحياناً ويسقط أحياناً.
     يُحسم صراحةً هنا (نفس ما يفعله scoped-staff-screens). */
  try { hideLoginScreen(); } catch (_) {}
  STATE.currentUser = { username: 'mostafa.kishk', displayName: 'مصطفى كشك', role: 'user',
    permissions: { can_create_pr: true }, scopeSectors: ['الصيانة والتشغيل'] };
  STATE.prView = 'list'; await renderPRPortal();
});
await page.waitForFunction(() => {
  const all = [...document.querySelectorAll('.pr-work-queue .pr-work-due')];
  return all.length > 0 && all.every((c) => { const r = c.getBoundingClientRect();
    return r.width > 0 && r.height > 0; });
}, { timeout: 8000 });
/* ⚠️ القياس بعد **استقرار التخطيط**: تبديل المقاس ثمّ القراءة فوراً يُرجع
   صناديق صفريّة (قِيس: النصّ صحيح والصندوق 0×0)، فيبدو العنصر غير مرسوم وهو
   مرسوم. ننتظر أوّل صندوق غير صفريّ بدل مهلة ثابتة. */

const dueUI = await page.evaluate(() => {
  const list = document.querySelector('.pr-work-queue .pr-work-list');
  const rows = [...list.children].map(el => el.classList.contains('pr-work-group')
    ? { group: el.querySelector('span')?.textContent.trim() }
    : { id: (el.querySelector('.pr-work-request-id')?.textContent || '').trim(),
        due: (el.querySelector('.pr-work-due')?.textContent || '').trim(),
        box: (() => { const c = el.querySelector('.pr-work-due'); if (!c) return 0;
          const r = c.getBoundingClientRect(); return Math.round(r.width * r.height); })() });
  return { rows, groups: rows.filter(r => r.group).map(r => r.group) };
});
const dueRows = dueUI.rows.filter(r => r.id);
T('مجموعة موعد التوريد تظهر في الطابور',
  dueUI.groups.some(g => /موعد التوريد/.test(g)), JSON.stringify(dueUI.groups));
/* صندوقٌ غير صفريّ = **مرسومة فعلاً**، لا موجودة في الترميز وحده. */
T('  وشارة الموعد مرسومة بصندوق غير صفريّ',
  dueRows.filter(r => r.box > 0).length === 2, JSON.stringify(dueRows.map(r => [r.id.slice(-4), r.box])));
T('  ونصّها يفرّق بين ما فات وما يستحقّ غداً',
  dueRows.some(r => /تجاوز موعد التوريد/.test(r.due)) && dueRows.some(r => /غداً/.test(r.due)),
  JSON.stringify(dueRows.map(r => r.due).filter(Boolean)));
/* 0003 فات موعده و0010 يستحقّ غداً — ورقم 0010 أكبر، فالفرز بالرقم كان سيقلبهما. */
T('  وما فات موعده يسبق ما يستحقّ غداً رغم أنّ رقمه أصغر',
  dueRows.findIndex(r => r.id.endsWith('0003')) < dueRows.findIndex(r => r.id.endsWith('0010')),
  dueRows.map(r => r.id.slice(-4)).join(','));
T('  والبعيد (45 يوماً) بلا شارة',
  (dueRows.find(r => r.id.endsWith('0009')) || {}).box === 0);

T('صفر خطأ صفحة', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.slice(0, 2).join(' | '));

await browser.close();
let bad = 0;
for (const [n, ok, d] of results) { console.log(`${ok ? '  ✓' : '  ✗'} ${n}${ok || !d ? '' : '  — ' + d}`); if (!ok) bad++; }
console.log(`\nالنتيجة: ${results.length - bad} ناجح · ${bad} فاشل`);
process.exit(bad ? 1 : 0);

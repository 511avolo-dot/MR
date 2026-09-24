/* فحص متصفّح تحت **CSP الإنتاج**: محضر طلب الشراء ونسخة المورّد يخرجان في
 * **صفحة واحدة شاملة كل شيء**.
 *
 * بلاغ المالك (2026-09-22، بلقطة): «عند طباعة محضر طلب الشراء التواقيع
 * والمعلومات غالباً تُطبع في صفحة ثانية وهذا خطأ **حتى في البنود الصغيرة**».
 *
 * ⚠️ الحقيقة الأرض هنا **عدّ صفحات PDF فعليّ** لا تقدير ارتفاع:
 *   (أ) معاينة الشاشة حاويتها `flex-direction:column`، فمستندٌ أطول من
 *       `min-height` كان **يتقلّص** ويفيض محتواه — فارتفاعه المقروء كاذب
 *       (مقيس: 2271px تُقرأ 1058px). أُصلِح بـ`flex-shrink:0`، ومع ذلك لا
 *       نبني التأكيد على ارتفاعٍ بل على ما يخرج من محرّك الطباعة.
 *   (ب) لذلك نبني **نفس HTML الذي يبنيه `executePrint`** (أنماط الصفحة +
 *       `@page{size:A4;margin:0}`) ونُخرجه PDF ونعُدّ صفحاته.
 *   (ج) والعدد يُقابَل بـ`ceil(الارتفاع/الصفحة)` فيتحقّق كلٌّ من الآخر — عدّادٌ
 *       بتعبير نمطيّ وحده قد يكذب بصمت.
 *
 * ⚠️ وصفحة الـPDF تُقطَع عنها كل شبكة خارجية: خطوط المستند مضمَّنة data-URI،
 *   فتحميل خطٍّ خارجيّ (أو فشله) يغيّر المقاسات بين بيئة التطوير والعدّاء —
 *   وهو بالضبط صنف التقلّب الذي عالجه `app-boot.mjs`.
 *
 * التشغيل: node scripts/csp-preview-server.mjs &  ثمّ  node scripts/e2e/pr-print-one-page.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const BASE = process.env.BASE || 'http://127.0.0.1:8812';
const OUT = path.join(os.tmpdir(), 'aldeyabi-pr-print-one-page');
fs.mkdirSync(OUT, { recursive: true });
const results = []; const T = (n, ok, d) => { results.push([n, !!ok, d || '']); };

/* ── حالات القياس: من ثلاثة بنود (لبّ البلاغ) إلى أربعين (الحدّ الصادق) ── */
const CASES = [
  { id: 'PR-P3',  n: 3,  onePage: true  },
  { id: 'PR-P5',  n: 5,  onePage: true  },
  { id: 'PR-P17', n: 17, onePage: true  },   // حجم طلب المالك في اللقطة
  { id: 'PR-P30', n: 30, onePage: true  },
  { id: 'PR-P40', n: 40, onePage: false }    // ما دون الحدّ الأدنى: ورقتان بصدق
];

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const pageErrors = [], csp = [];
page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await blockSupabase(page);   // انظر app-boot.mjs — لا فحص يلمس الإنتاج
await page.goto(`${BASE}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.prPrint === 'function'
  && typeof window.prPrintSupplier === 'function' && typeof window.printFitOnePage === 'function');
await enterApp(page);

const FIT_MIN = await page.evaluate(() => PRINT_FIT_MIN);
T('PRINT_FIT_MIN حدّ أدنى مُعلَن بين 0.5 و1', FIT_MIN > 0.5 && FIT_MIN < 1, `القيمة ${FIT_MIN}`);

await page.evaluate((cases) => {
  STATE.currentUser = { username: 'qa.admin', displayName: 'مدير المشتريات', role: 'admin',
                        permissions: { can_view_amounts: true }, prProfileKey: 'module_admin' };
  STATE.purchaseRequests = cases.map(c => ({
    id: c.id, title: `طلب بـ${c.n} بنداً`, department_id: 'DEP-MAINT',
    department: 'إدارة الصيانة والتشغيل', project: 'مشروع المقر الرئيسي',
    requester: 'ops.employee', requester_name: 'خالد العتيبي', requester_mobile: '0501234567',
    priority: 'عالي', needed_by: '2026-09-30', sector: 'الصيانة والتشغيل',
    justification: 'احتياج تشغيليّ لاستمرار الخدمة في الموقع.',
    status: 'in_review', workflow_state: 'procurement_review', current_seq: 2, revision: 1,
    request_date: '2026-09-10', created_at: '2026-09-10T08:00:00Z',
    items: Array.from({ length: c.n }, (_, i) => ({
      id: `${c.id}-${i}`, seq: i + 1, description: `صنف تجريبي رقم ${i + 1} باسم متوسّط الطول`,
      unit: 'حبة', requested_qty: (i % 7) + 1, unit_price: 25 + i })),
    approvals: [
      { seq: 1, revision: 1, stage_key: 'maintenance_need',
        stage_label: 'اعتماد الحاجة — مدير الصيانة والتشغيل', approver: 'maint.manager',
        approver_name: 'م. فهد القحطاني', decision: 'approved',
        acted_at: '2026-09-11T09:10:00Z', comment: 'الحاجة معتمدة' },
      { seq: 2, revision: 1, stage_key: 'procurement_pricing',
        stage_label: 'إذن بدء التسعير — مدير المشتريات', approver: 'qa.admin',
        approver_name: 'مدير المشتريات', decision: 'pending' }
    ],
    approvals_current: null, po_links: []
  }));
}, CASES);

/* صفحة منفصلة للـPDF، مقطوعة عن كل شبكة خارجية (انظر الترويسة). */
const pdfPage = await browser.newPage();
await pdfPage.route('**/*', r => {
  const u = r.request().url();
  return /^(data:|about:|blob:)/.test(u) ? r.continue() : r.abort();
});

/** يبني نفس HTML إطار الطباعة الذي يبنيه `executePrint` من معاينة مفتوحة. */
const printHtml = () => page.evaluate(() => {
  const styles = Array.from(document.styleSheets).map(sheet => {
    try { return Array.from(sheet.cssRules).map(r => r.cssText).join('\n'); } catch (e) { return ''; }
  }).join('\n');
  return `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><style>
${styles}
body{margin:0;padding:0;background:white;font-family:'NeoSansArabic','Segoe UI',Tahoma,sans-serif}
.print-document{display:block !important;width:auto;max-width:none;margin:0;padding:18mm 16mm;box-shadow:none;page-break-after:always}
.print-document:last-child{page-break-after:auto}
@page{size:A4;margin:0}
@media print { body{margin:0} .print-document{padding:18mm 16mm} }
</style></head><body>${document.getElementById('pp-content').innerHTML}</body></html>`;
});

async function render(kind, c) {
  await page.evaluate(() => { try { closePrintPreview(); } catch (e) {} });
  await page.evaluate(([k, id]) => (k === 'sup' ? prPrintSupplier(id) : prPrint(id)), [kind, c.id]);
  await page.waitForSelector('#pp-content .print-table');
  const scale = await page.evaluate(() =>
    Number(document.querySelector('#pp-content .print-document').style.zoom || 1));
  const html = await printHtml();
  await pdfPage.setContent(html, { waitUntil: 'load' });
  const buf = await pdfPage.pdf({ format: 'A4', printBackground: true,
                                  margin: { top: 0, right: 0, bottom: 0, left: 0 } });
  fs.writeFileSync(path.join(OUT, `${kind}-${c.id}.pdf`), buf);
  const pdfPages = (buf.toString('latin1').match(/\/Type\s*\/Page[^s]/g) || []).length;
  const geom = await pdfPage.evaluate(() => {
    const d = document.querySelector('.print-document');
    const probe = document.createElement('div');
    probe.style.cssText = 'position:absolute;visibility:hidden;height:100mm;width:0';
    document.body.appendChild(probe);
    const mm = probe.getBoundingClientRect().height / 100; probe.remove();
    const box = d.getBoundingClientRect();
    const bottom = (sel) => { const e = d.querySelector(sel); return e ? e.getBoundingClientRect().bottom - box.top : null; };
    return { h: box.height, page: 297 * mm,
             sign: bottom('.print-signatures'), foot: bottom('.print-footer'),
             chain: !!d.querySelector('.print-table') };
  });
  return { scale, pdfPages, ...geom };
}

for (const kind of ['rec', 'sup']) {
  const label = kind === 'rec' ? 'المحضر' : 'نسخة المورّد';
  for (const c of CASES) {
    const r = await render(kind, c);
    const expected = Math.max(1, Math.ceil(r.h / r.page - 0.001));
    T(`${label} · ${c.n} بنداً · عدّ صفحات PDF يطابق الارتفاع المقيس`,
      r.pdfPages === expected, `PDF ${r.pdfPages} · المتوقَّع من الارتفاع ${expected} (${Math.round(r.h)}px/${Math.round(r.page)}px)`);
    if (c.onePage) {
      T(`${label} · ${c.n} بنداً · صفحة واحدة`, r.pdfPages === 1,
        `صفحات ${r.pdfPages} · ارتفاع ${Math.round(r.h)}px من ${Math.round(r.page)}px · مقياس ${r.scale}`);
      /* «شاملة كل شيء»: التواقيع والتذييل داخل الصفحة الأولى لا بعدها */
      T(`${label} · ${c.n} بنداً · التواقيع والتذييل داخل الصفحة الأولى`,
        r.sign !== null && r.foot !== null && r.foot <= r.page,
        `أسفل التواقيع ${r.sign && Math.round(r.sign)}px · أسفل التذييل ${r.foot && Math.round(r.foot)}px`);
    }
    /* الحدّ الأدنى مُعلَن ولا يُتجاوَز إلى اللاقراءة مهما طال المستند */
    T(`${label} · ${c.n} بنداً · المقياس لا يهبط دون الحدّ الأدنى`,
      r.scale >= FIT_MIN - 1e-9 && r.scale <= 1, `المقياس ${r.scale}`);
    /* ولا يضيع شيء من المستند عند التصغير */
    T(`${label} · ${c.n} بنداً · المستند كامل (جداوله قائمة)`, r.chain, '');
  }
}

/* التواقيع محميّة من التيتّم حتى في المستند الذي لا يسع صفحة واحدة */
{
  const r = await render('rec', CASES[CASES.length - 1]);
  const orphan = await pdfPage.evaluate(() => {
    const d = document.querySelector('.print-document');
    const s = getComputedStyle(d.querySelector('.print-signatures'));
    return { avoid: `${s.breakInside} ${s.pageBreakInside}`, count: d.querySelectorAll('.print-sign').length };
  });
  T('المستند الطويل: كتلة التواقيع لا تنقسم عبر الصفحات',
    /avoid/.test(orphan.avoid) && orphan.count >= 2, `${orphan.avoid} · تواقيع ${orphan.count}`);
}

/* ── صفر انحدار: مطبوعةٌ لم تطلب الملاءمة لا تُضغَط ولا تُصغَّر ────────── */
{
  const plain = await page.evaluate(() => {
    const el = document.createElement('div');
    el.innerHTML = buildPrintDoc({}, { title: 'اختبار' }, '<p>محتوى</p>');
    const d = el.firstElementChild;
    const fit = document.createElement('div');
    fit.innerHTML = buildPrintDoc({}, { title: 'اختبار', fitPage: true }, '<p>محتوى</p>');
    const f = fit.firstElementChild;
    return { plainCls: d.className, plainAttr: d.getAttribute('data-fit-page'),
             fitCls: f.className, fitAttr: f.getAttribute('data-fit-page') };
  });
  T('مطبوعة بلا fitPage: بلا صنف الضغط وبلا وسم الملاءمة',
    !/print-tight/.test(plain.plainCls) && plain.plainAttr === null, JSON.stringify(plain));
  T('مطبوعة بـfitPage: تحمل صنف الضغط ووسم الملاءمة',
    /print-tight/.test(plain.fitCls) && plain.fitAttr === '1', JSON.stringify(plain));
}

T('صفر خطأ صفحة', pageErrors.length === 0, pageErrors.join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.join(' | '));

await browser.close();
let bad = 0;
for (const [n, ok, d] of results) { if (!ok) bad++; console.log(`${ok ? '✓' : '✗'} ${n}${d ? ` — ${d}` : ''}`); }
console.log(`\n${results.length - bad}/${results.length} فحصاً · الملفّات: ${OUT}`);
process.exit(bad ? 1 : 0);

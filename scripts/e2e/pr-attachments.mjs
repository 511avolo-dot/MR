/* فحص متصفّح تحت **CSP الإنتاج** لمسار مرفقات طلب الشراء.
 *
 * ⚠️ لماذا المتصفّح لا الحزمة وحدها: العطل المُبلَّغ عنه (2026-09-16،
 *    «تعذّر فتح المستند: تعذّر جلب الملف (HTTP 400)») وقع في تركيب ثلاث طبقات
 *    لا تظهر في صندوق Node — توجيه المفتاح، ثمّ ذاكرة العارض، ثمّ رسم pdf.js
 *    تحت `connect-src 'self'`. وسابقة مثبَّتة: خادم بلا ترويسات الإنتاج أخفى
 *    عيب `blob:` حتى وصل المستخدم.
 *
 * التشغيل: node scripts/csp-preview-server.mjs &  ثمّ  node scripts/e2e/pr-attachments.mjs
 */
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const BASE = process.env.BASE || 'http://127.0.0.1:8812';
const KEY_PDF = 'docs/pr/PR-DG2026-0006/7dad81c9-35cf-415e-aaaa-c797b2ddf895.pdf';
const KEY_IMG = 'docs/pr/PR-DG2026-0006/bbbbbbbb-2222.png';

/* PDF صغير صالح (صفحة واحدة) — يُبنى بلا مكتبة كي لا نضيف اعتمادية. */
function tinyPdf() {
  const objs = [
    '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj',
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj',
    '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R>>endobj',
    '4 0 obj<</Length 44>>stream\nBT /F1 12 Tf 20 100 Td (MR test) Tj ET\nendstream endobj',
  ];
  let out = '%PDF-1.4\n'; const off = [];
  for (const o of objs) { off.push(out.length); out += o + '\n'; }
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`
    + off.map(o => String(o).padStart(10, '0') + ' 00000 n \n').join('')
    + `trailer<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n${xref}\n%%EOF`;
  return Buffer.from(out, 'latin1');
}
/* PNG 1×1 صالح */
const tinyPng = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64');

const results = []; const T = (name, ok) => { results.push([name, !!ok]); };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const pageErrors = [], cspViolations = [], regDocHits = [], prDocHits = [];
page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (/Content Security Policy/i.test(m.text())) cspViolations.push(m.text()); });

/* الشبكة: نقطة مرفقات الطلب تعمل · ونقطة وثائق الموردين ترتدّ 400 كما في
   الإنتاج — فأي تسرّب إليها يظهر عطلاً لا نجاحاً صامتاً. */
await page.route('**/api/pr-doc*', route => {
  const key = new URL(route.request().url()).searchParams.get('key') || '';
  prDocHits.push(key);
  const isPng = key.endsWith('.png');
  route.fulfill({
    status: 200,
    contentType: isPng ? 'image/png' : 'application/pdf',
    body: isPng ? tinyPng : tinyPdf(),
  });
});
await page.route('**/api/reg-doc*', route => {
  regDocHits.push(new URL(route.request().url()).searchParams.get('key') || '');
  route.fulfill({ status: 400, contentType: 'application/json', body: '{"error":"مفتاح غير صالح"}' });
});

await blockSupabase(page);   // انظر app-boot.mjs — لا فحص يلمس الإنتاج
await page.goto(`${BASE}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.docvOpen === 'function' && typeof window.prViewAttachment === 'function');
await enterApp(page);   // إقلاع حتميّ — انظر app-boot.mjs

/* هويّة وحالة: طلب واحد بمرفقين ورسالة تشير لأحدهما. */
await page.evaluate(() => {
  CLOUD = window.CLOUD = { enabled: true, client: {
    auth: { getSession: async () => ({ data: { session: { access_token: 'jwt-test' } } }) },
  } };
  STATE.currentUser = { username: 'field1', displayName: 'موظّف', role: 'user',
    permissions: { can_upload_docs: true, can_comment: true, can_create_pr: true },
    scopeSectors: ['الصيانة والتشغيل'] };
  STATE.purchaseRequests = [{
    id: 'PR-DG2026-0006', request_no: 'PR-DG2026-0006', status: 'in_review',
    requester: 'field1', department_id: 'DEP-OPS', project: 'مشروع',
    attachments: [
      { id: 11, object_key: 'docs/pr/PR-DG2026-0006/7dad81c9-35cf-415e-aaaa-c797b2ddf895.pdf',
        file_name: 'CP-23392265 18082026.pdf', kind: 'support', uploaded_by: 'field1' },
      { id: 12, object_key: 'docs/pr/PR-DG2026-0006/bbbbbbbb-2222.png',
        file_name: 'صورة الموقع.png', kind: 'other', uploaded_by: 'proc1' },
    ],
    messages: [{ id: 1, kind: 'question', body: 'أين الموقع؟', author: 'proc1',
                 author_name: 'المشتريات', created_at: '2026-09-16T08:00:00Z', attachment_ids: [12] }],
  }];
});

// ── ① لوحة المرفقات تسرد الاثنين وفيها حقل إضافة ──
const panel = await page.evaluate(() =>
  prWorkspaceAttachmentsHTML(STATE.purchaseRequests[0]));
T('اللوحة تسرد المرفقين معاً', /CP-23392265/.test(panel) && /صورة الموقع/.test(panel));
T('وفيها حقل إضافة مرفقات متعدّد بعد إنشاء الطلب',
  /type="file"/.test(panel) && /multiple/.test(panel) && /prAddAttachments/.test(panel));
T('والمرفق المُشار إليه في رسالة يُوسَم «مرفق مناقشة»', /مرفق مناقشة/.test(panel));

// ── ② الخيط يعرض رقاقة مرفق الرسالة ──
const thread = await page.evaluate(() => prThreadHTML(STATE.purchaseRequests[0]));
T('خيط المناقشة يعرض رقاقة مرفق الرسالة',
  /📎 صورة الموقع\.png/.test(thread) && /prViewAttachment\('PR-DG2026-0006','docs\/pr\//.test(thread));
T('وفيه حقل إرفاق مع الرسالة', /id="pr-msg-doc"/.test(thread) && /multiple/.test(thread));

// ── ③ فتح المرفق PDF فعليّاً: المسار كاملاً حتى رسم pdf.js ──
await page.evaluate(k => window.prViewAttachment('PR-DG2026-0006', k, 'مرفق'), KEY_PDF);
await page.waitForFunction(() => {
  const s = document.getElementById('docv-stage');
  return s && (s.querySelector('canvas') || /تعذّر/.test(s.textContent));
}, { timeout: 25000 });
const pdfState = await page.evaluate(() => {
  const s = document.getElementById('docv-stage');
  return { canvas: !!s.querySelector('canvas'), iframes: s.querySelectorAll('iframe').length,
           err: /تعذّر/.test(s.textContent) ? s.textContent.trim().slice(0, 120) : '' };
});
T('المرفق PDF يُرسَم فعلاً على canvas بلا خطأ', pdfState.canvas && !pdfState.err);
T('  ولا إطار مضمّن (iOS لا يرسم PDF داخله)', pdfState.iframes === 0);
T('  والطلب ذهب إلى /api/pr-doc ولم يمسّ نقطة وثائق الموردين إطلاقاً',
  prDocHits.includes(KEY_PDF) && regDocHits.length === 0);

// ── ④ التبويب الثاني (صورة) يُجلَب كسولاً من النقطة نفسها ──
await page.evaluate(() => window.docvStep(1));
await page.waitForFunction(() => {
  const s = document.getElementById('docv-stage');
  return s && (s.querySelector('img') || /تعذّر/.test(s.textContent));
}, { timeout: 15000 });
const imgState = await page.evaluate(() => {
  const s = document.getElementById('docv-stage');
  const img = s.querySelector('img');
  return { has: !!img, blob: !!img && String(img.src).startsWith('blob:'),
           err: /تعذّر/.test(s.textContent) ? s.textContent.trim().slice(0, 120) : '' };
});
T('التبويب الثاني (صورة) يُعرَض من blob محلّي', imgState.has && imgState.blob && !imgState.err);
T('  وجُلِب من /api/pr-doc كذلك (صفر تسرّب لنقطة الموردين)',
  prDocHits.includes(KEY_IMG) && regDocHits.length === 0);

// ── ⑤ عدد التبويبات = عدد مرفقات الطلب ──
const tabs = await page.evaluate(() => document.getElementById('docv-counter')?.textContent || '');
T('العارض فتح كل مرفقات الطلب لا المنقور وحده', /2\s*\/\s*2/.test(tabs.replace(/‏/g, '')));

await page.evaluate(() => window.docvClose());

// ── ⑥ سلامة الصفحة ──
T('صفر خطأ صفحة', pageErrors.length === 0);
T('صفر انتهاك CSP (الترويسة تبقى مشدّدة)', cspViolations.length === 0);

await browser.close();
let bad = 0;
for (const [n, ok] of results) { console.log(`${ok ? '  ✓' : '  ✗'} ${n}`); if (!ok) bad++; }
if (pageErrors.length) console.log('أخطاء الصفحة:', pageErrors.slice(0, 3));
if (cspViolations.length) console.log('انتهاكات CSP:', cspViolations.slice(0, 3));
console.log(`\nالنتيجة: ${results.length - bad} ناجح · ${bad} فاشل`);
process.exit(bad ? 1 : 0);

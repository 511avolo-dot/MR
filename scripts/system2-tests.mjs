#!/usr/bin/env node
/**
 * حزمة تأكيدات النظام 2 — نظام المشتريات الأساسي (index.html)
 * ------------------------------------------------------------------
 * لا اعتماديات. تُشغَّل: node scripts/system2-tests.mjs
 *
 * لماذا: index.html ملف واحد بلا سكربت بناء، وكان بلا أي تغطية آلية —
 * كل CI في المستودع يخدم البوابة (النظام 3). هذه الحزمة شبكة الأمان
 * للمنطق الحسابي والعرضي الذي تعتمد عليه المشتريات يومياً.
 *
 * كيف: نستخرج كتل <script> من index.html، ونحمّل الدوال الخالصة في
 * صندوق بكعوب DOM بسيطة، ثم نستجوب سلوكها فعلياً (لا نطابق نصوصاً).
 *
 * عند إضافة منطق حسابي أو عمود مطبوعة جديد: أضِف تأكيداً هنا.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HTML = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

/* ── عدّاد التأكيدات ─────────────────────────────────────────── */
let pass = 0, fail = 0, group = '';
const G = (name) => { group = name; console.log('\n' + name); };
const T = (name, cond, detail) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (detail ? '  → ' + detail : '')); }
};

/* ── 1) سلامة بنيوية ─────────────────────────────────────────── */
const scripts = [...HTML.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
const JS = scripts.join('\n');
// نسخة بلا تعليقات: الفحوص البنيوية تفحص الشيفرة المنفَّذة لا الشروح
const CODE = JS.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/[^\n]*/g, '$1');

G('١) سلامة بنيوية');
T('يوجد كتلة سكربت واحدة على الأقل', scripts.length > 0);

// أسماء الدوال المكرّرة: في جافاسكربت التعريف الأخير يطغى صامتاً على ما قبله.
// هذا ما جعل ثلاث دوال حفظ بيانات تعمل بسلوك مختلف عن المقصود (push بدل unshift، وابتلاع الأخطاء).
const defs = [...CODE.matchAll(/^\s*(?:async\s+)?function\s+([A-Za-z0-9_$]+)\s*\(/gm)].map(m => m[1]);
const seen = new Map();
defs.forEach(n => seen.set(n, (seen.get(n) || 0) + 1));
const dups = [...seen.entries()].filter(([, c]) => c > 1);
T('لا أسماء دوال مكرّرة (التعريف الأخير يطغى صامتاً)', dups.length === 0,
  dups.map(([n, c]) => `${n}×${c}`).join('، '));

// انحدار مؤكَّد سابقاً: DATA مُعرَّف بـconst فلا يوجد على window؛ قراءته هكذا تُرجع undefined
// فيُحسب أساس دمج البذور صفراً وتختفي السجلات المحلية غير المرفوعة.
T('لا قراءة للبذور عبر window.DATA (تُرجع undefined دائماً)', !/window\.DATA/.test(CODE));

/* ── 2) تحميل الدوال الخالصة في صندوق ─────────────────────────── */
function grab(name) {
  const lines = JS.split('\n');
  const i = lines.findIndex(l => l.startsWith(`function ${name}(`) || l.startsWith(`async function ${name}(`));
  if (i < 0) throw new Error('دالة غير موجودة: ' + name);
  const head = lines[i];
  if (head.trim().endsWith('}') && (head.split('{').length === head.split('}').length)) return head;
  for (let j = i + 1; j < lines.length; j++) if (lines[j] === '}') return lines.slice(i, j + 1).join('\n');
  throw new Error('تعذّر تحديد نهاية الدالة: ' + name);
}
function grabConst(name) {
  const lines = JS.split('\n');
  const i = lines.findIndex(l => l.startsWith(`const ${name} `) || l.startsWith(`const ${name}=`));
  if (i < 0) throw new Error('ثابت غير موجود: ' + name);
  if (lines[i].includes(';') && lines[i].split('{').length === lines[i].split('}').length
      && lines[i].split('[').length === lines[i].split(']').length) return lines[i];
  for (let j = i + 1; j < lines.length; j++) if (lines[j] === '};' || lines[j] === '];') return lines.slice(i, j + 1).join('\n');
  throw new Error('تعذّر تحديد نهاية الثابت: ' + name);
}

const NEEDED_FNS = [
  'poSeqParse', 'poSeriesKey', 'poNumCompare', 'poNumCell', 'poSeqSummary', 'poNextNumber',
  'poProjectList', 'poProjectCell', 'poProjectText', 'poIsPartial', 'poIsCancelled', 'poCancelInfo',
  'poPartialInfo', 'poReceivedSum', 'poDays', 'poDelayCell', 'poStatusBadgeClass',
  'poNormalizeStatus', 'poStatusStep', 'poParseDate', 'poToISO', 'poFmtDate',
  'recomputePOderived', 'poFilteredList', 'poFind',
  'buildPOListReport', 'buildPOOverdueReport', 'buildPOFinanceReport', 'printUrgentMemo',
  'buildPOCycleReport', 'poPrintDashboard', 'poStateSnapshot', 'poHealthScore',
  'poStageStats', 'poFmtDuration', 'poCurrentStageAge', 'poProjectStats', 'printPO',
  'poPriceRef', 'poPriceRefPrefix', 'poItemIndex', 'poMatchItem', 'poPriceEligible',
  'poSyncPriceHistory', 'recomputeItemStats', 'siNormalize', 'poMatchLine',
];
// متغيّرات وحدة قابلة للتغيّر تحتاجها الدوال (ذاكرة فهرس الأصناف)
const NEEDED_LETS = ['__poItemIdx'];
function grabLet(name){
  const lines = JS.split('\n');
  const i = lines.findIndex(l => l.startsWith(`let ${name} `) || l.startsWith(`let ${name}=`) || l.startsWith(`let ${name},`));
  if (i < 0) throw new Error('متغيّر غير موجود: ' + name);
  return lines[i];
}
const NEEDED_CONSTS = ['SI_SYNONYM_MAP', 'PO_PRICE_REF', 'PO_ENUMS', 'PO_STATUS_META', 'PO_BOARD_ORDER', 'PO_STEPPER', 'PO_TERMINAL', 'PO_STATUS_ALIAS', 'PO_SEGMENTS'];

const stubs = `
const escapeHtml = s => String(s==null?'':s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const escapeAttr = escapeHtml;
const fmtPrice = n => n==null||isNaN(n) ? '—' : Number(n).toLocaleString('en-US',{maximumFractionDigits:2});
const tafqitSAR = () => 'صفر ريال لا غير';
const STATE = { purchaseOrders:[], suppliers:[], items:[], history:[],
  currentUser:{username:'t',displayName:'مختبِر',role:'admin'},
  poSegment:'all', poFilter:{q:'',sector:'',status:'',priority:'',project:''},
  poSort:{col:'po_number',dir:'desc'}, poPage:1, perPage:25 };
function hasPermission(){ return true; }
function requirePermission(){ return true; }
function toast(){}
function logAudit(){}
function reportError(){}
function updateCounts(){}
function renderPurchaseOrders(){}
function renderPOTable(){}
function poSave(po){ recomputePOderived(po); }
function poStageTimeline(){ return []; }
function poSupplierRating(){ return null; }
function poUpsertLocal(){}
function poCloudUpsert(){}
function saveUserEntry(){}
function deleteUserEntry(){}
function todayStr(){ return new Date().toISOString().slice(0,10); }
const localStorage = { getItem:()=>null, setItem(){}, removeItem(){} };
const window = {};
let __captured = null;
async function printDocOpen(opts, body){ __captured = {opts, body}; }
const document = {
  getElementById: () => ({ classList:{contains:()=>false, add(){}, remove(){}, toggle(){}}, value:'', innerHTML:'',
                           style:{}, focus(){}, setAttribute(){}, querySelectorAll:()=>[], onclick:null }),
  querySelectorAll: () => [], body:{ classList:{add(){},remove(){},contains:()=>false} },
};
`;

const body = [stubs, ...NEEDED_LETS.map(grabLet), ...NEEDED_CONSTS.map(grabConst), ...NEEDED_FNS.map(grab)].join('\n\n');
const exportLine = `; return {${[...NEEDED_FNS, ...NEEDED_CONSTS].join(',')}, STATE, get captured(){return __captured;}};`;
let M;
try {
  M = new Function(body + exportLine)();
} catch (e) {
  console.log('\n✗ تعذّر تحميل الدوال في الصندوق: ' + e.message);
  process.exit(1);
}
const api = M;
const { STATE } = api;

const mkPO = (o) => Object.assign({
  po_number: 'P.O-DG26-3200', issue_date: '2026-08-01', supplier: 'مورد', project: 'مشروع أ',
  sector: 'النقليات', subtotal: 1000, status: 'قيد التوريد', expected_delivery: '2026-12-01',
  actual_delivery: null, priority: 'متوسط', items: [], receipts: [], status_history: [],
}, o);
const seed = (list) => { STATE.purchaseOrders = list.map(mkPO); STATE.purchaseOrders.forEach(api.recomputePOderived); };

/* ── 3) الحساب المشتقّ ───────────────────────────────────────── */
G('٢) الحساب المشتقّ (recomputePOderived)');
{
  const po = mkPO({ items: [{ desc: 'أ', qty: 4, price: 250 }], subtotal: 0 });
  api.recomputePOderived(po);
  T('الإجمالي يُجمع من البنود', po.subtotal === 1000, String(po.subtotal));
  T('ضريبة 15٪ بدقّة منزلتين', po.vat === 150, String(po.vat));
  T('الإجمالي شامل الضريبة', po.total === 1150, String(po.total));

  const late = mkPO({ expected_delivery: '2026-08-01', status: 'قيد التوريد' });
  api.recomputePOderived(late);
  T('التأخير يُحتسب للأمر النشط المتجاوز موعده', late.days_delayed > 0);

  const done = mkPO({ status: 'تسليم كامل', expected_delivery: '2026-08-01', actual_delivery: '2026-08-01' });
  api.recomputePOderived(done);
  T('المُسلَّم في موعده بلا تأخير', done.days_delayed === 0);

  const cancelled = mkPO({ status: 'ملغى', expected_delivery: '2020-01-01' });
  api.recomputePOderived(cancelled);
  T('الملغى لا يُحسب متأخراً', cancelled.days_delayed === 0);

  const alias = mkPO({ status: 'معتمد' });
  api.recomputePOderived(alias);
  T('الحالات القديمة تُوحَّد (معتمد ← اعتماد مدير الشراء)', alias.status === 'اعتماد مدير الشراء', alias.status);
}

/* ── 4) تسلسل الأرقام ────────────────────────────────────────── */
G('٣) تسلسل أرقام أوامر الشراء');
{
  const p = api.poSeqParse('P.O-DG26-3209');
  T('يفصل البادئة عن الرقم التسلسلي', p && p.prefix === 'P.O-DG26-' && p.seq === 3209 && p.pad === 4);
  T('لا تخدعه سنة داخل البادئة', api.poSeqParse('P.O-DG2026-3101').seq === 3101);
  T('رقم بلا تسلسل يُرجع null', api.poSeqParse('ABC') === null);
  T('صيغتا السنة سلسلة واحدة', api.poSeriesKey('P.O-DG2026-') === api.poSeriesKey('P.O-DG26-'));
  T('فرز رقمي لا نصّي (9 قبل 10)', api.poNumCompare('P.O-DG26-9', 'P.O-DG26-10') < 0);
  const sorted = ['P.O-DG26-3211','P.O-DG2026-3101','P.O-DG26-3204','P.O-DG2026-3199'].sort(api.poNumCompare);
  T('الترتيب متّصل عبر الصيغتين',
    sorted.join(' ') === 'P.O-DG2026-3101 P.O-DG2026-3199 P.O-DG26-3204 P.O-DG26-3211', sorted.join(' '));

  seed([{po_number:'P.O-DG2026-3101'},{po_number:'P.O-DG2026-3102'},{po_number:'P.O-DG26-3104'}]);
  const sum = api.poSeqSummary(STATE.purchaseOrders);
  T('السلسلة واحدة رغم اختلاف الصيغة', sum.length === 1, JSON.stringify(sum.map(s=>s.key)));
  T('النطاق من الأدنى للأعلى', sum[0].min === 3101 && sum[0].max === 3104);
  T('الفجوة تُرصد بدقّة', JSON.stringify(sum[0].missing) === JSON.stringify([3103]), JSON.stringify(sum[0].missing));
  T('الرقم التالي يواصل بادئة أعلى رقم', api.poNextNumber() === 'P.O-DG26-3105', api.poNextNumber());
  STATE.purchaseOrders = [];
  T('سجل فارغ يعود للصيغة الافتراضية', /^P\.O-DG\d{4}-1001$/.test(api.poNextNumber()));

  const cell = api.poNumCell('P.O-DG26-3209');
  T('العرض يفصل البادئة عن التسلسل', cell.includes('class="pfx"') && cell.includes('class="seq">3209'));
}

/* ── 5) حالات الصفّ والجهة ───────────────────────────────────── */
G('٤) حالات الصفّ وجهة المشروع');
{
  T('الجهة الفارغة تُبرَز لا تُخفى', api.poProjectCell({project:''}).includes('po-noproject'));
  T('نصّ المستندات لا يختفي عند الغياب', api.poProjectText({project:''}) === 'غير محدّدة');
  T('الجهة تُشذَّب', api.poProjectText({project:'  مطار تبوك '}) === 'مطار تبوك');
  T('تهريب HTML في خلية الجهة', api.poProjectCell({project:'<b>x</b>'}).includes('&lt;b&gt;'));

  seed([{po_number:'P.O-DG26-1',project:'أ'},{po_number:'P.O-DG26-2',project:''},{po_number:'P.O-DG26-3',project:'أ'}]);
  T('قائمة الجهات بلا تكرار ولا فراغ', JSON.stringify(api.poProjectList()) === JSON.stringify(['أ']));
  STATE.poFilter.project = '__none__';
  T('مرشّح «بلا جهة» يعزل الناقص', api.poFilteredList().length === 1);
  STATE.poFilter.project = 'أ';
  T('مرشّح الجهة يُرجع أوامرها', api.poFilteredList().length === 2);
  STATE.poFilter.project = '';

  const partial = mkPO({ status:'تسليم جزئي', items:[{desc:'أ',qty:10,price:100,received_qty:7}] });
  const pi = api.poPartialInfo(partial);
  T('التسليم الجزئي يحسب المستلَم والمتبقّي', pi.received === 7 && pi.ordered === 10 && pi.remaining === 3);
  T('نسبة التقدّم صحيحة', pi.pct === 70, String(pi.pct));
  T('poIsPartial يميّز الجزئي', api.poIsPartial(partial) && !api.poIsPartial(mkPO({})));

  const cancelled = mkPO({ status:'ملغى', status_history:[{from:'قيد التوريد',to:'ملغى',by:'ع',at:'2026-08-20T00:00:00Z',note:'اعتذر المورد'}] });
  const ci = api.poCancelInfo(cancelled);
  T('سبب الإلغاء يُستخرج من الخط الزمني', ci && ci.reason === 'اعتذر المورد' && ci.by === 'ع');
  T('خلية التأخير للملغى لا تدّعي التزاماً', !api.poDelayCell(cancelled).includes('في الموعد'));
  const deliveredLate = mkPO({ status:'تسليم كامل', expected_delivery:'2026-08-01', actual_delivery:'2026-08-08' });
  api.recomputePOderived(deliveredLate);
  T('المُسلَّم متأخراً بصيغة الماضي', api.poDelayCell(deliveredLate).includes('سُلّم متأخراً'));
}

/* ── 6) صيغة الأيام العربية ──────────────────────────────────── */
G('٥) صيغة الأيام العربية');
{
  T('مفرد', api.poDays(1) === 'يوم واحد');
  T('مثنّى', api.poDays(2) === 'يومان');
  T('جمع قلّة (3–10)', api.poDays(7) === '7 أيام');
  T('تمييز (11+)', api.poDays(11) === '11 يوماً');
}

/* ── 7) هندسة جداول المطبوعات ───────────────────────────────── */
G('٦) هندسة جداول المطبوعات');
{
  // عرض الخلايا مع احتساب colspan — يمنع انزياح الأعمدة عند إضافة عمود جديد
  const cellW = html => [...html.matchAll(/<t[dh](?![a-z])[^>]*>/g)]
    .map(c => { const m = /colspan="(\d+)"/.exec(c); return m ? Number(m[1]) : 1; })
    .reduce((a, b) => a + b, 0);

  const checkTables = (label, html) => {
    const tables = html.match(/<table class="print-table">[\s\S]*?<\/table>/g) || [];
    T(`${label}: يوجد جدول`, tables.length > 0);
    tables.forEach((tb, i) => {
      const cols = cellW((tb.match(/<thead>[\s\S]*?<\/thead>/) || [''])[0]);
      const rows = ((tb.match(/<tbody>([\s\S]*?)<\/tbody>/) || ['',''])[1].match(/<tr[^>]*>[\s\S]*?<\/tr>/g) || []);
      let ok = true, why = '';
      rows.forEach(r => { const w = cellW(r); if (w !== cols) { ok = false; why = `صف بعرض ${w} مقابل ${cols}`; } });
      T(`${label}: جدول ${i + 1} — كل صف يطابق ${cols} أعمدة`, ok, why);
      const foot = (tb.match(/<tfoot>[\s\S]*?<\/tfoot>/) || [''])[0];
      if (foot) T(`${label}: جدول ${i + 1} — التذييل بعرض ${cols}`, cellW(foot) === cols, 'عرض=' + cellW(foot));
    });
  };

  seed([
    {po_number:'P.O-DG26-3201', status:'قيد التوريد', expected_delivery:'2026-08-01', project:'مطار الرياض', items:[{desc:'أ',qty:2,price:500}]},
    {po_number:'P.O-DG26-3202', status:'تسليم للإدارة المالية', project:'', payment_method:'تحويل بنكي'},
    {po_number:'P.O-DG26-3204', status:'تسليم كامل', actual_delivery:'2026-08-05', project:'جمرك جدة'},
  ]);

  const reports = [
    ['سجل الأوامر', () => api.buildPOListReport({})],
    ['المتأخرات', () => api.buildPOOverdueReport()],
    ['لدى المالية', () => api.buildPOFinanceReport()],
    ['مذكرة الاستعجال', () => api.printUrgentMemo()],
    ['زمن الدورة', () => api.buildPOCycleReport()],
    ['لوحة التحكم', () => api.poPrintDashboard()],
  ];
  for (const [label, run] of reports) {
    await run();
    const cap = api.captured;
    T(`${label}: يذكر الجهة مع كل أمر`, /المشروع \/ الجهة|الجهة \/ المشروع/.test(cap.body));
    checkTables(label, cap.body);
  }

  await api.buildPOListReport({});
  T('سجل الأوامر: الترتيب تنازلي بالتسلسل', (() => {
    const seqs = [...api.captured.body.matchAll(/class="seq">(\d+)</g)].map(m => +m[1]);
    return JSON.stringify(seqs) === JSON.stringify([...seqs].sort((a, b) => b - a));
  })());
  T('سجل الأوامر: يحمل بيان تسلسل الأرقام', api.captured.body.includes('تسلسل الأرقام'));
  await api.buildPOListReport({ project: '__none__' });
  T('تصفية التقرير بـ«بلا جهة» تعمل', api.captured.body.includes('3202') && !api.captured.body.includes('3201'));

  api.printPO('P.O-DG26-3201');
  await new Promise(r => setTimeout(r, 0));
  T('أمر الشراء المطبوع: الجهة في العنوان الفرعي', api.captured.opts.subtitle.includes('مطار الرياض'));
  T('أمر الشراء المطبوع: كتلة الجهة البارزة', api.captured.body.includes('print-party-proj'));
  api.printPO('P.O-DG26-3202');
  await new Promise(r => setTimeout(r, 0));
  T('أمر بلا جهة يطبع «غير محدّدة» لا فراغاً', api.captured.body.includes('غير محدّدة'));
}

/* ── 8) تجميع الجهات ────────────────────────────────────────── */
G('٧) تجميع الجهات (يغذّي التقرير الذكي)');
{
  seed([
    {po_number:'P.O-DG26-1', project:'أ', subtotal:1000, status:'قيد التوريد', expected_delivery:'2026-08-01'},
    {po_number:'P.O-DG26-2', project:'أ', subtotal:2000},
    {po_number:'P.O-DG26-3', project:'',  subtotal:500},
    {po_number:'P.O-DG26-4', project:'ب', subtotal:100, status:'ملغى'},
  ]);
  const st = api.poProjectStats();
  T('الملغى مستبعد من التجميع', !st.some(x => x.project === 'ب'));
  T('التجميع بالجهة صحيح', st.find(x => x.project === 'أ').count === 2);
  T('مرتّب تنازلياً بالقيمة', st[0].value >= st[st.length - 1].value);
  T('اللقطة تعدّ الأوامر بلا جهة', api.poStateSnapshot().no_project === 1);
}

/* ── 9) حلقة السعر ──────────────────────────────────────────── */
G('٨) حلقة السعر (أمر الشراء ← السجل السعري)');
{
  STATE.items = [
    { code:'IT-1', name:'أنابيب PVC 50 مم', category:'أدوات صحية', unit:'حبة' },
    { code:'IT-2', name:'كيبل نحاس 3×2.5', category:'كهرباء', unit:'متر' },
  ];
  STATE.history = [];

  T('المطابقة التامة بعد التطبيع', api.poMatchItem('أنابيب PVC 50 مم')?.code === 'IT-1');
  T('المطابقة رغم اختلاف ترتيب الكلمات', api.poMatchItem('PVC 50 مم أنابيب')?.code === 'IT-1');
  T('لا تخمين لبند غير موجود', api.poMatchItem('صنف لا وجود له إطلاقاً') === null);
  T('سبب التعذّر يُميَّز: غير موجود', api.poMatchLine('صنف لا وجود له إطلاقاً').reason === 'none');
  // اسم يخصّ صنفين — الكتالوج الحقيقي فيه 15 حالة كهذه، والتخمين ينسب السعر لصنف خاطئ
  STATE.items.push({ code:'IT-3', name:'أنابيب PVC 50 مم', category:'أخرى', unit:'حبة' });
  T('الاسم الملتبس لا يُطابَق تخميناً', api.poMatchItem('أنابيب PVC 50 مم') === null);
  T('سبب التعذّر يُميَّز: التباس', api.poMatchLine('أنابيب PVC 50 مم').reason === 'ambiguous');
  STATE.items.pop();
  T('زوال الالتباس يعيد المطابقة', api.poMatchItem('أنابيب PVC 50 مم')?.code === 'IT-1');

  const draft = mkPO({ po_number:'P.O-DG26-9001', status:'قيد المراجعة', supplier:'مورد أ', issue_date:'2026-08-10',
    items:[{desc:'أنابيب PVC 50 مم', qty:10, price:120}] });
  T('الأمر قبل الاعتماد غير مؤهَّل', api.poPriceEligible(draft) === false);
  let r = api.poSyncPriceHistory(draft);
  T('لا يُسجَّل سعر من أمر غير معتمد', r.added === 0 && STATE.history.length === 0);

  const po = mkPO({ po_number:'P.O-DG26-9001', status:'اعتماد مدير الشراء', supplier:'مورد أ', issue_date:'2026-08-10',
    items:[ {desc:'أنابيب PVC 50 مم', qty:10, price:120},
            {desc:'كيبل نحاس 3×2.5',  qty:5,  price:40},
            {desc:'صنف خارج الكتالوج', qty:2, price:99},
            {desc:'أنابيب PVC 50 مم', qty:1, price:0} ] });
  r = api.poSyncPriceHistory(po);
  T('البنود المطابَقة تُسجَّل', r.added === 2, JSON.stringify(r));
  T('البند بلا مطابقة يُعَدّ ولا يُخمَّن', r.unmatched === 1);
  T('البند بسعر صفر لا يُسجَّل', STATE.history.length === 2);
  T('المرجع يحمل رقم الأمر وترتيب البند',
    STATE.history.some(h => h.reference === 'PO:P.O-DG26-9001#0'));
  T('السجل يحمل المورد والتاريخ من الأمر',
    STATE.history.every(h => h.supplier === 'مورد أ' && h.date === '2026-08-10'));
  T('السجل مربوط بكود الصنف', STATE.history.every(h => h.code === 'IT-1' || h.code === 'IT-2'));

  api.recomputeItemStats();
  T('سعر الصنف تحدَّث من الأمر', STATE.items.find(i=>i.code==='IT-1').last_price === 120);

  r = api.poSyncPriceHistory(po);
  T('إعادة الحفظ لا تُكرّر السجلات', r.added === 0 && r.updated === 0 && STATE.history.length === 2);

  po.items[0].price = 135;
  r = api.poSyncPriceHistory(po);
  T('تعديل سعر البند يُحدِّث السجل نفسه', r.updated === 1 && STATE.history.length === 2);
  api.recomputeItemStats();
  T('سعر الصنف يتبع التعديل', STATE.items.find(i=>i.code==='IT-1').last_price === 135);

  po.items.splice(1, 1);
  r = api.poSyncPriceHistory(po);
  T('حذف بند يسحب سجله', r.removed === 1 && STATE.history.length === 1);

  po.status = 'ملغى';
  r = api.poSyncPriceHistory(po);
  T('إلغاء الأمر يسحب كل أسعاره', r.removed === 1 && STATE.history.length === 0);
  api.recomputeItemStats();
  T('سعر الصنف يعود فارغاً بعد السحب', STATE.items.find(i=>i.code==='IT-1').last_price === null);

  // لا يمسّ السجلات اليدوية
  STATE.history = [{ num:1, code:'IT-1', name:'أنابيب PVC 50 مم', price:99, supplier:'يدوي', date:'2026-01-01', reference:'عرض سعر', _user:true }];
  po.status = 'اعتماد مدير الشراء'; po.items = [{desc:'أنابيب PVC 50 مم', qty:1, price:120}];
  api.poSyncPriceHistory(po);
  T('السجلات اليدوية لا تُمَسّ', STATE.history.some(h => h.reference === 'عرض سعر'));
  po.status = 'ملغى';
  api.poSyncPriceHistory(po);
  T('السحب لا يطال إلا سجلات هذا الأمر', STATE.history.length === 1 && STATE.history[0].reference === 'عرض سعر');
}

/* ── النتيجة ─────────────────────────────────────────────────── */
console.log(`\n${'─'.repeat(52)}`);
console.log(`النتيجة: ${pass} ناجح · ${fail} فاشل`);
process.exit(fail ? 1 : 0);

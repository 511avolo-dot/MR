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

// أصل ضخم مضمَّن أكثر من مرّة = بايتات تُنزَّل مكرّرة في كل فتح للصفحة.
// سابقة مقيسة: شعار الشركة كان مضمَّناً مرّتين (221KB × 2 = 8.3% من الملف).
const b64s = [...HTML.matchAll(/base64,([A-Za-z0-9+/=]{5000,})/g)].map(m => m[1]);
const b64seen = new Map();
b64s.forEach(x => b64seen.set(x, (b64seen.get(x) || 0) + 1));
const b64dups = [...b64seen.entries()].filter(([, c]) => c > 1);
T('لا أصل base64 ضخم مضمَّن أكثر من مرّة', b64dups.length === 0,
  b64dups.map(([x, c]) => `${Math.round(x.length / 1024)}KB×${c}`).join('، '));

/* ── حوكمة ووصولية (فحوص بنيوية) ──────────────────────────────── */
// كل مفتاح صلاحية معرَّف يجب أن يُنفَّذ فعلاً، وكل مفتاح مُنفَّذ يجب أن يكون معرَّفاً.
// مفتاح بلا إنفاذ = وعد حوكميّ لا يحرس شيئاً؛ ومفتاح بلا تعريف = بوّابة لا يستطيع
// المدير منحها أو سحبها من لوحة الصلاحيات.
const permCat  = [...JS.matchAll(/\{\s*key:\s*'(can_[a-z0-9_]+)'/g)].map(m => m[1]);
const permUsed = new Set([...JS.matchAll(/(?:hasPermission|requirePermission)\(\s*'(can_[a-z0-9_]+)'/g)].map(m => m[1]));
const permAttr = new Set([...HTML.matchAll(/data-requires-perm="(can_[a-z0-9_]+)"/g)].map(m => m[1]));
const permAll  = new Set([...permUsed, ...permAttr]);
const permSet  = new Set(permCat);
T('لا مفتاح صلاحية معرَّف بلا إنفاذ', [...permSet].every(k => permAll.has(k)),
  [...permSet].filter(k => !permAll.has(k)).join('، '));
T('لا بوّابة تستعمل مفتاحاً غير معرَّف في الكتالوج', [...permAll].every(k => permSet.has(k)),
  [...permAll].filter(k => !permSet.has(k)).join('، '));
T('لا مفتاح مكرّر في كتالوج الصلاحيات', permCat.length === permSet.size,
  permCat.filter((k, i) => permCat.indexOf(k) !== i).join('، '));

// ممرّ الوصولية يجب أن يبقى مربوطاً: الشاشات تُرسَم بـinnerHTML فتفقد السمات،
// فإزالة أيّ من نقاط الربط تُعيد الحقول والنوافذ بلا اسم مقروء بصمت.
T('ممرّ الوصولية مربوط بالإقلاع والتنقّل وفتح النوافذ',
  (CODE.match(/a11yWire\(/g) || []).length >= 4);

// مدخلا القائمة الجانبية المُخفيان بقرار المالك (منهجية التسمية · طلبات الشراء):
// الإخفاء بالـCSS على الرابط وحده — الصفحتان تبقيان، وبطاقة لوحة المهام
// تظلّ تفتح صفحة الطلبات. إعادة إظهارهما بالخطأ يُفشِل البناء.
T('مدخلا «منهجية التسمية» و«طلبات الشراء» مُخفيان من القائمة الجانبية',
  /\.nav-item\[data-page="reference"\][\s\S]{0,80}\.nav-item\[data-page="pr"\]\s*\{[^}]*display\s*:\s*none/.test(HTML));
T('صفحة طلبات الشراء تبقى قابلة للوصول من لوحة المهام',
  CODE.includes("navigate('pr')") && HTML.includes('id="page-pr"'));

// ── بيانات وملفات الموردين تبقى في النظام (قرار المالك 2026-09-06) ──
// (أ) لا مسار يحذف صفوف طلبات التسجيل: حذف الصفّ ييتّم وثائقه في المخزن
//     ويقطع رابط بطاقة المورد ببيانات تسجيله.
T('لا مسار يحذف صفوف طلبات تسجيل الموردين',
  !/from\(REG_TABLE\)\s*\.\s*delete\(/.test(CODE) && !CODE.includes('archiveAndClean'),
  (CODE.match(/from\(REG_TABLE\)\s*\.\s*delete\(/g) || []).join('، '));
// (ب) لا مسار يحذف وثيقة تسجيل من المخزن.
T('لا مسار يحذف وثائق التسجيل من المخزن',
  !/from\(REG_BUCKET\)\s*\.\s*remove\(/.test(CODE));
// (ج) الوثائق تُفتح داخل النظام: لا رابط تخزين يُفتح في تبويب متصفّح خارجي.
//     العارض يبني blob محلّياً — أي عودة إلى target="_blank" على signedUrl تُفشِل البناء.
T('وثائق التسجيل لا تُفتح في تبويب خارجي على رابط التخزين',
  !/signedUrl[\s\S]{0,200}target="_blank"/.test(CODE));
T('عارض المستندات داخل النظام موجود ومربوط بنقطتَي الدخول',
  CODE.includes('function docvOpen(') && CODE.includes('function docvShow(') &&
  CODE.includes('docvFromReg(') && CODE.includes('docvFromSupplier(') &&
  HTML.includes('id="modal-doc-viewer"'));
// (د) العارض يعتمد blob محلّي داخل <iframe> — وسياسة CSP في _headers تسمح به
//     وتمنع <object>/<embed> (object-src 'none')، فلا يُستبدَل بهما.
T('العارض يستعمل blob محلّياً لا رابطاً خارجياً',
  /createObjectURL/.test(CODE) && /docv-stage[\s\S]{0,4000}<iframe/.test(CODE));
T('العارض لا يستعمل object/embed اللذين تمنعهما CSP',
  !/docvShow[\s\S]{0,2500}<(object|embed)\b/.test(CODE));
// (هـ) النافذة يجب أن تكون خارج أي <section class="page">: القسم غير النشط
//      display:none فيُخفي كل ما بداخله حتى العناصر position:fixed — وقد أُصيب
//      العارض بذلك فعلاً فلم يفتح من بطاقة المورد (صفحة الموردين).
{
  const dv = HTML.indexOf('id="modal-doc-viewer"');
  const secBefore = HTML.lastIndexOf('<section class="page"', dv);
  const secEnd = secBefore < 0 ? -1 : HTML.indexOf('</section>', secBefore);
  T('نافذة العارض خارج أقسام الصفحات (وإلا لم تفتح إلا من صفحتها)',
    dv > 0 && (secBefore < 0 || (secEnd > 0 && secEnd < dv)));
}

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
  'repList', 'repFilterProjects', 'repDescList',
  'poFollowDelivery', 'poFollowReceived', 'buildPOFollowupReport',
  'rtIndexOf', 'rtApply',
  'buildPOListReport', 'buildPOOverdueReport', 'buildPOFinanceReport', 'printUrgentMemo',
  'buildPOCycleReport', 'poPrintDashboard', 'poStateSnapshot', 'poHealthScore',
  'poStageStats', 'poFmtDuration', 'poCurrentStageAge', 'poProjectStats', 'printPO',
  'poPriceRef', 'poPriceRefPrefix', 'poItemIndex', 'poMatchItem', 'poPriceEligible',
  'poSyncPriceHistory', 'recomputeItemStats', 'siNormalize', 'poMatchLine',
  // سجل المشاريع المعتمد
  'prjNorm', 'prjClean', 'prjBigrams', 'prjDice', 'prjLev', 'prjDigits', 'prjSim', 'prjActive', 'prjById', 'prjNames',
  'prjNewId', 'prjIndex', 'prjInvalidate', 'prjResolve', 'prjCanonical',
  'prjPersistLocal', 'prjPersistCloud', 'prjPersist', 'prjSeedFromOrders',
  'prjAdd', 'prjAddAlias', 'prjRemoveAlias', 'prjRename', 'prjRewriteOrders', 'prjSetActive',
  'prjOrderCount', 'prjStats', 'prjDelete', 'prjPendingUnify', 'prjApplyUnify', 'prjMergeProjects',
  'prjDuplicatePairs', 'prjAutoUnify', 'poImportResolveProjects',
];
// متغيّرات وحدة قابلة للتغيّر تحتاجها الدوال (ذاكرة فهرس الأصناف + فهرس المشاريع)
const NEEDED_LETS = ['__poItemIdx', '_prjIdx'];
function grabLet(name){
  const lines = JS.split('\n');
  const i = lines.findIndex(l => l.startsWith(`let ${name} `) || l.startsWith(`let ${name}=`) || l.startsWith(`let ${name},`));
  if (i < 0) throw new Error('متغيّر غير موجود: ' + name);
  return lines[i];
}
const NEEDED_CONSTS = ['SI_SYNONYM_MAP', 'PO_PRICE_REF', 'PO_ENUMS', 'PO_STATUS_META', 'PO_BOARD_ORDER', 'PO_STEPPER', 'PO_TERMINAL', 'PO_STATUS_ALIAS', 'PO_SEGMENTS',
  'PRJ_SETTINGS_KEY', 'PRJ_LOCAL_KEY', 'PRJ', 'PRJ_STOPWORDS', 'PRJ_SIM_STRONG', 'PRJ_SIM_WEAK',
  'RT_MAP'];

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

/* ── سجل المشاريع المعتمد ────────────────────────────────────── */
{
  G('٩) سجل المشاريع المعتمد — توحيد كتابات الجهة');
  const PRJ = api.PRJ;
  const reset = (list) => { PRJ.list = list || []; api.prjInvalidate(); };

  // التطبيع: الكتابات المختلفة للمشروع نفسه تنهار إلى مفتاح واحد
  T('التطبيع يوحّد الهمزة والتاء المربوطة وأداة التعريف',
    api.prjNorm('المحكمة الإدارية') === api.prjNorm('محكمه الاداريه'));
  T('التطبيع يُسقط الرموز والمسافات الزائدة',
    api.prjNorm('  برج-الشمال  ') === api.prjNorm('برج الشمال'));
  T('التطبيع يوحّد الأرقام الهندية', api.prjNorm('مستودع ٣') === api.prjNorm('مستودع 3'));
  T('كلمة «مشروع» العامّة لا تصنع مشروعاً آخر',
    api.prjNorm('مشروع برج الشمال') === api.prjNorm('برج الشمال'));
  T('مشروعان مختلفان لا ينهاران لمفتاح واحد',
    api.prjNorm('برج الشمال') !== api.prjNorm('برج الجنوب'));

  // قياس التشابه: يلتقط الخطأ الإملائي دون خلط المشاريع المتمايزة
  T('الخطأ الإملائي بحرف واحد تشابهه قويّ',
    api.prjSim('المحكمة الإدارية', 'المحكمة الادارة') >= api.PRJ_SIM_STRONG);
  T('مشروعان مختلفان تشابههما دون العتبة',
    api.prjSim('مستودع الرياض', 'مستودع جدة') < api.PRJ_SIM_STRONG);

  // الحلّ: قاطع (اسم/مرادف/تطبيع) مقابل اقتراح لا يُطبَّق تلقائياً
  reset([{ id:'P1', name:'المحكمة الإدارية', aliases:['محكمة إدارية بالرياض'], active:true }]);
  T('الاسم المعتمد يُحلّ قطعاً', api.prjResolve('المحكمة الإدارية').method === 'exact');
  T('الكتابة المختلفة تُحلّ قطعاً بعد التطبيع',
    api.prjResolve('محكمه الاداريه').status === 'ok');
  T('المرادف يُحلّ قطعاً', api.prjResolve('محكمة إدارية بالرياض').status === 'ok');
  const sug = api.prjResolve('المحكمة الادارة');
  T('الخطأ الإملائي اقتراح لا مطابقة', sug.status === 'suggest' && sug.project.id === 'P1');
  T('الاقتراح لا يُطبَّق تلقائياً (prjCanonical لا يخمّن)', api.prjCanonical('المحكمة الادارة') === '');
  T('مشروع غريب لا يُحلّ', api.prjResolve('سد وادي حنيفة').status === 'none');
  T('الفراغ حالة مستقلّة', api.prjResolve('   ').status === 'empty');

  // منع المكرّر عند الإضافة
  reset([{ id:'P1', name:'برج الشمال', aliases:[], active:true }]);
  T('إضافة كتابة مختلفة لمشروع قائم تُرجعه نفسه',
    api.prjAdd('برج شمال').id === 'P1' && PRJ.list.length === 1);
  const p2 = api.prjAdd('برج الجنوب');
  T('مشروع مختلف يُضاف فعلاً', p2 && p2.id !== 'P1' && PRJ.list.length === 2);

  // المرادفات محجوزة لمشروع واحد
  T('المرادف يُقبل', api.prjAddAlias('P1', 'البرج الشمالي') === true);
  T('المرادف لا يُسرَق من مشروع آخر', api.prjAddAlias(p2.id, 'البرج الشمالي') === false);
  T('المرادف يعمل فوراً في الحلّ', api.prjResolve('البرج الشمالي').project.id === 'P1');
  T('حذف المرادف يُلغي حلّه',
    api.prjRemoveAlias('P1', 'البرج الشمالي') && api.prjResolve('البرج الشمالي').status !== 'ok');

  // البذرة من الأوامر: الكتابات المتطابقة بعد التطبيع = مشروع واحد
  const STATE = api.STATE;
  STATE.purchaseOrders = [
    { po_number:'A-1', project:'المحكمة الإدارية', total:100 },
    { po_number:'A-2', project:'المحكمة الإدارية', total:100 },
    { po_number:'A-3', project:'محكمه الاداريه',  total:100 },
    { po_number:'A-4', project:'مستودع الخرج',    total:50  },
    { po_number:'A-5', project:'',                total:10  },
  ];
  reset([]);
  const seeded = api.prjSeedFromOrders();
  T('البذرة تنشئ مشروعاً لكل مجموعة متطابقة بعد التطبيع', seeded === 2 && PRJ.list.length === 2);
  const court = PRJ.list.find(p => api.prjNorm(p.name) === api.prjNorm('المحكمة الإدارية'));
  T('الاسم المعتمد هو الكتابة الأكثر وروداً', court.name === 'المحكمة الإدارية');
  T('الكتابة الأقلّ تُحفظ مرادفاً', court.aliases.includes('محكمه الاداريه'));
  T('البذرة لا تمسّ أي أمر شراء', STATE.purchaseOrders[2].project === 'محكمه الاداريه');

  // التوحيد: يعيد كتابة الأوامر ويحفظ المرادف
  const pend = api.prjPendingUnify();
  T('صفّ توحيد واحد للكتابة غير المعتمدة', pend.length === 1 && pend[0].raw === 'محكمه الاداريه');
  T('الصفّ مصنّف مطابقة مؤكَّدة', pend[0].kind === 'alias' && pend[0].target.id === court.id);
  const res = api.prjApplyUnify(pend);
  T('التوحيد يعيد كتابة الأوامر', res.orders === 1 && STATE.purchaseOrders[2].project === 'المحكمة الإدارية');
  T('لا يبقى صفّ توحيد بعد التطبيق', api.prjPendingUnify().length === 0);
  T('القيمة تتجمّع تحت المشروع الواحد', api.prjStats(court).count === 3);

  // إعادة التسمية: تُعيد كتابة الأوامر وتحفظ الاسم القديم مرادفاً
  const n = api.prjRename(court.id, 'المحكمة الإدارية بالرياض');
  T('إعادة التسمية تُحدّث كل أوامر المشروع', n === 3);
  T('كل الأوامر صارت بالاسم الجديد',
    STATE.purchaseOrders.filter(o => o.project === 'المحكمة الإدارية بالرياض').length === 3);
  T('الاسم القديم صار مرادفاً يُحلّ', api.prjResolve('المحكمة الإدارية').project.id === court.id);
  T('اسم يخصّ مشروعاً آخر يُرفض',
    api.prjRename(court.id, PRJ.list.find(p => p.id !== court.id).name) === -1);

  // الدمج
  const store = PRJ.list.find(p => p.id !== court.id);
  const moved = api.prjMergeProjects(store.id, court.id);
  T('الدمج ينقل أوامر المشروع المدموج', moved === 1);
  T('المشروع المدموج يخرج من السجل', !api.prjById(store.id) && PRJ.list.length === 1);
  T('اسم المدموج يبقى قابلاً للحلّ مرادفاً', api.prjResolve('مستودع الخرج').project.id === court.id);

  // الحذف محكوم بالاستعمال
  T('لا حذف لمشروع مستعمل', api.prjDelete(court.id) === false);
  const tmp = api.prjAdd('مشروع بلا أوامر');
  T('حذف مشروع غير مستعمل يمرّ', api.prjDelete(tmp.id) === true);

  // الأزواج المتشابهة داخل السجل: الخطأ الإملائي المسجَّل مشروعاً مستقلاً
  // يبدو معتمداً ولا يظهر في التوحيد — لذلك يُرصد على حدة ويُدمج بقرار بشريّ.
  reset([]);
  STATE.purchaseOrders = [
    { po_number:'E-1', project:'المحكمة الإدارية', total:100 },
    { po_number:'E-2', project:'المحكمة الإدارية', total:100 },
    { po_number:'E-3', project:'المحكمة الادارة',  total:100 },
    { po_number:'E-4', project:'مستودع الخرج',    total:50  },
  ];
  api.prjSeedFromOrders();
  T('الخطأ الإملائي يُسجَّل مشروعاً مستقلاً (البذرة لا تخمّن)', PRJ.list.length === 3);
  T('لا يظهر في صفوف التوحيد لأنه صار معتمداً', api.prjPendingUnify().length === 0);
  const pairs = api.prjDuplicatePairs();
  T('يُرصد زوجاً متشابهاً داخل السجل', pairs.length === 1);
  T('يُبقى الأكثر استعمالاً ويُدمج الأقلّ',
    pairs[0].keep.name === 'المحكمة الإدارية' && pairs[0].drop.name === 'المحكمة الادارة');
  T('المشروع المتمايز ليس ضمن الأزواج',
    !pairs.some(p => p.keep.name === 'مستودع الخرج' || p.drop.name === 'مستودع الخرج'));
  api.prjMergeProjects(pairs[0].drop.id, pairs[0].keep.id);
  T('دمج الزوج يوحّد الأوامر',
    STATE.purchaseOrders.filter(o => o.project === 'المحكمة الإدارية').length === 3);
  T('لا أزواج متبقّية بعد الدمج', api.prjDuplicatePairs().length === 0);

  // الأرقام مميِّزة لا إملائية — «فرع الرياض 3» و«فرع الرياض 4» مشروعان مختلفان
  T('اسمان بأرقام مختلفة دون عتبة الترشيح',
    api.prjSim('فرع الرياض 3', 'فرع الرياض 4') < api.PRJ_SIM_WEAK);
  T('رقم على جانب واحد لا يُقترح تلقائياً',
    api.prjSim('مستودع الخرج', 'مستودع الخرج 2') < api.PRJ_SIM_STRONG);
  T('الأرقام نفسها لا تُضعف التشابه',
    api.prjSim('فرع الرياض ٣', 'فرع الرياض 3') === 1);
  reset([
    { id:'N1', name:'فرع الرياض 3', aliases:[], active:true },
    { id:'N2', name:'فرع الرياض 4', aliases:[], active:true },
  ]);
  T('لا زوج دمج كاذب بين رقمين مختلفين', api.prjDuplicatePairs().length === 0);
  T('كلٌّ يُحلّ لنفسه', api.prjResolve('فرع الرياض 4').project.id === 'N2');

  // المسافات الزائدة: قيمة مخزَّنة مختلفة ⇒ مجموعة منفصلة في كل تجميع يقرأ po.project
  reset([]);
  STATE.purchaseOrders = [
    { po_number:'W-1', project:'مستودع الخرج',    total:100 },
    { po_number:'W-2', project:'  مستودع الخرج ', total:100 },
    { po_number:'W-3', project:'مستودع  الخرج',   total:100 },
  ];
  api.prjSeedFromOrders();
  T('البذرة تنتج مشروعاً واحداً للمسافات المختلفة', PRJ.list.length === 1);
  T('الاسم المعتمد نظيف من المسافات الزائدة', PRJ.list[0].name === 'مستودع الخرج');
  const auto = api.prjAutoUnify();
  T('التوحيد التلقائي يعيد كتابة الأوامر المخزَّنة بمسافات زائدة', auto.orders === 2);
  T('كل الأوامر بقيمة مخزَّنة واحدة',
    new Set(STATE.purchaseOrders.map(o => o.project)).size === 1);
  T('لا يبقى شيء للتوحيد', api.prjPendingUnify().length === 0);
  T('التوحيد التلقائي لا يكتب ثانيةً بلا داعٍ', api.prjAutoUnify().orders === 0);

  // التوحيد التلقائي لا يمسّ المشتبه به (قراره بشريّ)
  reset([{ id:'S1', name:'المحكمة الإدارية', aliases:[], active:true }]);
  STATE.purchaseOrders = [{ po_number:'S-1', project:'المحكمة الادارة', total:100 }];
  T('المشتبه به لا يُوحَّد تلقائياً',
    api.prjAutoUnify().orders === 0 && STATE.purchaseOrders[0].project === 'المحكمة الادارة');

  // الاستيراد: القاطع يُطبَّق، المشتبه يُنبَّه ولا يُخمَّن
  reset([{ id:'P1', name:'برج الشمال', aliases:['البرج الشمالي'], active:true }]);
  const rows = [
    { po_number:'B-1', project:'البرج الشمالي' },
    { po_number:'B-2', project:'برج شمال' },
    { po_number:'B-3', project:'برج الشمل' },
    { po_number:'B-4', project:'سد وادي حنيفة' },
    { po_number:'B-5', project:'' },
  ];
  const warns = [];
  const sum = api.poImportResolveProjects(rows, warns);
  T('الاستيراد يوحّد المرادف تلقائياً', rows[0].project === 'برج الشمال');
  T('الاستيراد يوحّد الكتابة المتطابقة بعد التطبيع', rows[1].project === 'برج الشمال');
  T('عدّاد التوحيد صحيح', sum.mapped === 2);
  T('الخطأ الإملائي لا يُخمَّن في الاستيراد', rows[2].project === 'برج الشمل' && sum.suggest === 1);
  T('المشروع الغريب يُنبَّه عليه', sum.unknown === 1 && warns.length === 2);
  T('الجهة الفارغة لا تُنبِّه', rows[4].project === '');

  // خلية الجدول تسم الكتابة غير المعتمدة
  T('الكتابة غير المعتمدة تُوسم في الجدول',
    /po-prj-unmapped/.test(api.poProjectCell({ project:'برج الشمل' })));
  T('الاسم المعتمد بلا وسم', !/po-prj-unmapped/.test(api.poProjectCell({ project:'برج الشمال' })));

  // مرشّح القائمة يجمع السجل والمستعمل
  STATE.purchaseOrders = [{ po_number:'C-1', project:'موقع غير مسجّل' }];
  const names = api.poProjectList();
  T('قائمة المرشّح تضمّ السجل والمستعمل معاً',
    names.includes('برج الشمال') && names.includes('موقع غير مسجّل'));

  // البحث واعٍ بالمرادفات
  STATE.purchaseOrders = [{ po_number:'D-1', project:'برج الشمال', status:'قيد المراجعة' }];
  STATE.purchaseOrders.forEach(api.recomputePOderived);
  STATE.poSegment = 'all'; STATE.poSort = { col:'po_number', dir:'desc' };
  STATE.poFilter = { q:'البرج الشمالي', sector:'', status:'', priority:'', project:'' };
  T('البحث بكتابة قديمة يجد أوامر المشروع', api.poFilteredList().length === 1);
  STATE.poFilter.q = '';
}

/* ── تقارير متعدّدة المشاريع/الحالات ─────────────────────────── */
{
  G('١٠) تقارير أوامر الشراء — اختيار عدّة مشاريع وحالات');
  const STATE = api.STATE;
  const mk = (n, project, status, days) => ({
    po_number:'P.O-DG26-' + n, issue_date:'2026-08-01', project, supplier:'مورد',
    sector:'إنشاءات', subtotal:1000, status, days_delayed:days||0,
    expected_delivery:'2026-08-20', items:[], status_history:[],
  });
  STATE.purchaseOrders = [
    mk(4001, 'برج الشمال',   'قيد المراجعة', 0),
    mk(4002, 'مستودع الخرج', 'قيد المراجعة', 12),
    mk(4003, 'فرع الرياض 3', 'تسليم كامل',   0),
    mk(4004, '',             'قيد المراجعة', 5),
    mk(4005, 'برج الشمال',   'تسليم للإدارة المالية', 0),
  ];
  STATE.purchaseOrders.forEach(api.recomputePOderived);

  // repList: يقبل الواحد والمتعدّد والفارغ
  T('القيمة الواحدة تصير قائمة', api.repList('أ').length === 1);
  T('المصفوفة تمرّ كما هي بلا فراغات', api.repList(['أ','','ب']).join(',') === 'أ,ب');
  T('الفراغ والمصفوفة الفارغة = بلا تصفية',
    api.repList('').length === 0 && api.repList([]).length === 0 && api.repList(undefined).length === 0);

  // التصفية بعدّة مشاريع
  const all = STATE.purchaseOrders;
  T('بلا اختيار تمرّ كل الأوامر', api.repFilterProjects(all, []).length === 5);
  T('مشروع واحد (توافق خلفي مع النصّ)', api.repFilterProjects(all, 'برج الشمال').length === 2);
  T('مشروعان معاً في تقرير واحد',
    api.repFilterProjects(all, ['برج الشمال','فرع الرياض 3']).length === 3);
  T('«بلا جهة» تُختار مع مشاريع أخرى',
    api.repFilterProjects(all, ['برج الشمال','__none__']).length === 3);
  T('«بلا جهة» وحدها لا تجلب المحدّدة',
    api.repFilterProjects(all, ['__none__']).every(o => !String(o.project||'').trim()));

  // وصف المرشّح المطبوع يسمّي المختار
  T('الوصف يسمّي المشروعين', api.repDescList('الجهة', ['برج الشمال','فرع الرياض 3'])
    === 'الجهة: برج الشمال + فرع الرياض 3');
  T('الوصف يختصر ما زاد على أربعة',
    /و1 أخرى$/.test(api.repDescList('الجهة', ['أ','ب','ج','د','هـ'])));
  T('بلا اختيار لا وصف', api.repDescList('الجهة', []) === '');
  T('«بلا جهة» تُترجَم في الوصف', api.repDescList('الجهة', ['__none__']) === 'الجهة: بلا جهة محدّدة');

  // التقرير نفسه: عدّة مشاريع + عدّة حالات
  api.buildPOListReport({ project:['برج الشمال','مستودع الخرج'] });
  let cap = api.captured;
  T('السجل يطبع أوامر المشروعين معاً', /4001/.test(cap.body) && /4002/.test(cap.body));
  T('ويستبعد ما سواهما', !/4003/.test(cap.body) && !/4004/.test(cap.body));
  T('عنوان التقرير يذكر المشروعين', /برج الشمال \+ مستودع الخرج/.test(cap.opts.subtitle));

  api.buildPOListReport({ status:['قيد المراجعة','تسليم كامل'] });
  cap = api.captured;
  T('عدّة حالات في تقرير واحد', /4001/.test(cap.body) && /4003/.test(cap.body));
  T('والحالة غير المختارة مستبعَدة', !/4005/.test(cap.body));

  // الفجوة لا تُعلَن على تقرير مُصفّى — الأمر المستبعَد بالمرشّح ليس «غير مسجّل»
  api.buildPOListReport({ project:['برج الشمال','مستودع الخرج'] });
  cap = api.captured;
  T('التقرير المُصفّى لا يدّعي فجوات كاذبة', !/غير مسجّل/.test(cap.body));
  T('ويقول إنه مُصفّى', /التقرير مُصفّى/.test(cap.body));
  api.buildPOListReport({});
  cap = api.captured;
  T('التقرير غير المُصفّى ما زال يكشف الفجوات الحقيقية',
    /متّصل بلا فجوات/.test(cap.body) || /غير مسجّل/.test(cap.body));
  T('وغير المُصفّى لا يُوصَف بأنه مُصفّى', !/التقرير مُصفّى/.test(cap.body));

  // التوزيع حسب الجهة يبقى مبنيّاً على المُصفّى
  api.buildPOListReport({ project:['برج الشمال'] });
  cap = api.captured;
  T('قسم التوزيع يحصر المشروع المختار',
    /التوزيع حسب الجهة/.test(cap.body) && !/مستودع الخرج/.test(cap.body));

  // المتأخرات ولدى المالية صارا يقبلان مشاريع متعدّدة
  api.buildPOOverdueReport({ project:['مستودع الخرج'] });
  cap = api.captured;
  T('المتأخرات تُصفّى بالمشروع', /4002/.test(cap.body) && !/4004/.test(cap.body));
  T('وعنوانها يذكر الجهة', /مستودع الخرج/.test(cap.opts.subtitle));
  api.buildPOOverdueReport();
  T('المتأخرات بلا مرشّح تبقى كما كانت', /4002/.test(api.captured.body) && /4004/.test(api.captured.body));

  api.buildPOFinanceReport({ project:['برج الشمال'] });
  T('الأوامر لدى المالية تُصفّى بالمشروع', /4005/.test(api.captured.body));
  api.buildPOFinanceReport();
  T('ولدى المالية بلا مرشّح تعمل كما كانت', /4005/.test(api.captured.body));
}

/* ── المزامنة التفاضلية ───────────────────────────────────────── */
{
  G('١١) المزامنة التفاضلية — تطبيق الحدث بلا تحميل كامل');
  const STATE = api.STATE;
  const ev = (type, row, old) => ({ eventType:type, new:row, old:old });

  // أمر شراء: إضافة ثم تعديل نفس الصفّ
  STATE.purchaseOrders = [];
  let ok = api.rtApply('pos', ev('INSERT', {
    po_number:'P.O-DG26-7001', issue_date:'2026-08-01', supplier:'مورد', project:'برج',
    subtotal:1000, status:'قيد المراجعة', items:[], updated_at:'2026-08-01T10:00:00Z' }));
  T('حدث إضافة أمر يُطبَّق مباشرةً', ok === true && STATE.purchaseOrders.length === 1);
  T('الأرقام المشتقّة تُحسب للصفّ المُطبَّق',
    STATE.purchaseOrders[0].vat === 150 && STATE.purchaseOrders[0].total === 1150);
  T('طابع القفل المتفائل يُضبط كما في التحميل الكامل',
    STATE.purchaseOrders[0]._sync === '2026-08-01T10:00:00Z');
  T('الصفّ يُوسم سحابياً', STATE.purchaseOrders[0]._cloud === true);

  ok = api.rtApply('pos', ev('UPDATE', {
    po_number:'P.O-DG26-7001', issue_date:'2026-08-01', supplier:'مورد آخر', project:'برج',
    subtotal:2000, status:'اعتماد مدير الشراء', items:[], updated_at:'2026-08-01T11:00:00Z' }));
  T('التعديل يستبدل الصفّ ولا يُكرّره', ok && STATE.purchaseOrders.length === 1);
  T('القيم الجديدة سرت', STATE.purchaseOrders[0].supplier === 'مورد آخر'
    && STATE.purchaseOrders[0].total === 2300);
  T('الطابع تحدَّث مع التعديل', STATE.purchaseOrders[0]._sync === '2026-08-01T11:00:00Z');

  // صنف: مفتاحه code
  STATE.items = [{ code:'IT-1', name:'قديم', category:'أ' }];
  api.rtApply('items', ev('UPDATE', { code:'IT-1', name:'جديد', category:'أ' }));
  T('الصنف يُطابَق بالكود ويُستبدَل',
    STATE.items.length === 1 && STATE.items[0].name === 'جديد' && STATE.items[0]._cloud === true);
  api.rtApply('items', ev('INSERT', { code:'IT-2', name:'صنف ثانٍ' }));
  T('الصنف الجديد يُضاف أوّلاً (الأحدث أولاً)',
    STATE.items.length === 2 && STATE.items[0].code === 'IT-2');

  // المورد: المفتاح id ثم الاسم — تغيير الاسم على نفس المعرّف تعديلٌ لا صفّ جديد
  STATE.suppliers = [{ id:'S-1', name:'الاسم القديم' }];
  api.rtApply('suppliers', ev('UPDATE', { id:'S-1', name:'الاسم الجديد' }));
  T('المورد يُطابَق بالمعرّف حتى لو تغيّر اسمه',
    STATE.suppliers.length === 1 && STATE.suppliers[0].name === 'الاسم الجديد');
  // صفّ بلا معرّف يُطابَق بالاسم (سجلّ بذرة قديم)
  STATE.suppliers = [{ name:'مورد بذرة' }];
  api.rtApply('suppliers', ev('INSERT', { id:'S-9', name:'مورد بذرة' }));
  T('الصفّ السحابي يحلّ محلّ سجلّ البذرة بنفس الاسم',
    STATE.suppliers.length === 1 && STATE.suppliers[0].id === 'S-9');

  // السجل السعري: مفتاحه num
  STATE.history = [{ num:5, code:'IT-1', price:100 }];
  api.rtApply('history', ev('UPDATE', { num:5, code:'IT-1', price:150 }));
  T('سجلّ السعر يُطابَق برقمه', STATE.history.length === 1 && STATE.history[0].price === 150);

  // الحالات التي **يجب** أن تسقط للتحميل الكامل — لا تخمين
  T('الحذف يسقط للتحميل الكامل عمداً',
    api.rtApply('pos', ev('DELETE', null, { po_number:'P.O-DG26-7001' })) === false);
  T('الحدث المجهول لا يُطبَّق', api.rtApply('pos', ev('TRUNCATE', {})) === false);
  T('الجدول غير المعروف لا يُطبَّق', api.rtApply('unknown', ev('INSERT', { id:1 })) === false);
  T('حمولة فارغة لا تُطبَّق', api.rtApply('pos', null) === false);
  T('صفّ بلا مفتاح لا يُطبَّق', api.rtApply('items', ev('INSERT', { name:'بلا كود' })) === false);
  T('مفتاح فارغ نصّياً لا يُطبَّق', api.rtApply('items', ev('INSERT', { code:'', name:'س' })) === false);

  // الحذف لم يغيّر الحالة (لأنه لم يُطبَّق)
  T('الحذف الساقط لا يمسّ الحالة',
    STATE.purchaseOrders.length === 1 && STATE.purchaseOrders[0].po_number === 'P.O-DG26-7001');

  // rtIndexOf: ترتيب المفاتيح مُحترَم
  const list = [{ id:'A', name:'س' }, { id:'B', name:'ص' }];
  T('يُطابق بالمفتاح الأوّل المتوفّر', api.rtIndexOf(list, ['id','name'], { id:'B', name:'س' }) === 1);
  T('يسقط للمفتاح التالي عند غياب الأوّل', api.rtIndexOf(list, ['id','name'], { name:'س' }) === 0);
  T('لا مطابقة ⇒ -1', api.rtIndexOf(list, ['id','name'], { id:'Z' }) === -1);

  // خريطة الجداول تغطّي ما تشترك عليه القناة اللحظية
  T('الخريطة تغطّي الجداول الأربعة',
    ['items','suppliers','history','pos'].every(k => api.RT_MAP[k] && api.RT_MAP[k].arr && api.RT_MAP[k].keys.length));
}

/* ── 12) تقرير المتابعة الميدانية — سرّية المبالغ ───────────── */
{
  G('١٢) تقرير المتابعة بلا مبالغ (يُسلَّم لموظفي الصيانة)');
  const STATE = api.STATE;
  // مبالغ مميّزة لا تتصادف مع كميّة أو تاريخ أو رقم أمر — أي ظهور لها تسريب
  const AMTS = ['987654', '432109', '765432', '210987'];
  STATE.purchaseOrders = [
    { po_number:'P.O-DG26-5001', issue_date:'2026-08-01', project:'برج الشمال', supplier:'مورد أ',
      sector:'إنشاءات', status:'تسليم جزئي', expected_delivery:'2026-08-20',
      items:[{desc:'كابل', unit:'متر', qty:10, price:987654, received_qty:4}], receipts:[], status_history:[] },
    { po_number:'P.O-DG26-5002', issue_date:'2026-08-02', project:'مستودع الخرج', supplier:'مورد ب',
      sector:'إنشاءات', status:'قيد التوريد', expected_delivery:'2026-08-05',
      items:[{desc:'مضخة', unit:'حبة', qty:2, price:432109, received_qty:0}], receipts:[], status_history:[] },
    { po_number:'P.O-DG26-5003', issue_date:'2026-08-03', project:'برج الشمال', supplier:'مورد ج',
      sector:'إنشاءات', status:'تسليم كامل', expected_delivery:'2026-08-25', actual_delivery:'2026-08-24',
      items:[{desc:'دهان', unit:'علبة', qty:5, price:765432, received_qty:5}], receipts:[], status_history:[] },
    { po_number:'P.O-DG26-5004', issue_date:'2026-08-04', project:'', supplier:'مورد د',
      sector:'النقليات', status:'ملغى', expected_delivery:'2026-08-10',
      items:[{desc:'مولّد ملغى', unit:'حبة', qty:3, price:210987, received_qty:0}], receipts:[], status_history:[] },
    { po_number:'P.O-DG26-5005', issue_date:'2026-08-04', project:'برج الشمال', supplier:'مورد هـ',
      sector:'النقليات', status:'قيد المراجعة', expected_delivery:'2026-09-30',
      items:[], receipts:[], status_history:[] },
  ];
  STATE.purchaseOrders.forEach(api.recomputePOderived);

  await api.buildPOFollowupReport({});
  const cap = api.captured;
  const doc = cap.opts.title + ' ' + cap.opts.subtitle + ' ' + cap.opts.eyebrow + ' ' + cap.body;

  // ── الحارس الأساس: لا مبلغ ولا أثر مالي في المستند كلّه
  T('لا يظهر أي مبلغ من الأوامر في التقرير', AMTS.every(a => !doc.includes(a)),
    AMTS.filter(a => doc.includes(a)).join('، '));
  T('لا إجمالي محسوب (شامل الضريبة) في التقرير',
    !doc.includes(String(api.STATE.purchaseOrders[0].total)) &&
    !doc.includes(String(api.STATE.purchaseOrders[0].vat)));
  T('لا وحدة عملة في التقرير', !doc.includes('ر.س'));
  T('لا خلية سعر (class=price) في التقرير', !/class="[^"]*\bprice\b/.test(cap.body));
  // حارس المصدر: عمود جديد يحمل مبلغاً يُفشِل البناء قبل أن يُطبع
  const srcFollow = grab('buildPOFollowupReport') + grab('poFollowDelivery') + grab('poFollowReceived');
  T('متن الدالة خالٍ من أي مصدر مالي',
    !/fmtPrice|\.total\b|\.subtotal\b|\.vat\b|\.price\b|ر\.س/.test(srcFollow),
    (srcFollow.match(/fmtPrice|\.total\b|\.subtotal\b|\.vat\b|\.price\b|ر\.س/g) || []).join('، '));

  // ── المحتوى المفيد للمتابعة موجود فعلاً (تقرير بلا مبالغ لا بلا معلومات)
  T('يسرد كل الأوامر المطابقة', ['5001','5002','5003','5004','5005'].every(n => cap.body.includes('P.O-DG26-' + n)));
  T('يعرض الجهة مع كل أمر', cap.body.includes('برج الشمال') && cap.body.includes('مستودع الخرج'));
  T('يعرض المورد', cap.body.includes('مورد أ') && cap.body.includes('مورد ج'));
  T('نسبة الاستلام بالكميّات لا بالقيم', cap.body.includes('4 / 10 (40%)'));
  T('الأمر بلا بنود يعرض «—» لا 0%', api.poFollowReceived(STATE.purchaseOrders[4]) === '—');
  T('جدول البنود المنتظَرة يذكر المتبقّي', cap.body.includes('البنود المنتظَر استلامها') && cap.body.includes('كابل'));
  T('البند المستلَم بالكامل لا يظهر في المنتظَر', !cap.body.includes('دهان'));
  T('بنود الأمر الملغى لا تُطلب في المتابعة', !cap.body.includes('مولّد ملغى'));
  T('التوزيع حسب الجهة بالعدد فقط',
    cap.body.includes('التوزيع حسب الجهة / المشروع') && cap.body.includes('إجمالي الأوامر'));
  T('لافتة التسليم الجزئي تنبّه للإقفال', cap.body.includes('بانتظار إكمال الاستلام'));
  T('المستند يعلن أنه بلا مبالغ', cap.body.includes('بلا أي مبالغ') && cap.opts.title.includes('بلا مبالغ'));

  // ── حالة التسليم بصيغة الماضي/المستقبل الصحيحة
  T('المُسلَّم في الموعد يُوصَف بالماضي', api.poFollowDelivery(STATE.purchaseOrders[2]).includes('سُلّم'));
  T('المتأخر قيد التنفيذ يُوصَف متأخراً', api.poFollowDelivery(STATE.purchaseOrders[1]).includes('متأخر'));
  T('الملغى يُوسم ملغى لا «في الموعد»', api.poFollowDelivery(STATE.purchaseOrders[3]).includes('ملغى'));
  T('الملغى بلا مبلغه حتى في بنوده', !doc.includes('210987'));

  // ── المرشّحات نفسها التي في سجل الأوامر التفصيلي
  await api.buildPOFollowupReport({ project:['برج الشمال'] });
  const f1 = api.captured.body;
  T('التصفية بالجهة تعمل', f1.includes('5001') && f1.includes('5003') && !f1.includes('5002'));
  await api.buildPOFollowupReport({ status:['قيد التوريد'] });
  T('التصفية بالحالة تعمل', api.captured.body.includes('5002') && !api.captured.body.includes('5001'));
  await api.buildPOFollowupReport({ from:'2026-08-03' });
  T('التصفية بالتاريخ تعمل', api.captured.body.includes('5003') && !api.captured.body.includes('5001'));

  // ── الكتالوج: البطاقة موجودة ومرشّحاتها مطابقة لسجل الأوامر
  const cardAt = JS.indexOf("title:'متابعة أوامر الشراء — بلا مبالغ', desc:");
  const card = cardAt < 0 ? '' : JS.slice(cardAt, cardAt + 900);
  T('بطاقة التقرير في كتالوج المشتريات', cardAt > 0 && card.includes('buildPOFollowupReport'));
  T('بطاقتها بمرشّحات متعدّدة (حالة/جهة/قطاع)',
    ['status','project','sector'].every(k => card.includes(`key:'${k}'`)));
}

/* ── النتيجة ─────────────────────────────────────────────────── */
console.log(`\n${'─'.repeat(52)}`);
console.log(`النتيجة: ${pass} ناجح · ${fail} فاشل`);
process.exit(fail ? 1 : 0);

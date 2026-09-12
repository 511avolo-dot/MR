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
/* المقصد كما هو: الملف يُعرَض من نسخة محليّة لا من رابط تخزين خارجيّ. تغيّرت
   الآليّة فقط — الرسم صار canvas بـpdf.js بدل `<iframe>` لأن iOS Safari لا
   يرسم PDF داخل إطار مضمّن (بلاغ 2026-09-07). */
T('العارض يستعمل blob محلّياً لا رابطاً خارجياً',
  /createObjectURL/.test(CODE) && /docvBlobUrl\(d\.path\)/.test(CODE) &&
  !/docv-stage[\s\S]{0,4000}src="https?:/.test(CODE));
T('العارض لا يستعمل object/embed اللذين تمنعهما CSP',
  !/docvShow[\s\S]{0,2500}<(object|embed)\b/.test(CODE));

/* ── عرض PDF: لا إطار مضمّن، ومكتبة محلّية لا CDN ─────────────────────────────
   iOS Safari لا يرسم PDF داخل `<iframe>` (بياض كامل — بلاغ المالك بلقطة
   2026-09-07)، فأي عودة للإطار تُعيد العطل على كل مستخدمي الآيفون. */
T('لا `<iframe>` لعرض PDF في مسرح العارض',
  !/docvShow\([\s\S]{0,2500}<iframe/.test(CODE));
T('pdf.js يُحمَّل من `/vendor/` المحلّي (بلا CDN ⇒ بلا تعديل CSP)',
  /import\('\/vendor\/pdf\.min\.mjs'\)/.test(CODE) &&
  /workerSrc\s*=\s*'\/vendor\/pdf\.worker\.min\.mjs'/.test(CODE) &&
  fs.existsSync(path.join(ROOT,'vendor/pdf.min.mjs')) &&
  fs.existsSync(path.join(ROOT,'vendor/pdf.worker.min.mjs')));
T('التحميل كسول — لا يُجلب pdf.js إلا عند فتح أوّل PDF',
  /let _PDFJS = null/.test(CODE) && /if \(_PDFJS\) return _PDFJS/.test(CODE) &&
  !/^import .*pdf\.min\.mjs/m.test(CODE));
T('سقف دقّة الرسم يمنع انهيار الذاكرة على الجوال',
  /Math\.min\(window\.devicePixelRatio \|\| 1, 2\)/.test(CODE));
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
// (و) القاعدة نفسها معمَّمة على **كل** النوافذ: `.page.active` تحمل animation،
//     وأي transform على السلف يجعله الحاوي لـposition:fixed فتُرسم النافذة
//     منسوبةً للقسم الطويل المُمرَّر لا للشاشة (بلاغ المالك: البطاقة تعلق أسفل
//     الشاشة ولا تُرفع). نافذتا التسجيل والقوالب أُصيبتا بذلك فعلاً ونُقِلتا.
{
  const inside = [];
  const re = /id="(modal-[A-Za-z0-9_-]+)"/g;
  let m;
  while ((m = re.exec(HTML))) {
    const sec = HTML.lastIndexOf('<section class="page"', m.index);
    const end = sec < 0 ? -1 : HTML.indexOf('</section>', sec);
    if (sec >= 0 && end > m.index) inside.push(m[1]);
  }
  T('لا نافذة داخل أي <section class="page"> (تُرسم أسفل الشاشة ولا تُرفع)',
    inside.length === 0, inside.join('، '));
}
// (ز) السبب الجذريّ: fill-mode على حركة الصفحة يُبقي transform محسوباً للأبد.
T('حركة .page.active بلا fill مُبقٍ للـtransform (both/forwards)',
  /\.page\.active\s*\{[^}]*animation:[^;]*\bbackwards\b/.test(HTML) &&
  !/\.page\.active\s*\{[^}]*animation:[^;]*\b(both|forwards)\b/.test(HTML));

/* ── سرعة فتح المستندات: الوثيقة القديمة كانت ثلاث رحلات في كل مرّة ── */
T('الكاش السالب بالمسار لا برقم التسجيل (المورّد صار مختلط المخزنَين)',
  /REGDOC_R2_MISS\.add\(path\)/.test(CODE) && /REGDOC_R2_MISS\.has\(path\)/.test(CODE) &&
  CODE.includes('REGDOC_LEGACY_HINT'));
T('روابط وثائق الطلب تُسكّ دفعةً واحدة عند فتح العارض',
  CODE.includes('function regDocSignBatch(') && /createSignedUrls\(/.test(CODE) &&
  /docvOpen\([\s\S]{0,600}regDocSignBatch\(/.test(CODE));
{
  // الترتيب مهمّ: الاستدعاء بعد رسم الوثيقة المطلوبة، وإلا زاحمها التحميل المُسبَق.
  const body = CODE.slice(CODE.indexOf('async function docvShow('));
  const call = body.indexOf('docvPrefetchNeighbors()');
  const draw = body.indexOf('docvRenderPdf(');   // نقطة الرسم بعد التحوّل إلى pdf.js
  T('تحميل مُسبَق للتبويب المجاور بعد العرض لا قبله',
    CODE.includes('function docvPrefetchNeighbors(') && call > 0 && draw > 0 && call > draw);
}
T('إبطال الـblob لا يطال الوثيقة المعروضة الآن',
  /const shown = \(DOCV\.list\[DOCV\.i\] \|\| \{\}\)\.path/.test(CODE) &&
  /find\(k => k !== shown\)/.test(CODE));
// (ح) ملف عرض سعر المورّد: كان يُنزَّل على الجهاز ثم يُحذف من المخزن.
T('لا مسار يُنزّل ملف عرض السعر ثم يحذفه من المخزن',
  !CODE.includes('rfqDownloadQuoteFile') &&
  !/storage\.from\('supplier-docs'\)\s*\.\s*remove\(/.test(CODE) &&
  CODE.includes('function rfqViewQuoteFile(') && /rfqViewQuoteFile[\s\S]{0,300}docvOpen\(/.test(CODE));

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
  'arNorm', 'supKey', 'supKeyStrong', 'supVal', 'supDataGaps', 'supGapMatch', 'supGapBadge', 'supIsEmptyVal', 'supMergeRows', 'supDedupeByName', 'supSourceBreakdown',
  'supHaystack', 'supMatches', 'supDaysTo', 'supExpiryStrip', 'supPhoneKeys', 'supQueryDigits',
  'regFmtBytes', 'supDocRow', 'supDocNeedsAction', 'supDocUrgency', 'supDocSort',
  'regDocRegId', 'regDocSignedGet', 'regDocToken', 'regDocFromR2', 'regDocFromLegacy', 'regDocFetch',
  // حملة تسجيل الموردين غير المسجَّلين + إكمال البطاقة القائمة عند الاعتماد
  'regCampWaPhone', 'regCampMessage', 'regCampBuild', 'regSupplierFill', 'regMatchExistingSupplier', 'normalizeSaudiPhone',
  'docvKind', 'docvExt', 'docvListFromReg', 'docvLabel', 'regSearchSafe',
  'poFollowDelivery', 'poFollowReceived', 'buildPOFollowupReport',
  'rtIndexOf', 'rtApply',
  'buildPOListReport', 'buildPOOverdueReport', 'buildPOFinanceReport', 'printUrgentMemo',
  'buildPOCycleReport', 'poPrintDashboard', 'poStateSnapshot', 'poHealthScore',
  'poStageStats', 'poFmtDuration', 'poCurrentStageAge', 'poProjectStats', 'printPO',
  'poPriceRef', 'poPriceRefPrefix', 'poItemIndex', 'poMatchItem', 'poPriceEligible',
  'poSyncPriceHistory', 'recomputeItemStats', 'siNormalize', 'poMatchLine',
  // سجل المشاريع المعتمد
  'prjNorm', 'prjClean', 'prjBigrams', 'prjDice', 'prjLev', 'prjDigits', 'prjRawSim', 'prjDistinctWords',
  'prjSim', 'prjActive', 'prjById', 'prjNames',
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
const NEEDED_CONSTS = ['SUP_REQUIRED_DOCS', 'SUP_EXPIRY_SOON_DAYS', 'REG_PLAN_LIMITS', 'DOCV_NAMES', 'SI_SYNONYM_MAP', 'PO_PRICE_REF', 'PO_ENUMS', 'PO_STATUS_META', 'PO_BOARD_ORDER', 'PO_STEPPER', 'PO_TERMINAL', 'PO_STATUS_ALIAS', 'PO_SEGMENTS',
  'PRJ_SETTINGS_KEY', 'PRJ_LOCAL_KEY', 'PRJ', 'PRJ_STOPWORDS', 'PRJ_SIM_STRONG', 'PRJ_SIM_WEAK',
  'RT_MAP',
  // جلب وثائق الموردين (مخزنان: R2 + القديم) — تُختبَر سلوكيّاً
  'SUP_ENTITY_RE', 'SUP_GAP_FIELDS', 'REG_SUP_COLS', 'REG_BUCKET', 'REGDOC_R2_MISS', 'REGDOC_LEGACY_HINT', 'REGDOC_SIGNED', 'REGDOC_SIGN_TTL'];

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
/* الكود يقرأ \`CLOUD\` مجرّداً و\`window.CLOUD\` معاً — فليكونا المرجع نفسه */
let CLOUD = null;
const window = { get CLOUD(){ return CLOUD; }, set CLOUD(v){ CLOUD = v; } };
let __captured = null;
async function printDocOpen(opts, body){ __captured = {opts, body}; }
const document = {
  getElementById: () => ({ classList:{contains:()=>false, add(){}, remove(){}, toggle(){}}, value:'', innerHTML:'',
                           style:{}, focus(){}, setAttribute(){}, querySelectorAll:()=>[], onclick:null }),
  querySelectorAll: () => [], body:{ classList:{add(){},remove(){},contains:()=>false} },
};
`;

const body = [stubs, ...NEEDED_LETS.map(grabLet), ...NEEDED_CONSTS.map(grabConst), ...NEEDED_FNS.map(grab)].join('\n\n');
const exportLine = `; return {${[...NEEDED_FNS, ...NEEDED_CONSTS].join(',')}, STATE, window, get captured(){return __captured;}};`;
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

  /* ── الكلمة المميِّزة (بلاغ كاذب حقيقيّ رآه المالك على الإنتاج) ────────────
     ثمانية «مشاريع متشابهة» بنسبة 87–91% كانت في الحقيقة مطارات مختلفة تشترك
     في السابقة «المباني الجمركية بمطار». الكاسر يفصلها **دون** أن يُخفي الخطأ
     الإملائي الحقيقي — والشقّان محروسان معاً: إسقاط أحدهما يُفشِل البناء. */
  const AIRPORT = (c) => 'المباني الجمركية بمطار ' + c;
  for (const [a, b] of [['الطائف','حائل'], ['جدة','الجوف'], ['ابها','تبوك'],
                        ['الرياض','الدمام'], ['القصيم','الدمام']])
    T(`مطاران مختلفان لا يُقترحان للدمج (${a}/${b})`,
      api.prjSim(AIRPORT(a), AIRPORT(b)) < api.PRJ_SIM_WEAK,
      (api.prjSim(AIRPORT(a), AIRPORT(b)) * 100).toFixed(0) + '%');
  T('كلمة مميِّزة مختلفة تكسر التشابه ولو طال المشترك',
    api.prjSim('محطة المعالجة', 'محطة التحلية') < api.PRJ_SIM_WEAK);
  // ⚠️ الشقّ المقابل: خطأ إملائي بحرف واحد داخل الكلمة **يبقى مكشوفاً**
  for (const [a, b] of [['مستودع الدمام','مستودع الدمم'], ['برج الشمال','برج الشمل'],
                        ['فرع الرياض','فرع الريان']])
    T(`خطأ إملائي بحرف يبقى مقترحاً (${a}/${b})`,
      api.prjSim(a, b) >= api.PRJ_SIM_STRONG, (api.prjSim(a, b) * 100).toFixed(0) + '%');
  T('كلمة زائدة على جانب واحد لا تُقترح تلقائياً',
    api.prjSim('مستودع الخرج', 'مستودع الخرج الجنوبي') < api.PRJ_SIM_STRONG);
  T('فرق الكلمات يحترم التكرار ويعطي كلمة لكل جانب',
    JSON.stringify(api.prjDistinctWords('مباني جمركيه بمطار طاءف', 'مباني جمركيه بمطار حاءل'))
      === JSON.stringify({ dx:['طاءف'], dy:['حاءل'] }));
  T('التشابه الخام بلا كواسر (أساس مقارنة الكلمة بالكلمة)',
    api.prjRawSim('دمام','دمم') >= api.PRJ_SIM_WEAK && api.prjRawSim('طاءف','حاءل') < api.PRJ_SIM_WEAK);
  reset([
    { id:'A1', name:AIRPORT('الطائف'), aliases:[], active:true },
    { id:'A2', name:AIRPORT('حائل'),   aliases:[], active:true },
    { id:'A3', name:AIRPORT('جدة'),    aliases:[], active:true },
  ]);
  T('شاشة التوحيد لا تعرض مطارات مختلفة كمرشّحات دمج',
    api.prjDuplicatePairs().length === 0, api.prjDuplicatePairs().length + ' زوج');

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

/* ── 13) الموردون: بحث عربي متسامح وسعة ألف مورد ─────────────── */
{
  G('١٣) الموردون — بحث عربي متسامح · سعة · متابعة صلاحية الوثائق');

  // التطبيع: أكثر حالة واقعية هي الهمزة والتاء المربوطة والياء
  T('الهمزات تُوحَّد', api.arNorm('أحمد') === api.arNorm('احمد'));
  T('التاء المربوطة تُوحَّد', api.arNorm('مؤسسة') === api.arNorm('مؤسسه'));
  T('الألف المقصورة تُوحَّد', api.arNorm('مصطفى') === api.arNorm('مصطفي'));
  T('التشكيل والتطويل يُسقطان', api.arNorm('شَرِكـــة') === api.arNorm('شركه'));
  T('الأرقام الهندية تُحوَّل', api.arNorm('٥٠٢') === '502');
  T('لا يخلط اسمين مختلفين', api.arNorm('النخبة') !== api.arNorm('النخيل'));

  const sup = {name:'مؤسسة أحمد الغامدي للمقاولات', specialty:'أعمال كهربائية', contact:'خالد',
    phone:'+966 13-857-6550', mobile:'0501234567', email:'info@nokhba.sa',
    commercial_reg:'4030123456', tax_id:'300012345600003', city:'الدمام'};
  const hunt = (q) => api.supMatches(sup, api.arNorm(q).split(' ').filter(Boolean), api.supQueryDigits(q));
  T('يجد الاسم بكتابة بلا همزات', hunt('مؤسسه احمد'));
  T('يجد بكلمتين متفرّقتين بأي ترتيب', hunt('الغامدي مؤسسة'));
  T('يجد بالسجل التجاري', hunt('4030123456'));
  T('يجد بالرقم الضريبي', hunt('300012345600003'));
  // الرقم نفسه يُكتب بثلاث صيغ في السعودية — الثلاث يجب أن تجده
  T('يجد بالهاتف بصيغة 013…', hunt('0138576550'));
  T('يجد بالهاتف بصيغة +966 13…', hunt('+966138576550'));
  T('يجد بالهاتف بجزء منه', hunt('8576550'));
  T('يجد بالجوال', hunt('0501234567'));
  T('رقم مختلف لا يُطابق', !hunt('0559998888'));
  T('يجد بالبريد والمدينة', hunt('nokhba') && hunt('الدمام'));
  T('لا يطابق ما ليس فيه', !hunt('مصنع بلاستيك'));

  // سعة: البحث خطّيّ على ألف مورد ويجب أن يبقى فوريّاً
  const many = Array.from({length:1000}, (_,i) => ({
    name:'مورد رقم ' + i, specialty:'قطاع ' + (i % 12), contact:'مسؤول ' + i,
    phone:'05' + String(10000000 + i), mobile:'', email:'s'+i+'@x.sa',
    commercial_reg:String(4030000000 + i), tax_id:'', city:'الرياض'}));
  many[777].name = 'مؤسسة النخبة الذهبية';
  const t0 = Date.now();
  const hit = many.filter(s => api.supMatches(s, api.arNorm('النخبه الذهبيه').split(' ').filter(Boolean), ''));
  const ms = Date.now() - t0;
  T('يجد المورد وسط ألف مورد بكتابة مختلفة', hit.length === 1 && hit[0].name === 'مؤسسة النخبة الذهبية');
  T('البحث في ألف مورد أسرع من 300ms', ms < 300, ms + 'ms');

  // العرض على دفعات: 1000 بطاقة دفعةً واحدة تُجمّد الصفحة
  T('العرض على دفعات لا يرسم كل الموردين دفعةً',
    /const SUP_PAGE\s*=\s*\d+/.test(CODE) && CODE.includes('slice(0, _supShown)') && CODE.includes('function supShowMore'));
  T('يُعلَن المجموع فلا يبدو الباقي مفقوداً',
    CODE.includes("getElementById('sup-count')") && HTML.includes('id="sup-count"'));
  T('مُنتقي التخصص يُعاد بناؤه مع تغيّر القائمة',
    /sel\.options\.length\s*-\s*1\s*!==\s*specs\.length/.test(CODE));
  T('مستمعا البحث والتخصص لا يمرّران الحدث كمعامل',
    CODE.includes("addEventListener('input',()=>renderSuppliers())") &&
    CODE.includes("addEventListener('change',()=>renderSuppliers())"));

  // متابعة صلاحية الوثائق النظامية
  const day = 86400000, iso = (d) => new Date(Date.now() + d*day).toISOString().slice(0,10);
  T('يحسب الأيام المتبقّية', Math.abs(api.supDaysTo(iso(10)) - 10) <= 1);
  T('تاريخ فارغ ⇒ لا حساب', api.supDaysTo('') === null && api.supDaysTo(null) === null);
  T('تاريخ تالف ⇒ لا حساب', api.supDaysTo('غير صالح') === null);
  T('السجل المنتهي يُوسَم منتهياً', api.supExpiryStrip({cr_expiry_date: iso(-40)}).includes('منتهٍ منذ'));
  T('المقارب للانتهاء يُوسَم تحذيراً', api.supExpiryStrip({cr_expiry_date: iso(12)}).includes('ينتهي خلال'));
  T('السارية تُوسَم سارية', api.supExpiryStrip({cr_expiry_date: iso(400)}).includes('سارٍ'));
  T('بلا تواريخ ⇒ لا شريط', api.supExpiryStrip({}) === '');

  // سعة شاشة التسجيلات: ترقيم على الخادم ومجموع حقيقي، لا سقف صامت
  T('شاشة التسجيلات مُرقَّمة على الخادم لا مبتورة بسقف',
    CODE.includes('const REG_PAGE_SIZE') && /\.range\(from, from \+ REG_PAGE_SIZE - 1\)/.test(CODE) &&
    !/from\(REG_TABLE\)\.select\('\*'\)[\s\S]{0,80}\.limit\(100\)/.test(CODE));
  T('المجموع الحقيقي يُعلَن (count exact) ومعه شريط ترقيم',
    /count:\s*'exact'/.test(CODE) && CODE.includes('function renderRegPager') && HTML.includes('id="reg-pager"'));
  T('للتسجيلات بحث على الخادم',
    HTML.includes('id="reg-search"') && /legal_name_ar\.ilike\./.test(CODE) && CODE.includes('function regSearchSafe'));
  T('البحث يُعقّم محارف PostgREST الخاصة',
    api.regSearchSafe('a,b(c)*d\\e').indexOf(',') < 0 && api.regSearchSafe('x)y').indexOf(')') < 0);
  T('لا يُحقن صفّ التسجيل كاملاً في سمة onclick',
    !CODE.includes('openRegDetail(${JSON.stringify(JSON.stringify(r))})') && CODE.includes('function openRegById'));
  T('قائمة التسجيلات تجلب أعمدتها فقط لا *',
    CODE.includes('const REG_LIST_COLS') && !/REG_LIST_COLS[\s\S]{0,200}products_services/.test(CODE));
  T('تصدير التسجيلات يتجاوز سقف PostgREST بالصفحات',
    CODE.includes('async function regFetchAll') && !/from\(REG_TABLE\)\.select\('\*'\)\.order\('submitted_at', \{ascending: false\}\);/.test(CODE));
  T('عدّ الحالات على الخادم لا بجلب آلاف الصفوف',
    /count:\s*'exact',\s*head:\s*true/.test(CODE) && !/select\('status, metrics'\)\.limit\(2000\)/.test(CODE));

  // العارض: نداء بالفهرس (مفتاح باقتباس كان يكسر السمة) وسقف ذاكرة الـblob
  T('العارض يُنادى بالفهرس لا بمفتاح نصّيّ داخل السمة',
    /function docvFromReg\(idx\)/.test(CODE) && !/docvFromReg\('\$\{/.test(CODE));
  T('ذاكرة الـblob مسقوفة (13 وثيقة × 10MB لا تبقى كلّها)',
    /while \(DOCV\.urls\.size >= \d+\)/.test(CODE) && /revokeObjectURL/.test(CODE));
  T('نوع المستند يُشتقّ من الامتداد بدقّة',
    api.docvKind('a/b/c.PDF') === 'pdf' && api.docvKind('x.png') === 'img' &&
    api.docvKind('x.docx') === 'other' && api.docvKind('') === 'other');
  T('قائمة المستندات تتجاهل المسارات الفارغة',
    api.docvListFromReg({doc_paths:{cr:'a.pdf', vat:'', gosi:null}}).length === 1);
  T('اسم المستند يسقط للمفتاح عند غياب ترجمته',
    api.docvLabel('cr') === 'السجل التجاري' && api.docvLabel('zzz') === 'zzz');

  // سعة التخزين تُقاس فعليّاً لا تُخمَّن
  T('تنسيق الأحجام صحيح',
    api.regFmtBytes(0) === '0 B' && api.regFmtBytes(1536) === '1.5 KB' &&
    api.regFmtBytes(9 * 1024 ** 3).startsWith('9 GB'));
  T('لوحة قياس السعة موجودة وتقارن بخطط التخزين',
    CODE.includes('async function regMeasureStorage') && /REG_PLAN_LIMITS/.test(CODE) &&
    HTML.includes('id="reg-capacity"') && CODE.includes("storage.from(REG_BUCKET).list("));
}

/* ── 14) متابعة مستندات الموردين + تخزين R2 ──────────────────── */
{
  G('١٤) متابعة مستندات الموردين · تخزين R2');
  const day = 86400000, iso = (d) => new Date(Date.now() + d*day).toISOString().slice(0,10);
  const full = {cr:'a.pdf', vat:'b.pdf', gosi:'c.pdf', chamber:'d.pdf', natl_addr:'e.pdf', iban_cert:'f.pdf'};

  const ok = api.supDocRow({id:'DG-1', legal_name_ar:'مورد كامل', doc_paths:full,
    cr_expiry_date: iso(400), chamber_expiry: iso(300)});
  T('المكتمل: 6/6 بلا نواقص', ok.present === 6 && ok.missing.length === 0);
  T('المكتمل السارية شهاداته لا يحتاج متابعة', !api.supDocNeedsAction(ok) && !ok.expired && !ok.soon);

  const miss = api.supDocRow({id:'DG-2', legal_name_ar:'ناقص', doc_paths:{cr:'a.pdf', vat:'b.pdf'}});
  T('يعُدّ النواقص بأسمائها', miss.present === 2 && miss.missing.length === 4 &&
    miss.missing.includes('شهادة التأمينات') && miss.missing.includes('شهادة الآيبان'));
  T('الناقص يحتاج متابعة', api.supDocNeedsAction(miss));

  const expd = api.supDocRow({id:'DG-3', legal_name_ar:'منتهٍ', doc_paths:full, cr_expiry_date: iso(-5)});
  T('المنتهي يُرصد وإن اكتملت وثائقه', expd.expired && !expd.soon && api.supDocNeedsAction(expd));

  const soon = api.supDocRow({id:'DG-4', legal_name_ar:'يقارب', doc_paths:full, cr_expiry_date: iso(12)});
  T('المقارب للانتهاء يُرصد', soon.soon && !soon.expired && api.supDocNeedsAction(soon));
  T('عتبة القرب 30 يوماً',
    api.supDocRow({id:'x', doc_paths:full, cr_expiry_date: iso(45)}).soon === false &&
    api.supDocRow({id:'x', doc_paths:full, cr_expiry_date: iso(29)}).soon === true);

  T('بلا تواريخ ⇒ لا إنذار صلاحية (ولا يُعَدّ منتهياً)',
    !api.supDocRow({id:'x', doc_paths:full}).expired && !api.supDocRow({id:'x', doc_paths:full}).soon);
  T('الأسوأ هو الحاكم عند تاريخين',
    api.supDocRow({id:'x', doc_paths:full, cr_expiry_date: iso(400), chamber_expiry: iso(-3)}).expired);
  T('الوثائق الإلزامية الستّ هي مرجع العدّ',
    api.SUP_REQUIRED_DOCS.length === 6 && api.SUP_EXPIRY_SOON_DAYS === 30);

  /* ── ما يُطلَب تجديده: أساس بريد التجديد (مفاتيح لا أسماء) ── */
  T('الصفّ المكتمل السارية شهاداته لا يطلب تجديداً',
    api.supDocRow({id:'x', doc_paths:full, cr_expiry_date: iso(400), chamber_expiry: iso(400)}).renew.length === 0);
  T('الشهادة المنتهية تُدرَج للتجديد بمفتاحها',
    api.supDocRow({id:'x', doc_paths:full, cr_expiry_date: iso(-5)}).renew.join() === 'cr');
  T('المقاربة على الانتهاء تُدرَج أيضاً',
    api.supDocRow({id:'x', doc_paths:full, chamber_expiry: iso(12)}).renew.join() === 'chamber');
  {
    const r = api.supDocRow({id:'x', doc_paths:{cr:'a.pdf'}, cr_expiry_date: iso(-2)});
    T('الوثيقة الناقصة تُطلَب من المورّد كذلك (بلا تكرار)',
      r.renew.includes('vat') && r.renew.includes('iban_cert') && r.renew.includes('cr') &&
      r.renew.length === new Set(r.renew).size);
  }
  /* الشهادة المُعلَنة بلا مرفق أو بلا تاريخ: ليست في الوثائق الإلزامية فلا يلتقطها
     فحص النواقص — وهي الحالة الفعلية لسبع شهادات فُقدت بعيب القائمة البيضاء. */
  {
    const declaredNoFile = api.supDocRow({id:'x', doc_paths:full, local_content_has:true});
    const declaredNoDate = api.supDocRow({id:'x', doc_paths:{...full, local_content:'p.pdf'}, local_content_has:true});
    const complete = api.supDocRow({id:'x', doc_paths:{...full, local_content:'p.pdf'},
                                    local_content_has:true, local_content_expiry: iso(300)});
    const notDeclared = api.supDocRow({id:'x', doc_paths:full});
    T('شهادة محتوى محلي مُعلَنة بلا مرفق ⇒ نقص يُطلَب تجديده',
      declaredNoFile.lcGap === true && declaredNoFile.renew.includes('local_content') &&
      api.supDocNeedsAction(declaredNoFile));
    T('مُعلَنة بمرفق وبلا تاريخ ⇒ نقص أيضاً',
      declaredNoDate.lcGap === true && declaredNoDate.renew.includes('local_content'));
    T('مكتملة (مرفق + تاريخ سارٍ) ⇒ لا نقص',
      complete.lcGap === false && !complete.renew.includes('local_content'));
    T('من لم يُعلِن شهادة لا يُطالَب بها',
      notDeclared.lcGap === false && !notDeclared.renew.includes('local_content') &&
      !api.supDocNeedsAction(notDeclared));
  }
  T('بريد المراسلة يُقرأ من الصفّ (الأولوية لمسؤول التواصل)',
    api.supDocRow({id:'x', doc_paths:full, contact_email:'a@b.com', email:'c@d.com'}).email === 'a@b.com' &&
    api.supDocRow({id:'x', doc_paths:full, email:'c@d.com'}).email === 'c@d.com');

  /* ── تحديد مَن أرفق شهادة المحتوى المحلي (طلب المالك 2026-09-07) ──────────
     القياس على الإنتاج: 8 مورّدين أعلنوها ورقم الشهادة والنسبة محفوظان لهم جميعاً،
     بينما المرفق موجود لواحد فقط. فالفصل الثلاثيّ (معلَن / مُرفَق / بيانات) واجب —
     ولا يجوز أن يُخفي «غير معلَن» و«معلَن بلا مرفق» بعضهما. */
  {
    const withFile = api.supDocRow({id:'x', doc_paths:{...full, local_content:'lc.pdf'},
      local_content_has:true, local_content_percentage:'61.00', local_content_cert_no:'M207667'});
    const noFile = api.supDocRow({id:'y', doc_paths:full,
      local_content_has:true, local_content_percentage:'25.67', local_content_cert_no:'7018067004'});
    const none = api.supDocRow({id:'z', doc_paths:full});
    T('المُرفِق يُميَّز عن المُعلِن بلا مرفق',
      withFile.lcFile === true && noFile.lcFile === false &&
      withFile.lcDeclared === true && noFile.lcDeclared === true);
    T('النسبة ورقم الشهادة يُقرآن حتى بلا مرفق (محفوظان على الإنتاج)',
      noFile.lcPct === 25.67 && noFile.lcCert === '7018067004' && withFile.lcPct === 61);
    T('من لم يُعلِن: لا نسبة ولا رقم ولا مرفق',
      none.lcDeclared === false && none.lcFile === false && none.lcPct === null && none.lcCert === '');
    T('عمودا رقم الشهادة والنسبة يُجلبان من القاعدة (وإلّا فرغت الخلية)',
      /BASE_COLS[\s\S]{0,400}local_content_cert_no,local_content_percentage/.test(CODE));
    T('مرشّح «شهادة محتوى محلي» يعرض كل من أعلنها لا المُرفِقين فقط',
      /lc:\s*all\.filter\(r => r\.lcDeclared\)/.test(CODE) && /tab\('lc'/.test(CODE));
    T('خلية المحتوى المحلي تفصل «مُرفَقة» عن «معلَنة — بلا مرفق»',
      /const lcCell/.test(CODE) && /✓ مُرفَقة/.test(CODE) && /معلَنة — بلا مرفق/.test(CODE) &&
      /lcCell\(r\)/.test(CODE));
    T('بطاقة المورد تُظهر المحتوى المحلي حتى بلا تاريخ انتهاء',
      /supExpiryStrip[\s\S]{0,1400}lcChip/.test(CODE) && /محتوى محلي بلا مرفق/.test(CODE));
    /* شاشة تفاصيل الطلب كانت تحذف صفّ «المستند» عند غيابه (القيمة null) فيبدو
       القسم مكتملاً بينما الشهادة غير محفوظة — بلاغ المالك الفعليّ. */
    T('تفاصيل الطلب تُعلن نقص مرفق الشهادة صراحةً لا بحذف الصفّ',
      (CODE.match(/⚠️ غير مرفق — لم تُحفَظ نسخة الشهادة/g) || []).length >= 2 &&
      !/\['المستند', \(r\.doc_paths && r\.doc_paths\.local_content\) \? '[^']*' : null\]/.test(CODE));
  }

  /* ── ترتيب الإلحاح: ما يستحقّ التصرّف الآن أعلى الجدول ── */
  {
    const rows = [
      api.supDocRow({id:'A', legal_name_ar:'سليم', doc_paths:full, cr_expiry_date: iso(400)}),
      api.supDocRow({id:'B', legal_name_ar:'ناقص', doc_paths:{cr:'a'}}),
      api.supDocRow({id:'C', legal_name_ar:'منتهٍ', doc_paths:full, cr_expiry_date: iso(-9)}),
      api.supDocRow({id:'D', legal_name_ar:'يقارب', doc_paths:full, cr_expiry_date: iso(11)}),
    ];
    const order = api.supDocSort(rows).map(r => r.id).join('');
    T('الترتيب: منتهٍ ← يقارب ← ناقص ← سليم', order === 'CDBA', order);
    T('الفرز لا يُغيّر المصفوفة الأصلية', rows.map(r=>r.id).join('') === 'ABCD');
    T('الجدول يعرض القائمة مرتّبة بالإلحاح', /const list = supDocSort\(/.test(CODE));
  }

  /* ── فحص سلامة الوثائق: المؤشّر قد يشير لملف غير موجود والعدّاد يقول «6/6» ── */
  T('فحص السلامة يسأل المخزنَين ولا يحكم بالفقد إلا بخيبتهما',
    /async function supDocPathExists/.test(CODE) &&
    /supDocPathExists[\s\S]{0,700}api\/reg-doc\?meta=1/.test(CODE) &&
    /supDocPathExists[\s\S]{0,900}createSignedUrl/.test(CODE) &&
    /return 'missing'/.test(CODE));
  T('الفحص وجود فقط — لا تنزيل بايتات', /meta=1&key=/.test(CODE));
  T('زرّ الفحص مربوط ونتيجته تُعرض في اللوحة',
    /id="supdoc-verify-btn"[\s\S]{0,200}supDocVerify\(\)/.test(CODE) ||
    /supDocVerify\(\)[\s\S]{0,200}id="supdoc-verify-btn"/.test(CODE));
  T('المكسور يُعرَض بزرّ طلب تجديد مباشر (لا تشخيص بلا علاج)',
    /supDocVerify[\s\S]{0,2600}supDocRenew\('/.test(CODE));
  T('الفحص محدود التزامن فلا يُغرق الشبكة', /const CONC = \d+;/.test(CODE));

  /* ── حملة شهادة المحتوى المحلي ── */
  {
    const mk = (o) => api.supDocRow({id:'x', doc_paths:{cr:'a',vat:'b',gosi:'c',chamber:'d',natl_addr:'e',iban_cert:'f'},
      contact_email:'a@b.com', ...o});
    const has  = mk({ doc_paths:{cr:'a',local_content:'lc.pdf'}, local_content_has:true });
    const none = mk({ local_content_has:false, local_content_none_at:'2026-09-07T10:00:00Z' });
    const regNo = mk({ local_content_has:false });   // «لا» في نموذج التسجيل فقط
    const unknown = mk({});
    T('أربع حالات: مُرفِق · أفاد رداً على الحملة · «لا» بالتسجيل · لم يُجب',
      has.lcFile === true && none.lcAnswered === true &&
      regNo.lcNone === true && regNo.lcAnswered === false &&
      unknown.lcUnknown === true && unknown.lcAnswered === false);
    T('«لا» بالتسجيل تبقى ضمن المستهدَفين (قد يكون حصل عليها بعدها)',
      regNo.lcAnswered === false && has.lcFile === true && none.lcAnswered === true);
    T('وقت الإفادة يُقرأ فيظهر في السجلّ', none.lcNoneAt === '2026-09-07T10:00:00Z');
    /* ⚠️ تصحيح المالك: «الجميع» تعني كل المعتمدين — و«لا» في نموذج التسجيل ليست
       إجابةً على سؤال الحملة (قد يكون حصل على الشهادة بعد تسجيله). الاستثناء
       الوحيد المشروع: من رفع شهادته، أو أفادنا بعدمها **رداً على الحملة**. */
    T('الحملة تسأل الجميع — لا تستثني «لا» نموذج التسجيل',
      /supDocLcTargets[\s\S]{0,260}!r\.lcFile && !r\.lcAnswered/.test(CODE) &&
      !/supDocLcTargets[\s\S]{0,260}!r\.lcNone/.test(CODE));
    T('الإفادة رداً على الحملة وحدها تحسم السؤال',
      /const lcAnswered = !!reg\.local_content_none_at/.test(CODE));
    T('الإرسال بتأكيد صريح بالعدد ومُباعَد (بريد خارجيّ لموردين حقيقيين)',
      /supDocLcCampaign[\s\S]{0,2200}confirm\(/.test(CODE) &&
      /supDocLcCampaign[\s\S]{0,2600}setTimeout\(z, 350\)/.test(CODE));
    /* ملاحظة المالك: «المؤشّر موجود» ≠ «الشهادة محفوظة» — 7 شهادات فُقدت فعلاً،
       ومؤشّر معطوب كان سيستثني صاحبها فلا يُسأل عن شهادته الضائعة أبداً. */
    T('الاستثناء بالتحقّق من وجود الملف لا بوجود المؤشّر',
      /async function supDocLcTargetsVerified/.test(CODE) &&
      /supDocLcTargetsVerified[\s\S]{0,700}await supDocPathExists\(path\)\) !== 'missing'/.test(CODE) &&
      /supDocLcCampaign[\s\S]{0,400}await supDocLcTargetsVerified\(\)/.test(CODE));
    T('صاحب الشهادة المفقودة يُدرَج في الحملة لا يُستثنى',
      /broken\.push\(r\); out\.push\(r\)/.test(CODE));
    T('تعذّر الفحص لا يُزعج المورّد (يُعامَل كموجود)',
      /catch\(e\)\{ ok = true; \}/.test(CODE));
    T('الحملة تمرّر الغرض للخادم فيختار القالب الصحيح',
      /supDocRenewSend\(r\.id, \['local_content'\], 'local_content'\)/.test(CODE) &&
      /purpose: purpose \|\| undefined/.test(CODE));
    /* دفعة التجديد السابقة (2026-09-07) وصلت **مرّتين** إلى 7 موردين لأن الزرّ
       ضُغِط مرّتين بفارق 40 ثانية — مُثبَت في سجلّ Resend. الحارس يمنع تكرارها. */
    T('منع التكرار: من وصلته الحملة خلال 14 يوماً يُستثنى',
      /async function supDocLcSentRecently/.test(CODE) &&
      /eq\('new_value->>stage','lc_campaign'\)/.test(CODE) &&
      /supDocLcCampaign[\s\S]{0,900}alreadySent\.has\(r\.id\)/.test(CODE));
    T('الخادم يسم إرسال الحملة في التدقيق (أساس منع التكرار)',
      /stage: isLc \? 'lc_campaign' : undefined/.test(
        fs.readFileSync(path.join(ROOT, 'functions/api/doc-renew.js'), 'utf8')));
    T('تعذّر قراءة التدقيق لا يمنع الإرسال (فشل مفتوح مقصود للتنبيه لا للحجب)',
      /supDocLcSentRecently[\s\S]{0,700}catch\(e\)\{[^}]*\}\s*\n\s*return out;/.test(CODE));
    T('خلية «لا توجد — بإفادتهم» تُميَّز عن «لم يُجب»',
      /لا توجد — بإفادتهم/.test(CODE) && /لم يُجب المورّد بعد/.test(CODE));
    T('سجلّ المورد يعرض الإفادة صراحةً',
      (CODE.match(/أفاد بعدم وجود شهادة محتوى محلي/g) || []).length >= 2);
    T('عمود الإفادة يُجلب من القاعدة', /local_content_expiry,local_content_none_at/.test(CODE));
  }
  {
    const RN = fs.readFileSync(path.join(ROOT, 'renew-doc.html'), 'utf8');
    T('صفحة المورّد تطلب رقم الشهادة والنسبة مع الملف',
      /d\.extra\|\|\[\]/.test(RN) && /x-\$\{i\}-\$\{esc\(f\.name\)\}/.test(RN) &&
      /extraQs\.push/.test(RN));
    T('التحقّق المحلّي يمنع رحلة فاشلة (نسبة 0–100 وحقل مطلوب)',
      /رقماً بين 0 و100/.test(RN) && /أدخل ' \+ f\.label/.test(RN));
    T('زرّ «لا توجد شهادة» موجود ومربوط بنقطة الإفادة',
      /btn-none/.test(RN) && /declare=none/.test(RN) && /async function declareNone/.test(RN));
    T('رفع الشهادة يُخفي زرّ الإفادة (لا تناقض)', /noneBox\.style\.display = 'none'/.test(RN));
  }
  {
    const API = fs.readFileSync(path.join(ROOT, 'functions/api/doc-renew.js'), 'utf8');
    T('الخادم يُلزِم الحقول المرافقة ويُثبِت الامتلاك عند الرفع',
      /extra: \[/.test(API) && /setTrue: 'local_content_has'/.test(API) &&
      /patch\[DOC_META\[doc\]\.setTrue\] = true/.test(API));
    T('نقطة الإفادة تمنع إلغاء شهادة مرفوعة فعلاً',
      /async function declareNoLocalContent/.test(API) && /reason: 'has_cert'/.test(API) &&
      /409/.test(API));
    T('قالب الحملة مستقلّ عن قالب التجديد',
      /function localContentEmail/.test(API) && /isLc \? localContentEmail/.test(API));
  }

  // اللوحة مربوطة: تحميل، مرشّحات، فتح بالعارض، بطاقة مهام
  T('لوحة المتابعة مربوطة بالشاشة والعارض',
    CODE.includes('async function loadSupDocs') && CODE.includes('function renderSupDocs') &&
    CODE.includes('function supDocOpen') && HTML.includes('id="supdoc-body"'));
  T('المتابعة تجلب المعتمدين فقط وبالصفحات (لا سقف عارٍ)',
    /loadSupDocs[\s\S]{0,700}regFetchAll\([\s\S]{0,200}eq\('status', 'approved'\)/.test(CODE));
  T('بطاقة مهام للوثائق الناقصة/المنتهية',
    CODE.includes('TASKS.docIssues') && /موردون بوثائق ناقصة أو منتهية/.test(CODE));

  // ── تخزين R2: القراءة المزدوجة والمصادقة ──
  const RD = fs.readFileSync(path.join(ROOT, 'functions/api/reg-doc.js'), 'utf8');
  // العزل يعني ألّا تُستعمل حاوية البوابة كـbinding — ذكرها في تعليق توضيحيّ مقصود.
  T('الرفع يُفضّل R2 عبر binding مستقلّ عن حاوية البوابة',
    /env\.SUPPLIER_DOCS/.test(RD) && /bucket\.put\(path, buf/.test(RD) && !/env\.QUOTES_BUCKET/.test(RD));
  T('الرفع على R2 لا يشترط مفتاح خدمة Supabase',
    /if \(!bucket && !legacyConfigured\(env\)\)/.test(RD));
  T('قراءة الوثيقة من R2 مُصادَقة وفشلها مغلق',
    /async function verifyCaller/.test(RD) && /auth\/v1\/user/.test(RD) &&
    /const user = await verifyCaller\(env, request\);\s*\n\s*if \(!user\) return json\(\{ error: 'غير مصرّح' \}, 401\);/.test(RD));
  T('مسار الوثيقة مُتحقَّق منه (لا اجتياز مسار)',
    /function safeKey/.test(RD) && /includes\('\.\.'\)/.test(RD) && /DOC_ALLOW\.has\(m\[2\]\)/.test(RD));
  T('البثّ بترويسات التحييد المشتركة',
    /fileResponseHeaders/.test(RD) && /import \{ inspectUpload, fileResponseHeaders \}/.test(RD));
  T('حجم الوثيقة يُقرأ بـhead لا ببثّ البايتات', /meta.*===.*'1'[\s\S]{0,200}bucket\.head\(key\)/.test(RD));
  T('الواجهة تقرأ R2 أولاً وتسقط للمخزن القديم',
    CODE.includes('async function regDocFetch') && /\/api\/reg-doc\?key=/.test(CODE) &&
    /r\.status !== 404 && r\.status !== 503/.test(CODE) &&
    /regDocFromLegacy[\s\S]{0,900}createSignedUrl/.test(CODE));
  T('كل مسارات الجلب توحّدت على regDocFetch',
    (CODE.match(/regDocFetch\(/g) || []).length >= 3 &&
    !/fetchDocBlob[\s\S]{0,300}createSignedUrl/.test(CODE));
  T('لوحة السعة تقارن بخطط R2',
    /Cloudflare R2 المجاني/.test(CODE) && /gb:10/.test(CODE) && CODE.includes('async function regDocSize'));
}

/* ── جلب الوثيقة عبر المخزنَين — اختبار **سلوكيّ** (بلاغ إنتاج 2026-09-07) ──
   منذ ميزة التجديد صار المورّد الواحد مختلط المخزنَين: القديم على Supabase
   والمُجدَّد على R2. الحرّاس النصّية لم تلتقط ذلك، فهذه تُشغِّل `regDocFetch`
   فعلاً على شبكة مُقلَّدة. ⚠️ لا تُبدِّلها بفحص نصّيّ. */
await (async () => {
  const OLD = 'DG-MIX001/cr/old.pdf', NEW = 'DG-MIX001/chamber/new-uuid.pdf';
  const realFetch = globalThis.fetch;
  // شبكة مُقلَّدة: R2 يحمل ما في r2Set · المخزن القديم يحمل ما في legacySet
  const wire = (r2Set, legacySet, opts = {}) => {
    const calls = { r2: [], sign: [] };
    globalThis.fetch = async (u) => {
      const s = String(u);
      if (s.startsWith('/api/reg-doc')) {
        const key = decodeURIComponent(new URL(s, 'http://x').searchParams.get('key') || '');
        calls.r2.push(key);
        if (opts.r2Status) return new Response('{}', { status: opts.r2Status });
        return r2Set.has(key) ? new Response('R2:' + key, { status: 200 })
                              : new Response('{}', { status: 404 });
      }
      if (s.startsWith('legacy://')) return new Response('LEGACY:' + s.slice(9), { status: 200 });
      return new Response('{}', { status: 500 });
    };
    api.window.CLOUD = { enabled: true, client: {
      auth: { getSession: async () => ({ data: { session: { access_token: 'jwt' } } }) },
      storage: { from: () => ({
        createSignedUrl: async (path) => { calls.sign.push(path);
          return legacySet.has(path) ? { data: { signedUrl: 'legacy://' + path } }
                                     : { error: { message: 'Object not found' } }; },
      }) },
    } };
    api.REGDOC_R2_MISS.clear(); api.REGDOC_LEGACY_HINT.clear(); api.REGDOC_SIGNED.clear();
    return calls;
  };
  const text = async (pr) => { try { return await (await pr).text(); } catch (e) { return 'ERR:' + e.message; } };
  try {
    // (1) العلّة نفسها: وثيقة قديمة ثمّ وثيقة مُجدَّدة لنفس المورّد
    let c = wire(new Set([NEW]), new Set([OLD]));
    const oldRes = await text(api.regDocFetch(OLD));
    const newRes = await text(api.regDocFetch(NEW));
    T('الوثيقة القديمة تُفتح من المخزن القديم', oldRes === 'LEGACY:' + OLD, oldRes);
    T('الوثيقة المُجدَّدة تُفتح من R2 رغم أنّ وثيقة سابقة للمورّد نفسه ليست عليه',
      newRes === 'R2:' + NEW, newRes);
    T('R2 سُئل عن المسار المُجدَّد (لم يحجبه كاش التسجيل)', c.r2.includes(NEW), JSON.stringify(c.r2));

    // (2) التحسين محفوظ: تسجيل كلّه قديم ⇒ رحلة R2 واحدة مهما تعدّدت وثائقه
    const olds = ['DG-OLD002/cr/a.pdf', 'DG-OLD002/vat/b.pdf', 'DG-OLD002/gosi/c.pdf'];
    c = wire(new Set(), new Set(olds));
    for (const p of olds) await text(api.regDocFetch(p));
    T('تسجيل كلّه قديم ⇒ رحلة R2 واحدة لا ثلاث (التلميح يحفظ التحسين)',
      c.r2.length === 1, c.r2.length + ' رحلة');

    // (3) تسجيل كلّه على R2 ⇒ لا سكّ روابط للمخزن القديم إطلاقاً
    const news = ['DG-NEW003/cr/a.pdf', 'DG-NEW003/vat/b.pdf'];
    c = wire(new Set(news), new Set());
    for (const p of news) await text(api.regDocFetch(p));
    T('تسجيل كلّه على R2 ⇒ صفر سكّ روابط للمخزن القديم', c.sign.length === 0, JSON.stringify(c.sign));

    // (4) خطأ حقيقيّ (لا 404/503) يُرمى ولا يُخفى بسقوط صامت
    c = wire(new Set(), new Set([OLD]), { r2Status: 401 });
    T('خطأ R2 حقيقيّ (401) يُرمى لا يُبتلع', (await text(api.regDocFetch(OLD))).startsWith('ERR:'));

    // (5) مفقود في المخزنَين ⇒ رسالة واضحة بعد تجربتهما معاً
    c = wire(new Set(), new Set());
    const gone = await text(api.regDocFetch('DG-GONE04/cr/x.pdf'));
    T('المفقود في المخزنَين يُبلَّغ بوضوح بعد تجربتهما', /ERR:.*مخزن النظام/.test(gone), gone);
    T('وقد جُرِّب المخزنان فعلاً قبل الإخفاق', c.r2.length === 1 && c.sign.length === 1);
  } finally { globalThis.fetch = realFetch; api.window.CLOUD = null; }
})();

/* ── ١٥) تجديد المستندات المنتهية ببريد ورابط رفع ──────────────
   قرار المالك (2026-09-07): «يُرسَل بريد من Resend برفع المستند الجديد بتاريخه
   الجديد واستبدال القديم». الحرّاس هنا على الربط والعقد — والسلوك الخادميّ
   مُختبَر في `db/portal-tests/file-guard.test.mjs` (20 تأكيداً). */
{
  const RENEW_API = fs.readFileSync(path.join(ROOT, 'functions/api/doc-renew.js'), 'utf8');
  const RENEW_PAGE = fs.readFileSync(path.join(ROOT, 'renew-doc.html'), 'utf8');

  T('زرّ طلب التجديد في صفّ المتابعة مربوط بالنقطة',
    CODE.includes('async function supDocRenew(') && CODE.includes('async function supDocRenewSend(') &&
    /supDocRenew\('/.test(CODE) && /fetch\('\/api\/doc-renew'/.test(CODE));
  T('الإرسال الجماعي للتصنيف المعروض موجود ومربوط',
    CODE.includes('async function supDocRenewAll(') && /supDocRenewAll\(\)/.test(CODE));
  T('الطلب يحمل رمز جلسة الموظّف (لا نقطة مفتوحة)',
    /supDocRenewSend[\s\S]{0,900}Authorization:\s*'Bearer '/.test(CODE));
  T('المتابعة تجلب بريد المورّد كي يُرسَل إليه',
    /loadSupDocs[\s\S]{0,700}contact_email,email/.test(CODE));

  // العقد الخادميّ: تاريخ لكل وثيقة في عمودها الصحيح، ولا حذف لأي ملف.
  T('عمودا الانتهاء مربوطان بالوثيقتين الصحيحتين',
    /cr:\s*\{[^}]*expiryCol:\s*'cr_expiry_date'/.test(RENEW_API) &&
    /chamber:\s*\{[^}]*expiryCol:\s*'chamber_expiry'/.test(RENEW_API));
  T('التجديد لا يحذف أي ملف مورّد (استبدال منطقيّ)',
    !/\.delete\(/.test(RENEW_API) && !/method:\s*'DELETE'/.test(RENEW_API) && !/storage\/v1\/object\/list/.test(RENEW_API));
  T('الرفع يمرّ بحارس الملفات الطبقي',
    RENEW_API.includes("from './_file-guard.js'") && /inspectUpload\(buf\)/.test(RENEW_API));
  T('الرمز موقَّع ويُتحقَّق منه بمقارنة ثابتة الزمن',
    RENEW_API.includes('function timingSafeEq') && /HMAC/.test(RENEW_API) &&
    /verifyToken/.test(RENEW_API));
  T('حاوية البوابة ممنوعة في نقطة التجديد (فصل الأنظمة)',
    !/env\.QUOTES_BUCKET/.test(RENEW_API) && RENEW_API.includes('env.SUPPLIER_DOCS'));

  /* ⚠️ رأس الجدول الداكن (بلاغ المالك 2026-09-07): القاعدتان العامّتان
     `th{color:var(--ink-2)}` و`td{color:var(--ink-2)}` **تتغلّبان على اللون
     المورَّث من `<tr>`** (مُحدِّد العنصر يسبق الوراثة، ولو كانت من نمط سطريّ
     على الأب)، فيصير عنوان العمود شبه أسود على كحليّ ولا يُقرأ نهاراً.
     مقيس في Chromium: بلا العلاج `rgb(58,51,48)`، ومعه أبيض.
     الحارس **يحسب الإضاءة** ولا يعتمد قائمة ألوان مثبَّتة — فأي صفّ داكن
     جديد يُضاف بلا تغطية يُفشِل البناء. */
  {
    // ⚠️ الملف فيه أكثر من كتلة <style> (كتلة الخطوط أوّلاً) — فلا تقصّ عند أوّل إغلاق.
    // ولا تمسح 2.4MB بتعبير نمطيّ مفتوح (تراجع كارثيّ): اقتطع حول موضع القاعدة.
    const at = HTML.indexOf('tr.thead-navy');
    const rule = at < 0 ? '' : HTML.slice(at, HTML.indexOf('}', at) + 1);
    const lum = h => {
      const n = parseInt(h.slice(1), 16);
      return (0.2126 * ((n >> 16) & 255) + 0.7152 * ((n >> 8) & 255) + 0.0722 * (n & 255)) / 255;
    };
    const darkRows = [...HTML.matchAll(/<tr\b[^>]*>/g)].map(m => m[0]).filter(tag => {
      const st = (tag.match(/style="([^"]*)"/) || [, ''])[1];
      if (!/background/.test(st)) return false;
      return (st.match(/#[0-9a-fA-F]{6}/g) || []).some(h => lum(h) < 0.4);
    });
    const uncovered = darkRows.filter(tag => {
      if (/class="[^"]*thead-navy/.test(tag)) return false;
      const st = (tag.match(/style="([^"]*)"/) || [, ''])[1];
      return !(st.match(/#[0-9a-fA-F]{6}/g) || []).some(h =>
        rule.toLowerCase().includes(`tr[style*="${h.toLowerCase()}"]`));
    });
    T('قاعدة الصفوف الداكنة موجودة وتُعيد اللون المورَّث (color:inherit) لـth وtd',
      /tr\.thead-navy th/.test(rule) && /tr\.thead-navy td/.test(rule));
    T(`كل صفّ داكن مُغطّى بالقاعدة (${darkRows.length} صفّاً · بلا تغطية: ${uncovered.length})`,
      darkRows.length >= 4 && uncovered.length === 0);
  }

  /* ⚠️ الجذر الذي أنتج عيب «شهادة المحتوى المحلي» (2026-09-07): قائمة الوثائق
     في `register.html` وقائمة الخادم البيضاء تنفصلان بصمت، فيُرفَض الرفع 400
     و`register.html` يعامله رفضاً نهائيّاً ⇒ الوثيقة تُفقد. هذا التأكيد يستخرج
     **كل** معرّفات الوثائق من نموذج التسجيل (المصفوفتان + أي `fi-<id>` مستقلّ)
     ويُلزِم وجودها في `reg-doc.js` — فأي وثيقة جديدة تُنسى تُفشِل البناء. */
  {
    const REG_PAGE = fs.readFileSync(path.join(ROOT, 'register.html'), 'utf8');
    const REG_API = fs.readFileSync(path.join(ROOT, 'functions/api/reg-doc.js'), 'utf8');
    const listed = [...REG_PAGE.matchAll(/\{\s*id:\s*'([a-z_]+)'\s*,\s*name:/g)].map(m => m[1]);
    const standalone = [...REG_PAGE.matchAll(/id="fi-([a-z_]+)"/g)].map(m => m[1]);
    const docIds = [...new Set([...listed, ...standalone])];
    const allowBlock = (REG_API.match(/const DOC_ALLOW = new Set\(\[([\s\S]*?)\]\)/) || [])[1] || '';
    const allowed = new Set([...allowBlock.matchAll(/'([a-z_]+)'/g)].map(m => m[1]));
    const missing = docIds.filter(d => !allowed.has(d));
    T('كل وثيقة في نموذج التسجيل موجودة في القائمة البيضاء للخادم',
      docIds.length >= 12 && missing.length === 0, missing.join('، '));
    T('شهادة المحتوى المحلي مقبولة رفعاً وعرضاً وتجديداً',
      allowed.has('local_content') && /local_content:\s*\{/.test(RENEW_API));
  }
  /* عمود تاريخ الشهادة ترقية اختيارية: يجب أن يعمل النظام قبلها وبعدها. */
  T('تاريخ المحتوى المحلي يسقط بهدوء إن لم تُشغَّل الترقية',
    /OPTIONAL_COLS = \['local_content_expiry'\]/.test(RENEW_API) &&
    /optionalCol: true/.test(RENEW_API) && /expiry_saved/.test(RENEW_API) &&
    /rows = await regFetchAll\(BASE_COLS,/.test(CODE));
  T('سقف يوميّ للرفع يمنع إغراق المخزن برابط مسرَّب',
    /MAX_UPLOADS_PER_DAY/.test(RENEW_API) && /recentUploadCount/.test(RENEW_API) &&
    /rate_limited/.test(RENEW_API));
  T('رفع المورّد يُشعِر المراجعين داخل النظام (لا يمرّ صامتاً)',
    /function notifyReviewers/.test(RENEW_API) && /proc_notifications/.test(RENEW_API) &&
    /can_review_registrations/.test(RENEW_API));
  T('الإرسال الجماعي مُباعَد (حدّ معدّل مزوّد البريد)',
    /supDocRenewAll[\s\S]{0,900}setTimeout\(z, 350\)/.test(CODE));
  /* التذكير المجدوَل: يعمل بلا تدخّل، ولا يُرسل مرّتين لنفس المرحلة، ولا يُفتح لأحد. */
  T('نقطة التذكير المجدوَل محميّة بسرّ الكرون',
    /sweep=1/.test(RENEW_API) && /CRON_SECRET/.test(RENEW_API) &&
    /timingSafeEq\(given, secret\)/.test(RENEW_API));
  T('مراحل التذكير 30/14/7 ثم دوريّاً بعد الانتهاء',
    /function stageFor/.test(RENEW_API) && /'d30'/.test(RENEW_API) &&
    /'d14'/.test(RENEW_API) && /'d7'/.test(RENEW_API) && /'exp'/.test(RENEW_API));
  T('منع التكرار بوسم المرحلة في سجلّ التدقيق (بلا جدول جديد)',
    /sentKeys\.has\(row\.id \+ ':' \+ stage\)/.test(RENEW_API) && /stage: d\.stage/.test(RENEW_API));
  T('خانق يمنع تشغيلتين في اليوم وسقف لكل تشغيلة',
    /SWEEP_MIN_HOURS/.test(RENEW_API) && /throttled/.test(RENEW_API) &&
    /SWEEP_MAX_PER_RUN/.test(RENEW_API));
  /* النبضة الكسولة: التذكير يعمل بلا مُشغِّل كرون خارجيّ — أوّل موظّف مخوَّل
     يفتح النظام في اليوم يُنبّه الخادم. إزالة أيّ من طرفَيها تُعيد النظام
     لانتظار كرون قد لا يُربَط أبداً، فيصمت التذكير بلا إنذار. */
  T('نبضة الموظّف مسار تصريح ثانٍ للكنسة (تُغني عن الـWorker)',
    /by = 'staff'/.test(RENEW_API) && /sameOrigin\(request\) && await verifyStaff/.test(RENEW_API));
  T('نبضة الموظّف لا تتجاوز الخانق (force للكرون وحده)',
    /force'\) === '1' && by === 'cron'/.test(RENEW_API));
  T('الواجهة تُطلق النبضة لحاملي مراجعة التسجيلات فقط وبصمت',
    /function docRenewTick/.test(CODE) &&
    /docRenewTick[\s\S]{0,400}hasPermission\('can_review_registrations'\)/.test(CODE) &&
    /docRenewTick[\s\S]{0,900}fetch\('\/api\/doc-renew\?sweep=1'/.test(CODE));
  T('النبضة مربوطة بمسار الإقلاع (tasksLoadCloud) وإلّا لم تُنادَ أبداً',
    /tasksLoadCloud[\s\S]{0,1600}docRenewTick\(\)/.test(CODE));
  T('بطاقة المهام تقرأ عمود شهادة المحتوى المحلي (وإلّا فات lcGap عدّها)',
    /local_content_has[\s\S]{0,400}regFetchAll\(COLS\+',local_content_expiry'[\s\S]{0,400}TASKS\.docIssues/.test(CODE));

  // صفحة المورّد: عامّة بلا حساب — فلا تُفهرَس، ولا تحمّل أي سكربت خارجيّ (CSP).
  T('صفحة التجديد غير مفهرَسة',
    /name="robots"[^>]*noindex/.test(RENEW_PAGE));
  T('صفحة التجديد بلا أي مصدر خارجيّ (آمنة CSP)',
    !/<script[^>]+src=/i.test(RENEW_PAGE) && !/https?:\/\/(?!suppliers\.aldeyabi\.com)[^"'\s]*\.(js|css)/i.test(RENEW_PAGE));
  T('صفحة التجديد ترفع للنقطة الخادمية لا للتخزين مباشرةً',
    RENEW_PAGE.includes("fetch('/api/doc-renew'") && !/storage\/v1\/object/.test(RENEW_PAGE));
  T('الصفحة تُلزِم تاريخ الانتهاء الجديد للوثائق ذات التاريخ',
    /has_expiry/.test(RENEW_PAGE) && /تاريخ الانتهاء الجديد/.test(RENEW_PAGE));
  /* النقر المزدوج على الجوال كان يرفع الملف مرّتين أو ثلاثاً: التعطيل كان **بعد**
     فحص التوقيع غير المتزامن. القفل الآن قبل أيّ await — ويُحرَس هنا. */
  T('قفل الرفع المزدوج قبل أي await (لا رفع مكرّر بالنقر المتلاحق)',
    /const BUSY = new Set\(\)/.test(RENEW_PAGE) &&
    /if\(BUSY\.has\(i\)\) return;[\s\S]{0,80}BUSY\.add\(i\); btn\.disabled = true;/.test(RENEW_PAGE) &&
    /async function doUpload\(/.test(RENEW_PAGE));
}

/* ══════════════════════════════════════════════════════════════════════════
   قشرة الجوال (بلاغ المالك 2026-09-07: «في الجوال سيء جدًا»)
   ══════════════════════════════════════════════════════════════════════════ */
{
  /* 🐛 الجذر المقيس: لوحة off-canvas مُغلقة تُخفى بـtransform **وحده** تبقى
     تُوسّع عرض المستند القابل للتمرير — كانت الصفحة تنزلق أفقياً 220px في كل
     شاشة بسبب `#po-drawer`. الحارس يمنع عودة النمط لأي لوحة. */
  T('اللوحة المُغلقة لا تُوسّع عرض الصفحة (visibility لا transform وحده)',
    /\.po-drawer:not\(\.active\)\{visibility:hidden\}/.test(HTML) &&
    /\.sidebar:not\(\.open\)\{visibility:hidden\}/.test(HTML));
  T('حزام أمان: لا تمرير أفقيّ للصفحة',
    /html\{overflow-x:clip\}/.test(HTML));

  T('viewport-fit=cover مضبوط (شرط عمل env(safe-area-inset-*))',
    /name="viewport"[^>]*viewport-fit=cover/.test(HTML));
  T('المناطق الآمنة مُحترَمة في الشريطين العلويّ والسفليّ',
    /padding-top:calc\(10px \+ env\(safe-area-inset-top\)\)/.test(HTML) &&
    /\.mnav\{[\s\S]{0,400}padding-bottom:env\(safe-area-inset-bottom\)/.test(HTML));
  T('تطبيق قابل للتثبيت: manifest + أيقونات + ألوان النظام',
    /rel="manifest"/.test(HTML) && /name="theme-color"/.test(HTML) &&
    /apple-mobile-web-app-capable/.test(HTML) &&
    fs.existsSync(path.join(ROOT,'manifest.webmanifest')) &&
    ['icon-192.png','icon-512.png','icon-maskable-512.png','apple-touch-icon.png']
      .every(f => fs.existsSync(path.join(ROOT,'icons',f))));
  {
    const mf = JSON.parse(fs.readFileSync(path.join(ROOT,'manifest.webmanifest'),'utf8'));
    T('المانيفست عربيّ RTL بوضع standalone وأيقونة maskable',
      mf.dir === 'rtl' && mf.lang === 'ar' && mf.display === 'standalone' &&
      mf.icons.some(i => i.purpose === 'maskable'));
  }

  T('شريط تبويبات سفليّ مربوط بالتنقّل ومُزامَن مع الشاشة',
    /class="mnav"/.test(HTML) && /function mnavSync\(/.test(CODE) &&
    /navigate\(btn\.dataset\.mpage\)/.test(CODE) &&
    /function navigate\([\s\S]{0,400}mnavSync\(\)/.test(CODE));
  /* ⚠️ `body.nav-open` هي ما يُجمّد التمرير خلف الدرج المفتوح؛ إسقاطها يُعيد
     تمرير المحتوى تحت الدرج (سلوك يكسر الإحساس بالتطبيق الأصيل). */
  T('الدرج المفتوح يُجمّد تمرير الصفحة خلفه',
    /function navDrawer\(/.test(CODE) &&
    /classList\.toggle\('nav-open'/.test(CODE) &&
    /body\.nav-open\{overflow:hidden\}/.test(HTML));
  T('نقطة تحكّم واحدة للدرج (لا فتح/إغلاق مبعثر)',
    /navDrawer\(true\)/.test(CODE) && /navDrawer\(false\)/.test(CODE) &&
    /function navigate\([\s\S]{0,400}navDrawer\(false\)/.test(CODE));

  /* ⚠️ إخفاء زرّ من الشريط العلويّ على الجوال بلا بديل في الدرج = مستخدم هاتف
     بلا طريق لتسجيل الخروج أو الإعدادات. الحارس يُلزِم البديل لكل مُخفى. */
  {
    const hidden = ['#btn-settings','#btn-goto-portal','#btn-logout','#btn-cloud-reconnect']
      .filter(sel => new RegExp('\\.topbar '+sel.replace('#','#')).test(HTML));
    // القصّ حتى تذييل الشريط: الكتلة فيها divs متداخلة فلا يصلح إغلاق كسول
    const a0 = HTML.indexOf('<div class="sidebar-account">');
    const acct = a0 < 0 ? '' : HTML.slice(a0, HTML.indexOf('<div class="sidebar-footer">', a0));
    T(`كل زرّ مُخفى من الشريط العلويّ له بديل في الدرج (${hidden.length} أزرار)`,
      hidden.length === 4 && hidden.every(sel => acct.includes(`getElementById('${sel.slice(1)}')`)));
  }
  T('هوية المستخدم تُعرَض في الدرج (الشارة العلويّة مخفيّة على الجوال)',
    /id="sa-name"/.test(HTML) && /getElementById\('sa-name'\)/.test(CODE));

  /* الجداول العريضة: حاوية تمرير حولها لا تحويلها إلى block (يُفكّك الأعمدة) */
  T('الجداول العريضة تُلفّ بحاوية تمرير وقت التشغيل',
    /function mobileTableWrap\(/.test(CODE) &&
    /box\.className = 'table-scroll'/.test(CODE) &&
    !/table\{display:block;overflow-x:auto/.test(HTML));
  T('لافّ الجداول مربوط بنقاط الرسم الثلاث (وإلّا فاتته الجداول المولَّدة)',
    (CODE.match(/mobileTableWrap\(/g) || []).length >= 4);
  T('حقول البحث ≥16px فلا يُقرّب iOS الشاشة عند التركيز',
    /\.topbar \.search input\{font-size:16px\}/.test(HTML));

  /* 🐛 عيب وقعتُ فيه فعلاً (2026-09-08): كتبتُ قواعد «النوافذ كأوراق سفليّة» على
     `.modal-box`/`.modal-content` — **وهما غير موجودين** في هذا الملف؛ فلم تُطبَّق،
     والقاعدة الوحيدة التي أصابت (`.modal{align-items:flex-end}`) ضربت **الصندوق**
     لا الغلاف فانكمش رأس كل نافذة (قياس: 260px داخل 345px).
     الحارس يستخرج **كل صنف** في كتلة الجوال ويُلزِم وجوده في الترميز — فأي قاعدة
     تُكتب على اسم متوهَّم تُفشِل البناء بدل أن تمرّ صامتة. */
  {
    // ⚠️ الملف فيه أكثر من كتلة `@media (max-width:900px)` — امسحها كلّها لا الأولى
    let block = '', from = 0, at;
    while ((at = HTML.indexOf('@media (max-width:900px){', from)) > -1){
      let depth = 0, end = at;
      for (let i = HTML.indexOf('{', at); i < HTML.length; i++){
        if (HTML[i] === '{') depth++;
        else if (HTML[i] === '}'){ depth--; if (!depth){ end = i; break; } }
      }
      block += HTML.slice(at, end);
      from = end;
    }
    // أصناف تُنشَأ في الكتلة نفسها أو تُضاف بـJS وقت التشغيل — لا تُطلَب في الترميز الثابت
    const ownClasses = new Set(['mnav','mnav-item','mnav-badge','sidebar-account','sa-who','sa-name',
      'sa-role','sa-actions','sa-btn','danger','table-scroll','nav-open','docv-pdf','docv-page','docv-more',
      'open','active','btn-sm']);
    const used = [...new Set([...block.matchAll(/\.([a-zA-Z][\w-]*)/g)].map(m => m[1]))]
      .filter(c => !ownClasses.has(c));
    // الصنف «حيّ» إن ورد في ترميز ثابت أو أُسنِد وقت التشغيل (className/classList/قالب نصّي)
    const alive = c => new RegExp(`class="[^"]*\\b${c}\\b`).test(HTML)
                    || new RegExp(`className\\s*=\\s*['"\`][^'"\`]*\\b${c}\\b`).test(HTML)
                    || new RegExp(`classList\\.(add|toggle)\\(['"\`]${c}['"\`]`).test(HTML)
                    || new RegExp(`class=\\\\?"[^"]*\\b${c}\\b`).test(HTML);
    const dead = used.filter(c => !alive(c));
    T(`لا مُحدِّد صنف ميّت في كتلة الجوال (${used.length} صنفاً · ميّت: ${dead.join('،') || 'لا شيء'})`,
      used.length > 10 && dead.length === 0);
  }
  T('ورقة النافذة تستهدف الغلاف لا الصندوق (وإلّا انكمش رأسها)',
    /\.modal-overlay\{align-items:flex-end/.test(HTML) &&
    !/\.modal\{align-items:flex-end\}/.test(HTML));
  T('بطاقات المؤشّرات تبقى عمودين على الجوال (لا تُفرَض عموداً)',
    !/\.stats-grid[^}]*grid-template-columns:1fr!important/.test(HTML));
  T('روابط الاتصال هدف لمس مريح على الجوال',
    /a\[href\^="tel:"\][\s\S]{0,120}min-height:40px/.test(HTML));

  /* ⚠️ pdf.js يفتح عاملاً ومخازن صفحات لكل مستند — بلا destroy تتراكم حتى تُقتل
     التبويبة (قياس: 3 وثائق ⇒ 3 عمّال). النقطة الوحيدة للإغلاق محروسة هنا. */
  /* ⚠️ لا تُثبِّت التأكيد على تعليق — `CODE` يُجرّد التعليقات فيفشل دائماً.
     البنية وحدها: الدالة موجودة، وتُنادى داخل الرسم **قبل** getDocument، وداخل الإغلاق. */
  T('مستند PDF السابق يُدمَّر قبل فتح جديد وعند الإغلاق (لا تسريب عمّال)',
    /function docvDestroyPdf\(/.test(CODE) &&
    /DOCV\._pdf\.destroy\(\)/.test(CODE) &&
    /function docvRenderPdf\([\s\S]{0,300}docvDestroyPdf\(\)[\s\S]{0,200}getDocument\(/.test(CODE) &&
    /function docvClose\(\)[\s\S]{0,400}docvDestroyPdf\(\)/.test(CODE));
  T('تصليب pdf.js: eval معطَّل صراحةً',
    /isEvalSupported: false/.test(CODE));

  /* 🐛 بلاغ إنتاج 2026-09-08: «Unexpected server response (0) while retrieving PDF blob:…»
     pdf.js يجلب أي `url` **عبر طبقة الشبكة**، و`connect-src` في CSP الإنتاج لا تسمح
     بـ`blob:` فيُرفَض. اختباري المحلّي مرّ لأنّه كان **بلا ترويسات الإنتاج** — وهذا
     خطأ منهجيّ. العلاج: تمرير البايتات (`data`) فلا طلب شبكة أصلاً.
     ⚠️ الحارس مزدوج: لا `url` في getDocument، **و**`connect-src` تبقى بلا `blob:`
     (فلو عاد أحدهم للرابط انكشف فوراً بدل أن يُخفيه توسيعُ CSP). */
  T('pdf.js يستقبل بايتات لا رابطاً (مناعة من connect-src)',
    /getDocument\(\{[\s\S]{0,80}data: bytes/.test(CODE) &&
    !/getDocument\(\{[\s\S]{0,60}\burl\b\s*[,:]/.test(CODE) &&
    /async function docvBytes\(/.test(CODE) &&
    /blob\.arrayBuffer\(\)/.test(CODE));
  {
    const HEADERS = fs.readFileSync(path.join(ROOT,'_headers'),'utf8');
    const connect = (HEADERS.match(/connect-src([^;]*)/)||[,''])[1];
    T('CSP تبقى مشدّدة — لم نُوسّعها لتمرير blob',
      !/blob:/.test(connect));
  }

  /* 🐛 «يحتاج مزامنة أكثر من مرة ليتصل» — `CLOUD.enabled=true` يُضبط داخل init()
     أي **قبل** وصول البيانات، وحارس إعادة الاتصال شرطه `!CLOUD.enabled`، فلو فشل
     تحميل البيانات على شبكة الجوال بقي «متّصلاً» بلا بيانات ولا يُعيد المحاولة أبداً. */
  T('«متّصل بلا بيانات» حالة معروفة ويُعاد تحميلها تلقائياً',
    /CLOUD\.dataLoaded = false;\s*\n\s*await refreshFromCloud\(\);\s*\n\s*CLOUD\.dataLoaded = true/.test(CODE) &&
    /CLOUD\.dataLoaded === false/.test(CODE));
  T('تعافٍ فوريّ عند عودة الشبكة أو الرجوع للتبويبة (لا انتظار 10 ثوانٍ)',
    /addEventListener\('online', kick\)/.test(CODE) &&
    /visibilitychange[\s\S]{0,60}kick\(\)/.test(CODE) &&
    /function __cloudRetryNow\(/.test(CODE));

  /* «النظام يظهر صغيراً جداً»: التخطيط سليم مقيساً، والسبب خارج سيطرة الصفحة
     (تكبير سفاري المحفوظ / وضع سطح المكتب). الصفحة تقيسه وتقوله بدل التخمين. */
  /* 🐛 «بعض النوافذ بالجوال مضروبة» (بلاغ بلقطة 2026-09-08): جدول «سجلّ المشاريع»
     يعرض «أوامر · القيمة · أزرار» **بلا عمود اسم المشروع**.
     سببان: (أ) اصطلاح `scrollLeft` في حاوية RTL يختلف بين المحرّكات — كروميوم
     يجعل 0 = البداية، وWebKit تاريخيّاً 0 = نهاية المحتوى، فيفتح الجدول على
     الآيفون منزلقاً؛ (ب) لا شيء يُبقي عمود الهوية ظاهراً عند التمرير. */
  T('بداية تمرير RTL مضبوطة بالتحقّق لا بافتراض اصطلاح محرّك',
    /function scrollInlineStart\(/.test(CODE) &&
    /const atStart = \(\)/.test(CODE) &&
    /el\.scrollLeft = el\.scrollWidth/.test(CODE) &&        // اصطلاح WebKit
    /el\.scrollLeft = -\(el\.scrollWidth\)/.test(CODE));    // اصطلاح فَيرفُكس
  T('ضبط بداية التمرير يجري على كل العروض لا الجوال وحده',
    /function mobileTableWrap\(root\)\{[\s\S]{0,200}scrollersToStart\(root\);[\s\S]{0,120}matchMedia/.test(CODE));
  T('عمود الهوية لاصق فلا تبقى أرقام بلا صاحب',
    /table th:first-child,[\s\S]{0,140}position:sticky;inset-inline-start:0/.test(HTML) &&
    /\.prj-wrap table th:first-child/.test(HTML));
  T('حاوية جدول المشاريع مشمولة بقواعد التمرير على الجوال',
    /\.table-scroll,\.table-wrap,\.prj-wrap\{overflow-x:auto/.test(HTML));
  /* النافذة تُعيد رسم محتواها بعد الفتح (تبويب/إجراء)، فاللفّة عند الفتح وحدها تفوت
     كل جدول لاحق — مُراقب مؤجَّل يُعيد الضبط. ⚠️ يراقب childList فقط: مراقبة
     السمات ستُعيد إطلاقه من a11yWire فتدور بلا نهاية. */
  T('إعادة رسم النافذة بعد الفتح تُعيد ضبط الجداول',
    /function modalRenderWatch\(/.test(CODE) &&
    /openModal\([\s\S]{0,180}modalRenderWatch\(el\)/.test(CODE) &&
    /observe\(el, \{ childList:true, subtree:true \}\)/.test(CODE) &&
    !/observe\(el, \{[^}]*attributes:\s*true/.test(CODE));

  T('كشف التصغير يُبلِّغ بالأرقام الفعلية ولا يظهر على عرض سليم',
    /function mobileViewportCheck\(/.test(CODE) &&
    /documentElement\.clientWidth/.test(CODE) && /screen\.width/.test(CODE) &&
    /ratio > 1\.3/.test(CODE) && /id="vp-hint"|id = 'vp-hint'/.test(CODE));

  /* عبور نقطة الانكسار (دوران/طيّ/تغيير حجم) — عيبان مقيسان كانا كامنَين:
     غطاء الدرج يبقى فوق سطح المكتب (قاعدته خارج @media)، والجداول المرسومة
     قبل الدوران تبقى بلا لافّ فيعود الانزلاق (12 جدولاً عارياً · 173px). */
  T('عبور نقطة الانكسار يُغلق الدرج ويُعيد لفّ الجداول',
    /function onBreakpointChange\(/.test(CODE) &&
    /matchMedia\('\(max-width:900px\)'\)\.matches/.test(CODE) &&
    /onBreakpointChange[\s\S]{0,300}navDrawer\(false\)[\s\S]{0,120}mobileTableWrap\(\)/.test(CODE));
  T('يلتقط الدوران لا تغيير الحجم وحده (iOS قد لا يُطلق resize فوراً)',
    /addEventListener\('resize', onBreakpointChange\)/.test(CODE) &&
    /addEventListener\('orientationchange', onBreakpointChange\)/.test(CODE));
  T('الأزرار العائمة فوق شريط التبويبات لا تحته',
    /\.ai-fab,#wf-bell\{bottom:calc\(66px \+ env\(safe-area-inset-bottom\)\)\}/.test(HTML));
}

/* ══════════════════════════════════════════════════════════════════════════
   شهادة المحتوى المحلي: ادّعاء بلا دليل ممنوع (register.html)
   ══════════════════════════════════════════════════════════════════════════ */
{
  const REG = fs.readFileSync(path.join(ROOT,'register.html'),'utf8');
  /* 🐛 الجذر: الشهادة ليست في `REQUIRED_DOCS`، ففشل رفعها كان يمرّ بتنبيه عابر
     ثمّ **يكتمل الإرسال** بـhas=true ورقم ونسبة بلا أي مرفق — وهو ما أنتج
     سبعة موردين «لديهم شهادة» بلا ملف. */
  T('لا يكتمل الإرسال بادّعاء شهادة محتوى محلي بلا مرفق',
    /lc-yes'\)\?\.checked && !docPaths\['local_content'\]/.test(REG) &&
    /toast\('error','لا يمكن إتمام الإرسال — لم يُرفَع مرفق شهادة المحتوى المحلي/.test(REG));
  T('الحارس يقع بعد حلقة الرفع (على المسار الفعليّ لا على النيّة)',
    REG.indexOf("!docPaths['local_content']") > REG.indexOf('const uploadFailures = []'));
  T('التحقّق الأماميّ يُلزِم المرفق أيضاً (رحلة فاشلة أقلّ)',
    /!uploadedDocs\['local_content'\][\s\S]{0,120}يرجى إرفاق شهادة المحتوى المحلي/.test(REG));
}

/* ══════════════════════════════════════════════════════════════════════════
   تركيب قائمة الموردين — لماذا يتغيّر العدد، ولا بطاقات شبح
   سؤال المالك: «كيف أصبح الموردون من 104 إلى 137؟» — الجواب أنّ القائمة دمج
   (سحابة + بذرة إكسل غير مرفوعة)، وأنّ إصلاح قراءة البذرة أعاد الجزء الغائب.
   هذه التأكيدات تحرس: الدمج بالاسم المطبَّع · لا تكرار داخل البذرة · التفكيك.
   ══════════════════════════════════════════════════════════════════════════ */
G('٢٦) تركيب قائمة الموردين');
{
  const seedRows = [
    { name:'شركة الأدوات الصحية', contact:'أحمد', phone:null, commercial_reg:'1010587730', tax_id:null },
    { name:'شركة الادوات الصحيه', contact:null, phone:'0112410019', commercial_reg:null, tax_id:'311197862800003' },
    { name:'مؤسسة النور', phone:'0500000000' },
  ];
  const merged = api.supDedupeByName(seedRows);
  T('صفّا البذرة لنفس المورد (كتابة مختلفة) يصيران بطاقة واحدة', merged.length === 2,
    'الناتج ' + merged.length);
  T('الدمج يجمع الحقول ولا يُتلف مملوءاً',
    merged[0].commercial_reg === '1010587730' && merged[0].tax_id === '311197862800003' &&
    merged[0].phone === '0112410019' && merged[0].contact === 'أحمد',
    JSON.stringify(merged[0]));
  T('«—» تُعامَل فراغاً فتُملأ بالقيمة الحقيقية',
    api.supMergeRows({ email:'—', name:'x' }, { email:'a@b.c' }).email === 'a@b.c');
  T('الاسم المطبَّع مفتاح واحد للكتابتين',
    api.supKey('شركة الأدوات الصحية') === api.supKey('شركة الادوات الصحيه'));

  // بذرة الملف الحقيقية: كانت تحمل المورد الواحد في صفّين (نحيل + غنيّ)
  const DATA_SUP = (() => {
    const i = HTML.indexOf('const DATA = ');
    let s = HTML.slice(i + 'const DATA = '.length, HTML.indexOf('\n', i));
    if (s.endsWith(';')) s = s.slice(0, -1);
    return JSON.parse(s).suppliers;
  })();
  const uniq = new Set(DATA_SUP.map(s => api.supKey(s.name))).size;
  T('بذرة الملف تُنظَّف من صفوفها المكرّرة (بطاقات شبح)',
    api.supDedupeByName(DATA_SUP).length === uniq && uniq < DATA_SUP.length,
    `${DATA_SUP.length} صفّاً → ${api.supDedupeByName(DATA_SUP).length} (فريد ${uniq})`);

  const list = [
    { name:'مورد سحابي', _cloud:true }, { name:'مورد سحابي ثانٍ', _cloud:true },
    { name:'مورد بذرة' },
  ];
  const bd = api.supSourceBreakdown(list);
  T('التفكيك يفصل صفوف السحابة عن البذرة',
    bd.total === 3 && bd.cloud === 2 && bd.seed === 1, JSON.stringify(bd));
  T('التفكيك يرصد الاسم المكرّر عبر المصدرين',
    api.supSourceBreakdown([{ name:'مورد', _cloud:true }, { name:'مورد' }]).dupGroups === 1);
  T('قائمة نظيفة = صفر تكرار', bd.dupGroups === 0 && bd.dupRows === 0);
  T('المورد بلا اسم لا يُبتلع في مجموعة واحدة',
    api.supDedupeByName([{ name:'' }, { name:null }]).length === 2);

  // الدمج مع السحابة يجب أن يطابق بالمفتاح المطبَّع أيضاً، وإلا ظهر المورد مرّتين
  T('دمج البذرة مع السحابة يستبعد الكتابات المطبَّعة المطابقة',
    /cloudSupKeys\s*=\s*new Set\(data\.suppliers\.map\(s=>supKey\(s\.name\)\)\)/.test(CODE) &&
    /supDedupeByName\(\(SEED\.suppliers\|\|\[\]\)[\s\S]{0,160}!cloudSupKeys\.has\(supKey\(s\.name\)\)/.test(CODE));
  T('البذرة تُنظَّف عند الإقلاع أيضاً (قبل الاتصال بالسحابة)',
    /loadUserSuppliers\(\);\s*\n\s*STATE\.suppliers = supDedupeByName\(STATE\.suppliers\)/.test(CODE));
  T('شاشة الموردين تعرض تركيب العدد (سحابة/بذرة) بلا مرشّح',
    /supSourceBreakdown\(\)/.test(CODE) && /من السحابة/.test(HTML) && /من بذرة الإكسل/.test(HTML));
  T('التكرار يُعرَض ولا يُدمَج تلقائياً (قرار بيانات يخصّ المالك)',
    /function supShowDupes\(\)/.test(CODE) && !/supAutoMerge|autoMergeSuppliers/.test(CODE));
  T('نافذة التكرار تُلحَق بـbody لا داخل قسم صفحة',
    /modal-sup-dupes[\s\S]{0,2000}document\.body\.appendChild\(m\)/.test(CODE));

  /* ── بعد رفع موردي أوامر الشراء للسحابة (2026-09-08) ─────────────────────
     المفتاح القويّ للمقارنة: يُسقِط كلمة الكيان والمسافات. أثبت عمليّاً أنّ ستّ
     حالات كانت ستُرفَع نسخاً ثانية لموردين قائمين. */
  T('المفتاح القويّ يطوي كلمة الكيان', api.supKeyStrong('شركة اكسترا') === api.supKeyStrong('اكسترا'));
  T('المفتاح القويّ يطوي فرق المسافات داخل الاسم',
    api.supKeyStrong('مفروشات العبد اللطيف') === api.supKeyStrong('مفروشات العبداللطيف'));
  T('المفتاح القويّ يطوي «مؤسسة» كذلك',
    api.supKeyStrong('مؤسسة منزل الياقوت') === api.supKeyStrong('منزل الياقوت'));
  /* رموز العرض العربية (U+FB50–FEFF) تصل من استخراج PDF وتبدو عربيّة عاديّة للعين.
     ثمانية موردين في الإنتاج كانوا كذلك: البحث بالاسم الطبيعيّ لا يجدهم إطلاقاً. */
  T('التطبيع يفكّ رموز العرض العربية (أسماء مستخرَجة من PDF)',
    api.arNorm('ﺷﺮﻛﺔ ﺃﺩﻳﻢ ﺍﻟﺼﺤﺮﺍﺀ ﻟﻠﺘﺠﺎﺭﺓ') === api.arNorm('شركة أديم الصحراء للتجارة'));
  T('والبحث يجدها فعلاً بالاسم الطبيعيّ',
    api.supMatches({ name: 'ﺷﺮﻛﺔ ﺃﺩﻳﻢ ﺍﻟﺼﺤﺮﺍﺀ ﻟﻠﺘﺠﺎﺭﺓ' }, api.arNorm('اديم الصحراء').split(' '), ''));
  T('لكنه لا يخلط موردين مختلفين',
    api.supKeyStrong('شركة الحياة لمواد البناء') !== api.supKeyStrong('شركة الخنيزان'));
  T('بوّابة دمج البذرة مع السحابة تستعمل المفتاح القويّ',
    /cloudSupHard\s*=\s*new Set\(data\.suppliers\.map\(s=>supKeyStrong\(s\.name\)\)\)/.test(CODE) &&
    /!cloudSupHard\.has\(supKeyStrong\(s\.name\)\)/.test(CODE));
  /* ⛔️ بذرة موردي أوامر الشراء كانت مصدر قفزة 104←137، ورُفِع محتواها للسحابة.
     إحياؤها يعيد ثماني بطاقات شبح لا تلتقطها أي مطابقة نصّية (منها نقل حرفيّ
     عربيّ↔لاتينيّ: «شركة اكس سي ام جي» مقابل «شركة XCMG»). */
  /* السحابة نُقّيت من سجلات سعرية مكرّرة برقمين مختلفين؛ المطابقة بالرقم وحده كانت
     تُعيد إدراج المحذوف من البذرة في كل جهاز فينتفخ عدّاد العروض (6 سجلات مقيسة). */
  T('دمج السجل السعري يُسقِط المكرّر بالمحتوى لا بالرقم وحده',
    /cloudHistSigs\s*=\s*new Set\(data\.history\.map\(histSig\)\)/.test(CODE) &&
    /!cloudHistNums\.has\(h\.num\)\s*&&\s*!cloudHistSigs\.has\(histSig\(h\)\)/.test(CODE));
  T('بصمة السجل تشمل الصنف والمورد والسعر والتاريخ',
    /histSig\s*=\s*h\s*=>\s*\[h\.code\|\|h\.name\|\|'',\s*arNorm\(h\.supplier\|\|''\),\s*h\.price,\s*h\.date\]/.test(CODE));
  /* ── اكتمال بيانات المورد ────────────────────────────────────────────────
     بعد استكمال الدليل من كل مصادر النظام بقي موردون بلا وسيلة تواصل، منهم
     من له 114 عرض سعر. الشاشة تُظهر من ينقصه ماذا وتفتح التعديل بنقرة. */
  T('«—» و«-» تُعامَل فراغاً لا بيانات',
    api.supVal('—') === '' && api.supVal('-') === '' && api.supVal('ـــ') === '' && api.supVal('0501') === '0501');
  T('المورد المكتمل بلا نقص',
    api.supDataGaps({ name:'x', phone:'0501', commercial_reg:'1010', specialty:'كهرباء', city:'الرياض' }).length === 0);
  T('غياب الهاتف والجوال والبريد = نقص وسيلة تواصل',
    api.supDataGaps({ name:'x', commercial_reg:'1010', specialty:'a', city:'b' }).map(f=>f.key).join() === 'contact');
  T('البريد وحده يكفي كوسيلة تواصل',
    !api.supDataGaps({ name:'x', email:'a@b.c', commercial_reg:'1', specialty:'a', city:'b' }).some(f=>f.key==='contact'));
  T('السجل التجاري أو الرقم الضريبي — أيّهما يكفي للهويّة',
    !api.supDataGaps({ name:'x', phone:'1', tax_id:'3', specialty:'a', city:'b' }).some(f=>f.key==='identity') &&
     api.supDataGaps({ name:'x', phone:'1', specialty:'a', city:'b' }).some(f=>f.key==='identity'));
  T('القيمة النائبة لا تُحسَب بياناتٍ فيبقى النقص مرصوداً',
    api.supDataGaps({ name:'x', phone:'—', mobile:'-', email:'—' }).some(f=>f.key==='contact'));
  T('المرشّح: any و ok و نقص بعينه',
    api.supGapMatch({ name:'x' }, 'any') && !api.supGapMatch({ name:'x' }, 'ok') &&
    api.supGapMatch({ name:'x', phone:'1', specialty:'a', city:'b' }, 'identity') &&
    api.supGapMatch({ name:'x', phone:'1', tax_id:'1', specialty:'a', city:'b' }, 'ok'));
  T('مرشّح فارغ = لا تصفية', api.supGapMatch({ name:'x' }, '') === true);
  T('الشاشة مربوطة: مُنتقي + تصفية + مفتاح إعادة الرسم',
    /id="sup-gaps"/.test(HTML) && /gapFilter\s*=\s*document\.getElementById\('sup-gaps'\)/.test(CODE) &&
    /list = list\.filter\(s=>supGapMatch\(s, gapFilter\)\)/.test(CODE) &&
    /key = raw \+ '\\u0000' \+ specFilter \+ '\\u0000' \+ sort \+ '\\u0000' \+ gapFilter/.test(CODE));
  T('الشارة تفتح نموذج التعديل مباشرةً ولا تفتح بطاقة المورد',
    /function supFixSupplier\(name\)\{[\s\S]{0,200}openEditSupplier\(s\)/.test(CODE) &&
    /event\.stopPropagation\(\);supFixSupplier\(/.test(CODE));
  T('الشارة معروضة في بطاقة المورد وملخّص النقص في سطر العدّاد',
    /\$\{supGapBadge\(s, criticalGapsOnly\)\}/.test(CODE) && /supGapSummaryHtml\(\)/.test(CODE));
  /* لوحة التحكم تعرض «أعلى الموردين» بالبطاقة نفسها — النقص غير الحرِج ضجيج هناك. */
  T('لوحة التحكم تُظهر النقص الحرِج فقط (لا وسيلة تواصل)',
    /top-suppliers'\)\.innerHTML = topSup\.map\(s=>supplierCard\(s, true\)\)/.test(CODE) &&
    /criticalOnly\) g = g\.filter\(f=>f\.key === 'contact'\)/.test(CODE));
  T('وضع «الحرِج فقط» يُسكِت نقص المدينة ويُبقي نقص التواصل',
    api.supGapBadge({ name:'x', phone:'1', commercial_reg:'1', specialty:'a' }, true) === '' &&
    api.supGapBadge({ name:'x', commercial_reg:'1', specialty:'a', city:'b' }, true) !== '');
  T('الشارة هدف لمس صالح للجوال (≥28px)',
    /\.sup-gap-badge\{[^}]*min-height:28px/.test(HTML));
  T('بذرة موردي أوامر الشراء لم تُحيَ (لا ثابت ولا دمج)',
    !/const PO_SUPPLIER_SEED\s*=/.test(CODE) && !/function mergePOSupplierSeed/.test(CODE) &&
    !/\bmergePOSupplierSeed\(\)/.test(CODE));
}

/* ══════════════════════════════════════════════════════════════════════════
   موارد خطوط pdf.js — نصّ المستندات العربية كان يخرج مفكّكاً ومتداخلاً
   بلاغ إنتاج بلقطة: شهادة المحتوى المحلي تُعرَض بحروف عربية منفصلة مقلوبة
   وكلمات لاتينية متداخلة. الجذر: `getDocument` كان بلا أي مورد خطوط، فيستبدل
   pdf.js الخطّ غير المُضمَّن بخطّ الجهاز (عروض محارف مختلفة) ولا يملك جداول
   cMap لخطوط CID (وكل مستند عربي مُنسَّق تقريباً منها).
   ══════════════════════════════════════════════════════════════════════════ */
G('٢٧) موارد خطوط pdf.js');
{
  const cmapDir = path.join(ROOT, 'vendor', 'cmaps');
  const fontDir = path.join(ROOT, 'vendor', 'standard_fonts');
  const cmaps = fs.existsSync(cmapDir) ? fs.readdirSync(cmapDir) : [];
  const fonts = fs.existsSync(fontDir) ? fs.readdirSync(fontDir) : [];
  T('جداول cMap مُضمَّنة في المستودع', cmaps.length > 100, 'العدد ' + cmaps.length);
  T('بيانات الخطوط القياسية مُضمَّنة', fonts.some(f => /LiberationSans-Regular\.ttf$/.test(f)) && fonts.length >= 10,
    'العدد ' + fonts.length);
  T('جداول cMap المُرمَّزة موجودة بصيغتها المضغوطة', cmaps.includes('UniGB-UCS2-H.bcmap') && cmaps.includes('UniJIS-UCS2-H.bcmap'));

  // كتلة خيارات العارض
  const opts = (CODE.match(/getDocument\(\{[\s\S]{0,600}?\}\)\.promise/g) || []).join('\n');
  T('العارض يمرّر بيانات الخطوط القياسية', /standardFontDataUrl:\s*'\/vendor\/standard_fonts\/'/.test(opts));
  T('العارض يمرّر جداول cMap مضغوطة', /cMapUrl:\s*'\/vendor\/cmaps\/'/.test(opts) && /cMapPacked:\s*true/.test(opts));
  T('العارض لا يعتمد على خطوط الجهاز (عرض واحد على كل جهاز)', /useSystemFonts:\s*false/.test(opts));
  /* 🐛 بلاغ إنتاج (لقطتان): الشهادات الحكومية تُعرَض بكلمات مفكّكة وحروف في غير مواضعها.
     الجذر — أُعيد إنتاجه على الملفّ الحقيقيّ ثمّ زال: الشهادة تُضمِّن نسخة مُجزّأة من
     خطّ Tahoma (Identity-H)، ويعيد pdf.js بناءها خطَّ ويب فيرفضها **مُعقِّم خطوط
     المتصفّح بصمت** ⇒ سقوط لخطّ افتراضي برموز خاطئة. `disableFontFace` يجعل pdf.js
     يرسم مسارات الرموز بنفسه فلا دخل لمحرّك خطوط المتصفّح.
     ⚠️ الانحدار هنا **بصريّ بحت**: عدد البكسلات المرسومة يكاد يتطابق في الحالتين
     (96048 مقابل 96053 على شهادة التأمينات) فلا يلتقطه أي مقياس عدديّ — لذلك هذا
     التأكيد البنيويّ هو الحارس الوحيد الممكن. لا تحذفه ولا تحذف الخيار «للأداء»
     (التكلفة المقيسة +12ms على صفحة كاملة = 5%). */
  T('العارض يرسم مسارات الرموز بنفسه (لا @font-face) — إصلاح تشوّه الشهادات',
    /disableFontFace:\s*true/.test(opts));
  T('تعطيل eval باقٍ (CSP تمنعه) ومسار رسم المسارات يعمل بدونه',
    /isEvalSupported:\s*false/.test(opts));
  T('استخراج النصّ من PDF يحمل جداول cMap كذلك',
    /getDocument\(\{\s*data,\s*cMapUrl:\s*'\/vendor\/cmaps\/',\s*cMapPacked:\s*true\s*\}\)/.test(CODE));
  // كل الموارد من نفس الأصل — وإلّا رفضتها connect-src وعاد التشوّه صامتاً
  T('كل موارد الخطوط من نفس الأصل لا من CDN',
    !/(standardFontDataUrl|cMapUrl):\s*'https?:/.test(CODE));
  // الكاش: أصول ثابتة بإصدار مثبَّت — لا تُعاد في كل فتح
  const HDRS = fs.readFileSync(path.join(ROOT, '_headers'), 'utf8');
  T('`/vendor/*` مكاشة (تشمل الخطوط وجداول cMap)', /\/vendor\/\*\s*\n\s*Cache-Control:/.test(HDRS));
}

/* ── ٢٨) قفل التمرير: مصدر واحد مشتقّ من الحالة ───────────────── */
/* بلاغ المالك «السكرولينق يعلق في بعض الشاشات أحياناً». الجذر المقيس: القفل كان
   يُضبَط في ثلاثة مواضع ويُفَكّ في أربعة، ونافذتان تُفتَحان بـ`display:flex` بلا
   مرور بأيٍّ منها — فمسار «تفاصيل الطلب ← عارض المستندات ← إغلاقهما» يترك
   `body{overflow:hidden}` إلى الأبد. الحرّاس هنا تمنع عودة التفرّق. */
G('٢٨) قفل التمرير (بلاغ «السكرولينق يعلق»)');
{
  const sets = [...CODE.matchAll(/document\.body\.style\.overflow\s*=/g)].length;
  T('مصدر واحد فقط يضبط `body.style.overflow` (لا تفرّق يعيد التسريب)', sets === 1,
    'مواضع الضبط: ' + sets);
  const sync = grab('syncScrollLock');
  T('`syncScrollLock` هي ذلك المصدر وتشتقّ القفل لا تتراكمه',
    /document\.body\.style\.overflow\s*=\s*anyOverlayOpen\(\)/.test(sync));

  // معاينة الطباعة صنفها `print-preview-overlay` لا `modal-overlay` — إسقاطها
  // من الحساب يُلغي قفلها صامتاً (وقع فعلاً في أوّل صياغة، أمسكه القياس).
  const activeSel = grabConst('SCROLL_LOCK_ACTIVE');
  T('حساب الطبقات يشمل معاينة الطباعة', /\.print-preview-overlay\.active/.test(activeSel));
  T('وحساب الطبقات يشمل النوافذ العادية', /\.modal-overlay\.active/.test(activeSel));
  const layers = grabConst('SCROLL_LOCK_LAYERS');
  ['#modal-doc-viewer', '#modal-reg-detail', '#modal-email-templates'].forEach(id =>
    T('طبقة `display:flex` محسوبة: ' + id, layers.includes(id)));

  // كل مسار يفتح أو يغلق طبقةً ينادي المزامنة — وإلّا عاد التسريب من ذلك الباب
  [['openModal','فتح نافذة'], ['closeModal','إغلاق نافذة'], ['closeAllModals','إغلاق الكل'],
   ['showPrintPreview','فتح معاينة الطباعة'], ['closePrintPreview','إغلاق المعاينة'],
   ['docvOpen','فتح عارض المستندات'], ['docvClose','إغلاق العارض'],
   ['closeRegDetail','إغلاق تفاصيل الطلب'], ['closeEmailTemplates','إغلاق قوالب البريد'],
   ['supCloseDupes','إغلاق نافذة التكرار'], ['poCloseMissing','إغلاق نافذة الأرقام المفقودة'],
   ['poReceiveClose','إغلاق نافذة الاستلام']
  ].forEach(([fn, label]) =>
    T(label + ' ينادي `syncScrollLock`', /syncScrollLock\(\)/.test(grab(fn))));

  // إغلاق المعاينة كنافذة عادية كان يترك `print-preview-active` والمستند خلفه
  T('إغلاق معاينة الطباعة يمرّ بمنظّفها الخاصّ',
    /id===['"]modal-print-preview['"]\s*\)\s*\{\s*try\{\s*closePrintPreview\(\)/.test(CODE));

  // النوافذ المُلحَقة وقت التشغيل: تُوسَم عابرة فتُزال لا تُخفى (وإلّا معرّف مكرَّر)
  ['modal-sup-dupes', 'modal-po-missing', 'modal-po-receive'].forEach(id =>
    T('نافذة مُلحَقة موسومة عابرة: ' + id,
      new RegExp("m\\.id='" + id + "'; m\\.dataset\\.ephemeral='1';").test(CODE)));
  T('`closeModal` يزيل النوافذ العابرة من DOM',
    /dataset\.ephemeral === '1'\) el\.remove\(\)/.test(grab('closeModal')));

  /* تأكيد سلوكيّ: المسار المُبلَّغ عنه حرفيّاً على DOM مُقلَّد.
     ⚠️ لا تُبدِّله بفحص نصّيّ — الفحص النصّيّ هو الذي مرّ عليه العيب أصلاً. */
  const mkDoc = () => {
    const L = { '#modal-doc-viewer': { style:{display:'none'} },
                '#modal-reg-detail': { style:{display:'none'} },
                '#modal-email-templates': { style:{display:'none'} } };
    let actives = 0;
    return { body:{ style:{ overflow:'' } },
      querySelector(sel){ return sel.includes('.active') ? (actives > 0 ? {} : null) : (L[sel] || null); },
      _open(id){ L[id].style.display = 'flex'; }, _close(id){ L[id].style.display = 'none'; },
      _actives(n){ actives = n; } };
  };
  const make = new Function('document',
    grabConst('SCROLL_LOCK_ACTIVE') + '\n' + grabConst('SCROLL_LOCK_LAYERS') + '\n' +
    grab('anyOverlayOpen') + '\n' + grab('syncScrollLock') + '\n' +
    'return { anyOverlayOpen, syncScrollLock };');
  let d = mkDoc(); let api = make(d);
  d._open('#modal-reg-detail'); api.syncScrollLock();
  T('تفاصيل طلب التسجيل تقفل التمرير خلفها', d.body.style.overflow === 'hidden');
  d._open('#modal-doc-viewer'); api.syncScrollLock();
  d._close('#modal-doc-viewer'); api.syncScrollLock();
  T('إغلاق عارض المستندات لا يفكّ القفل والتفاصيل مفتوحة', d.body.style.overflow === 'hidden');
  d._close('#modal-reg-detail'); api.syncScrollLock();
  T('إغلاق التفاصيل بعده يفكّ القفل (العيب المُبلَّغ عنه)', d.body.style.overflow === '');
  d = mkDoc(); api = make(d);
  d._actives(2); api.syncScrollLock();
  d._actives(1); api.syncScrollLock();
  T('إغلاق نافذة داخلية لا يفكّ قفل الخارجية', d.body.style.overflow === 'hidden');
  d._actives(0); api.syncScrollLock();
  T('إغلاق الأخيرة يفكّ القفل', d.body.style.overflow === '');

  /* الانزلاق الأفقيّ على الهاتف يخطف تمرير الإصبع فيبدو التمرير «معلَّقاً».
     مقيس قبل الإصلاح: شاشة الإدخال 50px عند 393px، ولوحة التحكم 29px عند 360px —
     كلاهما من عنصر شبكة لا يصغر دون min-content ابنه غير الملتفّ. */
  const CSS = [...HTML.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(m => m[1]).join('\n');
  const mob = (CSS.match(/@media\s*\(max-width:\s*900px\)\s*\{[\s\S]*/) || [''])[0];
  T('عناصر شبكة شاشة الإدخال تُسمَح بالانكماش على الجوال', /\.entry-layout\s*>\s*\*\{min-width:0\}/.test(mob));
  T('مبدّل الوضع يلتفّ على الجوال (مقاسه الأدنى كان يدفع الصفحة 429px)',
    /\.mode-toggle\{display:flex;flex-wrap:wrap;width:100%\}/.test(mob));
  T('عناصر شبكة لوحة التحكم تُسمَح بالانكماش على الجوال', /\.dash-charts\s*>\s*\*\{min-width:0\}/.test(mob));
  T('صفّ الرسم الدائريّ يلتفّ على الجوال', /#dash-cat-chart\s*>\s*div\{flex-wrap:wrap\}/.test(mob));
  T('ما يفيض من بطاقة رسم يمرّر داخلها لا على الصفحة', /\.chart-card\{overflow-x:auto\}/.test(mob));
}

/* ── ٢٩) حملة التسجيل + إكمال البطاقة القائمة ───────────────────── */
/* طلب المالك 2026-09-10: مورّدون أُدخِلوا يدويّاً أو من عروض الأسعار يُدعَون
   للتسجيل، وبعد تسجيلهم **تُكمَل بطاقتهم القائمة** لا تُنشأ بطاقة ثانية.
   الحالة المقيسة وقتها على القاعدة الحيّة: 117 من 155 بلا تسجيل، 73 فقط لديهم
   سجل تجاري — فالمطابقة بالسجل وحدها (وهي ما كان قائماً) كانت ستُكرِّر أغلبهم. */
G('٢٩) حملة التسجيل + إكمال بطاقة المورد');
{
  const REGISTER  = fs.readFileSync(path.join(ROOT, 'register.html'), 'utf8');
  const INVITE_API = fs.readFileSync(path.join(ROOT, 'functions/api/supplier-invite-link.js'), 'utf8');
  const { regCampWaPhone, regCampMessage, regCampBuild, regSupplierFill, regMatchExistingSupplier } = api;

  // ── رقم الواتساب: الجوال فقط، بصيغة دولية، ومن كل كتابات الرقم السعودي
  T('جوال 05 يصير 9665…', regCampWaPhone({mobile:'0542057081'}) === '966542057081');
  T('صيغة +966 مقبولة كما هي', regCampWaPhone({mobile:'+966 54-205-7081'}) === '966542057081');
  T('الأرقام العربية تُقرأ', regCampWaPhone({mobile:'٠٥٤٢٠٥٧٠٨١'}) === '966542057081');
  // الأرضيّ لا واتساب له — إرسال دعوة إليه ضياع لا خطأ ظاهر
  T('الهاتف الأرضيّ لا يُعَدّ رقم واتساب', regCampWaPhone({phone:'0138576550'}) === '');
  T('الجوال يسبق الأرضيّ', regCampWaPhone({phone:'0112410019', mobile:'0501234567'}) === '966501234567');
  T('بلا رقم ⇒ فارغ', regCampWaPhone({}) === '');
  T('القيمة النائبة «—» ليست رقماً', regCampWaPhone({mobile:'—'}) === '');

  // ── الرسالة
  const URL_ = 'https://suppliers.aldeyabi.com/register?s=AAA.BBB';
  const msg = regCampMessage({name:'شركة الأنواع الشاملة'}, URL_);
  T('الرسالة تحمل اسم المنشأة', msg.includes('شركة الأنواع الشاملة'));
  T('الرسالة تحمل الرابط الخاصّ', msg.includes(URL_));
  /* ⚠️ واتساب لا يجعل الرابط قابلاً للنقر إن التصق بنصّ عربيّ — سطر مستقلّ شرط */
  T('الرابط في سطر مستقلّ (وإلّا لم يصر قابلاً للنقر)',
    msg.split('\n').some(l => l.trim() === URL_));
  T('الرسالة تذكر الوثائق المطلوبة', /السجل التجاري/.test(msg) && /الآيبان/.test(msg));
  T('الرسالة تحمل قناة تواصل', msg.includes('920000194') && msg.includes('supply@aldeyabi.com'));
  T('نصّ خالص بلا HTML (الواتساب لا يعرضه)', !/<[a-z/][^>]*>/i.test(msg));
  T('اسم فارغ لا يُنتج رسالة مبتورة', /السادة \/ \*المورد\*/.test(regCampMessage({}, URL_)));
  /* ⚠️ قرار المالك 2026-09-10: لغة مؤسسية لاستكمال البيانات — **لا** نبرة
     «ملفّكم موجود لدينا والرابط خاصّ بكم» ولا طمأنات متتالية. آليّة الربط شأن
     داخليّ لا يُشرَح في متن الخطاب. (الحارس على الرسالة والبطاقة معاً.) */
  const CARD_ = fs.readFileSync(path.join(ROOT, 'supplier-invitation-whatsapp.html'), 'utf8');
  const CHATTY = /ملف جديد|ملفّ?كم الحالي|مسجَّلون لدينا|لن تفقدوا|خاصّ بمنشأتكم|عبّأنا لكم/;
  T('الرسالة بلغة مؤسسية بلا نبرة «ملفّكم موجود والرابط لكم»', !CHATTY.test(msg), msg.match(CHATTY)?.[0]);
  T('البطاقة كذلك بلا تلك النبرة', !CHATTY.test(CARD_.replace(/<!--[\s\S]*?-->/g, '')));
  T('لافتة النموذج كذلك بلا تلك النبرة',
    !CHATTY.test((REGISTER.match(/function showInviteBanner\([\s\S]*?\n\}/) || [''])[0]));
  T('صيغة المراسلات الرسمية (مخاطبة وخاتمة)',
    /^السادة \//m.test(msg) && /تحية طيبة وبعد/.test(msg) && /وتفضلوا بقبول فائق الاحترام/.test(msg));
  T('الرسالة تُصرّح بالمطلوب: استكمال البيانات واعتماد الملف',
    /استكمال بيانات منشأتكم/.test(msg) && /متطلبات استكمال الملف/.test(msg));

  // ── من لم يُسجّل: أربعة مسارات استبعاد
  const sups = [
    {id:'s1', name:'شركة ألف للتجارة', commercial_reg:'1010000001', mobile:'0501111111', offers_count:5},
    {id:'s2', name:'مؤسسة باء',        tax_id:'310000000000003',    mobile:'0502222222', offers_count:9},
    {id:'s3', name:'شركة جيم للمقاولات', mobile:'0503333333', offers_count:2},
    {id:'s4', name:'مؤسسة دال',        mobile:'0504444444', offers_count:1},
    {id:'s5', name:'شركة هاء',         phone:'0114444444', offers_count:7},
  ];
  STATE.suppliers = sups;
  const regs = [
    {commercial_reg:'1010000001', legal_name_ar:'اسم مختلف تماماً'},   // يستبعد s1 بالسجل
    {vat_number:'310000000000003', legal_name_ar:'اسم آخر'},           // يستبعد s2 بالضريبي
    {legal_name_ar:'جيم للمقاولات'},                                   // يستبعد s3 بمفتاح الاسم (كلمة الكيان مُسقَطة)
    {legal_name_ar:'لا علاقة', link_supplier_id:'s4'},                 // يستبعد s4 برابط الدعوة
  ];
  const camp = regCampBuild(regs);
  T('المسجَّل بالسجل التجاري لا يدخل الحملة', !camp.some(r => r.id === 's1'));
  T('المسجَّل بالرقم الضريبي لا يدخل الحملة', !camp.some(r => r.id === 's2'));
  T('«شركة جيم» و«جيم» مورد واحد (المفتاح القويّ)', !camp.some(r => r.id === 's3'));
  T('من سجّل عبر رابط الدعوة لا يدخل الحملة', !camp.some(r => r.id === 's4'));
  T('غير المسجَّل يدخل الحملة', camp.length === 1 && camp[0].id === 's5');
  T('من بلا جوال يُدرَج لكن بلا رقم واتساب', camp[0].wa === '' && camp[0].phone === '0114444444');
  const camp2 = regCampBuild([]);
  T('الترتيب بالأهمّية (عدد العروض)', camp2.map(r=>r.id).join() === 's2,s5,s1,s3,s4', camp2.map(r=>r.id).join());
  T('المورد بلا اسم لا يُدرَج',
    regCampBuild([]).length === 5 && !regCampBuild([]).some(r => !r.name));

  // ── الملء: الفارغ فقط
  const reg = { id:'DG-TEST01', legal_name_ar:'الاسم من التسجيل', city:'جدة', phone:'0126666666',
                contact_name:'خالد', contact_mobile:'0505555555', email:'a@b.com', address:'حيّ',
                commercial_reg:'1010009999', vat_number:'310000000000099', iban:'SA0000000000000000000000',
                sectors:['مقاولات'], entity_type:'شركة', business_scope:['توريد'], business_description:'وصف' };
  const cur = { id:'s9', name:'الاسم القديم في البطاقة', city:'الرياض', phone:'—', notes:'مورد من أوامر الشراء' };
  const fill = regSupplierFill(cur, reg);
  /* الاسم مفتاح ربط أوامر الشراء والسجل السعري — استبداله يفصل البطاقة عن تاريخها */
  T('اسم البطاقة لا يُستبدَل أبداً', !('name' in fill));
  T('حقل مملوء لا يُتلَف', !('city' in fill));
  T('«—» تُعامَل فراغاً فتُستبدل ببيانات حقيقية', fill.phone === '0126666666');
  T('الحقول الفارغة تُملأ', fill.contact === 'خالد' && fill.email === 'a@b.com' && fill.iban === reg.iban);
  T('الهويّة النظامية تُملأ', fill.commercial_reg === '1010009999' && fill.tax_id === '310000000000099');
  T('القطاعات تصير تخصّصاً', fill.specialty === 'مقاولات');
  T('رقم الطلب يُلحَق بالملاحظات بلا مسح', /مورد من أوامر الشراء/.test(fill.notes) && /DG-TEST01/.test(fill.notes));
  T('إعادة الاعتماد لا تُكرّر رقم الطلب في الملاحظات',
    !('notes' in regSupplierFill(Object.assign({}, cur, {notes:'... DG-TEST01 ...'}), reg)));
  T('بطاقة مكتملة ⇒ لا تغيير',
    Object.keys(regSupplierFill({id:'s9', name:'ن', city:'ج', phone:'1', mobile:'2', email:'e', contact:'c',
      address:'a', commercial_reg:'1', tax_id:'2', entity_type:'e', business_scope:'b', business_description:'d',
      specialty:'s', bank_name:'b', account_holder:'h', account_number:'n', iban:'i', notes:'DG-TEST01'}, reg)).length === 0);

  // ── المطابقة الرباعية (سلوكيّ على عميل مُقلَّد — لا فحص نصّيّ)
  const mkClient = (rows) => ({ client: { from(){ const q = {
      _col:null, _val:null,
      select(){ return q; },
      eq(c, v){ q._col = c; q._val = v; return q; },
      limit(){ return Promise.resolve({ data: rows.filter(r => String(r[q._col]) === String(q._val)) }); },
    }; return q; } } });
  const CARDS = [
    {id:'s1', name:'شركة ألف للتجارة', commercial_reg:'1010000001'},
    {id:'s2', name:'مؤسسة باء',        tax_id:'310000000000003'},
    {id:'s3', name:'شركة جيم للمقاولات'},
    {id:'s6', name:'اسم ملتبس'}, {id:'s7', name:'شركة اسم ملتبس'},
    {id:'s8', name:'شركة سراكو',       commercial_reg:'2050007518'},
  ];
  api.window.CLOUD = mkClient(CARDS);
  STATE.suppliers = CARDS;
  const M = (r) => regMatchExistingSupplier(r);
  T('المرتبة ١: رابط الدعوة قاطع',
    (await M({link_supplier_id:'s2', legal_name_ar:'أيّ اسم'}) || {}).id === 's2');
  T('المرتبة ٢: السجل التجاري',
    (await M({legal_name_ar:'كتابة أخرى', commercial_reg:'1010000001'}) || {}).id === 's1');
  T('المرتبة ٣: الرقم الضريبي',
    (await M({legal_name_ar:'كتابة أخرى', vat_number:'310000000000003'}) || {}).id === 's2');
  T('المرتبة ٤: مفتاح الاسم القويّ',
    (await M({legal_name_ar:'جيم للمقاولات'}) || {}).id === 's3');
  /* درس «سراكو»: تشابه الاسم ليس دليلاً — السجل التجاري هو الفاصل */
  T('تعارض السجل التجاري يُبطِل مطابقة الاسم',
    (await M({legal_name_ar:'شركة سراكو', commercial_reg:'2050111360'})) === null);
  T('الاسم الملتبس (بطاقتان) لا يُخمَّن',
    (await M({legal_name_ar:'اسم ملتبس'})) === null);
  T('لا مطابقة ⇒ بطاقة جديدة (السلوك القائم)',
    (await M({legal_name_ar:'مورد جديد تماماً'})) === null);
  T('رابط دعوة لبطاقة محذوفة يسقط للمراتب التالية',
    (await M({link_supplier_id:'sX', commercial_reg:'1010000001'}) || {}).id === 's1');
  api.window.CLOUD = null;
  STATE.suppliers = [];

  // ── الربط في الشيفرة (بنيويّ — ما لا يُشغَّل في الصندوق)
  T('نموذج التسجيل يحفظ معرّف بطاقة الدعوة', /link_supplier_id:\s*_inviteSupplierId/.test(REGISTER));
  T('وضع الدعوة لا يُتلف حقلاً عبّأه المورّد', /if \(el && val && !String\(el\.value \|\| ''\)\.trim\(\)\)/.test(REGISTER));
  T('فشل الدعوة يسقط لتسجيل عاديّ بلا تعطيل', /catch \(_\) \{ \/\* تسجيل عاديّ \*\/ \}/.test(REGISTER));
  T('نقطة الرمز لا تبثّ أي حقل بنكيّ',
    !/'iban'|'account_number'|'bank_name'|'account_holder'/.test(
      (INVITE_API.match(/const PREFILL_COLS = \[[\s\S]*?\];/) || [''])[0]));
  T('سكّ الروابط يتطلّب جلسة موظّف + نفس الأصل',
    /if \(!sameOrigin\(request\)\) return json/.test(INVITE_API) && /verifyStaff\(env, request\)/.test(INVITE_API));
  T('الرمز يُقارَن بمقارنة ثابتة الزمن', /timingSafeEq\(expect, parts\[1\]\)/.test(INVITE_API));
  T('بطاقة المورد تجد طلب التسجيل بمعرّف الدعوة',
    /\.eq\('link_supplier_id', sup\.id\)/.test(CODE));
  T('فشل ملء البطاقة يُجهِض الاعتماد (لا نجاح زائف)',
    /if \(fillErr\) throw fillErr;/.test(CODE));

  /* ⚠️ الاعتماد صار **يُعدّل بطاقة قائمة** لا يُنشئ صفّاً جديداً — فبلا أثر تدقيق
     لا سبيل لمعرفة أي بطاقة تأثّرت ولا بأي مرتبة طوبقت. (كان غائباً تماماً.) */
  T('الاعتماد يُسجَّل في التدقيق بالبطاقة والمرتبة والحقول المملوءة',
    /logAudit\(alreadyExisted \? 'reg_approve_merge' : 'reg_approve_create', 'supplier', suppId/.test(CODE)
    && /matched_by:/.test(CODE) && /filled_fields: filledCount/.test(CODE));
  T('كل مرتبة مطابقة تُوسَم باسمها',
    /tag\(hit, 'invite_link'\)/.test(CODE) && /tag\(hit, col\)/.test(CODE) && /tag\(first\(data\), 'name_key'\)/.test(CODE));
  /* التدقيق يُكتب **بعد** نجاح الكتابات، وإخفاقه لا يُسقِط الاعتماد */
  T('فشل التدقيق لا يُسقِط اعتماداً نجح',
    /reportError\('approveRegistration\/audit', e\)/.test(CODE));

  /* بطاقة الدعوة المصوَّرة: الواتساب لا يعرض HTML، فالبطاقة صورة تُرفَق بالنصّ.
     ⚠️ فيض المحتوى يقصّ التذييل **صامتاً** (وقع فعلاً: 1552 على بطاقة 1350) —
     الحارس السلوكيّ لذلك في `scripts/build-invite-card.mjs`، وهنا البنيويّ. */
  const CARD = fs.readFileSync(path.join(ROOT, 'supplier-invitation-whatsapp.html'), 'utf8');
  T('البطاقة بمقاس الواتساب 1080×1350', /width:1080px;height:1350px/.test(CARD));
  T('البطاقة تقصّ ما يفيض (لا تمدّد الصورة)', /#card\{[\s\S]{0,200}overflow:hidden/.test(CARD));
  T('هويّة الدعوة السابقة محفوظة (كحليّ + ذهبيّ)',
    CARD.includes('#16243d') && CARD.includes('#c2a063') && CARD.includes('#a37f43'));
  /* لا مصدر خارجيّ: التوليد يجب أن يُنتج الصورة نفسها بلا شبكة ولا CDN */
  T('لا مصادر خارجية في البطاقة', !/https?:\/\//.test(CARD.replace(/<!--[\s\S]*?-->/g, '')));
  T('البطاقة تُصرّح بأثر استكمال الملف (لا طمأنات)',
    /اعتماد البيانات البنكية/.test(CARD) && /استكمال بيانات منشأتكم/.test(CARD));
  /* سكربت `<image-slot>` كان مضمَّناً data: URI في صفحة التسجيل: 41KB يُنزَّل مع
     كل فتح، تحجبه CSP فلا يعمل أصلاً. الحملة تسوق ~90 مورداً لهذه الصفحة. */
  T('لا سكربت data: URI في صفحة التسجيل (تحجبه CSP ويُثقِلها بلا فائدة)',
    !/<script[^>]+src="data:/i.test(REGISTER));

  T('مولّد البطاقة يُفشِل البناء على الفيض',
    /scrollH > m\.h/.test(fs.readFileSync(path.join(ROOT, 'scripts/build-invite-card.mjs'), 'utf8')));
}

/* ── ٣٠) نطاق موظفي الصيانة والتشغيل ─────────────────────────────
   المُنطَّق = مستخدم له قطاعات في `scope_sectors`. الحدّ الحقيقيّ في RLS
   (db/system2-staff-scope.sql + db/system2-tests/)، وهذه التأكيدات تحرس
   **طبقة الواجهة**: ألّا تطلب ما لا يخصّه، وألّا تعرض مبلغاً، وألّا تكتب
   الصفّ مباشرةً. ⚠️ صندوق مستقلّ يحمّل `fmtPrice`/`hasPermission`
   **الحقيقيّتين** — صندوق القسم 2 يكعّبهما فلا يصلح لاختبار البوّابة نفسها. */
{
  G('٣٠) نطاق موظفي الصيانة والتشغيل');

  // ── بنيويّ ──
  T('مصدر واحد للوجهات المسموحة (SCOPED_PAGES) يخدم القائمتين و navigate',
    /const SCOPED_PAGES\s*=/.test(CODE)
    && /function pageAllowed\(/.test(CODE)
    && /applyScopedNav[\s\S]{0,700}\.nav-item\[data-page\][\s\S]{0,400}\.mnav-item\[data-mpage\]/.test(CODE)
    && /function navigate\(page\)\{\s*[\s\S]{0,200}?if\(!pageAllowed\(page\)\)/.test(CODE));

  // ⚠️ كشفه المتصفّح لا الفحص النصّيّ: القاعدة الثابتة لإخفاء «طلبات الشراء»
  // تحمل !important، فـ`style.display='flex'` السطريّ لا يغلبها والمدخل يبقى
  // مخفيّاً عن الموظّف الذي هي مسار طلباته. العلاج قاعدة مضادّة بنفس القوّة.
  T('مدخل الطلبات يُرفع للمُنطَّق وللمشتريات بقاعدة CSS مضادّة لا بـstyle سطريّ',
    /body\.role-scoped \.nav-item\[data-page="pr"\],[\s\S]{0,400}body\.pr-visible \.nav-item\[data-page="pr"\]\{\s*display:flex !important/.test(HTML)
    && !/\.nav-item\[data-page="pr"\]'\)\.forEach\(el => \{\s*el\.style\.display/.test(CODE));

  // ⚠️ «شاشتان فقط» أمرٌ صريح من المالك: زرّ ثالث في الشريط السفليّ يعيد
  // فتح باب أغلقه القرار. التأكيد يمنع عودته.
  T('الشريط السفليّ يحمل وجهة الطلبات ولا يحمل وجهة ثالثة للمُنطَّق',
    /data-mpage="pr" data-scoped-only/.test(HTML)
    && !/data-mpage="reports" data-scoped-only/.test(HTML)
    && /body\.role-scoped \.mnav-item\[data-scoped-only\]\{\s*display:flex/.test(HTML));

  T('السقوط المحلّي لا يصكّ حساباً مُنطَّقاً أبداً',
    !/AUTH_BOOTSTRAP_USERS\s*=[\s\S]{0,900}scope/i.test(CODE)
    && /validScope\s*=\s*profile\s*\?/.test(CODE));

  T('المُنطَّق يقرأ الأوامر من العرض لا من الجدول',
    /scoped\s*\?\s*'proc_po_visible'\s*:\s*'proc_purchase_orders'/.test(CODE));

  T('المُنطَّق لا يطلب الكتالوج ولا الموردين ولا السجل',
    /const\s+\[items,\s*suppliers,\s*history\]\s*=\s*scoped\s*\?\s*\[\[\],\[\],\[\]\]/.test(CODE));

  T('لا دمج بذرة للمُنطَّق (وإلّا وصلته الأسعار من الملف نفسه)',
    /const SEED\s*=\s*\(typeof DATA[^;]*!isScopedUser\(\)\)\s*\?\s*DATA/.test(CODE));

  T('المُنطَّق لا يُشغّل توحيد المشاريع (لا صلاحية كتابة له على الأوامر)',
    /if\(!isScopedUser\(\)\)\{[\s\S]{0,200}prjAutoUnify\(\)/.test(CODE));

  T('استلام المُنطَّق يمرّ بـRPC لا بـpoSave',
    /if\(isScopedUser\(\)\)\s*return poReceiveSaveScoped/.test(CODE)
    && /rpc\('po_record_receipt'/.test(CODE)
    && !/poReceiveSaveScoped[\s\S]{0,1200}poSave\(/.test(CODE));

  T('التعليق يمرّ بـRPC خادميّة', /rpc\('po_add_comment'/.test(CODE));

  T('الاستلام صلاحية مستقلّة عن تعديل الأمر',
    /hasPermission\('can_edit_po'\)\s*\|\|\s*hasPermission\('can_receive_po'\)/.test(CODE));

  // ⚠️ لا منسّق نقديّ ثانٍ يلتفّ حول البوّابة
  // النداء الوحيد المسموح لـfmtPriceRaw هو من داخل البوّابة نفسها؛ أي نداء
  // ثانٍ = مسار يعرض مبلغاً دون المرور بها.
  const rawCalls = (CODE.match(/fmtPriceRaw\(/g) || []).length;
  T('لا منسّق نقديّ يتجاوز بوّابة المبالغ (fmtPriceRaw داخليّ فقط)',
    rawCalls === 1
    && /const fmtPrice = n => canViewAmounts\(\) \? fmtPriceRaw\(n\) : '—';/.test(CODE),
    'نداءات fmtPriceRaw = ' + rawCalls);
  // ⚠️ التعريف نفسه `function tafqitSARRaw(` يطابق النمط (خلافاً لصيغة السهم
  // في fmtPriceRaw) — فيُستبعَد قبل العدّ، وإلّا صار التأكيد يقيس شكل التعريف
  // لا عدد النداءات.
  const tafqitCalls = (CODE.replace(/function tafqitSARRaw\(/g, 'function _def_(')
                           .match(/tafqitSARRaw\(/g) || []).length;
  T('ولا التفقيط (tafqitSARRaw داخليّ فقط)', tafqitCalls === 1,
    'نداءات tafqitSARRaw = ' + tafqitCalls);
  T('التفقيط محجوب كذلك (وإلّا تسرّب المبلغ حروفاً)',
    /function tafqitSAR\(amount\)\{\s*if\(!canViewAmounts\(\)\) return '—';/.test(CODE));

  T('مركز التقارير قائمة بيضاء لا سوداء',
    /canViewAmounts\(\)\s*\|\|\s*x\.d\.noMoney === true/.test(CODE)
    && /def\.noMoney !== true && !canViewAmounts\(\)/.test(CODE));

  // ── سلوكيّ: صندوق يحمّل البوّابة الحقيقية ──
  const P = (() => {
    const src = [
      `const STATE = { currentUser:null };`,
      `function toast(){}`,
      grabConst('PERMISSION_DEFS'), grabConst('PERMISSION_KEYS'), grabConst('DEFAULT_PERMISSIONS'),
      grab('hasPermission'), grab('isAdmin'),
      grab('normScopeSectors'), grab('myScopeSectors'), grab('isScopedUser'), grab('canViewAmounts'),
      grab('effectivePerm'),
      grabConst('SCOPED_PAGES'), grab('pageAllowed'),
      grab('prPermStrict'), grabConst('PR_TEAM_KEYS'), grab('prCanSeeAll'), grab('prIsProcurement'),
      grabConst('fmtPriceRaw'), grabConst('fmtPrice'),
      grab('tafqitSAR'), grab('tafqitSARRaw'),
    ].join('\n\n');
    return new Function(src + `; return {STATE, hasPermission, effectivePerm, normScopeSectors,
      isScopedUser, canViewAmounts, pageAllowed, fmtPrice, tafqitSAR, DEFAULT_PERMISSIONS,
      prPermStrict, prCanSeeAll, prIsProcurement};`)();
  })();

  const asUser = (perms, scope, role) => {
    P.STATE.currentUser = { username:'u', role: role||'user', permissions: perms||{}, scopeSectors: scope||[] };
  };

  P.STATE.currentUser = null;
  T('normScopeSectors يقبل المصفوفة والنصّ ويُسقِط الفارغ',
    P.normScopeSectors(['أ','',' ب ']).join('|') === 'أ|ب'
    && P.normScopeSectors('["ج"]').join('') === 'ج'
    && P.normScopeSectors(null).length === 0
    && P.normScopeSectors('نصّ تالف').length === 0);

  asUser({}, []);
  T('بلا قطاعات = غير مُنطَّق', P.isScopedUser() === false);
  asUser({}, ['الصيانة والتشغيل']);
  T('بقطاع = مُنطَّق', P.isScopedUser() === true);

  // ⚠️ أمر المالك الصريح: «شاشة أوامر الشراء التي تخصّه وشاشة رفع الطلبات
  // ومتابعتها — باقي النظام ما يخصّه أبداً». حتى لوحة التحكم والتقارير
  // خارج نطاقه (تقرير المتابعة يُطبع من داخل شاشة الأوامر).
  T('الوجهات المسموحة للمُنطَّق شاشتان فقط',
    ['purchase-orders','pr'].every(p => P.pageAllowed(p))
    && !['dashboard','reports','items','suppliers','history','entry','pricing',
         'analytics','ai','registrations'].some(p => P.pageAllowed(p)));
  T('مهبط الموظّف شاشة أوامره لا لوحة التحكم',
    /const SCOPED_HOME\s*=\s*'purchase-orders'/.test(CODE)
    && /if\(isScopedUser\(\)\)\{[^}]*navigate\(SCOPED_HOME\)/.test(CODE));
  /* ⚠️ وداخل الشاشة «القائمة» لا «لوحة التحكم»: عرض اللوحة تحليلاتٌ أكثر قيمها
     محجوبة عنه، فيمرّ على الجوال بسبع بطاقات مؤشّرات قبل أوّل أمر شراء. */
  T('وعرضه الافتراضيّ قائمة أوامره لا لوحة تحليلات',
    /if\(isScopedUser\(\)\)\{\s*STATE\.poView\s*=\s*'list'/.test(CODE));
  asUser({}, []);
  T('غير المُنطَّق يصل كل وجهة (صفر انحدار)',
    ['items','suppliers','analytics','ai','registrations'].every(p => P.pageAllowed(p)));

  // ⚠️ حارس الانحدار: مستخدم قائم بصلاحيات مكتوبة صراحةً وبلا المفتاح الجديد
  asUser({ can_create_po:true, can_edit_po:true }, []);
  T('مستخدم قائم بلا مفتاح المبالغ يبقى يراها (userDefault:true)',
    P.canViewAmounts() === true && P.fmtPrice(1500) === '1,500');
  T('نظيره في نموذج الصلاحيات يُرسَم مُحدَّداً لا فارغاً',
    P.effectivePerm({ can_create_po:true }, 'can_view_amounts', 'user') === true);
  T('ومفتاح افتراضه false يبقى غير مُحدَّد',
    P.effectivePerm({ can_create_po:true }, 'can_delete', 'user') === false);

  asUser({ can_view_amounts:false }, ['الصيانة والتشغيل']);
  T('الموظّف المُنطَّق لا يرى رقماً نقديّاً',
    P.fmtPrice(1500) === '—' && P.fmtPrice(0) === '—' && P.tafqitSAR(1500) === '—');
  asUser({ can_view_amounts:true }, ['الصيانة والتشغيل']);
  T('ومنحُه المفتاح يُعيدها (قابلية الضبط لا قاعدة مثبَّتة)',
    P.fmtPrice(1500) === '1,500');
  asUser({}, [], 'admin');
  T('المدير يرى المبالغ دائماً', P.canViewAmounts() === true && P.fmtPrice(12) === '12');

  /* ⚠️ عيب حقيقيّ كشفه المتصفّح لا الفحص النصّيّ: `can_manage_rfq` افتراضه
     **true** (مفتاح موظّفي المكتب)، فصفّ موظّف صيانة لا يذكره كان يُقرأ «من
     المشتريات» — تبويب الوارد وأزرار «بدأت العمل عليه» وقائمةُ طلبات زملائه
     بدل طلباته. الخادم كان يرفض الفعل (`pr_has_perm` افتراضه false) فالأثر
     واجهة وسعة قائمة؛ والعلاج: للمُنطَّق المنح صريح أو لا شيء. */
  asUser({ can_receive_po:true, can_view_amounts:false }, ['الصيانة والتشغيل']);
  T('المفتاح الغائب لا يجعل الموظّف الميدانيّ «مشتريات»',
    P.prIsProcurement() === false && P.prCanSeeAll() === false);
  /* ⚠️ وهذا هو الفرق الجوهريّ: `hasPermission` نفسها صارت صارمة للمُنطَّق.
     كانت تسقط لافتراضيّ الدور فتمنحه can_edit_po/can_create_po/can_import/
     can_export/can_use_ai — أزرارٌ يراها والخادم يرفضها
     (po_update/po_insert = NOT proc_is_scoped()). المنح صريح أو لا شيء. */
  T('ومفاتيح الكتابة الغائبة لا تُمنَح له ضمنياً',
    ['can_edit_po','can_create_po','can_delete_po','can_import','can_export',
     'can_use_ai','can_manage_suppliers','can_review_registrations','can_view_audit']
      .every(k => P.hasPermission(k) === false)
    && P.hasPermission('can_receive_po') === true);
  T('و`prPermStrict` صارت مطابِقة لـ`hasPermission` (لا بوّابتان تتفارقان)',
    P.DEFAULT_PERMISSIONS.user.can_edit_po === true
    && ['can_edit_po','can_manage_rfq','can_receive_po','can_view_amounts']
         .every(k => P.prPermStrict(k) === P.hasPermission(k)));
  asUser({ can_manage_rfq:true }, ['الصيانة والتشغيل']);
  T('والمنح الصريح يعمل (لا قاعدة مثبَّتة)', P.prIsProcurement() === true);
  asUser({ can_approve_l1:true }, ['الصيانة والتشغيل']);
  T('ومعتمِد قطاعٍ مُنطَّق يبقى يرى طلبات قطاعه',
    P.prCanSeeAll() === true && P.prIsProcurement() === false);
  // عدم انحدار: موظّف المكتب بلا مفتاح صريح يبقى «مشتريات» كما اليوم حرفيّاً
  asUser({ can_create_po:true, can_edit_po:true }, []);
  T('وموظّف المكتب غير المُنطَّق يبقى «مشتريات» (صفر انحدار)',
    P.prIsProcurement() === true && P.prCanSeeAll() === true);
  /* ⚠️ الحارس الأهمّ في هذا القسم: الصرامة **للمُنطَّق وحده**. صفوف موظّفي
     المكتب القائمين لا تحمل أكثر المفاتيح، فلو تسرّبت الصرامة إليهم فقدوا
     أدواتهم كلّها في لحظة نشر. */
  asUser({}, []);
  T('وصفٌّ بلا أي مفتاح يبقى على افتراضيّ الدور ما دام غير مُنطَّق',
    ['can_edit_po','can_create_po','can_import','can_export','can_use_ai',
     'can_manage_suppliers','can_view_amounts'].every(k => P.hasPermission(k) === true)
    && P.hasPermission('can_receive_po') === false
    && P.hasPermission('can_delete_po') === false);

  /* ⚠️ والمنع الصريح يبقى أقوى من كل شيء: `false` مكتوبة تُحترَم للطرفين. */
  asUser({ can_edit_po:false }, []);
  T('والمنع الصريح يُحترَم لغير المُنطَّق أيضاً', P.hasPermission('can_edit_po') === false);
  asUser({}, ['الصيانة والتشغيل'], 'admin');
  T('والأدمن يبقى فوق الصرامة ولو أُسنِد له قطاع',
    P.hasPermission('can_edit_po') === true && P.canViewAmounts() === true);

  /* الزرّان العائمان: لا يخصّانه، ويغطّيان أزرار «القائمة/اللوحة/الإنذارات»
     على 393px (مقيسٌ في المتصفّح). */
  /* ⚠️ يقرأ HTML لا CODE: الأخير جافاسكربت بلا CSS ولا ترميز، فتأكيدٌ عليه
     يمرّ فراغاً (وقع فعلاً في أوّل صياغة لهذا القسم). */
  T('الزرّان العائمان (الذكاء والجرس) مخفيّان عن الموظّف المُنطَّق',
    /body\.role-scoped\s+\.ai-fab\s*,\s*body\.role-scoped\s+#wf-bell\s*\{[^}]*display:\s*none/.test(HTML));

  /* عنوان مجموعة بلا وجهة تحته = ضجيج. الشريط مسطّح فلا حاوية تُخفى معها. */
  T('عناوين مجموعات الشريط الجانبي الفارغة تُخفى',
    /function hideEmptyNavLabels\s*\(/.test(CODE)
    && /hideEmptyNavLabels\(\);\s*\n\}/.test(CODE.slice(CODE.indexOf('function applyScopedNav'))));

  /* نصّ يَعِد بما أُلغي أسوأ من نصٍّ ناقص: قرار المالك «متابعة لا وورك فلو». */
  T('لا نصّ مرئيّ يَعِد بسلسلة موافقات أُلغيت',
    !/سلسلة الموافقات/.test(HTML)
    && !/page-subtitle">[^<]*سلسلة الاعتماد/.test(HTML)
    && !/subtitle:'[^']*سلسلة الاعتماد/.test(CODE)
    && !/desc:'[^']*سلسلة الاعتماد/.test(CODE));

  /* ⚠️ ثلاث بوّابات في صفّ أزرار الدرج كشفتها الصرامة ولم تُحدِثها:
     — «📦 استلام» كان محكوماً بـcan_edit_po وحده، بينما `poReceiveOpen`
       تقبل can_edit_po **أو** can_receive_po: بوّابة الزرّ أضيق من بوّابة
       الفعل، فموظّف الميدان لا يرى زرّ عمله الأساسيّ.
     — «▶ <المرحلة التالية>» و«إلغاء» كانا **بلا أي بوّابة صلاحية**، بينما
       `changePOStatus` ترفضهما بـrequirePermission('can_edit_po'). */
  T('زرّ الاستلام يتبع بوّابة فعله لا بوّابة أضيق',
    /const canRecv\s*=\s*canEdit \|\| hasPermission\('can_receive_po'\)/.test(CODE)
    && /\$\{\(canRecv &&[^}]*poReceiveOpen/.test(CODE)
    && !/\$\{\(canEdit && !PO_TERMINAL\.includes\(po\.status\) && Array\.isArray\(po\.items\)/.test(CODE));
  T('وزرّا نقل المرحلة والإلغاء صارا خلف صلاحية التعديل',
    /\$\{\(canEdit && _nextStage\)\?/.test(CODE)
    && /\$\{\(canEdit && !PO_TERMINAL\.includes\(po\.status\)\)\?[\s\S]{0,240}?'ملغى'/.test(CODE));

  /* شريط الفجوات على قائمةٍ مُصفّاة بطبيعتها = إنذار كاذب: أرقام القطاعات
     الأخرى تبدو «مفقودة» وهي مسجَّلة. نفس قاعدة التقارير المُصفّاة. */
  T('لا إنذار فجوات تسلسل للموظّف المُنطَّق (قائمته مُصفّاة بالقطاع)',
    /function renderPOSeqBar\(\)\{[\s\S]{0,700}?if\(isScopedUser\(\)\)\{ el\.innerHTML=''; return; \}/.test(CODE));
  /* وبطاقةٌ قيمتها «—» دائماً ليست حجباً بل ضجيج. */
  T('بطاقتا قيمة المشتريات وصحة النظام تسقطان عمّن لا يعنيانه',
    /if\(k\.label === 'قيمة المشتريات'\)\s*return canViewAmounts\(\);/.test(CODE)
    && /if\(k\.label === 'مؤشر صحة النظام'\)\s*return !isScopedUser\(\);/.test(CODE));

  /* نظيرة الصرامة على الخادم — وإلّا أخفت الواجهة ما يُرسله الخادم فعلاً. */
  {
    const LP = fs.readFileSync(path.join(ROOT, 'db/system2-scoped-least-privilege.sql'), 'utf8');
    /* ⚠️ و`coalesce` الداخليّة ليست تجميلاً: `scope_sectors` عمودها NULL لكل
       موظفي المكتب، فبدونها يُنتج التعبير NULL لا true ويفقد الأربعةُ
       القائمون مبالغهم لحظة النشر (أمسكه LP1 قبل أي تطبيق حيّ). */
    T('SQL: افتراضيّ «عرض المبالغ» يُصفَّر للمُنطَّق ويبقى true لغيره',
      /CREATE OR REPLACE FUNCTION proc_can_view_amounts/.test(LP)
      && /NOT coalesce\(\s*CASE WHEN jsonb_typeof\(u\.scope_sectors\) = 'array'/.test(LP)
      && /THEN jsonb_array_length\(u\.scope_sectors\) > 0 END,\s*false\)/.test(LP));
  }
}

/* ── ٣١) دورة الطلب: مسار الطالب · الاستفهام · القوالب · مراحل المشتريات ──
   طلب المالك: «يظهر لهم حالة الطلب، من استلمه ومن بدأ في تسعيره وكم له يوم
   منذ أن بدأ العمل به، ويمكن للمشتريات إرجاعه للتعديل أو الاستفهام من خلال
   النظام، وحفظ الطلبات الشهرية المتكررة بكمّياتها ومسمّياتها».
   الحدّ الحوكميّ في `db/system2-request-flow.sql`؛ وهذه تحرس طبقة الواجهة
   **سلوكيّاً** (تُشغّل الدوال فعلاً) لا نصّيّاً. */
{
  G('٣١) دورة الطلب: المسار والاستفهام والقوالب');

  const FLOW      = fs.readFileSync(path.join(ROOT, 'db/system2-request-flow.sql'), 'utf8');
  const NOTIFY    = fs.readFileSync(path.join(ROOT, 'functions/api/notify.js'), 'utf8');
  const PR_SHARED = fs.readFileSync(path.join(ROOT, 'functions/api/_pr-shared.js'), 'utf8');

  // ── بنيويّ: مراحل المشتريات صارت محكومة ──
  T('مراحل المشتريات تمرّ بـRPC لا بـUPDATE مباشر',
    /rpc\('pr_proc_stage', \{p_pr_id:id, p_stage:stage\}\)/.test(CODE)
    && /async function prStart\(id\)\{ return prProcStage\(id,'in_progress'\); \}/.test(CODE)
    && /async function prQuotesDone\(id\)\{ return prProcStage\(id,'quotes_collected'\); \}/.test(CODE));

  /* ⚠️ السقوط للمسار القديم مشروط **حصراً** بغياب الدالّة من القاعدة (أي أنّ
     الحارس غير موجود بعد)، فلا يصلح بوّابةً خلفيّة حول حارس قائم. أي كتابة
     مباشرة لـproc_status خارج هذا الفرع = تجاوز. */
  const directStage = (CODE.match(/proc_status:'(in_progress|quotes_collected)'/g) || []).length;
  T('الكتابة المباشرة للمرحلة محصورة في فرع «الدالّة غير موجودة»',
    /if\(!prFnMissing\(error\)\) throw error;[\s\S]{0,700}from\('proc_purchase_requests'\)[\s\S]{0,200}\.update\(/.test(CODE)
    && directStage === 2, 'كتابات مباشرة = ' + directStage);
  T('كشف غياب الدالّة يغطّي رمز PostgREST ورمز Postgres معاً',
    /PGRST202\|42883/.test(CODE));

  // ── بنيويّ: قناة إشعار واحدة، والاتجاه يُحسَب على الخادم ──
  const notifyCalls = (CODE.match(/fetch\('\/api\/notify'/g) || []).length;
  T('قناة إشعار واحدة للطلبات (لا ترويسة/جسم مكرّران)',
    /async function prNotifyPR\(prId, event, comment\)/.test(CODE)
    && /prNotifyPR\(pr\.id, 'submitted'\)/.test(CODE)
    && /prNotifyPR\(id, META\.ev\)/.test(CODE)
    && /prNotifyPR\(prId, kind, txt\)/.test(CODE));
  T('العميل لا يمرّر وجهة البريد (يُحسَب من نوع الحدث على الخادم)',
    !/body\.to\s*=|recipient:/.test(CODE.slice(CODE.indexOf('async function prNotifyPR'),
                                               CODE.indexOf('async function prNotifyPR') + 700))
    && /const TO_REQUESTER\s+= \[/.test(NOTIFY) && /const TO_PROCUREMENT\s+= \[/.test(NOTIFY));
  T('أحداث المشتريات والاستفهام معرَّفة في قوالب البريد',
    ['proc_started','quotes_collected','question','answer']
      .every(e => PR_SHARED.includes(`${e}:`)));

  // ── بنيويّ: الجدولان الاختياريّان يُجلبان بتسامح ──
  T('المحادثة والقوالب تُجلبان بتسامح (الواجهة تعمل قبل الترقية)',
    /window\.__prMsgOK = false/.test(CODE) && /window\.__prTplOK = false/.test(CODE)
    && /p\.messages\s*=\s*\(msByPr\[p\.id\]\|\|\[\]\)\.sort\(\(a,b\)=>\(a\.id\|\|0\)-\(b\.id\|\|0\)\)/.test(CODE)
    && /STATE\.prTemplates = \(tpls\|\|\[\]\)/.test(CODE));

  // ── بنيويّ: الحوكمة في القاعدة ──
  T('SQL: المعالجة تتطلّب صلاحية مشتريات وطلباً معتمَداً',
    /pr_has_perm\('can_manage_rfq'\) OR pr_is_admin\(\)/.test(FLOW)
    && /v_pr\.status <> 'approved'/.test(FLOW));
  T('SQL: تقدّم للأمام فقط (لا يُمحى أثر من عمل على الطلب)',
    /انتقال غير مسموح/.test(FLOW) && /v_cur = 'completed'/.test(FLOW));
  T('SQL: الاستفهام لا يُغيّر حالة الطلب ولا يمسّ سلسلة الاعتماد',
    !/UPDATE proc_purchase_requests/.test(
      FLOW.slice(FLOW.indexOf('FUNCTION pr_post_message'), FLOW.indexOf('FUNCTION pr_proc_stage'))));
  T('SQL: لا سياسة INSERT على المحادثة (لا انتحال مؤلِّف)',
    /لا سياسة INSERT\/UPDATE\/DELETE/.test(FLOW)
    && !/CREATE POLICY "prmsg_insert"/.test(FLOW));
  T('SQL: الاستفهام مقيَّد برؤية الطلب وبطول محدود',
    /NOT proc_can_see_pr\(p_pr_id\)/.test(FLOW) && /length\(v_txt\) > 4000/.test(FLOW));
  T('SQL: القوالب يكتبها صاحبها ويراها قطاعه',
    /lower\(owner\) = lower\(proc_me\(\)\)/.test(FLOW)
    && /sector = ANY\(proc_scope_sectors\(\)\)/.test(FLOW));
  T('SQL: تنفيذ الدالّتين مسحوب من anon',
    /REVOKE ALL ON FUNCTION pr_post_message[\s\S]{0,120}FROM PUBLIC, anon/.test(FLOW)
    && /REVOKE ALL ON FUNCTION pr_proc_stage[\s\S]{0,120}FROM PUBLIC, anon/.test(FLOW));

  /* ⚠️ كشفهما المتصفّح: تبويب «الوارد للمشتريات» كان يظهر للموظّف الميدانيّ
     بعدّاد (شاشة مقفلة عليه = ضجيج يوهمه بعملٍ ينتظره)، وسطر الإجمالي كان
     يعرض «— ر.س» = وحدة عملة بلا رقم. */
  /* ⚠️ «متابعة وليس وورك فلو» (قرار المالك 2026-09-10): لا تبويب اعتماد ولا
     شاشة أقسام إطلاقاً — وجودها يعيد فتح باب أغلقه القرار. */
  T('لا تبويب اعتماد ولا شاشة أقسام في شاشة الطلبات',
    /\$\{isProc \? prTab\('incoming'/.test(CODE)
    && !/prTab\('inbox'/.test(CODE) && !/prTab\('depts'/.test(CODE)
    && /if\(view==='inbox' \|\| view==='depts'\) view = 'list';/.test(CODE));
  /* ⚠️ عيبٌ وقع فعلاً وأمسكه المتصفّح وحده: بقي `const showInbox = inboxN > 0`
     بعد حذف `inboxN` ⇒ ReferenceError يُفرِغ شاشة الطلبات كاملةً، و`node --check`
     لا يراه (خطأ تنفيذ لا صياغة). الحارس: لا مرجع لمتغيّرات الاعتماد المحذوفة. */
  /* ⚠️ إنذار كاذب: اللافتة كانت تقول إن الطلب سيقف بلا معتمِد ما لم تُضبَط
     الأقسام — وهو صحيح للوورك فلو وباطل للمتابعة. أمسكها المتصفّح. */
  T('لا لافتة «اضبط الأقسام ومدراءها» في نموذج الطلب',
    !/لم تُضبَط الأقسام ومدراؤها/.test(CODE)
    // اللافتة الوحيدة في رأس النموذج صارت لافتة «تُكمل مسودّة» لا إنذار اعتماد.
    && /const _deptWarn = __prEditId/.test(CODE)
    && /تُكمل الآن المسودّة/.test(CODE));
  T('لا مرجع متبقٍّ لمتغيّرات الاعتماد المحذوفة',
    !/\binboxN\b/.test(CODE) && !/\bshowInbox\b/.test(CODE) && !/\binboxLabel\b/.test(CODE));
  T('ولا لوحة قرار اعتماد في شاشة المتابعة',
    // لا قرار اعتماد إطلاقاً — واللوحة الوحيدة هناك هي إكمال المسودّة.
    !/prAct\s*\(/.test(CODE) && !/prActPrompt/.test(CODE)
    && /const actionPanel = \(pr\.status==='draft'\)/.test(CODE)
    && /prEditDraft\('\$\{escapeAttr\(pr\.id\)\}'\)/.test(CODE));
  T('وحدة العملة تختفي مع الرقم المحجوب (لا «— ر.س»)',
    /\$\{fmtPrice\(pr\.est_total\)\}\$\{canViewAmounts\(\)\?' ر\.س':''\}/.test(CODE));

  // ── سلوكيّ: صندوق يُشغّل دوال العرض الحقيقية ──
  const R = (() => {
    const src = [
      `const STATE = { currentUser:null, prTemplates:[], purchaseRequests:[] };`,
      `const window = { __prTplOK:true };`,
      `let __perms = {}; let __proc = false;`,
      `function hasPermission(k){ return __perms[k] === true; }`,
      grab('escapeHtml'), grab('escapeAttr'), grab('poDays'),
      grab('prDaysSince'), grab('prSinceText'), grab('prIsLive'),
      `function prIsProcurement(){ return __proc; }`,
      grab('prJourneyHTML'), grab('prThreadHTML'), grab('prTemplatesHTML'),
    ].join('\n\n');
    return new Function(src + `; return {STATE, window, prDaysSince, prSinceText,
      prJourneyHTML, prThreadHTML, prTemplatesHTML,
      setUser:(u,proc)=>{ STATE.currentUser=u; __proc=!!proc; }};`)();
  })();

  const daysAgo = n => new Date(Date.now() - n*86400000).toISOString();

  T('عمر الطلب بالأيام يُحسب من الطابع الزمنيّ',
    R.prDaysSince(daysAgo(5)) === 5 && R.prDaysSince(null) === null
    && R.prDaysSince('ليس تاريخاً') === null && R.prSinceText(daysAgo(0)) === 'اليوم');

  // المطلب الحرفيّ: «من بدأ في تسعيره وكم له يوم منذ أن بدأ العمل به»
  const jr = R.prJourneyHTML({ id:'PR-1', status:'approved', proc_status:'in_progress',
    created_at: daysAgo(9), proc_started_by:'ahmad', proc_started_at: daysAgo(3) });
  T('مسار الطالب يسمّي من بدأ العمل ويُبرز عمره بالأيام',
    jr.includes('ahmad') && jr.includes('منذ بدء العمل عليه') && jr.includes('3 أيام'));
  T('وقبل بدء العمل يُحسب العمر من إرسال الطلب لا صفراً مضلّلاً',
    (() => { const h = R.prJourneyHTML({ id:'PR-2', status:'approved', proc_status:'received',
               created_at: daysAgo(4) });
             return h.includes('منذ إرسال الطلب') && h.includes('4 أيام'); })());
  /* ⚠️ المسار صار **متابعة**: لا مرحلة «سلسلة اعتماد» ولا «بانتظار مَن يعتمد».
     خلاصته «صدر أمر الشراء رقم …» — وهو ما طلبه المالك حرفيّاً. */
  T('مسار الطالب بلا أي مرحلة اعتماد',
    (() => { const h = R.prJourneyHTML({ id:'PR-3', status:'submitted', proc_status:'received',
               created_at: daysAgo(1) });
             return !h.includes('سلسلة الاعتماد') && !h.includes('بانتظار:')
                    && h.includes('أُرسل الطلب للمشتريات') && h.includes('وصل المشتريات'); })());
  T('وخلاصته «صدر أمر الشراء رقم …» قابلاً للنقر',
    (() => { const h = R.prJourneyHTML({ id:'PR-4', status:'submitted', proc_status:'po_issued',
               created_at: daysAgo(2), po_number:'P.O-DG26-3210' });
             return h.includes('P.O-DG26-3210') && h.includes('prOpenLinkedPO')
                    && h.includes('صدر لهذا الطلب'); })());
  T('والمسودّة لا تُعرَض كأنها وصلت المشتريات',
    (() => { const h = R.prJourneyHTML({ id:'PR-5', status:'draft', created_at: daysAgo(1) });
             return !h.includes('صدر لهذا الطلب'); })());

  // الاستفهام: المشتريات تسأل، والطالب يجيب — بلا تغيير حالة
  const pr = { id:'PR-9', requester:'field1', messages:[
    {id:1, kind:'question', body:'هل الكمية 10 أم 100؟', author:'proc1', author_name:'أحمد', created_at:'2026-09-01T08:00:00Z'},
    {id:2, kind:'answer',   body:'100', author:'field1', author_name:'سالم', created_at:'2026-09-01T09:00:00Z'}]};
  R.setUser({username:'proc1', role:'user'}, true);
  const th1 = R.prThreadHTML(pr);
  T('المشتريات ترى صندوق استفهام والحوار كاملاً',
    th1.includes("prPostMessage('PR-9','question')")
    && th1.includes('هل الكمية 10 أم 100؟') && th1.includes('أحمد'));
  R.setUser({username:'field1', role:'user'}, false);
  T('والطالب يرى صندوق الردّ لا الاستفهام',
    R.prThreadHTML(pr).includes("prPostMessage('PR-9','answer')")
    && !R.prThreadHTML(pr).includes("'question')"));
  R.setUser({username:'other', role:'user'}, false);
  T('وغريبٌ بلا رسائل لا يرى اللوحة أصلاً',
    R.prThreadHTML({ id:'PR-8', requester:'field1', messages:[] }) === '');

  // القوالب
  R.setUser({username:'field1', role:'user'}, false);
  R.STATE.prTemplates = [
    { id:'TPL-A', name:'مستلزمات برج الشمال الشهرية', owner:'field1', sector:'الصيانة والتشغيل',
      project:'برج الشمال', items:[{description:'فلتر',requested_qty:10},{description:'زيت',requested_qty:4}],
      use_count:3, last_used_at:'2026-08-01' },
    { id:'TPL-B', name:'قالب زميل', owner:'field2', sector:'الصيانة والتشغيل', items:[{description:'كرتون'}] },
  ];
  const tpl = R.prTemplatesHTML();
  T('لوحة القوالب تعرض الاسم وعدد البنود وزرّ الإنشاء',
    tpl.includes('مستلزمات برج الشمال الشهرية') && tpl.includes("prUseTemplate('TPL-A')")
    && tpl.includes('>2<') && tpl.includes('استُخدم 3 مرّة'));
  T('وحذف القالب لصاحبه وحده',
    tpl.includes("prDeleteTemplate('TPL-A')") && !tpl.includes("prDeleteTemplate('TPL-B')"));
  R.STATE.prTemplates = [];
  T('وبلا قوالب ترشد لصنع أوّل قالب لا تترك فراغاً',
    R.prTemplatesHTML().includes('حفظ كقالب متكرّر'));
  R.window.__prTplOK = false;
  T('وقبل تطبيق الترقية تقول ذلك صراحةً (لا فشل صامت)',
    R.prTemplatesHTML().includes('system2-request-flow.sql'));
  R.window.__prTplOK = true;

  // ⚠️ القالب بيانات لا التزام: استدعاؤه يملأ نموذجاً يمرّ بالسلسلة كاملةً.
  T('القالب لا يختصر أي اعتماد (يملأ نموذج طلب جديد فقط)',
    /async function prUseTemplate\(id\)\{[\s\S]{0,900}STATE\.prView = 'create'/.test(CODE)
    && !/prUseTemplate[\s\S]{0,900}prBuildChain/.test(CODE));
  /* ⚠️ قطاع القالب لا يُفرَض إن كان خارج نطاق الموظّف — وإلّا ضاع الطلب بين
     قطاعين: لا هو يراه ولا مدير قطاعه. */
  T('قطاع القالب يُقبل فقط إن كان خياراً متاحاً للموظّف',
    /\[\.\.\.sc\.options\]\.some\(o=>o\.value===t\.sector\)/.test(CODE));
}

/* ── ٣٢) متابعة لا وورك فلو — سند موقَّع + ربط أمر الشراء ─────────
   تصحيح نموذج بقرار المالك: «نظام بسيط وليس وورك فلو… ما في مواضيع اعتمادات
   وقصص طويلة، إلا إذا مكنتهم من رفع الطلب PDF موقع من المدير… ورفعنا أمر
   الشراء يظهر لهم ونقدر نربط الأمر بالطلب… وخلاص متابعة.» */
{
  G('٣٢) متابعة لا وورك فلو: السند والربط');

  const TRACK  = fs.readFileSync(path.join(ROOT, 'db/system2-request-tracking.sql'), 'utf8');
  const NOTIFY2    = fs.readFileSync(path.join(ROOT, 'functions/api/notify.js'), 'utf8');
  const PR_SHARED2 = fs.readFileSync(path.join(ROOT, 'functions/api/_pr-shared.js'), 'utf8');
  const PRDOC  = fs.readFileSync(path.join(ROOT, 'functions/api/pr-doc.js'), 'utf8');

  // ── لا اعتمادات ──
  T('الطلب يُرسَل مباشرةً للمشتريات (لا in_review ولا بناء سلسلة)',
    /currency:'SAR', status:'draft'/.test(CODE)
    && !/prBuildChain/.test(CODE)
    && !/status\s*:\s*'in_review'/.test(CODE));
  T('SQL: سلسلة الاعتماد مُطفأة تعطيلاً لا حذفاً (قابلة للإحياء)',
    /UPDATE proc_approval_rules SET active = false/.test(TRACK)
    && !/DROP TABLE[\s\S]{0,60}proc_approval_rules/.test(TRACK));

  // ── السند الموقَّع: إلزاميّ، ودليل لا ادّعاء ──
  T('لا إرسال بلا سند موقَّع (والمسودّة تُحفظ بدونه)',
    // `existingDoc` = مسودّة رُفِع سندها سابقاً — لا تُطالَب بإرفاقه مرّتين.
    /if\(!asDraft && !__prDraftDoc && !existingDoc\)\{[\s\S]{0,220}return;/.test(CODE)
    && /السند مطلوب/.test(CODE));
  T('حقل الرفع في النموذج بصيغ مقبولة وحدّ حجم',
    /id="pr-doc-input"[\s\S]{0,140}accept="application\/pdf,image\/jpeg,image\/png"/.test(CODE)
    && /PR_DOC_MAX\s*=\s*10 \* 1024 \* 1024/.test(CODE));
  T('نقطة الرفع تمرّ بحارس الملفات الطبقيّ نفسه',
    /import \{ inspectUpload, fileResponseHeaders, MAX_UPLOAD_BYTES \} from '\.\/_file-guard\.js'/.test(PRDOC)
    && /const check = inspectUpload\(buf\)/.test(PRDOC));
  /* ⚠️ المفتاح يُولَّد خادميّاً من التوقيع السحريّ لا من اسم الملف ولا من
     Content-Type الذي أرسله العميل — وإلّا رُفِع تحت مجلّد طلب آخر. */
  T('المفتاح خادميّ والامتداد من التوقيع لا من اسم الملف',
    /const key = `\$\{PREFIX\}\$\{prId\}\/\$\{crypto\.randomUUID\(\)\}\.\$\{check\.ext\}`/.test(PRDOC)
    && /contentType: check\.ct/.test(PRDOC));
  T('الرؤية تُفحص بهوية المتصل (RLS هي الحكم) وتفشل مغلقةً',
    /rpc\/proc_can_see_pr/.test(PRDOC)
    && /return \(await r\.json\(\)\) === true;/.test(PRDOC)
    && /catch \(_\) \{ return false; \}/.test(PRDOC));
  /* ⚠️ الفحص على **الوصول الفعليّ** لا على ذِكر الاسم: التعليق يشرح العزل
     ويسمّي حاوية البوابة، وحظر النصّ كان سيمنع توثيق القاعدة نفسها. */
  T('ولا يلمس حاوية البوابة (النظام 3 معزول)',
    !/env\s*(?:\.\s*QUOTES_BUCKET|\[\s*['"`]QUOTES_BUCKET)/.test(PRDOC)
    && /env\.SUPPLIER_DOCS/.test(PRDOC));
  T('SQL: مفتاح السند مقيَّد بمجال الطلب نفسه',
    /p_key NOT LIKE \('docs\/pr\/' \|\| p_pr_id \|\| '\/%'\)/.test(TRACK));

  // ── ربط أمر الشراء: جوهر المتابعة ──
  T('SQL: لا ربط برقم أمر غير موجود',
    /NOT EXISTS \(SELECT 1 FROM proc_purchase_orders WHERE po_number = v_po\)/.test(TRACK));
  T('SQL: الربط صلاحية مشتريات ويترك أثر تدقيق',
    /ربط أمر الشراء يتطلّب صلاحية المشتريات/.test(TRACK)
    && /'pr_link_po'/.test(TRACK) && /'pr_unlink_po'/.test(TRACK));
  T('SQL: «صدر أمر الشراء» لا تُدَّعى بزرّ بل يثبتها الربط',
    /p_stage = 'po_issued' AND coalesce\(v_pr\.po_number,''\) = ''/.test(TRACK));
  /* ⚠️ اختيار من قائمة لا كتابة حرّة: رقمٌ بكتابة مختلفة يكسر الربط بصمت
     (درس توحيد المشاريع). */
  T('الواجهة تربط باختيار من قائمة الأوامر القائمة لا بحقل حرّ',
    /<select class="select" id="pr-po-pick"/.test(CODE)
    && /rpc\('pr_link_po', \{ p_pr_id: prId, p_po_number: num \}\)/.test(CODE));
  /* ⚠️ لا يكفي وجود النصّ في الملف: يجب أن **يصل العرض**. أوّل صياغة فحصت
     التعريف فقط، فحذفُ سطر التركيب مرّ بلا إخفاق — تأكيدٌ فراغيّ. */
  T('والربط عكسيّ كذلك: درج الأمر يقول عن أي طلب صدر',
    /const _srcPr = \(STATE\.purchaseRequests\|\|\[\]\)\.find\(r => r && r\.po_number === po\.po_number\)/.test(CODE)
    && /صادر عن طلب الشراء/.test(CODE)
    && /const _ageBanner = _ageBanner0 \+ _srcPrHtml;/.test(CODE)
    && /\$\{_ageBanner\}/.test(CODE));
  T('وإشعار البريد بصدور الأمر يذهب للطالب',
    /prNotifyPR\(prId, 'po_issued', num\)/.test(CODE)
    && /'po_issued'/.test(NOTIFY2) && /po_issued:/.test(PR_SHARED2));

  // ── الوارد للمشتريات = ما لم يصدر له أمر بعد ──
  T('الوارد يستثني ما صدر له أمر شراء أو أُقفل',
    /prIsLive\(p\) && !\['po_issued','closed','completed'\]\.includes\(p\.proc_status\|\|''\)/.test(CODE));
  T('وبطاقة لوحة المهام صارت متابعةً لا اعتماداً',
    /طلبات شراء لم يصدر لها أمر بعد/.test(CODE)
    && !/طلبات شراء بانتظار اعتمادك/.test(CODE));

  // ── عرض السند داخل النظام لا في تبويب خارجيّ ──
  T('السند يُفتح داخل النظام بحقن blob في عارض المستندات',
    /DOCV\.blobs\.set\(pr\.doc_key, blob\)/.test(CODE)
    && /docvOpen\(\[\{ path: pr\.doc_key/.test(CODE));
  T('وسكّ روابط التخزين مقصور على وثائق التسجيل',
    /filter\(p => p && \/\^\(\?:supplier-docs\\\/\)\?DG-\/\.test\(p\)/.test(CODE));
}

/* ── ٣٣) رابط دعوة موظفي القطاع ──────────────────────────────────
   طلب المالك: «رابط لدعوة موظفين ومدير الصيانة والتشغيل للدخول وتسجيل بياناتهم
   لتوصلهم الإشعارات والمتابعة». وقراراته: رابط واحد للقطاع · بريد الشركة حصراً
   · الحساب ينتظر التفعيل.
   ⚠️ سلوك النقطة مُختبَر بـ22 تأكيداً في `db/portal-tests/file-guard.test.mjs`
   (منها أنّ الحساب يُنشأ موقوفاً والقطاع من الرمز). هنا **ما لا يُمسَك سلوكيّاً**:
   خصائص زمنية/بنيوية وسلامة الصفحة العامّة. */
{
  G('٣٣) رابط دعوة موظفي القطاع');

  const SINV = fs.readFileSync(path.join(ROOT, 'functions/api/staff-invite.js'), 'utf8');
  const SPAGE = fs.readFileSync(path.join(ROOT, 'staff-register.html'), 'utf8');

  /* ⚠️ خاصيّة **زمنية** لا سلوكية: `===` و`timingSafeEq` يقبلان ويرفضان نفس
     المدخلات، فلا اختبار وظيفيّ يمسك الفرق — الحارس بنيويّ بالضرورة. */
  T('توقيع الرمز يُقارَن بمقارنة ثابتة الزمن',
    /if \(!timingSafeEq\(expect, parts\[1\]\)\) return null;/.test(SINV)
    && /d \|= x\.charCodeAt\(i\) \^ y\.charCodeAt\(i\)/.test(SINV));
  T('والرمز يحمل حمولته موقَّعة — لا جدول رموز ولا هجرة له',
    /crypto\.subtle\.importKey/.test(SINV) && !/proc_invitations/.test(SINV));
  T('والإبطال بمفتاح epoch في الإعدادات (نقرة تُسقِط كل الروابط)',
    /key=eq\.staff_invite/.test(SINV) && /action === 'revoke'/.test(SINV));
  T('ومدّة الصلاحية مسقوفة', /Math\.min\(MAX_DAYS/.test(SINV) && /MAX_DAYS = 60/.test(SINV));

  /* الحقول الحوكمية مفروضة نصّاً في الخادم — لا تُقرأ من جسم الطلب إطلاقاً. */
  T('الدور والصلاحيات والحالة مفروضة خادميّاً لا من العميل',
    /role: 'user', permissions: FIELD_PERMISSIONS, active: false,/.test(SINV)
    && /scope_sectors: \[p\.s\]/.test(SINV)
    && /FIELD_PERMISSIONS = \{ can_receive_po: true, can_view_amounts: false \}/.test(SINV));
  T('وسقف الصفوف المعلّقة معرَّف', /MAX_PENDING_PER_SECTOR = \d+/.test(SINV));

  /* الصفحة العامّة: بلا فهرسة وبلا أي مصدر خارجيّ (آمنة CSP كصفحات المورّدين). */
  T('صفحة التسجيل غير مفهرسة',
    /<meta name="robots" content="noindex,nofollow">/.test(SPAGE));
  T('وبلا أي مصدر خارجيّ (آمنة CSP)',
    !/https?:\/\//.test(SPAGE.replace(/<!--[\s\S]*?-->/g, '')));
  T('وحقولها 16px فلا يُقرّب iOS الشاشة تلقائياً',
    /input\{[^}]*font-size:16px/.test(SPAGE));
  T('وترفع للنقطة الخادمية لا للقاعدة مباشرةً',
    /fetch\('\/api\/staff-invite/.test(SPAGE) && !/supabase/i.test(SPAGE));

  // الواجهة الإدارية
  T('زرّ الرابط في لوحة المستخدمين محكوم بصلاحية إدارية',
    /id="btn-staff-invite"/.test(HTML)
    && /requirePermission\('can_manage_users','رابط دعوة الموظفين'\)/.test(CODE));
  T('ويعرض الإبطال بجوار التوليد',
    /staffInviteMint\(\)/.test(CODE) && /staffInviteRevoke\(\)/.test(CODE));
  /* ⚠️ النافذة تُلحَق وقت التشغيل ⇒ يجب أن تُوسَم ephemeral وإلّا بقيت في DOM
     بمعرّف مكرَّر وتسرّب قفل التمرير (سابقة مثبَّتة في هذا الملف). */
  T('ونافذته المُلحَقة وقت التشغيل تُزال عند الإغلاق',
    /id='modal-staff-invite'; el\.dataset\.ephemeral='1'/.test(CODE)
    && /syncScrollLock\(\); a11yWire\(el\);/.test(CODE));
  /* ⚠️ الخادم يشترط `role==='admin'`؛ بوّابة الواجهة على `can_manage_users`
     وحدها كانت تُظهر الزرّ لمن سيُرفَض بعد النقر. */
  T('وبوّابة الزرّ توافق شرط الخادم (أدمن لا مجرّد مفتاح)',
    /STATE\.currentUser\?\.role !== 'admin'/.test(CODE)
    && /x\.role === 'admin' && x\.active !== false/.test(SINV));
  /* ⚠️ الإنتاج يحمل صفَّين يختلفان بحالة الأحرف فقط (`Abdullah` أدمن نشط ·
     `abdullah` موقوف)، و`emailToUsername` تُعيد الاسم بحروف صغيرة — فمطابقة
     `eq.` كانت ترفض المالك نفسه بـ403. (السلوك مُغطّى بتأكيد سلوكيّ كذلك.) */
  T('ومطابقة هوية الأدمن غير حسّاسة لحالة الأحرف',
    /username=ilike\./.test(SINV) && !/proc_users\?username=eq\./.test(SINV)
    && /replace\(\/\[\\\\%_\]\/g/.test(SINV));
  /* سقفُ المعلّقين وُصِف «لكل قطاع» وكان استعلامه عالميّاً بلا مرشّح قطاع. */
  T('وسقف المعلّقين مُنطاق فعلاً بالقطاع لا عالميّاً',
    /scope_sectors=cs\./.test(SINV) && /created_by=eq\.staff_invite/.test(SINV));
}

/* ══════════════════════════════════════════════════════════════════════════
   ٣٤) الترقيم الخادميّ · مسار المسودّة · ترتيب الإرسال
   --------------------------------------------------------------------------
   ثلاثة عيوب كشفها فحص ما بعد التنفيذ، كلّها **مرّت من فحوص نصّية** — فما
   يمكن إثباته سلوكيّاً يُثبَت بتشغيل الدالّة، لا بمطابقة نصّ.
   ══════════════════════════════════════════════════════════════════════════ */
{
  G('٣٤) الترقيم والمسودّة وترتيب الإرسال');
  const NUM    = fs.readFileSync(path.join(ROOT, 'db/system2-request-numbering.sql'), 'utf8');
  const TRACK  = fs.readFileSync(path.join(ROOT, 'db/system2-request-tracking.sql'), 'utf8');
  const SHARED = fs.readFileSync(path.join(ROOT, 'functions/api/_pr-shared.js'), 'utf8');

  // ① الترقيم لا يُشتقّ من القائمة المعروضة
  T('الرقم يأتي من `pr_next_number` الخادميّة لا من STATE',
    /await CLOUD\.client\.rpc\('pr_next_number'\)/.test(CODE)
    && /id: editing \? __prEditId : await prNextNumber\(\)/.test(CODE));
  T('والدالّة DEFINER تحت قفل استشاريّ (فلا تسابُق ولا رؤية مُصفّاة)',
    /SECURITY DEFINER/.test(NUM) && /pg_advisory_xact_lock\('pr_next_number'\)|pg_advisory_xact_lock\(hashtext\('pr_next_number'\)\)/.test(NUM));
  T('والسقوط للحساب المحلّي مشروط بغياب الدالّة وحده (لا يبتلع خطأً)',
    /if\(!prFnMissing\(e\)\) throw e;/.test(CODE));
  /* ⚠️ `upsert` مع رقمٍ مكرّر = كتابة فوق طلب قائم. الإنشاء `insert` صريح. */
  T('الإنشاء `insert` لا `upsert` (فالتعارض يُكشف لا يُبتلَع)',
    !/from\('proc_purchase_requests'\)\.upsert/.test(CODE)
    && /\? await tbl\.update\(pr\)\.eq\('id', pr\.id\)\s*:\s*await tbl\.insert\(pr\)/.test(CODE));

  // ② المسودّة تُفتح وتُكمَل
  T('المسودّة تُفتح للإكمال بمعرّفها لا كطلب جديد',
    /function prEditDraft\(id\)/.test(CODE) && /__prEditId = id;/.test(CODE)
    && /prSaveCloud\(pr, items, editing \? 'update' : 'insert'\)/.test(CODE));
  T('ولها مدخل ظاهر في القائمة وفي شاشة المتابعة',
    (CODE.match(/prEditDraft\('/g) || []).length >= 2
    && /إكمال المسودّة وإرسالها/.test(CODE));
  T('وفتح «طلب جديد» يُلغي وضع التعديل (لا يُحدَّث طلبٌ آخر بالخطأ)',
    /if\(view==='create'\)\{ __prDraftItems=\[\]; __prDraftDoc=null; __prEditId=null; \}/.test(CODE));

  // ③ ترتيب الإرسال: مسودّة → مرفق → إرسال → إشعار
  T('الطلب يُحفَظ مسودّةً ثمّ يُحوَّل بعد وصول السند',
    (() => {
      const i = CODE.indexOf('async function prSubmitNew');
      const body = CODE.slice(i, i + 3000);
      const save = body.indexOf('await prSaveCloud(pr, items');
      const up   = body.indexOf('await prUploadDoc(pr.id, __prDraftDoc)');
      const flip = body.indexOf(`.update({status:'submitted'`);
      const noti = body.indexOf(`prNotifyPR(pr.id, 'submitted')`);
      return save > 0 && up > save && flip > up && noti > flip;
    })());
  T('ولا تُكتب حالة `submitted` في صفّ الإنشاء إطلاقاً',
    !/status: asDraft\?'draft':'submitted'/.test(CODE));

  // ── SQL: الحُرّاس المرافقة ──
  T('SQL: حذف بنود الطلب بالرؤية لا بالنطاق (وإلّا تضاعفت عند إعادة الحفظ)',
    /CREATE POLICY "prc_delete" ON proc_pr_items FOR DELETE TO authenticated\s*\n\s*USING \(proc_can_see_pr\(pr_id\)\)/.test(NUM));
  T('SQL: السند لا يُمسَح بعد الإرسال (المرفق هو الاعتماد)',
    /لا يُزال سند الطلب بعد إرساله/.test(TRACK));
  T('SQL: أمر شراء واحد لطلب واحد',
    /WHERE po_number = v_po AND id <> p_pr_id/.test(TRACK));

  // ── الكتلة الميتة: لا إحياء ──
  T('كتلة سلسلة الاعتماد محذوفة بالكامل من الواجهة',
    ['prBuildChain','prMatchRule','prResolveApprover','prCurrentStage',
     'prCanActOn','prInbox(','prAct(','prActPrompt','prInboxHTML']
      .every(n => !CODE.includes(n)));
  T('ولا تُجلب جداولها في كل تحميل (رحلتا شبكة بلا قارئ)',
    !/fetchAll\('proc_pr_approvals'/.test(CODE)
    && !/fetchAll\('proc_approval_rules'/.test(CODE)
    && !/STATE\.prRules/.test(CODE));
  T('واشتراك اللحظيّ صار على المحادثة لا على سلسلة الاعتماد',
    !/table:'proc_pr_approvals'/.test(CODE) && /table:'proc_pr_messages'/.test(CODE));

  // ── البريد ──
  T('ردّ الطالب يصل مَن يعمل على طلبه فعلاً لا الفريق كلّه',
    /proc_started_by,quotes_collected_by/.test(SHARED)
    && /const owner = pr\.proc_started_by \|\| pr\.quotes_collected_by/.test(SHARED));
  T('ونصّ بريد الاستلام بلا ذِكر «سلسلة الاعتماد» المُلغاة',
    !/بدأ مساره في سلسلة الاعتماد/.test(SHARED));

  // ── سلوكيّ: نصّ مرحلة المتابعة مصدرٌ واحد للشارة والمطبوعة ──
  const S = (() => {
    const src = [ grab('prIsLive'), grabConst('PROC_STAGE_LABEL'),
                  grab('prProcStageText'), grab('procStatusBadge') ].join('\n\n');
    return new Function(src + '; return {prProcStageText, procStatusBadge};')();
  })();
  T('نصّ المرحلة: المسودّة «—» والمُرسَل مرحلته والمربوط رقم أمره',
    S.prProcStageText({status:'draft'}) === '—'
    && S.prProcStageText({status:'submitted', proc_status:'in_progress'}) === 'قيد التنفيذ'
    && S.prProcStageText({status:'submitted', proc_status:'received'}) === 'وارد جديد'
    && S.prProcStageText({status:'submitted', po_number:'PO-9'}).includes('PO-9'));
  T('والشارة تشترك معه في المصدر نفسه (لا جدولان يتفارقان)',
    S.procStatusBadge({proc_status:'po_issued'}).includes('صدر أمر الشراء')
    && (CODE.match(/const PROC_STAGE_LABEL/g) || []).length === 1);
}

/* ── النتيجة ─────────────────────────────────────────────────── */
console.log(`\n${'─'.repeat(52)}`);
console.log(`النتيجة: ${pass} ناجح · ${fail} فاشل`);
process.exit(fail ? 1 : 0);

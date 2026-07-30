#!/usr/bin/env node
/**
 * pages-exclude.mjs — سلامة نشر GitHub Pages (Stage 1، البنود 5 · G1-03 · G1-04).
 * ════════════════════════════════════════════════════════════════════════════
 * المشكلة: workflow «Deploy to GitHub Pages» يرفع المستودع كاملاً، فتُنشَر صفحات تعتمد
 * على Cloudflare Functions (/api/*) حيث لا وجود لها على GitHub Pages فتُكسَر.
 *
 * الحل: قبل رفع أرتيفاكت Pages نستبدل كل صفحة **معتمِدة على Functions** بكعب إعادة توجيه
 * للنشر القانوني (canonical_origin) **مع الحفاظ على query string و hash** (رمز المورّد ?t=…).
 *
 * G1-03 (تكافؤ المجموعة): مصدر الحقيقة = `pages[].needs_functions` في البيان. المجموعة
 * المُستبعَدة = بالضبط { الصفحات needs_functions=true }. `--check` يفشل عند:
 *   • صفحة needs_functions غير موجودة على القرص (انجراف البيان↔الشجرة)، أو
 *   • صفحة needs_functions غائبة عن `derived_pages` (استبعاد ناقص — الثغرة التي رُصدت)، أو
 *   • مُدخَل في `derived_pages` ليس needs_functions أو غير موجود (استبعاد قديم/زائد).
 *
 * الاستخدام:
 *   node scripts/pages-exclude.mjs --dir <artifact_dir> [--manifest deploy/system3-manifest.json]
 *   node scripts/pages-exclude.mjs --check     # تحقّق تكافؤ المجموعة فقط، لا يكتب
 * يخرج 0 عند النجاح، ≠0 عند أي خرق (fail-closed).
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, isAbsolute } from 'node:path';

function arg(name, def) {
  const i = process.argv.indexOf('--' + name);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return (v && !v.startsWith('--')) ? v : true;
}
function die(msg) { console.error('❌ pages-exclude: ' + msg); process.exit(2); }

const manifestPath = arg('manifest', 'deploy/system3-manifest.json');
const checkOnly = arg('check', false) === true;
const dir = arg('dir', '.');

let manifest;
try { manifest = JSON.parse(readFileSync(manifestPath, 'utf8')); }
catch (e) { die(`تعذّرت قراءة/تحليل البيان ${manifestPath}: ${e.message}`); }

const origin = String(manifest.canonical_origin || '').trim();
if (!/^https:\/\/[a-z0-9.-]+\.[a-z]{2,}(\/[^\s]*)?$/i.test(origin)) {
  die(`canonical_origin غير صالح في البيان: «${origin}» (يجب أن يكون https://host).`);
}

function safeName(p) {                                   // أسماء ملفات مسطّحة فقط (لا تجاوز مسار)
  return (typeof p === 'string' && /^[A-Za-z0-9._-]+\.html$/.test(p)) ? p : null;
}

// مصدر الحقيقة: pages[].needs_functions. مع دعم رجعي لبيان الاختبار الذي يمرّر قائمة صريحة فقط.
const pageRecords = Array.isArray(manifest.pages) ? manifest.pages : null;
let needSet, declaredList;
if (pageRecords) {
  needSet = new Set();
  for (const p of pageRecords) {
    const nm = safeName(p && p.file);
    if (p && p.needs_functions === true) {
      if (!nm) die(`اسم صفحة غير صالح في pages[]: «${p && p.file}».`);
      needSet.add(nm);
    } else if (p && p.file && !nm) {
      die(`اسم صفحة غير صالح في pages[]: «${p.file}».`);
    }
  }
  declaredList = (manifest.github_pages_exclude && manifest.github_pages_exclude.derived_pages) || [];
} else {
  // مسار رجعي: بيان مبسّط بقائمة github_pages_exclude.pages فقط (يُستخدم في اختبارات سلبية).
  declaredList = (manifest.github_pages_exclude && manifest.github_pages_exclude.pages) || [];
  needSet = null;
}

for (const raw of declaredList) if (!safeName(raw)) die(`اسم صفحة غير صالح في قائمة الاستبعاد: «${raw}».`);
const declaredSet = new Set(declaredList);
if (declaredSet.size === 0 && !needSet) die('قائمة الاستبعاد فارغة ولا يوجد pages[] — لا مصدر للاستبعاد (fail-closed).');

// (G1-03) تكافؤ المجموعة عند وجود pages[].
// تناسق البيان الداخلي (needs_functions ⇔ derived_pages) يُفرَض دائماً (بلا قرص).
// أمّا وجود الملف على القرص (انجراف البيان↔الشجرة) فيُفرَض في --check فقط، لأنّ وضع الكتابة
// قد يعمل على أرتيفاكت جزئي ويتخطّى غير الموجود بأمان.
if (needSet) {
  const problems = [];
  for (const nm of needSet) {
    if (!declaredSet.has(nm)) problems.push(`صفحة معتمِدة على Functions غائبة عن الاستبعاد: ${nm}`);
  }
  for (const nm of declaredSet) {
    if (!needSet.has(nm)) problems.push(`مُدخَل استبعاد ليس needs_functions (قديم/زائد): ${nm}`);
  }
  if (checkOnly) {
    for (const nm of needSet) {
      const full = isAbsolute(dir) ? join(dir, nm) : join(process.cwd(), dir, nm);
      if (!existsSync(full)) problems.push(`صفحة معتمِدة على Functions غير موجودة على القرص: ${nm}`);
    }
  }
  if (problems.length) die('خرق تكافؤ مجموعة الاستبعاد:\n   - ' + problems.join('\n   - '));
}

const targets = needSet ? [...needSet] : [...declaredSet];

// (G1-04) كعب إعادة توجيه يحفظ query string و hash.
function stubFor(page) {
  const base = origin.replace(/\/+$/, '') + '/' + page;
  const j = JSON.stringify(base);   // آمن للحقن داخل <script>
  const hEsc = base.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
  return `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="robots" content="noindex">
<title>يتطلب النشر الرسمي</title>
<script>(function(){var b=${j};var u=b+location.search+location.hash;try{var a=document.getElementById('go');if(a)a.href=u;}catch(e){}location.replace(u);})();</script>
</head><body style="font-family:system-ui,'Segoe UI',sans-serif;max-width:640px;margin:16vh auto;padding:28px;line-height:1.9;color:#0f172a">
<h2 style="color:#0f172a">هذه الصفحة تُخدَم من النشر الرسمي فقط</h2>
<p>تعتمد هذه الصفحة على دوال الخادم (Cloudflare Functions) غير المتوفّرة على GitHub Pages. جارٍ تحويلك مع الحفاظ على رابطك بالكامل…</p>
<p><a id="go" href="${hEsc}">${hEsc}</a></p>
<noscript><p>فعّل JavaScript، أو افتح الرابط أعلاه (أضِف مُعاملات رابطك الأصلية يدويّاً إن لزم).</p></noscript>
</body></html>\n`;
}

if (checkOnly) {
  console.log(`▶ pages-exclude --check: needs_functions=${needSet ? needSet.size : '(n/a)'} · excluded=${declaredSet.size} · origin=${origin}`);
  console.log('✅ تكافؤ مجموعة الاستبعاد سليم، وقيم البيان صالحة.');
  process.exit(0);
}

let written = [], missing = [];
for (const name of targets) {
  const full = isAbsolute(dir) ? join(dir, name) : join(process.cwd(), dir, name);
  if (!existsSync(full)) { missing.push(name); continue; }
  writeFileSync(full, stubFor(name), 'utf8'); written.push(name);
}
console.log(`✅ pages-exclude: استُبدِلت ${written.length} صفحة بكعب إعادة توجيه (يحفظ query+hash) إلى ${origin}` +
  (missing.length ? ` (غير موجودة، تُخطّى: ${missing.join(', ')})` : '') + '.');
process.exit(0);

#!/usr/bin/env node
/**
 * pages-exclude.mjs — سلامة نشر GitHub Pages (متطلّب المالك، البند 5).
 * ════════════════════════════════════════════════════════════════════════════
 * المشكلة: workflow «Deploy to GitHub Pages» يرفع المستودع كاملاً (path: '.')، فتُنشَر
 * صفحات النظام 3 (وكل صفحات التطبيق) على GitHub Pages حيث لا وجود لـ Cloudflare Functions
 * (/api/*)، فتُكسَر الصفحات المعتمِدة عليها (portal-config يعيد 404).
 *
 * الحل: قبل رفع أرتيفاكت Pages، نستبدل كل صفحة معتمِدة على Functions (المُعلَنة في
 * deploy/system3-manifest.json → github_pages_exclude.pages) بكعب إعادة توجيه (redirect stub)
 * إلى النشر القانوني على Cloudflare (canonical_origin). فلا يرى زائر GitHub Pages صفحةً مكسورة.
 *
 * الاستخدام:
 *   node scripts/pages-exclude.mjs --dir <artifact_dir> [--manifest deploy/system3-manifest.json]
 *   node scripts/pages-exclude.mjs --check   # تحقّق فقط: يتأكّد أنّ كل صفحة مُعلَنة موجودة؛ لا يكتب
 * يخرج 0 عند النجاح، ≠0 عند خطأ إعداد (fail-closed).
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
if (!/^https:\/\/[a-z0-9.-]+(\.[a-z]{2,})(\/.*)?$/i.test(origin)) {
  die(`canonical_origin غير صالح في البيان: «${origin}» (يجب أن يكون https://host).`);
}
const pages = (manifest.github_pages_exclude && manifest.github_pages_exclude.pages) || [];
if (!Array.isArray(pages) || pages.length === 0) {
  die('github_pages_exclude.pages فارغة أو غير مصفوفة — لا شيء لاستبعاده (fail-closed: راجع البيان).');
}

function safeName(p) {
  // أسماء ملفات مسطّحة فقط (لا مسار/تجاوز) — يمنع الكتابة خارج المجلّد.
  if (typeof p !== 'string' || !/^[A-Za-z0-9._-]+\.html$/.test(p)) return null;
  return p;
}
function stubFor(page) {
  const url = origin.replace(/\/+$/, '') + '/' + page;
  const u = url.replace(/"/g, '&quot;');
  return `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0; url=${u}">
<title>يتطلب النشر الرسمي</title></head><body style="font-family:system-ui,'Segoe UI',sans-serif;max-width:640px;margin:16vh auto;padding:28px;line-height:1.9;color:#0f172a">
<h2 style="color:#0f172a">هذه الصفحة تُخدَم من النشر الرسمي فقط</h2>
<p>تعتمد هذه الصفحة على دوال الخادم (Cloudflare Functions) غير المتوفّرة على GitHub Pages. جارٍ تحويلك…</p>
<p><a href="${u}">${u}</a></p>
</body></html>\n`;
}

let missing = [], written = [];
for (const raw of pages) {
  const name = safeName(raw);
  if (!name) die(`اسم صفحة غير صالح في البيان: «${raw}» (يجب اسم ملف html مسطّح).`);
  const full = isAbsolute(dir) ? join(dir, name) : join(process.cwd(), dir, name);
  if (!existsSync(full)) { missing.push(name); continue; }
  if (!checkOnly) { writeFileSync(full, stubFor(name), 'utf8'); written.push(name); }
}

if (checkOnly) {
  console.log(`▶ pages-exclude --check: ${pages.length} صفحة معلَنة، origin=${origin}`);
  if (missing.length) die(`صفحات مُعلَنة غير موجودة على القرص: ${missing.join(', ')} (البيان لا يطابق الشجرة).`);
  console.log('✅ كل الصفحات المُعلَنة موجودة، وقيم البيان صالحة.');
  process.exit(0);
}
console.log(`✅ pages-exclude: استُبدِلت ${written.length} صفحة بكعب إعادة توجيه إلى ${origin}` +
  (missing.length ? ` (تخطّى غير الموجودة: ${missing.join(', ')})` : '') + '.');
process.exit(0);

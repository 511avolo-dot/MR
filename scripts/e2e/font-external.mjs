/* فحص متصفّح تحت **CSP الإنتاج** لبند ⑥ من دراسة النظام (2026-11-01):
 *   خطّ `NeoSansArabic` كان مضمَّناً base64 داخل `<style>` بـ271,248 محرفاً —
 *   وهو **114,707 بايت مضغوطاً في كل فتح بارد** (12.7% من الصفحة المضغوطة،
 *   مقيس بـgzip على الملفّ مع الخطّ وبدونه). صار ملفّاً مستقلّاً WOFF2 بـ55,192
 *   بايت (مضغوطاً داخليّاً بـBrotli): **أوّل فتح −59.5KB، وكل فتح لاحق −114.7KB**
 *   لأنّ `/*.woff2` مُكاش أسبوعاً في `_headers` أصلاً.
 *
 * ⚠️ والمحكّ **أنّ الخطّ يُرسَم فعلاً** لا أنّ القاعدة موجودة: السقوط الصامت إلى
 *    خطّ النظام يبدو سليماً للعين في لقطةٍ ويكسر هويّة المطبوعات. يُقاس بـ
 *    `document.fonts.check()` وبعرض نصٍّ بالخطّ مقابل خطّ احتياطيّ.
 *
 * التشغيل: node scripts/csp-preview-server.mjs &  ثمّ  node scripts/e2e/font-external.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const BASE = process.env.BASE || 'http://127.0.0.1:8812';
const SHOTS = process.env.FONT_SHOTS || path.join(os.tmpdir(), 'aldeyabi-font-external');
fs.mkdirSync(SHOTS, { recursive: true });
const results = []; const T = (n, ok, d) => { results.push([n, !!ok, d || '']); };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const pageErrors = [], csp = [], fontReqs = [];
page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });
page.on('response', r => { if (/\.woff2(\?|$)/.test(r.url())) fontReqs.push([r.url(), r.status()]); });

await blockSupabase(page);
await page.goto(`${BASE}/index.html`, { waitUntil: 'load' });
await page.evaluate(() => document.fonts.ready);

/* ── الملفّ يُجلَب فعلاً من نفس الأصل ── */
const own = fontReqs.filter(([u]) => u.startsWith(BASE));
T('ملفّ الخطّ يُجلَب من نفس الأصل بنجاح',
  own.length >= 1 && own.every(([, s]) => s === 200), JSON.stringify(fontReqs));
T('ولا data: URI للخطّ في الصفحة بعد النقل',
  await page.evaluate(() => !/data:font\//.test(document.documentElement.innerHTML)));

/* ── الخطّ مُحمَّل فعلاً، لا سقوطاً صامتاً لخطّ النظام ── */
T('الخطّ مُحمَّل ومُتاح للرسم (لا سقوط صامت)',
  await page.evaluate(() => document.fonts.check("16px 'NeoSansArabic'")));
T('وعائلته حاضرة في مجموعة خطوط المستند',
  await page.evaluate(() => [...document.fonts].some(f => f.family.includes('NeoSansArabic')
                                                       && f.status === 'loaded')));

/* ⚠️ القياس الحاسم: عرضُ نصٍّ عربيّ بالخطّ **يختلف** عن عرضه بخطٍّ احتياطيّ.
   لو سقط الخطّ صامتاً لتساوى العرضان بالبكسل. */
const widths = await page.evaluate(() => {
  const mk = (fam) => { const s = document.createElement('span');
    s.textContent = 'مجموعة الذيابي للمقاولات والصيانة';
    s.style.cssText = `position:fixed;left:-9999px;top:0;font-size:48px;white-space:nowrap;font-family:${fam}`;
    document.body.appendChild(s); const w = s.getBoundingClientRect().width; s.remove(); return Math.round(w); };
  return { neo: mk("'NeoSansArabic'"), fallback: mk('monospace') };
});
T('ونصٌّ عربيّ بالخطّ يُرسَم بعرضٍ مختلف عن الاحتياطيّ (برهان الرسم الفعليّ)',
  widths.neo > 0 && widths.fallback > 0 && widths.neo !== widths.fallback, JSON.stringify(widths));

/* ── مسار الطباعة: الإطار المخفيّ ينسخ الأنماط، والرابط نسبيّ لنفس الأصل ── */
await enterApp(page);
const printOk = await page.evaluate(async () => {
  if (typeof printDocOpen !== 'function') return 'لا دالّة طباعة';
  printDocOpen({ title: 'فحص الخطّ', compactHeader: true },
    '<div class="print-section"><p style="font-family:\'NeoSansArabic\',serif">نصّ عربيّ للطباعة</p></div>');
  await new Promise(r => setTimeout(r, 400));
  await document.fonts.ready;
  return document.fonts.check("16px 'NeoSansArabic'") ? 'ok' : 'سقط في مسار الطباعة';
});
T('ومسار الطباعة يبقى على الخطّ نفسه', printOk === 'ok', String(printOk));
await page.screenshot({ path: path.join(SHOTS, 'print-preview-font.png'), fullPage: false });

T('صفر خطأ صفحة', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.slice(0, 2).join(' | '));

await browser.close();
const bad = results.filter(r => !r[1]);
for (const [n, ok, d] of results) console.log(`  ${ok ? '✓' : '✗'} ${n}${d && !ok ? '  → ' + d : ''}`);
console.log(`\nالخطّ الخارجيّ: ${results.length - bad.length}/${results.length} · اللقطات: ${SHOTS}`);
process.exit(bad.length ? 1 : 0);

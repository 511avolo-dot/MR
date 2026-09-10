#!/usr/bin/env node
/**
 * توليد بطاقة دعوة التسجيل المصوَّرة للواتساب.
 * ------------------------------------------------------------------
 *   node scripts/build-invite-card.mjs      (أو: npm run build:invite-card)
 *
 * ⚠️ لماذا سكربت لا تصدير يدويّ: أوّل نسخة من البطاقة **فاض محتواها** فقُصّ
 *    التذييل كلّه (scrollHeight 1552 على بطاقة 1350) — والصورة تبدو سليمة حتى
 *    تنظر إلى أسفلها. التأكيد أدناه يُفشِل التوليد على أي فيض، فلا تُنشَر بطاقة
 *    مبتورة مرّة أخرى.
 */
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT  = path.join(ROOT, 'assets', 'دعوة-تسجيل-المورد-واتساب.png');
const PORT = 8977;
const TYPES = { '.html':'text/html', '.png':'image/png', '.css':'text/css', '.js':'application/javascript' };

let chromium;
try { ({ chromium } = await import('playwright')); }
catch (_) { console.error('يحتاج playwright: npm i -D playwright'); process.exit(1); }

const server = http.createServer((req, res) => {
  const f = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]));
  fs.readFile(f, (e, d) => {
    if (e) { res.writeHead(404); return res.end('nf'); }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream' });
    res.end(d);
  });
}).listen(PORT);

const exe = process.env.CHROMIUM_PATH || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
const browser = await chromium.launch(fs.existsSync(exe) ? { executablePath: exe } : {});
const page = await browser.newPage({ viewport: { width: 1140, height: 1420 }, deviceScaleFactor: 2 });
const errs = [];
page.on('pageerror', e => errs.push(String(e)));
await page.goto(`http://127.0.0.1:${PORT}/supplier-invitation-whatsapp.html`, { waitUntil: 'networkidle' });

const m = await page.evaluate(() => {
  const c = document.getElementById('card');
  const f = c.querySelector('.ft');
  return { w: c.clientWidth, h: c.clientHeight, scrollH: c.scrollHeight,
           footerBottom: Math.round(f.getBoundingClientRect().bottom),
           cardBottom:   Math.round(c.getBoundingClientRect().bottom) };
});

fs.mkdirSync(path.dirname(OUT), { recursive: true });
await (await page.$('#card')).screenshot({ path: OUT });
await browser.close();
server.close();

const fail = [];
if (errs.length) fail.push('أخطاء صفحة: ' + errs[0]);
if (m.w !== 1080 || m.h !== 1350) fail.push(`المقاس ${m.w}×${m.h} ≠ 1080×1350`);
// الحارس الحقيقي: أي فيض يقصّ التذييل صامتاً
if (m.scrollH > m.h) fail.push(`فيض المحتوى: ${m.scrollH} > ${m.h} — التذييل سيُقصّ`);
if (m.footerBottom > m.cardBottom + 1) fail.push('التذييل خارج البطاقة');

console.log(`البطاقة: ${m.w}×${m.h} · ارتفاع المحتوى ${m.scrollH} · ${OUT}`);
if (fail.length) { fail.forEach(x => console.error('✗ ' + x)); process.exit(1); }
console.log('✓ البطاقة كاملة بلا فيض');

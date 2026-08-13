#!/usr/bin/env node
/**
 * browser-fixture.test.mjs — اختبار متصفّح حتميّ لـbrowser-run.mjs بلا staging خارجيّ (F2/F3).
 * يخدم صفحة محلّية تحاكي **عقد دخول النظام-3 الحقيقي** (#pa-email/#pa-pass/#pa-lg-btn ونجاح =
 * إخفاء #pa-login وإظهار .topbar+.wrap) + /api/portal-config، ثم يشغّل browser-run.mjs:
 *   • باعتماد صحيح ⇒ يجب أن ينجح (خروج 0) + تأكيدات الحدّ (HTTP/WS/SW).
 *   • باعتماد خاطئ ⇒ يجب أن يفشل مغلقاً (خروج ≠ 0).
 * يتطلّب playwright (package.json مثبَّت) + Chromium (/opt/pw-browsers).
 */
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import assert from 'node:assert/strict';

const REF = 'abcdefghij0123456789';           // مرجع staging وهميّ (≠ الإنتاج)
const EMAIL = 'tester@staging.local', PASS = 'correct-horse-staging';
const here = dirname(fileURLToPath(import.meta.url));

const PAGE = `<!doctype html><html><head><meta charset="utf-8"><title>System-3 fixture</title>
<style>.topbar,.wrap{display:none}</style></head><body>
<div id="pa-login"><input id="pa-email"><input id="pa-pass" type="password"><button id="pa-lg-btn">دخول</button></div>
<div class="topbar">TOPBAR</div><div class="wrap">WRAP</div>
<script>
document.getElementById('pa-lg-btn').addEventListener('click',function(){
  var e=document.getElementById('pa-email').value, p=document.getElementById('pa-pass').value;
  if(e===${JSON.stringify(EMAIL)}&&p===${JSON.stringify(PASS)}){
    document.getElementById('pa-login').style.display='none';
    document.querySelector('.topbar').style.display='block';
    document.querySelector('.wrap').style.display='block';
  }
});
</script></body></html>`;

const server = createServer((req, res) => {
  if (req.url.startsWith('/api/portal-config')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, env: 'preview', ref: REF, url: `https://${REF}.supabase.co` }));
  } else if (req.url === '/sw.js') {
    res.writeHead(200, { 'content-type': 'application/javascript' }); res.end('/* noop sw */');
  } else {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(PAGE);
  }
});

await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
const runner = join(here, 'browser-run.mjs');
// spawn غير متزامن (لا spawnSync) كي يبقى event loop حرّاً فيخدم الخادم المحلّي أثناء تشغيل المتصفّح.
function run(pw) {
  return new Promise((resolve) => {
    const ch = spawn('node', [runner], {
      env: { ...process.env, E2E_BASE_URL: base, GUARDED_REF: REF, STAGING_TEST_EMAIL: EMAIL, STAGING_TEST_PASSWORD: pw } });
    let stdout = '', stderr = '';
    ch.stdout.on('data', (d) => { stdout += d; });
    ch.stderr.on('data', (d) => { stderr += d; });
    ch.on('close', (code) => resolve({ status: code, stdout, stderr }));
  });
}
let ok = 0; const t = (m) => { console.log('  ✓ ' + m); ok++; };
try {
  console.log('▶ browser-fixture (F2/F3): عقد دخول حقيقيّ + حدّ HTTP/WS/SW');
  const good = await run(PASS);
  if (good.status !== 0) { console.error(good.stdout + '\n' + good.stderr); }
  assert.equal(good.status, 0); assert.match(good.stdout, /smoke نجح/); t('اعتماد صحيح ⇒ دخول ناجح + حالة محميّة');
  // (G1-FINAL-02) مخرجات مضيف دقيقة — لا عدّادات عامّة
  assert.match(good.stdout, /prodHTTP=blocked/); assert.match(good.stdout, /otherHTTP=blocked/); assert.match(good.stdout, /stagingHTTP=allowed/); t('HTTP: prod محظور · other-ref محظور · staging مسموح');
  assert.match(good.stdout, /prodWSS=blocked/); assert.match(good.stdout, /otherWSS=blocked/); assert.match(good.stdout, /stagingWSS=allowed/); t('WebSocket: prod محظور · other-ref محظور · staging مسموح');
  assert.match(good.stdout, /swRegistrations=0/); t('Service Worker: صفر تسجيلات (الحظر محكوم)');
  assert.doesNotMatch(good.stdout, /LEAK|DENIED/); t('لا تسريب/منع خاطئ في أيّ مخرج مضيف');
  const bad = await run('wrong-password');
  assert.notEqual(bad.status, 0); t('اعتماد خاطئ ⇒ يفشل مغلقاً (لا حالة محميّة)');
  console.log(`✅ browser-fixture: ${ok} تأكيدات — كلها نجحت.`);
} finally { server.close(); }
process.exit(0);

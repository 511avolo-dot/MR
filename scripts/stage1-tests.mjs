#!/usr/bin/env node
/**
 * stage1-tests.mjs — اختبارات + ضوابط سلبية لسلامة النشر (Stage 1، البند 8).
 * تغطّي: env-guard (التحقّق + الاقتران بالأمر)، pages-exclude (البيان + الاستبعاد + منع التجاوز)،
 * portal-config (fail-closed: بيئة/تحليل عنوان/anon/جاهزية خادم/رفض الإنتاج في المعاينة).
 * تأكيدات صريحة (throw) — يخرج 0 عند نجاح الكل، ≠0 عند أول فشل. لا يمسّ أي قاعدة/خدمة.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';
import { onRequestGet } from '../functions/api/portal-config.js';

const PROD = 'mwbjoysuybgbrvfrprex';
const STAGING = 'abcdefghij0123456789';          // 20 محرفاً، ليس الإنتاج
let n = 0; const ok = (m) => { n++; console.log('  ✓ ' + m); };
function node(args, env) { return spawnSync('node', args, { encoding: 'utf8', env: { ...process.env, ...(env || {}) } }); }

console.log('▶ env-guard:');
{
  // رفض مرجع الإنتاج
  let r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', PROD, '--confirm', 'STAGING']);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /الإنتاج/); ok('يرفض مرجع الإنتاج');
  // رفض غياب تأكيد STAGING
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'nope']);
  assert.notEqual(r.status, 0); ok('يرفض غياب تأكيد STAGING');
  // رفض عنوان مخادع user@prod
  r = node(['scripts/env-guard.mjs', '--purpose', 'e2e', '--url', `https://user@${PROD}.supabase.co`, '--confirm', 'STAGING']);
  assert.notEqual(r.status, 0); ok('يرفض خداع user@host في العنوان');
  // يقبل staging مؤكَّداً
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'STAGING']);
  assert.equal(r.status, 0); ok('يقبل staging مؤكَّداً');
  // الاقتران: يشغّل الأمر بالمرجع المُتحقَّق منه محقوناً (GUARDED_REF)
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'STAGING',
            '--exec', '--', 'node', '-e', `process.exit(process.env.GUARDED_REF==='${STAGING}'?0:7)`]);
  assert.equal(r.status, 0); ok('الاقتران يحقن GUARDED_REF المُتحقَّق منه في الأمر');
  // الاقتران لا يشغّل الأمر إن رُفض الهدف (الإنتاج) — الأمر يجب ألّا يُنفَّذ
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', PROD, '--confirm', 'STAGING',
            '--exec', '--', 'node', '-e', 'process.exit(0)']);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /الإنتاج/); ok('الاقتران لا يشغّل الأمر عند رفض الهدف');
  // --exec بلا أمر ⇒ رفض
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'STAGING', '--exec', '--']);
  assert.notEqual(r.status, 0); ok('--exec بلا أمر مرفوض');
}

console.log('▶ pages-exclude:');
{
  // --check على الشجرة الحقيقية: كل الصفحات المُعلَنة موجودة
  let r = node(['scripts/pages-exclude.mjs', '--check']);
  assert.equal(r.status, 0); ok('--check ينجح: كل الصفحات المُعلَنة موجودة');
  // الاستبعاد في مجلّد مؤقّت يكتب كعب إعادة توجيه
  const dir = mkdtempSync(join(tmpdir(), 'pgx-'));
  writeFileSync(join(dir, 'purchase-portal.html'), '<html>REAL PORTAL</html>');
  r = node(['scripts/pages-exclude.mjs', '--dir', dir]);
  assert.equal(r.status, 0);
  const out = readFileSync(join(dir, 'purchase-portal.html'), 'utf8');
  assert.match(out, /http-equiv="refresh"/); assert.match(out, /aldeyabi-procurement\.pages\.dev/);
  assert.doesNotMatch(out, /REAL PORTAL/); ok('يستبدل صفحة النظام 3 بكعب إعادة توجيه');
  // بيان بعنوان صفحة يحوي تجاوز مسار ⇒ رفض (fail-closed)
  const badMan = join(dir, 'bad-manifest.json');
  writeFileSync(badMan, JSON.stringify({ canonical_origin: 'https://x.pages.dev',
    github_pages_exclude: { pages: ['../evil.html'] } }));
  r = node(['scripts/pages-exclude.mjs', '--dir', dir, '--manifest', badMan]);
  assert.notEqual(r.status, 0); ok('يرفض اسم صفحة فيه تجاوز مسار');
  // بيان بـ origin غير صالح ⇒ رفض
  const badOrigin = join(dir, 'bad-origin.json');
  writeFileSync(badOrigin, JSON.stringify({ canonical_origin: 'javascript:alert(1)',
    github_pages_exclude: { pages: ['purchase-portal.html'] } }));
  r = node(['scripts/pages-exclude.mjs', '--dir', dir, '--manifest', badOrigin]);
  assert.notEqual(r.status, 0); ok('يرفض canonical_origin غير صالح');
}

console.log('▶ portal-config (fail-closed):');
async function cfg(env) { const res = await onRequestGet({ env }); const body = await res.json(); return { status: res.status, body }; }
{
  const anon = 'eyJhbGciOiJIUzI1NiJ9.' + Buffer.from(JSON.stringify({ role: 'anon' })).toString('base64url') + '.sig';
  const svc  = 'eyJhbGciOiJIUzI1NiJ9.' + Buffer.from(JSON.stringify({ role: 'service_role' })).toString('base64url') + '.sig';
  const stagingUrl = `https://${STAGING}.supabase.co`, prodUrl = `https://${PROD}.supabase.co`;
  const full = (over) => Object.assign({ PORTAL_SUPABASE_URL: stagingUrl, PORTAL_SUPABASE_ANON_KEY: anon,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'x', QUOTES_BUCKET: {}, CF_PAGES_BRANCH: 'feature' }, over || {});

  // (1) بلا تحديد بيئة ⇒ 503
  let r = await cfg({ PORTAL_SUPABASE_URL: stagingUrl, PORTAL_SUPABASE_ANON_KEY: anon });
  assert.equal(r.status, 503); assert.equal(r.body.ok, false); ok('بلا CF_PAGES_BRANCH/PORTAL_ENV ⇒ 503');
  // (3) معاينة + مرجع الإنتاج ⇒ 409
  r = await cfg(full({ PORTAL_SUPABASE_URL: prodUrl }));
  assert.equal(r.status, 409); ok('معاينة على مشروع الإنتاج ⇒ 409');
  // (4) مفتاح service_role ⇒ 500 (يُرفض بثّه)
  r = await cfg(full({ PORTAL_SUPABASE_ANON_KEY: svc }));
  assert.equal(r.status, 500); ok('مفتاح service_role ⇒ 500');
  // (2) عنوان مخادع user@host ⇒ 503 (تحليل قانوني يرفضه)
  r = await cfg(full({ PORTAL_SUPABASE_URL: `https://user@${STAGING}.supabase.co` }));
  assert.equal(r.status, 503); ok('عنوان user@host ⇒ 503');
  // (5) جاهزية الخادم ناقصة (لا bucket) ⇒ 503
  r = await cfg(full({ QUOTES_BUCKET: undefined }));
  assert.equal(r.status, 503); ok('نقص ربط الخادم (bucket) ⇒ 503');
  // المسار السعيد: إنتاج على main + anon + خدمة + bucket ⇒ ok
  r = await cfg({ PORTAL_SUPABASE_URL: prodUrl, PORTAL_SUPABASE_ANON_KEY: anon,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'x', QUOTES_BUCKET: {}, CF_PAGES_BRANCH: 'main' });
  assert.equal(r.status, 200); assert.equal(r.body.ok, true); assert.equal(r.body.ref, PROD); ok('إنتاج على main ⇒ ok:true');
}

console.log(`\n✅ Stage-1 deployment-safety: ${n} تأكيداً — كلها نجحت.`);

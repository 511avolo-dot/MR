#!/usr/bin/env node
/**
 * stage1-tests.mjs — اختبارات + ضوابط سلبية لسلامة النشر (Stage 1، البند 8 + تصحيح G1-01…G1-04).
 * تغطّي: env-guard (التحقّق + الاقتران الحقيقي بهدف الأمر)، pages-exclude (تكافؤ المجموعة + حفظ query/hash
 * + منع التجاوز)، portal-config (fail-closed: بيئة/تناقض PORTAL_ENV/تحليل عنوان/ربط مشروع المفتاح/جاهزية).
 * تأكيدات صريحة (throw) — يخرج 0 عند نجاح الكل. لا يمسّ أي قاعدة/خدمة.
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
function jwt(payload) { return 'eyJhbGciOiJIUzI1NiJ9.' + Buffer.from(JSON.stringify(payload)).toString('base64url') + '.sig'; }

console.log('▶ env-guard (التحقّق + الاقتران G1-01):');
{
  let r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', PROD, '--confirm', 'STAGING']);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /الإنتاج/); ok('يرفض مرجع الإنتاج');
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'nope']);
  assert.notEqual(r.status, 0); ok('يرفض غياب تأكيد STAGING');
  r = node(['scripts/env-guard.mjs', '--purpose', 'e2e', '--url', `https://user@${PROD}.supabase.co`, '--confirm', 'STAGING']);
  assert.notEqual(r.status, 0); ok('يرفض خداع user@host في العنوان');
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'STAGING']);
  assert.equal(r.status, 0); ok('يقبل staging مؤكَّداً');

  // (G1-01) الأمر يستهدف الإنتاج صراحةً ⇒ يُرفض قبل التشغيل، والأمر لا يُنفَّذ (دليل: ملف علامة غائب).
  const dir = mkdtempSync(join(tmpdir(), 'eg-'));
  const mark = join(dir, 'ran.txt');
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'STAGING',
            '--exec', '--', 'node', '-e', 'require("fs").writeFileSync(process.env.MARK,"ran")',
            '--project-ref', PROD], { MARK: mark });
  assert.notEqual(r.status, 0); assert.equal(existsSync(mark), false);
  ok('الاقتران يرفض هدف الإنتاج الصريح في الأمر ولا يُشغّله');

  // (G1-01) العنوان الصريح للإنتاج داخل الأمر ⇒ يُرفض كذلك.
  r = node(['scripts/env-guard.mjs', '--purpose', 'e2e', '--ref', STAGING, '--confirm', 'STAGING',
            '--exec', '--', 'node', '-e', 'process.exit(0)', `https://${PROD}.supabase.co`]);
  assert.notEqual(r.status, 0); ok('الاقتران يرفض عنوان الإنتاج الصريح في الأمر');

  // (G1-01) العلامة {GUARDED_REF} تُستبدَل بالهدف المُتحقَّق منه فيمرّ ويُشغَّل بالهدف الصحيح.
  const out = join(dir, 'target.txt');
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'STAGING',
            '--exec', '--', 'node', '-e', 'require("fs").writeFileSync(process.argv[1],process.argv[3])',
            out, '--project-ref', '{GUARDED_REF}']);
  assert.equal(r.status, 0); assert.equal(readFileSync(out, 'utf8'), STAGING);
  ok('{GUARDED_REF} يُستبدَل ويُشغَّل الأمر بالهدف المُتحقَّق منه');

  // الهدف الصريح المطابق للـstaging مسموح (سبقه رمز موضعي كي لا يُفسِّر node العَلَم كخياره).
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'STAGING',
            '--exec', '--', 'node', '-e', 'process.exit(0)', 'x', '--project-ref', STAGING]);
  assert.equal(r.status, 0); ok('هدف staging صريح مطابق مسموح');

  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'STAGING', '--exec', '--']);
  assert.notEqual(r.status, 0); ok('--exec بلا أمر مرفوض');
}

console.log('▶ pages-exclude (تكافؤ المجموعة G1-03 + حفظ query/hash G1-04):');
{
  let r = node(['scripts/pages-exclude.mjs', '--check']);
  assert.equal(r.status, 0); ok('--check ينجح على الشجرة الحقيقية (تكافؤ المجموعة)');

  const dir = mkdtempSync(join(tmpdir(), 'pgx-'));
  writeFileSync(join(dir, 'purchase-portal.html'), '<html>REAL PORTAL</html>');
  writeFileSync(join(dir, 'supplier-quote.html'), '<html>REAL SQ</html>');
  r = node(['scripts/pages-exclude.mjs', '--dir', dir]);
  assert.equal(r.status, 0);
  const out = readFileSync(join(dir, 'purchase-portal.html'), 'utf8');
  assert.match(out, /location\.replace/); assert.match(out, /location\.search/); assert.match(out, /location\.hash/);
  assert.match(out, /aldeyabi-procurement\.pages\.dev/); assert.doesNotMatch(out, /REAL PORTAL/);
  ok('يستبدل الصفحة بكعب يحفظ query+hash (G1-04)');
  const sq = readFileSync(join(dir, 'supplier-quote.html'), 'utf8');
  assert.match(sq, /supplier-quote\.html/); assert.match(sq, /location\.search\+location\.hash/);
  ok('كعب supplier-quote يحفظ الرمز ?t=… (search+hash)');

  // (G1-03) صفحة معتمِدة على Functions غائبة عن الاستبعاد ⇒ --check يفشل.
  const m1 = join(dir, 'omit.json');
  writeFileSync(m1, JSON.stringify({ canonical_origin: 'https://x.pages.dev',
    pages: [{ file: 'purchase-portal.html', needs_functions: true }],
    github_pages_exclude: { derived_pages: [] } }));
  r = node(['scripts/pages-exclude.mjs', '--check', '--dir', dir, '--manifest', m1]);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /غائبة عن الاستبعاد/); ok('يرصد صفحة معتمِدة على Functions محذوفة من الاستبعاد');

  // (G1-03) مُدخَل استبعاد قديم ليس needs_functions ⇒ --check يفشل.
  const m2 = join(dir, 'stale.json');
  writeFileSync(m2, JSON.stringify({ canonical_origin: 'https://x.pages.dev',
    pages: [{ file: 'purchase-portal.html', needs_functions: false }],
    github_pages_exclude: { derived_pages: ['purchase-portal.html'] } }));
  r = node(['scripts/pages-exclude.mjs', '--check', '--dir', dir, '--manifest', m2]);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /قديم\/زائد/); ok('يرصد مُدخَل استبعاد قديم/زائد');

  // منع التجاوز + origin غير صالح.
  const m3 = join(dir, 'trav.json');
  writeFileSync(m3, JSON.stringify({ canonical_origin: 'https://x.pages.dev',
    github_pages_exclude: { pages: ['../evil.html'] } }));
  r = node(['scripts/pages-exclude.mjs', '--dir', dir, '--manifest', m3]);
  assert.notEqual(r.status, 0); ok('يرفض اسم صفحة فيه تجاوز مسار');
  const m4 = join(dir, 'origin.json');
  writeFileSync(m4, JSON.stringify({ canonical_origin: 'javascript:alert(1)',
    github_pages_exclude: { pages: ['purchase-portal.html'] } }));
  r = node(['scripts/pages-exclude.mjs', '--dir', dir, '--manifest', m4]);
  assert.notEqual(r.status, 0); ok('يرفض canonical_origin غير صالح');
}

console.log('▶ portal-config (fail-closed + G1-02):');
async function cfg(env) { const res = await onRequestGet({ env }); return { status: res.status, body: await res.json() }; }
{
  const anon = jwt({ role: 'anon' });                        // بلا ref
  const anonStg = jwt({ role: 'anon', ref: STAGING });
  const anonProd = jwt({ role: 'anon', ref: PROD });
  const svc = jwt({ role: 'service_role' });
  const stagingUrl = `https://${STAGING}.supabase.co`, prodUrl = `https://${PROD}.supabase.co`;
  const base = (over) => Object.assign({ PORTAL_SUPABASE_URL: stagingUrl, PORTAL_SUPABASE_ANON_KEY: anon,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'x', QUOTES_BUCKET: {}, CF_PAGES_BRANCH: 'feature' }, over || {});

  let r = await cfg({ PORTAL_SUPABASE_URL: stagingUrl, PORTAL_SUPABASE_ANON_KEY: anon });
  assert.equal(r.status, 503); ok('بلا CF_PAGES_BRANCH/PORTAL_ENV ⇒ 503');
  r = await cfg(base({ PORTAL_SUPABASE_URL: prodUrl }));
  assert.equal(r.status, 409); ok('معاينة على مشروع الإنتاج ⇒ 409');
  r = await cfg(base({ PORTAL_SUPABASE_ANON_KEY: svc }));
  assert.equal(r.status, 500); ok('مفتاح service_role ⇒ 500');
  r = await cfg(base({ PORTAL_SUPABASE_URL: `https://user@${STAGING}.supabase.co` }));
  assert.equal(r.status, 503); ok('عنوان user@host ⇒ 503');
  r = await cfg(base({ QUOTES_BUCKET: undefined }));
  assert.equal(r.status, 503); ok('نقص ربط الخادم (bucket) ⇒ 503');

  // (G1-02) PORTAL_ENV يناقض الفرع ⇒ 409 (الفرع قاطع).
  r = await cfg(base({ PORTAL_ENV: 'production', PORTAL_SUPABASE_URL: prodUrl }));
  assert.equal(r.status, 409); assert.match(r.body.error, /يناقض الفرع/); ok('PORTAL_ENV=production على فرع معاينة ⇒ 409 (لا تخطّي)');
  // (G1-02) مفتاح anon لمشروع مختلف عن العنوان ⇒ 500.
  r = await cfg(base({ PORTAL_SUPABASE_ANON_KEY: anonProd }));
  assert.equal(r.status, 500); assert.match(r.body.error, /مشروع/); ok('anon key لمشروع مغاير للعنوان ⇒ 500 (ربط المشروع)');
  // (G1-02) publishable مبهم بلا PORTAL_SUPABASE_EXPECTED_REF ⇒ 500.
  r = await cfg(base({ PORTAL_SUPABASE_ANON_KEY: 'sb_publishable_abc123' }));
  assert.equal(r.status, 500); ok('publishable مبهم بلا expected-ref ⇒ 500');
  // publishable مبهم مع expected-ref مطابق ⇒ ok.
  r = await cfg(base({ PORTAL_SUPABASE_ANON_KEY: 'sb_publishable_abc123', PORTAL_SUPABASE_EXPECTED_REF: STAGING }));
  assert.equal(r.status, 200); assert.equal(r.body.ok, true); ok('publishable مبهم مع expected-ref مطابق ⇒ ok');
  // (G1-02) غياب الفرع + PORTAL_ENV بلا هوية نشر ⇒ 409.
  r = await cfg({ PORTAL_SUPABASE_URL: prodUrl, PORTAL_SUPABASE_ANON_KEY: anon,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'x', QUOTES_BUCKET: {}, PORTAL_ENV: 'production' });
  assert.equal(r.status, 409); ok('PORTAL_ENV بلا فرع وبلا هوية نشر ⇒ 409');
  // غياب الفرع + PORTAL_ENV + هوية نشر مطابقة ⇒ ok.
  r = await cfg({ PORTAL_SUPABASE_URL: prodUrl, PORTAL_SUPABASE_ANON_KEY: anon,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'x', QUOTES_BUCKET: {}, PORTAL_ENV: 'production', PORTAL_ENV_IDENTITY: PROD });
  assert.equal(r.status, 200); assert.equal(r.body.ok, true); ok('PORTAL_ENV + هوية نشر مطابقة ⇒ ok');
  // المسار السعيد: إنتاج على main + anon(بلا ref) + خدمة + bucket.
  r = await cfg({ PORTAL_SUPABASE_URL: prodUrl, PORTAL_SUPABASE_ANON_KEY: anon,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: 'x', QUOTES_BUCKET: {}, CF_PAGES_BRANCH: 'main' });
  assert.equal(r.status, 200); assert.equal(r.body.ok, true); assert.equal(r.body.ref, PROD); ok('إنتاج على main ⇒ ok:true');
}

console.log(`\n✅ Stage-1 deployment-safety: ${n} تأكيداً — كلها نجحت.`);

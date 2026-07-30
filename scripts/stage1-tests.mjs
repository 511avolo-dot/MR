#!/usr/bin/env node
/**
 * stage1-tests.mjs — اختبارات + ضوابط سلبية لسلامة النشر (Stage 1؛ G1-01…G1-04 + G1-R2-01…G1-R2-04).
 * env-guard (مُحوّلات مسمّاة، لا تمرير أمر حرّ) · pages-exclude (تكافؤ المجموعة + حفظ query/hash فعليّاً في DOM)
 * · portal-config (هوية نشر ثابتة + ربط مفتاح/مشروع للمفاتيح غير المربوطة). تأكيدات صريحة، يخرج 0 عند نجاح الكل.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';
import { onRequestGet } from '../functions/api/portal-config.js';
import { isAllowedUrl, installNetworkAllowlist } from './e2e/net-allow.mjs';

const PROD = 'mwbjoysuybgbrvfrprex';
const STAGING = 'abcdefghij0123456789';
let n = 0; const ok = (m) => { n++; console.log('  ✓ ' + m); };
function node(args, env) { return spawnSync('node', args, { encoding: 'utf8', env: { ...process.env, ...(env || {}) } }); }
function jwt(payload) { return 'eyJhbGciOiJIUzI1NiJ9.' + Buffer.from(JSON.stringify(payload)).toString('base64url') + '.sig'; }
const G = ['scripts/env-guard.mjs', '--ref', STAGING, '--confirm', 'STAGING'];

console.log('▶ env-guard (مُحوّلات G1-R2-01):');
{
  // رفض الأساسيات
  let r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', PROD, '--confirm', 'STAGING', '--command', 'supabase-db-push']);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /الإنتاج/); ok('يرفض مرجع الإنتاج');
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'no', '--command', 'supabase-db-push']);
  assert.notEqual(r.status, 0); ok('يرفض غياب تأكيد STAGING');

  // (G1-R2-01) migrate/e2e بلا --command ⇒ رفض (التنفيذ المقترن إلزامي)
  r = node(['scripts/env-guard.mjs', '--purpose', 'migrate', '--ref', STAGING, '--confirm', 'STAGING']);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /--command/); ok('migrate بلا --command مرفوض');
  r = node(['scripts/env-guard.mjs', '--purpose', 'e2e', '--ref', STAGING, '--confirm', 'STAGING']);
  assert.notEqual(r.status, 0); ok('e2e بلا --command مرفوض');

  // (G1-R2-01) --exec القديم مرفوض؛ أمر غير معروف مرفوض؛ عَلَم مجهول (تهريب هدف) مرفوض
  r = node([...G, '--purpose', 'migrate', '--exec', '--', 'sh', '-c', `supabase db push --project-ref ${PROD}`]);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /exec/); ok('يرفض --exec (نمط sh -c قديم)');
  r = node([...G, '--purpose', 'migrate', '--command', 'sh-c']);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /غير معروف/); ok('يرفض أمراً غير معروف (sh-c)');
  r = node([...G, '--purpose', 'migrate', '--command', 'supabase-db-push', '--project-ref', PROD]);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /غير معروف/); ok('يرفض عَلَم --project-ref (تهريب هدف)');
  r = node([...G, '--purpose', 'migrate', '--command', 'psql-migration', '--db-url', `postgresql://postgres:pw@db.${PROD}.supabase.co:5432/postgres`]);
  assert.notEqual(r.status, 0); ok('يرفض --db-url المباشر (db.<prod> / pooler)');
  r = node([...G, '--purpose', 'e2e', '--command', 'supabase-db-push']);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /الغرض|migrate/); ok('يرفض عدم تطابق المُحوّل/الغرض');

  // (G1-R2-01) وضع التحقّق فقط لا يشغّل أمراً
  r = node([...G, '--purpose', 'check']);
  assert.equal(r.status, 0); assert.match(r.stdout, /تحقّق فقط/); ok('--purpose check يتحقّق بلا تشغيل أمر');

  // dry-run يبني الهدف داخليّاً من المرجع المُتحقَّق منه (لا مرجع إنتاج)
  r = node([...G, '--purpose', 'migrate', '--command', 'supabase-db-push', '--dry-run']);
  assert.equal(r.status, 0); assert.match(r.stdout, new RegExp('--project-ref ' + STAGING)); assert.match(r.stdout, /supabase-push\.mjs/); assert.doesNotMatch(r.stdout, new RegExp(PROD)); ok('supabase-db-push يستدعي مُشغّل link→push --linked بالهدف');
  // (G1-R3-03) psql: المضيف من المرجع، كلمة مرور بأحرف خاصّة عبر البيئة لا argv/stdout
  const SPW = 'p@ss:w/#%rd word';
  r = node([...G, '--purpose', 'migrate', '--command', 'psql-migration', '--file', 'db/portal-migrations/062-request-documents.sql', '--dry-run'], { SUPABASE_DB_PASSWORD: SPW });
  assert.equal(r.status, 0); assert.match(r.stdout, new RegExp('db\\.' + STAGING + '\\.supabase\\.co')); assert.doesNotMatch(r.stdout, /p@ss/); assert.match(r.stdout, /PGPASSWORD/); ok('psql: المضيف من المرجع، كلمة المرور (أحرف خاصّة) عبر البيئة لا argv/stdout');
  // (G1-R3-02) browser-e2e يشغّل المُشغّل الثابت بلا --spec اعتباطي
  r = node([...G, '--purpose', 'e2e', '--command', 'browser-e2e', '--dry-run']);
  assert.equal(r.status, 0); assert.match(r.stdout, /scripts\/e2e\/run\.mjs/); assert.match(r.stdout, new RegExp('E2E_SUPABASE_URL=https://' + STAGING)); ok('browser-e2e يشغّل المُشغّل الثابت بالهدف');
  r = node([...G, '--purpose', 'e2e', '--command', 'browser-e2e', '--spec', 'scripts/x.mjs', '--dry-run']);
  assert.notEqual(r.status, 0); ok('browser-e2e يرفض --spec (لا سكربت اعتباطي)');
  // psql-migration بلا/بمسار خبيث
  r = node([...G, '--purpose', 'migrate', '--command', 'psql-migration', '--dry-run'], { SUPABASE_DB_PASSWORD: 'x' });
  assert.notEqual(r.status, 0); ok('psql-migration بلا --file مرفوض');
  r = node([...G, '--purpose', 'migrate', '--command', 'psql-migration', '--file', 'db/../etc/passwd.sql', '--dry-run'], { SUPABASE_DB_PASSWORD: 'x' });
  assert.notEqual(r.status, 0); ok('psql-migration يرفض مسار ملف خبيث');
}

console.log('▶ launchers + net-allow (G1-R3-01/02):');
{
  // supabase-push launcher: خطة link→verify→push، رفض الإنتاج/غياب كلمة المرور
  let r = node(['scripts/deploy/supabase-push.mjs', '--dry-run'], { GUARDED_REF: STAGING, SUPABASE_DB_PASSWORD: 'x' });
  assert.equal(r.status, 0); assert.match(r.stdout, new RegExp('link --project-ref ' + STAGING)); assert.match(r.stdout, /db push --linked/); assert.doesNotMatch(r.stdout, new RegExp(PROD)); ok('supabase-push: خطة معزولة link→verify==ref→push --linked');
  r = node(['scripts/deploy/supabase-push.mjs', '--dry-run'], { GUARDED_REF: PROD, SUPABASE_DB_PASSWORD: 'x' });
  assert.notEqual(r.status, 0); ok('supabase-push يرفض GUARDED_REF=الإنتاج');
  r = node(['scripts/deploy/supabase-push.mjs', '--dry-run'], { GUARDED_REF: STAGING });
  assert.notEqual(r.status, 0); ok('supabase-push يرفض غياب SUPABASE_DB_PASSWORD');
  // e2e-run: يثبّت الحارس للهدف، يرفض الإنتاج
  r = node(['scripts/e2e/run.mjs'], { E2E_SUPABASE_URL: `https://${STAGING}.supabase.co` });
  assert.equal(r.status, 0); assert.match(r.stdout, /حارس الشبكة/); ok('e2e-run يثبّت حارس الشبكة للهدف');
  r = node(['scripts/e2e/run.mjs'], { GUARDED_REF: PROD });
  assert.notEqual(r.status, 0); ok('e2e-run يرفض هدف الإنتاج');

  // net-allow: قائمة سماح المضيف
  assert.equal(isAllowedUrl(`https://${PROD}.supabase.co/rest/v1/x`, STAGING), false);
  assert.equal(isAllowedUrl(`https://${STAGING}.supabase.co/rest/v1/x`, STAGING), true);
  assert.equal(isAllowedUrl(`https://db.${STAGING}.supabase.co`, STAGING), true);
  assert.equal(isAllowedUrl(`https://${STAGING}.pooler.supabase.com`, STAGING), true);
  assert.equal(isAllowedUrl('https://zzzzzzzzzzzzzzzzzzzz.supabase.co', STAGING), false);
  assert.equal(isAllowedUrl('https://example.com/api/portal-config', STAGING), true);
  ok('net-allow: يمنع الإنتاج/مرجعاً آخر ويسمح بالهدف وغير-Supabase');
  // سيناريو خبيث: نداء مباشر للإنتاج يُحظَر قبل إرساله فعليّاً
  const calls = []; const orig = globalThis.fetch; globalThis.fetch = (u) => { calls.push(u); return Promise.resolve({}); };
  const restore = installNetworkAllowlist(STAGING);
  let threw = false; try { globalThis.fetch(`https://${PROD}.supabase.co/rest/v1/secret`); } catch (_) { threw = true; }
  restore(); globalThis.fetch = orig;
  assert.equal(threw, true); assert.equal(calls.length, 0); ok('net-allow يحظر نداء الإنتاج قبل إرساله (سيناريو خبيث)');
}

console.log('▶ pages-exclude (تكافؤ G1-03 + حفظ query/hash فعليّاً G1-R2-04):');
{
  let r = node(['scripts/pages-exclude.mjs', '--check']);
  assert.equal(r.status, 0); ok('--check ينجح على الشجرة الحقيقية (تكافؤ المجموعة)');

  const dir = mkdtempSync(join(tmpdir(), 'pgx-'));
  writeFileSync(join(dir, 'purchase-portal.html'), '<html>REAL</html>');
  writeFileSync(join(dir, 'supplier-quote.html'), '<html>REAL SQ</html>');
  r = node(['scripts/pages-exclude.mjs', '--dir', dir]);
  assert.equal(r.status, 0);
  const out = readFileSync(join(dir, 'purchase-portal.html'), 'utf8');
  assert.match(out, /location\.search/); assert.match(out, /location\.hash/); assert.doesNotMatch(out, /REAL/);

  // (G1-R2-04) سلوك DOM فعليّ: السكربت (آخر الجسم) يضبط href الرابط ويحفظ search+hash.
  const code = [...out.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1];
  const a = { href: '' };
  const loc = { search: '?t=TOKEN123', hash: '#frag', replace() {} };
  new Function('document', 'location', code)({ getElementById: (id) => (id === 'go' ? a : null) }, loc);
  assert.match(a.href, /\?t=TOKEN123/); assert.match(a.href, /#frag/); assert.match(a.href, /aldeyabi-procurement\.pages\.dev/);
  ok('كعب إعادة التوجيه يحفظ ?t=…&hash في الرابط القابل للنقر فعليّاً (DOM)');

  // (G1-03) الاستبعاد الناقص/القديم يفشل --check
  const m1 = join(dir, 'omit.json');
  writeFileSync(m1, JSON.stringify({ canonical_origin: 'https://x.pages.dev', pages: [{ file: 'purchase-portal.html', needs_functions: true }], github_pages_exclude: { derived_pages: [] } }));
  r = node(['scripts/pages-exclude.mjs', '--check', '--dir', dir, '--manifest', m1]);
  assert.notEqual(r.status, 0); ok('يرصد صفحة معتمِدة على Functions محذوفة من الاستبعاد');
  const m2 = join(dir, 'stale.json');
  writeFileSync(m2, JSON.stringify({ canonical_origin: 'https://x.pages.dev', pages: [{ file: 'purchase-portal.html', needs_functions: false }], github_pages_exclude: { derived_pages: ['purchase-portal.html'] } }));
  r = node(['scripts/pages-exclude.mjs', '--check', '--dir', dir, '--manifest', m2]);
  assert.notEqual(r.status, 0); ok('يرصد مُدخَل استبعاد قديم/زائد');
  const m3 = join(dir, 'trav.json');
  writeFileSync(m3, JSON.stringify({ canonical_origin: 'https://x.pages.dev', github_pages_exclude: { pages: ['../evil.html'] } }));
  r = node(['scripts/pages-exclude.mjs', '--dir', dir, '--manifest', m3]);
  assert.notEqual(r.status, 0); ok('يرفض اسم صفحة فيه تجاوز مسار');
}

console.log('▶ portal-config (هوية نشر ثابتة G1-R2-02 + ربط مفتاح G1-R2-03):');
async function cfg(env) { const res = await onRequestGet({ env }); return { status: res.status, body: await res.json() }; }
{
  const noref = jwt({ role: 'anon' });
  const anonStg = jwt({ role: 'anon', ref: STAGING, iss: 'supabase' });
  const anonProd = jwt({ role: 'anon', ref: PROD });
  const svc = jwt({ role: 'service_role' });
  const expired = jwt({ role: 'anon', ref: STAGING, exp: 1 });
  const stagingUrl = `https://${STAGING}.supabase.co`, prodUrl = `https://${PROD}.supabase.co`;
  const svcRole = 'x', bkt = {};
  const prev = (over) => Object.assign({ PORTAL_SUPABASE_URL: stagingUrl, PORTAL_SUPABASE_ANON_KEY: anonStg,
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: svcRole, QUOTES_BUCKET: bkt, CF_PAGES_BRANCH: 'feature' }, over || {});

  // (G1-R2-02) غياب الفرع ⇒ 503 (فشل مغلق على النقطة العامّة)
  let r = await cfg({ PORTAL_SUPABASE_URL: stagingUrl, PORTAL_SUPABASE_ANON_KEY: anonStg, PORTAL_SUPABASE_SERVICE_ROLE_KEY: svcRole, QUOTES_BUCKET: bkt });
  assert.equal(r.status, 503); ok('غياب CF_PAGES_BRANCH ⇒ 503 (فشل مغلق)');
  // (G1-R2-02) PORTAL_PROD_BRANCH لا يُتجاوَز: فرع معاينة يدّعي أنه إنتاج + مرجع إنتاج ⇒ يبقى معاينة ⇒ 409
  r = await cfg(prev({ PORTAL_PROD_BRANCH: 'feature', PORTAL_SUPABASE_URL: prodUrl, PORTAL_SUPABASE_ANON_KEY: anonProd }));
  assert.equal(r.status, 409); ok('PORTAL_PROD_BRANCH=<preview> مُتجاهَل ⇒ معاينة على الإنتاج ⇒ 409');
  // (G1-R2-02) main + مرجع غير الإنتاج ⇒ 409
  r = await cfg({ PORTAL_SUPABASE_URL: stagingUrl, PORTAL_SUPABASE_ANON_KEY: anonStg, PORTAL_SUPABASE_SERVICE_ROLE_KEY: svcRole, QUOTES_BUCKET: bkt, CF_PAGES_BRANCH: 'main' });
  assert.equal(r.status, 409); ok('main + مرجع غير الإنتاج ⇒ 409');
  // معاينة + مرجع الإنتاج ⇒ 409
  r = await cfg(prev({ PORTAL_SUPABASE_URL: prodUrl, PORTAL_SUPABASE_ANON_KEY: anonProd }));
  assert.equal(r.status, 409); ok('معاينة + مرجع الإنتاج ⇒ 409');
  // service_role ⇒ 500 · user@host ⇒ 503 · نقص bucket ⇒ 503
  r = await cfg(prev({ PORTAL_SUPABASE_ANON_KEY: svc })); assert.equal(r.status, 500); ok('service_role ⇒ 500');
  r = await cfg(prev({ PORTAL_SUPABASE_URL: `https://user@${STAGING}.supabase.co` })); assert.equal(r.status, 503); ok('user@host ⇒ 503');
  r = await cfg(prev({ QUOTES_BUCKET: undefined })); assert.equal(r.status, 503); ok('نقص bucket ⇒ 503');

  // (G1-R2-03) JWT بلا ref ⇒ غير مربوط: بلا expected-ref ⇒ 500
  r = await cfg(prev({ PORTAL_SUPABASE_ANON_KEY: noref }));
  assert.equal(r.status, 500); ok('JWT بلا ref وبلا expected-ref ⇒ 500 (غير مربوط)');
  // JWT بلا ref + expected-ref مطابق ⇒ ok
  r = await cfg(prev({ PORTAL_SUPABASE_ANON_KEY: noref, PORTAL_SUPABASE_EXPECTED_REF: STAGING }));
  assert.equal(r.status, 200); assert.equal(r.body.ok, true); ok('JWT بلا ref + expected-ref مطابق ⇒ ok');
  // JWT بلا ref + expected-ref مغاير ⇒ 500
  r = await cfg(prev({ PORTAL_SUPABASE_ANON_KEY: noref, PORTAL_SUPABASE_EXPECTED_REF: PROD }));
  assert.equal(r.status, 500); ok('JWT بلا ref + expected-ref مغاير ⇒ 500');
  // JWT بمطالبة ref مغايرة للعنوان ⇒ 500
  r = await cfg(prev({ PORTAL_SUPABASE_ANON_KEY: anonProd }));
  assert.equal(r.status, 500); ok('JWT ref لمشروع مغاير للعنوان ⇒ 500');
  // JWT منتهي الصلاحية ⇒ 500
  r = await cfg(prev({ PORTAL_SUPABASE_ANON_KEY: expired }));
  assert.equal(r.status, 500); ok('JWT منتهي الصلاحية ⇒ 500');
  // publishable مبهم: بلا expected ⇒ 500؛ مع expected مطابق ⇒ ok
  r = await cfg(prev({ PORTAL_SUPABASE_ANON_KEY: 'sb_publishable_abc' })); assert.equal(r.status, 500); ok('publishable مبهم بلا expected ⇒ 500');
  r = await cfg(prev({ PORTAL_SUPABASE_ANON_KEY: 'sb_publishable_abc', PORTAL_SUPABASE_EXPECTED_REF: STAGING })); assert.equal(r.status, 200); ok('publishable مبهم + expected مطابق ⇒ ok');

  // المسار السعيد: معاينة على staging بمفتاح مربوط (ref=staging) ⇒ ok
  r = await cfg(prev({}));
  assert.equal(r.status, 200); assert.equal(r.body.ok, true); assert.equal(r.body.ref, STAGING); ok('معاينة على staging بمفتاح مربوط ⇒ ok');
  // main + مرجع الإنتاج + مفتاح مربوط للإنتاج ⇒ ok
  r = await cfg({ PORTAL_SUPABASE_URL: prodUrl, PORTAL_SUPABASE_ANON_KEY: anonProd, PORTAL_SUPABASE_SERVICE_ROLE_KEY: svcRole, QUOTES_BUCKET: bkt, CF_PAGES_BRANCH: 'main' });
  assert.equal(r.status, 200); assert.equal(r.body.ok, true); assert.equal(r.body.ref, PROD); ok('إنتاج على main بمفتاح مربوط ⇒ ok');
}

console.log(`\n✅ Stage-1 deployment-safety: ${n} تأكيداً — كلها نجحت.`);

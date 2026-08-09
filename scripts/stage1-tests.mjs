#!/usr/bin/env node
/**
 * stage1-tests.mjs — اختبارات + ضوابط سلبية لسلامة النشر (Stage 1؛ G1-01…G1-04 + G1-R2-01…G1-R2-04).
 * env-guard (مُحوّلات مسمّاة، لا تمرير أمر حرّ) · pages-exclude (تكافؤ المجموعة + حفظ query/hash فعليّاً في DOM)
 * · portal-config (هوية نشر ثابتة + ربط مفتاح/مشروع للمفاتيح غير المربوطة). تأكيدات صريحة، يخرج 0 عند نجاح الكل.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { onRequestGet } from '../functions/api/portal-config.js';
import { isAllowedUrl, installNetworkAllowlist } from './e2e/net-allow.mjs';
import { parsePendingVersions, assertExactly062, MIG_VERSION, MIG_DEST_NAME } from './deploy/mig-parse.mjs';

const PROD = 'mwbjoysuybgbrvfrprex';
const STAGING = 'abcdefghij0123456789';
let n = 0; const ok = (m) => { n++; console.log('  ✓ ' + m); };
function node(args, env) { return spawnSync('node', args, { encoding: 'utf8', env: { ...process.env, ...(env || {}) } }); }
function jwt(payload) { return 'eyJhbGciOiJIUzI1NiJ9.' + Buffer.from(JSON.stringify(payload)).toString('base64url') + '.sig'; }

for (const shellPath of ['db/portal-tests/run.sh', 'db/staging-bootstrap/verify-baseline.sh']) {
  assert.doesNotMatch(readFileSync(shellPath, 'utf8'), /\r\n/, `${shellPath} must use LF line endings for Linux CI`);
}
ok('all tracked shell launchers use LF line endings for Linux CI');
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
  r = node([...G, '--purpose', 'migrate', '--command', 'supabase-db-push', '--db-url', `postgresql://postgres:pw@db.${PROD}.supabase.co:5432/postgres`]);
  assert.notEqual(r.status, 0); ok('يرفض --db-url المباشر (عَلَم مجهول — لا تهريب هدف)');
  r = node([...G, '--purpose', 'e2e', '--command', 'supabase-db-push']);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /الغرض|migrate/); ok('يرفض عدم تطابق المُحوّل/الغرض');

  // (G1-R2-01) وضع التحقّق فقط لا يشغّل أمراً
  r = node([...G, '--purpose', 'check']);
  assert.equal(r.status, 0); assert.match(r.stdout, /تحقّق فقط/); ok('--purpose check يتحقّق بلا تشغيل أمر');

  // dry-run يبني الهدف داخليّاً من المرجع المُتحقَّق منه (لا مرجع إنتاج)
  r = node([...G, '--purpose', 'migrate', '--command', 'supabase-db-push', '--dry-run']);
  assert.equal(r.status, 0); assert.match(r.stdout, new RegExp('--project-ref ' + STAGING)); assert.match(r.stdout, /supabase-push\.mjs --mode apply-remediations/); assert.doesNotMatch(r.stdout, new RegExp(PROD)); ok('supabase-db-push يستدعي حمولة المعالجات الكاملة ثم link→push --linked بالهدف');
  // (G1-R3-02) browser-e2e يشغّل المُشغّل الثابت بلا --spec اعتباطي
  r = node([...G, '--purpose', 'e2e', '--command', 'browser-e2e', '--dry-run']);
  assert.equal(r.status, 0); assert.match(r.stdout, /scripts\/e2e\/browser-run\.mjs/); assert.match(r.stdout, new RegExp('E2E_SUPABASE_URL=https://' + STAGING)); ok('browser-e2e يستدعي متصفّح Playwright الفعليّ (browser-run.mjs) بالهدف (G1-R6-03)');
  r = node([...G, '--purpose', 'e2e', '--command', 'browser-e2e', '--spec', 'scripts/x.mjs', '--dry-run']);
  assert.notEqual(r.status, 0); ok('browser-e2e يرفض --spec (لا سكربت اعتباطي)');
  // (G1-R4-02) psql-migration أُزيل نهائيّاً — أمر غير معروف الآن
  r = node([...G, '--purpose', 'migrate', '--command', 'psql-migration', '--dry-run']);
  assert.notEqual(r.status, 0); assert.match(r.stderr, /غير معروف/); ok('psql-migration أُزيل (مُنفّذ الهجرة الوحيد = Supabase CLI)');
}

console.log('▶ launchers + net-allow (G1-R3-01/02):');
{
  // (F1) supabase-push: أساس ثم 062 ثم سلسلة P0 المثبّتة كاملة. dry-run بلا اتّصال.
  let r = node(['scripts/deploy/supabase-push.mjs', '--dry-run', '--mode', 'bootstrap'], { GUARDED_REF: STAGING });
  assert.equal(r.status, 0); assert.match(r.stdout, /mode=bootstrap/); assert.match(r.stdout, /baseline_through_061/); assert.match(r.stdout, new RegExp('link --project-ref ' + STAGING)); assert.doesNotMatch(r.stdout, new RegExp(PROD)); ok('supabase-push --mode bootstrap: الأساس فقط، خطة link→push بالهدف');
  r = node(['scripts/deploy/supabase-push.mjs', '--dry-run', '--mode', 'apply-062'], { GUARDED_REF: STAGING });
  assert.equal(r.status, 0); assert.match(r.stdout, /mode=apply-062/); assert.match(r.stdout, /baseline_through_061/); assert.match(r.stdout, new RegExp(MIG_VERSION)); ok('supabase-push --mode apply-062: الأساس+062 و062 وحدها معلّقة');
  r = node(['scripts/deploy/supabase-push.mjs', '--dry-run', '--mode', 'apply-remediations'], { GUARDED_REF: STAGING });
  assert.equal(r.status, 0); assert.match(r.stdout, /mode=apply-remediations/); assert.match(r.stdout, /P0 chain 12\/12 sha/);
  assert.match(r.stdout, /p0_1b_portal_users_guard/); assert.match(r.stdout, /p0_1n_direct_expense_raw_read_boundary/); ok('supabase-push --mode apply-remediations: الحمولة المرتبة الكاملة P0-1b…P0-1n');
  r = node(['scripts/deploy/supabase-push.mjs', '--dry-run'], { GUARDED_REF: STAGING });
  assert.notEqual(r.status, 0); assert.match(r.stderr, /--mode/); ok('supabase-push بلا --mode يفشل مغلقاً (خلط الوضع)');
  r = node(['scripts/deploy/supabase-push.mjs', '--dry-run', '--mode', 'bootstrap'], { GUARDED_REF: PROD });
  assert.notEqual(r.status, 0); ok('supabase-push يرفض GUARDED_REF=الإنتاج');
  const bsha = createHash('sha256').update(readFileSync('db/staging-bootstrap/baseline_through_061.sql','utf8').replace(/\r\n/g,'\n')).digest('hex');
  const msha = createHash('sha256').update(readFileSync('db/portal-migrations/062-request-documents.sql','utf8').replace(/\r\n/g,'\n')).digest('hex');
  const pushSrc = readFileSync('scripts/deploy/supabase-push.mjs', 'utf8');
  assert.match(pushSrc, new RegExp(bsha)); assert.match(pushSrc, new RegExp(msha));
  const remediationFiles = [
    'p0_1b-portal-users-guard-no-session-user-jwt-bypass.sql',
    'p0_1d-quote-confidentiality-direct-expense-permission.sql',
    'p0_1e-quote-confidentiality-rls-grants.sql',
    'p0_1f-flexible-committee-policy.sql', 'p0_1g-po-chain-transition-window.sql',
    'p0_1h-requester-safe-purchase-dossier.sql', 'p0_1i-final-release-blocker-hardening.sql',
    'p0_1j-exact-head-review-remediation.sql', 'p0_1k-independent-review-remediation.sql',
    'p0_1l-final-independent-review-remediation.sql', 'p0_1m-clean-install-raw-read-grants.sql',
    'p0_1n-direct-expense-raw-read-boundary.sql',
  ];
  for (const file of remediationFiles) {
    const sha = createHash('sha256').update(readFileSync('db/portal-migrations/' + file,'utf8').replace(/\r\n/g,'\n')).digest('hex');
    assert.match(pushSrc, new RegExp(sha), `launcher hash missing for ${file}`);
  }
  ok('بصمات الأساس و062 وكل سلسلة P0 المثبَّتة تطابق ملفات الحمولة (حارس انجراف)');
  r = node(['scripts/deploy/supabase-push.mjs', '--mode', 'bootstrap'], { GUARDED_REF: STAGING });
  assert.notEqual(r.status, 0); ok('supabase-push (حيّ) يرفض غياب SUPABASE_DB_PASSWORD');
  r = node(['scripts/deploy/supabase-push.mjs', '--mode', 'bootstrap'], { GUARDED_REF: STAGING, SUPABASE_DB_PASSWORD: 'x' });
  assert.notEqual(r.status, 0); ok('supabase-push (حيّ) يفشل بوضوح بلا Supabase CLI (لا نجاح زائف)')
  // (Gate-1 §2) ALLOWED_STAGING_REF: عند ضبطه يُرفَض أيّ مرجع غير المُصرَّح به (بما فيه أيّ ref آخر صالح)
  const OTHER = 'bbbbbbbbbbbbbbbbbbbb';
  r = node(['scripts/deploy/supabase-push.mjs', '--dry-run', '--mode', 'bootstrap'], { GUARDED_REF: STAGING, ALLOWED_STAGING_REF: STAGING });
  assert.equal(r.status, 0); ok('supabase-push: يقبل مرجع staging المُصرَّح به عند ضبط ALLOWED_STAGING_REF');
  r = node(['scripts/deploy/supabase-push.mjs', '--dry-run', '--mode', 'bootstrap'], { GUARDED_REF: OTHER, ALLOWED_STAGING_REF: STAGING });
  assert.notEqual(r.status, 0); assert.match(r.stderr, /غير ذي صلة/); ok('supabase-push: يرفض أيّ مرجع غير المُصرَّح به (ALLOWED_STAGING_REF)');
  r = node([...G.slice(0,1), '--ref', OTHER, '--confirm', 'STAGING', '--purpose', 'migrate', '--command', 'supabase-db-push', '--dry-run'], { ALLOWED_STAGING_REF: STAGING });
  assert.notEqual(r.status, 0); ok('env-guard: يرفض أيّ مرجع غير المُصرَّح به (ALLOWED_STAGING_REF)');
  // (G1-R6-03) e2e-run يفوّض إلزاميّاً إلى browser-run.mjs (يفشل مغلقاً بلا Playwright/‏staging — لا نجاح زائف)
  r = node(['scripts/e2e/run.mjs'], { E2E_SUPABASE_URL: `https://${STAGING}.supabase.co` });
  assert.notEqual(r.status, 0); assert.match(r.stdout, /تفويض إلى متصفّح/); ok('e2e-run يفوّض إلى browser-run.mjs ويفشل مغلقاً (G1-R6-03)');
  // (G1-R6-03/04) browser-run.mjs مباشرةً يفشل مغلقاً بلا E2E_BASE_URL/‏Playwright
  r = node(['scripts/e2e/browser-run.mjs'], { GUARDED_REF: STAGING });
  assert.notEqual(r.status, 0); ok('browser-run.mjs يفشل مغلقاً بلا staging/‏Playwright (لا نجاح زائف)');
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

console.log('▶ mig-parse: فرض «062 وحدها» في dry-run (G1-R5-02):');
{
  // إيجابيّ: 062 وحدها (اسم ملف) ⇒ تمرّ
  assert.deepEqual(assertExactly062(`Would push:\n ${MIG_DEST_NAME}\n`), [MIG_VERSION]); ok('062 وحدها ⇒ تمرّ');
  // تكرار نفس 062 (اسم + نسخة مجرّدة) ⇒ تمرّ (dedupe)
  assert.deepEqual(assertExactly062(`${MIG_DEST_NAME}\n${MIG_VERSION}\n`), [MIG_VERSION]); ok('تكرار 062 (اسم+مجرّدة) ⇒ يُدمَج ويمرّ');
  // 062 + هجرة إضافية غير متوقَّعة ⇒ يفشل مغلقاً
  assert.throws(() => assertExactly062(`${MIG_DEST_NAME}\n20260101000000_099_other.sql\n`), /إضافية غير متوقَّعة/); ok('062 + هجرة زائدة ⇒ يفشل');
  // صفر (up to date) ⇒ يفشل مغلقاً
  assert.throws(() => assertExactly062('Remote database is up to date.\n'), /لم يكتشف أيّ هجرة/); ok('صفر معلّق ⇒ يفشل');
  // نسخة مغايرة وحدها ⇒ يفشل مغلقاً
  assert.throws(() => assertExactly062('20260101000000_099_other.sql\n'), /ليست 062/); ok('غير-062 وحدها ⇒ يفشل');
  // غموض: نسختان مختلفتان ⇒ يفشل (extra)
  assert.equal(parsePendingVersions(`${MIG_DEST_NAME}\n20259999999999_x.sql`).length, 2); ok('parsePendingVersions يجمع النسخ الفريدة');
}

console.log('▶ staging baseline lineage (F1):');
{
  // (F1) الأساس مطابق للمولَّد الحتميّ (drift guard)
  let r = node(['scripts/deploy/build-baseline.mjs', '--check']);
  assert.equal(r.status, 0); ok('baseline_through_061.sql مطابق للمولَّد الحتميّ');
  // (F1) الأساس لا يحتوي 062، والهجرة 062 موجودة منفصلةً
  const base = readFileSync('db/staging-bootstrap/baseline_through_061.sql', 'utf8');
  assert.equal(/portal_request_documents/.test(base), false); ok('قطعة الأساس لا تحتوي كائنات 062 (through 061 فقط)');
  assert.equal(existsSync('db/portal-migrations/062-request-documents.sql'), true); ok('الهجرة 062 موجودة كملفّ منفصل يُطبَّق فوق الأساس');
  // (F1) لا بيان تاريخ مُخترَع بعد الآن
  assert.equal(existsSync('db/portal-migrations/manifest.json'), false); ok('بيان التاريخ المُخترَع أُزيل (لا history مُلفَّق)');
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
    PORTAL_SUPABASE_SERVICE_ROLE_KEY: svcRole, QUOTES_BUCKET: bkt, CF_PAGES_BRANCH: 'feature',
    CF_PAGES_COMMIT_SHA: '1234567890abcdef1234567890abcdef12345678' }, over || {});

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
  assert.equal(r.status, 200); assert.equal(r.body.ok, true); assert.equal(r.body.ref, STAGING);
  assert.equal(r.body.commit, '1234567890abcdef1234567890abcdef12345678'); ok('معاينة على staging بمفتاح مربوط ⇒ ok + commit identity');
  // main + مرجع الإنتاج + مفتاح مربوط للإنتاج ⇒ ok
  r = await cfg({ PORTAL_SUPABASE_URL: prodUrl, PORTAL_SUPABASE_ANON_KEY: anonProd, PORTAL_SUPABASE_SERVICE_ROLE_KEY: svcRole, QUOTES_BUCKET: bkt, CF_PAGES_BRANCH: 'main' });
  assert.equal(r.status, 200); assert.equal(r.body.ok, true); assert.equal(r.body.ref, PROD); ok('إنتاج على main بمفتاح مربوط ⇒ ok');
}

console.log(`\n✅ Stage-1 deployment-safety: ${n} تأكيداً — كلها نجحت.`);

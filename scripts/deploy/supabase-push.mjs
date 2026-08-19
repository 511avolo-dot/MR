#!/usr/bin/env node
/**
 * supabase-push.mjs — مُنفّذ هجرة Supabase مربوط بالهدف، بلينيَج staging صادق (F1؛ يستبدل نهج
 * «البيان المُخترَع للتاريخ الكامل» الذي رفضه المالك في G1-R7-01/02).
 * ════════════════════════════════════════════════════════════════════════════
 * لا نخترع طوابع زمنية لهجرات الإنتاج 001–058. بدلاً من ذلك لينيَج staging منفصل ومُرتَّب:
 *   1) قطعة أساس مُثبَّتة البصمة «baseline_through_061» (تُنشئ قاعدة فارغة بنجاح؛ المخطّط حتى 061، بلا 062)؛
 *   2) الهجرة الحقيقية 062 (`db/portal-migrations/062-request-documents.sql`).
 *   3) سلسلة المعالجات P0-1b…P0-1n بملفاتها وإصداراتها وبصماتها المثبَّتة.
 *
 * ثلاثة أوضاع صريحة (خلط الوضع يفشل مغلقاً):
 *   • --mode bootstrap : يبني workdir بالأساس فقط ويطبّقه على staging فارغ.
 *   • --mode apply-062 : يبني workdir بالأساس + 062، يتحقّق أنّ الأساس مُطبَّق أصلاً، يؤكّد أنّ 062 وحدها
 *                        معلّقة، ثم يطبّق 062.
 *   • --mode apply-remediations : يبني الحمولة الكاملة، ويتحقّق أنّ 062 مطبَّقة وأن المجموعة المعلّقة
 *                        تساوي سلسلة P0 المثبَّتة بالضبط، ثم يطبّقها بالترتيب.
 * لا migration repair · لا INSERT يدويّ في جداول التاريخ · لا استهداف إنتاج · كلمة المرور عبر SUPABASE_DB_PASSWORD.
 *
 * ⚠️ التنفيذ الحيّ يتطلّب Supabase CLI + staging مُصرَّح به من المالك (F5 external). بلا CLI: --dry-run يبني
 *    الحمولة ويتحقّق من كل البصمات ويطبع الخطة (بلا اتّصال). إثبات القاعدة الفعليّ محلّيّاً/CI عبر
 *    db/staging-bootstrap/verify-baseline.sh (قاعدة فارغة → أساس → 062 → الحزمة).
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { MIG_VERSION, assertExactly062, parsePendingVersions } from './mig-parse.mjs';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
// قطعة الأساس: مُثبَّتة البصمة. تُولَّد بـ scripts/deploy/build-baseline.mjs من portal-standalone.sql (قبل قسم 062).
const BASELINE_SQL = 'db/staging-bootstrap/baseline_through_061.sql';
const BASELINE_SHA = '5f9a1a6d56e7fe52d8f2143395252a876aa71c93e5be94f947cc2af16aa32d83';
const BASELINE_VERSION = '20260729120000';                                  // بعد 061 (…073619)، قبل 062 (…120000)
const BASELINE_DEST = `${BASELINE_VERSION}_baseline_through_061.sql`;
const MIG_062 = 'db/portal-migrations/062-request-documents.sql';
const MIG_062_SHA = '9ebecd908c63cb4f239728d3d349ae4afaa2d6cb54ce04fc13fb2ab3e2354f9e';
const MIG_062_DEST = `${MIG_VERSION}_062_request_documents.sql`;
const REMEDIATIONS = [
  ['20260802092848', 'db/portal-migrations/p0_1b-portal-users-guard-no-session-user-jwt-bypass.sql', '18c94971775eb83c0285251bb31564b8af57897013e2bb1f1943ef90f9bcea4c'],
  ['20260802142842', 'db/portal-migrations/p0_1d-quote-confidentiality-direct-expense-permission.sql', '8829ca057a695f3804ed61fc64f0faf2be8335e1da726a1f54d41bd9f9ec2719'],
  ['20260802162955', 'db/portal-migrations/p0_1e-quote-confidentiality-rls-grants.sql', '93c3439ba35387349e1adcb62c10aa17d9fb7230e665c2888941e7a9688fbe44'],
  ['20260802174929', 'db/portal-migrations/p0_1f-flexible-committee-policy.sql', '737b7e74d5cccb38a6abc28cc57035ef2fb84dc93ab69a80eb87067487f80113'],
  ['20260802175017', 'db/portal-migrations/p0_1g-po-chain-transition-window.sql', 'c853a68b2517d8e5836824adb3c6a3e236bfa94488d61832a12465ced59f44da'],
  ['20260802182252', 'db/portal-migrations/p0_1h-requester-safe-purchase-dossier.sql', '50999c830a6c1cae30cf9629f23324ad165672fc39f9f999b3e86c92ea8da3cb'],
  ['20260803081827', 'db/portal-migrations/p0_1i-final-release-blocker-hardening.sql', '696de4f929c155ccc8f0135f909d3024a869b562e9cf2387a220872a484d0b08'],
  ['20260803093553', 'db/portal-migrations/p0_1j-exact-head-review-remediation.sql', '2362c54b96137b629059e0e90ea97f033678a9af07342fab27ab265b5cb1d823'],
  ['20260803112523', 'db/portal-migrations/p0_1k-independent-review-remediation.sql', 'd5ea3edb1d2791364e1976cffab65b0864cc70de32f288116bd3623f12d7ac2e'],
  ['20260803121401', 'db/portal-migrations/p0_1l-final-independent-review-remediation.sql', 'b75e48f5c1e92afa53d5aaaf54cce28057b4184f13e441649dc9cba1837f5e51'],
  ['20260803123153', 'db/portal-migrations/p0_1m-clean-install-raw-read-grants.sql', '489fab0211db2f8e0ae2ac81ee0200dc2aec77fda4a35313b44976f9b6d2bcdf'],
  ['20260803125546', 'db/portal-migrations/p0_1n-direct-expense-raw-read-boundary.sql', 'f6a71b603b55e9c7c4ce67f6dec68c23d0989b3c8c5cc5f36ea1c8f3c7c002b8'],
].map(([version, source, sha]) => ({
  version, source, sha,
  dest: `${version}_${source.split('/').pop().replace(/\.sql$/, '').replace(/-/g, '_')}.sql`,
}));
function die(m) { console.error('❌ supabase-push: ' + m); process.exit(2); }
function sha256(p) {
  return createHash('sha256').update(readFileSync(p, 'utf8').replace(/\r\n/g, '\n')).digest('hex');
}

const ref = (process.env.GUARDED_REF || '').toLowerCase();
const dry = process.argv.includes('--dry-run');
const mi = process.argv.indexOf('--mode');
const mode = mi >= 0 ? process.argv[mi + 1] : '';
if (!/^[a-z0-9]{20}$/.test(ref)) die('GUARDED_REF غير صالح — يُضبط عبر env-guard فقط.');
if (ref === PROD_REF) die('GUARDED_REF هو الإنتاج — مرفوض.');
// (Gate-1 §2) قائمة سماح مرجع staging الوحيد المُصرَّح به: عند ضبط ALLOWED_STAGING_REF يُرفَض أيّ مرجع آخر.
const ALLOWED_STAGING_REF = (process.env.ALLOWED_STAGING_REF || '').toLowerCase();
if (ALLOWED_STAGING_REF) {
  if (!/^[a-z0-9]{20}$/.test(ALLOWED_STAGING_REF) || ALLOWED_STAGING_REF === PROD_REF) die('ALLOWED_STAGING_REF غير صالح أو يساوي الإنتاج — مرفوض.');
  if (ref !== ALLOWED_STAGING_REF) die(`GUARDED_REF («${ref}») ليس مرجع staging المُصرَّح به الوحيد («${ALLOWED_STAGING_REF}») — أيّ مرجع غير ذي صلة مرفوض.`);
}
if (!['bootstrap', 'apply-062', 'apply-remediations'].includes(mode)) {
  die('يجب تحديد --mode bootstrap|apply-062|apply-remediations صراحةً (خلط الوضع يفشل مغلقاً — F1).');
}

// تحقّق البصمات قبل أيّ شيء (انجراف الأساس أو 062 ⇒ إيقاف).
for (const [p, want, name] of [[BASELINE_SQL, BASELINE_SHA, 'baseline_through_061'], [MIG_062, MIG_062_SHA, '062']]) {
  if (!existsSync(p)) die(`ملف مفقود: ${p}`);
  const got = sha256(p);
  if (got !== want) die(`بصمة ${name} لا تطابق المثبَّتة (${want.slice(0, 12)}… ≠ ${got.slice(0, 12)}…) — إيقاف.`);
}
for (const migration of REMEDIATIONS) {
  if (!existsSync(migration.source)) die(`ملف معالجة مفقود: ${migration.source}`);
  const got = sha256(migration.source);
  if (got !== migration.sha) die(`بصمة ${migration.source} لا تطابق المثبَّتة (${migration.sha.slice(0, 12)}… ≠ ${got.slice(0, 12)}…) — إيقاف.`);
}

function payloadFiles() {
  const files = [{ source: BASELINE_SQL, dest: BASELINE_DEST }];
  if (mode !== 'bootstrap') files.push({ source: MIG_062, dest: MIG_062_DEST });
  if (mode === 'apply-remediations') files.push(...REMEDIATIONS);
  return files;
}
function copyPayload(migDir) {
  for (const file of payloadFiles()) copyFileSync(file.source, join(migDir, file.dest));
}

// ابنِ دليل عمل معزولاً حسب الوضع.
const workdir = mkdtempSync(join(tmpdir(), 'sbpush-'));
const migDir = join(workdir, 'supabase', 'migrations');
mkdirSync(migDir, { recursive: true });
copyPayload(migDir);
const refFile = join(workdir, 'supabase', '.temp', 'project-ref');

if (dry) {
  const files = payloadFiles().map((file) => file.dest);
  console.log(`✅ (dry-run, mode=${mode}) حمولة مُتحقَّقة بالبصمة (بلا اتّصال):\n`
    + `  • baseline sha ✓ (${BASELINE_SHA.slice(0, 12)}…)  ·  062 sha ✓ (${MIG_062_SHA.slice(0, 12)}…)  ·  P0 chain ${REMEDIATIONS.length}/${REMEDIATIONS.length} sha ✓\n`
    + `  • workdir migrations: ${files.join(' , ')}\n`
    + (mode === 'bootstrap'
      ? `  خطوات: init → link --project-ref ${ref} → verify linked==${ref} → db push --dry-run --linked (baseline معلّقة) → db push --linked`
      : mode === 'apply-062'
        ? `  خطوات: init → link --project-ref ${ref} → verify linked==${ref} → db push --dry-run --linked → assertExactly062 (062 وحدها) → db push --linked`
        : `  خطوات: init → link --project-ref ${ref} → verify linked==${ref} → db push --dry-run --linked → assert exact P0-1b…P0-1n chain → db push --linked`)
    + '\n  (staging مُهيّأ من نفس الأساس؛ كلمة المرور عبر SUPABASE_DB_PASSWORD — ليست في argv.)');
  process.exit(0);
}

// ── التنفيذ الحيّ ──
if (!process.env.SUPABASE_DB_PASSWORD) die('SUPABASE_DB_PASSWORD مطلوب في البيئة للتنفيذ الحيّ (لا argv).');
function sb(args) { return spawnSync('supabase', ['--workdir', workdir, ...args], { stdio: ['inherit', 'pipe', 'inherit'], encoding: 'utf8', env: process.env }); }
let r = spawnSync('supabase', ['--version'], { encoding: 'utf8' });
if (r.error) die('Supabase CLI غير مثبَّت — التنفيذ الحيّ غير ممكن هنا (owner-gated staging). استخدم --dry-run + verify-baseline.sh.');

r = sb(['init']); process.stdout.write(r.stdout || '');
if (r.status !== 0) die('فشل supabase init.');
copyPayload(migDir);
r = sb(['link', '--project-ref', ref]); process.stdout.write(r.stdout || '');
if (r.status !== 0) die('فشل supabase link (رمز ' + r.status + ').');
const linked = existsSync(refFile) ? readFileSync(refFile, 'utf8').trim().toLowerCase() : '';
if (linked !== ref) die(`المرجع المربوط («${linked || 'غير موجود'}») لا يطابق الهدف («${ref}») — إيقاف (fail-closed).`);

r = sb(['db', 'push', '--dry-run', '--linked']); const disc = r.stdout || ''; process.stdout.write(disc);
if (r.status !== 0) die('فشل db push --dry-run.');
if (mode === 'apply-062') {
  try { assertExactly062(disc); } catch (e) { die(e.message + '  (تأكّد أنّ الأساس مُطبَّق مسبقاً — استخدم --mode bootstrap على قاعدة فارغة أولاً).'); }
} else if (mode === 'apply-remediations') {
  const pending = parsePendingVersions(disc);
  const expected = REMEDIATIONS.map((migration) => migration.version);
  if (JSON.stringify(pending) !== JSON.stringify(expected)) {
    die(`مجموعة معالجات P0 المعلّقة لا تطابق السلسلة المثبَّتة. المتوقع=[${expected.join(', ')}] الفعلي=[${pending.join(', ')}]. تأكّد أن baseline و062 مطبّقتان وأنه لا توجد هجرة زائدة.`);
  }
} else if (!disc.includes(BASELINE_DEST) && !disc.includes('baseline_through_061')) {
  die('bootstrap: الـdry-run لم يُظهِر قطعة الأساس معلّقة — هل القاعدة غير فارغة؟ (fail-closed).');
}

r = sb(['db', 'push', '--linked']); process.stdout.write(r.stdout || '');
process.exit(typeof r.status === 'number' ? r.status : 1);

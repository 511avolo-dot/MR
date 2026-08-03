#!/usr/bin/env node
/**
 * supabase-push.mjs — مُنفّذ هجرة Supabase مربوط بالهدف، بلينيَج staging صادق (F1؛ يستبدل نهج
 * «البيان المُخترَع للتاريخ الكامل» الذي رفضه المالك في G1-R7-01/02).
 * ════════════════════════════════════════════════════════════════════════════
 * لا نخترع طوابع زمنية لهجرات الإنتاج 001–058. بدلاً من ذلك لينيَج staging منفصل من قِطعتين:
 *   1) قطعة أساس مُثبَّتة البصمة «baseline_through_061» (تُنشئ قاعدة فارغة بنجاح؛ المخطّط حتى 061، بلا 062)؛
 *   2) الهجرة الحقيقية 062 (`db/portal-migrations/062-request-documents.sql`).
 *
 * وضعان صريحان (خلط الوضع يفشل مغلقاً):
 *   • --mode bootstrap : يبني workdir بالأساس فقط ويطبّقه على staging فارغ.
 *   • --mode apply-062 : يبني workdir بالأساس + 062، يتحقّق أنّ الأساس مُطبَّق أصلاً، يؤكّد أنّ 062 وحدها
 *                        معلّقة، ثم يطبّق 062.
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
import { MIG_VERSION, assertExactly062 } from './mig-parse.mjs';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
// قطعة الأساس: مُثبَّتة البصمة. تُولَّد بـ scripts/deploy/build-baseline.mjs من portal-standalone.sql (قبل قسم 062).
const BASELINE_SQL = 'db/staging-bootstrap/baseline_through_061.sql';
const BASELINE_SHA = 'db0aa6dcfa93fb52227b1664fe7094893472aacc4de7abaddfb3597790230664';
const BASELINE_VERSION = '20260729120000';                                  // بعد 061 (…073619)، قبل 062 (…120000)
const BASELINE_DEST = `${BASELINE_VERSION}_baseline_through_061.sql`;
const MIG_062 = 'db/portal-migrations/062-request-documents.sql';
const MIG_062_SHA = '9ebecd908c63cb4f239728d3d349ae4afaa2d6cb54ce04fc13fb2ab3e2354f9e';
const MIG_062_DEST = `${MIG_VERSION}_062_request_documents.sql`;
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
if (mode !== 'bootstrap' && mode !== 'apply-062') die('يجب تحديد --mode bootstrap|apply-062 صراحةً (خلط الوضع يفشل مغلقاً — F1).');

// تحقّق البصمات قبل أيّ شيء (انجراف الأساس أو 062 ⇒ إيقاف).
for (const [p, want, name] of [[BASELINE_SQL, BASELINE_SHA, 'baseline_through_061'], [MIG_062, MIG_062_SHA, '062']]) {
  if (!existsSync(p)) die(`ملف مفقود: ${p}`);
  const got = sha256(p);
  if (got !== want) die(`بصمة ${name} لا تطابق المثبَّتة (${want.slice(0, 12)}… ≠ ${got.slice(0, 12)}…) — إيقاف.`);
}

// ابنِ دليل عمل معزولاً حسب الوضع.
const workdir = mkdtempSync(join(tmpdir(), 'sbpush-'));
const migDir = join(workdir, 'supabase', 'migrations');
mkdirSync(migDir, { recursive: true });
copyFileSync(BASELINE_SQL, join(migDir, BASELINE_DEST));
if (mode === 'apply-062') copyFileSync(MIG_062, join(migDir, MIG_062_DEST));
const refFile = join(workdir, 'supabase', '.temp', 'project-ref');

if (dry) {
  const files = mode === 'bootstrap' ? [BASELINE_DEST] : [BASELINE_DEST, MIG_062_DEST];
  console.log(`✅ (dry-run, mode=${mode}) حمولة مُتحقَّقة بالبصمة (بلا اتّصال):\n`
    + `  • baseline sha ✓ (${BASELINE_SHA.slice(0, 12)}…)  ·  062 sha ✓ (${MIG_062_SHA.slice(0, 12)}…)\n`
    + `  • workdir migrations: ${files.join(' , ')}\n`
    + (mode === 'bootstrap'
      ? `  خطوات: init → link --project-ref ${ref} → verify linked==${ref} → db push --dry-run --linked (baseline معلّقة) → db push --linked`
      : `  خطوات: init → link --project-ref ${ref} → verify linked==${ref} → db push --dry-run --linked → assertExactly062 (062 وحدها) → db push --linked`)
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
copyFileSync(BASELINE_SQL, join(migDir, BASELINE_DEST));
if (mode === 'apply-062') copyFileSync(MIG_062, join(migDir, MIG_062_DEST));
r = sb(['link', '--project-ref', ref]); process.stdout.write(r.stdout || '');
if (r.status !== 0) die('فشل supabase link (رمز ' + r.status + ').');
const linked = existsSync(refFile) ? readFileSync(refFile, 'utf8').trim().toLowerCase() : '';
if (linked !== ref) die(`المرجع المربوط («${linked || 'غير موجود'}») لا يطابق الهدف («${ref}») — إيقاف (fail-closed).`);

r = sb(['db', 'push', '--dry-run', '--linked']); const disc = r.stdout || ''; process.stdout.write(disc);
if (r.status !== 0) die('فشل db push --dry-run.');
if (mode === 'apply-062') {
  try { assertExactly062(disc); } catch (e) { die(e.message + '  (تأكّد أنّ الأساس مُطبَّق مسبقاً — استخدم --mode bootstrap على قاعدة فارغة أولاً).'); }
} else if (!disc.includes(BASELINE_DEST) && !disc.includes('baseline_through_061')) {
  die('bootstrap: الـdry-run لم يُظهِر قطعة الأساس معلّقة — هل القاعدة غير فارغة؟ (fail-closed).');
}

r = sb(['db', 'push', '--linked']); process.stdout.write(r.stdout || '');
process.exit(typeof r.status === 'number' ? r.status : 1);

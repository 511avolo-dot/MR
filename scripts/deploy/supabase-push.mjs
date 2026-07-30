#!/usr/bin/env node
/**
 * supabase-push.mjs — مُنفّذ هجرة Supabase مربوط بالهدف + حمولة تاريخ كامل مُتحقَّقة بالبصمة
 * (G1-R3-01 + G1-R4-01 + G1-R6-01/02).
 * ════════════════════════════════════════════════════════════════════════════
 * العيوب المُصحَّحة:
 *  • (R4-01) كان دليل العمل فارغاً — لا حمولة.
 *  • (R6-01) ثم صار يحوي 062 وحدها — يفتقد التاريخ (059/060/061…) فينتج عدم تطابق تاريخ لا {062} نظيفة.
 * الآن: يبني دليل عمل يحوي **كامل تاريخ الهجرات** من `manifest.json` (كلٌّ باسم إصدار Supabase قانونيّ
 * وبصمة مُتحقَّقة)، فيطابق تاريخ staging المُهيّأ من البيان نفسه ⇒ `db push --dry-run --linked` يُظهر 062
 * وحدها معلّقة. إصدار 062 = `20260730120000` (بعد 061 المُتحقَّق حيّاً — R6-02).
 *
 * التدفّق الحيّ: verify manifest ⇒ init ⇒ نسخ كل الهجرات ⇒ link --project-ref <GUARDED_REF> ⇒ تحقّق المرجع
 * المربوط == الهدف ⇒ `db push --dry-run --linked` ⇒ **assertExactly062** ⇒ `db push --linked`.
 * كلمة المرور عبر SUPABASE_DB_PASSWORD (لا argv). staging يُهيّأ من البيان نفسه (خطوة مالك، انظر STAGING_SETUP_PLAN).
 *
 * ⚠️ التنفيذ الحيّ يتطلّب Supabase CLI مثبَّت + staging مُهيّأ من البيان (owner-gated, R6-06). بلا CLI:
 *    `--dry-run` يبني الحمولة الكاملة ويتحقّق من كل البصمات ويطبع الخطة (بلا اتّصال).
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { MIG_VERSION, assertExactly062 } from './mig-parse.mjs';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
const MIG_DIR = 'db/portal-migrations';
const MANIFEST = join(MIG_DIR, 'manifest.json');
function die(m) { console.error('❌ supabase-push: ' + m); process.exit(2); }
function sha256(p) { return createHash('sha256').update(readFileSync(p)).digest('hex'); }

const ref = (process.env.GUARDED_REF || '').toLowerCase();
const dry = process.argv.includes('--dry-run');
if (!/^[a-z0-9]{20}$/.test(ref)) die('GUARDED_REF غير صالح — يُضبط عبر env-guard فقط.');
if (ref === PROD_REF) die('GUARDED_REF هو الإنتاج — مرفوض.');

// حمّل البيان وتحقّق من بصمة كل هجرة (يمنع دفع حمولة مُلوَّثة/منجرفة — لكامل التاريخ لا 062 وحدها).
if (!existsSync(MANIFEST)) die(`بيان الهجرات غير موجود: ${MANIFEST} (ولّده: node scripts/deploy/build-migration-manifest.mjs).`);
const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'));
const head = manifest.migrations[manifest.migrations.length - 1];
if (head.seq !== '062' || head.version !== MIG_VERSION) die(`رأس البيان (${head.seq}=${head.version}) لا يطابق 062=${MIG_VERSION} — أعِد توليد البيان.`);
for (const m of manifest.migrations) {
  const src = join(MIG_DIR, m.file);
  if (!existsSync(src)) die(`هجرة مفقودة: ${src}`);
  const actual = sha256(src);
  if (actual !== m.sha256) die(`بصمة ${m.file} لا تطابق البيان (${m.sha256.slice(0, 12)}… ≠ ${actual.slice(0, 12)}…) — إيقاف.`);
}

// ابنِ دليل عمل معزولاً بكامل التاريخ (كلّ هجرة باسم إصدار Supabase).
const workdir = mkdtempSync(join(tmpdir(), 'sbpush-'));
const migDir = join(workdir, 'supabase', 'migrations');
mkdirSync(migDir, { recursive: true });
for (const m of manifest.migrations) copyFileSync(join(MIG_DIR, m.file), join(migDir, m.dest));
const refFile = join(workdir, 'supabase', '.temp', 'project-ref');

if (dry) {
  console.log('✅ (dry-run) حمولة التاريخ الكامل جاهزة ومُتحقَّقة بالبصمة (بلا اتّصال):\n'
    + `  • ${manifest.count} هجرة من البيان (كلّها بصماتها مطابقة ✓)\n`
    + `  • الرأس: ${head.dest}  (062، الإصدار ${MIG_VERSION} — بعد 061)\n`
    + `  خطوات التنفيذ الحيّ: init → نسخ كامل التاريخ → link --project-ref ${ref} → verify linked==${ref}\n`
    + `    → db push --dry-run --linked (assertExactly062: 062 وحدها معلّقة على staging المُهيّأ من البيان)\n`
    + `    → db push --linked   (كلمة المرور عبر SUPABASE_DB_PASSWORD — ليست في argv)`);
  process.exit(0);
}

// ── التنفيذ الحيّ ──
if (!process.env.SUPABASE_DB_PASSWORD) die('SUPABASE_DB_PASSWORD مطلوب في البيئة للتنفيذ الحيّ (لا argv).');
function sb(args) { return spawnSync('supabase', ['--workdir', workdir, ...args], { stdio: ['inherit', 'pipe', 'inherit'], encoding: 'utf8', env: process.env }); }
let r = spawnSync('supabase', ['--version'], { encoding: 'utf8' });
if (r.error) die('Supabase CLI غير مثبَّت — التنفيذ الحيّ غير ممكن هنا (ثبّت الإصدار المثبَّت في خط staging). استخدم --dry-run.');

r = sb(['init']); process.stdout.write(r.stdout || '');
if (r.status !== 0) die('فشل supabase init.');
for (const m of manifest.migrations) copyFileSync(join(MIG_DIR, m.file), join(migDir, m.dest)); // أعِد النسخ إن أعاد init التهيئة
r = sb(['link', '--project-ref', ref]); process.stdout.write(r.stdout || '');
if (r.status !== 0) die('فشل supabase link (رمز ' + r.status + ').');
const linked = existsSync(refFile) ? readFileSync(refFile, 'utf8').trim().toLowerCase() : '';
if (linked !== ref) die(`المرجع المربوط («${linked || 'غير موجود'}») لا يطابق الهدف («${ref}») — إيقاف قبل الدفع (fail-closed).`);

r = sb(['db', 'push', '--dry-run', '--linked']); const disc = r.stdout || ''; process.stdout.write(disc);
if (r.status !== 0) die('فشل db push --dry-run.');
// (G1-R5-02/R6-01) على staging المُهيّأ من البيان (تاريخ متطابق حتى 061) يجب أن تكون 062 وحدها المعلّقة.
try { assertExactly062(disc); } catch (e) { die(e.message + '  (تحقّق أنّ staging مُهيّأ من البيان حتى 061 — R6-06).'); }

r = sb(['db', 'push', '--linked']); process.stdout.write(r.stdout || '');
process.exit(typeof r.status === 'number' ? r.status : 1);

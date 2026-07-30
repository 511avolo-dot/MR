#!/usr/bin/env node
/**
 * supabase-push.mjs — مُنفّذ هجرة Supabase مربوط بالهدف + بحمولة مُتحقَّقة بالبصمة (G1-R3-01 + G1-R4-01).
 * ════════════════════════════════════════════════════════════════════════════
 * الخلل السابق: كان يُنشئ دليل عمل **فارغاً** فلا حمولة هجرة تُدفَع (تحقّق المرجع المربوط لا يتحقّق من
 * الحمولة). الآن يبني دليلاً معزولاً حتميّاً يحوي:
 *   • `supabase/config.toml` عبر `supabase init` (تخطيط صحيح للإصدار المثبَّت)؛
 *   • نسخة **مُتحقَّقة بـ SHA-256** من الهجرة 062 تحت `supabase/migrations/<ts>_062_*.sql`.
 * ثم: `link --project-ref <GUARDED_REF>` (كلمة المرور عبر SUPABASE_DB_PASSWORD) → تحقّق المرجع المربوط ==
 * الهدف → **`db push --dry-run --linked`** والتأكّد أنّ 062 هي المُكتشَفة ولا هجرة أخرى معلّقة → `db push --linked`.
 * تلوّث/انجراف الهجرة يُوقِف قبل أيّ اتّصال (بصمة مثبَّتة). لا يُصنَّع/يُعاد ترقيم تاريخ الهجرات.
 *
 * ⚠️ التنفيذ الحيّ يتطلّب Supabase CLI مثبَّت الإصدار + staging (G1-R4-04/06). بلا CLI: `--dry-run` يبني
 *    الحمولة ويتحقّق من البصمة ويطبع الخطة (بلا اتّصال)؛ التنفيذ الحقيقي يخرج بوضوح إن غاب الـCLI.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { MIG_DEST_NAME, assertExactly062 } from './mig-parse.mjs';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
const MIG_SRC = 'db/portal-migrations/062-request-documents.sql';
const MIG_SHA = '7b56d64abd7b9b8b2601b5f294e8a2367f0ac7136c1689b12bde299814f35bf3';   // بصمة مثبَّتة للهجرة 062
function die(m) { console.error('❌ supabase-push: ' + m); process.exit(2); }
function sha256(p) { return createHash('sha256').update(readFileSync(p)).digest('hex'); }

const ref = (process.env.GUARDED_REF || '').toLowerCase();
const dry = process.argv.includes('--dry-run');
if (!/^[a-z0-9]{20}$/.test(ref)) die('GUARDED_REF غير صالح — يُضبط عبر env-guard فقط.');
if (ref === PROD_REF) die('GUARDED_REF هو الإنتاج — مرفوض.');

// (G1-R4-01) تحقّق البصمة قبل أيّ شيء — يمنع دفع حمولة مُلوَّثة/منجرفة.
if (!existsSync(MIG_SRC)) die(`الهجرة المصدر غير موجودة: ${MIG_SRC}`);
const actual = sha256(MIG_SRC);
if (actual !== MIG_SHA) die(`بصمة الهجرة 062 لا تطابق المثبَّتة (متوقَّع ${MIG_SHA.slice(0, 12)}…، فعليّ ${actual.slice(0, 12)}…) — إيقاف. حدّث MIG_SHA عمداً عند تغيير مقصود.`);

// ابنِ دليل عمل معزولاً + حمولة الهجرة (لا يرث supabase/ المستودع).
const workdir = mkdtempSync(join(tmpdir(), 'sbpush-'));
const migDir = join(workdir, 'supabase', 'migrations');
mkdirSync(migDir, { recursive: true });
const migDest = join(migDir, MIG_DEST_NAME);
copyFileSync(MIG_SRC, migDest);
const refFile = join(workdir, 'supabase', '.temp', 'project-ref');

if (dry) {
  console.log('✅ (dry-run) حمولة الهجرة المعزولة جاهزة (بلا اتّصال):\n'
    + `  • sha256(062) = ${actual}  (مطابقة للمثبَّتة ✓)\n`
    + `  • ${join('supabase', 'migrations', MIG_DEST_NAME)}  (نسخة مُتحقَّقة)\n`
    + `  خطوات التنفيذ الحيّ: supabase --workdir <wd> init → link --project-ref ${ref} → verify linked==${ref}\n`
    + `    → db push --dry-run --linked (تأكّد اكتشاف 062 ولا معلّق آخر) → db push --linked\n`
    + '  (كلمة المرور عبر SUPABASE_DB_PASSWORD في البيئة — ليست في argv.)');
  process.exit(0);
}

// ── التنفيذ الحيّ: يتطلّب CLI + كلمة مرور ──
if (!process.env.SUPABASE_DB_PASSWORD) die('SUPABASE_DB_PASSWORD مطلوب في البيئة للتنفيذ الحيّ (لا argv).');
function sb(args) { return spawnSync('supabase', ['--workdir', workdir, ...args], { stdio: ['inherit', 'pipe', 'inherit'], encoding: 'utf8', env: process.env }); }
let r = spawnSync('supabase', ['--version'], { encoding: 'utf8' });
if (r.error) die('Supabase CLI غير مثبَّت — التنفيذ الحيّ غير ممكن هنا (ثبّت الإصدار المثبَّت في خط staging). استخدم --dry-run للتحقّق دون اتّصال.');

r = sb(['init']); process.stdout.write(r.stdout || '');
if (r.status !== 0) die('فشل supabase init.');
copyFileSync(MIG_SRC, migDest);   // أعِد وضع الهجرة إن أعاد init تهيئة المجلّد
r = sb(['link', '--project-ref', ref]); process.stdout.write(r.stdout || '');
if (r.status !== 0) die('فشل supabase link (رمز ' + r.status + ').');
const linked = existsSync(refFile) ? readFileSync(refFile, 'utf8').trim().toLowerCase() : '';
if (linked !== ref) die(`المرجع المربوط («${linked || 'غير موجود'}») لا يطابق الهدف («${ref}») — إيقاف قبل الدفع (fail-closed).`);

r = sb(['db', 'push', '--dry-run', '--linked']); const disc = r.stdout || ''; process.stdout.write(disc);
if (r.status !== 0) die('فشل db push --dry-run.');
// (G1-R5-02) فرض حتميّ: المجموعة المعلّقة == {062} بالضبط (يفشل مغلقاً على صفر/زائدة/غير-062).
try { assertExactly062(disc); } catch (e) { die(e.message); }

r = sb(['db', 'push', '--linked']); process.stdout.write(r.stdout || '');
process.exit(typeof r.status === 'number' ? r.status : 1);

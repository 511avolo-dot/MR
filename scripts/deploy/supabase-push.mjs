#!/usr/bin/env node
/**
 * supabase-push.mjs — مُشغّل هجرة Supabase مربوط بالهدف (G1-R3-01). يُستدعى حصراً عبر
 * env-guard (--command supabase-db-push) الذي يضبط GUARDED_REF بالمرجع المُتحقَّق منه.
 *
 * العقد الصحيح للـCLI: ‏`supabase db push` لا يقبل ‎--project-ref (ذاك على ‎supabase link).
 * لذا: (1) دليل عمل معزول (لا يرث ربط المستودع القائم — قد يكون للإنتاج)؛ (2) ‏`supabase link
 * --project-ref <GUARDED_REF>`‏ (كلمة المرور عبر SUPABASE_DB_PASSWORD في البيئة، لا argv)؛
 * (3) **تحقّق أنّ المرجع المربوط فعلاً == GUARDED_REF** قبل الدفع (يفشل مغلقاً وإلّا)؛ (4) ‏`supabase
 * db push --linked`. عقد الأعلام يُثبَّت في CI عبر ‎`supabase … --help` (خطوة اختيارية عند توفّر الـCLI).
 *   --dry-run يطبع الخطة دون تنفيذ (بلا أسرار).
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
function die(m) { console.error('❌ supabase-push: ' + m); process.exit(2); }

const ref = (process.env.GUARDED_REF || '').toLowerCase();
const dry = process.argv.includes('--dry-run');
if (!/^[a-z0-9]{20}$/.test(ref)) die('GUARDED_REF غير صالح — يُضبط عبر env-guard فقط.');
if (ref === PROD_REF) die('GUARDED_REF هو الإنتاج — مرفوض.');
if (!process.env.SUPABASE_DB_PASSWORD) die('SUPABASE_DB_PASSWORD مطلوب في البيئة (لا يُمرَّر عبر argv).');

const workdir = mkdtempSync(join(tmpdir(), 'sbpush-'));   // معزول: لا يرث supabase/ المستودع
const linkArgs = ['--workdir', workdir, 'link', '--project-ref', ref];
const pushArgs = ['--workdir', workdir, 'db', 'push', '--linked'];
const refFile = join(workdir, 'supabase', '.temp', 'project-ref');

if (dry) {
  console.log('✅ (dry-run) خطة الهجرة المربوطة بالهدف (دليل عمل معزول):\n'
    + `  1) supabase ${linkArgs.join(' ')}\n`
    + `  2) تحقّق: محتوى ${'<workdir>/supabase/.temp/project-ref'} == ${ref} (وإلّا إيقاف قبل الدفع)\n`
    + `  3) supabase ${pushArgs.join(' ')}\n`
    + '  (كلمة المرور عبر SUPABASE_DB_PASSWORD في البيئة — ليست في argv.)');
  process.exit(0);
}

let r = spawnSync('supabase', linkArgs, { stdio: 'inherit', env: process.env });
if (r.error) die('تعذّر تشغيل supabase (ثبّت CLI مُثبَّت الإصدار): ' + r.error.message);
if (r.status !== 0) die('فشل supabase link (رمز ' + r.status + ').');

// تحقّق حاسم: المرجع المربوط فعلاً يجب أن يطابق الهدف المُتحقَّق منه (يمنع دفعاً لمشروع آخر).
const linked = existsSync(refFile) ? readFileSync(refFile, 'utf8').trim().toLowerCase() : '';
if (linked !== ref) die(`المرجع المربوط («${linked || 'غير موجود'}») لا يطابق الهدف المُتحقَّق منه («${ref}») — إيقاف قبل الدفع (fail-closed).`);

r = spawnSync('supabase', pushArgs, { stdio: 'inherit', env: process.env });
if (r.error) die('تعذّر تشغيل supabase db push: ' + r.error.message);
process.exit(typeof r.status === 'number' ? r.status : 1);

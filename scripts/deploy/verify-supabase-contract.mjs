#!/usr/bin/env node
/**
 * verify-supabase-contract.mjs — تحقّق عقد الـCLI الحقيقي (G1-R3-01): يتأكّد أنّ أعلام المُشغّل
 * تطابق الإصدار المثبَّت فعليّاً بتحليل ‎`--help` الحقيقي (لا محاكاة). يُشغَّل حيث الـCLI متوفّر
 * (خطوة تجهيز staging)؛ إن غاب الـCLI **يتخطّى بوضوح** (خروج 0) بدل ادّعاء تحقّق زائف.
 *
 * العقد المتوقَّع: ‎supabase db push فيه --linked ولا --project-ref؛ ‎supabase link فيه --project-ref.
 * الإصدار المثبَّت الموصى به: SUPABASE_CLI_PIN (مثلاً 2.x) — يُطبع للتوثيق.
 */
import { spawnSync } from 'node:child_process';

const PIN = process.env.SUPABASE_CLI_PIN || '(غير مثبَّت — ثبّت الإصدار في خط تجهيز staging)';
function help(args) { const r = spawnSync('supabase', args, { encoding: 'utf8' }); return r; }

const probe = help(['--version']);
if (probe.error) {
  console.log('⏭️  supabase CLI غير متوفّر هنا — تخطّي تحقّق العقد (يُنفَّذ في تجهيز staging). لا ادّعاء تحقّق.');
  process.exit(0);
}
console.log(`▶ supabase CLI موجود (${(probe.stdout || '').trim()}؛ الإصدار الموصى بتثبيته: ${PIN}).`);

let fail = 0;
const push = help(['db', 'push', '--help']).stdout || '';
const link = help(['link', '--help']).stdout || '';
if (!/--linked\b/.test(push)) { console.error('❌ supabase db push يفتقد --linked.'); fail++; }
if (/--project-ref\b/.test(push)) { console.error('❌ supabase db push يعرض --project-ref (عقد غير متوقَّع — راجع المُشغّل).'); fail++; }
if (!/--project-ref\b/.test(link)) { console.error('❌ supabase link يفتقد --project-ref.'); fail++; }
if (fail) { console.error(`العقد لا يطابق المُشغّل (${fail} خرق) — أوقف قبل أيّ هجرة.`); process.exit(2); }
console.log('✅ عقد الـCLI مطابق للمُشغّل (db push --linked بلا --project-ref؛ link --project-ref).');
process.exit(0);

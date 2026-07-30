#!/usr/bin/env node
/**
 * env-guard.mjs — حارس عزل staging (Stage 1، البند 3؛ مُعاد تصميمه لـ G1-R2-01).
 * ════════════════════════════════════════════════════════════════════════════
 * الدرس من المراجعة: تأمين تمرير أمر حرّ بالاستدلال على الرموز قابل للتجاوز
 * (‏`sh -c '… --project-ref <prod>'`‏، ‏`db.<ref>.supabase.co`‏، تداخل نصّي…). لذا:
 *   • لا تمرير أمر حرّ إطلاقاً. فقط **مُحوّلات (adapters) مسمّاة** تبني وسيط الهدف داخليّاً
 *     من المرجع المُتحقَّق منه، ولا تقبل عنوان/مرجع هدف من المتّصل.
 *   • `migrate`/`e2e` **يُلزمان التنفيذ المقترن** (`--command <adapter>`)؛ لا خروج-0 مجرّد.
 *   • `--purpose check` وضع تحقّق صريح لا يأذن بتشغيل أيّ أمر منفصل.
 *   • أيّ عَلَم غير معروف أو `--exec` (القديم) أو مُفسِّر صدفة ⇒ رفض (fail-closed).
 *
 * الاستخدام:
 *   node scripts/env-guard.mjs --purpose migrate --ref "$REF" --confirm STAGING --command supabase-db-push
 *   node scripts/env-guard.mjs --purpose e2e     --ref "$REF" --confirm STAGING --command browser-e2e
 *   node scripts/env-guard.mjs --purpose check   --ref "$REF" --confirm STAGING        # تحقّق فقط، لا أمر
 *   (+ --dry-run لطباعة الأمر المُنشأ دون تنفيذ — للاختبار/المعاينة، بلا أسرار.)
 */
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';

const PROD_REF = 'mwbjoysuybgbrvfrprex';   // مرجع الإنتاج — ممنوع منعاً باتّاً

const KNOWN_FLAGS = new Set(['--purpose', '--ref', '--url', '--confirm', '--command', '--dry-run']);

function arg(name) { const i = process.argv.indexOf('--' + name); return i >= 0 ? process.argv[i + 1] : undefined; }
function has(name) { return process.argv.includes('--' + name); }
function die(msg) { console.error('❌ حارس البيئة رفض: ' + msg); process.exit(2); }

function refOf(s) {                          // مرجع من عنوان قانوني أو رمز مجرّد 20 محرفاً فقط
  if (!s) return null;
  const raw = String(s).trim();
  if (/^https?:\/\//i.test(raw)) {
    let u; try { u = new URL(raw); } catch (_) { return null; }
    if (u.protocol !== 'https:' || u.username || u.password) return null;
    if (u.port && u.port !== '443') return null;
    const m = /^([a-z0-9]{20})\.supabase\.co$/i.exec(u.hostname.toLowerCase());
    return m ? m[1] : null;
  }
  return /^[a-z0-9]{20}$/i.test(raw) ? raw.toLowerCase() : null;
}
function safePath(p, re) { return (typeof p === 'string' && re.test(p) && existsSync(p)) ? p : null; }

// ── رفض الأعلام المجهولة و--exec القديم (منع تهريب هدف عبر أعلام غير مُصرّح بها) ──
if (has('exec')) die('«--exec» أُزيل (كان قابلاً للتجاوز). استخدم --command <adapter> بمُحوّل مسمّى.');
for (let i = 2; i < process.argv.length; i++) {
  const tok = process.argv[i];
  if (tok.startsWith('--') && !KNOWN_FLAGS.has(tok)) die(`عَلَم غير معروف: ${tok} (fail-closed — لا تهريب هدف).`);
}

const purpose = arg('purpose') || '';
const ref = refOf(arg('ref') || arg('url') || '');
const confirm = arg('confirm') || process.env.STAGING_CONFIRM || '';
const dryRun = has('dry-run');

console.log(`▶ env-guard: purpose=${purpose}  target_ref=${ref || '(غير محدَّد)'}`);
if (!ref)                 die('لم يُحدَّد مرجع مشروع الهدف (--ref/--url) بشكل قانوني.');
if (ref === PROD_REF)     die(`الهدف هو مشروع الإنتاج (${PROD_REF}) — مرفوض. staging مشروع منفصل.`);
if (confirm !== 'STAGING') die('تأكيد staging مفقود — مرّر STAGING_CONFIRM=STAGING (تأكيد صريح).');

// ── وضع التحقّق فقط: لا يأذن بتشغيل أيّ أمر ──
if (purpose === 'check') {
  console.log(`✅ تحقّق فقط: الهدف «${ref}» ليس الإنتاج، وتأكيد STAGING موجود. `
    + '(هذا الوضع لا يأذن بتشغيل أيّ أمر منفصل — استخدم --purpose migrate/e2e مع --command للتنفيذ المقترن.)');
  process.exit(0);
}
if (purpose !== 'migrate' && purpose !== 'e2e') die('الغرض يجب أن يكون migrate أو e2e أو check.');

// ── المُحوّلات المسمّاة: تبني وسيط الهدف داخليّاً من المرجع المُتحقَّق منه ──
// (G1-R4-02) مُنفّذ الهجرة الوحيد الموثوق = Supabase CLI عبر المُشغّل الثابت. أُزيل مسار psql الخام
// (غير ذرّي + لا يُسجّل تاريخ الهجرة في supabase_migrations — يُعيد غموض التاريخ الذي عالجته البوّابة 0).
const ADAPTERS = {
  // (G1-R3-01/G1-R4-01) المُشغّل يبني حمولة هجرة معزولة مُتحقَّقة بالبصمة ثم link→verify→dry-run→push --linked.
  'supabase-db-push': { purpose: 'migrate', build(r) {
    return { program: 'node', args: ['scripts/deploy/supabase-push.mjs'], env: {},
      show: `node scripts/deploy/supabase-push.mjs  (GUARDED_REF=${r} → build isolated workdir + verify 062 sha → link --project-ref ${r} → verify linked==${r} → db push --dry-run --linked → db push --linked; password via SUPABASE_DB_PASSWORD)` };
  } },
  // (G1-R3-02/G1-R4-03/G1-R6-03) مُشغّل E2E ثابت وحيد (لا --spec) = **متصفّح Playwright الفعليّ** مباشرةً
  // (`browser-run.mjs`: حدّ سياق المتصفّح context.route + سيناريو smoke). يفشل مغلقاً بلا الحزمة/‏staging.
  'browser-e2e': { purpose: 'e2e', build(r) {
    return { program: 'node', args: ['scripts/e2e/browser-run.mjs'], env: { E2E_SUPABASE_URL: `https://${r}.supabase.co` },
      show: `node scripts/e2e/browser-run.mjs  (E2E_SUPABASE_URL=https://${r}.supabase.co؛ حدّ سياق المتصفّح مقيَّد بـ${r}؛ يفشل مغلقاً بلا Playwright/‏staging)` };
  } },
};

const command = arg('command');
if (!command) die(`${purpose} يتطلّب تنفيذاً مقترناً: --command <adapter> (${Object.keys(ADAPTERS).join(' | ')}).`);
const adapter = ADAPTERS[command];
if (!adapter) die(`أمر غير معروف «${command}». المسموح: ${Object.keys(ADAPTERS).join(' | ')} (لا تمرير أمر حرّ).`);
if (adapter.purpose !== purpose) die(`الأمر «${command}» للغرض «${adapter.purpose}» لا «${purpose}».`);

const built = adapter.build(ref);
if (dryRun) {
  console.log(`✅ (dry-run) الأمر المُنشأ داخليّاً بالهدف المُتحقَّق منه «${ref}»:\n   ${built.show}`);
  process.exit(0);
}
console.log(`▶ env-guard: تشغيل «${command}» ← ${built.show}`);
const r = spawnSync(built.program, built.args, { stdio: 'inherit', env: { ...process.env, GUARDED_REF: ref, ...built.env } });
if (r.error) die(`تعذّر تشغيل «${built.program}»: ${r.error.message}`);
process.exit(typeof r.status === 'number' ? r.status : 1);

#!/usr/bin/env node
/**
 * env-guard.mjs — حارس البيئة لعزل staging عن الإنتاج (متطلّب المالك، البند 6).
 * ════════════════════════════════════════════════════════════════════════════
 * يُستخدَم قبل: (أ) تطبيق هجرات staging، (ب) تشغيل E2E على المتصفّح.
 * يمنع لمس مشروع الإنتاج، ويطبع المرجع المستهدَف، ويطلب تأكيد STAGING صريحاً.
 *
 * الاستخدام:
 *   node scripts/env-guard.mjs --purpose migrate  --ref "$STAGING_PROJECT_REF" --confirm "$STAGING_CONFIRM"
 *   node scripts/env-guard.mjs --purpose e2e       --url "$E2E_SUPABASE_URL"    --confirm "$STAGING_CONFIRM"
 * يخرج 0 إذا كان الهدف staging مؤكَّداً؛ وإلا يخرج ≠ 0 ويطبع سبب الرفض.
 */
const PROD_REF = 'mwbjoysuybgbrvfrprex';   // مرجع مشروع الإنتاج — ممنوع منعاً باتّاً

function arg(name) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
function refOf(s) {
  if (!s) return null;
  const m = /^https:\/\/([a-z0-9]+)\.supabase\.co/i.exec(s);
  return (m ? m[1] : s).toLowerCase();
}
function die(msg) { console.error('❌ حارس البيئة رفض: ' + msg); process.exit(2); }

const purpose = arg('purpose') || 'unknown';
const ref = refOf(arg('ref') || arg('url') || '');
const confirm = arg('confirm') || process.env.STAGING_CONFIRM || '';

console.log(`▶ env-guard: purpose=${purpose}  target_ref=${ref || '(غير محدَّد)'}`);   // (د) اطبع الهدف دائماً

if (!ref)                 die('لم يُحدَّد مرجع مشروع الهدف (--ref/--url).');
if (ref === PROD_REF)     die(`الهدف هو مشروع الإنتاج (${PROD_REF}) — مرفوض. staging يجب أن يكون مشروعاً منفصلاً.`);
if (confirm !== 'STAGING') die('تأكيد staging مفقود — مرّر STAGING_CONFIRM=STAGING (تأكيد صريح مطلوب).');

// (أ/ب) الهدف ليس الإنتاج + التأكيد موجود ⇒ مسموح.
console.log(`✅ حارس البيئة: الهدف «${ref}» ليس الإنتاج، وتأكيد STAGING موجود — يُسمح بـ${purpose}.`);
process.exit(0);

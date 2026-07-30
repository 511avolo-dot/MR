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
 *
 * وضع الاقتران بالأمر (البند 3 — «الهدف المُتحقَّق منه = الهدف المُستخدَم فعلاً»):
 *   node scripts/env-guard.mjs --purpose migrate --ref X --confirm STAGING --exec -- <command...>
 * لا يكتفي بالتحقّق: بعد القبول **يُشغّل الأمر بنفسه** ويحقن المرجع المُتحقَّق منه في بيئته
 * (GUARDED_REF + STAGING_PROJECT_REF + E2E target)، فلا يمكن للأمر أن يستهدف مرجعاً غير المُتحقَّق منه.
 * رمز خروج العملية = رمز خروج الأمر. غياب أمر بعد `--` مع `--exec` ⇒ رفض.
 */
import { spawnSync } from 'node:child_process';
const PROD_REF = 'mwbjoysuybgbrvfrprex';   // مرجع مشروع الإنتاج — ممنوع منعاً باتّاً

function arg(name) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
function refOf(s) {
  if (!s) return null;
  // (Codex round-3) تحليل قانونيّ: مرجع من hostname القانوني حصراً (لا regex بادئة يُخدَع بـ user@host).
  // إن كان الوسيط عنواناً، حلِّله؛ وإلّا عامله كمرجع مجرّد (لكن ارفض ما يحوي '@' أو '/' أو ':').
  const raw = String(s).trim();
  if (/^https?:\/\//i.test(raw)) {
    let u;
    try { u = new URL(raw); } catch (_) { return null; }
    if (u.protocol !== 'https:') return null;
    if (u.username || u.password) return null;
    if (u.port && u.port !== '443') return null;
    const m = /^([a-z0-9]{20})\.supabase\.co$/i.exec(u.hostname.toLowerCase());
    return m ? m[1] : null;
  }
  // مرجع مجرّد: 20 محرفاً بلا فواصل مسار/مضيف — أي شيء آخر يُرفض (لا يُقارَن نصّاً خام).
  const bare = raw.toLowerCase();
  return /^[a-z0-9]{20}$/.test(bare) ? bare : null;
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

// (البند 3 + G1-01) وضع الاقتران: يربط الأمر بالهدف المُتحقَّق منه فعليّاً — لا حقن بيئة فقط.
const execIdx = process.argv.indexOf('--exec');
if (execIdx >= 0) {
  const sep = process.argv.indexOf('--', execIdx);
  let cmd = sep >= 0 ? process.argv.slice(sep + 1) : [];
  if (cmd.length === 0) die('«--exec» بلا أمر بعد «--» — لا شيء لتشغيله (fail-closed).');

  // (1) استبدال العلامة {GUARDED_REF} بالمرجع المُتحقَّق منه — الطريقة الآمنة لتمرير الهدف.
  cmd = cmd.map(tok => tok.split('{GUARDED_REF}').join(ref));

  // (2) استخلاص أي مرجع مشروع صريح داخل الأمر ورفض ما لا يطابق الهدف المُتحقَّق منه.
  //     يمنع: `--project-ref <prod>` و `https://<prod>.supabase.co` و مرجعاً مجرّداً مغايراً.
  const TARGET_FLAGS = new Set(['--project-ref', '--ref', '--url', '--db-url', '--database', '--project', '-p']);
  function refIn(token) {
    // عنوان supabase → مرجعه؛ أو مرجع مجرّد 20 محرفاً؛ وإلّا null.
    const t = String(token);
    const um = /https?:\/\/([a-z0-9]{20})\.supabase\.co/i.exec(t);
    if (um) return um[1].toLowerCase();
    if (/^[a-z0-9]{20}$/i.test(t)) return t.toLowerCase();
    return null;
  }
  const offenders = [];
  for (let i = 0; i < cmd.length; i++) {
    const tok = cmd[i];
    // شكل --flag=value
    const eq = /^(--[a-z-]+|-p)=(.+)$/i.exec(tok);
    if (eq && TARGET_FLAGS.has(eq[1].toLowerCase())) {
      const r = refIn(eq[2]); if (r && r !== ref) offenders.push(`${eq[1]}=${eq[2]}`);
      continue;
    }
    // شكل --flag value
    if (TARGET_FLAGS.has(tok.toLowerCase())) {
      const val = cmd[i + 1]; const r = val != null ? refIn(val) : null;
      if (r && r !== ref) offenders.push(`${tok} ${val}`);
      continue;
    }
    // أي رمز يحمل مرجعاً صريحاً (عنوان supabase أو مرجع مجرّد) مغايراً للهدف
    const r = refIn(tok);
    if (r && r !== ref) offenders.push(tok);
  }
  if (offenders.length) {
    die(`الأمر يستهدف مرجعاً غير المُتحقَّق منه (${ref}) — مرفوض قبل التشغيل: ${offenders.join(' | ')}. ` +
        `استخدم العلامة {GUARDED_REF} بدل تمرير مرجع صريح.`);
  }

  const childEnv = { ...process.env, GUARDED_REF: ref, STAGING_PROJECT_REF: ref };
  if (/^https?:\/\//i.test(String(arg('url') || ''))) childEnv.E2E_SUPABASE_URL = arg('url');
  console.log(`▶ env-guard --exec: ${cmd.join(' ')}  (GUARDED_REF=${ref})`);
  const r = spawnSync(cmd[0], cmd.slice(1), { stdio: 'inherit', env: childEnv });
  if (r.error) die(`تعذّر تشغيل الأمر: ${r.error.message}`);
  process.exit(typeof r.status === 'number' ? r.status : 1);
}
process.exit(0);

#!/usr/bin/env node
/**
 * build-baseline.mjs — يولّد قطعة الأساس staging «baseline_through_061.sql» حتميّاً من portal-standalone.sql
 * (F1). قطعة الأساس = كامل المخطّط النظيف حتى الهجرة 061، أي standalone قبل قسم «دمج الهجرة 062» (القسم
 * الأخير في الملف). لا اختراع طوابع زمنية لهجرات الإنتاج؛ لينيَج staging منفصل تماماً.
 *
 * الاستخدام: node scripts/deploy/build-baseline.mjs [--check]
 *   بلا وسيط: يكتب db/staging-bootstrap/baseline_through_061.sql.
 *   --check : يتحقّق أنّ الملف المكتوب مطابق للمولَّد (CI drift guard) + يطبع بصمته.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const STANDALONE = 'db/portal-standalone.sql';
const OUT = 'db/staging-bootstrap/baseline_through_061.sql';
const MARKER = 'دمج الهجرة 062';   // عنوان قسم 062 المدمج (القسم الأخير في standalone)

const text = readFileSync(STANDALONE, 'utf8');
const mi = text.indexOf(MARKER);
if (mi < 0) { console.error('❌ build-baseline: تعذّر إيجاد قسم «دمج الهجرة 062» في standalone.'); process.exit(2); }
// قصّ عند سطر الفاصل «-- ═…» الذي يسبق العنوان مباشرةً.
const sepOff = text.lastIndexOf('\n-- ═', mi);
if (sepOff < 0) { console.error('❌ build-baseline: تعذّر إيجاد فاصل القسم قبل 062.'); process.exit(2); }
// نُبقي المحتوى حتى الفاصل، مُطبَّعاً لينتهي بسطر جديد واحد، ثم نُلحق ختم الأساس.
const body = text.slice(0, sepOff).replace(/\s*$/, '') + '\n';
const baseline = body
  + '\n-- ═══════════════════════════════════════════════════════════════════════════\n'
  + '-- END baseline_through_061 — المخطّط الكامل حتى الهجرة 061 (بلا 062).\n'
  + '-- الهجرة 062 (db/portal-migrations/062-request-documents.sql) تُطبَّق منفصلةً عبر supabase-push.mjs.\n'
  + '-- إثبات القاعدة: db/staging-bootstrap/verify-baseline.sh (قاعدة فارغة → أساس → 062 → الحزمة).\n'
  + '-- ═══════════════════════════════════════════════════════════════════════════\n';

const sha = createHash('sha256').update(baseline).digest('hex');
if (process.argv.includes('--check')) {
  let cur; try { cur = readFileSync(OUT, 'utf8'); } catch (_) { console.error(`❌ ${OUT} غير موجود — ولّده.`); process.exit(1); }
  if (cur !== baseline) { console.error(`❌ ${OUT} غير محدَّث — أعِد التوليد: node scripts/deploy/build-baseline.mjs`); process.exit(1); }
  console.log(`✅ baseline_through_061.sql مطابق للمولَّد الحتميّ. sha256=${sha}`);
} else {
  writeFileSync(OUT, baseline);
  console.log(`✅ كُتب ${OUT} (${baseline.split('\n').length} سطر). sha256=${sha}`);
}

#!/usr/bin/env node
/**
 * build-migration-manifest.mjs — يولّد بيان الهجرات القانونيّ (G1-R6-01/02).
 * ════════════════════════════════════════════════════════════════════════════
 * يعالج عيبين أشار إليهما المالك:
 *  • (R6-01) دفع 062 وحدها في دليل عمل يفتقد التاريخ الكامل يُنتج عدم تطابق تاريخ لا مجموعة {062} نظيفة.
 *    الحلّ: بيان يغطّي **كامل تاريخ الهجرات** (001…062) بأرقام إصدار Supabase قانونيّة + بصمات، فيُبنى
 *    منه دليل عمل متّسق يطابق تاريخ staging المُهيّأ من البيان نفسه ⇒ 062 وحدها معلّقة.
 *  • (R6-02) 062 كان يحمل إصداراً (20260728000000) **أقدم** من 059/060/061 المُطبَّقة فعلاً. الحلّ:
 *    059/060/061 مثبَّتة على قيمها الحيّة المُتحقَّقة، و062 إصداره **بعدها تماماً**.
 *
 * أرقام الإصدار: 059/060/061/062 مثبَّتة (المُتحقَّقة حيّاً + 062 بعد 061)؛ الباقي (قبل 059) يُخصَّص
 * تسلسليّاً canonically قبل 059 (staging greenfield يُهيّأ من هذا البيان — البيان هو مصدر الحقيقة).
 * البيان قابل لإعادة التوليد بالكامل وحتميّ. RUN-ALL* مُستبعَد (ملفّ تجميعيّ، ليس هجرة مرتَّبة).
 *
 * الاستخدام: `node scripts/deploy/build-migration-manifest.mjs [--check]`
 *   بلا وسيط: يكتب db/portal-migrations/manifest.json.  --check: يتحقّق أنّ المكتوب مطابق (CI).
 */
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const DIR = 'db/portal-migrations';
const OUT = join(DIR, 'manifest.json');
// إصدارات حيّة مُتحقَّقة (ledger MIGRATION_HISTORY) + 062 مُخصَّص بعد 061 تماماً.
const PINNED = { '059': '20260728093548', '060': '20260728170320', '061': '20260729073619', '062': '20260730120000' };

function sha256(p) { return createHash('sha256').update(readFileSync(p)).digest('hex'); }
// مفتاح فرز طبيعيّ: البادئة الرقمية ثم لاحقة الحرف (055 قبل 055b قبل 056).
function sortKey(name) {
  const m = /^(\d+)([a-z]?)-/.exec(name);
  return m ? [parseInt(m[1], 10), m[2] || ''] : [1e9, name];
}
function seqOf(name) { const m = /^(\d+[a-z]?)-/.exec(name); return m ? m[1] : name; }
function slug(name) { return name.replace(/^\d+[a-z]?-/, '').replace(/\.sql$/, '').replace(/-/g, '_'); }

const files = readdirSync(DIR)
  .filter(f => f.endsWith('.sql') && !f.startsWith('RUN-ALL'))
  .sort((a, b) => { const ka = sortKey(a), kb = sortKey(b); return ka[0] - kb[0] || (ka[1] < kb[1] ? -1 : ka[1] > kb[1] ? 1 : 0); });

// إصدارات canonical للهجرات قبل 059: تبدأ 2026-01-01 وتزيد ساعةً لكلّ واحدة (كلّها < 20260728…).
let hourIdx = 0;
function derivedVersion() {
  const d = new Date(Date.UTC(2026, 0, 1, 0, 0, 0) + hourIdx * 3600 * 1000); hourIdx++;
  const p = n => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`;
}

const migrations = files.map(file => {
  const seq = seqOf(file);
  const version = PINNED[seq] || derivedVersion();
  return { seq, file, version, dest: `${version}_${seq}_${slug(file)}.sql`, sha256: sha256(join(DIR, file)) };
});

// ثوابت السلامة: تفرّد + تزايد صارم + 062 بعد 061.
const versions = migrations.map(m => m.version);
if (new Set(versions).size !== versions.length) { console.error('❌ إصدارات مكرّرة في البيان.'); process.exit(2); }
for (let i = 1; i < versions.length; i++) if (versions[i] <= versions[i - 1]) { console.error(`❌ ترتيب غير تصاعدي عند ${migrations[i].file} (${versions[i]} ≤ ${versions[i - 1]}).`); process.exit(2); }
const v061 = migrations.find(m => m.seq === '061').version, v062 = migrations.find(m => m.seq === '062').version;
if (!(v062 > v061)) { console.error('❌ إصدار 062 ليس بعد 061.'); process.exit(2); }

const manifest = {
  note: 'Canonical Supabase migration history for System-3 staging bootstrap (G1-R6-01/02). 059/060/061 = verified live versions; 062 strictly after 061; earlier = deterministic canonical (staging greenfield is provisioned from this manifest). RUN-ALL* excluded. Regenerate: node scripts/deploy/build-migration-manifest.mjs',
  count: migrations.length,
  head_migration: migrations[migrations.length - 1].seq,
  migrations,
};
const json = JSON.stringify(manifest, null, 2) + '\n';

if (process.argv.includes('--check')) {
  const cur = readFileSync(OUT, 'utf8');
  if (cur !== json) { console.error('❌ manifest.json غير محدَّث — أعِد التوليد: node scripts/deploy/build-migration-manifest.mjs'); process.exit(1); }
  console.log(`✅ manifest.json مطابق (${migrations.length} هجرة؛ 062=${v062} بعد 061=${v061}).`);
} else {
  writeFileSync(OUT, json);
  console.log(`✅ كُتب ${OUT}: ${migrations.length} هجرة، الرأس ${manifest.head_migration}=${v062} (بعد 061=${v061}).`);
}

/**
 * mig-parse.mjs — تحليل حتميّ لمخرجات `supabase db push --dry-run --linked` (G1-R5-02).
 * الغرض: فرض «الهجرة 062 وحدها معلّقة، لا شيء غيرها». نُصدِّر دوالاً نقيّة قابلة للاختبار (لا آثار جانبية).
 *
 * صيغ المخرجات المدعومة (كلاهما شائع عبر إصدارات CLI):
 *   • أسماء ملفات:  `20260728000000_062_request_documents.sql`
 *   • نسخ مجرّدة في قائمة:  سطر يحوي `20260728000000` وحده.
 * أي رمز 14-رقماً يُعامَل كنسخة هجرة. «Remote database is up to date» ⇒ صفر ⇒ يفشل مغلقاً.
 */
// (G1-R6-02) الإصدار القانونيّ لـ062 = بعد 061 المُتحقَّق حيّاً (20260729073619) تماماً. مصدر الحقيقة
// manifest.json (المُولَّد من build-migration-manifest.mjs)؛ اختبار البيان يؤكّد التطابق.
export const MIG_VERSION = '20260730120000';
export const MIG_DEST_NAME = `${MIG_VERSION}_062_request_documents.sql`;

/** يستخرج مجموعة نسخ الهجرات المعلّقة (14 رقماً) من مخرجات dry-run — فريدة ومرتَّبة. */
export function parsePendingVersions(stdout) {
  const s = String(stdout || '');
  const set = new Set();
  // (أ) أسماء ملفات migrations: <14 رقماً>_...sql
  for (const m of s.matchAll(/(\d{14})_[^\s/\\]*\.sql/g)) set.add(m[1]);
  // (ب) نسخ مجرّدة على سطر مستقلّ داخل قائمة
  for (const m of s.matchAll(/^\s*(\d{14})\s*$/gm)) set.add(m[1]);
  return [...set].sort();
}

/**
 * يؤكّد أنّ المجموعة المعلّقة == {062} بالضبط. يرمي (fail-closed) عند صفر/مكرّر-مختلف/أيّ زائدة.
 * يعيد المجموعة عند النجاح.
 */
export function assertExactly062(stdout) {
  const pending = parsePendingVersions(stdout);
  if (pending.length === 0) throw new Error('dry-run لم يكتشف أيّ هجرة معلّقة — متوقَّع 062 وحدها (fail-closed).');
  if (pending.length > 1) throw new Error(`dry-run كشف هجرات إضافية غير متوقَّعة: [${pending.join(', ')}] — متوقَّع 062 (${MIG_VERSION}) وحدها (fail-closed).`);
  if (pending[0] !== MIG_VERSION) throw new Error(`الهجرة المعلّقة (${pending[0]}) ليست 062 المثبَّتة (${MIG_VERSION}) — إيقاف (fail-closed).`);
  return pending;
}

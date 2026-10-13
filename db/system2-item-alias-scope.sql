-- ════════════════════════════════════════════════════════════════════════
-- النظام 2 — نطاق المورد في مرادفات الأصناف (proc_item_aliases)
-- ════════════════════════════════════════════════════════════════════════
-- تُطبَّق على المشروع القديم `yofcaxvstjcrmbgciwym` (النظام 1+2).
-- ⚠️ لا علاقة لها بالبوابة (النظام 3) ولا بأي جدول portal_*.
--
-- لماذا:
--   توجيه المالك: «مهما اختلفت بعض المسميات من مورد لمورد … لا يكررها ولا
--   يربطها في بند خاطئ». وكان جدول المرادفات يحمل مفتاحاً **عامّاً واحداً**
--   (`normalized_alias` فريد وحده)، فله ثلاث نتائج مقيسة بالكود:
--     (أ) نفس التسمية العامية عند موردين مختلفين قد تعني منتجين مختلفين،
--         ولا سبيل للتمييز — فربطٌ صحيح لمورد يصير ربطاً خاطئاً لمورد آخر.
--     (ب) حفظ مرادف قائم لصنف آخر كان ينفّذ `update(item_code)` فيُعيد توجيه
--         ربطٍ اعتمده بشريٌّ سابقاً **بصمت**، ثم تُدمَج كل العروض التالية بذلك
--         الاسم في الصنف الجديد بثقة 0.99.
--     (ج) لا أثر لمصدر الربط (تأكيد بشريّ · اختيار يدويّ · حكم ذكاء) فلا
--         يمكن تمييز الدليل القويّ من الضعيف.
--
-- ما تفعله:
--   · عمود `supplier_key` (نطاق المورد؛ '' = مرادف عامّ) + مفتاح فريد مركّب.
--   · عمود `source` (مصدر التعلُّم) و`conflict_count`/`last_conflict` (أثر التعارض).
--   · فهرس على المفتاح المركّب.
-- إضافيّة بحتة: الصفوف القائمة كلّها تصير مرادفات عامّة ('') كما كانت تعمل،
-- فلا يفقد المستخدم ربطاً اعتمده. والكود **متسامح**: يعمل قبل الهجرة وبعدها
-- (يجرّب الأعمدة الجديدة ويسقط للقديمة عند 400).
--
-- idempotent — يمكن إعادة تشغيلها. وفي نهايتها كتلة تراجع معلَّقة.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE proc_item_aliases ADD COLUMN IF NOT EXISTS supplier_key   TEXT NOT NULL DEFAULT '';
ALTER TABLE proc_item_aliases ADD COLUMN IF NOT EXISTS source         TEXT;
ALTER TABLE proc_item_aliases ADD COLUMN IF NOT EXISTS conflict_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE proc_item_aliases ADD COLUMN IF NOT EXISTS last_conflict  JSONB;

-- المفتاح الفريد القديم كان على العمود وحده؛ يُستبدَل بالمركّب.
-- (اسم القيد الافتراضي الذي تولّده Postgres لـUNIQUE في CREATE TABLE.)
DO $$
DECLARE c TEXT;
BEGIN
  FOR c IN
    SELECT con.conname
      FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
     WHERE rel.relname = 'proc_item_aliases'
       AND con.contype = 'u'
       AND (SELECT count(*) FROM unnest(con.conkey)) = 1
       AND EXISTS (
             SELECT 1 FROM pg_attribute a
              WHERE a.attrelid = rel.oid
                AND a.attnum = con.conkey[1]
                AND a.attname = 'normalized_alias')
  LOOP
    EXECUTE format('ALTER TABLE proc_item_aliases DROP CONSTRAINT %I', c);
  END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_aliases_norm_supplier
  ON proc_item_aliases(normalized_alias, supplier_key);
CREATE INDEX IF NOT EXISTS idx_aliases_supplier
  ON proc_item_aliases(supplier_key);

COMMENT ON COLUMN proc_item_aliases.supplier_key IS
  'نطاق المورد للمرادف (اسم المورد مطبَّعاً). '''' = مرادف عامّ يسري على كل الموردين.';
COMMENT ON COLUMN proc_item_aliases.source IS
  'مصدر التعلُّم: confirm (تأكيد بشريّ في الاستيراد) · manual (اختيار يدويّ في الإدخال) · ai.';

COMMIT;

-- ── تحقّق (للتشغيل اليدويّ بعد التطبيق) ───────────────────────────────
-- SELECT column_name FROM information_schema.columns
--  WHERE table_name='proc_item_aliases' AND column_name IN ('supplier_key','source','conflict_count','last_conflict');
-- SELECT indexname FROM pg_indexes WHERE tablename='proc_item_aliases';
-- SELECT supplier_key, count(*) FROM proc_item_aliases GROUP BY 1 ORDER BY 2 DESC;

-- ── تراجع (rollback) — لا تُشغَّل إلا عند الحاجة ──────────────────────
-- BEGIN;
--   DROP INDEX IF EXISTS uq_aliases_norm_supplier;
--   DROP INDEX IF EXISTS idx_aliases_supplier;
--   -- ⚠️ إعادة المفتاح الفريد القديم تفشل إن وُجد مرادف واحد بنطاقين مختلفين؛
--   --    احذف نطاقات الموردين أوّلاً إن أردت العودة الكاملة:
--   --    DELETE FROM proc_item_aliases WHERE supplier_key <> '';
--   ALTER TABLE proc_item_aliases ADD CONSTRAINT proc_item_aliases_normalized_alias_key UNIQUE (normalized_alias);
--   ALTER TABLE proc_item_aliases DROP COLUMN IF EXISTS supplier_key;
--   ALTER TABLE proc_item_aliases DROP COLUMN IF EXISTS source;
--   ALTER TABLE proc_item_aliases DROP COLUMN IF EXISTS conflict_count;
--   ALTER TABLE proc_item_aliases DROP COLUMN IF EXISTS last_conflict;
-- COMMIT;

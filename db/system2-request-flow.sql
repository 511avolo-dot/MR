-- ════════════════════════════════════════════════════════════════════════════
--  دورة طلبات الشراء للموظّف الميدانيّ — قوالب متكررة · استفهام · متابعة محكومة
-- ----------------------------------------------------------------------------
--  الفجوات التي تسدّها (مقيسة على الكود والقاعدة الحيّة):
--   ① الطلبات الشهرية المتكررة كانت تُكتب من الصفر في كل مرّة — لا قوالب.
--   ② لا قناة **استفهام**: كان أمام المشتريات خياران فقط، إرجاع الطلب كلّه
--      (يُصفّر سلسلة الاعتماد) أو الاتصال خارج النظام فتضيع المعلومة.
--   ③ مراحل المشتريات (`proc_status`) كانت تُكتب بـUPDATE مباشر من العميل —
--      بلا حارس صلاحية ولا فصل مهام، وموظّف مُنطَّق لا يستطيعها أصلاً.
--   ④ عمر الطلب في مرحلته لم يكن محسوباً في القاعدة.
--
--  إضافيّ بالكامل وidempotent. كتلة التراجع في نهاية الملف.
--  ⚠️ يفترض `db/system2-staff-scope.sql` مُطبَّقة (يستعمل proc_me/proc_is_scoped).
-- ════════════════════════════════════════════════════════════════════════════

-- ═══════════════ 1) قوالب الطلبات المتكررة ═══════════════
-- «الطلب الشهريّ للمشروع» يُحفظ مرّة بمسمّياته وكمّياته ويُستدعى بضغطة.
CREATE TABLE IF NOT EXISTS proc_pr_templates (
  id            TEXT PRIMARY KEY,               -- TPL-XXXXXX
  name          TEXT NOT NULL,                  -- «مستلزمات برج الشمال الشهرية»
  owner         TEXT NOT NULL,                  -- منشئه (username)
  title         TEXT,                           -- نوع/فئة المواد (يملأ حقل الطلب)
  department_id TEXT,
  sector        TEXT,                           -- يحكم من يراه (نطاق القطاع)
  project       TEXT,
  priority      TEXT DEFAULT 'متوسط',
  justification TEXT,
  items         JSONB NOT NULL DEFAULT '[]'::jsonb,  -- [{description,unit,requested_qty,...}]
  active        BOOLEAN DEFAULT true,
  use_count     INT DEFAULT 0,
  last_used_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_prtpl_owner  ON proc_pr_templates(owner);
CREATE INDEX IF NOT EXISTS idx_prtpl_sector ON proc_pr_templates(sector);

-- ═══════════════ 2) محادثة الطلب (استفهام ↔ جواب) ═══════════════
-- ملاحظة/سؤال على الطلب **بلا تغيير حالته**: المشتريات تستفهم، والطالب يجيب،
-- والحوار كلّه محفوظ على الطلب فلا تضيع المعلومة في مكالمة أو واتساب.
CREATE TABLE IF NOT EXISTS proc_pr_messages (
  id          BIGSERIAL PRIMARY KEY,
  pr_id       TEXT NOT NULL REFERENCES proc_purchase_requests(id) ON DELETE CASCADE,
  author      TEXT NOT NULL,
  author_name TEXT,
  kind        TEXT NOT NULL DEFAULT 'message',  -- question | answer | message
  body        TEXT NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_prmsg_pr ON proc_pr_messages(pr_id, created_at);

-- ═══════════════ 3) سياسات RLS ═══════════════
-- القوالب: يراها صاحبها وزملاء قطاعه (فالقالب الشهريّ للمشروع يخدم الفريق)،
-- ولا يكتبها إلا صاحبها. غير المُنطَّق (المشتريات/الإدارة) يرى الكل.
ALTER TABLE proc_pr_templates ENABLE ROW LEVEL SECURITY;
SELECT proc_drop_all_policies('proc_pr_templates');
CREATE POLICY "tpl_select" ON proc_pr_templates FOR SELECT TO authenticated
  USING (NOT proc_is_scoped()
         OR lower(owner) = lower(proc_me())
         OR sector = ANY(proc_scope_sectors()));
CREATE POLICY "tpl_insert" ON proc_pr_templates FOR INSERT TO authenticated
  WITH CHECK (lower(owner) = lower(proc_me()) OR NOT proc_is_scoped());
CREATE POLICY "tpl_update" ON proc_pr_templates FOR UPDATE TO authenticated
  USING (lower(owner) = lower(proc_me()) OR NOT proc_is_scoped())
  WITH CHECK (lower(owner) = lower(proc_me()) OR NOT proc_is_scoped());
CREATE POLICY "tpl_delete" ON proc_pr_templates FOR DELETE TO authenticated
  USING (lower(owner) = lower(proc_me()) OR NOT proc_is_scoped());

-- المحادثة: تُقرأ بمن يرى الطلب، وتُكتب **حصراً** عبر RPC (لا انتحال مؤلِّف).
ALTER TABLE proc_pr_messages ENABLE ROW LEVEL SECURITY;
SELECT proc_drop_all_policies('proc_pr_messages');
CREATE POLICY "prmsg_select" ON proc_pr_messages FOR SELECT TO authenticated
  USING (proc_can_see_pr(pr_id));
-- لا سياسة INSERT/UPDATE/DELETE: الكتابة عبر pr_post_message وحدها.

-- ═══════════════ 3b) صلاحيات الجداول (لا تُترك للافتراضيّ) ═══════════════
-- ⚠️ لولا هذه المنح لسقط الجدولان على «الامتيازات الافتراضية» للمشروع — وهي
-- إعداد بيئة لا عقد. والمنح مقصودة الشكل: **المحادثة تُقرأ ولا تُكتب مباشرةً**
-- (لا INSERT/UPDATE/DELETE إطلاقاً) فتُضاف طبقة امتياز فوق غياب السياسة،
-- والكتابة عبر `pr_post_message` وحدها. القوالب بيانات المستخدم فيكتبها بنفسه.
-- ⚠️ **السحب صريح لا مُفترَض:** Supabase تضبط امتيازات افتراضية على `public`
-- تمنح `ALL` لـanon/authenticated على **أي جدول جديد**، فـ`GRANT SELECT` وحده
-- لا يسحب INSERT/UPDATE/DELETE — يبقيان ممنوحَين ويسقط قفل الامتياز صامتاً.
-- (مُقاس على الإنتاج: `has_table_privilege('authenticated', 'proc_pr_messages',
--  'INSERT')` = true بعد GRANT SELECT وحده.)
GRANT  SELECT, INSERT, UPDATE, DELETE ON proc_pr_templates TO authenticated;
REVOKE ALL                            ON proc_pr_messages  FROM authenticated;
GRANT  SELECT                         ON proc_pr_messages  TO   authenticated;
REVOKE ALL ON proc_pr_templates FROM anon;
REVOKE ALL ON proc_pr_messages  FROM anon;

-- ═══════════════ 4) دوال الكتابة المحكومة ═══════════════

-- سؤال/جواب على الطلب. لا تُغيّر الحالة ولا تمسّ سلسلة الاعتماد.
CREATE OR REPLACE FUNCTION pr_post_message(p_pr_id text, p_body text, p_kind text DEFAULT 'message')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_name text; v_txt text := btrim(coalesce(p_body,''));
  v_kind text := lower(coalesce(p_kind,'message')); v_id bigint;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF v_txt = '' THEN RAISE EXCEPTION 'الرسالة فارغة'; END IF;
  IF length(v_txt) > 4000 THEN RAISE EXCEPTION 'الرسالة طويلة جداً (4000 حرف كحدّ أقصى)'; END IF;
  IF v_kind NOT IN ('question','answer','message') THEN v_kind := 'message'; END IF;
  IF NOT EXISTS (SELECT 1 FROM proc_purchase_requests WHERE id = p_pr_id) THEN
    RAISE EXCEPTION 'الطلب غير موجود';
  END IF;
  IF NOT proc_can_see_pr(p_pr_id) THEN RAISE EXCEPTION 'هذا الطلب خارج نطاقك'; END IF;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  INSERT INTO proc_pr_messages (pr_id, author, author_name, kind, body)
  VALUES (p_pr_id, v_me, coalesce(v_name, v_me), v_kind, v_txt)
  RETURNING id INTO v_id;

  INSERT INTO proc_audit_log (username, display_name, action, entity_type, entity_id, new_value)
  VALUES (v_me, coalesce(v_name,v_me), 'pr_'||v_kind, 'pr', p_pr_id,
          jsonb_build_object('body', left(v_txt,300)));

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'kind', v_kind,
                            'by', coalesce(v_name,v_me), 'at', now());
END $fn$;

-- انتقال مرحلة المشتريات. كان UPDATE مباشراً من العميل بلا أي حارس.
--   (فارغ/received) → in_progress → quotes_collected → completed
CREATE OR REPLACE FUNCTION pr_proc_stage(p_pr_id text, p_stage text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_name text; v_pr proc_purchase_requests%ROWTYPE;
  v_cur text; v_at timestamptz := now();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF p_stage NOT IN ('in_progress','quotes_collected','completed') THEN
    RAISE EXCEPTION 'مرحلة غير صالحة';
  END IF;
  -- معالجة المشتريات صلاحية مشتريات (أو أدمن) — لا يفعلها الطالب.
  IF NOT (pr_has_perm('can_manage_rfq') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'معالجة الطلب تتطلّب صلاحية المشتريات';
  END IF;

  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id = p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_pr.status <> 'approved' THEN
    RAISE EXCEPTION 'لم يُعتمد الطلب بعد — لا معالجة قبل اكتمال سلسلة الاعتماد';
  END IF;

  v_cur := coalesce(nullif(v_pr.proc_status,''), 'received');
  -- تقدّم للأمام فقط (لا يُعاد الطلب لمرحلة سابقة فيُمحى أثر من عمل عليه)
  IF (v_cur = 'received'          AND p_stage <> 'in_progress')
  OR (v_cur = 'in_progress'       AND p_stage NOT IN ('quotes_collected','completed'))
  OR (v_cur = 'quotes_collected'  AND p_stage <> 'completed')
  OR (v_cur = 'completed') THEN
    RAISE EXCEPTION 'انتقال غير مسموح: % ← %', v_cur, p_stage;
  END IF;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  v_name := coalesce(v_name, v_me);

  UPDATE proc_purchase_requests SET
    proc_status         = p_stage,
    proc_started_by     = CASE WHEN p_stage='in_progress'      THEN v_me ELSE proc_started_by END,
    proc_started_at     = CASE WHEN p_stage='in_progress'      THEN v_at ELSE proc_started_at END,
    quotes_collected_by = CASE WHEN p_stage='quotes_collected' THEN v_me ELSE quotes_collected_by END,
    quotes_collected_at = CASE WHEN p_stage='quotes_collected' THEN v_at ELSE quotes_collected_at END,
    updated_by = v_me, updated_at = v_at
  WHERE id = p_pr_id;

  RETURN jsonb_build_object('ok', true, 'stage', p_stage, 'by', v_name, 'at', v_at);
END $fn$;

REVOKE ALL ON FUNCTION pr_post_message(text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_proc_stage(text, text)         FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_post_message(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION pr_proc_stage(text, text)         TO authenticated;

-- ═══════════════ التراجع (للطوارئ) ═══════════════
/*
DROP FUNCTION IF EXISTS pr_post_message(text, text, text);
DROP FUNCTION IF EXISTS pr_proc_stage(text, text);
DROP TABLE IF EXISTS proc_pr_messages;
DROP TABLE IF EXISTS proc_pr_templates;
*/

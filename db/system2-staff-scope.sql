-- ════════════════════════════════════════════════════════════════════════════
--  نطاق موظفي الصيانة والتشغيل — النظام 2 (المشروع القديم yofcaxvstjcrmbgciwym)
-- ----------------------------------------------------------------------------
--  لماذا: لم يكن في النظام **أي** نطاق رؤية. RLS على كل جدول `proc_*` هو
--  `auth_all FOR ALL TO authenticated USING(true)` — أي أن كل مستخدم مسجَّل
--  يقرأ كل صفّ: كل أوامر الشراء بمبالغها، وكل صفوف `proc_users` بهاشات كلمات
--  السرّ. فحسابٌ لموظف صيانة «يتابع ما يخصّه فقط» يستحيل بناؤه في المتصفّح
--  وحده — التصفية في الواجهة تجميليّة، والحدّ الحقيقيّ يجب أن يكون هنا.
--
--  المحور (قرار المالك): **القطاع** `proc_purchase_orders.sector`.
--  قِيس على الإنتاج: 115 أمراً · الصيانة والتشغيل 73 · الإدارة العامة 21 ·
--  الإنشاءات 16 · النقليات 4 · بلا قطاع 1.
--
--  ⚠️ عدم الانحدار هو القيد الأول: `scope_sectors` فارغ = **غير مُنطَّق** =
--  سلوك اليوم حرفيّاً. المستخدمون الأربعة القائمون لا يتغيّر لهم شيء.
--
--  إضافيّ وidempotent وقابل لإعادة التشغيل. كتلة التراجع في نهاية الملف.
--  يُشغَّل في Supabase → SQL Editor **بعد** نشر واجهة `index.html` الواعية به.
-- ════════════════════════════════════════════════════════════════════════════

-- ═══════════════ 1) الأعمدة الجديدة ═══════════════

-- نطاق الموظف: مصفوفة أسماء قطاعات. NULL أو [] = وصول كامل (السلوك القائم).
ALTER TABLE proc_users
  ADD COLUMN IF NOT EXISTS scope_sectors JSONB DEFAULT NULL;
COMMENT ON COLUMN proc_users.scope_sectors IS
  'قطاعات أوامر الشراء التي يراها المستخدم. NULL/[] = غير مُنطَّق (وصول كامل كما كان).';

-- تعليقات المتابعة الميدانية على أمر الشراء — نفس سابقة `receipts`
-- في db/goods-receipt.sql: عمود jsonb على الأمر، بلا جدول جديد.
ALTER TABLE proc_purchase_orders
  ADD COLUMN IF NOT EXISTS comments JSONB;
COMMENT ON COLUMN proc_purchase_orders.comments IS
  'ملاحظات متابعة: [{by, username, at, text}] — تُكتب حصراً عبر po_add_comment().';


-- ═══════════════ 2) المساعدات (كلها STABLE SECURITY DEFINER) ═══════════════

-- هوية المتصل. تبني على pr_username() القائمة (db/pr-portal.sql:233) لكنها
-- ⚠️ تجرّب مطابقة عمود `email` أولاً: pr_username() تشتقّ اسم المستخدم من
-- البريد (`split_part(email,'@',1)` + ثلاثة استثناءات)، فصفٌّ أُنشئ يدويّاً
-- ببريد لا يطابق اسم المستخدم كان سيعيد NULL ⇒ يُحجب صاحبه عن كل شيء.
CREATE OR REPLACE FUNCTION proc_me() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce(
    (SELECT u.username FROM proc_users u
      WHERE coalesce(u.active, true)
        AND nullif(lower(coalesce(auth.jwt() ->> 'email','')),'') = lower(u.email)
      LIMIT 1),
    pr_username());
$fn$;

-- قطاعات المتصل، أو NULL إن كان غير مُنطَّق / غير معروف.
CREATE OR REPLACE FUNCTION proc_scope_sectors() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT CASE WHEN jsonb_typeof(u.scope_sectors) = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(u.scope_sectors))
         END
    FROM proc_users u
   WHERE lower(u.username) = lower(proc_me())
   LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION proc_is_scoped() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce(array_length(proc_scope_sectors(), 1), 0) > 0;
$fn$;

-- بوّابة صفّ أمر الشراء. **تفشل مغلقةً**: متصل لا نعرف هويّته في proc_users
-- (حساب Auth بلا صفّ، أو موقوف) لا يرى شيئاً — وهو تشديد على سلوك اليوم.
CREATE OR REPLACE FUNCTION proc_can_see_po(p_sector text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT CASE
           WHEN proc_me() IS NULL   THEN false
           WHEN NOT proc_is_scoped() THEN true
           ELSE p_sector = ANY(proc_scope_sectors())
         END;
$fn$;

-- رؤية المبالغ. ⚠️ الافتراضيّ **true** حين يغيب المفتاح — مطابقةً لدلالة
-- `hasPermission` في الواجهة (`userDefault:true`)، وإلا فقد المستخدمون
-- الأربعة القائمون (وصفوفهم بلا هذا المفتاح) مبالغهم فجأة.
-- ولهذا لا تُستعمل هنا `pr_has_perm` القائمة: افتراضيّها `false`.
CREATE OR REPLACE FUNCTION proc_can_view_amounts() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS(
    SELECT 1 FROM proc_users u
     WHERE lower(u.username) = lower(proc_me())
       AND coalesce(u.active, true)
       AND (u.role = 'admin'
            OR coalesce((u.permissions ->> 'can_view_amounts')::boolean, true)));
$fn$;

-- رؤية طلب شراء (لتقييد الجداول الفرعية بلا تكرار RLS الأب).
CREATE OR REPLACE FUNCTION proc_can_see_pr(p_pr_id text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT CASE
           WHEN proc_me() IS NULL    THEN false
           WHEN NOT proc_is_scoped() THEN true
           ELSE EXISTS(SELECT 1 FROM proc_purchase_requests p
                        WHERE p.id = p_pr_id
                          AND (lower(coalesce(p.requester,'')) = lower(proc_me())
                               OR p.sector = ANY(proc_scope_sectors())))
         END;
$fn$;

GRANT EXECUTE ON FUNCTION proc_me()                     TO authenticated;
GRANT EXECUTE ON FUNCTION proc_scope_sectors()          TO authenticated;
GRANT EXECUTE ON FUNCTION proc_is_scoped()              TO authenticated;
GRANT EXECUTE ON FUNCTION proc_can_see_po(text)         TO authenticated;
GRANT EXECUTE ON FUNCTION proc_can_view_amounts()       TO authenticated;
GRANT EXECUTE ON FUNCTION proc_can_see_pr(text)         TO authenticated;


-- ═══════════════ 3) سدّ ثغرة تصعيد: الموظف يوسّع نطاقه بنفسه ═══════════════
-- `proc_users_guard` (db/proc-users-hardening.sql) يمرّر أي UPDATE لا يمسّ
-- قائمة الحقول الحسّاسة كـ«تعديل حميد» (مثل last_login). و`scope_sectors`
-- عمود جديد فليس في تلك القائمة ⇒ موظّف مُنطَّق يستطيع PATCH صفَّه ويمنح
-- نفسه كل القطاعات. نُعيد تعريف الحارس بإضافة العمود إلى الفحص.
-- (بقيّة منطق الحارس منقولة كما هي حرفيّاً.)
CREATE OR REPLACE FUNCTION proc_users_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF pr_is_service() THEN RETURN COALESCE(NEW, OLD); END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.permissions   IS NOT DISTINCT FROM OLD.permissions
     AND NEW.role          IS NOT DISTINCT FROM OLD.role
     AND NEW.active        IS NOT DISTINCT FROM OLD.active
     AND NEW.is_away       IS NOT DISTINCT FROM OLD.is_away
     AND NEW.delegate_to   IS NOT DISTINCT FROM OLD.delegate_to
     AND NEW.username      IS NOT DISTINCT FROM OLD.username
     AND NEW.email         IS NOT DISTINCT FROM OLD.email
     AND NEW.password_hash IS NOT DISTINCT FROM OLD.password_hash
     AND NEW.scope_sectors IS NOT DISTINCT FROM OLD.scope_sectors   -- ← الجديد
  THEN RETURN NEW; END IF;

  IF pr_has_perm('can_manage_users') THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل المستخدمين أو صلاحياتهم يتطلّب صلاحية «إدارة المستخدمين»';
END $fn$;

DROP TRIGGER IF EXISTS trg_proc_users_guard ON proc_users;
CREATE TRIGGER trg_proc_users_guard
  BEFORE INSERT OR UPDATE OR DELETE ON proc_users
  FOR EACH ROW EXECUTE FUNCTION proc_users_guard();


-- ═══════════════ 4) سياسات RLS ═══════════════
-- ⚠️ قاعدتان تحكمان كل ما يلي:
--   (أ) `FOR ALL` يُلغي أي تقييد على SELECT (السياسات تُجمَع بـOR)، فلا بدّ
--       من سياسة لكل أمر على حدة — نفس الدرس المثبَّت في هجرة البوابة 009.
--   (ب) تُحذف **كل** السياسات القائمة على الجدول أوّلاً مهما كان اسمها
--       (`auth_all` / `auth_read` / «Enable read for all» …) فينتهي الجدول
--       إلى حالة معروفة أيّاً كانت السكربتات التاريخية التي شُغِّلت عليه.
--       (نفس أسلوب db/security-hardening.sql:89.)

CREATE OR REPLACE FUNCTION proc_drop_all_policies(p_table text) RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE p record;
BEGIN
  FOR p IN SELECT policyname FROM pg_policies
            WHERE schemaname = 'public' AND tablename = p_table LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p.policyname, p_table);
  END LOOP;
END $fn$;

-- ── 4-أ) أوامر الشراء: القراءة مُنطَّقة، والكتابة لغير المُنطَّق فقط ──
-- المُنطَّق لا يكتب الصفّ إطلاقاً؛ استلامه وتعليقه يمرّان بدالّتَي القسم 5
-- (SECURITY DEFINER) — فلا يستطيع عميلٌ مقيَّد أن يكتب الصفّ كاملاً ويمحو
-- المبالغ التي صُفِّرت له في العرض.
ALTER TABLE proc_purchase_orders ENABLE ROW LEVEL SECURITY;
SELECT proc_drop_all_policies('proc_purchase_orders');
CREATE POLICY "po_select" ON proc_purchase_orders FOR SELECT TO authenticated
  USING (proc_can_see_po(sector));
CREATE POLICY "po_insert" ON proc_purchase_orders FOR INSERT TO authenticated
  WITH CHECK (NOT proc_is_scoped());
CREATE POLICY "po_update" ON proc_purchase_orders FOR UPDATE TO authenticated
  USING (NOT proc_is_scoped()) WITH CHECK (NOT proc_is_scoped());
CREATE POLICY "po_delete" ON proc_purchase_orders FOR DELETE TO authenticated
  USING (NOT proc_is_scoped());

-- ── 4-ب) المستخدمون: المُنطَّق يرى صفَّه وحده ──
-- كان أي موظّف يقرأ هاش كلمة سرّ كل مستخدم. الكتابة تبقى كما هي —
-- الحارس أعلاه هو المدافع (رفض افتراضيّ لكل حقل حسّاس).
ALTER TABLE proc_users ENABLE ROW LEVEL SECURITY;
SELECT proc_drop_all_policies('proc_users');
CREATE POLICY "users_select" ON proc_users FOR SELECT TO authenticated
  USING (NOT proc_is_scoped() OR lower(username) = lower(proc_me()));
CREATE POLICY "users_insert" ON proc_users FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "users_update" ON proc_users FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "users_delete" ON proc_users FOR DELETE TO authenticated USING (true);

-- ── 4-ج) الجداول حاملة الأسعار: تُحجب عمّن لا يرى المبالغ ──
-- الكتالوج والسجل السعريّ ودليل الموردين كلّها أسعار. من لا يرى مبلغ أمر
-- الشراء لا معنى لأن يقرأ دفتر الأسعار كلّه من الباب الخلفيّ.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['proc_items','proc_suppliers','proc_history'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    PERFORM proc_drop_all_policies(t);
    EXECUTE format($f$CREATE POLICY "cat_select" ON %I FOR SELECT TO authenticated
                        USING (NOT proc_is_scoped() OR proc_can_view_amounts())$f$, t);
    EXECUTE format($f$CREATE POLICY "cat_insert" ON %I FOR INSERT TO authenticated
                        WITH CHECK (NOT proc_is_scoped())$f$, t);
    EXECUTE format($f$CREATE POLICY "cat_update" ON %I FOR UPDATE TO authenticated
                        USING (NOT proc_is_scoped()) WITH CHECK (NOT proc_is_scoped())$f$, t);
    EXECUTE format($f$CREATE POLICY "cat_delete" ON %I FOR DELETE TO authenticated
                        USING (NOT proc_is_scoped())$f$, t);
  END LOOP;
END $$;

-- ── 4-د) طلبات الشراء: طلباته + طلبات قطاعاته، ويُنشئ باسمه هو ──
-- آلة الحالة تبقى محكومة بـ`pr_transition` وحارسَي pr_guard_status/approval
-- القائمين (db/pr-portal.sql) — لم نُضعِف منها شيئاً.
ALTER TABLE proc_purchase_requests ENABLE ROW LEVEL SECURITY;
SELECT proc_drop_all_policies('proc_purchase_requests');
CREATE POLICY "pr_select" ON proc_purchase_requests FOR SELECT TO authenticated
  USING (NOT proc_is_scoped()
         OR lower(coalesce(requester,'')) = lower(proc_me())
         OR sector = ANY(proc_scope_sectors()));
CREATE POLICY "pr_insert" ON proc_purchase_requests FOR INSERT TO authenticated
  WITH CHECK (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me()));
CREATE POLICY "pr_update" ON proc_purchase_requests FOR UPDATE TO authenticated
  USING (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me()))
  WITH CHECK (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me()));
CREATE POLICY "pr_delete" ON proc_purchase_requests FOR DELETE TO authenticated
  USING (NOT proc_is_scoped() OR lower(coalesce(requester,'')) = lower(proc_me()));

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['proc_pr_items','proc_pr_approvals'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    PERFORM proc_drop_all_policies(t);
    EXECUTE format($f$CREATE POLICY "prc_select" ON %I FOR SELECT TO authenticated
                        USING (proc_can_see_pr(pr_id))$f$, t);
    EXECUTE format($f$CREATE POLICY "prc_insert" ON %I FOR INSERT TO authenticated
                        WITH CHECK (proc_can_see_pr(pr_id))$f$, t);
    EXECUTE format($f$CREATE POLICY "prc_update" ON %I FOR UPDATE TO authenticated
                        USING (proc_can_see_pr(pr_id)) WITH CHECK (proc_can_see_pr(pr_id))$f$, t);
    EXECUTE format($f$CREATE POLICY "prc_delete" ON %I FOR DELETE TO authenticated
                        USING (NOT proc_is_scoped())$f$, t);
  END LOOP;
END $$;

-- ── 4-هـ) سجلّ التدقيق: ليس لموظّف الصيانة ──
ALTER TABLE proc_audit_log ENABLE ROW LEVEL SECURITY;
SELECT proc_drop_all_policies('proc_audit_log');
CREATE POLICY "audit_select" ON proc_audit_log FOR SELECT TO authenticated
  USING (NOT proc_is_scoped());
CREATE POLICY "audit_insert" ON proc_audit_log FOR INSERT TO authenticated WITH CHECK (true);
-- لا UPDATE ولا DELETE — إضافة فقط، كما كان.


-- ═══════════════ 5) كتابة الموظّف المُنطَّق — دالّتان فقط ═══════════════
-- لا سياسة UPDATE للمُنطَّق على أمر الشراء إطلاقاً. هاتان الدالّتان هما كل
-- ما يستطيع كتابته، والمنطق كلّه على الخادم فلا يُصدَّق شيء من العميل.

-- تسجيل استلام. تُعيد بناء ما تفعله `poReceiveSave` في الواجهة، خادميّاً.
--   p_lines = [{"idx":0,"qty":5}, ...]  (الفهرس داخل مصفوفة items)
CREATE OR REPLACE FUNCTION po_record_receipt(
  p_po text, p_lines jsonb, p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me      text := proc_me();
  v_name    text;
  v_po      proc_purchase_orders%ROWTYPE;
  v_items   jsonb;
  v_line    jsonb;
  v_idx     int;
  v_item    jsonb;
  v_q       numeric; v_prev numeric; v_rem numeric; v_now numeric;
  v_applied jsonb := '[]'::jsonb;
  v_any     boolean := false;
  v_ordered numeric := 0; v_recvd numeric := 0;
  v_complete boolean; v_newstatus text; v_at timestamptz := now();
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;

  SELECT * INTO v_po FROM proc_purchase_orders WHERE po_number = p_po FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'أمر الشراء غير موجود'; END IF;

  -- النطاق أوّلاً: لا استلام على أمر خارج قطاعات المتصل.
  IF NOT proc_can_see_po(v_po.sector) THEN
    RAISE EXCEPTION 'هذا الأمر خارج نطاقك';
  END IF;
  IF NOT (pr_has_perm('can_receive_po') OR pr_has_perm('can_edit_po')) THEN
    RAISE EXCEPTION 'تسجيل الاستلام يتطلّب صلاحية «تسجيل استلام البضاعة»';
  END IF;
  IF v_po.status = ANY (ARRAY['تسليم كامل','ملغى']) THEN
    RAISE EXCEPTION 'الأمر في حالة نهائية (مُغلق أو مُلغى)';
  END IF;

  v_items := coalesce(v_po.items, '[]'::jsonb);
  IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'هذا الأمر بلا بنود قابلة للاستلام';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) LOOP
    v_idx := (v_line ->> 'idx')::int;
    IF v_idx IS NULL OR v_idx < 0 OR v_idx >= jsonb_array_length(v_items) THEN CONTINUE; END IF;
    v_item := v_items -> v_idx;
    v_q    := coalesce((v_item ->> 'qty')::numeric, 0);
    v_prev := least(v_q, greatest(0, coalesce((v_item ->> 'received_qty')::numeric, 0)));
    v_rem  := greatest(0, v_q - v_prev);
    -- ⚠️ القصّ عند المتبقّي على الخادم: العميل لا يُصدَّق في الكمية.
    v_now  := least(greatest(coalesce((v_line ->> 'qty')::numeric, 0), 0), v_rem);
    IF v_now > 0 THEN
      v_items := jsonb_set(v_items, ARRAY[v_idx::text, 'received_qty'],
                           to_jsonb(v_prev + v_now), true);
      v_applied := v_applied || jsonb_build_object(
                     'desc', coalesce(v_item ->> 'desc',''), 'qty', v_now);
      v_any := true;
    END IF;
  END LOOP;

  IF NOT v_any THEN RAISE EXCEPTION 'أدخل كمية مستلمة واحدة على الأقل'; END IF;

  SELECT coalesce(sum(coalesce((e ->> 'qty')::numeric, 0)), 0),
         coalesce(sum(least(coalesce((e ->> 'qty')::numeric, 0),
                            greatest(0, coalesce((e ->> 'received_qty')::numeric, 0)))), 0)
    INTO v_ordered, v_recvd
    FROM jsonb_array_elements(v_items) e;
  v_complete := v_ordered > 0 AND v_recvd >= v_ordered;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username) = lower(v_me) LIMIT 1;
  v_name := coalesce(v_name, v_me);

  v_newstatus := v_po.status;
  IF v_complete THEN v_newstatus := 'تسليم كامل';
  ELSIF v_po.status <> 'تسليم جزئي' THEN v_newstatus := 'تسليم جزئي';
  END IF;

  UPDATE proc_purchase_orders SET
    items    = v_items,
    receipts = coalesce(receipts, '[]'::jsonb) || jsonb_build_object(
                 'by', v_name, 'username', v_me, 'at', v_at,
                 'note', nullif(btrim(coalesce(p_note,'')), ''), 'lines', v_applied),
    status   = v_newstatus,
    status_history = CASE WHEN v_newstatus <> v_po.status
                          THEN coalesce(status_history, '[]'::jsonb) || jsonb_build_object(
                                 'from', v_po.status, 'to', v_newstatus, 'by', v_name, 'at', v_at)
                          ELSE status_history END,
    actual_delivery = CASE WHEN v_complete AND actual_delivery IS NULL
                           THEN to_char(v_at, 'YYYY-MM-DD') ELSE actual_delivery END,
    updated_at = v_at,
    updated_by = v_me
  WHERE po_number = p_po;

  INSERT INTO proc_audit_log (username, display_name, action, entity_type, entity_id, new_value)
  VALUES (v_me, v_name, 'receive', 'po', p_po,
          jsonb_build_object('lines', v_applied, 'complete', v_complete,
                             'received', v_recvd, 'ordered', v_ordered, 'via', 'rpc'));

  RETURN jsonb_build_object('ok', true, 'complete', v_complete, 'received', v_recvd,
                            'ordered', v_ordered, 'status', v_newstatus);
END $fn$;

-- ملاحظة متابعة ميدانية على أمر داخل نطاق المتصل.
CREATE OR REPLACE FUNCTION po_add_comment(p_po text, p_text text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_name text; v_sector text; v_at timestamptz := now();
  v_txt text := btrim(coalesce(p_text, ''));
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF v_txt = '' THEN RAISE EXCEPTION 'الملاحظة فارغة'; END IF;
  IF length(v_txt) > 2000 THEN RAISE EXCEPTION 'الملاحظة طويلة جداً (2000 حرف كحدّ أقصى)'; END IF;

  SELECT sector INTO v_sector FROM proc_purchase_orders WHERE po_number = p_po FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'أمر الشراء غير موجود'; END IF;
  IF NOT proc_can_see_po(v_sector) THEN RAISE EXCEPTION 'هذا الأمر خارج نطاقك'; END IF;

  SELECT display_name INTO v_name FROM proc_users WHERE lower(username) = lower(v_me) LIMIT 1;
  v_name := coalesce(v_name, v_me);

  UPDATE proc_purchase_orders
     SET comments = coalesce(comments, '[]'::jsonb) || jsonb_build_object(
                      'by', v_name, 'username', v_me, 'at', v_at, 'text', v_txt)
   WHERE po_number = p_po;

  INSERT INTO proc_audit_log (username, display_name, action, entity_type, entity_id, new_value)
  VALUES (v_me, v_name, 'comment', 'po', p_po, jsonb_build_object('text', v_txt));

  RETURN jsonb_build_object('ok', true, 'by', v_name, 'at', v_at);
END $fn$;

REVOKE ALL ON FUNCTION po_record_receipt(text, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION po_add_comment(text, text)           FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION po_record_receipt(text, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION po_add_comment(text, text)           TO authenticated;


-- ═══════════════ 6) عرض إخفاء المبالغ ═══════════════
-- `security_invoker = true` مقصود: تبقى سياسات القسم 4 هي حارس **الصفوف**،
-- والعرض مسؤول عن **الأعمدة** فقط. فلا يتكرّر شرط النطاق في موضعين.
-- ⚠️ لا تُسحَب SELECT عن الجدول الأساس: القفل المتفائل في `poCloudUpsert`
-- يقرأ `updated_at/updated_by` منه مباشرةً، وسحبها تكسره لكل المستخدمين.
DROP VIEW IF EXISTS proc_po_visible;
CREATE VIEW proc_po_visible WITH (security_invoker = true) AS
SELECT
  po_number, issue_date, sector, project, supplier, officer, payment_method,
  priority, expected_delivery, actual_delivery, status, days_delayed,
  delay_reason, notes, category, lead_time_days, status_history, receipts,
  comments, source, created_by, created_at, updated_by, updated_at,
  CASE WHEN proc_can_view_amounts() THEN subtotal END AS subtotal,
  CASE WHEN proc_can_view_amounts() THEN vat      END AS vat,
  CASE WHEN proc_can_view_amounts() THEN total    END AS total,
  CASE WHEN proc_can_view_amounts() THEN items
       ELSE (SELECT coalesce(jsonb_agg(e - 'price'), '[]'::jsonb)
               FROM jsonb_array_elements(coalesce(items, '[]'::jsonb)) e)
  END AS items
FROM proc_purchase_orders;

GRANT SELECT ON proc_po_visible TO authenticated;


-- ═══════════════ التحقّق (شغّلها بعد التطبيق) ═══════════════
-- SELECT count(*) FROM pg_policies WHERE tablename='proc_purchase_orders';  -- 4
-- SELECT proc_is_scoped(), proc_can_view_amounts();                          -- false,true للأدمن
-- SELECT count(*) FROM proc_po_visible;                                      -- 115 لغير المُنطَّق

-- ═══════════════ التراجع (لا تشغّله إلا للطوارئ) ═══════════════
-- يعيد كل جدول إلى `auth_all` المفتوحة كما كانت قبل هذا الملف.
/*
DROP VIEW IF EXISTS proc_po_visible;
DROP FUNCTION IF EXISTS po_record_receipt(text, jsonb, text);
DROP FUNCTION IF EXISTS po_add_comment(text, text);
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['proc_purchase_orders','proc_users','proc_items','proc_suppliers',
                           'proc_history','proc_purchase_requests','proc_pr_items',
                           'proc_pr_approvals','proc_audit_log'] LOOP
    PERFORM proc_drop_all_policies(t);
    EXECUTE format('CREATE POLICY "auth_all" ON %I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;
*/

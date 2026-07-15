-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 031 — ضبط الميزانية (Commitment Control) — P0 من التدقيق الاستشاري
--  المشكلة: لا ربط للطلب بميزانية معتمدة ⇒ يمكن التعميد بلا حدّ مالي. أكبر
--  الشركات لا تلتزم مالياً دون فحص توفّر ميزانية القسم/السنة (محاسبة الالتزام).
--
--  الحل (الأقل تدخّلاً + المحاسبي الصحيح):
--    • جدول `portal_budgets` (قسم × سنة مالية × مبلغ معتمد) — كتابة عبر RPC فقط،
--      قراءة للمالية/الأدمن/المشتريات (RLS).
--    • «المرتبط» (committed) = مجموع قيم التعميدات النشطة شاملةً الضريبة (الالتزام
--      يقع عند الترسية لا عند الصرف — فلا ازدواج حساب). المجزّأ يُحسب بمجموع بنوده.
--    • الإنفاذ عبر **مُشغِّل قيد مؤجَّل** على portal_award يتحقّق عند تثبيت المعاملة
--      (يلتقط الترسية المجزّأة كاملةً) — دون لمس أيٍّ من دوال الترسية.
--
--  خامل وآمن: بلا ميزانية معرّفة للقسم/السنة ⇒ لا إنفاذ إطلاقاً (السلوك الحالي).
--  حتى مع ميزانية: `budget_enforce=0` (افتراضي) ⇒ تحذير غير مانع؛ =1 ⇒ منع.
--  idempotent — مدمجة في portal-standalone.sql.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) جدول الميزانيات ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_budgets (
  id            BIGSERIAL PRIMARY KEY,
  department_id TEXT NOT NULL REFERENCES portal_departments(id),
  fiscal_year   INT  NOT NULL,
  amount        NUMERIC NOT NULL DEFAULT 0 CHECK (amount >= 0),
  note          TEXT,
  active        BOOLEAN NOT NULL DEFAULT true,
  updated_by    TEXT,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (department_id, fiscal_year)
);

-- قراءة مقيَّدة بالمالية/الأدمن/المشتريات؛ الكتابة عبر RPC (DEFINER) فقط.
ALTER TABLE portal_budgets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_budgets_read ON portal_budgets;
CREATE POLICY portal_budgets_read ON portal_budgets FOR SELECT USING (
  portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement'));
REVOKE ALL ON portal_budgets FROM anon, PUBLIC;
GRANT  SELECT ON portal_budgets TO authenticated;             -- تصفية RLS تحكم الرؤية الفعلية
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_budgets TO service_role;
GRANT  USAGE, SELECT ON SEQUENCE portal_budgets_id_seq TO service_role;

-- ── (2) حساب «المرتبط» (committed) — الالتزام عند الترسية شاملاً الضريبة ──────
-- خادمية (DEFINER)؛ يستدعيها المُشغِّل ودالة الحالة. لا تُمنح للعميل مباشرة.
CREATE OR REPLACE FUNCTION portal_budget_committed(p_dept text, p_year int)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(
    COALESCE((SELECT sum(al.line_total) FROM portal_award_lines al WHERE al.request_id = a.request_id),
             a.winner_total)
    * (1 + portal_setting_num('vat', 15) / 100.0)
  ), 0)
  FROM portal_award a
  JOIN portal_requests r ON r.id = a.request_id
  WHERE a.status IN ('pending','approved')
    AND r.department_id = p_dept
    AND EXTRACT(YEAR FROM r.created_at)::int = p_year
    AND coalesce(r.status,'') <> 'cancelled';
$fn$;
REVOKE ALL ON FUNCTION portal_budget_committed(text, int) FROM anon, authenticated, PUBLIC;

-- ── (3) حالة الميزانية (للمالية/الأدمن/المشتريات) ───────────────────────────
CREATE OR REPLACE FUNCTION portal_budget_status(p_dept text, p_year int)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_amount numeric; v_committed numeric;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_see_finance') OR portal_has_perm('can_manage_procurement')) THEN
    RAISE EXCEPTION 'غير مصرّح بعرض الميزانية';
  END IF;
  SELECT amount INTO v_amount FROM portal_budgets WHERE department_id=p_dept AND fiscal_year=p_year AND active;
  v_committed := portal_budget_committed(p_dept, p_year);
  RETURN jsonb_build_object(
    'department', p_dept, 'fiscal_year', p_year,
    'defined',   v_amount IS NOT NULL,
    'amount',    coalesce(v_amount, 0),
    'committed', v_committed,
    'available', coalesce(v_amount, 0) - v_committed,
    'enforced',  portal_setting_num('budget_enforce', 0) >= 1
  );
END $fn$;
REVOKE ALL ON FUNCTION portal_budget_status(text, int) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_budget_status(text, int) TO authenticated;

-- ── (4) إدارة الميزانية (المالية/الأدمن فقط) ─────────────────────────────────
CREATE OR REPLACE FUNCTION portal_budget_set(p_dept text, p_year int, p_amount numeric, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username();
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'غير مصرّح بإدارة الميزانية';
  END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN RAISE EXCEPTION 'مبلغ الميزانية غير صالح'; END IF;
  IF NOT EXISTS (SELECT 1 FROM portal_departments WHERE id = p_dept) THEN RAISE EXCEPTION 'قسم غير موجود'; END IF;
  INSERT INTO portal_budgets (department_id, fiscal_year, amount, note, updated_by, updated_at)
    VALUES (p_dept, p_year, p_amount, p_note, v_me, now())
  ON CONFLICT (department_id, fiscal_year)
    DO UPDATE SET amount = EXCLUDED.amount, note = EXCLUDED.note, active = true,
                  updated_by = v_me, updated_at = now();
  RETURN jsonb_build_object('ok', true, 'department', p_dept, 'fiscal_year', p_year, 'amount', p_amount);
END $fn$;
REVOKE ALL ON FUNCTION portal_budget_set(text, int, numeric, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_budget_set(text, int, numeric, text) TO authenticated;

CREATE OR REPLACE FUNCTION portal_budget_delete(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username();
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'غير مصرّح بإدارة الميزانية';
  END IF;
  DELETE FROM portal_budgets WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END $fn$;
REVOKE ALL ON FUNCTION portal_budget_delete(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_budget_delete(bigint) TO authenticated;

-- ── (5) الإنفاذ: مُشغِّل قيد مؤجَّل على portal_award ─────────────────────────
-- يفحص عند تثبيت المعاملة (بعد اكتمال award + award_lines للترسية المجزّأة).
CREATE OR REPLACE FUNCTION portal_budget_enforce() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_dept text; v_year int; v_budget numeric; v_committed numeric; v_enforce numeric;
BEGIN
  SELECT department_id, EXTRACT(YEAR FROM created_at)::int INTO v_dept, v_year
    FROM portal_requests WHERE id = NEW.request_id;
  IF v_dept IS NULL THEN RETURN NULL; END IF;
  SELECT amount INTO v_budget FROM portal_budgets WHERE department_id=v_dept AND fiscal_year=v_year AND active;
  IF v_budget IS NULL THEN RETURN NULL; END IF;               -- لا ميزانية معرّفة ⇒ لا إنفاذ
  v_committed := portal_budget_committed(v_dept, v_year);
  IF v_committed <= v_budget THEN RETURN NULL; END IF;
  v_enforce := portal_setting_num('budget_enforce', 0);
  IF v_enforce >= 1 THEN
    RAISE EXCEPTION 'تجاوز الميزانية: القسم % سنة % — المرتبط % يتجاوز المعتمد % (المتاح %)',
      v_dept, v_year, round(v_committed), round(v_budget), round(v_budget - v_committed);
  ELSE
    RAISE WARNING 'تحذير ميزانية (غير مانع): القسم % سنة % — المرتبط % يتجاوز المعتمد %',
      v_dept, v_year, round(v_committed), round(v_budget);
  END IF;
  RETURN NULL;
END $fn$;

DROP TRIGGER IF EXISTS trg_portal_budget_enforce ON portal_award;
CREATE CONSTRAINT TRIGGER trg_portal_budget_enforce
  AFTER INSERT OR UPDATE ON portal_award
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION portal_budget_enforce();

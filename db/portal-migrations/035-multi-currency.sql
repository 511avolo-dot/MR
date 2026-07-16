-- ════════════════════════════════════════════════════════════════════════════
--  الهجرة 035 — أساس تعدّد العملات (Multi-Currency) — بند برمجي اختياري
--  الفجوة: `portal_requests.currency` موجود لكن بلا أسعار صرف ولا تحويل لعملة
--  الأساس — فالتقارير/الميزانية بعملة واحدة ضمنية. الموردون الدوليون متعذّرون.
--
--  التصميم (خامل وآمن — لا تغيير سلوك):
--    • جدول `portal_currencies` (رمز + سعر مقابل عملة الأساس + تفعيل). بذرة SAR=1.
--    • `portal_currency_rate(code)` يعيد سعر التحويل لعملة الأساس (1 للأساس/المفقود).
--    • دالتا القيمة `portal_award_total`/`portal_budget_committed` صارتا تحوّلان
--      بعملة الطلب × سعرها → كل التجميعات (ميزانية/مطابقة/تقارير) بعملة الأساس.
--
--  كل البيانات الحالية `currency='SAR'` بسعر 1 ⇒ التحويل no-op ⇒ صفر تغيير سلوك.
--  idempotent — مدمجة في portal-standalone.sql. تطبَّق بعد 034.
-- ════════════════════════════════════════════════════════════════════════════

-- ── (1) جدول العملات + بذرة الأساس ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS portal_currencies (
  code         TEXT PRIMARY KEY,                          -- ISO: SAR, USD, EUR, AED...
  name         TEXT,
  rate_to_base NUMERIC NOT NULL DEFAULT 1 CHECK (rate_to_base > 0),
  active       BOOLEAN NOT NULL DEFAULT true,
  updated_by   TEXT,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO portal_currencies(code, name, rate_to_base, active)
  VALUES ('SAR','ريال سعودي',1,true) ON CONFLICT (code) DO NOTHING;
-- عملة الأساس في الإعدادات (افتراضي SAR)
UPDATE portal_settings SET value = jsonb_set(coalesce(value,'{}'::jsonb),'{base_currency}', to_jsonb('SAR'::text), true)
  WHERE key='portal_settings' AND NOT (coalesce(value,'{}'::jsonb) ? 'base_currency');

-- العملات مرجع عام (قراءة لكل مسجَّل، كتابة عبر RPC فقط)
ALTER TABLE portal_currencies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portal_currencies_read ON portal_currencies;
CREATE POLICY portal_currencies_read ON portal_currencies FOR SELECT TO authenticated USING (true);
REVOKE ALL ON portal_currencies FROM anon, PUBLIC;
GRANT  SELECT ON portal_currencies TO authenticated, anon;
GRANT  SELECT, INSERT, UPDATE, DELETE ON portal_currencies TO service_role;

-- ── (2) سعر التحويل لعملة الأساس (1 للأساس أو المفقود) ───────────────────────
CREATE OR REPLACE FUNCTION portal_currency_rate(p_code text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE((SELECT rate_to_base FROM portal_currencies WHERE code = upper(coalesce(nullif(trim(p_code),''),'SAR'))), 1);
$fn$;
REVOKE ALL ON FUNCTION portal_currency_rate(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_currency_rate(text) TO authenticated;

-- ── (3) إدارة العملات (مالية/أدمن) ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION portal_currency_set(p_code text, p_name text, p_rate numeric, p_active boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_code text := upper(trim(coalesce(p_code,'')));
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'إدارة العملات صلاحية مالية/أدمن';
  END IF;
  IF v_code !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'رمز عملة غير صالح (3 أحرف ISO)'; END IF;
  IF p_rate IS NULL OR p_rate <= 0 THEN RAISE EXCEPTION 'سعر الصرف غير صالح'; END IF;
  INSERT INTO portal_currencies(code, name, rate_to_base, active, updated_by, updated_at)
    VALUES (v_code, p_name, p_rate, coalesce(p_active,true), v_me, now())
  ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, rate_to_base = EXCLUDED.rate_to_base,
    active = EXCLUDED.active, updated_by = v_me, updated_at = now();
  RETURN jsonb_build_object('ok', true, 'code', v_code, 'rate', p_rate);
END $fn$;
REVOKE ALL ON FUNCTION portal_currency_set(text, text, numeric, boolean) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_currency_set(text, text, numeric, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION portal_currency_delete(p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text := portal_username(); v_code text := upper(trim(coalesce(p_code,''))); v_base text;
BEGIN
  IF v_me IS NULL OR NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'إدارة العملات صلاحية مالية/أدمن';
  END IF;
  v_base := upper(coalesce((SELECT value->>'base_currency' FROM portal_settings WHERE key='portal_settings'),'SAR'));
  IF v_code = v_base THEN RAISE EXCEPTION 'لا يمكن حذف عملة الأساس (%)', v_base; END IF;
  DELETE FROM portal_currencies WHERE code = v_code;
  RETURN jsonb_build_object('ok', true);
END $fn$;
REVOKE ALL ON FUNCTION portal_currency_delete(text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_currency_delete(text) TO authenticated;

-- ── (4) دوال القيمة صارت واعية بالعملة (تحويل لعملة الأساس) ──────────────────
-- إجمالي أمر الشراء بعملة الأساس = (winner_total أو مجموع بنود المجزّأ) × الضريبة × سعر عملة الطلب.
CREATE OR REPLACE FUNCTION portal_award_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(
    COALESCE((SELECT sum(line_total) FROM portal_award_lines WHERE request_id = p_request_id),
             (SELECT winner_total FROM portal_award WHERE request_id = p_request_id AND status IN ('pending','approved'))),
    0)
  * (1 + portal_setting_num('vat', 15) / 100.0)
  * portal_currency_rate((SELECT currency FROM portal_requests WHERE id = p_request_id));
$fn$;
REVOKE ALL ON FUNCTION portal_award_total(text) FROM anon, authenticated, PUBLIC;

-- المرتبط (الميزانية) بعملة الأساس = مجموع التعميدات النشطة × الضريبة × سعر عملة كل طلب.
CREATE OR REPLACE FUNCTION portal_budget_committed(p_dept text, p_year int)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(
    COALESCE((SELECT sum(al.line_total) FROM portal_award_lines al WHERE al.request_id = a.request_id),
             a.winner_total)
    * (1 + portal_setting_num('vat', 15) / 100.0)
    * portal_currency_rate(r.currency)
  ), 0)
  FROM portal_award a
  JOIN portal_requests r ON r.id = a.request_id
  WHERE a.status IN ('pending','approved')
    AND r.department_id = p_dept
    AND EXTRACT(YEAR FROM r.created_at)::int = p_year
    AND coalesce(r.status,'') <> 'cancelled';
$fn$;
REVOKE ALL ON FUNCTION portal_budget_committed(text, int) FROM anon, authenticated, PUBLIC;

-- إجمالي الفواتير والمرتجعات بعملة الأساس (تُدخَل بعملة الطلب) — لاتّساق المطابقة الثلاثية.
CREATE OR REPLACE FUNCTION portal_invoiced_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(amount), 0) * portal_currency_rate((SELECT currency FROM portal_requests WHERE id = p_request_id))
  FROM portal_supplier_invoices WHERE request_id = p_request_id;
$fn$;
REVOKE ALL ON FUNCTION portal_invoiced_total(text) FROM anon, authenticated, PUBLIC;

CREATE OR REPLACE FUNCTION portal_returns_total(p_request_id text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(SUM(debit_amount), 0) * portal_currency_rate((SELECT currency FROM portal_requests WHERE id = p_request_id))
  FROM portal_returns WHERE request_id = p_request_id;
$fn$;
REVOKE ALL ON FUNCTION portal_returns_total(text) FROM anon, authenticated, PUBLIC;

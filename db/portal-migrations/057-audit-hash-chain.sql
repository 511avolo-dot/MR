-- ═══════════════════════════════════════════════════════════════════════════
--  057 — تدقيق ثابت مقاوم للعبث (Hash-Chained WORM Audit) — المرحلة 6 (التصليب)
--  ─────────────────────────────────────────────────────────────────────────
--  سجلّ التدقيق (portal_audit) append-only أصلاً (حارس يمنع UPDATE/DELETE حتى
--  بمفتاح الخدمة). هذه الهجرة ترفعه إلى **دليل مقاوم للعبث تشفيرياً**: كل صفّ
--  يحمل تجزئة SHA-256 تربطه بالصفّ السابق (سلسلة تجزئة)، فأيّ تعديل لصفّ ماضٍ —
--  حتى بتجاوز التطبيق على مستوى القاعدة — **يكسر السلسلة ويُكتشَف** عبر دالة تحقّق.
--
--  التصميم:
--   • مُشغِّل BEFORE INSERT يحسب `row_hash = SHA256(prev_hash | محتوى الصفّ)` —
--     يتجاهل أيّ قيمة يُمرّرها العميل (لا تزوير عند الإدراج). قفل استشاري يُسلسِل
--     الإلحاق فلا تتفرّع السلسلة تحت التزامن.
--   • sha256 مدمجة في PostgreSQL 11+ (لا امتداد). النقطة الأولى genesis (السلسلة
--     تبدأ من هذه الهجرة؛ الصفوف القديمة — بيانات تجريبية قبل الإطلاق — غير مُسلسَلة).
--   • `portal_audit_verify()` تمشي السلسلة كاملةً وتُرجِع أوّل صفّ مكسور (أو لا شيء).
--
--  ⚠️ تُطبَّق حيّاً بعد 056. مدمجة في db/portal-standalone.sql.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE portal_audit ADD COLUMN IF NOT EXISTS prev_hash TEXT;
ALTER TABLE portal_audit ADD COLUMN IF NOT EXISTS row_hash  TEXT;

-- ── دالة التجزئة الكنسيّة لمحتوى الصفّ (تُستعمَل عند الإدراج وعند التحقّق) ───────
CREATE OR REPLACE FUNCTION portal_audit_hash(p_prev text, p_request_id text, p_event text,
    p_actor text, p_channel text, p_detail jsonb, p_created_at timestamptz) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT encode(sha256(convert_to(
    coalesce(p_prev,'GENESIS') || '|' || coalesce(p_request_id,'') || '|' || coalesce(p_event,'') || '|' ||
    coalesce(p_actor,'') || '|' || coalesce(p_channel,'') || '|' || coalesce(p_detail::text,'') || '|' ||
    coalesce(p_created_at::text,''), 'UTF8')), 'hex');
$$;
REVOKE ALL ON FUNCTION portal_audit_hash(text,text,text,text,text,jsonb,timestamptz) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_audit_hash(text,text,text,text,text,jsonb,timestamptz) TO authenticated;

-- ── مُشغِّل سلسلة التجزئة (BEFORE INSERT) — يحسب الحقول ويتجاهل مُدخَل العميل ──
CREATE OR REPLACE FUNCTION portal_audit_chain() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $fn$
DECLARE v_prev text;
BEGIN
  PERFORM pg_advisory_xact_lock(4923771077);   -- يُسلسِل إلحاق السلسلة (لا تفرّع)
  SELECT row_hash INTO v_prev FROM portal_audit WHERE row_hash IS NOT NULL ORDER BY id DESC LIMIT 1;
  v_prev := coalesce(v_prev, 'GENESIS');
  NEW.prev_hash := v_prev;
  NEW.row_hash  := portal_audit_hash(v_prev, NEW.request_id, NEW.event, NEW.actor, NEW.channel, NEW.detail, NEW.created_at);
  RETURN NEW;
END $fn$;
REVOKE ALL ON FUNCTION portal_audit_chain() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_audit_chain() TO authenticated;

DROP TRIGGER IF EXISTS trg_portal_audit_chain ON portal_audit;
CREATE TRIGGER trg_portal_audit_chain BEFORE INSERT ON portal_audit
  FOR EACH ROW EXECUTE FUNCTION portal_audit_chain();

-- ── التحقّق: يمشي السلسلة كاملةً ويكشف أوّل عبث ──────────────────────────────
CREATE OR REPLACE FUNCTION portal_audit_verify() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE r RECORD; v_prev text := 'GENESIS'; v_calc text; v_checked int := 0; v_broken bigint := NULL;
BEGIN
  IF NOT (portal_is_admin() OR portal_has_perm('can_see_finance')) THEN
    RAISE EXCEPTION 'التحقّق من سلامة التدقيق صلاحية مالية/أدمن';
  END IF;
  FOR r IN SELECT * FROM portal_audit WHERE row_hash IS NOT NULL ORDER BY id ASC LOOP
    v_calc := portal_audit_hash(v_prev, r.request_id, r.event, r.actor, r.channel, r.detail, r.created_at);
    IF r.prev_hash IS DISTINCT FROM v_prev OR r.row_hash <> v_calc THEN
      v_broken := r.id; EXIT;
    END IF;
    v_prev := r.row_hash; v_checked := v_checked + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', v_broken IS NULL, 'checked', v_checked, 'broken_at', v_broken);
END $fn$;
REVOKE ALL ON FUNCTION portal_audit_verify() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION portal_audit_verify() TO authenticated;

-- تحقّق:
--   SELECT portal_audit_verify();   ⇒ {"ok":true,"checked":N,"broken_at":null}

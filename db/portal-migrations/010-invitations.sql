-- ═══════════════════════════════════════════════════════════════════════════
--  الهجرة 010 — بوابة الدعوات + تقييد النطاق البريدي (D)
--  المواصفات (توجيه المالك): روابط تسجيل للموظفين، بريد @aldeyabi حصراً، رفض أي
--  بريد خارجي/شخصي إلا ما يعتمده الأدمن مسبقاً (قائمة بيضاء).
--
--  • جدول portal_invitations: دعوات لمرة واحدة برمز عشوائي وصلاحية زمنية — يُدار
--    خادمياً فقط (لا سياسة RLS للعميل، كنمط portal_email_tokens المُثبَت). الأدمن
--    ينشئ الدعوة عبر /api/portal-invite، والموظف يُسجّل عبر /api/portal-register.
--  • إعدادات: allowed_email_domain='aldeyabi.com' + email_whitelist=[] (يضيف إليها
--    الأدمن العناوين الخارجية المعتمَدة مسبقاً). الخادم هو مرجع القرار (لا العميل).
--  • دالة portal_email_allowed(email): مرجع موحّد لقرار القبول (نطاق الشركة أو
--    قائمة بيضاء) — تُستعمل في الاختبار وأي تحقّق قاعدي.
--  idempotent. شغّلها في مشروع Supabase mwbjoysuybgbrvfrprex بعد 005–009.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS portal_invitations (
  id            BIGSERIAL PRIMARY KEY,
  token         TEXT UNIQUE NOT NULL,
  email         TEXT NOT NULL,
  display_name  TEXT,
  job_key       TEXT REFERENCES portal_jobs(key),
  department_id TEXT REFERENCES portal_departments(id),
  role          TEXT NOT NULL DEFAULT 'user',              -- user | admin
  status        TEXT NOT NULL DEFAULT 'pending',           -- pending | accepted | revoked | expired
  invited_by    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days'),
  accepted_at   TIMESTAMPTZ,
  accepted_user TEXT
);
CREATE INDEX IF NOT EXISTS idx_portal_inv_email  ON portal_invitations(lower(email));
CREATE INDEX IF NOT EXISTS idx_portal_inv_status ON portal_invitations(status);

-- تفعيل RLS بلا أي سياسة = مقفل كلياً على العميل (خادم/الدوال DEFINER فقط).
ALTER TABLE portal_invitations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON portal_invitations FROM authenticated, anon;
GRANT ALL ON portal_invitations TO service_role;
GRANT USAGE, SELECT ON SEQUENCE portal_invitations_id_seq TO service_role;

-- ═══ إعدادات النطاق البريدي (تُدمج في صف الإعدادات الموحّد دون مسح غيرها) ═══
INSERT INTO portal_settings(key, value) VALUES ('portal_settings', '{}'::jsonb)
  ON CONFLICT (key) DO NOTHING;
UPDATE portal_settings SET value = value || jsonb_build_object('allowed_email_domain','aldeyabi.com')
  WHERE key='portal_settings' AND NOT (value ? 'allowed_email_domain');
UPDATE portal_settings SET value = value || jsonb_build_object('email_whitelist','[]'::jsonb)
  WHERE key='portal_settings' AND NOT (value ? 'email_whitelist');

-- ═══ مرجع قرار قبول البريد: نطاق الشركة أو القائمة البيضاء (حصراً) ═══
CREATE OR REPLACE FUNCTION portal_email_allowed(p_email text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH s AS (SELECT value FROM portal_settings WHERE key='portal_settings')
  SELECT
    lower(trim(coalesce(p_email,''))) <> ''
    AND (
      -- نطاق الشركة
      lower(trim(p_email)) LIKE ('%@' || lower(coalesce((SELECT value->>'allowed_email_domain' FROM s), 'aldeyabi.com')))
      -- أو قائمة بيضاء يعتمدها الأدمن مسبقاً (تطابق حرفي، غير حسّاس لحالة الأحرف)
      OR EXISTS (
        SELECT 1 FROM s, jsonb_array_elements_text(coalesce((SELECT value->'email_whitelist' FROM s), '[]'::jsonb)) w
        WHERE lower(trim(w)) = lower(trim(p_email))
      )
    );
$fn$;
REVOKE ALL ON FUNCTION portal_email_allowed(text) FROM public;
GRANT EXECUTE ON FUNCTION portal_email_allowed(text) TO authenticated, service_role;

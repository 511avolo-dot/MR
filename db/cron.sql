-- ════════════════════════════════════════════════════════════════════════
--  المهام المجدولة (pg_cron) — تذكيرات وتقارير تلقائية (إشعارات داخل النظام)
-- ════════════════════════════════════════════════════════════════════════
--  المتطلّب: فعّل الإضافة من Supabase → Database → Extensions → pg_cron (Enable).
--  ثم نفّذ هذا الملف. كل المهام تُنشئ إشعارات في proc_notifications (بلا قنوات خارجية).
-- ════════════════════════════════════════════════════════════════════════

-- مولّد معرّف إشعار بسيط
CREATE OR REPLACE FUNCTION _ntf_id() RETURNS text LANGUAGE sql AS
$$ SELECT 'ntf_'||floor(extract(epoch from clock_timestamp())*1000)::bigint||'_'||floor(random()*100000)::int $$;

-- 1) تنبيه الوثائق المُقاربة على الانتهاء (خلال 30 يوماً) → للمدراء
CREATE OR REPLACE FUNCTION cron_document_expiry_alerts() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; adm record;
BEGIN
  FOR r IN
    SELECT legal_name_ar AS nm, cr_expiry_date AS exp, 'السجل التجاري' AS doc FROM proc_supplier_registrations
      WHERE status='approved' AND cr_expiry_date BETWEEN current_date AND current_date+30
    UNION ALL
    SELECT legal_name_ar, chamber_expiry, 'عضوية الغرفة' FROM proc_supplier_registrations
      WHERE status='approved' AND chamber_expiry BETWEEN current_date AND current_date+30
  LOOP
    FOR adm IN SELECT username FROM proc_users WHERE role='admin' AND active IS NOT FALSE LOOP
      INSERT INTO proc_notifications(id, recipient, type, title, body, link, read, created_at)
      SELECT _ntf_id(), adm.username, 'reminder', 'وثيقة قاربت الانتهاء',
             coalesce(r.nm,'مورد')||' — '||r.doc||' تنتهي في '||r.exp, 'registrations', false, now()
      WHERE NOT EXISTS (
        SELECT 1 FROM proc_notifications n WHERE n.recipient=adm.username AND n.type='reminder'
          AND n.body LIKE '%'||r.doc||' تنتهي في '||r.exp||'%' AND n.created_at > now()-interval '20 days');
    END LOOP;
  END LOOP;
END; $$;

-- 2) تنبيه RFQ المُقاربة على الإغلاق (خلال يومين) → لمُنشئها
CREATE OR REPLACE FUNCTION cron_rfq_deadline_alerts() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id, title, created_by, deadline FROM proc_rfqs
           WHERE status='open' AND deadline BETWEEN current_date AND current_date+2 LOOP
    IF r.created_by IS NOT NULL THEN
      INSERT INTO proc_notifications(id, recipient, type, title, body, link, read, created_at)
      SELECT _ntf_id(), r.created_by, 'reminder', 'RFQ يقارب الإغلاق',
             r.title||' — آخر موعد '||r.deadline, null, false, now()
      WHERE NOT EXISTS (SELECT 1 FROM proc_notifications n WHERE n.recipient=r.created_by
        AND n.body LIKE r.title||' — آخر موعد '||r.deadline AND n.created_at > now()-interval '2 days');
    END IF;
  END LOOP;
END; $$;

-- 3) ملخّص أسبوعي للمدراء (طلبات اعتماد معلّقة + نشاط الأسعار)
CREATE OR REPLACE FUNCTION cron_weekly_summary() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE adm record; v_pending int; v_prices int; v_msg text;
BEGIN
  SELECT count(*) INTO v_pending FROM proc_purchase_requests WHERE status='pending';
  SELECT count(*) INTO v_prices  FROM proc_history WHERE created_at > now()-interval '7 days';
  v_msg := 'آخر 7 أيام: '||coalesce(v_prices,0)||' سعر مُدخَل · '||coalesce(v_pending,0)||' طلب اعتماد معلّق';
  FOR adm IN SELECT username FROM proc_users WHERE role='admin' AND active IS NOT FALSE LOOP
    INSERT INTO proc_notifications(id, recipient, type, title, body, link, read, created_at)
    VALUES (_ntf_id(), adm.username, 'system', 'الملخّص الأسبوعي', v_msg, null, false, now());
  END LOOP;
END; $$;

-- ── جدولة المهام ──
-- (إن لزم، احذف الجدولة القديمة بنفس الاسم أولاً: SELECT cron.unschedule('...'); )
SELECT cron.schedule('doc-expiry-daily',  '0 6 * * *',  $$ SELECT cron_document_expiry_alerts(); $$);
SELECT cron.schedule('rfq-deadline-daily','0 7 * * *',  $$ SELECT cron_rfq_deadline_alerts(); $$);
SELECT cron.schedule('weekly-summary',    '0 7 * * 7',  $$ SELECT cron_weekly_summary(); $$);

-- ════════════════════════════════════════════════════════════════════════════
--  اختبار التصليب الأمني (الهجرة 030) + نموذج الصلاحيات — تأكيدات تُفشِل البناء.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_cnt int; v_bad text;
BEGIN
  -- S1: anon محجوب عن قراءة portal_outbox (منح مسحوب)
  IF has_table_privilege('anon','portal_outbox','SELECT') THEN RAISE EXCEPTION 'S1 fail: anon يقرأ portal_outbox'; END IF;
  RAISE NOTICE 'PASS S1 anon لا يقرأ الصادر';

  -- S2: anon محجوب عن تنفيذ دوال الصادر الخادمية
  IF has_function_privilege('anon','portal_outbox_claim(int)','EXECUTE')
     OR has_function_privilege('anon','portal_outbox_mark(bigint,boolean,text)','EXECUTE')
    THEN RAISE EXCEPTION 'S2 fail: anon ينفّذ دوال الصادر'; END IF;
  RAISE NOTICE 'PASS S2 anon لا ينفّذ الصادر';

  -- S3: دالة كتابة رئيسية — anon فقدت، authenticated احتفظت
  IF has_function_privilege('anon','portal_payment_transition(bigint,text,text,text,jsonb,text)','EXECUTE')
    THEN RAISE EXCEPTION 'S3 fail: anon ينفّذ portal_payment_transition'; END IF;
  IF NOT has_function_privilege('authenticated','portal_payment_transition(bigint,text,text,text,jsonb,text)','EXECUTE')
    THEN RAISE EXCEPTION 'S3 fail: authenticated فقد portal_payment_transition'; END IF;
  RAISE NOTICE 'PASS S3 anon=منع / authenticated=سماح';

  -- S4: عيّنات إضافية
  IF has_function_privilege('anon','portal_submit_offer(text,text,numeric,int,int,int,text,text,jsonb)','EXECUTE')
     OR has_function_privilege('anon','portal_award_split(text,jsonb,text)','EXECUTE')
    THEN RAISE EXCEPTION 'S4 fail: anon ينفّذ دالة كتابة'; END IF;
  IF NOT has_function_privilege('authenticated','portal_submit_offer(text,text,numeric,int,int,int,text,text,jsonb)','EXECUTE')
    THEN RAISE EXCEPTION 'S4 fail: authenticated فقد submit_offer'; END IF;
  RAISE NOTICE 'PASS S4 عيّنات إضافية';

  -- S5: لا دالة SECURITY DEFINER بلا search_path مثبَّت
  SELECT count(*), coalesce(string_agg(proname,', '),'') INTO v_cnt, v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname LIKE 'portal\_%' AND p.prosecdef
    AND (p.proconfig IS NULL OR NOT EXISTS(SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'));
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'S5 fail: % دالة DEFINER بلا search_path: %', v_cnt, v_bad; END IF;
  RAISE NOTICE 'PASS S5 كل DEFINER له search_path';

  -- S6: service_role يحتفظ بتنفيذ الصادر (لم نكسر الخادم)
  IF NOT has_function_privilege('service_role','portal_outbox_claim(int)','EXECUTE')
     OR NOT has_function_privilege('service_role','portal_outbox_mark(bigint,boolean,text)','EXECUTE')
    THEN RAISE EXCEPTION 'S6 fail: service_role فقد تنفيذ الصادر'; END IF;
  RAISE NOTICE 'PASS S6 service_role سليم';

  -- S7: عدم الكسر — المجموعة الخادمية حصراً هي الدوال المقصودة، والباقي للمستخدم
  SELECT count(*), coalesce(string_agg(proname,', ' ORDER BY proname),'') INTO v_cnt, v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname LIKE 'portal\_%'
    AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE');
  -- P0-parity (2026-08-02): سُحب EXECUTE عن authenticated من دوال المُشغِّلات (تُستدعى عبر
  -- المُشغِّل فقط) فانضمّت للمجموعة الخادمية. المجموعة الآن = الدوال الخادمية المقصودة + كل حُرّاس/
  -- مُشغِّلات البوابة (لا استدعاء مباشر عبر PostgREST). أي انحراف يُفشِل هذا التأكيد.
  IF v_bad <> 'portal_apply_perm_overrides, portal_approvals_guard, portal_audit_chain, portal_audit_immutable, portal_audit_write, portal_award_approvals_guard, portal_award_guard, portal_award_total, portal_beneficiary_iban_guard, portal_budget_committed, portal_budget_enforce, portal_build_chain, portal_config_guard, portal_contract_consumed, portal_contract_enforce, portal_create_token, portal_invoiced_total, portal_locked_guard, portal_open_direct_payment, portal_outbox_claim, portal_outbox_enqueue, portal_outbox_mark, portal_outbox_purge, portal_payments_guard, portal_perm_overrides_delta, portal_po_approvals_guard, portal_pr_transition_email, portal_recurring_run, portal_reqdoc_guard, portal_request_status_guard, portal_requests_notify, portal_returns_total, portal_run_sla, portal_set_due, portal_supplier_iban_guard, portal_supplier_token_request, portal_three_way_guard, portal_users_guard'
    THEN RAISE EXCEPTION 'S7 fail: المجموعة الخادمية غير متوقّعة (%): %', v_cnt, v_bad; END IF;
  RAISE NOTICE 'PASS S7 المجموعة الخادمية = 38 دالة (خادمية مقصودة + مساعدتا صلاحيات المستخدم + كل حُرّاس/مُشغِّلات البوابة server-only)، الباقي للمستخدم';

  -- S8: لا دالة كتابة في البوابة قابلة للتنفيذ من anon.
  --     خلفية: Supabase تمنح anon صلاحية صريحة على كل دالة جديدة (pg_default_acl)،
  --     و«REVOKE ... FROM public» لا يزيل منحاً صريحاً لدور — فيجب السحب من anon صراحةً.
  --     هذا التأكيد يمنع تكرار الارتداد صامتاً (اكتُشف حيّاً في portal_update_request).
  SELECT count(*), coalesce(string_agg(proname,', ' ORDER BY proname),'') INTO v_cnt, v_bad
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname LIKE 'portal\_%'
    AND has_function_privilege('anon', p.oid, 'EXECUTE')
    -- استثناء مقصود وموثّق (هجرة 047): بوابة المورّد الذاتية. المورّد لا حساب له،
    -- والرمز (43 محرفاً عشوائياً) هو هويّته. الدالتان SECURITY DEFINER محروستان
    -- بالرمز + مرحلة التسعير، ولا تكشفان إلا بنود ذلك الطلب (لا عروض منافسين
    -- ولا ميزانية ولا معتمِدين). أي دالة أخرى تظهر هنا = ارتداد يجب سحبه.
    AND p.proname NOT IN ('portal_supplier_rfq','portal_supplier_submit');
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'S8 fail: % دالة بوابة قابلة للتنفيذ من anon (اسحبها: REVOKE ALL ON FUNCTION ... FROM anon): %', v_cnt, v_bad;
  END IF;
  RAISE NOTICE 'PASS S8 لا دالة بوابة مكشوفة لـanon (عدا بوابة المورّد المقصودة)';

  RAISE NOTICE '════ SECURITY: 8/8 PASS ════';
END $t$;

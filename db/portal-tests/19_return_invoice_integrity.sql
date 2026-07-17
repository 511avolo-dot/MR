-- ════════════════════════════════════════════════════════════════════════════
--  اختبار الهجرة 039 — تكامل المرتجع (كمية ≤ المستلَم) + إلزام اسم مورد الفاتورة.
--  تأكيدات خفيفة (حارس انحدار CI): وجود المنطق في مصدر الدالة + ثبات التوقيع/الصلاحية.
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
BEGIN
  -- K1: portal_return_record يتحقّق من received_qty (لا إرجاع يتجاوز المستلَم)
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='public' AND p.proname='portal_return_record' AND p.prosrc LIKE '%received_qty%'
  ) THEN RAISE EXCEPTION 'K1 fail: portal_return_record لا يتحقّق من المستلَم (039 غير مطبَّقة)'; END IF;
  RAISE NOTICE 'PASS K1 039: المرتجع يتحقّق من المستلَم';

  -- K2: portal_invoice_record يُلزِم اسم المورد
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='public' AND p.proname='portal_invoice_record'
      AND p.prosrc LIKE '%اسم المورد مطلوب%'
  ) THEN RAISE EXCEPTION 'K2 fail: portal_invoice_record لا يُلزِم اسم المورد'; END IF;
  RAISE NOTICE 'PASS K2 039: الفاتورة تُلزِم اسم المورد';

  -- K3: التواقيع ثابتة (إضافة غير كاسرة) + الصلاحية للمستخدم المسجَّل باقية
  IF NOT has_function_privilege('authenticated', 'portal_return_record(text,jsonb,text,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'portal_invoice_record(text,text,numeric,text,date,text,text)', 'EXECUTE')
  THEN RAISE EXCEPTION 'K3 fail: صلاحية تنفيذ إحدى الدالتين فُقدت'; END IF;
  RAISE NOTICE 'PASS K3 039: التواقيع/الصلاحيات ثابتة';

  RAISE NOTICE '════ RETURN/INVOICE INTEGRITY (039): 3/3 PASS ════';
END $t$;

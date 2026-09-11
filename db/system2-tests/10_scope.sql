-- ════════════════════════════════════════════════════════════════════════════
--  تأكيدات نطاق موظفي الصيانة والتشغيل — db/system2-staff-scope.sql
-- ----------------------------------------------------------------------------
--  تُشغَّل بعد 00_stub.sql ثم الهجرة. كل تأكيد `RAISE EXCEPTION` عند الفشل،
--  والملف يعمل بـ`ON_ERROR_STOP=1` فيُفشِل البناء.
--  ⚠️ RLS **فعليّة**: كل فحص يمرّ بـ`SET ROLE authenticated` + هوية JWT —
--  لا فحص نصّيّ ولا استعلام بامتياز المالك (المالك يتجاوز RLS أصلاً).
-- ════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- ═══ البذور ═══
-- البذر بهوية الخادم: حارس `proc_users_guard` يرفض الكتابة بلا هوية مخوَّلة
-- (وهو ما نريده) — و`/api/admin-users` يبذر في الإنتاج بمفتاح الخدمة كذلك.
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);

INSERT INTO proc_users (username, display_name, email, role, permissions, active, scope_sectors) VALUES
  ('Abdullah','عبدالله','abdullah@aldeyabi.com','admin','{}'::jsonb, true, NULL),
  -- ⚠️ مستخدم قائم بصلاحيات مكتوبة صراحةً لكن **بلا** مفتاح can_view_amounts
  --    (هذا هو شكل صفوف الإنتاج اليوم) — حارس عدم الانحدار.
  ('Mostafa','مصطفى','supply@aldeyabi.com','user',
   '{"can_create_po":true,"can_edit_po":true,"can_export":true}'::jsonb, true, NULL),
  -- موظّف صيانة مُنطَّق: يستلم، ولا يرى المبالغ.
  ('saleh','صالح الميداني','saleh@aldeyabi.com','user',
   '{"can_receive_po":true,"can_view_amounts":false}'::jsonb, true,
   '["الصيانة والتشغيل"]'::jsonb),
  -- موظّف مُنطَّق بلا صلاحية استلام.
  ('nasser','ناصر','nasser@aldeyabi.com','user',
   '{"can_view_amounts":false}'::jsonb, true, '["الصيانة والتشغيل"]'::jsonb)
ON CONFLICT (username) DO NOTHING;

INSERT INTO proc_purchase_orders (po_number, sector, project, supplier, subtotal, vat, total, status, items) VALUES
  ('PO-A','الصيانة والتشغيل','برج الشمال','مورد أ', 1000, 150, 1150,'قيد التوريد',
   '[{"desc":"مضخة","unit":"عدد","qty":10,"price":100,"received_qty":0},
     {"desc":"صمام","unit":"عدد","qty":4,"price":50}]'::jsonb),
  ('PO-B','الإنشاءات','فرع الرياض','مورد ب', 2000, 300, 2300,'قيد التوريد',
   '[{"desc":"حديد","unit":"طن","qty":5,"price":400}]'::jsonb),
  ('PO-C','الصيانة والتشغيل','برج الشمال','مورد ج', 500, 75, 575,'ملغى', '[]'::jsonb),
  ('PO-D', NULL,'بلا قطاع','مورد د', 90, 13.5, 103.5,'قيد التوريد', '[]'::jsonb)
ON CONFLICT (po_number) DO NOTHING;

INSERT INTO proc_items (code, name) VALUES ('IT-1','صنف') ON CONFLICT DO NOTHING;
INSERT INTO proc_history (num, code, supplier, price, date) VALUES (1,'IT-1','مورد أ',100,'2026-01-01') ON CONFLICT DO NOTHING;
INSERT INTO proc_purchase_requests (id, title, sector, requester, status) VALUES
  ('PR-1','طلب صالح','الصيانة والتشغيل','saleh','draft'),
  ('PR-2','طلب آخر','الإنشاءات','Mostafa','draft')
ON CONFLICT (id) DO NOTHING;
INSERT INTO proc_pr_items (pr_id, seq, description, requested_qty, unit_price)
VALUES ('PR-1',1,'بند',1,10),('PR-2',1,'بند',1,10);
INSERT INTO proc_audit_log (username, action, entity_type) VALUES ('Abdullah','login','auth');

SELECT set_config('request.jwt.claims', '', false);

-- مساعد الانتحال
CREATE OR REPLACE FUNCTION t_as(p_email text) RETURNS void
LANGUAGE sql AS $$ SELECT set_config('request.jwt.claims', json_build_object('email',p_email)::text, false); $$;

DO $$
DECLARE n int; v jsonb; ok boolean; t text;
BEGIN
  -- ═══ SC1 — عدم انحدار: غير المُنطَّق يرى كل الأوامر ═══
  PERFORM t_as('supply@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_purchase_orders;
  IF n <> 4 THEN RAISE EXCEPTION 'SC1 فشل: غير المُنطَّق يرى % لا 4', n; END IF;
  RESET ROLE;

  -- ═══ SC2 — المُنطَّق يرى قطاعه فقط (والأمر بلا قطاع محجوب) ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_purchase_orders;
  IF n <> 2 THEN RAISE EXCEPTION 'SC2 فشل: المُنطَّق يرى % لا 2', n; END IF;
  SELECT count(*) INTO n FROM proc_purchase_orders WHERE po_number IN ('PO-B','PO-D');
  IF n <> 0 THEN RAISE EXCEPTION 'SC2 فشل: تسرّب أمر خارج القطاع'; END IF;
  RESET ROLE;

  -- ═══ SC3 — المُنطَّق يرى صفَّه وحده في proc_users (كان يقرأ كل الهاشات) ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_users;
  IF n <> 1 THEN RAISE EXCEPTION 'SC3 فشل: المُنطَّق يقرأ % صفّاً من المستخدمين', n; END IF;
  RESET ROLE;
  PERFORM t_as('supply@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_users;
  IF n <> 4 THEN RAISE EXCEPTION 'SC3 فشل: غير المُنطَّق يقرأ % لا 4', n; END IF;
  RESET ROLE;

  -- ═══ SC4 — المُنطَّق لا يكتب صفّ أمر الشراء إطلاقاً ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  UPDATE proc_purchase_orders SET notes = 'اختراق' WHERE po_number = 'PO-A';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'SC4 فشل: المُنطَّق عدّل % صفّاً', n; END IF;
  RESET ROLE;

  -- ═══ SC5 — الجداول حاملة الأسعار محجوبة عمّن لا يرى المبالغ ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_items;   IF n <> 0 THEN RAISE EXCEPTION 'SC5 فشل: الكتالوج مكشوف'; END IF;
  SELECT count(*) INTO n FROM proc_history; IF n <> 0 THEN RAISE EXCEPTION 'SC5 فشل: السجل السعري مكشوف'; END IF;
  RESET ROLE;

  -- ═══ SC6 — العرض يُصفّر المبالغ ويجرّد أسعار البنود للمُنطَّق ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_po_visible
   WHERE total IS NOT NULL OR subtotal IS NOT NULL OR vat IS NOT NULL;
  IF n <> 0 THEN RAISE EXCEPTION 'SC6 فشل: العرض سرّب مبلغاً'; END IF;
  SELECT count(*) INTO n FROM proc_po_visible v, jsonb_array_elements(v.items) e WHERE e ? 'price';
  IF n <> 0 THEN RAISE EXCEPTION 'SC6 فشل: سعر بند باقٍ في العرض'; END IF;
  SELECT count(*) INTO n FROM proc_po_visible v, jsonb_array_elements(v.items) e WHERE e ? 'qty';
  -- بندا PO-A فقط (PO-C بلا بنود، وPO-B/PO-D خارج النطاق)
  IF n <> 2 THEN RAISE EXCEPTION 'SC6 فشل: الكميات ضاعت مع الأسعار (%)', n; END IF;
  RESET ROLE;

  -- ═══ SC7 — ⚠️ حارس الانحدار الأهمّ: مستخدم قائم **بلا** مفتاح
  --      can_view_amounts يبقى يرى المبالغ (userDefault:true) ═══
  PERFORM t_as('supply@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT total INTO v FROM (SELECT to_jsonb(total) total FROM proc_po_visible WHERE po_number='PO-A') s;
  IF v IS NULL OR v = 'null'::jsonb THEN
    RAISE EXCEPTION 'SC7 فشل: مستخدم قائم بلا المفتاح فقد مبالغه — انحدار';
  END IF;
  SELECT count(*) INTO n FROM proc_po_visible v2, jsonb_array_elements(v2.items) e
   WHERE v2.po_number='PO-A' AND e ? 'price';
  IF n <> 2 THEN RAISE EXCEPTION 'SC7 فشل: أسعار البنود ضاعت عن مستخدم قائم'; END IF;
  RESET ROLE;

  -- ═══ SC8 — الاستلام داخل النطاق يعمل ويقصّ عند المتبقّي ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  -- 999 مطلوبة على بند كميّته 10 ⇒ تُقصّ إلى 10
  v := po_record_receipt('PO-A', '[{"idx":0,"qty":999}]'::jsonb, 'استلام ميدانيّ');
  IF (v ->> 'ok') <> 'true' THEN RAISE EXCEPTION 'SC8 فشل: الاستلام لم ينجح'; END IF;
  IF (v ->> 'complete')::boolean THEN RAISE EXCEPTION 'SC8 فشل: أُعلن اكتمال والبند الثاني لم يُستلَم'; END IF;
  IF (v ->> 'received')::numeric <> 10 THEN
    RAISE EXCEPTION 'SC8 فشل: القصّ عند المتبقّي لم يعمل (%)', v ->> 'received';
  END IF;
  RESET ROLE;
  SELECT status INTO t FROM proc_purchase_orders WHERE po_number='PO-A';
  IF t <> 'تسليم جزئي' THEN RAISE EXCEPTION 'SC8 فشل: الحالة % لا «تسليم جزئي»', t; END IF;
  SELECT count(*) INTO n FROM proc_audit_log WHERE action='receive' AND entity_id='PO-A';
  IF n <> 1 THEN RAISE EXCEPTION 'SC8 فشل: لا أثر تدقيق للاستلام'; END IF;

  -- ═══ SC9 — استلام أمر خارج النطاق مرفوض ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  ok := false;
  BEGIN PERFORM po_record_receipt('PO-B', '[{"idx":0,"qty":1}]'::jsonb, NULL);
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'SC9 فشل: استُلم أمر من قطاع آخر'; END IF;
  -- والأمر الملغى مرفوض كذلك
  ok := false;
  BEGIN PERFORM po_record_receipt('PO-C', '[{"idx":0,"qty":1}]'::jsonb, NULL);
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'SC9 فشل: استُلم أمر ملغى'; END IF;
  RESET ROLE;

  -- ═══ SC10 — بلا صلاحية استلام يُرفض ═══
  PERFORM t_as('nasser@aldeyabi.com'); SET LOCAL ROLE authenticated;
  ok := false;
  BEGIN PERFORM po_record_receipt('PO-A', '[{"idx":1,"qty":1}]'::jsonb, NULL);
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'SC10 فشل: استلام بلا صلاحية'; END IF;
  RESET ROLE;

  -- ═══ SC11 — ⚠️ لا يوسّع الموظّف نطاقه بنفسه (ثغرة الحارس المسدودة) ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  ok := false;
  BEGIN
    UPDATE proc_users SET scope_sectors = '["الصيانة والتشغيل","الإنشاءات"]'::jsonb
     WHERE username = 'saleh';
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  RESET ROLE;
  SELECT count(*) INTO n FROM proc_users
   WHERE username='saleh' AND scope_sectors = '["الصيانة والتشغيل"]'::jsonb;
  IF n <> 1 THEN RAISE EXCEPTION 'SC11 فشل: الموظّف وسّع نطاقه بنفسه'; END IF;

  -- ═══ SC12 — فشل مغلق: حساب Auth بلا صفّ في proc_users لا يرى شيئاً ═══
  PERFORM t_as('ghost@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_purchase_orders;
  IF n <> 0 THEN RAISE EXCEPTION 'SC12 فشل: مجهول يرى % أمراً', n; END IF;
  RESET ROLE;

  -- ═══ SC13 — التعليق: يعمل داخل النطاق ويُرفض خارجه ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  PERFORM po_add_comment('PO-A', 'المضخة وصلت والصمام متأخر');
  ok := false;
  BEGIN PERFORM po_add_comment('PO-B', 'خارج نطاقي'); EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'SC13 فشل: علّق على أمر خارج نطاقه'; END IF;
  ok := false;
  BEGIN PERFORM po_add_comment('PO-A', '   '); EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'SC13 فشل: قُبلت ملاحظة فارغة'; END IF;
  RESET ROLE;
  SELECT jsonb_array_length(comments) INTO n FROM proc_purchase_orders WHERE po_number='PO-A';
  IF n <> 1 THEN RAISE EXCEPTION 'SC13 فشل: التعليق لم يُحفظ'; END IF;

  -- ═══ SC14 — سجلّ التدقيق محجوب عن المُنطَّق، مكشوف لغيره ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_audit_log;
  IF n <> 0 THEN RAISE EXCEPTION 'SC14 فشل: المُنطَّق يقرأ سجلّ التدقيق'; END IF;
  RESET ROLE;
  PERFORM t_as('supply@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_audit_log;
  IF n = 0 THEN RAISE EXCEPTION 'SC14 فشل: غير المُنطَّق فقد سجلّ التدقيق — انحدار'; END IF;
  RESET ROLE;

  -- ═══ SC15 — طلبات الشراء: طلباته وطلبات قطاعه فقط ═══
  PERFORM t_as('saleh@aldeyabi.com'); SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM proc_purchase_requests;
  IF n <> 1 THEN RAISE EXCEPTION 'SC15 فشل: يرى % طلباً لا 1', n; END IF;
  SELECT count(*) INTO n FROM proc_pr_items;
  IF n <> 1 THEN RAISE EXCEPTION 'SC15 فشل: بنود طلب غيره مكشوفة (%)', n; END IF;
  -- يُنشئ طلباً باسمه
  INSERT INTO proc_purchase_requests (id,title,sector,requester,status)
  VALUES ('PR-3','طلب جديد','الصيانة والتشغيل','saleh','draft');
  -- ولا ينتحل غيره
  ok := false;
  BEGIN INSERT INTO proc_purchase_requests (id,title,sector,requester,status)
        VALUES ('PR-4','انتحال','الصيانة والتشغيل','Mostafa','draft');
  EXCEPTION WHEN OTHERS THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'SC15 فشل: أنشأ طلباً باسم غيره'; END IF;
  RESET ROLE;

  -- ═══ SC16 — عدم انحدار شامل: غير المُنطَّق يكتب كما كان ═══
  PERFORM t_as('supply@aldeyabi.com'); SET LOCAL ROLE authenticated;
  UPDATE proc_purchase_orders SET notes='تعديل عاديّ' WHERE po_number='PO-B';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'SC16 فشل: غير المُنطَّق لم يعد يكتب — انحدار'; END IF;
  SELECT count(*) INTO n FROM proc_items;
  IF n <> 1 THEN RAISE EXCEPTION 'SC16 فشل: غير المُنطَّق فقد الكتالوج — انحدار'; END IF;
  RESET ROLE;

  RAISE NOTICE 'كل تأكيدات النطاق نجحت (SC1–SC16)';
END $$;

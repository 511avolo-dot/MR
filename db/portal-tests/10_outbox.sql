-- ════════════════════════════════════════════════════════════════════════════
--  اختبار صندوق الصادر المعامَلاتي (الهجرة 029) — تأكيدات تُفشِل البناء عند الخطأ.
--  يُشغَّل كـpostgres (session_user='postgres' يجتاز حارس دوال الخادم).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_id bigint; v_id2 bigint; v_status text; v_att int; v_cnt int; v_next timestamptz; v_res jsonb; v_purged int;
BEGIN
  -- تنظيف أي أثر سابق (تشغيل متكرّر آمن)
  DELETE FROM portal_outbox WHERE ntf_id LIKE 'ntf_ci_%';
  DELETE FROM portal_notifications WHERE id LIKE 'ntf_ci_%';

  -- T1: المُشغِّل المعامَلاتي يلتقط الإشعار
  INSERT INTO portal_notifications(id,recipient,type,title,body,link)
    VALUES ('ntf_ci_1','mgr1','pending','طلب بانتظار اعتمادك','REQ-1','inbox');
  SELECT count(*) INTO v_cnt FROM portal_outbox WHERE ntf_id='ntf_ci_1';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'T1 fail: expected 1 outbox row, got %', v_cnt; END IF;
  SELECT status, attempts INTO v_status, v_att FROM portal_outbox WHERE ntf_id='ntf_ci_1';
  IF v_status <> 'pending' OR v_att <> 0 THEN RAISE EXCEPTION 'T1 fail: status=% attempts=%', v_status, v_att; END IF;
  RAISE NOTICE 'PASS T1 التقاط معامَلاتي';

  -- T2: idempotency (ntf_id فريد)
  INSERT INTO portal_outbox(ntf_id,recipient,title) VALUES('ntf_ci_1','mgr1','dup') ON CONFLICT (ntf_id) DO NOTHING;
  SELECT count(*) INTO v_cnt FROM portal_outbox WHERE ntf_id='ntf_ci_1';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'T2 fail: duplicate created (%)', v_cnt; END IF;
  RAISE NOTICE 'PASS T2 idempotency';

  -- T3: claim يسحب ويعلّم processing + attempts=1
  SELECT id INTO v_id FROM portal_outbox_claim(10);
  IF v_id IS NULL THEN RAISE EXCEPTION 'T3 fail: claim returned nothing'; END IF;
  SELECT status, attempts INTO v_status, v_att FROM portal_outbox WHERE id=v_id;
  IF v_status <> 'processing' OR v_att <> 1 THEN RAISE EXCEPTION 'T3 fail: status=% attempts=%', v_status, v_att; END IF;
  RAISE NOTICE 'PASS T3 claim/processing';

  -- T4: claim فوري ثانٍ لا يعيد نفس الصف (ليس pending)
  IF EXISTS (SELECT 1 FROM portal_outbox_claim(10)) THEN RAISE EXCEPTION 'T4 fail: double-claim'; END IF;
  RAISE NOTICE 'PASS T4 لا سحب مزدوج';

  -- T5: mark فشل ⇒ إعادة جدولة بتراجع أُسّي (pending مستقبلاً، attempts محفوظ)
  v_res := portal_outbox_mark(v_id, false, 'resend 502');
  SELECT status, next_attempt_at INTO v_status, v_next FROM portal_outbox WHERE id=v_id;
  IF v_status <> 'pending' OR v_next <= now() OR (SELECT last_error FROM portal_outbox WHERE id=v_id) IS NULL
    THEN RAISE EXCEPTION 'T5 fail: status=% next=%', v_status, v_next; END IF;
  RAISE NOTICE 'PASS T5 تراجع أُسّي (retry بعد ~% دقيقة)', round(extract(epoch from v_next-now())/60);

  -- T6: dead-letter بعد بلوغ الحد
  UPDATE portal_outbox SET attempts=max_attempts, status='processing' WHERE id=v_id;
  v_res := portal_outbox_mark(v_id, false, 'permanent');
  SELECT status INTO v_status FROM portal_outbox WHERE id=v_id;
  IF v_status <> 'dead' THEN RAISE EXCEPTION 'T6 fail: status=%', v_status; END IF;
  RAISE NOTICE 'PASS T6 dead-letter';

  -- T7: mark نجاح ⇒ sent + sent_at
  INSERT INTO portal_notifications(id,recipient,type,title,body,link)
    VALUES ('ntf_ci_2','fin1','payment_pending','صرف بانتظارك','REQ-2','inbox');
  SELECT id INTO v_id2 FROM portal_outbox_claim(10);
  IF v_id2 IS NULL THEN RAISE EXCEPTION 'T7 fail: claim empty'; END IF;
  v_res := portal_outbox_mark(v_id2, true, NULL);
  SELECT status INTO v_status FROM portal_outbox WHERE id=v_id2;
  IF v_status <> 'sent' OR (SELECT sent_at FROM portal_outbox WHERE id=v_id2) IS NULL
    THEN RAISE EXCEPTION 'T7 fail: status=%', v_status; END IF;
  RAISE NOTICE 'PASS T7 sent';

  -- T8: purge يحذف المُرسَل القديم فقط
  UPDATE portal_outbox SET sent_at = now() - interval '40 days' WHERE id=v_id2;
  v_purged := portal_outbox_purge(30);
  IF v_purged < 1 OR EXISTS (SELECT 1 FROM portal_outbox WHERE id=v_id2)
    THEN RAISE EXCEPTION 'T8 fail: purged=%', v_purged; END IF;
  RAISE NOTICE 'PASS T8 purge (حذف % مُرسَلاً قديماً)', v_purged;

  -- تنظيف
  DELETE FROM portal_outbox WHERE ntf_id LIKE 'ntf_ci_%';
  DELETE FROM portal_notifications WHERE id LIKE 'ntf_ci_%';
  RAISE NOTICE '════ OUTBOX: 8/8 PASS ════';
END $t$;

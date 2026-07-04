-- ═══════════════════════════════════════════════════════════════════════════
--  حذف كامل للبيانات التجريبية — بوابة الطلبات والموافقات (النظام 3)
--  شغّله في Supabase → SQL Editor (كـ postgres) → Run.
--  يحذف كل مستخدم/مورد/طلب تجريبي (@demo.aldeyabi) وكل سجلّاته المرتبطة،
--  ويعيد مديري القسمين إلى الفراغ. لا يمسّ أي بيانات حقيقية أو بذوراً.
--  (يعطّل حارس «تدقيق للإضافة فقط» مؤقتاً لحذف سجلّات تدقيق التجربة، ثم يعيده.)
-- ═══════════════════════════════════════════════════════════════════════════

-- سجلّات التدقيق مقفلة ضد الحذف بحارس مطلق — نعطّله مؤقتاً (SQL Editor = postgres)
ALTER TABLE portal_audit DISABLE TRIGGER trg_portal_audit_immutable;

-- تعريف مجموعة الطلبات التجريبية = ما أنشأه مستخدمون تجريبيون
-- (الحذف من الأبناء نحو الأصل — ترتيب آمن للمفاتيح الأجنبية)
DELETE FROM portal_receipts        WHERE request_id IN (SELECT id FROM portal_requests WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi'));
DELETE FROM portal_payments        WHERE request_id IN (SELECT id FROM portal_requests WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi'));
DELETE FROM portal_award_approvals WHERE request_id IN (SELECT id FROM portal_requests WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi'));
DELETE FROM portal_award           WHERE request_id IN (SELECT id FROM portal_requests WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi'));
DELETE FROM portal_offers          WHERE request_id IN (SELECT id FROM portal_requests WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi'));
DELETE FROM portal_approvals       WHERE request_id IN (SELECT id FROM portal_requests WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi'));
DELETE FROM portal_request_items   WHERE request_id IN (SELECT id FROM portal_requests WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi'));
DELETE FROM portal_email_tokens    WHERE request_id IN (SELECT id FROM portal_requests WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi'));
DELETE FROM portal_audit           WHERE request_id IN (SELECT id FROM portal_requests WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi'));

-- إشعارات المستخدمين التجريبيين
DELETE FROM portal_notifications   WHERE recipient IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi');

-- الطلبات نفسها
DELETE FROM portal_requests        WHERE requester IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi');

-- الموردون التجريبيون (بأرقام السجل التجريبية)
DELETE FROM portal_suppliers       WHERE cr IN ('1010111111','1010222222','1010333333');

-- إعادة مديري القسمين إلى الفراغ (فقط إن كانوا مستخدمين تجريبيين)
UPDATE portal_departments SET manager_user=NULL WHERE manager_user IN (SELECT username FROM portal_users WHERE email LIKE '%@demo.aldeyabi');

-- المستخدمون التجريبيون (أخيراً — بعد أن لم يعد يشير إليهم شيء)
DELETE FROM portal_users           WHERE email LIKE '%@demo.aldeyabi';

-- إعادة تفعيل حارس التدقيق
ALTER TABLE portal_audit ENABLE TRIGGER trg_portal_audit_immutable;

-- تحقّق (يجب أن تكون كل الأعداد صفراً)
SELECT
  (SELECT count(*) FROM portal_users     WHERE email LIKE '%@demo.aldeyabi') AS demo_users_left,
  (SELECT count(*) FROM portal_suppliers WHERE cr IN ('1010111111','1010222222','1010333333')) AS demo_suppliers_left,
  (SELECT count(*) FROM portal_requests  WHERE requester LIKE 'demo\_%') AS demo_requests_left;

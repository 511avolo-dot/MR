-- CI-only pre-migration fixture: P0-1k must return this runnable direct-expense
-- chain because it has no verified payment_request evidence.
\set ON_ERROR_STOP on

DO $fixture$
BEGIN
  PERFORM set_config('app.portal_transition', '1', true);
  INSERT INTO portal_departments(id,name_ar,sector,active)
  VALUES ('QA-P0K','P0K','P0K',true)
  ON CONFLICT (id) DO UPDATE SET active=true;

  INSERT INTO portal_users(username,email,display_name,department_id,role,permissions,active)
  VALUES ('p0k_owner','p0k_owner@aldeyabi.com','P0K Owner','QA-P0K','user','{"can_create_direct_expense":true}'::jsonb,true)
  ON CONFLICT (username) DO UPDATE SET
    email=excluded.email,department_id=excluded.department_id,role=excluded.role,
    permissions=excluded.permissions,active=true;

  DELETE FROM portal_requests WHERE id='REQ-P0K-INFLIGHT';
  INSERT INTO portal_requests(
    id,title,department_id,requester,requester_name,est_total,status,phase,
    current_seq,created_by,req_type,expense_method,expense_details
  ) VALUES (
    'REQ-P0K-INFLIGHT','P0K invalid in-flight','QA-P0K','p0k_owner','P0K Owner',100,
    'in_review','disbursement',1,'p0k_owner','direct_expense','bank','{}'::jsonb
  );
  INSERT INTO portal_approvals(
    request_id,cycle,seq,stage_label,resolver,role_key,decision
  ) VALUES (
    'REQ-P0K-INFLIGHT','disbursement',1,'P0K pending stage','role','can_approve_disbursement','pending'
  );
  PERFORM set_config('app.portal_transition', '0', true);
END;
$fixture$;

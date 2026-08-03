-- Pre-P0-1i fixture: 062 allowed the same caller-trusted storage key on more
-- than one document.  P0-1i must quarantine this state before adding UNIQUE.
\set ON_ERROR_STOP on

SELECT set_config('app.portal_transition', '1', false);

INSERT INTO portal_departments(id,name_ar,sector,active)
VALUES ('QA-P0L','QA P0-1l','QA',true)
ON CONFLICT (id) DO UPDATE SET active=true;

INSERT INTO portal_users(username,email,display_name,department_id,role,permissions,active)
VALUES ('p0l_owner','p0l_owner@aldeyabi.com','P0L Owner','QA-P0L','user','{"can_create":true,"can_create_direct_expense":true}'::jsonb,true)
ON CONFLICT (username) DO UPDATE SET
  email=excluded.email, department_id=excluded.department_id,
  permissions=excluded.permissions, active=true;

INSERT INTO portal_requests(
  id,title,department_id,requester,requester_name,status,phase,created_by,req_type
) VALUES (
  'REQ-P0L-DUP','P0L duplicate legacy evidence','QA-P0L','p0l_owner','P0L Owner',
  'draft','need','p0l_owner','purchase'
) ON CONFLICT (id) DO NOTHING;

INSERT INTO portal_request_documents(
  request_id,document_type,title,storage_key,mime_type,uploaded_by,active
) VALUES
  ('REQ-P0L-DUP','memo','Duplicate A','legacy/reused-object.pdf','application/pdf','p0l_owner',true),
  ('REQ-P0L-DUP','memo','Duplicate B','legacy/reused-object.pdf','application/pdf','p0l_owner',true);

SELECT set_config('app.portal_transition', '0', false);

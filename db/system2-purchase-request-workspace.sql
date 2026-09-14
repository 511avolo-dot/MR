-- =============================================================================
-- System 2 · Purchase-request workspace (launch model)
-- Apply after:
--   pr-portal.sql
--   system2-request-flow.sql
--   system2-request-tracking.sql
--   system2-staff-scope.sql
--   system2-scoped-least-privilege.sql
--   system2-request-numbering.sql
--
-- This migration supersedes the tracking-only operating decision dated
-- 2026-09-10. The current operating decision requires two electronic gates:
-- maintenance-manager approval, then procurement-manager authorization to price.
-- It is additive and keeps the legacy po_number column readable during rollout.
-- =============================================================================

BEGIN;

-- ───────────────────────────── Access model ────────────────────────────────
CREATE TABLE IF NOT EXISTS proc_pr_permission_profiles (
  profile_key    text PRIMARY KEY,
  name_ar        text NOT NULL,
  description_ar text,
  permissions    jsonb NOT NULL DEFAULT '{}'::jsonb,
  system_defined boolean NOT NULL DEFAULT false,
  active         boolean NOT NULL DEFAULT true,
  sort_order     integer NOT NULL DEFAULT 100,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT proc_pr_permission_profiles_object CHECK (jsonb_typeof(permissions) = 'object')
);

ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS pr_profile_key text;
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS pr_permission_overrides jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE proc_users ADD COLUMN IF NOT EXISTS pr_department_ids text[] NOT NULL DEFAULT '{}'::text[];

INSERT INTO proc_pr_permission_profiles
  (profile_key, name_ar, description_ar, permissions, system_defined, sort_order)
VALUES
  ('requester', 'مقدّم طلب', 'ينشئ الطلبات ويتابع طلباته ومناقشاتها.',
   '{"pr_create":true,"pr_view_own":true,"pr_comment":true,"pr_upload_attachments":true,"pr_print":true}'::jsonb, true, 10),
  ('maintenance_manager', 'مدير الصيانة والتشغيل', 'يرى طلبات إدارته ويعتمد الحاجة أو يعيدها.',
   '{"pr_create":true,"pr_view_own":true,"pr_view_department":true,"pr_comment":true,"pr_upload_attachments":true,"pr_print":true,"pr_approve_maintenance":true}'::jsonb, true, 20),
  ('procurement_officer', 'موظف مشتريات', 'يتابع التسعير والمناقشات ويربط أوامر الشراء ضمن الصلاحية.',
   '{"pr_view_all":true,"pr_comment":true,"pr_upload_attachments":true,"pr_print":true,"pr_manage_pricing":true,"pr_link_purchase_orders":true,"pr_view_financials":true}'::jsonb, true, 30),
  ('procurement_manager', 'مدير المشتريات', 'يأذن ببدء التسعير ويدير التنفيذ والربط والتقارير.',
   '{"pr_view_all":true,"pr_comment":true,"pr_upload_attachments":true,"pr_print":true,"pr_authorize_pricing":true,"pr_manage_pricing":true,"pr_link_purchase_orders":true,"pr_view_financials":true,"pr_manage_workflows":true}'::jsonb, true, 40),
  ('module_admin', 'مدير موديل طلبات الشراء', 'يدير الصلاحيات والإعدادات ويملك كامل صلاحيات الموديل.',
   '{"pr_create":true,"pr_view_own":true,"pr_view_department":true,"pr_view_all":true,"pr_comment":true,"pr_upload_attachments":true,"pr_print":true,"pr_approve_maintenance":true,"pr_authorize_pricing":true,"pr_manage_pricing":true,"pr_link_purchase_orders":true,"pr_view_financials":true,"pr_manage_workflows":true,"pr_manage_users":true}'::jsonb, true, 50)
ON CONFLICT (profile_key) DO UPDATE SET
  name_ar = EXCLUDED.name_ar,
  description_ar = EXCLUDED.description_ar,
  permissions = EXCLUDED.permissions,
  system_defined = true,
  sort_order = EXCLUDED.sort_order,
  updated_at = now();

UPDATE proc_users
SET pr_profile_key = CASE
  WHEN role = 'admin' THEN 'module_admin'
  WHEN coalesce(permissions->>'can_approve_l2','false') = 'true' THEN 'procurement_manager'
  WHEN coalesce(permissions->>'can_manage_rfq','false') = 'true' THEN 'procurement_officer'
  WHEN coalesce(permissions->>'can_approve_l1','false') = 'true' THEN 'maintenance_manager'
  ELSE 'requester'
END
WHERE pr_profile_key IS NULL;

-- Preserve the live System 2 rule during the one-time upgrade: an existing
-- unscoped office account with no explicit amount flag already sees amounts.
-- Recording that grant prevents a silent regression, while explicit denials
-- and sector-scoped accounts remain denied.
UPDATE proc_users
SET pr_permission_overrides = coalesce(pr_permission_overrides,'{}'::jsonb)
                              || '{"pr_view_financials":true}'::jsonb
WHERE coalesce(active,true)
  AND coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(scope_sectors)='array' THEN scope_sectors ELSE '[]'::jsonb END),0)=0
  AND NOT (coalesce(permissions,'{}'::jsonb) ? 'can_view_amounts')
  AND NOT (coalesce(pr_permission_overrides,'{}'::jsonb) ? 'pr_view_financials');

-- A sector-scoped legacy account used explicit opt-in. Mapping every account
-- to the requester profile must not silently grant missing field abilities.
UPDATE proc_users
SET pr_permission_overrides = coalesce(pr_permission_overrides,'{}'::jsonb)
  || CASE WHEN NOT (coalesce(permissions,'{}'::jsonb) ? 'can_create_pr')
           AND NOT (coalesce(pr_permission_overrides,'{}'::jsonb) ? 'pr_create')
          THEN '{"pr_create":false}'::jsonb ELSE '{}'::jsonb END
  || CASE WHEN NOT (coalesce(permissions,'{}'::jsonb) ? 'can_upload_docs')
           AND NOT (coalesce(pr_permission_overrides,'{}'::jsonb) ? 'pr_upload_attachments')
          THEN '{"pr_upload_attachments":false}'::jsonb ELSE '{}'::jsonb END
  || CASE WHEN NOT (coalesce(permissions,'{}'::jsonb) ? 'can_comment')
           AND NOT (coalesce(pr_permission_overrides,'{}'::jsonb) ? 'pr_comment')
          THEN '{"pr_comment":false}'::jsonb ELSE '{}'::jsonb END
  || CASE WHEN NOT (coalesce(permissions,'{}'::jsonb) ? 'can_view_amounts')
           AND NOT (coalesce(pr_permission_overrides,'{}'::jsonb) ? 'pr_view_financials')
          THEN '{"pr_view_financials":false}'::jsonb ELSE '{}'::jsonb END
WHERE coalesce(active,true)
  AND coalesce(jsonb_array_length(CASE WHEN jsonb_typeof(scope_sectors)='array' THEN scope_sectors ELSE '[]'::jsonb END),0)>0;

ALTER TABLE proc_users ALTER COLUMN pr_profile_key SET DEFAULT 'requester';

CREATE OR REPLACE FUNCTION pr_effective_permissions(p_username text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH me AS (
    SELECT u.*
    FROM proc_users u
    WHERE lower(u.username) = lower(coalesce(p_username, proc_me()))
      AND coalesce(u.active, true)
    LIMIT 1
  ), profile AS (
    SELECT p.permissions
    FROM me JOIN proc_pr_permission_profiles p ON p.profile_key = me.pr_profile_key
    WHERE p.active
  ), legacy AS (
    SELECT jsonb_strip_nulls(jsonb_build_object(
      'pr_create', CASE WHEN me.permissions ? 'can_create_pr' THEN (me.permissions->>'can_create_pr')::boolean ELSE NULL END,
      'pr_view_own', true,
      'pr_comment', CASE WHEN me.permissions ? 'can_comment' THEN (me.permissions->>'can_comment')::boolean ELSE NULL END,
      'pr_upload_attachments', CASE WHEN me.permissions ? 'can_upload_docs' THEN (me.permissions->>'can_upload_docs')::boolean ELSE NULL END,
      'pr_view_department', CASE WHEN me.permissions ? 'can_approve_l1' THEN (me.permissions->>'can_approve_l1')::boolean ELSE NULL END,
      'pr_view_all', CASE WHEN me.permissions ? 'can_manage_rfq' THEN (me.permissions->>'can_manage_rfq')::boolean ELSE NULL END,
      'pr_approve_maintenance', CASE WHEN me.permissions ? 'can_approve_l1' THEN (me.permissions->>'can_approve_l1')::boolean ELSE NULL END,
      'pr_authorize_pricing', CASE WHEN me.permissions ? 'can_approve_l2' THEN (me.permissions->>'can_approve_l2')::boolean ELSE NULL END,
      'pr_manage_pricing', CASE WHEN me.permissions ? 'can_manage_rfq' THEN (me.permissions->>'can_manage_rfq')::boolean ELSE NULL END,
      'pr_link_purchase_orders', CASE WHEN me.permissions ? 'can_manage_rfq' THEN (me.permissions->>'can_manage_rfq')::boolean ELSE NULL END,
      'pr_view_financials', CASE WHEN me.permissions ? 'can_view_amounts' THEN (me.permissions->>'can_view_amounts')::boolean ELSE NULL END,
      'pr_manage_users', CASE WHEN me.permissions ? 'can_manage_users' THEN (me.permissions->>'can_manage_users')::boolean ELSE NULL END
    )) AS permissions FROM me
  )
  SELECT CASE WHEN EXISTS (SELECT 1 FROM me WHERE role='admin')
    THEN (SELECT permissions FROM proc_pr_permission_profiles WHERE profile_key='module_admin')
    ELSE coalesce((SELECT permissions FROM profile),'{}'::jsonb)
         || coalesce((SELECT permissions FROM legacy),'{}'::jsonb)
         || coalesce((SELECT pr_permission_overrides FROM me),'{}'::jsonb)
  END;
$fn$;

CREATE OR REPLACE FUNCTION pr_has_module_perm(p_permission text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT coalesce((pr_effective_permissions()->>p_permission)::boolean, false);
$fn$;

-- Keep the legacy helper as a compatibility bridge for older code paths.
CREATE OR REPLACE FUNCTION pr_has_perm(p_key text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT CASE p_key
    WHEN 'can_create_pr'   THEN pr_has_module_perm('pr_create')
    WHEN 'can_upload_docs' THEN pr_has_module_perm('pr_upload_attachments')
    WHEN 'can_comment'     THEN pr_has_module_perm('pr_comment')
    WHEN 'can_approve_l1'  THEN pr_has_module_perm('pr_approve_maintenance')
    WHEN 'can_approve_l2'  THEN pr_has_module_perm('pr_authorize_pricing')
    WHEN 'can_manage_rfq'  THEN pr_has_module_perm('pr_manage_pricing')
    WHEN 'can_manage_users'THEN pr_has_module_perm('pr_manage_users')
    WHEN 'can_view_amounts'THEN pr_has_module_perm('pr_view_financials')
    ELSE coalesce((pr_effective_permissions()->>p_key)::boolean, false)
  END;
$fn$;

-- Authorization columns join the write guard in the same transaction that
-- creates them. This is intentionally installed after the one-time backfill:
-- migrations run without an end-user JWT, while no intermediate state becomes
-- visible before COMMIT. Once installed, the broad users UPDATE policy can
-- continue serving harmless profile activity without exposing an escalation path.
CREATE OR REPLACE FUNCTION proc_users_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF pr_is_service() THEN RETURN COALESCE(NEW, OLD); END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.permissions             IS NOT DISTINCT FROM OLD.permissions
     AND NEW.role                    IS NOT DISTINCT FROM OLD.role
     AND NEW.active                  IS NOT DISTINCT FROM OLD.active
     AND NEW.is_away                 IS NOT DISTINCT FROM OLD.is_away
     AND NEW.delegate_to             IS NOT DISTINCT FROM OLD.delegate_to
     AND NEW.username                IS NOT DISTINCT FROM OLD.username
     AND NEW.email                   IS NOT DISTINCT FROM OLD.email
     AND NEW.password_hash           IS NOT DISTINCT FROM OLD.password_hash
     AND NEW.scope_sectors           IS NOT DISTINCT FROM OLD.scope_sectors
     AND NEW.department_id           IS NOT DISTINCT FROM OLD.department_id
     AND NEW.manager_user            IS NOT DISTINCT FROM OLD.manager_user
     AND NEW.requested_role          IS NOT DISTINCT FROM OLD.requested_role
     AND NEW.pr_profile_key          IS NOT DISTINCT FROM OLD.pr_profile_key
     AND NEW.pr_permission_overrides IS NOT DISTINCT FROM OLD.pr_permission_overrides
     AND NEW.pr_department_ids       IS NOT DISTINCT FROM OLD.pr_department_ids
  THEN RETURN NEW; END IF;

  IF pr_has_perm('can_manage_users') THEN RETURN COALESCE(NEW, OLD); END IF;
  RAISE EXCEPTION 'تعديل المستخدمين أو صلاحياتهم يتطلّب صلاحية «إدارة المستخدمين»';
END $fn$;

DROP TRIGGER IF EXISTS trg_proc_users_guard ON proc_users;
CREATE TRIGGER trg_proc_users_guard BEFORE INSERT OR UPDATE OR DELETE ON proc_users
  FOR EACH ROW EXECUTE FUNCTION proc_users_guard();

-- ───────────────────────── Request state model ─────────────────────────────
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS workflow_state text NOT NULL DEFAULT 'draft';
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS current_owner text;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS submitted_at timestamptz;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS maintenance_approved_by text;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS maintenance_approved_at timestamptz;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS pricing_authorized_by text;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS pricing_authorized_at timestamptz;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS closed_by text;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS closed_at timestamptz;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS revision integer NOT NULL DEFAULT 1;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS return_reason text;

-- Compatibility with the RFQ award-approval panel already hosted by index.html.
-- These rows share the historical table but use an `apr_` id and never enter the
-- maintenance request state machine.
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS supplier text;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS amount numeric DEFAULT 0;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS details jsonb DEFAULT '{}'::jsonb;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS requested_by text;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS requested_by_name text;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS required_level integer DEFAULT 1;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS decided_by text;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS decided_at timestamptz;
ALTER TABLE proc_purchase_requests ADD COLUMN IF NOT EXISTS decision_note text;
ALTER TABLE proc_purchase_requests ALTER COLUMN requested_by DROP NOT NULL;
UPDATE proc_purchase_requests SET workflow_state=CASE status
  WHEN 'pending' THEN 'award_review'
  WHEN 'approved' THEN 'award_approved'
  WHEN 'rejected' THEN 'award_rejected'
  ELSE workflow_state END
WHERE requested_by IS NOT NULL AND coalesce(requester,'')='' AND workflow_state='draft';

ALTER TABLE proc_pr_approvals ADD COLUMN IF NOT EXISTS stage_key text;
ALTER TABLE proc_pr_approvals ADD COLUMN IF NOT EXISTS assigned_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE proc_pr_approvals ADD COLUMN IF NOT EXISTS assigned_by text;
ALTER TABLE proc_pr_approvals ADD COLUMN IF NOT EXISTS due_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS uq_proc_pr_approval_stage ON proc_pr_approvals(pr_id, seq);

CREATE TABLE IF NOT EXISTS proc_pr_versions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pr_id text NOT NULL REFERENCES proc_purchase_requests(id) ON DELETE CASCADE,
  revision integer NOT NULL,
  snapshot jsonb NOT NULL,
  reason text,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(pr_id, revision)
);

-- A request may create several POs and a PO may aggregate several requests.
CREATE TABLE IF NOT EXISTS proc_pr_po_links (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pr_id text NOT NULL REFERENCES proc_purchase_requests(id) ON DELETE CASCADE,
  po_number text NOT NULL,
  note text,
  linked_by text NOT NULL,
  linked_at timestamptz NOT NULL DEFAULT now(),
  unlinked_by text,
  unlinked_at timestamptz,
  active boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_proc_pr_po_active
  ON proc_pr_po_links(pr_id, po_number) WHERE active;
CREATE INDEX IF NOT EXISTS idx_proc_pr_po_number ON proc_pr_po_links(po_number) WHERE active;

CREATE TABLE IF NOT EXISTS proc_pr_item_allocations (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  link_id bigint NOT NULL REFERENCES proc_pr_po_links(id) ON DELETE CASCADE,
  pr_item_id bigint NOT NULL REFERENCES proc_pr_items(id) ON DELETE CASCADE,
  allocated_qty numeric NOT NULL CHECK (allocated_qty > 0),
  unit_price numeric CHECK (unit_price IS NULL OR unit_price >= 0),
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(link_id, pr_item_id)
);

CREATE INDEX IF NOT EXISTS idx_proc_pr_alloc_item ON proc_pr_item_allocations(pr_item_id);

-- New request documents are immutable R2 objects. Legacy Supabase Storage
-- columns remain readable during rollout; every new object is registered here.
ALTER TABLE proc_pr_attachments ADD COLUMN IF NOT EXISTS storage_provider text;
ALTER TABLE proc_pr_attachments ADD COLUMN IF NOT EXISTS object_key text;
ALTER TABLE proc_pr_attachments ADD COLUMN IF NOT EXISTS file_name text;
ALTER TABLE proc_pr_attachments ADD COLUMN IF NOT EXISTS kind text;
ALTER TABLE proc_pr_attachments ADD COLUMN IF NOT EXISTS content_type text;
ALTER TABLE proc_pr_attachments ADD COLUMN IF NOT EXISTS size_bytes bigint;
ALTER TABLE proc_pr_attachments ADD COLUMN IF NOT EXISTS uploaded_by text;
ALTER TABLE proc_pr_attachments ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();
ALTER TABLE proc_pr_attachments ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS uq_proc_pr_attachment_object_key
  ON proc_pr_attachments(object_key) WHERE object_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_proc_pr_attachment_active
  ON proc_pr_attachments(pr_id, created_at) WHERE deleted_at IS NULL;

ALTER TABLE proc_pr_messages ADD COLUMN IF NOT EXISTS parent_id bigint REFERENCES proc_pr_messages(id) ON DELETE SET NULL;
ALTER TABLE proc_pr_messages ADD COLUMN IF NOT EXISTS pr_item_id bigint REFERENCES proc_pr_items(id) ON DELETE SET NULL;
ALTER TABLE proc_pr_messages ADD COLUMN IF NOT EXISTS resolved_at timestamptz;
ALTER TABLE proc_pr_messages ADD COLUMN IF NOT EXISTS resolved_by text;
ALTER TABLE proc_pr_messages ADD COLUMN IF NOT EXISTS mentions text[] NOT NULL DEFAULT '{}'::text[];

-- The oldest System 2 schema called the audit fields `action` and `at`, while
-- pr-portal uses `event` and `created_at`. Keep existing history and expose the
-- richer workspace shape on either upgrade path.
ALTER TABLE proc_pr_audit ADD COLUMN IF NOT EXISTS event text;
ALTER TABLE proc_pr_audit ADD COLUMN IF NOT EXISTS channel text;
ALTER TABLE proc_pr_audit ADD COLUMN IF NOT EXISTS detail jsonb;
ALTER TABLE proc_pr_audit ADD COLUMN IF NOT EXISTS created_at timestamptz;
DO $compat$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='proc_pr_audit' AND column_name='action'
  ) THEN
    EXECUTE 'UPDATE proc_pr_audit SET event=coalesce(event,action) WHERE event IS NULL';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='proc_pr_audit' AND column_name='at'
  ) THEN
    EXECUTE 'UPDATE proc_pr_audit SET created_at=coalesce(created_at,at) WHERE created_at IS NULL';
  END IF;
END
$compat$;
UPDATE proc_pr_audit SET created_at=now() WHERE created_at IS NULL;
ALTER TABLE proc_pr_audit ALTER COLUMN created_at SET DEFAULT now();

CREATE OR REPLACE FUNCTION pr_can_view_request(p_pr_id text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH me AS (
    SELECT u.username, u.department_id, u.pr_department_ids
    FROM proc_users u WHERE lower(u.username)=lower(proc_me()) AND coalesce(u.active,true) LIMIT 1
  )
  SELECT EXISTS (
    SELECT 1 FROM proc_purchase_requests r, me
    WHERE r.id=p_pr_id AND (
      pr_has_module_perm('pr_view_all')
      OR (pr_has_module_perm('pr_view_own') AND lower(coalesce(r.requester,''))=lower(me.username))
      OR (pr_has_module_perm('pr_view_own') AND lower(coalesce(r.requested_by,''))=lower(me.username))
      OR (pr_has_module_perm('pr_view_department') AND (
        r.department_id=me.department_id OR r.department_id=ANY(coalesce(me.pr_department_ids,'{}'::text[]))
      ))
      OR EXISTS (SELECT 1 FROM proc_pr_approvals a WHERE a.pr_id=r.id AND lower(coalesce(a.approver,''))=lower(me.username))
    )
  );
$fn$;

CREATE OR REPLACE FUNCTION proc_can_view_amounts() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT pr_has_module_perm('pr_view_financials');
$fn$;

-- Compatibility name used by the R2 document endpoint and older helper RPCs.
CREATE OR REPLACE FUNCTION proc_can_see_pr(p_pr_id text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT pr_can_view_request(p_pr_id);
$fn$;

CREATE OR REPLACE FUNCTION pr_register_attachment(
  p_pr_id text, p_key text, p_file_name text, p_kind text,
  p_content_type text, p_size_bytes bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text:=proc_me(); v_id bigint; v_name text; v_kind text; v_now timestamptz:=now();
BEGIN
  IF v_me IS NULL OR NOT (pr_has_module_perm('pr_upload_attachments') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'لا تملك صلاحية رفع مرفقات الطلب';
  END IF;
  IF NOT pr_can_view_request(p_pr_id) THEN RAISE EXCEPTION 'الطلب خارج نطاقك'; END IF;
  IF p_key IS NULL OR p_key LIKE '%..%'
     OR p_key !~ '^docs/pr/[A-Za-z0-9._-]{3,60}/[A-Za-z0-9._-]{1,80}$'
     OR split_part(p_key,'/',3)<>p_pr_id THEN
    RAISE EXCEPTION 'مفتاح المرفق لا يطابق الطلب';
  END IF;
  IF p_content_type NOT IN ('application/pdf','image/jpeg','image/png') THEN
    RAISE EXCEPTION 'نوع المرفق غير مسموح';
  END IF;
  IF coalesce(p_size_bytes,0)<64 OR p_size_bytes>10485760 THEN
    RAISE EXCEPTION 'حجم المرفق غير مسموح';
  END IF;
  v_name:=left(replace(replace(regexp_replace(btrim(coalesce(p_file_name,'مرفق')),
    '[[:cntrl:]]+','_','g'),'/','_'),chr(92),'_'),160);
  v_kind:=CASE WHEN p_kind IN ('source_form','quote','support','technical','comparison','other') THEN p_kind ELSE 'support' END;
  INSERT INTO proc_pr_attachments
    (pr_id,storage_provider,object_key,file_name,kind,content_type,size_bytes,uploaded_by,created_at)
  VALUES(p_pr_id,'r2',p_key,v_name,v_kind,p_content_type,p_size_bytes,v_me,v_now)
  RETURNING id INTO v_id;
  INSERT INTO proc_audit_log(username,action,entity_type,entity_id,new_value)
  VALUES(v_me,'pr_attachment_added','pr',p_pr_id,
    jsonb_build_object('attachment_id',v_id,'file_name',v_name,'kind',v_kind,'size_bytes',p_size_bytes));
  INSERT INTO proc_pr_audit(pr_id,event,actor,channel,detail)
  VALUES(p_pr_id,'attachment_added',v_me,'portal',
    jsonb_build_object('attachment_id',v_id,'file_name',v_name,'kind',v_kind,'size_bytes',p_size_bytes));
  RETURN jsonb_build_object('ok',true,'id',v_id,'pr_id',p_pr_id,'object_key',p_key,
    'file_name',v_name,'kind',v_kind,'content_type',p_content_type,'size_bytes',p_size_bytes,
    'uploaded_by',v_me,'created_at',v_now);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'المرفق مسجّل مسبقاً';
END;
$fn$;

-- ───────────────────── Atomic save + approval creation ─────────────────────
CREATE OR REPLACE FUNCTION pr_resolve_stage_approver(p_department_id text, p_permission text)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_user text;
BEGIN
  IF p_permission='pr_approve_maintenance' THEN
    SELECT d.manager_user INTO v_user
    FROM proc_departments d JOIN proc_users u ON lower(u.username)=lower(d.manager_user)
    WHERE d.id=p_department_id AND d.active AND coalesce(u.active,true)
      AND coalesce((pr_effective_permissions(u.username)->>p_permission)::boolean,false)
    LIMIT 1;
  END IF;
  IF v_user IS NULL THEN
    SELECT u.username INTO v_user FROM proc_users u
    WHERE coalesce(u.active,true)
      AND coalesce((pr_effective_permissions(u.username)->>p_permission)::boolean,false)
      AND (p_permission <> 'pr_approve_maintenance'
           OR u.department_id=p_department_id
           OR p_department_id=ANY(coalesce(u.pr_department_ids,'{}'::text[])))
    ORDER BY CASE WHEN u.role='admin' THEN 1 ELSE 0 END, u.username LIMIT 1;
  END IF;
  RETURN v_user;
END;
$fn$;

CREATE OR REPLACE FUNCTION pr_project_is_canonical(p_project text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH registry AS (
    SELECT value FROM proc_settings WHERE key='projects_registry' LIMIT 1
  )
  SELECT CASE
    WHEN btrim(coalesce(p_project,''))='' THEN false
    WHEN NOT EXISTS (SELECT 1 FROM registry) THEN false
    WHEN jsonb_array_length(coalesce((SELECT value->'projects' FROM registry),'[]'::jsonb))=0 THEN false
    ELSE EXISTS (
      SELECT 1 FROM registry r, jsonb_array_elements(coalesce(r.value->'projects','[]'::jsonb)) p
      WHERE coalesce((p->>'active')::boolean,true) AND p->>'name'=btrim(p_project)
    )
  END;
$fn$;

CREATE OR REPLACE FUNCTION pr_save_request(
  p_request jsonb,
  p_items jsonb,
  p_submit boolean DEFAULT true,
  p_pr_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_id text; v_now timestamptz := now();
  v_existing proc_purchase_requests%ROWTYPE; v_revision integer := 1;
  v_title text := btrim(coalesce(p_request->>'title',''));
  v_department_id text := nullif(btrim(coalesce(p_request->>'department_id','')),'');
  v_department text; v_sector text; v_requester_name text;
  v_project text := nullif(btrim(coalesce(p_request->>'project','')),'');
  v_manager text; v_proc_manager text; v_item_count integer;
BEGIN
  IF v_me IS NULL OR NOT pr_has_module_perm('pr_create') THEN RAISE EXCEPTION 'لا تملك صلاحية إنشاء طلب شراء'; END IF;
  IF jsonb_typeof(coalesce(p_items,'[]'::jsonb)) <> 'array' THEN RAISE EXCEPTION 'صيغة البنود غير صالحة'; END IF;
  IF jsonb_array_length(coalesce(p_items,'[]'::jsonb))>200 THEN RAISE EXCEPTION 'تجاوز الطلب الحد الأقصى للبنود'; END IF;
  IF length(v_title)>200 OR length(coalesce(p_request->>'justification',''))>4000 THEN
    RAISE EXCEPTION 'أحد حقول الطلب يتجاوز الطول المسموح';
  END IF;
  SELECT count(*) INTO v_item_count FROM jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x
    WHERE btrim(coalesce(x->>'description',''))<>'' AND coalesce((x->>'requested_qty')::numeric,0)>0;
  IF v_title='' OR v_department_id IS NULL THEN RAISE EXCEPTION 'عنوان الطلب والإدارة مطلوبان لحفظ المسودة'; END IF;
  IF p_submit AND (v_project IS NULL OR v_item_count=0) THEN
    RAISE EXCEPTION 'العنوان والإدارة والمشروع المعتمد وبند واحد صالح مطلوبة للإرسال';
  END IF;
  SELECT d.name_ar,d.sector INTO v_department,v_sector
  FROM proc_departments d WHERE d.id=v_department_id AND d.active;
  IF NOT FOUND THEN RAISE EXCEPTION 'الإدارة غير موجودة أو غير نشطة'; END IF;
  SELECT coalesce(nullif(btrim(u.display_name),''),v_me) INTO v_requester_name
  FROM proc_users u WHERE lower(u.username)=lower(v_me) AND coalesce(u.active,true) LIMIT 1;
  IF v_requester_name IS NULL THEN RAISE EXCEPTION 'حساب مقدم الطلب غير نشط أو غير موجود'; END IF;
  IF v_department_id IS NOT NULL AND NOT pr_has_module_perm('pr_view_all') AND NOT EXISTS(
    SELECT 1 FROM proc_users u WHERE lower(u.username)=lower(v_me)
      AND (u.department_id=v_department_id OR v_department_id=ANY(coalesce(u.pr_department_ids,'{}'::text[])))
  ) THEN RAISE EXCEPTION 'لا يمكنك إنشاء طلب لإدارة خارج نطاقك'; END IF;
  IF v_project IS NOT NULL AND NOT pr_project_is_canonical(v_project) THEN
    RAISE EXCEPTION 'المشروع غير موجود في سجل المشاريع المعتمد';
  END IF;

  IF p_pr_id IS NULL THEN
    v_id := pr_next_number();
  ELSE
    SELECT * INTO v_existing FROM proc_purchase_requests WHERE id=p_pr_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
    IF lower(coalesce(v_existing.requester,''))<>lower(v_me)
       AND NOT (pr_has_module_perm('pr_manage_users') OR pr_is_admin()) THEN
      RAISE EXCEPTION 'لا يمكنك تعديل طلب مستخدم آخر';
    END IF;
    IF v_existing.status NOT IN ('draft','returned') THEN RAISE EXCEPTION 'لا يمكن تعديل الطلب في حالته الحالية'; END IF;
    v_id := v_existing.id; v_revision := coalesce(v_existing.revision,1)+1;
    INSERT INTO proc_pr_versions(pr_id,revision,snapshot,reason,created_by)
    VALUES(v_id,coalesce(v_existing.revision,1),jsonb_build_object(
      'request',to_jsonb(v_existing),
      'items',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.seq) FROM proc_pr_items i WHERE i.pr_id=v_id),'[]'::jsonb)
    ),nullif(p_request->>'revision_reason',''),v_me)
    ON CONFLICT (pr_id,revision) DO NOTHING;
  END IF;

  IF p_submit THEN
    v_manager := pr_resolve_stage_approver(v_department_id,'pr_approve_maintenance');
    v_proc_manager := pr_resolve_stage_approver(v_department_id,'pr_authorize_pricing');
    IF v_manager IS NULL THEN RAISE EXCEPTION 'لم يُعيّن مدير صيانة مخوّل لهذه الإدارة'; END IF;
    IF v_proc_manager IS NULL THEN RAISE EXCEPTION 'لم يُعيّن مدير مشتريات مخوّل'; END IF;
  END IF;

  INSERT INTO proc_purchase_requests(
    id,request_no,title,department_id,department,sector,project,requester,requester_name,
    requester_mobile,request_date,needed_by,priority,justification,currency,status,current_seq,
    workflow_state,current_owner,submitted_at,revision,return_reason,created_by,created_at,updated_by,updated_at
  ) VALUES (
    v_id,v_id,v_title,v_department_id,v_department,v_sector,v_project,v_me,
    v_requester_name,left(nullif(btrim(coalesce(p_request->>'requester_mobile','')),''),30),current_date,
    nullif(p_request->>'needed_by','')::date,coalesce(nullif(p_request->>'priority',''),'متوسط'),
    nullif(p_request->>'justification',''),'SAR',CASE WHEN p_submit THEN 'in_review' ELSE 'draft' END,
    CASE WHEN p_submit THEN 1 ELSE 0 END,CASE WHEN p_submit THEN 'maintenance_review' ELSE 'draft' END,
    CASE WHEN p_submit THEN v_manager ELSE v_me END,CASE WHEN p_submit THEN v_now ELSE NULL END,
    v_revision,NULL,v_me,v_now,v_me,v_now
  )
  ON CONFLICT (id) DO UPDATE SET
    title=EXCLUDED.title,department_id=EXCLUDED.department_id,department=EXCLUDED.department,
    sector=EXCLUDED.sector,project=EXCLUDED.project,requester_name=EXCLUDED.requester_name,
    requester_mobile=EXCLUDED.requester_mobile,needed_by=EXCLUDED.needed_by,priority=EXCLUDED.priority,
    justification=EXCLUDED.justification,status=EXCLUDED.status,current_seq=EXCLUDED.current_seq,
    workflow_state=EXCLUDED.workflow_state,current_owner=EXCLUDED.current_owner,
    submitted_at=coalesce(proc_purchase_requests.submitted_at,EXCLUDED.submitted_at),revision=EXCLUDED.revision,
    return_reason=NULL,updated_by=v_me,updated_at=v_now;

  DELETE FROM proc_pr_items WHERE pr_id=v_id;
  INSERT INTO proc_pr_items(pr_id,seq,item_code,description,unit,contract_qty,stock_balance,requested_qty,category,notes)
  SELECT v_id,ord::integer,left(nullif(btrim(x->>'item_code'),''),80),left(btrim(x->>'description'),500),left(nullif(btrim(x->>'unit'),''),40),
         nullif(x->>'contract_qty','')::numeric,nullif(x->>'stock_balance','')::numeric,
         (x->>'requested_qty')::numeric,left(nullif(btrim(x->>'category'),''),120),left(nullif(btrim(x->>'notes'),''),1000)
  FROM jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) WITH ORDINALITY AS q(x,ord)
  WHERE btrim(coalesce(x->>'description',''))<>'' AND coalesce((x->>'requested_qty')::numeric,0)>0;

  DELETE FROM proc_pr_approvals WHERE pr_id=v_id;
  IF p_submit THEN
    INSERT INTO proc_pr_approvals(pr_id,seq,stage_key,stage_label,resolver,role_key,approver,decision,assigned_at,assigned_by,due_at)
    VALUES
      (v_id,1,'maintenance_need','اعتماد الحاجة — مدير الصيانة والتشغيل','department_manager','pr_approve_maintenance',v_manager,'pending',v_now,v_me,v_now+interval '24 hours'),
      (v_id,2,'procurement_pricing','إذن بدء التسعير — مدير المشتريات','permission','pr_authorize_pricing',v_proc_manager,'pending',v_now,v_me,v_now+interval '48 hours');
  END IF;

  INSERT INTO proc_audit_log(username,display_name,action,entity_type,entity_id,new_value)
  SELECT v_me,coalesce(u.display_name,v_me),CASE WHEN p_submit THEN 'pr_submitted' ELSE 'pr_draft_saved' END,
         'pr',v_id,jsonb_build_object('revision',v_revision,'workflow_state',CASE WHEN p_submit THEN 'maintenance_review' ELSE 'draft' END)
  FROM (SELECT 1) z LEFT JOIN proc_users u ON lower(u.username)=lower(v_me) LIMIT 1;

  RETURN jsonb_build_object('ok',true,'id',v_id,'revision',v_revision,'submitted',p_submit,
                            'workflow_state',CASE WHEN p_submit THEN 'maintenance_review' ELSE 'draft' END);
END;
$fn$;

-- ───────────────────────────── Decisions ───────────────────────────────────
CREATE OR REPLACE FUNCTION pr_decide(p_pr_id text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := proc_me(); v_pr proc_purchase_requests%ROWTYPE; v_step proc_pr_approvals%ROWTYPE;
  v_action text := lower(btrim(coalesce(p_action,''))); v_now timestamptz := now(); v_name text; v_authorized boolean:=false;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF v_action NOT IN ('approve','return','reject') THEN RAISE EXCEPTION 'إجراء غير صالح'; END IF;
  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id=p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود'; END IF;
  IF v_pr.status<>'in_review' THEN RAISE EXCEPTION 'الطلب ليس بانتظار قرار'; END IF;
  SELECT * INTO v_step FROM proc_pr_approvals
    WHERE pr_id=p_pr_id AND decision='pending' ORDER BY seq LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا توجد مرحلة معلّقة'; END IF;
  IF lower(coalesce(v_pr.requester,''))=lower(v_me) THEN
    RAISE EXCEPTION 'لا يجوز لمقدم الطلب اعتماد طلبه';
  END IF;
  v_authorized := lower(coalesce(v_step.approver,''))=lower(v_me)
    AND coalesce((pr_effective_permissions(v_me)->>v_step.role_key)::boolean,false);
  IF NOT v_authorized AND v_step.approver IS NOT NULL THEN
    SELECT coalesce(u.is_away,false) AND lower(coalesce(u.delegate_to,''))=lower(v_me)
      AND EXISTS(SELECT 1 FROM proc_users d WHERE lower(d.username)=lower(v_me) AND coalesce(d.active,true)
        AND coalesce((pr_effective_permissions(d.username)->>v_step.role_key)::boolean,false))
      INTO v_authorized FROM proc_users u WHERE lower(u.username)=lower(v_step.approver) LIMIT 1;
  END IF;
  IF NOT (coalesce(v_authorized,false) OR pr_is_admin()) THEN RAISE EXCEPTION 'هذه المرحلة ليست مسندة إليك'; END IF;
  IF v_action IN ('return','reject') AND length(btrim(coalesce(p_comment,'')))<3 THEN
    RAISE EXCEPTION 'سبب الإرجاع أو الرفض مطلوب';
  END IF;
  SELECT display_name INTO v_name FROM proc_users WHERE lower(username)=lower(v_me) LIMIT 1;
  PERFORM set_config('app.pr_transition','1',true);
  UPDATE proc_pr_approvals SET decision=CASE v_action WHEN 'approve' THEN 'approved' WHEN 'return' THEN 'returned' ELSE 'rejected' END,
    comment=nullif(btrim(coalesce(p_comment,'')),''),acted_at=v_now,approver=v_me WHERE id=v_step.id;

  IF v_action='return' THEN
    UPDATE proc_purchase_requests SET status='returned',workflow_state='returned',current_owner=requester,
      return_reason=p_comment,updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  ELSIF v_action='reject' THEN
    UPDATE proc_purchase_requests SET status='rejected',workflow_state='rejected',current_owner=NULL,
      return_reason=p_comment,updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  ELSIF v_step.stage_key='maintenance_need' THEN
    UPDATE proc_purchase_requests SET current_seq=2,workflow_state='procurement_review',
      current_owner=(SELECT approver FROM proc_pr_approvals WHERE pr_id=p_pr_id AND seq=2),
      maintenance_approved_by=v_me,maintenance_approved_at=v_now,updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  ELSE
    UPDATE proc_purchase_requests SET status='approved',current_seq=0,workflow_state='pricing',proc_status='in_progress',
      current_owner=NULL,pricing_authorized_by=v_me,pricing_authorized_at=v_now,
      proc_started_by=v_me,proc_started_at=coalesce(proc_started_at,v_now),updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  END IF;
  INSERT INTO proc_audit_log(username,display_name,action,entity_type,entity_id,new_value)
  VALUES(v_me,coalesce(v_name,v_me),'pr_'||v_action,'pr',p_pr_id,
         jsonb_build_object('stage_key',v_step.stage_key,'comment',nullif(p_comment,'')));
  RETURN jsonb_build_object('ok',true,'action',v_action,'stage_key',v_step.stage_key,
    'workflow_state',CASE WHEN v_action='return' THEN 'returned' WHEN v_action='reject' THEN 'rejected'
      WHEN v_step.stage_key='maintenance_need' THEN 'procurement_review' ELSE 'pricing' END);
END;
$fn$;

-- Same state machine for signed one-time email actions. The API calls this with
-- service_role; the intended approver and permission are revalidated here.
CREATE TABLE IF NOT EXISTS proc_email_tokens (
  token text PRIMARY KEY,
  pr_id text NOT NULL REFERENCES proc_purchase_requests(id) ON DELETE CASCADE,
  seq integer NOT NULL,
  approver text NOT NULL,
  used boolean NOT NULL DEFAULT false,
  used_at timestamptz,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_prtok_pr ON proc_email_tokens(pr_id);
ALTER TABLE proc_email_tokens ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION pr_transition_email(p_token text, p_action text, p_comment text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_tok proc_email_tokens%ROWTYPE; v_pr proc_purchase_requests%ROWTYPE;
  v_step proc_pr_approvals%ROWTYPE; v_me text; v_action text:=lower(btrim(coalesce(p_action,'')));
  v_ok boolean:=false; v_now timestamptz:=now(); v_state text; v_status text;
BEGIN
  IF v_action NOT IN ('approve','reject','return') THEN RETURN jsonb_build_object('error','invalid_action','code',400); END IF;
  SELECT * INTO v_tok FROM proc_email_tokens WHERE token=p_token FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','unknown_token','code',404); END IF;
  IF v_tok.used THEN RETURN jsonb_build_object('error','used','code',410); END IF;
  IF v_tok.expires_at<v_now THEN RETURN jsonb_build_object('error','expired','code',410); END IF;
  v_me:=v_tok.approver;
  SELECT * INTO v_pr FROM proc_purchase_requests WHERE id=v_tok.pr_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','pr_not_found','code',404); END IF;
  IF v_pr.status<>'in_review' THEN RETURN jsonb_build_object('error','not_in_review','code',409); END IF;
  SELECT * INTO v_step FROM proc_pr_approvals WHERE pr_id=v_tok.pr_id AND decision='pending' ORDER BY seq LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','no_pending','code',409); END IF;
  IF v_step.seq<>v_tok.seq THEN RETURN jsonb_build_object('error','stage_changed','code',409); END IF;
  IF lower(coalesce(v_pr.requester,''))=lower(v_me) THEN RETURN jsonb_build_object('error','sod','code',403); END IF;
  SELECT lower(coalesce(v_step.approver,''))=lower(v_me)
         OR coalesce((pr_effective_permissions(v_me)->>v_step.role_key)::boolean,false)
         OR EXISTS(SELECT 1 FROM proc_users u WHERE lower(u.username)=lower(v_me) AND u.role='admin' AND coalesce(u.active,true))
    INTO v_ok;
  IF NOT v_ok AND v_step.approver IS NOT NULL THEN
    SELECT coalesce(u.is_away,false) AND lower(coalesce(u.delegate_to,''))=lower(v_me)
      AND EXISTS(SELECT 1 FROM proc_users d WHERE lower(d.username)=lower(v_me) AND coalesce(d.active,true)
        AND coalesce((pr_effective_permissions(d.username)->>v_step.role_key)::boolean,false))
      INTO v_ok FROM proc_users u WHERE lower(u.username)=lower(v_step.approver) LIMIT 1;
  END IF;
  IF NOT coalesce(v_ok,false) THEN RETURN jsonb_build_object('error','not_approver','code',403); END IF;
  IF v_action IN ('reject','return') AND length(btrim(coalesce(p_comment,'')))<3 THEN
    RETURN jsonb_build_object('error','comment_required','code',400);
  END IF;

  UPDATE proc_email_tokens SET used=true,used_at=v_now WHERE token=p_token;
  PERFORM set_config('app.pr_transition','1',true);
  UPDATE proc_pr_approvals SET decision=CASE v_action WHEN 'approve' THEN 'approved' WHEN 'return' THEN 'returned' ELSE 'rejected' END,
    comment=nullif(btrim(coalesce(p_comment,'')),''),acted_at=v_now,approver=v_me,channel='email' WHERE id=v_step.id;
  IF v_action='return' THEN
    v_state:='returned';v_status:='returned';
    UPDATE proc_purchase_requests SET status=v_status,workflow_state=v_state,current_owner=requester,return_reason=p_comment,updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  ELSIF v_action='reject' THEN
    v_state:='rejected';v_status:='rejected';
    UPDATE proc_purchase_requests SET status=v_status,workflow_state=v_state,current_owner=NULL,return_reason=p_comment,updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  ELSIF v_step.stage_key='maintenance_need' THEN
    v_state:='procurement_review';v_status:='in_review';
    UPDATE proc_purchase_requests SET current_seq=2,workflow_state=v_state,
      current_owner=(SELECT approver FROM proc_pr_approvals WHERE pr_id=v_pr.id AND seq=2),
      maintenance_approved_by=v_me,maintenance_approved_at=v_now,updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  ELSE
    v_state:='pricing';v_status:='approved';
    UPDATE proc_purchase_requests SET status=v_status,current_seq=0,workflow_state=v_state,proc_status='in_progress',current_owner=NULL,
      pricing_authorized_by=v_me,pricing_authorized_at=v_now,proc_started_by=v_me,
      proc_started_at=coalesce(proc_started_at,v_now),updated_by=v_me,updated_at=v_now WHERE id=v_pr.id;
  END IF;
  RETURN jsonb_build_object('ok',true,'action',v_action,'status',v_status,'workflow_state',v_state,
    'finalized',v_status<>'in_review','seq',v_step.seq,
    'pr',jsonb_build_object('id',v_pr.id,'title',v_pr.title,'department',v_pr.department,
      'department_id',v_pr.department_id,'requester',v_pr.requester,'requester_name',v_pr.requester_name));
END;
$fn$;

-- ───────────────────── Many-to-many PO allocation ──────────────────────────
CREATE OR REPLACE FUNCTION pr_link_purchase_order(
  p_pr_id text, p_po_number text, p_allocations jsonb, p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text:=proc_me(); v_po text:=btrim(coalesce(p_po_number,'')); v_link bigint;
  v_bad integer; v_coverage numeric; v_now timestamptz:=now();
BEGIN
  IF v_me IS NULL OR NOT (pr_has_module_perm('pr_link_purchase_orders') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'لا تملك صلاحية ربط أوامر الشراء';
  END IF;
  IF v_po='' OR NOT EXISTS(SELECT 1 FROM proc_purchase_orders WHERE po_number=v_po) THEN
    RAISE EXCEPTION 'أمر الشراء غير موجود في النظام';
  END IF;
  PERFORM 1 FROM proc_purchase_requests
  WHERE id=p_pr_id AND status IN ('approved','rfq_issued','converted_to_po') FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'لا يُربط أمر شراء قبل اكتمال الاعتماد وإذن التسعير';
  END IF;
  IF jsonb_typeof(coalesce(p_allocations,'[]'::jsonb))<>'array' OR jsonb_array_length(coalesce(p_allocations,'[]'::jsonb))=0 THEN
    RAISE EXCEPTION 'وزّع كمية واحدة على الأقل من بنود الطلب';
  END IF;
  SELECT count(*) INTO v_bad
  FROM jsonb_to_recordset(p_allocations) AS a(item_id bigint, qty numeric)
  LEFT JOIN proc_pr_items i ON i.id=a.item_id AND i.pr_id=p_pr_id
  WHERE i.id IS NULL OR coalesce(a.qty,0)<=0;
  IF v_bad>0 THEN RAISE EXCEPTION 'توزيع البنود غير صالح'; END IF;
  SELECT id INTO v_link FROM proc_pr_po_links
  WHERE pr_id=p_pr_id AND po_number=v_po AND active FOR UPDATE;
  SELECT count(*) INTO v_bad FROM (
    SELECT a.item_id,
      coalesce((SELECT sum(x.allocated_qty) FROM proc_pr_item_allocations x
                JOIN proc_pr_po_links l ON l.id=x.link_id
                WHERE l.active AND x.pr_item_id=a.item_id AND (v_link IS NULL OR l.id<>v_link)),0)
      + sum(a.qty) AS total, max(i.requested_qty) AS requested
    FROM jsonb_to_recordset(p_allocations) AS a(item_id bigint, qty numeric)
    JOIN proc_pr_items i ON i.id=a.item_id AND i.pr_id=p_pr_id GROUP BY a.item_id
  ) q WHERE q.total>q.requested;
  IF v_bad>0 THEN RAISE EXCEPTION 'الكمية الموزّعة تتجاوز الكمية المطلوبة'; END IF;

  IF v_link IS NULL THEN
    INSERT INTO proc_pr_po_links(pr_id,po_number,note,linked_by,linked_at,active)
    VALUES(p_pr_id,v_po,nullif(btrim(coalesce(p_note,'')),''),v_me,v_now,true)
    RETURNING id INTO v_link;
  ELSE
    UPDATE proc_pr_po_links
    SET note=nullif(btrim(coalesce(p_note,'')),''), linked_by=v_me
    WHERE id=v_link;
    DELETE FROM proc_pr_item_allocations WHERE link_id=v_link;
  END IF;
  INSERT INTO proc_pr_item_allocations(link_id,pr_item_id,allocated_qty,unit_price,created_by)
  SELECT v_link,a.item_id,a.qty,a.unit_price,v_me
  FROM jsonb_to_recordset(p_allocations) AS a(item_id bigint, qty numeric, unit_price numeric);

  SELECT coalesce(sum(least(i.requested_qty,coalesce(x.allocated,0)))/nullif(sum(i.requested_qty),0),0)
  INTO v_coverage FROM proc_pr_items i LEFT JOIN (
    SELECT a.pr_item_id,sum(a.allocated_qty) allocated FROM proc_pr_item_allocations a
    JOIN proc_pr_po_links l ON l.id=a.link_id AND l.active GROUP BY a.pr_item_id
  ) x ON x.pr_item_id=i.id WHERE i.pr_id=p_pr_id;

  UPDATE proc_purchase_requests SET
    po_number=coalesce(po_number,v_po),
    workflow_state=CASE WHEN v_coverage>=1 THEN 'ordered' ELSE 'partially_ordered' END,
    proc_status=CASE WHEN v_coverage>=1 THEN 'po_issued' ELSE proc_status END,
    updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  INSERT INTO proc_audit_log(username,action,entity_type,entity_id,new_value)
  VALUES(v_me,'pr_po_linked','pr',p_pr_id,jsonb_build_object('po_number',v_po,'coverage',v_coverage));
  INSERT INTO proc_pr_audit(pr_id,event,actor,channel,detail)
  VALUES(p_pr_id,'po_linked',v_me,'portal',jsonb_build_object('po_number',v_po,'coverage',v_coverage));
  RETURN jsonb_build_object('ok',true,'link_id',v_link,'po_number',v_po,'coverage',v_coverage);
END;
$fn$;

CREATE OR REPLACE FUNCTION pr_unlink_purchase_order(p_pr_id text, p_po_number text, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_me text:=proc_me(); v_reason text:=btrim(coalesce(p_reason,'')); v_count integer; v_coverage numeric;
BEGIN
  IF v_me IS NULL OR NOT (pr_has_module_perm('pr_link_purchase_orders') OR pr_is_admin()) THEN RAISE EXCEPTION 'غير مصرّح'; END IF;
  IF length(v_reason)<3 THEN RAISE EXCEPTION 'سبب فك الربط مطلوب'; END IF;
  PERFORM 1 FROM proc_purchase_requests WHERE id=p_pr_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب الشراء غير موجود'; END IF;
  UPDATE proc_pr_po_links SET active=false,unlinked_by=v_me,unlinked_at=now(),note=concat_ws(' · ',note,'فك الربط: '||v_reason)
  WHERE pr_id=p_pr_id AND po_number=btrim(p_po_number) AND active;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count=0 THEN RAISE EXCEPTION 'الرابط غير موجود'; END IF;
  SELECT coalesce(sum(least(i.requested_qty,coalesce(x.allocated,0)))/nullif(sum(i.requested_qty),0),0)
  INTO v_coverage FROM proc_pr_items i LEFT JOIN (
    SELECT a.pr_item_id,sum(a.allocated_qty) allocated FROM proc_pr_item_allocations a
    JOIN proc_pr_po_links l ON l.id=a.link_id AND l.active GROUP BY a.pr_item_id
  ) x ON x.pr_item_id=i.id WHERE i.pr_id=p_pr_id;
  UPDATE proc_purchase_requests r SET
    po_number=(SELECT l.po_number FROM proc_pr_po_links l WHERE l.pr_id=r.id AND l.active ORDER BY l.linked_at LIMIT 1),
    workflow_state=CASE WHEN v_coverage>=1 THEN 'ordered'
      WHEN EXISTS(SELECT 1 FROM proc_pr_po_links l WHERE l.pr_id=r.id AND l.active) THEN 'partially_ordered' ELSE 'pricing' END,
    proc_status=CASE WHEN v_coverage>=1 THEN 'po_issued' ELSE 'in_progress' END,
    updated_by=v_me,updated_at=now() WHERE r.id=p_pr_id;
  INSERT INTO proc_audit_log(username,action,entity_type,entity_id,new_value)
  VALUES(v_me,'pr_po_unlinked','pr',p_pr_id,jsonb_build_object('po_number',btrim(p_po_number),'reason',v_reason));
  INSERT INTO proc_pr_audit(pr_id,event,actor,channel,detail)
  VALUES(p_pr_id,'po_unlinked',v_me,'portal',jsonb_build_object('po_number',btrim(p_po_number),'reason',v_reason));
  RETURN jsonb_build_object('ok',true);
END;
$fn$;

-- ───────────────────────── Secure direct access ────────────────────────────
CREATE OR REPLACE FUNCTION pr_attach_rfq(p_pr_id text, p_rfq_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text:=proc_me(); v_rfq text:=btrim(coalesce(p_rfq_id,'')); v_now timestamptz:=now();
BEGIN
  IF v_me IS NULL OR NOT (pr_has_module_perm('pr_manage_pricing') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'لا تملك صلاحية إدارة التسعير';
  END IF;
  IF v_rfq='' OR NOT EXISTS(SELECT 1 FROM proc_rfqs WHERE id=v_rfq) THEN
    RAISE EXCEPTION 'طلب التسعير غير موجود في النظام';
  END IF;
  PERFORM 1 FROM proc_purchase_requests
    WHERE id=p_pr_id AND status IN ('approved','rfq_issued','converted_to_po') FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'لا يمكن ربط التسعير قبل اكتمال الاعتماد'; END IF;
  PERFORM set_config('app.pr_transition','1',true);
  UPDATE proc_purchase_requests SET rfq_id=v_rfq,status='rfq_issued',proc_status='rfq_issued',
    updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  INSERT INTO proc_audit_log(username,action,entity_type,entity_id,new_value)
  VALUES(v_me,'pr_rfq_linked','pr',p_pr_id,jsonb_build_object('rfq_id',v_rfq));
  INSERT INTO proc_pr_audit(pr_id,event,actor,channel,detail)
  VALUES(p_pr_id,'rfq_linked',v_me,'portal',jsonb_build_object('rfq_id',v_rfq));
  RETURN jsonb_build_object('ok',true,'id',p_pr_id,'rfq_id',v_rfq);
END;
$fn$;

-- Compatibility RPCs for the RFQ award-approval panel already in index.html.
CREATE OR REPLACE FUNCTION pr_submit_award_request(
  p_title text, p_supplier text, p_amount numeric, p_details jsonb DEFAULT '{}'::jsonb,
  p_required_level integer DEFAULT 1
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text:=proc_me(); v_name text; v_id text; v_now timestamptz:=now(); v_level integer:=p_required_level;
BEGIN
  IF v_me IS NULL OR NOT (pr_has_module_perm('pr_manage_pricing') OR pr_is_admin()) THEN
    RAISE EXCEPTION 'لا تملك صلاحية إرسال طلب اعتماد الترسية';
  END IF;
  IF btrim(coalesce(p_title,''))='' OR coalesce(p_amount,0)<=0 OR v_level NOT IN (1,2) THEN
    RAISE EXCEPTION 'بيانات طلب اعتماد الترسية غير مكتملة';
  END IF;
  SELECT coalesce(nullif(btrim(display_name),''),v_me) INTO v_name
    FROM proc_users WHERE lower(username)=lower(v_me) AND coalesce(active,true) LIMIT 1;
  v_id:='apr_'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')||'_'||substr(md5(random()::text),1,6);
  PERFORM set_config('app.pr_transition','1',true);
  INSERT INTO proc_purchase_requests(
    id,title,supplier,amount,currency,details,requested_by,requested_by_name,
    status,required_level,workflow_state,created_by,created_at,updated_by,updated_at
  ) VALUES(
    v_id,btrim(p_title),nullif(btrim(coalesce(p_supplier,'')),''),p_amount,'SAR',coalesce(p_details,'{}'::jsonb),
    v_me,coalesce(v_name,v_me),'pending',v_level,'award_review',v_me,v_now,v_me,v_now
  );
  INSERT INTO proc_audit_log(username,action,entity_type,entity_id,new_value)
  VALUES(v_me,'award_request_submitted','purchase_request',v_id,
    jsonb_build_object('amount',p_amount,'required_level',v_level));
  RETURN jsonb_build_object('ok',true,'id',v_id,'required_level',v_level);
END;
$fn$;

CREATE OR REPLACE FUNCTION pr_decide_award_request(p_pr_id text, p_approve boolean, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text:=proc_me(); v_req proc_purchase_requests%ROWTYPE; v_status text; v_now timestamptz:=now();
BEGIN
  SELECT * INTO v_req FROM proc_purchase_requests
    WHERE id=p_pr_id AND workflow_state='award_review' AND status='pending' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'طلب اعتماد الترسية غير موجود أو سبق البت فيه'; END IF;
  IF v_me IS NULL OR NOT (pr_is_admin() OR
      (v_req.required_level=1 AND (pr_has_perm('can_approve_l1') OR pr_has_perm('can_approve_l2'))) OR
      (v_req.required_level=2 AND pr_has_perm('can_approve_l2'))) THEN
    RAISE EXCEPTION 'لا تملك اعتماد هذا المستوى';
  END IF;
  IF lower(coalesce(v_req.requested_by,''))=lower(v_me) THEN
    RAISE EXCEPTION 'لا يجوز لمقدم الطلب اعتماد طلبه';
  END IF;
  v_status:=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
  PERFORM set_config('app.pr_transition','1',true);
  UPDATE proc_purchase_requests SET status=v_status,workflow_state='award_'||v_status,
    decided_by=v_me,decided_at=v_now,decision_note=nullif(btrim(coalesce(p_note,'')),''),
    updated_by=v_me,updated_at=v_now WHERE id=p_pr_id;
  INSERT INTO proc_audit_log(username,action,entity_type,entity_id,old_value,new_value)
  VALUES(v_me,CASE WHEN p_approve THEN 'approve' ELSE 'reject' END,'purchase_request',p_pr_id,
    jsonb_build_object('status','pending'),jsonb_build_object('status',v_status,'note',p_note));
  RETURN jsonb_build_object('ok',true,'id',p_pr_id,'status',v_status);
END;
$fn$;

ALTER TABLE proc_pr_permission_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE proc_pr_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE proc_pr_po_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE proc_pr_item_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE proc_pr_attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE proc_pr_audit ENABLE ROW LEVEL SECURITY;

DO $policies$
DECLARE t text; p record;
BEGIN
  FOREACH t IN ARRAY ARRAY['proc_purchase_requests','proc_pr_items','proc_pr_approvals','proc_pr_attachments','proc_pr_messages','proc_pr_audit',
                            'proc_pr_versions','proc_pr_po_links','proc_pr_item_allocations','proc_pr_permission_profiles',
                            'proc_departments','proc_approval_rules'] LOOP
    FOR p IN SELECT policyname FROM pg_policies
      WHERE schemaname='public' AND tablename=t AND permissive='PERMISSIVE' LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON %I',p.policyname,t);
    END LOOP;
  END LOOP;
END $policies$;

CREATE POLICY pr_request_select ON proc_purchase_requests FOR SELECT TO authenticated USING (pr_can_view_request(id));
CREATE POLICY pr_request_insert_deny ON proc_purchase_requests FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY pr_request_update_deny ON proc_purchase_requests FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY pr_request_delete_deny ON proc_purchase_requests FOR DELETE TO authenticated USING (false);

CREATE POLICY pr_item_select ON proc_pr_items FOR SELECT TO authenticated USING (pr_can_view_request(pr_id));
CREATE POLICY pr_approval_select ON proc_pr_approvals FOR SELECT TO authenticated USING (pr_can_view_request(pr_id));
CREATE POLICY pr_attachment_select ON proc_pr_attachments FOR SELECT TO authenticated USING (pr_can_view_request(pr_id));
CREATE POLICY pr_message_select ON proc_pr_messages FOR SELECT TO authenticated USING (pr_can_view_request(pr_id));
CREATE POLICY pr_audit_select ON proc_pr_audit FOR SELECT TO authenticated USING (pr_can_view_request(pr_id));
CREATE POLICY pr_version_select ON proc_pr_versions FOR SELECT TO authenticated USING (pr_can_view_request(pr_id));
CREATE POLICY pr_po_link_select ON proc_pr_po_links FOR SELECT TO authenticated USING (pr_can_view_request(pr_id));
CREATE POLICY pr_alloc_select ON proc_pr_item_allocations FOR SELECT TO authenticated
  USING (EXISTS(SELECT 1 FROM proc_pr_po_links l WHERE l.id=link_id AND pr_can_view_request(l.pr_id)));
CREATE POLICY pr_profile_select ON proc_pr_permission_profiles FOR SELECT TO authenticated USING (active OR pr_has_module_perm('pr_manage_users'));
CREATE POLICY pr_department_select ON proc_departments FOR SELECT TO authenticated USING (true);
CREATE POLICY pr_department_insert ON proc_departments FOR INSERT TO authenticated
  WITH CHECK (pr_has_module_perm('pr_manage_workflows'));
CREATE POLICY pr_department_update ON proc_departments FOR UPDATE TO authenticated
  USING (pr_has_module_perm('pr_manage_workflows')) WITH CHECK (pr_has_module_perm('pr_manage_workflows'));
CREATE POLICY pr_department_delete_deny ON proc_departments FOR DELETE TO authenticated USING (false);
CREATE POLICY pr_rule_select ON proc_approval_rules FOR SELECT TO authenticated USING (true);
CREATE POLICY pr_rule_insert ON proc_approval_rules FOR INSERT TO authenticated
  WITH CHECK (pr_has_module_perm('pr_manage_workflows'));
CREATE POLICY pr_rule_update ON proc_approval_rules FOR UPDATE TO authenticated
  USING (pr_has_module_perm('pr_manage_workflows')) WITH CHECK (pr_has_module_perm('pr_manage_workflows'));
CREATE POLICY pr_rule_delete_deny ON proc_approval_rules FOR DELETE TO authenticated USING (false);

-- Mutations use SECURITY DEFINER RPCs so a browser cannot bypass the state machine.
REVOKE INSERT, UPDATE, DELETE ON proc_purchase_requests, proc_pr_items, proc_pr_approvals,
  proc_pr_attachments, proc_pr_messages, proc_pr_audit, proc_pr_versions, proc_pr_po_links, proc_pr_item_allocations,
  proc_pr_permission_profiles FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON proc_departments, proc_approval_rules FROM anon;
REVOKE DELETE ON proc_departments, proc_approval_rules FROM authenticated;
REVOKE ALL ON proc_email_tokens FROM anon, authenticated;
GRANT SELECT ON proc_purchase_requests, proc_pr_items, proc_pr_approvals, proc_pr_attachments, proc_pr_messages, proc_pr_audit,
  proc_pr_versions, proc_pr_po_links, proc_pr_item_allocations, proc_pr_permission_profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE ON proc_departments, proc_approval_rules TO authenticated;
REVOKE ALL ON FUNCTION pr_save_request(jsonb,jsonb,boolean,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_decide(text,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_link_purchase_order(text,text,jsonb,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_unlink_purchase_order(text,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_register_attachment(text,text,text,text,text,bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_attach_rfq(text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_submit_award_request(text,text,numeric,jsonb,integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_decide_award_request(text,boolean,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pr_transition_email(text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION pr_effective_permissions(text), pr_has_module_perm(text), pr_has_perm(text),
  pr_can_view_request(text), proc_can_view_amounts(), proc_can_see_pr(text),
  pr_resolve_stage_approver(text,text), pr_project_is_canonical(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pr_transition_email(text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION pr_effective_permissions(text), pr_has_module_perm(text), pr_has_perm(text),
  pr_can_view_request(text), proc_can_view_amounts(), proc_can_see_pr(text),
  pr_save_request(jsonb,jsonb,boolean,text), pr_decide(text,text,text),
  pr_link_purchase_order(text,text,jsonb,text), pr_unlink_purchase_order(text,text,text),
  pr_register_attachment(text,text,text,text,text,bigint), pr_attach_rfq(text,text),
  pr_submit_award_request(text,text,numeric,jsonb,integer), pr_decide_award_request(text,boolean,text) TO authenticated;

COMMIT;

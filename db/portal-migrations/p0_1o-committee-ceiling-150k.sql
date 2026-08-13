-- ════════════════════════════════════════════════════════════════════════════
--  p0_1o — F-PO-125K remediation (owner-decided Path A, 2026-08-05)
--  Raise the committee ceiling 125,000 → 150,000 so committee PO review covers
--  25,001–150,000 (aligned with the DoA tier-2 boundary), closing the
--  (125000, 150000] band that previously produced ZERO second-line PO approval.
--  Amounts > 150,000 keep the finance/GM PO stages per DoA (tier-3+).
--
--  Idempotent: re-running keeps max_amount_inclusive=150000 (version bumps, matching
--  the p0_1i pattern). Owner authorization: PR #74 Gate flow, staging only.
--  No DoA change; no fallback_role_key change (kept as-is).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- 1) Update the live committee_policy setting: max_amount_inclusive 125000 -> 150000.
DO $committee_150k$
DECLARE v_current jsonb; v_version integer;
BEGIN
  SELECT value INTO v_current FROM public.portal_settings WHERE key='committee_policy' FOR UPDATE;
  v_current := coalesce(v_current,'{}'::jsonb);
  v_version := coalesce((v_current->>'version')::integer,0)+1;
  PERFORM set_config('app.portal_transition','1',true);
  INSERT INTO public.portal_settings(key,value)
  VALUES ('committee_policy', jsonb_build_object(
    'enabled', coalesce((v_current->>'enabled')::boolean,true),
    'min_amount_exclusive', 25000,
    'max_amount_inclusive', 150000,
    'fallback_role_key', nullif(v_current->>'fallback_role_key',''),
    'version', v_version,
    'published_at', to_jsonb(now()),
    'published_by', 'migration:p0_1o'))
  ON CONFLICT (key) DO UPDATE SET value = excluded.value;
  PERFORM set_config('app.portal_transition','0',true);
END;
$committee_150k$;

-- 2) Keep the clean-install fallback default in sync (150000), so a fresh install
--    with no stored setting also uses the aligned ceiling.
CREATE OR REPLACE FUNCTION public.portal_get_committee_policy()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO public
AS $function$
  SELECT jsonb_build_object('enabled',true,'min_amount_exclusive',25000,'max_amount_inclusive',150000,
    'fallback_role_key',null,'version',1,'published_at',null,'published_by',null)
    || coalesce((SELECT value FROM public.portal_settings WHERE key='committee_policy'),'{}'::jsonb);
$function$;
REVOKE ALL ON FUNCTION public.portal_get_committee_policy() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_get_committee_policy() TO authenticated, service_role;

COMMIT;

-- P0-1t -- admin-only RPC to toggle governance enforcement flags from Settings
--
-- Mandate principle هـ.2: every governance behavior must be enable/disable/
-- adjustable from the Settings panel (the committee-feature pattern). The
-- enforcement flags (budget/iban/three-way/contract/quote-doc/disbursement
-- gate/txn-notifications) already exist in the engine but had no controlled
-- write path — only a full-JSON client UPDATE guarded by portal_config_guard,
-- which risks clobbering the whole settings object. This RPC gives the portal
-- admin a safe, key-whitelisted, audited toggle.
--
-- Governance: admin/privileged only (enforcement flags are admin-level — a bare
-- can_manage_users holder cannot flip them). Key whitelist prevents arbitrary
-- settings injection. Value range-checked. Merged with `||` (never replaces the
-- whole object). Does NOT change any flag by itself — it is the control surface;
-- flipping a flag is an explicit admin action.
--
-- Repo/tests only — NOT applied to any live database, and this migration does
-- NOT set any flag value.
BEGIN;

CREATE OR REPLACE FUNCTION portal_set_governance_flag(p_key text, p_value numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_me text := portal_username();
  v_allowed text[] := ARRAY['budget_enforce','iban_change_control','three_way_enforce',
    'three_way_tolerance_pct','contract_enforce','quote_doc_required','disb_gate_purchase',
    'txn_notifications'];
BEGIN
  IF NOT (portal_is_admin() OR portal_is_privileged()) THEN
    RAISE EXCEPTION 'ضبط الحوكمة يتطلّب صلاحية أدمن كاملة';
  END IF;
  IF NOT (p_key = ANY(v_allowed)) THEN RAISE EXCEPTION 'مفتاح إعداد غير معروف: %', p_key; END IF;
  IF p_value IS NULL OR p_value < 0 OR p_value > 100 THEN
    RAISE EXCEPTION 'قيمة غير صالحة (0..100): %', p_value;
  END IF;
  -- boolean-style flags accept only 0/1; the tolerance percentage may be 0..100.
  IF p_key <> 'three_way_tolerance_pct' AND p_value NOT IN (0,1) THEN
    RAISE EXCEPTION 'هذا المفتاح ثنائي (0 أو 1): %', p_key;
  END IF;

  PERFORM set_config('app.portal_transition', '1', true);
  UPDATE portal_settings
     SET value = coalesce(value,'{}'::jsonb) || jsonb_build_object(p_key, p_value)
   WHERE key = 'portal_settings';
  IF NOT FOUND THEN
    INSERT INTO portal_settings(key, value)
      VALUES ('portal_settings', jsonb_build_object(p_key, p_value));
  END IF;
  PERFORM set_config('app.portal_transition', '0', true);

  PERFORM portal_audit_write(NULL, 'governance_flag_set', v_me, 'portal',
    jsonb_build_object('key', p_key, 'value', p_value));
  RETURN jsonb_build_object('ok', true, 'key', p_key, 'value', p_value);
END $fn$;

REVOKE ALL ON FUNCTION portal_set_governance_flag(text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION portal_set_governance_flag(text,numeric) TO authenticated, service_role;

COMMIT;

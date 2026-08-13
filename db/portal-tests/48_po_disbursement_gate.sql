-- ════════════════════════════════════════════════════════════════════════════
--  48 — Entry-2 disbursement gate present on the purchase PO path (p0_1p).
--  Guards against the F-GATE2 drift where portal_po_transition lost the
--  `disb_gate_purchase` branch. Introspection assertion (deterministic).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'portal_po_transition' LIMIT 1;
  IF v_def IS NULL THEN RAISE EXCEPTION 'PG1 FAIL: portal_po_transition missing'; END IF;

  IF v_def NOT ILIKE '%disb_gate_purchase%' THEN
    RAISE EXCEPTION 'PG1 FAIL: portal_po_transition lacks the disb_gate_purchase branch (Entry-2 gate)';
  END IF;
  RAISE NOTICE 'PASS PG1 po_transition carries the disb_gate_purchase branch';

  IF v_def NOT ILIKE '%portal_build_chain(p_request_id, ''disbursement'')%' THEN
    RAISE EXCEPTION 'PG2 FAIL: gate does not build the disbursement chain';
  END IF;
  IF v_def NOT ILIKE '%phase = ''disbursement''%' THEN
    RAISE EXCEPTION 'PG3 FAIL: gate does not route the request into the disbursement phase';
  END IF;
  RAISE NOTICE 'PASS PG2/PG3 gate builds disbursement chain and routes into disbursement phase';

  -- setting exists (default 0 — inert until owner enables)
  IF (SELECT count(*) FROM portal_settings WHERE key='portal_settings' AND value ? 'disb_gate_purchase') <> 1 THEN
    RAISE EXCEPTION 'PG4 FAIL: disb_gate_purchase setting key missing';
  END IF;
  RAISE NOTICE 'PASS PG4 disb_gate_purchase setting present (default off)';
END $t$;

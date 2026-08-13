-- ════════════════════════════════════════════════════════════════════════════
--  47 — F-PO-125K remediation (p0_1o, owner Path A): committee ceiling = 150,000.
--  Proves the resolver (portal_committee_route) at the policy boundaries so the
--  previously-uncontrolled (125000,150000] band is now committee-covered.
--  Resolver-level assertions (no impersonation needed).
-- ════════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
SET client_min_messages = notice;

DO $t$
DECLARE v_max numeric; r jsonb;
BEGIN
  -- (1) setting applied
  SELECT (portal_get_committee_policy()->>'max_amount_inclusive')::numeric INTO v_max;
  IF v_max <> 150000 THEN RAISE EXCEPTION 'CC1 FAIL: max_amount_inclusive=% (expected 150000)', v_max; END IF;
  RAISE NOTICE 'PASS CC1 committee max_amount_inclusive = 150000';

  -- (2) min boundary unchanged: 25000 out, 25001 in
  IF (portal_committee_route(25000)->>'use_committee')::boolean THEN RAISE EXCEPTION 'CC2 FAIL: 25000 should be out of band'; END IF;
  IF NOT (portal_committee_route(25001)->>'use_committee')::boolean THEN RAISE EXCEPTION 'CC2 FAIL: 25001 should be in band'; END IF;
  RAISE NOTICE 'PASS CC2 min boundary (25000 out / 25001 in)';

  -- (3) the closed band: 125001, 149999, 150000 now use committee (previously 0 PO stages)
  IF NOT (portal_committee_route(125001)->>'use_committee')::boolean THEN RAISE EXCEPTION 'CC3 FAIL: 125001 not committee-covered (gap not closed)'; END IF;
  IF NOT (portal_committee_route(149999)->>'use_committee')::boolean THEN RAISE EXCEPTION 'CC3 FAIL: 149999 not committee-covered'; END IF;
  IF NOT (portal_committee_route(150000)->>'use_committee')::boolean THEN RAISE EXCEPTION 'CC3 FAIL: 150000 not committee-covered'; END IF;
  RAISE NOTICE 'PASS CC3 (125000,150000] band now committee-covered (gap closed)';

  -- (4) upper boundary: 150000 in, 150001 out (DoA tier-3 finance takes over above)
  IF NOT (portal_committee_route(150000)->>'use_committee')::boolean THEN RAISE EXCEPTION 'CC4 FAIL: 150000 should be in band (inclusive)'; END IF;
  IF (portal_committee_route(150001)->>'use_committee')::boolean THEN RAISE EXCEPTION 'CC4 FAIL: 150001 should be out of committee band'; END IF;
  RAISE NOTICE 'PASS CC4 upper boundary (150000 in / 150001 out -> DoA t3 finance)';
END $t$;

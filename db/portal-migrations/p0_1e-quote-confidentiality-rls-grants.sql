-- ═══════════════════════════════════════════════════════════════════════════
--  P0-1e — quote confidentiality read grants (RLS remains authoritative)
--
--  P0-1d tightened quotation/award visibility by replacing broad requester-based
--  policies with portal_can_view_quotes(...). In local CI and fresh deployments,
--  authenticated still needs table-level SELECT privileges before RLS can evaluate.
--  These grants do not expose rows by themselves; RLS policies remain the gate.
-- ═══════════════════════════════════════════════════════════════════════════

GRANT SELECT ON public.portal_requests TO authenticated;
GRANT SELECT ON public.portal_offers TO authenticated;
GRANT SELECT ON public.portal_offer_items TO authenticated;
GRANT SELECT ON public.portal_award TO authenticated;
GRANT SELECT ON public.portal_award_lines TO authenticated;

COMMENT ON POLICY quote_read_authorized ON public.portal_offers IS
  'P0-1d/P0-1e: authenticated has table SELECT, but rows are visible only through portal_can_view_quotes(...).';
COMMENT ON POLICY quote_items_read_authorized ON public.portal_offer_items IS
  'P0-1d/P0-1e: quote item rows follow parent offer quote confidentiality gate.';
COMMENT ON POLICY award_read_authorized ON public.portal_award IS
  'P0-1d/P0-1e: award-pricing rows are confidential and gated by portal_can_view_quotes(...).';
COMMENT ON POLICY award_lines_read_authorized ON public.portal_award_lines IS
  'P0-1d/P0-1e: award line rows are confidential and gated by portal_can_view_quotes(...).';

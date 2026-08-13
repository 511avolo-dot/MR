// Isolated-target guard for the authenticated E2E. Ensures the hosted portal-config
// resolves ONLY to the expected isolated staging Supabase project — validating BOTH the
// ref AND the URL host, and explicitly rejecting the production project ref in either.
// Used by the Node preflight; the same checks are mirrored inside the browser context
// before any authenticated REST call.
export const PROD_REF = 'mwbjoysuybgbrvfrprex';

export function validateTarget(cfg, expectedRef) {
  if (!cfg || cfg.ok !== true) throw new Error('portal-config is not ok:true');
  if (cfg.env !== 'preview') throw new Error(`portal-config env must be preview, got "${cfg.env}"`);
  if (!/^[a-z0-9]{20}$/.test(String(expectedRef)) || expectedRef === PROD_REF) {
    throw new Error('EXPECTED_STAGING_REF is malformed or is the production ref');
  }
  if (cfg.ref !== expectedRef) throw new Error(`portal-config ref "${cfg.ref}" != expected "${expectedRef}"`);
  if (String(cfg.ref).includes(PROD_REF)) throw new Error('portal-config ref contains the production project ref');
  let host;
  try { host = new URL(String(cfg.url)).hostname; } catch { throw new Error(`portal-config url is not a valid URL: "${cfg.url}"`); }
  if (host !== `${expectedRef}.supabase.co`) {
    throw new Error(`portal-config url host "${host}" != "${expectedRef}.supabase.co" (ref/url mismatch)`);
  }
  if (String(cfg.url).includes(PROD_REF)) throw new Error('portal-config url contains the production project ref');
  return true;
}

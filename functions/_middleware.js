// Portal permission/security guard + functional studio injection for Cloudflare Pages.
//
// Server/RLS remains the authoritative security boundary. The owner-approved
// legacy visual design is preserved: enterprise-ui.css/js are intentionally no
// longer injected. Functional document/quote/policy/access tools remain.

const PORTAL_ASSETS = `
<script src="/assets/document-studio.js?v=2" data-portal-asset="document-studio"></script>
<script src="/assets/generated-document-studio.js?v=1" data-portal-asset="generated-document-studio"></script>
<script src="/assets/quote-document-studio.js?v=1" data-portal-asset="quote-document-studio"></script>
<script src="/assets/policy-studio.js?v=1" data-portal-asset="policy-studio"></script>
<script src="/assets/access-inspector.js?v=1" data-portal-asset="access-inspector"></script>
<script src="/assets/payment-evidence-guard.js?v=1" data-portal-asset="payment-evidence-guard"></script>
`;

const PORTAL_UI_GUARD = `
(function(){
  function safeCall(fn, fallback){ try { return fn(); } catch(_e) { return fallback; } }
  function currentAccess(){ return safeCall(function(){ return accessOf(ME) || {}; }, {}); }
  function currentCan(){ var a = currentAccess(); return a.can || {}; }
  function currentSee(){ var a = currentAccess(); return a.see || {}; }
  function admin(){ return safeCall(function(){ return isAdmin(); }, false); }
  function hasDirectExpense(){ var c = currentCan(); return admin() || !!c.directExpense || !!c.canCreateDirectExpense; }
  function canUseExpenseTab(){ var c = currentCan(); var s = currentSee(); return hasDirectExpense() || !!c.approveDisb || !!c.disburse || !!s.finance; }
  function canViewQuotes(){ var c = currentCan(); return admin() || !!c.viewQuotes || !!c.manageRfq || !!c.approveAward || !!c.issuePO; }
  function txt(el){ return ((el && el.textContent) || '').replace(/\\s+/g,' ').trim(); }
  function closestBlock(el){ return el && el.closest && el.closest('.card,.modal,.doc-card,.print-sheet,section,article'); }

  var originalPaCan = safeCall(function(){ return pa_can; }, null);
  if (typeof originalPaCan === 'function') {
    pa_can = function(p){
      var c = originalPaCan(p) || {};
      p = p || {};
      c.directExpense = !!p.can_create_direct_expense;
      c.viewQuotes = !!(p.can_view_quotes || p.can_manage_procurement || p.can_approve_award || p.can_issue_po);
      return c;
    };
  }

  var originalPaSee = safeCall(function(){ return pa_see; }, null);
  if (typeof originalPaSee === 'function') {
    pa_see = function(p){
      var s = originalPaSee(p) || { requests: 1 };
      p = p || {};
      var quote = !!(p.can_view_quotes || p.can_manage_procurement || p.can_approve_award || p.can_issue_po);
      s.award = quote ? 1 : 0;
      s.comparison = quote ? 1 : 0;
      return s;
    };
  }

  safeCall(function(){ _pa_expCanUse = function(){ return canUseExpenseTab(); }; }, null);

  function scrubUnauthorizedUi(){
    var allowDirectCreate = hasDirectExpense();
    var allowQuotes = canViewQuotes();

    if (!canUseExpenseTab()) {
      document.querySelectorAll('button,a').forEach(function(el){
        if (/صرف مباشر/.test(txt(el))) el.style.display = 'none';
      });
    }

    if (!allowDirectCreate) {
      document.querySelectorAll('*').forEach(function(el){
        var t = txt(el);
        if (!/طلب صرف مباشر جديد/.test(t)) return;
        var b = closestBlock(el);
        if (b) b.remove();
      });
    }

    if (!allowQuotes) {
      var quoteRe = /(ملفات عروض الأسعار|محضر مقارنة عروض الأسعار|مقارنة عروض|مقارنة الأسعار|العروض المستلمة|المورد الفائز|التعميد|بيانات الترسية)/;
      document.querySelectorAll('*').forEach(function(el){
        if (el.children && el.children.length > 0) return;
        if (!quoteRe.test(txt(el))) return;
        var b = closestBlock(el);
        if (b) b.remove();
      });
    }
  }

  var originalRender = safeCall(function(){ return render; }, null);
  if (typeof originalRender === 'function') {
    render = function(){
      var out = originalRender.apply(this, arguments);
      setTimeout(scrubUnauthorizedUi, 0);
      setTimeout(scrubUnauthorizedUi, 60);
      return out;
    };
  }

  document.addEventListener('DOMContentLoaded', function(){
    scrubUnauthorizedUi();
    safeCall(function(){
      new MutationObserver(scrubUnauthorizedUi).observe(document.documentElement, { childList: true, subtree: true });
    }, null);
  });
  setTimeout(scrubUnauthorizedUi, 250);
})();
`;

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const isPortal = url.pathname === '/purchase-portal' || url.pathname === '/purchase-portal.html';
  const response = await context.next();

  if (!isPortal) return response;
  const contentType = response.headers.get('content-type') || '';
  if (!contentType.includes('text/html')) return response;

  return new HTMLRewriter()
    .on('head', {
      element(element) {
        element.append(
          '<link rel="stylesheet" href="/assets/generated-document-studio.css?v=1" data-portal-asset="generated-document-studio"><link rel="stylesheet" href="/assets/quote-document-studio.css?v=1" data-portal-asset="quote-document-studio"><link rel="stylesheet" href="/assets/access-inspector.css?v=1" data-portal-asset="access-inspector">',
          { html: true },
        );
      },
    })
    .on('body', {
      element(element) {
        element.append(PORTAL_ASSETS + `<script>${PORTAL_UI_GUARD}</script>`, { html: true });
      },
    })
    .transform(response);
}

/* Aldeyabi Procurement — enterprise interaction layer. */
(function enterpriseUiBootstrap(){
  'use strict';

  var VERSION = '1.0.0';
  var observer = null;
  var scheduled = false;

  function safe(fn, fallback){
    try { return fn(); } catch (_e) { return fallback; }
  }

  function text(value){ return String(value == null ? '' : value); }

  function createSkipLink(){
    if (document.querySelector('.eui-skip-link')) return;
    var link = document.createElement('a');
    link.className = 'eui-skip-link';
    link.href = '#eui-main';
    link.textContent = 'تجاوز إلى المحتوى الرئيسي';
    document.body.insertBefore(link, document.body.firstChild);
  }

  function createLiveRegion(){
    if (document.getElementById('eui-live-region')) return;
    var region = document.createElement('div');
    region.id = 'eui-live-region';
    region.setAttribute('role', 'status');
    region.setAttribute('aria-live', 'polite');
    region.setAttribute('aria-atomic', 'true');
    region.style.cssText = 'position:fixed;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;';
    document.body.appendChild(region);
  }

  function announce(message){
    var region = document.getElementById('eui-live-region');
    if (!region) return;
    region.textContent = '';
    setTimeout(function(){ region.textContent = text(message); }, 25);
  }

  function mainContainer(){
    return document.querySelector('.wrap') || document.querySelector('main') || document.body;
  }

  function enhanceLandmarks(){
    var main = mainContainer();
    if (main && !main.id) main.id = 'eui-main';
    if (main && !main.getAttribute('role') && main.tagName !== 'MAIN') main.setAttribute('role', 'main');
    var nav = document.querySelector('.nav');
    if (nav) {
      nav.setAttribute('role', 'navigation');
      nav.setAttribute('aria-label', 'التنقل الرئيسي');
    }
  }

  function enhanceButtons(){
    document.querySelectorAll('button').forEach(function(button){
      if (!button.type) button.type = 'button';
      var readable = (button.textContent || '').replace(/\s+/g, ' ').trim();
      var title = button.getAttribute('title');
      if (!button.getAttribute('aria-label') && title && readable.length < 2) button.setAttribute('aria-label', title);
      if (button.disabled) button.setAttribute('aria-disabled', 'true');
      else button.removeAttribute('aria-disabled');
    });
  }

  function enhanceForms(){
    document.querySelectorAll('input,select,textarea').forEach(function(field){
      if (!field.id) return;
      var label = document.querySelector('label[for="' + CSS.escape(field.id) + '"]');
      if (label) return;
      var parentLabel = field.closest('label');
      if (parentLabel) return;
      var previous = field.previousElementSibling;
      if (previous && previous.tagName === 'LABEL') {
        previous.setAttribute('for', field.id);
      }
    });
  }

  function enhanceTables(){
    document.querySelectorAll('table').forEach(function(table){
      if (!table.getAttribute('role')) table.setAttribute('role', 'table');
      if (!table.getAttribute('aria-label')) {
        var section = table.closest('.card');
        var title = section && section.querySelector('.sec-title,h2,h3');
        if (title) table.setAttribute('aria-label', (title.textContent || '').replace(/\s+/g, ' ').trim());
      }
      table.querySelectorAll('thead th').forEach(function(th){ if (!th.getAttribute('scope')) th.setAttribute('scope', 'col'); });
    });
  }

  function requestStateLabel(request){
    if (!request) return '';
    var raw = safe(function(){ return request._raw && request._raw.status; }, '') || request.status || request.phase || '';
    var labels = {
      draft: 'مسودة', returned: 'معاد للاستكمال', pending: 'قيد الإجراء',
      need: 'اعتماد الاحتياج', pricing: 'قيد طلب العروض', award: 'قيد التعميد',
      po: 'أمر الشراء', receipt: 'الاستلام', payment: 'الصرف',
      disb: 'قيد الاعتماد المالي', pay: 'قيد التنفيذ', closed: 'مكتمل', cancelled: 'ملغي'
    };
    return labels[raw] || text(raw).replace(/_/g, ' ') || 'قيد المعالجة';
  }

  function currentRequest(){
    return safe(function(){
      if (!window.CURRENT || !Array.isArray(window.REQS)) return null;
      return window.REQS.find(function(item){ return item.id === window.CURRENT; }) || null;
    }, null);
  }

  function enhanceDetailContext(){
    var main = mainContainer();
    if (!main) return;
    var existing = main.querySelector(':scope > .eui-context-strip');
    var isDetail = safe(function(){ return window.VIEW === 'detail'; }, false);
    var request = isDetail ? currentRequest() : null;
    if (!request) {
      if (existing) existing.remove();
      return;
    }
    var stateLabel = requestStateLabel(request);
    var title = request.title || request.purpose || 'معاملة';
    var meta = [request.id, request.dept || request.department || '', request.requester ? 'مقدم الطلب: ' + safe(function(){ return window.uName(request.requester); }, request.requester) : '']
      .filter(Boolean).join(' · ');
    if (!existing) {
      existing = document.createElement('section');
      existing.className = 'eui-context-strip';
      existing.setAttribute('aria-label', 'سياق المعاملة الحالية');
      main.insertBefore(existing, main.firstChild);
    }
    existing.innerHTML = '<div><div class="eui-context-strip__title"></div><div class="eui-context-strip__meta"></div></div><div class="eui-context-strip__state"></div>';
    existing.querySelector('.eui-context-strip__title').textContent = title;
    existing.querySelector('.eui-context-strip__meta').textContent = meta;
    existing.querySelector('.eui-context-strip__state').textContent = stateLabel;
  }

  function enhanceModal(){
    var overlay = document.getElementById('overlay');
    var modal = document.getElementById('modal');
    if (!overlay || !modal) return;
    var visible = overlay.classList.contains('show');
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', visible ? 'true' : 'false');
    if (visible) {
      var heading = modal.querySelector('h1,h2,h3');
      if (heading) {
        if (!heading.id) heading.id = 'eui-modal-title';
        modal.setAttribute('aria-labelledby', heading.id);
      }
    }
  }

  function enhance(){
    scheduled = false;
    document.documentElement.setAttribute('data-enterprise-ui', 'true');
    document.documentElement.setAttribute('data-enterprise-ui-version', VERSION);
    createSkipLink();
    createLiveRegion();
    enhanceLandmarks();
    enhanceButtons();
    enhanceForms();
    enhanceTables();
    enhanceDetailContext();
    enhanceModal();
    safe(function(){
      if (window.AldeyabiPolicyStudio && typeof window.AldeyabiPolicyStudio.refreshVisibility === 'function') {
        window.AldeyabiPolicyStudio.refreshVisibility();
      }
    });
  }

  function scheduleEnhance(){
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(enhance);
  }

  function installRenderBridge(){
    if (window.__enterpriseUiRenderBridge || typeof window.render !== 'function') return;
    var originalRender = window.render;
    window.render = function(){
      var result = originalRender.apply(this, arguments);
      scheduleEnhance();
      return result;
    };
    window.__enterpriseUiRenderBridge = true;
  }

  function boot(){
    enhance();
    installRenderBridge();
    if (!observer) {
      observer = new MutationObserver(scheduleEnhance);
      observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'disabled'] });
    }
    setTimeout(installRenderBridge, 600);
  }

  window.AldeyabiEnterpriseUI = {
    version: VERSION,
    enhance: enhance,
    announce: announce
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();

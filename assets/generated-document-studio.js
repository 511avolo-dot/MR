/*
 * Aldeyabi Generated Document Studio
 * Converts legacy print-only purchase requests, POs, receipts and vouchers into
 * a calm in-portal preview. The existing print function remains as fallback.
 */
(function generatedDocumentStudioBootstrap(){
  'use strict';

  var state = {
    root: null,
    iframe: null,
    scale: 1,
    fit: 'width',
    previousFocus: null,
    keyHandler: null,
    originalPrint: null
  };

  function safe(fn, fallback){ try { return fn(); } catch (_e) { return fallback; } }
  function esc(value){
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }

  function canSeeFinancials(){
    return safe(function(){
      if (window.isAdmin && window.isAdmin()) return true;
      var access = window.accessOf(window.ME) || {};
      var can = access.can || {};
      var see = access.see || {};
      return !!(see.finance || can.viewQuotes || can.manageRfq || can.approveAward || can.issuePO || can.approveDisb || can.disburse);
    }, false);
  }

  function removeColumn(table, index){
    table.querySelectorAll('tr').forEach(function(row){
      var cell = row.children[index];
      if (cell) cell.remove();
    });
  }

  function privacySanitize(clone){
    if (canSeeFinancials()) return;
    clone.querySelectorAll('table').forEach(function(table){
      var headings = Array.prototype.slice.call(table.querySelectorAll('thead th'));
      var indexes = [];
      headings.forEach(function(th, index){
        var label = (th.textContent || '').replace(/\s+/g, ' ').trim();
        if (/(سعر|الإجمالي|القيمة|المبلغ|الضريبة|خصم)/.test(label)) indexes.push(index);
      });
      indexes.sort(function(a, b){ return b - a; }).forEach(function(index){ removeColumn(table, index); });
    });
    clone.querySelectorAll('.doc-words,.financial-only,[data-financial]').forEach(function(node){ node.remove(); });
    clone.querySelectorAll('*').forEach(function(node){
      if (node.children.length) return;
      var label = (node.textContent || '').replace(/\s+/g, ' ').trim();
      if (/^(الإجمالي|القيمة|المبلغ|الضريبة|السعر)/.test(label)) {
        var block = node.closest('.meta-cell,.doc-meta-item,.r');
        if (block) block.remove();
      }
    });
  }

  function cloneDocument(element){
    var clone = element.cloneNode(true);
    clone.removeAttribute('id');
    clone.querySelectorAll('.doc-actions,button,script,iframe,object,embed,input,textarea,select,[data-no-print]').forEach(function(node){ node.remove(); });
    clone.querySelectorAll('[id]').forEach(function(node){ node.removeAttribute('id'); });
    privacySanitize(clone);
    return clone;
  }

  function styleHead(){
    var styles = Array.prototype.slice.call(document.querySelectorAll('head style,head link[rel="stylesheet"]'))
      .map(function(node){ return node.outerHTML; }).join('\n');
    return styles + '<style>'
      + 'html,body{margin:0;background:#eef1f4;color:#172033;font-family:inherit;direction:rtl}'
      + 'body{padding:24px;box-sizing:border-box}'
      + '.gds-document{width:min(210mm,100%);min-height:297mm;margin:0 auto;background:#fff;box-shadow:0 8px 28px rgba(20,32,51,.12);box-sizing:border-box}'
      + '.gds-document>.doc-sheet,.gds-document>.print-sheet,.gds-document>.document{box-shadow:none!important;margin:0!important;max-width:none!important;width:100%!important}'
      + '.doc-actions,button{display:none!important}'
      + '@page{size:A4;margin:12mm}'
      + '@media print{html,body{background:#fff;padding:0}.gds-document{width:100%;min-height:auto;box-shadow:none}.card{box-shadow:none!important}}'
      + '</style>';
  }

  function documentHtml(element, title, reference){
    var clone = cloneDocument(element);
    return '<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'
      + esc(title || 'مستند') + (reference ? ' — ' + esc(reference) : '') + '</title>' + styleHead() + '</head><body><main class="gds-document">'
      + clone.outerHTML + '</main></body></html>';
  }

  function toolbar(title, reference){
    return '<header class="gds-toolbar">'
      + '<div class="gds-brand"><div class="gds-title">' + esc(title || 'معاينة مستند') + '</div><div class="gds-meta">' + esc(reference || 'مستند صادر من البوابة') + ' · معاينة قبل الطباعة</div></div>'
      + '<div class="gds-group" aria-label="التكبير">'
      + '<button class="gds-btn" type="button" data-gds-action="zoom-out" aria-label="تصغير">−</button>'
      + '<button class="gds-btn" type="button" data-gds-action="reset">100%</button>'
      + '<button class="gds-btn" type="button" data-gds-action="zoom-in" aria-label="تكبير">+</button>'
      + '</div>'
      + '<div class="gds-group" aria-label="طريقة العرض">'
      + '<button class="gds-btn" type="button" data-gds-action="fit-width" aria-pressed="true">ملاءمة العرض</button>'
      + '<button class="gds-btn" type="button" data-gds-action="fit-page" aria-pressed="false">ملاءمة الصفحة</button>'
      + '</div>'
      + '<div class="gds-spacer"></div>'
      + '<button class="gds-btn" type="button" data-gds-action="print">طباعة / حفظ PDF</button>'
      + '<button class="gds-btn gds-close" type="button" data-gds-action="close" aria-label="إغلاق">×</button>'
      + '</header>';
  }

  function open(domId, title, reference){
    var element = typeof domId === 'string' ? document.getElementById(domId) : domId;
    if (!element) {
      if (typeof state.originalPrint === 'function') return state.originalPrint.apply(window, arguments);
      safe(function(){ window.toast('تعذّر العثور على المستند', 'err'); });
      return;
    }
    close(false);
    state.previousFocus = document.activeElement;
    state.scale = 1;
    state.fit = 'width';
    state.root = document.createElement('div');
    state.root.className = 'gds-root';
    state.root.setAttribute('role', 'dialog');
    state.root.setAttribute('aria-modal', 'true');
    state.root.setAttribute('aria-label', 'معاينة ' + (title || 'المستند'));
    state.root.innerHTML = toolbar(title, reference) + '<main class="gds-stage"><div class="gds-paper-wrap"><iframe class="gds-frame" title="' + esc(title || 'المستند') + '"></iframe></div></main>';
    document.body.appendChild(state.root);
    document.body.style.overflow = 'hidden';
    state.iframe = state.root.querySelector('.gds-frame');
    state.iframe.srcdoc = documentHtml(element, title, reference);
    state.root.addEventListener('click', handleClick);
    state.keyHandler = function(event){
      if (event.key === 'Escape') { event.preventDefault(); close(); }
      else if ((event.ctrlKey || event.metaKey) && (event.key === '+' || event.key === '=')) { event.preventDefault(); zoom(.1); }
      else if ((event.ctrlKey || event.metaKey) && event.key === '-') { event.preventDefault(); zoom(-.1); }
      else if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'p') { event.preventDefault(); print(); }
    };
    document.addEventListener('keydown', state.keyHandler);
    state.root.querySelector('[data-gds-action="close"]').focus();
  }

  function paper(){ return state.root && state.root.querySelector('.gds-paper-wrap'); }
  function apply(){
    var wrap = paper();
    if (wrap) {
      wrap.style.transform = 'scale(' + state.scale + ')';
      wrap.style.marginBottom = Math.max(0, (state.scale - 1) * 260) + 'px';
    }
    var reset = state.root && state.root.querySelector('[data-gds-action="reset"]');
    if (reset) reset.textContent = Math.round(state.scale * 100) + '%';
    var width = state.root && state.root.querySelector('[data-gds-action="fit-width"]');
    var page = state.root && state.root.querySelector('[data-gds-action="fit-page"]');
    if (width) width.setAttribute('aria-pressed', state.fit === 'width' ? 'true' : 'false');
    if (page) page.setAttribute('aria-pressed', state.fit === 'page' ? 'true' : 'false');
  }
  function zoom(delta){ state.fit = 'custom'; state.scale = Math.min(2.2, Math.max(.55, Math.round((state.scale + delta) * 10) / 10)); apply(); }
  function reset(){ state.fit = 'width'; state.scale = 1; apply(); }
  function fit(mode){ state.fit = mode; state.scale = mode === 'page' ? .78 : 1; apply(); }
  function print(){
    if (!state.iframe) return;
    safe(function(){ state.iframe.contentWindow.focus(); state.iframe.contentWindow.print(); });
  }

  function handleClick(event){
    var button = event.target.closest('[data-gds-action]');
    if (!button) return;
    var action = button.getAttribute('data-gds-action');
    if (action === 'close') close();
    else if (action === 'zoom-in') zoom(.1);
    else if (action === 'zoom-out') zoom(-.1);
    else if (action === 'reset') reset();
    else if (action === 'fit-width') fit('width');
    else if (action === 'fit-page') fit('page');
    else if (action === 'print') print();
  }

  function close(restoreFocus){
    if (state.keyHandler) document.removeEventListener('keydown', state.keyHandler);
    state.keyHandler = null;
    if (state.root && state.root.parentNode) state.root.parentNode.removeChild(state.root);
    state.root = null;
    state.iframe = null;
    document.body.style.overflow = '';
    if (restoreFocus !== false && state.previousFocus && typeof state.previousFocus.focus === 'function') safe(function(){ state.previousFocus.focus(); });
    state.previousFocus = null;
  }

  function installBridge(){
    if (window.__generatedDocumentStudioBridge) return;
    if (typeof window.printEl === 'function') {
      state.originalPrint = window.printEl;
      window.__gdsOriginalPrintEl = window.printEl;
      window.printEl = function(domId, title, reference){ return open(domId, title, reference); };
      window.__generatedDocumentStudioBridge = true;
    }
  }

  window.AldeyabiGeneratedDocumentStudio = { open: open, close: close, print: print, version: '1.0.0' };
  installBridge();
  document.addEventListener('DOMContentLoaded', installBridge, { once: true });
  setTimeout(installBridge, 500);
})();

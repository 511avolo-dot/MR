/*
 * Quote Document Studio
 * Replaces the legacy quotation modal with an authenticated, in-portal viewer.
 * The server endpoint remains authoritative and now enforces can_view_quotes.
 */
(function quoteDocumentStudioBootstrap(){
  'use strict';

  var state = {
    root: null,
    request: null,
    docs: [],
    selected: [],
    mode: 'compare',
    nextSlot: 1,
    objectUrls: [],
    previousFocus: null,
    keyHandler: null
  };

  function safe(fn, fallback){ try { return fn(); } catch (_e) { return fallback; } }
  function esc(value){
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }
  function money(value){ return (Number(value) || 0).toLocaleString('en-US') + ' ر.س'; }
  function toast(message, kind){ safe(function(){ window.toast(message, kind || 'err'); }); }

  async function token(){
    if (!window.SB || !window.SB.auth) throw new Error('جلسة البوابة غير متاحة');
    var result = await window.SB.auth.getSession();
    var value = result && result.data && result.data.session && result.data.session.access_token;
    if (!value) throw new Error('انتهت جلسة الدخول');
    return value;
  }

  async function load(doc){
    if (doc.resource) return doc.resource;
    var jwt = await token();
    var response = await fetch('/api/portal-quote?key=' + encodeURIComponent(doc.key), {
      headers: { Authorization: 'Bearer ' + jwt },
      cache: 'no-store'
    });
    if (!response.ok) throw new Error('تعذّر تحميل عرض ' + doc.title);
    var blob = await response.blob();
    if (!blob || !blob.size) throw new Error('ملف عرض ' + doc.title + ' فارغ');
    var url = URL.createObjectURL(blob);
    state.objectUrls.push(url);
    doc.resource = { url: url, mime: blob.type || 'application/pdf', size: blob.size };
    return doc.resource;
  }

  function revoke(){
    state.objectUrls.forEach(function(url){ safe(function(){ URL.revokeObjectURL(url); }); });
    state.objectUrls = [];
  }

  function canOpenQuotes(){
    return safe(function(){
      if (window.isAdmin && window.isAdmin()) return true;
      var access = window.accessOf(window.ME) || {};
      var can = access.can || {};
      return !!(can.viewQuotes || can.manageRfq || can.approveAward || can.issuePO);
    }, false);
  }

  function buildDocuments(reqId, sids){
    var request = safe(function(){ return (window.REQS || []).find(function(item){ return item.id === reqId; }); }, null);
    if (!request || !request.proc) return { request: request, docs: [] };
    var proc = request.proc;
    var ids = Array.isArray(sids) && sids.length
      ? sids.map(function(value){ try { return decodeURIComponent(value); } catch (_e) { return value; } })
      : (proc.supplierList || []).slice();
    var docs = ids.map(function(sid){
      var offer = proc.offers && proc.offers[sid];
      if (!offer || !offer.quotePdfKey) return null;
      var supplier = safe(function(){ return window.SUPPLIERS[sid].n; }, '') || offer.supplierName || sid;
      return {
        sid: sid,
        key: offer.quotePdfKey,
        title: supplier,
        total: Number(offer.total) || 0,
        deliveryDays: Number(offer.deliveryDays) || 0,
        offer: offer
      };
    }).filter(Boolean);
    return { request: request, docs: docs };
  }

  function toolbar(){
    var ref = state.request && state.request.id || '';
    return '<header class="eds-toolbar">'
      + '<div class="eds-brand"><div class="eds-title">استوديو عروض الأسعار</div><div class="eds-meta">' + esc(ref) + ' · معاينة سرية داخل البوابة</div></div>'
      + '<div class="eds-toolbar__group" aria-label="نمط العرض">'
      + '<button class="eds-btn" type="button" data-qds-action="single" aria-pressed="' + (state.mode === 'single') + '">عرض مفرد</button>'
      + '<button class="eds-btn" type="button" data-qds-action="compare" aria-pressed="' + (state.mode === 'compare') + '" ' + (state.docs.length < 2 ? 'disabled' : '') + '>مقارنة</button>'
      + '</div>'
      + '<div class="eds-spacer"></div>'
      + '<button class="eds-btn" type="button" data-qds-action="download" title="تنزيل العرض المحدد">↓</button>'
      + '<button class="eds-btn eds-close" type="button" data-qds-action="close" aria-label="إغلاق">×</button>'
      + '</header>';
  }

  function sidebar(){
    var best = state.docs.reduce(function(min, doc){ return doc.total > 0 && doc.total < min ? doc.total : min; }, Infinity);
    return '<aside class="eds-sidebar" aria-label="عروض الموردين">'
      + '<div class="qds-summary"><div class="qds-summary__label">عدد العروض المتاحة</div><div class="qds-summary__value">' + state.docs.length + '</div></div>'
      + '<div class="eds-sidebar__title">الموردون</div>'
      + state.docs.map(function(doc, index){
          var selected = state.selected.indexOf(index) >= 0;
          var meta = doc.deliveryDays ? 'توريد خلال ' + doc.deliveryDays + ' يوم' : 'مدة التوريد غير محددة';
          return '<button class="eds-file-card qds-card" type="button" data-qds-index="' + index + '" data-selected="' + selected + '" aria-current="' + selected + '">'
            + '<div class="eds-file-card__name">' + esc(doc.title) + (doc.total === best ? ' · الأقل سعراً' : '') + '</div>'
            + '<div class="qds-card__amount">' + esc(money(doc.total)) + '</div>'
            + '<div class="eds-file-card__meta">' + esc(meta) + '</div>'
            + '</button>';
        }).join('')
      + '<div class="qds-hint">في وضع المقارنة: اضغط مورداً لاستبدال إحدى جهتي المقارنة. الملفات تبقى داخل البوابة ولا يُنشأ رابط R2 عام.</div>'
      + '</aside>';
  }

  function viewer(doc){
    if (!doc || !doc.resource) return '<div class="qds-loading-card">جارٍ تحميل العرض…</div>';
    var mime = String(doc.resource.mime || '').toLowerCase();
    if (mime.indexOf('image/') === 0) return '<div class="eds-canvas"><img class="eds-image" src="' + doc.resource.url + '" alt="عرض سعر ' + esc(doc.title) + '"></div>';
    return '<div class="eds-canvas"><iframe class="eds-frame" title="عرض سعر ' + esc(doc.title) + '" src="' + doc.resource.url + '#toolbar=0&navpanes=0&scrollbar=1&view=FitH"></iframe></div>';
  }

  function pane(doc){
    return '<section class="qds-pane">'
      + '<div class="qds-pane__head"><div class="qds-pane__supplier">' + esc(doc.title) + '</div><div class="qds-pane__amount">' + esc(money(doc.total)) + '</div></div>'
      + viewer(doc)
      + '</section>';
  }

  function render(){
    if (!state.root) return;
    state.root.classList.toggle('eds-compare', state.mode === 'compare');
    state.root.classList.toggle('qds-single', state.mode === 'single');
    var toolbarHost = state.root.querySelector('[data-qds-toolbar]');
    var sidebarHost = state.root.querySelector('[data-qds-sidebar]');
    var stage = state.root.querySelector('[data-qds-stage]');
    if (toolbarHost) toolbarHost.innerHTML = toolbar();
    if (sidebarHost) sidebarHost.innerHTML = sidebar();
    var indexes = state.mode === 'compare' ? state.selected.slice(0, 2) : state.selected.slice(0, 1);
    if (!indexes.length && state.docs.length) indexes = [0];
    if (stage) stage.innerHTML = indexes.map(function(index){ return pane(state.docs[index]); }).join('');
  }

  function mount(){
    state.previousFocus = document.activeElement;
    state.root = document.createElement('div');
    state.root.className = 'eds-root qds-root';
    state.root.setAttribute('role', 'dialog');
    state.root.setAttribute('aria-modal', 'true');
    state.root.setAttribute('aria-label', 'استوديو عروض الأسعار');
    state.root.innerHTML = '<div data-qds-toolbar></div><div class="eds-layout"><div data-qds-sidebar></div><main class="eds-stage" data-qds-stage></main></div>';
    document.body.appendChild(state.root);
    document.body.style.overflow = 'hidden';
    state.root.addEventListener('click', handleClick);
    state.keyHandler = function(event){ if (event.key === 'Escape') { event.preventDefault(); close(); } };
    document.addEventListener('keydown', state.keyHandler);
    render();
    var closeButton = state.root.querySelector('[data-qds-action="close"]');
    if (closeButton) closeButton.focus();
  }

  function handleClick(event){
    var action = event.target.closest('[data-qds-action]');
    if (action) {
      var value = action.getAttribute('data-qds-action');
      if (value === 'close') return close();
      if (value === 'single') { state.mode = 'single'; state.selected = [state.selected[0] || 0]; render(); return; }
      if (value === 'compare' && state.docs.length > 1) { state.mode = 'compare'; if (state.selected.length < 2) state.selected = [state.selected[0] || 0, 1]; render(); return; }
      if (value === 'download') return downloadSelected();
    }
    var card = event.target.closest('[data-qds-index]');
    if (!card) return;
    var index = Number(card.getAttribute('data-qds-index'));
    if (!Number.isInteger(index) || !state.docs[index]) return;
    if (state.mode === 'single') state.selected = [index];
    else {
      if (state.selected.indexOf(index) >= 0) return;
      if (state.selected.length < 2) state.selected.push(index);
      else { state.selected[state.nextSlot] = index; state.nextSlot = state.nextSlot === 0 ? 1 : 0; }
    }
    render();
  }

  function downloadSelected(){
    var index = state.selected[0] || 0;
    var doc = state.docs[index];
    if (!doc || !doc.resource) return;
    var anchor = document.createElement('a');
    anchor.href = doc.resource.url;
    anchor.download = 'عرض سعر - ' + doc.title + (String(doc.resource.mime).indexOf('image/') === 0 ? '.png' : '.pdf');
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
  }

  async function open(reqId, sids){
    if (!canOpenQuotes()) {
      toast('لا تملك صلاحية مشاهدة عروض الأسعار', 'err');
      return;
    }
    var built = buildDocuments(reqId, sids);
    if (!built.request || !built.docs.length) {
      toast('لا توجد ملفات عروض متاحة لهذا الطلب', 'err');
      return;
    }
    close(false);
    state.request = built.request;
    state.docs = built.docs;
    state.selected = state.docs.length > 1 ? [0, 1] : [0];
    state.mode = state.docs.length > 1 ? 'compare' : 'single';
    state.nextSlot = 1;
    mount();
    try {
      await Promise.all(state.docs.map(load));
      render();
    } catch (error) {
      if (state.root) {
        var stage = state.root.querySelector('[data-qds-stage]');
        if (stage) stage.innerHTML = '<div class="eds-error" role="alert"><b>تعذّر تحميل بعض عروض الأسعار</b><br>' + esc(error && error.message || '') + '</div>';
      }
    }
  }

  function close(restoreFocus){
    if (state.keyHandler) document.removeEventListener('keydown', state.keyHandler);
    state.keyHandler = null;
    if (state.root && state.root.parentNode) state.root.parentNode.removeChild(state.root);
    state.root = null;
    document.body.style.overflow = '';
    revoke();
    state.request = null;
    state.docs = [];
    state.selected = [];
    if (restoreFocus !== false && state.previousFocus && typeof state.previousFocus.focus === 'function') safe(function(){ state.previousFocus.focus(); });
    state.previousFocus = null;
  }

  window.AldeyabiQuoteStudio = { open: open, close: close, version: '1.0.1' };
  window.openQuoteViewer = open;
  window.pa_qvClose = close;
})();

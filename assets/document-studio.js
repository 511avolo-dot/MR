/*
 * Aldeyabi Document Studio
 * Authenticated, in-portal preview for PDF/JPEG/PNG with document navigation,
 * keyboard controls, fit/zoom/rotate, print/download and side-by-side comparison.
 */
(function documentStudioBootstrap(){
  'use strict';

  var state = {
    root: null,
    objectUrls: [],
    current: null,
    documents: [],
    scale: 1,
    rotation: 0,
    fit: 'width',
    page: 1,
    compare: false,
    previousFocus: null,
    keyHandler: null
  };

  function escapeHtml(value){
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }

  function safe(fn, fallback){
    try { return fn(); } catch (_e) { return fallback; }
  }

  function filenameFromKey(key){
    var part = String(key || '').split('/').pop() || 'مستند';
    try { part = decodeURIComponent(part); } catch (_e) {}
    return part.replace(/^[0-9_-]+/, '') || 'مستند';
  }

  function typeLabel(type){
    var labels = {
      quotation: 'عرض سعر',
      supplier_invoice: 'فاتورة مورد',
      progress_claim: 'مستخلص',
      purchase_order: 'أمر شراء',
      contract: 'عقد',
      advance_payment: 'دفعة مقدمة',
      receipt: 'محضر استلام',
      beneficiary_bank: 'بيانات بنكية',
      memo: 'مذكرة',
      other: 'مستند'
    };
    return labels[type] || type || 'مستند';
  }

  function formatBytes(bytes){
    var n = Number(bytes) || 0;
    if (!n) return '';
    if (n < 1024) return n + ' ب';
    if (n < 1024 * 1024) return Math.round(n / 1024) + ' ك.ب';
    return (n / 1024 / 1024).toFixed(1) + ' م.ب';
  }

  async function accessToken(){
    if (!window.SB || !window.SB.auth) throw new Error('جلسة البوابة غير متاحة');
    var result = await window.SB.auth.getSession();
    var token = result && result.data && result.data.session && result.data.session.access_token;
    if (!token) throw new Error('انتهت جلسة الدخول. أعد تسجيل الدخول ثم حاول مرة أخرى.');
    return token;
  }

  async function fetchDocument(key){
    var token = await accessToken();
    var response = await fetch('/api/portal-doc?key=' + encodeURIComponent(key), {
      headers: { Authorization: 'Bearer ' + token },
      cache: 'no-store'
    });
    if (!response.ok) {
      var reason = await response.text().catch(function(){ return ''; });
      throw new Error(reason || 'تعذّر تحميل المستند');
    }
    var blob = await response.blob();
    if (!blob || !blob.size) throw new Error('المستند فارغ أو غير متاح');
    var url = URL.createObjectURL(blob);
    state.objectUrls.push(url);
    return { blob: blob, url: url, mime: blob.type || 'application/octet-stream' };
  }

  function revokeUrls(){
    state.objectUrls.forEach(function(url){ safe(function(){ URL.revokeObjectURL(url); }); });
    state.objectUrls = [];
  }

  function icon(name){
    var icons = {
      minus: '−', plus: '+', rotate: '↻', fitWidth: '↔', fitPage: '▣',
      print: '⌁', download: '↓', close: '×', previous: '‹', next: '›',
      compare: '▥', info: 'i'
    };
    return icons[name] || '•';
  }

  function toolbar(doc){
    var title = doc.title || doc.fileName || filenameFromKey(doc.key);
    var meta = [typeLabel(doc.type), formatBytes(doc.size)].filter(Boolean).join(' · ');
    return ''
      + '<header class="eds-toolbar">'
      +   '<div class="eds-brand">'
      +     '<div class="eds-title" title="' + escapeHtml(title) + '">' + escapeHtml(title) + '</div>'
      +     '<div class="eds-meta">' + escapeHtml(meta || 'معاينة داخل البوابة') + '</div>'
      +   '</div>'
      +   '<div class="eds-toolbar__group" aria-label="التكبير">'
      +     '<button class="eds-btn" type="button" data-eds-action="zoom-out" aria-label="تصغير">' + icon('minus') + '</button>'
      +     '<button class="eds-btn" type="button" data-eds-action="zoom-reset" aria-label="إعادة التكبير">100%</button>'
      +     '<button class="eds-btn" type="button" data-eds-action="zoom-in" aria-label="تكبير">' + icon('plus') + '</button>'
      +   '</div>'
      +   '<div class="eds-toolbar__group" aria-label="طريقة العرض">'
      +     '<button class="eds-btn" type="button" data-eds-action="fit-width" aria-pressed="true" title="ملاءمة العرض">' + icon('fitWidth') + '</button>'
      +     '<button class="eds-btn" type="button" data-eds-action="fit-page" aria-pressed="false" title="ملاءمة الصفحة">' + icon('fitPage') + '</button>'
      +     '<button class="eds-btn" type="button" data-eds-action="rotate" title="تدوير">' + icon('rotate') + '</button>'
      +   '</div>'
      +   '<div class="eds-spacer"></div>'
      +   '<div class="eds-toolbar__group">'
      +     '<button class="eds-btn" type="button" data-eds-action="print" title="طباعة">' + icon('print') + '</button>'
      +     '<button class="eds-btn" type="button" data-eds-action="download" title="تنزيل">' + icon('download') + '</button>'
      +   '</div>'
      +   '<button class="eds-btn eds-close" type="button" data-eds-action="close" aria-label="إغلاق">' + icon('close') + '</button>'
      + '</header>';
  }

  function sidebar(documents, activeKey){
    var docs = documents && documents.length ? documents : [state.current];
    return '<aside class="eds-sidebar" aria-label="مستندات المعاملة">'
      + '<div class="eds-sidebar__title">مستندات المعاملة</div>'
      + docs.map(function(doc){
          var title = doc.title || doc.fileName || filenameFromKey(doc.key);
          var meta = [typeLabel(doc.type), doc.version ? 'الإصدار ' + doc.version : '', formatBytes(doc.size)].filter(Boolean).join(' · ');
          return '<button class="eds-file-card" type="button" data-eds-key="' + escapeHtml(doc.key) + '" aria-current="' + (doc.key === activeKey ? 'true' : 'false') + '">'
            + '<div class="eds-file-card__name">' + escapeHtml(title) + '</div>'
            + '<div class="eds-file-card__meta">' + escapeHtml(meta) + '</div>'
            + '</button>';
        }).join('')
      + '</aside>';
  }

  function viewerMarkup(doc, resource, slot){
    var mime = String(resource.mime || doc.mime || '').toLowerCase();
    var title = doc.title || doc.fileName || filenameFromKey(doc.key);
    if (mime.indexOf('image/') === 0) {
      return '<div class="eds-canvas" data-eds-canvas="' + slot + '"><img class="eds-image" src="' + resource.url + '" alt="' + escapeHtml(title) + '"></div>';
    }
    var src = resource.url + '#toolbar=0&navpanes=0&scrollbar=1&view=FitH&page=1';
    return '<div class="eds-canvas" data-eds-canvas="' + slot + '"><iframe class="eds-frame" title="' + escapeHtml(title) + '" src="' + src + '"></iframe></div>';
  }

  function loadingMarkup(doc){
    return '<div class="eds-root" role="dialog" aria-modal="true" aria-label="معاينة المستند">'
      + toolbar(doc)
      + '<div class="eds-layout">'
      + sidebar(state.documents, doc.key)
      + '<main class="eds-stage" id="eds-stage"><div class="eds-loading" role="status">جارٍ تحميل المستند بأمان…</div></main>'
      + '</div></div>';
  }

  function mount(markup){
    close(false);
    state.previousFocus = document.activeElement;
    var host = document.createElement('div');
    host.innerHTML = markup;
    state.root = host.firstElementChild;
    document.body.appendChild(state.root);
    document.body.style.overflow = 'hidden';
    bindControls();
    var closeButton = state.root.querySelector('[data-eds-action="close"]');
    if (closeButton) closeButton.focus();
  }

  function bindControls(){
    if (!state.root) return;
    state.root.addEventListener('click', function(event){
      var actionButton = event.target.closest('[data-eds-action]');
      if (actionButton) {
        var action = actionButton.getAttribute('data-eds-action');
        handleAction(action);
        return;
      }
      var docButton = event.target.closest('[data-eds-key]');
      if (docButton) {
        var key = docButton.getAttribute('data-eds-key');
        var doc = state.documents.find(function(item){ return item.key === key; });
        if (doc) open(doc, { documents: state.documents });
      }
    });
    state.keyHandler = function(event){
      if (!state.root) return;
      if (event.key === 'Escape') { event.preventDefault(); close(); }
      else if ((event.ctrlKey || event.metaKey) && (event.key === '+' || event.key === '=')) { event.preventDefault(); zoom(.1); }
      else if ((event.ctrlKey || event.metaKey) && event.key === '-') { event.preventDefault(); zoom(-.1); }
      else if ((event.ctrlKey || event.metaKey) && event.key === '0') { event.preventDefault(); resetZoom(); }
    };
    document.addEventListener('keydown', state.keyHandler);
  }

  function handleAction(action){
    if (action === 'close') return close();
    if (action === 'zoom-in') return zoom(.1);
    if (action === 'zoom-out') return zoom(-.1);
    if (action === 'zoom-reset') return resetZoom();
    if (action === 'rotate') return rotate();
    if (action === 'fit-width') return fit('width');
    if (action === 'fit-page') return fit('page');
    if (action === 'download') return downloadCurrent();
    if (action === 'print') return printCurrent();
  }

  function canvases(){
    return state.root ? Array.prototype.slice.call(state.root.querySelectorAll('[data-eds-canvas]')) : [];
  }

  function applyTransform(){
    canvases().forEach(function(canvas){
      canvas.style.transform = 'scale(' + state.scale + ') rotate(' + state.rotation + 'deg)';
      canvas.style.marginBottom = Math.max(0, (state.scale - 1) * 240) + 'px';
    });
    var reset = state.root && state.root.querySelector('[data-eds-action="zoom-reset"]');
    if (reset) reset.textContent = Math.round(state.scale * 100) + '%';
  }

  function zoom(delta){
    state.fit = 'custom';
    state.scale = Math.min(2.5, Math.max(.55, Math.round((state.scale + delta) * 10) / 10));
    applyTransform();
    syncPressed();
  }

  function resetZoom(){
    state.scale = 1;
    state.rotation = 0;
    state.fit = 'width';
    applyTransform();
    syncPressed();
  }

  function rotate(){
    state.rotation = (state.rotation + 90) % 360;
    applyTransform();
  }

  function fit(mode){
    state.fit = mode;
    state.scale = mode === 'page' ? .86 : 1;
    applyTransform();
    var frames = state.root ? state.root.querySelectorAll('.eds-frame') : [];
    frames.forEach(function(frame){
      var base = frame.src.split('#')[0];
      frame.src = base + '#toolbar=0&navpanes=0&scrollbar=1&view=' + (mode === 'page' ? 'Fit' : 'FitH') + '&page=' + state.page;
    });
    syncPressed();
  }

  function syncPressed(){
    if (!state.root) return;
    var width = state.root.querySelector('[data-eds-action="fit-width"]');
    var page = state.root.querySelector('[data-eds-action="fit-page"]');
    if (width) width.setAttribute('aria-pressed', state.fit === 'width' ? 'true' : 'false');
    if (page) page.setAttribute('aria-pressed', state.fit === 'page' ? 'true' : 'false');
  }

  function downloadCurrent(){
    if (!state.current || !state.current.resource) return;
    var anchor = document.createElement('a');
    anchor.href = state.current.resource.url;
    anchor.download = state.current.fileName || filenameFromKey(state.current.key);
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
  }

  function printCurrent(){
    if (!state.current || !state.current.resource) return;
    var mime = String(state.current.resource.mime || '').toLowerCase();
    if (mime.indexOf('image/') === 0) {
      var win = window.open('', '_blank', 'noopener,noreferrer');
      if (!win) return;
      win.document.write('<img src="' + state.current.resource.url + '" style="max-width:100%" onload="window.print();window.close()">');
      win.document.close();
      return;
    }
    var frame = state.root && state.root.querySelector('.eds-frame');
    safe(function(){ frame.contentWindow.focus(); frame.contentWindow.print(); });
  }

  async function renderDocument(doc){
    try {
      var resource = await fetchDocument(doc.key);
      doc.resource = resource;
      state.current = doc;
      if (!state.root) return;
      var stage = state.root.querySelector('#eds-stage');
      if (!stage) return;
      stage.innerHTML = viewerMarkup(doc, resource, 'primary');
      state.root.querySelectorAll('[data-eds-key]').forEach(function(button){
        button.setAttribute('aria-current', button.getAttribute('data-eds-key') === doc.key ? 'true' : 'false');
      });
      applyTransform();
    } catch (error) {
      if (!state.root) return;
      var stage = state.root.querySelector('#eds-stage');
      if (stage) stage.innerHTML = '<div class="eds-error" role="alert"><b>تعذّر عرض المستند</b><br>' + escapeHtml(error && error.message || 'خطأ غير معروف') + '</div>';
    }
  }

  async function open(docOrKey, options){
    var doc = typeof docOrKey === 'string' ? { key: docOrKey } : Object.assign({}, docOrKey || {});
    if (!doc.key) throw new Error('مفتاح المستند غير موجود');
    options = options || {};
    state.documents = (options.documents || doc.documents || [doc]).filter(function(item){ return item && item.key; }).map(function(item){ return Object.assign({}, item); });
    if (!state.documents.some(function(item){ return item.key === doc.key; })) state.documents.unshift(doc);
    state.scale = 1;
    state.rotation = 0;
    state.fit = 'width';
    state.page = 1;
    mount(loadingMarkup(doc));
    await renderDocument(doc);
  }

  async function compare(leftDoc, rightDoc, options){
    var left = typeof leftDoc === 'string' ? { key: leftDoc } : Object.assign({}, leftDoc || {});
    var right = typeof rightDoc === 'string' ? { key: rightDoc } : Object.assign({}, rightDoc || {});
    if (!left.key || !right.key) throw new Error('يلزم مستندان للمقارنة');
    state.documents = (options && options.documents) || [left, right];
    state.scale = 1;
    state.rotation = 0;
    state.fit = 'width';
    state.compare = true;
    mount(loadingMarkup(left));
    state.root.classList.add('eds-compare');
    var stage = state.root.querySelector('#eds-stage');
    try {
      var resources = await Promise.all([fetchDocument(left.key), fetchDocument(right.key)]);
      left.resource = resources[0]; right.resource = resources[1];
      state.current = left;
      stage.innerHTML = viewerMarkup(left, resources[0], 'left') + viewerMarkup(right, resources[1], 'right');
      applyTransform();
    } catch (error) {
      stage.innerHTML = '<div class="eds-error" role="alert"><b>تعذّرت مقارنة المستندات</b><br>' + escapeHtml(error && error.message || '') + '</div>';
    }
  }

  function close(restoreFocus){
    if (state.keyHandler) document.removeEventListener('keydown', state.keyHandler);
    state.keyHandler = null;
    if (state.root && state.root.parentNode) state.root.parentNode.removeChild(state.root);
    state.root = null;
    document.body.style.overflow = '';
    revokeUrls();
    state.current = null;
    state.compare = false;
    if (restoreFocus !== false && state.previousFocus && typeof state.previousFocus.focus === 'function') safe(function(){ state.previousFocus.focus(); });
    state.previousFocus = null;
  }

  function documentsForRequest(reqId){
    return safe(function(){
      var request = (window.REQS || []).find(function(item){ return item.id === reqId; });
      return (request && request.docs || []).filter(function(doc){ return doc && doc.active !== false && doc.key; });
    }, []);
  }

  function openRequestDocument(reqId, docId){
    var docs = documentsForRequest(reqId);
    var doc = docs.find(function(item){ return String(item.id) === String(docId); });
    if (!doc) {
      safe(function(){ window.toast('المستند غير موجود أو غير مصرّح به', 'err'); });
      return;
    }
    open(doc, { documents: docs });
  }

  window.AldeyabiDocumentStudio = {
    open: open,
    openByKey: function(key, options){ return open(Object.assign({ key: key }, options || {}), options || {}); },
    openRequestDocument: openRequestDocument,
    compare: compare,
    close: close,
    version: '1.0.0'
  };

  function installLegacyBridge(){
    if (window.__edsBridgeInstalled) return;
    window.__edsBridgeInstalled = true;
    window.pa_docView = function(key){ return window.AldeyabiDocumentStudio.openByKey(key); };
    window.pa_reqdocView = function(reqId, docId){ return window.AldeyabiDocumentStudio.openRequestDocument(reqId, docId); };
  }

  installLegacyBridge();
  document.addEventListener('DOMContentLoaded', installLegacyBridge, { once: true });
  setTimeout(installLegacyBridge, 500);
})();

/*
 * Aldeyabi Policy Studio — first production-shaped admin surface.
 * Uses existing server-authorized RPCs. It never writes tables directly.
 */
(function policyStudioBootstrap(){
  'use strict';

  var current = null;
  var draft = null;
  var launcher = null;
  var shell = null;
  var publishArmed = false;
  var lastSimulation = null;

  function safe(fn, fallback){ try { return fn(); } catch (_e) { return fallback; } }
  function esc(value){
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }
  function isAdmin(){ return safe(function(){ return window.isAdmin(); }, false); }
  function announce(message){ safe(function(){ window.AldeyabiEnterpriseUI.announce(message); }); }
  function toast(message, kind){ safe(function(){ window.toast(message, kind || 'ok'); }, null); }

  async function rpc(name, args){
    if (!window.SB || typeof window.SB.rpc !== 'function') throw new Error('الاتصال بقاعدة البيانات غير جاهز');
    var response = await window.SB.rpc(name, args || {});
    if (response.error) throw new Error(response.error.message || 'تعذّر تنفيذ الإجراء');
    return response.data;
  }

  function normalize(policy){
    policy = policy || {};
    return {
      enabled: policy.enabled !== false,
      min_amount_exclusive: Number(policy.min_amount_exclusive == null ? 25000 : policy.min_amount_exclusive),
      max_amount_inclusive: policy.max_amount_inclusive == null || policy.max_amount_inclusive === '' ? null : Number(policy.max_amount_inclusive),
      fallback_role_key: policy.fallback_role_key || null,
      version: Number(policy.version || 1),
      published_at: policy.published_at || null,
      published_by: policy.published_by || null
    };
  }

  function clone(value){ return JSON.parse(JSON.stringify(value)); }

  function money(value){
    if (value == null || value === '') return 'مفتوح';
    return Number(value).toLocaleString('en-US') + ' ر.س';
  }

  function dateLabel(value){
    if (!value) return '—';
    try { return new Date(value).toLocaleString('ar-SA', { dateStyle: 'medium', timeStyle: 'short' }); }
    catch (_e) { return String(value); }
  }

  function fallbackLabel(key){
    var labels = {
      can_approve_finance: 'المعتمد المالي',
      can_approve_gm: 'المدير العام',
      can_approve_award: 'مدير المشتريات'
    };
    return labels[key] || (key ? 'صلاحية: ' + key : 'لا يوجد مسار بديل');
  }

  function changedFields(){
    if (!current || !draft) return [];
    var fields = [
      ['enabled', 'حالة اللجنة', current.enabled ? 'مفعلة' : 'معطلة', draft.enabled ? 'مفعلة' : 'معطلة'],
      ['min_amount_exclusive', 'الحد الأدنى', money(current.min_amount_exclusive), money(draft.min_amount_exclusive)],
      ['max_amount_inclusive', 'الحد الأعلى', money(current.max_amount_inclusive), money(draft.max_amount_inclusive)],
      ['fallback_role_key', 'المسار البديل', fallbackLabel(current.fallback_role_key), fallbackLabel(draft.fallback_role_key)]
    ];
    return fields.filter(function(row){ return String(row[2]) !== String(row[3]); });
  }

  function validate(){
    var errors = [];
    if (!draft) return ['تعذّر قراءة المسودة'];
    if (!Number.isFinite(Number(draft.min_amount_exclusive)) || Number(draft.min_amount_exclusive) < 0) errors.push('الحد الأدنى يجب أن يكون صفراً أو أكثر.');
    if (draft.max_amount_inclusive != null && (!Number.isFinite(Number(draft.max_amount_inclusive)) || Number(draft.max_amount_inclusive) <= Number(draft.min_amount_exclusive))) {
      errors.push('الحد الأعلى يجب أن يكون أكبر من الحد الأدنى.');
    }
    if (!draft.enabled && !draft.fallback_role_key) errors.push('عند تعطيل اللجنة سيستمر المسار دون مرحلة بديلة. راجع ذلك قبل النشر.');
    return errors;
  }

  function routeNodes(){
    var nodes = ['اعتماد مدير المشتريات'];
    if (draft.enabled) nodes.push('اللجنة ضمن النطاق المالي');
    else if (draft.fallback_role_key) nodes.push(fallbackLabel(draft.fallback_role_key) + ' بدلاً من اللجنة');
    else nodes.push('لا توجد مرحلة بديلة للجنة');
    nodes.push('الاعتمادات الأعلى حسب مصفوفة الصلاحيات');
    nodes.push('إصدار أمر الشراء');
    return nodes;
  }

  function diffMarkup(){
    var changes = changedFields();
    if (!changes.length) return '<div class="eps-diff"><div class="eps-diff__after">لا توجد تغييرات غير منشورة.</div></div>';
    return '<div class="eps-diff">' + changes.map(function(row){
      return '<div><b>' + esc(row[1]) + '</b><div class="eps-diff__row"><div class="eps-diff__before">الحالي: ' + esc(row[2]) + '</div><div class="eps-diff__after">الجديد: ' + esc(row[3]) + '</div></div></div>';
    }).join('') + '</div>';
  }

  function simulationMarkup(){
    if (!lastSimulation) return '<div style="color:var(--eui-muted);font-size:12px">أدخل مبلغاً واضغط «اختبار المسار» لرؤية النتيجة قبل النشر.</div>';
    var route = lastSimulation;
    var result = route.use_committee ? 'ستُضاف مرحلة اللجنة' : route.use_fallback ? 'سيُستخدم المسار البديل: ' + fallbackLabel(route.fallback_role_key) : route.in_band ? 'لا توجد مرحلة لجنة أو بديل' : 'المبلغ خارج نطاق سياسة اللجنة';
    return '<div class="eps-route"><div class="eps-route__node">' + esc(result) + '</div><div style="font-size:11px;color:var(--eui-muted)">المحاكاة تقرأ السياسة المنشورة حالياً من الخادم. بعد تعديل المسودة، اعتمد على معاينة المسار أعلاه حتى يتم النشر.</div></div>';
  }

  function render(){
    if (!shell || !draft || !current) return;
    var body = shell.querySelector('.eps-body');
    var errors = validate();
    body.innerHTML = ''
      + '<section class="eps-section">'
      +   '<div class="eps-switch"><div><h3 style="margin:0">تشغيل اللجنة</h3><div style="font-size:11px;color:var(--eui-muted)">تعطيلها لا يحذفها ولا يغيّر المعاملات القائمة.</div></div>'
      +   '<input id="eps-enabled" type="checkbox" ' + (draft.enabled ? 'checked' : '') + ' aria-label="تشغيل اللجنة"></div>'
      + '</section>'
      + '<section class="eps-section">'
      +   '<h3>النطاق المالي</h3>'
      +   '<div class="eps-grid">'
      +     '<label class="eps-field"><span>أكبر من مبلغ</span><input id="eps-min" type="number" min="0" step="1" value="' + esc(draft.min_amount_exclusive) + '"></label>'
      +     '<label class="eps-field"><span>حتى مبلغ — اتركه فارغاً للنطاق المفتوح</span><input id="eps-max" type="number" min="0" step="1" value="' + esc(draft.max_amount_inclusive == null ? '' : draft.max_amount_inclusive) + '"></label>'
      +   '</div>'
      + '</section>'
      + '<section class="eps-section">'
      +   '<h3>المسار عند تعطيل اللجنة</h3>'
      +   '<label class="eps-field"><span>المعتمد البديل</span><select id="eps-fallback">'
      +     '<option value="" ' + (!draft.fallback_role_key ? 'selected' : '') + '>لا يوجد — متابعة المسار بدون مرحلة بديلة</option>'
      +     '<option value="can_approve_finance" ' + (draft.fallback_role_key === 'can_approve_finance' ? 'selected' : '') + '>المعتمد المالي</option>'
      +     '<option value="can_approve_gm" ' + (draft.fallback_role_key === 'can_approve_gm' ? 'selected' : '') + '>المدير العام</option>'
      +     '<option value="can_approve_award" ' + (draft.fallback_role_key === 'can_approve_award' ? 'selected' : '') + '>مدير المشتريات</option>'
      +   '</select></label>'
      + '</section>'
      + '<section class="eps-section"><h3>معاينة مسار العمل</h3><div class="eps-route">'
      + routeNodes().map(function(node){ return '<div class="eps-route__node">' + esc(node) + '</div>'; }).join('')
      + '</div></section>'
      + '<section class="eps-section"><h3>اختبار سيناريو</h3>'
      +   '<div style="display:flex;gap:8px;align-items:end;flex-wrap:wrap"><label class="eps-field" style="flex:1;min-width:170px"><span>قيمة أمر الشراء</span><input id="eps-sim-amount" type="number" min="0" step="1" placeholder="مثال: 87500"></label><button class="btn btn-primary" type="button" data-eps-action="simulate">اختبار المسار</button></div>'
      +   '<div id="eps-simulation" style="margin-top:10px">' + simulationMarkup() + '</div>'
      + '</section>'
      + '<section class="eps-section"><h3>الفرق عن الإصدار المنشور</h3>' + diffMarkup() + '</section>'
      + '<section class="eps-section"><h3>معلومات الإصدار</h3><div style="font-size:12px;line-height:1.9;color:var(--eui-muted)">الإصدار الحالي: <b style="color:var(--eui-ink)">' + esc(current.version) + '</b><br>نشر بواسطة: <b style="color:var(--eui-ink)">' + esc(current.published_by || '—') + '</b><br>تاريخ النشر: <b style="color:var(--eui-ink)">' + esc(dateLabel(current.published_at)) + '</b></div></section>'
      + (errors.length ? '<section class="eps-section" style="border-color:#e2b8b5;background:var(--eui-danger-soft)"><h3 style="color:var(--eui-danger)">تنبيهات قبل النشر</h3><div style="font-size:12px;line-height:1.9">' + errors.map(function(error){ return '• ' + esc(error); }).join('<br>') + '</div></section>' : '');

    var publishButton = shell.querySelector('[data-eps-action="publish"]');
    if (publishButton) {
      var hasChanges = changedFields().length > 0;
      publishButton.disabled = !hasChanges || errors.some(function(error){ return error.indexOf('يجب') >= 0; });
      publishButton.textContent = publishArmed ? 'تأكيد نشر الإصدار الجديد' : 'مراجعة ونشر';
    }

    bindFields();
  }

  function bindFields(){
    var enabled = shell.querySelector('#eps-enabled');
    var min = shell.querySelector('#eps-min');
    var max = shell.querySelector('#eps-max');
    var fallback = shell.querySelector('#eps-fallback');
    if (enabled) enabled.onchange = function(){ draft.enabled = !!enabled.checked; publishArmed = false; render(); };
    if (min) min.oninput = function(){ draft.min_amount_exclusive = Number(min.value || 0); publishArmed = false; render(); };
    if (max) max.oninput = function(){ draft.max_amount_inclusive = max.value === '' ? null : Number(max.value); publishArmed = false; render(); };
    if (fallback) fallback.onchange = function(){ draft.fallback_role_key = fallback.value || null; publishArmed = false; render(); };
  }

  async function load(){
    var result = await rpc('portal_get_committee_policy');
    current = normalize(result);
    draft = clone(current);
    lastSimulation = null;
  }

  async function open(){
    if (!isAdmin()) return;
    if (shell) return;
    try {
      await load();
      shell = document.createElement('div');
      shell.className = 'eps-shell';
      shell.setAttribute('role', 'dialog');
      shell.setAttribute('aria-modal', 'true');
      shell.setAttribute('aria-label', 'استوديو سياسات الموافقات');
      shell.innerHTML = '<div class="eps-backdrop" data-eps-action="close"></div><aside class="eps-panel"><header class="eps-head"><div class="eps-head__copy"><h2>استوديو سياسات الموافقات</h2><p>مسودة · محاكاة · مقارنة · نشر بإصدار جديد</p></div><button class="eps-close" type="button" data-eps-action="close" aria-label="إغلاق">×</button></header><div class="eps-body"></div><footer class="eps-actions"><button class="btn" type="button" data-eps-action="reset">إلغاء التغييرات</button><button class="btn btn-primary" type="button" data-eps-action="publish">مراجعة ونشر</button></footer></aside>';
      document.body.appendChild(shell);
      document.body.style.overflow = 'hidden';
      shell.addEventListener('click', clickHandler);
      render();
      shell.querySelector('.eps-close').focus();
      announce('تم فتح استوديو سياسات الموافقات');
    } catch (error) {
      toast(error && error.message || 'تعذّر فتح استوديو السياسات', 'err');
    }
  }

  function close(){
    if (!shell) return;
    shell.remove();
    shell = null;
    document.body.style.overflow = '';
    publishArmed = false;
    lastSimulation = null;
    if (launcher) launcher.focus();
  }

  async function simulate(){
    var input = shell && shell.querySelector('#eps-sim-amount');
    var amount = Number(input && input.value);
    if (!Number.isFinite(amount) || amount < 0) {
      toast('أدخل قيمة صحيحة للمحاكاة', 'err');
      return;
    }
    try {
      lastSimulation = await rpc('portal_committee_route', { p_total: amount });
      var target = shell.querySelector('#eps-simulation');
      if (target) target.innerHTML = simulationMarkup();
      announce('اكتملت محاكاة المسار');
    } catch (error) {
      toast(error && error.message || 'تعذّرت المحاكاة', 'err');
    }
  }

  async function publish(){
    if (!changedFields().length) return;
    if (!publishArmed) {
      publishArmed = true;
      render();
      announce('راجع الفروقات ثم اضغط تأكيد نشر الإصدار الجديد');
      return;
    }
    var blocking = validate().filter(function(error){ return error.indexOf('يجب') >= 0; });
    if (blocking.length) {
      toast(blocking[0], 'err');
      return;
    }
    var button = shell.querySelector('[data-eps-action="publish"]');
    if (button) button.disabled = true;
    try {
      var payload = {
        enabled: !!draft.enabled,
        min_amount_exclusive: Number(draft.min_amount_exclusive),
        max_amount_inclusive: draft.max_amount_inclusive == null ? null : Number(draft.max_amount_inclusive),
        fallback_role_key: draft.fallback_role_key || null
      };
      var result = await rpc('portal_set_committee_policy', { p_policy: payload });
      current = normalize(result && result.policy || payload);
      draft = clone(current);
      publishArmed = false;
      render();
      toast('نُشرت سياسة اللجنة كإصدار ' + current.version, 'ok');
      announce('تم نشر إصدار جديد من سياسة اللجنة');
      safe(function(){ if (typeof window.loadAll === 'function') window.loadAll().then(window.render); });
    } catch (error) {
      if (button) button.disabled = false;
      toast(error && error.message || 'تعذّر نشر السياسة', 'err');
    }
  }

  function reset(){
    draft = clone(current);
    publishArmed = false;
    lastSimulation = null;
    render();
    announce('تم إلغاء التغييرات غير المنشورة');
  }

  function clickHandler(event){
    var button = event.target.closest('[data-eps-action]');
    if (!button) return;
    var action = button.getAttribute('data-eps-action');
    if (action === 'close') close();
    else if (action === 'simulate') simulate();
    else if (action === 'publish') publish();
    else if (action === 'reset') reset();
  }

  function ensureLauncher(){
    if (launcher) return launcher;
    launcher = document.createElement('button');
    launcher.className = 'eps-launcher';
    launcher.type = 'button';
    launcher.innerHTML = '<span aria-hidden="true">◇</span><span>استوديو السياسات</span>';
    launcher.addEventListener('click', open);
    document.body.appendChild(launcher);
    return launcher;
  }

  function refreshVisibility(){
    var button = ensureLauncher();
    button.setAttribute('data-visible', isAdmin() ? 'true' : 'false');
  }

  window.AldeyabiPolicyStudio = {
    open: open,
    close: close,
    refreshVisibility: refreshVisibility,
    version: '1.0.0'
  };

  function boot(){
    refreshVisibility();
    setTimeout(refreshVisibility, 700);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();

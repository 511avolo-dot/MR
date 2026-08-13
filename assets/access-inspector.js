/*
 * Aldeyabi Effective Access Inspector
 * Read-only admin diagnostic. It explains effective access from the portal's
 * existing USERS/JOBS/accessOf model without changing permissions or exposing secrets.
 */
(function accessInspectorBootstrap(){
  'use strict';

  var launcher = null;
  var shell = null;
  var selected = null;
  var query = '';

  var CAPABILITIES = [
    ['create', 'إنشاء طلب شراء'],
    ['directExpense', 'إنشاء صرف مباشر'],
    ['edit', 'تعديل طلب مُعاد أو بالنيابة'],
    ['approveStage', 'اعتماد مراحل الاحتياج'],
    ['manageRfq', 'إدارة طلبات العروض'],
    ['viewQuotes', 'مشاهدة عروض الأسعار السرية'],
    ['approveAward', 'اعتماد التعميد'],
    ['approveCommittee', 'اعتماد اللجنة'],
    ['issuePO', 'إصدار أمر شراء'],
    ['approveFinance', 'اعتماد مالي'],
    ['approveDisb', 'اعتماد الصرف'],
    ['disburse', 'تنفيذ الصرف'],
    ['verifyStock', 'الاستلام والجودة'],
    ['manageUsers', 'إدارة المستخدمين'],
    ['manageCompany', 'إدارة إعدادات الشركة'],
    ['seeFinance', 'رؤية البيانات المالية']
  ];

  var RAW_KEYS = {
    create: ['can_create'],
    directExpense: ['can_create_direct_expense'],
    edit: ['can_edit'],
    approveStage: ['can_approve_stage'],
    manageRfq: ['can_manage_procurement'],
    viewQuotes: ['can_view_quotes'],
    approveAward: ['can_approve_award'],
    approveCommittee: ['can_approve_committee'],
    issuePO: ['can_issue_po'],
    approveFinance: ['can_approve_finance'],
    approveDisb: ['can_approve_disbursement'],
    disburse: ['can_disburse'],
    verifyStock: ['can_verify_stock'],
    manageUsers: ['can_manage_users'],
    manageCompany: ['can_manage_company'],
    seeFinance: ['can_see_finance']
  };

  function safe(fn, fallback){ try { return fn(); } catch (_e) { return fallback; } }
  function esc(value){
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#039;');
  }
  function isAdmin(){ return safe(function(){ return window.isAdmin(); }, false); }
  function allUsers(){ return safe(function(){ return window.USERS || {}; }, {}); }
  function allJobs(){ return safe(function(){ return window.JOBS || {}; }, {}); }
  function allDepartments(){ return safe(function(){ return window.DEPTS || {}; }, {}); }
  function effective(username){ return safe(function(){ return window.accessOf(username) || {}; }, {}); }
  function announce(message){ safe(function(){ window.AldeyabiEnterpriseUI.announce(message); }); }

  function truthy(obj, names){
    if (!obj) return false;
    return names.some(function(name){ return obj[name] === true; });
  }

  function capabilityValue(access, cap){
    var can = access && access.can || {};
    var see = access && access.see || {};
    if (cap === 'seeFinance') return !!(see.finance || can.seeFinance || can.canSeeFinance);
    return !!can[cap];
  }

  function rawDirect(user, cap){
    var raw = user && user.perms || {};
    return truthy(raw, RAW_KEYS[cap] || []);
  }

  function rawJob(user, cap){
    var job = user && user.job && allJobs()[user.job];
    var access = job && job.acc || {};
    return capabilityValue(access, cap);
  }

  function scopeLabel(user, access){
    var scope = access && access.scope || user && user.acc && user.acc.scope || (user && user.job && allJobs()[user.job] && allJobs()[user.job].scope) || 'own';
    var labels = { own: 'طلباته فقط', department: 'القسم', dept: 'القسم', sector: 'القطاع', all: 'جميع الشركة' };
    return labels[scope] || scope || 'غير محدد';
  }

  function departmentLabel(user){
    var id = user && user.deptId;
    var dept = id && allDepartments()[id];
    return (dept && (dept.n || dept.name_ar || dept.name)) || id || 'بلا قسم';
  }

  function userLabel(username, user){
    return (user && user.n) || safe(function(){ return window.uName(username); }, '') || username;
  }

  function jobLabel(user){
    var job = user && user.job && allJobs()[user.job];
    return (job && job.title) || (user && user.r) || 'مستخدم';
  }

  function warnings(username, user, access){
    var out = [];
    var has = function(cap){ return capabilityValue(access, cap); };
    if (has('approveDisb') && has('disburse')) out.push('يجمع بين اعتماد الصرف وتنفيذه؛ راجع فصل المهام.');
    if (has('manageRfq') && has('approveAward')) out.push('يجمع بين إعداد العروض واعتماد التعميد؛ يجب ضبط من أعد المقارنة داخل المعاملة.');
    if (has('create') && has('approveStage')) out.push('يمكنه إنشاء الطلب واعتماد مرحلة احتياج؛ منع اعتماد طلبه الشخصي يجب أن يبقى خادمياً.');
    if (has('manageUsers') && (has('approveAward') || has('approveDisb') || has('disburse'))) out.push('صلاحية إدارية مع صلاحية مالية/تشغيلية حساسة؛ تأكد أن الجمع مقصود ومُوثق.');
    if (has('viewQuotes') && scopeLabel(user, access) === 'جميع الشركة') out.push('رؤية عروض الأسعار على نطاق الشركة بالكامل؛ راجع الحاجة الفعلية لهذا النطاق.');
    if (user && user.away && !user.delegate) out.push('المستخدم في إجازة أو غياب دون مفوّض محدد.');
    if (user && user.delegate === username) out.push('تفويض المستخدم إلى نفسه غير صالح تشغيلياً.');
    if (user && user.suspended) out.push('الحساب موقوف؛ لا ينبغي أن ينتج عنه وصول فعلي حتى لو ظهرت صلاحيات موروثة.');
    return out;
  }

  function filteredUsers(){
    var users = allUsers();
    var needle = query.trim().toLowerCase();
    return Object.keys(users).filter(function(username){
      if (!needle) return true;
      var user = users[username] || {};
      return [username, userLabel(username, user), jobLabel(user), departmentLabel(user)]
        .join(' ').toLowerCase().indexOf(needle) >= 0;
    }).sort(function(a, b){ return userLabel(a, users[a]).localeCompare(userLabel(b, users[b]), 'ar'); });
  }

  function sourcesMarkup(username, user, access){
    return CAPABILITIES.filter(function(row){ return capabilityValue(access, row[0]); }).map(function(row){
      var cap = row[0];
      var sources = [];
      if (user && user.admin) sources.push('مدير بوابة');
      if (rawDirect(user, cap)) sources.push('منح مباشر');
      if (rawJob(user, cap)) sources.push('الوظيفة');
      if (!sources.length) sources.push('حساب فعلي/توافق قديم');
      return '<div class="eai-source-row"><span>' + esc(row[1]) + '</span><span>' + esc(sources.join(' + ')) + '</span></div>';
    }).join('') || '<div class="eai-empty">لا توجد قدرات تشغيلية فعالة ظاهرة.</div>';
  }

  function capabilitiesMarkup(user, access){
    return CAPABILITIES.map(function(row){
      var cap = row[0];
      var on = capabilityValue(access, cap);
      var direct = rawDirect(user, cap);
      var title = direct ? 'منح مباشر للمستخدم' : rawJob(user, cap) ? 'موروثة من الوظيفة' : on ? 'وصول فعلي' : 'غير ممنوحة';
      return '<span class="eai-cap ' + (on ? 'on ' : '') + (direct ? 'direct' : '') + '" title="' + esc(title) + '">' + (on ? '✓ ' : '— ') + esc(row[1]) + '</span>';
    }).join('');
  }

  function userListMarkup(){
    var users = allUsers();
    var names = filteredUsers();
    if (!names.length) return '<div class="eai-empty">لا توجد نتائج مطابقة.</div>';
    return names.map(function(username){
      var user = users[username] || {};
      return '<button class="eai-user" type="button" data-eai-user="' + esc(username) + '" aria-current="' + (selected === username) + '">'
        + '<div class="eai-user__name">' + esc(userLabel(username, user)) + '</div>'
        + '<div class="eai-user__meta">' + esc(jobLabel(user)) + ' · ' + esc(departmentLabel(user)) + '</div>'
        + '</button>';
    }).join('');
  }

  function detailMarkup(){
    var users = allUsers();
    var user = selected && users[selected];
    if (!user) return '<div class="eai-empty">اختر مستخدماً لمعاينة الصلاحيات الفعلية ومصادرها.</div>';
    var access = effective(selected);
    var userWarnings = warnings(selected, user, access);
    var delegated = user.delegate ? userLabel(user.delegate, users[user.delegate] || {}) : 'لا يوجد';
    return '<div class="eai-hero">'
      + '<div><h3>' + esc(userLabel(selected, user)) + '</h3><p>' + esc(selected) + ' · ' + esc(jobLabel(user)) + ' · ' + esc(departmentLabel(user)) + '</p></div>'
      + '<span class="eai-status ' + (user.active === false || user.suspended ? 'inactive' : 'active') + '">' + (user.active === false || user.suspended ? 'موقوف' : 'نشط') + '</span>'
      + '</div>'
      + '<div class="eai-grid">'
      + '<section class="eai-section full"><h4>الصلاحيات الفعلية</h4><div class="eai-capabilities">' + capabilitiesMarkup(user, access) + '</div></section>'
      + '<section class="eai-section"><h4>النطاق والتنظيم</h4>'
      + '<div class="eai-source-row"><span>نطاق البيانات</span><span>' + esc(scopeLabel(user, access)) + '</span></div>'
      + '<div class="eai-source-row"><span>القسم</span><span>' + esc(departmentLabel(user)) + '</span></div>'
      + '<div class="eai-source-row"><span>القطاع</span><span>' + esc(user.sector || '—') + '</span></div>'
      + '<div class="eai-source-row"><span>المفوّض إليه</span><span>' + esc(delegated) + '</span></div>'
      + '</section>'
      + '<section class="eai-section"><h4>مصادر الوصول</h4>' + sourcesMarkup(selected, user, access) + '</section>'
      + '<section class="eai-section full"><h4>مراجعة فصل المهام</h4>'
      + (userWarnings.length ? userWarnings.map(function(item){ return '<div class="eai-warning">' + esc(item) + '</div>'; }).join('') : '<div style="color:var(--eui-success);font-size:11px">لم تُكتشف تركيبات عالية الخطورة من البيانات المتاحة في الواجهة.</div>')
      + '<div style="margin-top:10px;color:var(--eui-muted);font-size:9.5px;line-height:1.7">هذه معاينة تفسيرية للواجهة وليست بديلاً عن اختبارات RLS/RPC. المنع الخادمي وسجل التدقيق يظلان المرجع النهائي.</div>'
      + '</section></div>';
  }

  function render(){
    if (!shell) return;
    var list = shell.querySelector('[data-eai-list]');
    var detail = shell.querySelector('[data-eai-detail]');
    if (list) list.innerHTML = '<input class="eai-search" type="search" data-eai-search placeholder="ابحث بالاسم أو الوظيفة أو القسم" value="' + esc(query) + '">' + userListMarkup();
    if (detail) detail.innerHTML = detailMarkup();
    var search = shell.querySelector('[data-eai-search]');
    if (search) {
      search.addEventListener('input', function(){
        query = search.value;
        var cursor = search.selectionStart;
        render();
        var next = shell.querySelector('[data-eai-search]');
        if (next) { next.focus(); safe(function(){ next.setSelectionRange(cursor, cursor); }); }
      });
    }
  }

  function clickHandler(event){
    var closeButton = event.target.closest('[data-eai-action="close"]');
    if (closeButton) { close(); return; }
    var userButton = event.target.closest('[data-eai-user]');
    if (userButton) {
      selected = userButton.getAttribute('data-eai-user');
      render();
      announce('تم فتح معاينة صلاحيات ' + userLabel(selected, allUsers()[selected] || {}));
    }
  }

  function open(){
    if (!isAdmin() || shell) return;
    var names = filteredUsers();
    if (!selected || !allUsers()[selected]) selected = names[0] || null;
    shell = document.createElement('div');
    shell.className = 'eai-shell';
    shell.setAttribute('role', 'dialog');
    shell.setAttribute('aria-modal', 'true');
    shell.setAttribute('aria-label', 'معاينة الصلاحيات الفعلية');
    shell.innerHTML = '<div data-eai-action="close"></div><aside class="eai-panel"><header class="eai-head"><div class="eai-head__copy"><h2>معاينة الصلاحيات الفعلية</h2><p>من يملك ماذا، وفي أي نطاق، ومن أي مصدر — قراءة فقط</p></div><button class="eai-close" type="button" data-eai-action="close" aria-label="إغلاق">×</button></header><div class="eai-layout"><div class="eai-list" data-eai-list></div><main class="eai-detail" data-eai-detail></main></div></aside>';
    shell.addEventListener('click', clickHandler);
    document.body.appendChild(shell);
    document.body.style.overflow = 'hidden';
    render();
    shell.querySelector('.eai-close').focus();
    announce('تم فتح معاينة الصلاحيات الفعلية');
  }

  function close(){
    if (!shell) return;
    shell.remove();
    shell = null;
    document.body.style.overflow = '';
    if (launcher) launcher.focus();
  }

  function ensureLauncher(){
    if (launcher) return launcher;
    launcher = document.createElement('button');
    launcher.className = 'eai-launcher';
    launcher.type = 'button';
    launcher.innerHTML = '<span aria-hidden="true">◎</span><span>معاينة الصلاحيات</span>';
    launcher.addEventListener('click', open);
    document.body.appendChild(launcher);
    return launcher;
  }

  function refreshVisibility(){
    ensureLauncher().setAttribute('data-visible', isAdmin() ? 'true' : 'false');
  }

  window.AldeyabiAccessInspector = { open: open, close: close, refreshVisibility: refreshVisibility, version: '1.0.0' };

  function boot(){ refreshVisibility(); setTimeout(refreshVisibility, 800); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();

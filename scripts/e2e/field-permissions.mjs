/* ══════════════════════════════════════════════════════════════════════
   صلاحيات الميدان + الرابط العميق — معاينة على DOM حقيقيّ تحت CSP الإنتاج
   ----------------------------------------------------------------------
   بلاغا المالك (2026-09-13):
     ① «لا يوجد إدارة صلاحيات لموظفي الصيانة والتشغيل — لا صلاحيات تُعطى أو تُسحب»
     ② «بريد الإشعار يفتح بوابة الطلبات (النظام الآخر) ولا يفتح الطلب مباشرة»

   ⚠️ الفحص النصّيّ هو ما مرّت عليه عيوبٌ سابقة (قاعدة CSS على صنف غير موجود ·
   مدخل مخفيّ بـ`!important` لا يغلبه `style.display`). فهنا نُشغّل الصفحة فعلاً.

     node scripts/csp-preview-server.mjs &
     node scripts/e2e/field-permissions.mjs
   ══════════════════════════════════════════════════════════════════════ */
import { chromium } from 'playwright';
import { resolveChromiumExecutable } from './chromium-path.mjs';

const ORIGIN = 'http://127.0.0.1:8812';
const checks = [];
const ok = (n, p, d) => checks.push({ n, p, d });

const browser = await chromium.launch({ executablePath: resolveChromiumExecutable() });
const ctx = await browser.newContext({ viewport: { width: 1280, height: 950 }, locale: 'ar-SA' });
const page = await ctx.newPage();
const errors = [], csp = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

/* ── مُهيّئ: يُسجّل الدخول بصلاحيات مُعطاة ويُجهّز سحابة مُقلَّدة ── */
async function asUser(perms, sectors) {
  await page.evaluate(({ perms, sectors }) => {
    STATE.currentUser = { username:'saleh', display_name:'صالح', role:'user',
      permissions: perms, scopeSectors: sectors };
    try { hideLoginScreen(); } catch (e) {}
    try { hydSettle('ready'); } catch (e) {}
    CLOUD.enabled = true; CLOUD.dataLoaded = true;
    CLOUD.client = { auth:{ getSession: async () => ({ data:{ session:null } }) },
      from: () => ({ select: () => ({ order: async () => ({ data:[], error:null }) }) }),
      rpc: async () => ({ data:null, error:null }),
      channel: () => ({ on(){ return this; }, subscribe(){ return this; } }) };
    window.__prLoaded = true; try { __prLoaded = true; } catch (e) {}
    STATE.purchaseRequests = []; STATE.departments = []; STATE.prTemplates = [];
    try { applyUserRoleToUI(); } catch (e) {}
  }, { perms, sectors });
}

const FIELD_ALL = { can_create_pr:true, can_upload_docs:true, can_comment:true,
                    can_print_followup:true, can_receive_po:true, can_view_amounts:false };

/* ══════════ ١) الموظّف الممنوح كل قدرات الميدان ══════════ */
await page.goto(`${ORIGIN}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.renderPRPortal === 'function', { timeout: 15000 });
await asUser(FIELD_ALL, ['الصيانة والتشغيل']);
await page.evaluate(() => { navigate('pr'); prGoView('list'); });
await page.waitForTimeout(400);

const tabs = () => page.evaluate(() =>
  [...document.querySelectorAll('.pr-tab')].map(t => t.textContent.trim().replace(/\s+/g,' ')));
let t = await tabs();
ok('الممنوح يرى تبويبَي الرفع والقوالب',
  t.some(x => x.includes('طلب جديد')) && t.some(x => x.includes('القوالب')), t.join(' | '));

ok('وزرّ تقرير المتابعة ظاهر له',
  await page.evaluate(() => {
    const b = document.getElementById('po-followup-btn');
    return !!b && getComputedStyle(b).display !== 'none';
  }));

/* ══════════ ٢) المسحوبة منه القدرات — «متابعة فقط» ══════════ */
await asUser({ can_receive_po:true, can_view_amounts:false }, ['الصيانة والتشغيل']);
await page.evaluate(() => { STATE.prView='create'; renderPRPortal(); });
await page.waitForTimeout(400);
t = await tabs();
ok('والمسحوبة منه لا يرى تبويب الرفع ولا القوالب',
  !t.some(x => x.includes('طلب جديد')) && !t.some(x => x.includes('القوالب')), t.join(' | '));
ok('ولا تفتح له شاشة النموذج ولو بقيت الحالة قديمة',
  await page.evaluate(() => !document.getElementById('pr-title')));
ok('وزرّ تقرير المتابعة يختفي عنه (بوّابة الزرّ = بوّابة الفعل)',
  await page.evaluate(() => {
    const b = document.getElementById('po-followup-btn');
    return !b || getComputedStyle(b).display === 'none';
  }));

/* صندوق الردّ: يقرأ الحوار ولا يكتب */
const thread = await page.evaluate(() => {
  const pr = { id:'PR-9', requester:'saleh', messages:[
    {id:1, kind:'question', body:'هل الكمية 10 أم 100؟', author:'proc1',
     author_name:'أحمد', created_at:'2026-09-01T08:00:00Z'}]};
  return { off: prThreadHTML(pr) };
});
ok('ويقرأ حوار الاستفهام بلا مربّع كتابة',
  thread.off.includes('هل الكمية 10 أم 100؟')
  && !thread.off.includes('pr-msg-input') && !thread.off.includes('prPostMessage'));

/* ══════════ ٣) قوالب الأدوار في نافذة المستخدم ══════════ */
await asUser({ can_manage_users:true }, []);
const preset = await page.evaluate(() => {
  renderUserFormPermissions();
  const btns = [...document.querySelectorAll('#uf-perms-grid [data-uf-preset]')]
    .map(b => b.dataset.ufPreset);
  applyUserFormPreset('field');
  const on = [...document.querySelectorAll('#uf-perms-grid [data-perm]')]
    .filter(cb => cb.checked).map(cb => cb.dataset.perm).sort();
  applyUserFormPreset('viewer');
  const none = [...document.querySelectorAll('#uf-perms-grid [data-perm]')]
    .filter(cb => cb.checked).length;
  const hint = (document.getElementById('uf-preset-hint')||{}).textContent || '';
  return { btns, on, none, hint };
});
ok('ثلاثة أزرار قوالب في نافذة المستخدم',
  preset.btns.join(',') === 'field,supervisor,viewer', preset.btns.join(','));
ok('و«موظّف ميدانيّ» يضبط الخمسة ويُصفّر المبالغ ومفاتيح المكتب',
  preset.on.join(',') === ['can_comment','can_create_pr','can_print_followup',
                           'can_receive_po','can_upload_docs'].sort().join(','),
  preset.on.join(','));
ok('و«متابعة فقط» يُصفّر كل شيء', preset.none === 0, String(preset.none));
ok('ويُفصِح للمدير بما طُبِّق', /متابعة فقط/.test(preset.hint), preset.hint.slice(0,60));

/* شبكة الصلاحيات تسِم القدرات الميدانية */
ok('والقدرات الميدانية موسومة في الشبكة بفئتها',
  await page.evaluate(() => {
    const g = document.getElementById('uf-perms-grid');
    return !!g && g.textContent.includes('الميدان (الصيانة والتشغيل)')
      && !!g.querySelector('[data-perm="can_upload_docs"]')
      && !!g.querySelector('[data-perm="can_print_followup"]');
  }));

/* ══════════ ٤) الرابط العميق من البريد ══════════ */
{
  const p2 = await ctx.newPage();
  const errs2 = [], csp2 = [];
  p2.on('pageerror', (e) => errs2.push(String(e)));
  p2.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp2.push(m.text()); });
  await p2.goto(`${ORIGIN}/index.html?pr=PR-DG2026-0007`, { waitUntil: 'domcontentloaded' });
  await p2.waitForFunction(() => typeof window.openDeepLink === 'function', { timeout: 15000 });
  const deep = await p2.evaluate(() => {
    STATE.currentUser = { username:'saleh', display_name:'صالح', role:'user',
      permissions:{ can_create_pr:true, can_upload_docs:true, can_comment:true,
                    can_print_followup:true, can_receive_po:true, can_view_amounts:false },
      scopeSectors:['الصيانة والتشغيل'] };
    try { hideLoginScreen(); } catch (e) {}
    try { hydSettle('ready'); } catch (e) {}
    CLOUD.enabled = true; CLOUD.dataLoaded = true;
    CLOUD.client = { auth:{ getSession: async () => ({ data:{ session:null } }) },
      from: () => ({ select: () => ({ order: async () => ({ data:[], error:null }) }) }),
      rpc: async () => ({ data:null, error:null }),
      channel: () => ({ on(){ return this; }, subscribe(){ return this; } }) };
    window.__prLoaded = true; try { __prLoaded = true; } catch (e) {}
    STATE.purchaseRequests = []; STATE.departments = []; STATE.prTemplates = [];
    const before = location.search;
    openDeepLink();
    return { before, afterSearch: location.search };
  });
  await p2.waitForTimeout(500);
  const landed = await p2.evaluate(() => ({
    page: STATE.page, view: STATE.prView, id: STATE.prTrackId,
    active: (document.querySelector('.page.active')||{}).id || '',
  }));
  ok('الرابط العميق يهبط على شاشة الطلبات لا القائمة العامّة',
    landed.page === 'pr' && landed.active === 'page-pr', JSON.stringify(landed));
  ok('ويفتح متابعة الطلب المقصود بعينه',
    landed.view === 'track' && landed.id === 'PR-DG2026-0007', JSON.stringify(landed));
  ok('ويُنظَّف المعامل من شريط العنوان فلا يُعاد فتحه',
    deep.before.includes('pr=') && deep.afterSearch === '', JSON.stringify(deep));
  ok('صفر خطأ صفحة على مسار الرابط العميق', errs2.length === 0, errs2[0]);
  ok('صفر انتهاك CSP على مسار الرابط العميق', csp2.length === 0, csp2[0]);
  await p2.close();
}

ok('صفر خطأ صفحة', errors.length === 0, errors[0]);
ok('صفر انتهاك CSP', csp.length === 0, csp[0]);

await browser.close();
let bad = 0;
for (const c of checks) { if (!c.p) bad++; console.log(`${c.p ? '✓' : '✗ FAIL'}  ${c.n}${c.d ? '  → ' + c.d : ''}`); }
if (bad) { console.error(`\n❌ ${bad} فحص فشل`); process.exit(1); }
console.log(`\n✅ ${checks.length}/${checks.length} فحصاً نجحت`);

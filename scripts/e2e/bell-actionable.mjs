/* فحص متصفّح تحت **CSP الإنتاج** للجرس (2026-11-02):
 *   قياس الإنتاج: 210 إشعاراً غير مقروء من 424، أقدمها 6 أغسطس — ومن 131
 *   إشعار «طلب تسجيل مورد جديد» غير مقروء كان **127 يشير إلى تسجيلٍ اعتُمد
 *   أو رُفض فعلاً** و4 فقط إلى معلّق ⇒ **97% من العدّاد الأحمر إنذارٌ على
 *   عملٍ أُنجِز** لا ينطفئ بإنجازه، لأنّ الوسيلة الوحيدة لإطفائه كانت
 *   «تحديد الكل مقروء» وهي تُسكِت المعلّق مع المُنجَز، فتُرِكت.
 *
 * ⚠️ المحكّ هنا **ما يُرسَم ويُكتَب فعلاً**: نصّ البادج في الـDOM، وعناوين
 *    مجموعات اللوحة، و**الكتابات التي تذهب للقاعدة** (مُعترَضة) — لا وجود
 *    نصٍّ في الملف. العلّة كانت في منطق العدّ والتسوية، وتأكيدٌ نصّيّ يمرّ عليها.
 *
 * التشغيل: node scripts/csp-preview-server.mjs &  ثمّ  node scripts/e2e/bell-actionable.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveChromiumExecutable } from './chromium-path.mjs';
import { blockSupabase, enterApp } from './app-boot.mjs';
const { chromium } = await import('../../node_modules/playwright/index.mjs');

const BASE = process.env.BASE || 'http://127.0.0.1:8812';
const SHOTS = process.env.BELL_SHOTS || path.join(os.tmpdir(), 'aldeyabi-bell');
fs.mkdirSync(SHOTS, { recursive: true });
const results = []; const T = (n, ok, d) => { results.push([n, !!ok, d || '']); };

const ep = resolveChromiumExecutable();
const browser = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const pageErrors = [], csp = [];
page.on('pageerror', e => pageErrors.push(String(e)));
page.on('console', m => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await blockSupabase(page);
await page.goto(`${BASE}/index.html`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.wfRefreshBell === 'function'
  && typeof window.wfInjectUI === 'function' && typeof window.wfMarkAllRead === 'function');
await enterApp(page);

/* عميل مُقلَّد بشكل الإنتاج: إشعارٌ واحد لتسجيلٍ معلّق + تسعة لتسجيلات
   اعتُمدت + اثنان «للعلم» — ويُسجِّل كل كتابةٍ تذهب للقاعدة. */
const install = async (spec) => page.evaluate((spec) => {
  const OPEN = 'DG-OPEN01';
  const rows = []; const regs = {};
  /* `open` افتراضه 1 — وحالة «صفر معلّق» تُمرّره صفراً صراحةً. */
  if (spec.open !== 0) {
    rows.push({ id:'N1', recipient:'Mahmoud', title:'طلب تسجيل مورد جديد',
      body:`منشأة معلّقة — بانتظار المراجعة (${OPEN})`, link:'registrations', read:false,
      created_at:'2026-11-01T08:00:00Z' });
    regs[OPEN] = 'pending';
  }
  for (let i = 0; i < spec.done; i++) {
    const rid = 'DG-DN' + String(i).padStart(4, '0');
    rows.push({ id:'ND'+i, recipient:'Mahmoud', title:'طلب تسجيل مورد جديد',
      body:`منشأة منجَزة ${i} — بانتظار المراجعة (${rid})`, link:'registrations', read:false,
      created_at:'2026-08-06T08:00:00Z' });
    regs[rid] = 'approved';
  }
  for (let i = 0; i < spec.info; i++) rows.push({ id:'NI'+i, recipient:'Mahmoud',
    title:'مورّد حدّث مستنداً', body:'منشأة — شهادة المحتوى المحلي', link:'registrations',
    read:false, created_at:'2026-10-22T08:00:00Z' });

  window.__writes = [];
  const tbl = (name) => {
    if (name === 'proc_supplier_registrations') {
      const q = { _st:null, select(){ return q; }, eq(c,v){ if(c==='status') q._st=v; return q; },
        limit(){ return q; },
        then(res){ return Promise.resolve({ error:null,
          data: Object.entries(regs).filter(([,s])=>s===q._st).map(([id])=>({id})) }).then(res); } };
      return q;
    }
    const q = { _eq:{}, _upd:null, _in:null, _lim:null,
      select(){ return q; }, order(){ return q; }, limit(n){ q._lim=n; return q; },
      update(p){ q._upd=p; return q; }, eq(c,v){ q._eq[c]=v; return q; },
      in(c,v){ q._in={c,v}; return q; },
      then(res){
        if (q._upd) {
          window.__writes.push({ ids: q._in ? q._in.v.slice() : null, eq: {...q._eq} });
          const set = q._in ? new Set(q._in.v) : null;
          for (const r of rows) if (!set || set.has(r.id)) r.read = true;
          return Promise.resolve({ error:null }).then(res);
        }
        let d = rows.filter(r => r.recipient === q._eq.recipient);
        if (q._eq.read === false) d = d.filter(r => r.read !== true);
        if (q._lim != null) d = d.slice(0, q._lim);
        return Promise.resolve({ data: d.map(r=>({...r})), error:null }).then(res);
      } };
    return q;
  };
  STATE.currentUser = Object.assign({}, STATE.currentUser, { username:'Mahmoud', role:'admin' });
  CLOUD = { enabled:true, client:{ from: tbl } };
  __wfOpenRegs = { at:0, ids:null };
  wfInjectUI();
  return rows.length;
}, spec);

const read = () => page.evaluate(() => {
  const b = document.getElementById('wf-bell-badge');
  const bell = document.getElementById('wf-bell');
  const list = document.getElementById('wf-notif-list');
  const groups = [...list.querySelectorAll('.wf-notif-group')].map(e => e.textContent.trim());
  const bb = b.getBoundingClientRect();
  return {
    badge: b.textContent, display: getComputedStyle(b).display,
    visible: bb.width > 0 && bb.height > 0,
    title: bell.title, groups,
    ok: !!list.querySelector('.wf-notif-ok'),
    rows: list.querySelectorAll('.wf-notif').length,
    writes: window.__writes.map(w => ({ n: w.ids ? w.ids.length : null, rec: w.eq.recipient })),
  };
});

/* ── (أ) شكل الإنتاج: معلّقٌ واحد وسط تسعةٍ أُنجِزت واثنين للعلم ── */
await install({ done: 9, info: 2 });
await page.evaluate(() => wfRefreshBell());
await page.evaluate(() => { document.getElementById('wf-notif-panel').style.display = 'block'; });
let s = await read();
T('البادج المرسوم يقول 1 لا 12 (العدّاد يَعُدّ ما يحتاج إجراءً)', s.badge === '1', s.badge);
T('والبادج مرئيّ فعلاً بصندوقٍ له أبعاد', s.visible && s.display !== 'none', JSON.stringify(s));
T('وتلميح الجرس يسمّيه بصيغة عربية صحيحة',
  s.title === 'إشعار واحد بانتظار إجراءك', s.title);
T('واللوحة تُجمِّع «يحتاج إجراءك» أوّلاً ثمّ «للعلم»',
  s.groups.length === 2 && /يحتاج إجراءك/.test(s.groups[0]) && /للعلم/.test(s.groups[1]),
  JSON.stringify(s.groups));
/* ⚠️ الكتابة الفعليّة للقاعدة: دفعة واحدة بتسعة معرّفات مقيَّدة بالمستلِم. */
T('والتسعة المُنجَزة سُوِّيت فعلاً في دفعةٍ واحدة مقيَّدة بالمستلِم',
  s.writes.length === 1 && s.writes[0].n === 9 && s.writes[0].rec === 'Mahmoud',
  JSON.stringify(s.writes));
await page.screenshot({ path: path.join(SHOTS, 'bell-actionable.png'), fullPage: false });

/* ⚠️ والتسوية **دائمة**: دورةٌ ثانية لا تُعيد الكتابة ولا يعود العدّاد. */
await page.evaluate(() => wfRefreshBell());
s = await read();
T('ودورة ثانية: صفر كتابة جديدة والعدّاد ما زال 1 (التسوية دائمة لا تجميلية)',
  s.writes.length === 1 && s.badge === '1', JSON.stringify({ w:s.writes.length, b:s.badge }));

/* ── (ب) «إخفاء ما للعلم» لم تعُد تُسكِت المعلّق ── */
await page.evaluate(() => wfMarkAllRead());
await page.waitForTimeout(80);
s = await read();
T('«إخفاء ما للعلم» تُخفي المعلوماتيّ وحده والعدّاد يبقى 1',
  s.badge === '1' && s.writes.length === 2 && s.writes[1].n === 2,
  JSON.stringify({ b:s.badge, w:s.writes }));

/* ── (ج) صفر معلّق: لا عدّاد أحمر ولو بقيت مئة صفّ للعلم ── */
await install({ done: 0, info: 100, open: 0 });
await page.evaluate(() => { const r = document.getElementById('wf-notif-panel'); if (r) r.style.display='block'; });
await page.evaluate(() => wfRefreshBell());
s = await read();
T('مئة إشعار للعلم ⇒ البادج مخفيّ (العدّاد ليس أرشيفاً)',
  s.display === 'none', JSON.stringify({ d:s.display, b:s.badge }));
T('واللوحة تُعلِن «لا شيء ينتظر إجراءك» صراحةً', s.ok === true);
T('وتلميح الجرس يقول ذلك أيضاً', /لا شيء ينتظر إجراءك/.test(s.title), s.title);

/* ── (د) العدّاد لا يُقصِّر بسقف لوحة العرض (العلّة: limit(30)) ── */
await page.evaluate(() => {
  const rows = []; const regs = {};
  for (let i = 0; i < 48; i++) {
    const rid = 'DG-PN' + String(i).padStart(4, '0');
    rows.push({ id:'NP'+i, recipient:'Mahmoud', title:'طلب تسجيل مورد جديد',
      body:`منشأة ${i} — بانتظار المراجعة (${rid})`, link:'registrations', read:false,
      created_at:'2026-10-01T08:00:00Z' });
    regs[rid] = 'pending';
  }
  window.__writes = [];
  CLOUD = { enabled:true, client:{ from:(name)=>{
    if (name === 'proc_supplier_registrations') {
      const q = { _st:null, select(){return q;}, eq(c,v){ if(c==='status') q._st=v; return q; }, limit(){return q;},
        then(res){ return Promise.resolve({ error:null,
          data: Object.entries(regs).filter(([,st])=>st===q._st).map(([id])=>({id})) }).then(res); } };
      return q;
    }
    const q = { _eq:{}, _upd:null, _in:null, _lim:null,
      select(){return q;}, order(){return q;}, limit(n){ q._lim=n; return q; },
      update(p){ q._upd=p; return q; }, eq(c,v){ q._eq[c]=v; return q; }, in(c,v){ q._in={c,v}; return q; },
      then(res){
        if (q._upd) { window.__writes.push({ ids:q._in?q._in.v.slice():null, eq:{...q._eq} });
          return Promise.resolve({ error:null }).then(res); }
        let d = rows.filter(r=>r.recipient===q._eq.recipient);
        if (q._eq.read === false) d = d.filter(r=>r.read!==true);
        if (q._lim != null) d = d.slice(0, q._lim);
        return Promise.resolve({ data:d.map(r=>({...r})), error:null }).then(res);
      } };
    return q;
  } } };
  __wfOpenRegs = { at:0, ids:null };
});
await page.evaluate(() => wfRefreshBell());
s = await read();
T('48 معلّقاً تُعَدّ 48 لا 30 (سقف لوحة العرض لا يَقصُر البادج)', s.badge === '48', s.badge);
T('ولوحة العرض تبقى مسقوفة بـ30 صفّاً (اللوحة عرضٌ لا عدّاد)', s.rows === 30, String(s.rows));

/* ── (هـ) فشل قراءة حالة التسجيلات: فشلٌ مغلق ── */
await page.evaluate(() => {
  const rows = [{ id:'NX', recipient:'Mahmoud', title:'طلب تسجيل مورد جديد',
    body:'منشأة — بانتظار المراجعة (DG-DONE99)', link:'registrations', read:false,
    created_at:'2026-09-01T08:00:00Z' }];
  window.__writes = [];
  CLOUD = { enabled:true, client:{ from:(name)=>{
    if (name === 'proc_supplier_registrations') {
      const q = { select(){return q;}, eq(){return q;}, limit(){return q;},
        then(res){ return Promise.resolve({ error:{message:'denied'}, data:null }).then(res); } };
      return q;
    }
    const q = { _eq:{}, _upd:null, _in:null, _lim:null,
      select(){return q;}, order(){return q;}, limit(n){ q._lim=n; return q; },
      update(p){ q._upd=p; return q; }, eq(c,v){ q._eq[c]=v; return q; }, in(c,v){ q._in={c,v}; return q; },
      then(res){
        if (q._upd) { window.__writes.push({ ids:q._in?q._in.v.slice():null, eq:{...q._eq} });
          return Promise.resolve({ error:null }).then(res); }
        let d = rows.filter(r=>r.recipient===q._eq.recipient);
        if (q._eq.read === false) d = d.filter(r=>r.read!==true);
        if (q._lim != null) d = d.slice(0, q._lim);
        return Promise.resolve({ data:d.map(r=>({...r})), error:null }).then(res);
      } };
    return q;
  } } };
  __wfOpenRegs = { at:0, ids:null };
});
await page.evaluate(() => wfRefreshBell());
s = await read();
T('تعذّر قراءة الحالة ⇒ صفر تسوية والعدّاد يبقى قائماً (فشلٌ مغلق)',
  s.writes.length === 0 && s.badge === '1', JSON.stringify({ w:s.writes.length, b:s.badge }));

/* ── (و) الجوال: الجرس والبادج داخل الشاشة بلا انزلاق ── */
await page.setViewportSize({ width: 393, height: 852 });
await install({ done: 2, info: 1 });
await page.evaluate(() => wfRefreshBell());
const mob = await page.evaluate(() => {
  document.documentElement.style.overflowX = 'visible';   // القناع يقيس نفسه
  const over = Math.max(0, document.documentElement.scrollWidth - document.documentElement.clientWidth);
  document.documentElement.style.overflowX = '';
  const bell = document.getElementById('wf-bell').getBoundingClientRect();
  return { over, inside: bell.left >= -1 && bell.right <= innerWidth + 1 && bell.bottom <= innerHeight + 1 };
});
T('على 393px: الجرس داخل الشاشة وصفر انزلاق أفقيّ',
  mob.over === 0 && mob.inside, JSON.stringify(mob));
await page.screenshot({ path: path.join(SHOTS, 'bell-mobile.png'), fullPage: false });

T('صفر خطأ صفحة', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | '));
T('صفر انتهاك CSP', csp.length === 0, csp.slice(0, 2).join(' | '));

await browser.close();
const bad = results.filter(r => !r[1]);
for (const [n, ok, d] of results) console.log(`  ${ok ? '✓' : '✗'} ${n}${d && !ok ? '  → ' + d : ''}`);
console.log(`\nالجرس: ${results.length - bad.length}/${results.length} · اللقطات: ${SHOTS}`);
process.exit(bad.length ? 1 : 0);

/* ══════════════════════════════════════════════════════════════════════
   معاينة دعوة الموظّف — تحت CSP الإنتاج
   ----------------------------------------------------------------------
   ثلاث شاشات: نموذج الدعوة في لوحة الإدارة · صفحة تفعيل الموظّف ·
   قالب بريد الدعوة كما يراه في صندوقه.

     node scripts/csp-preview-server.mjs &      # منفذ 8812، ترويسات _headers حرفيّاً
     node scripts/e2e/staff-invite-screens.mjs

   ⚠️ لا اتصال بالإنتاج: نقطة `/api/staff-invite` مُعترَضة ومُقلَّدة بالكامل،
   وقالب البريد يُولَّد من الدالّة نفسها في Node لا من نسخة مكتوبة يدويّاً —
   فلو تغيّر القالب تغيّرت اللقطة معه.
   ══════════════════════════════════════════════════════════════════════ */
import { chromium } from 'playwright';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolveChromiumExecutable } from './chromium-path.mjs';

const OUT = process.env.SHOT_DIR || '/tmp/staff-invite';
const ORIGIN = 'http://127.0.0.1:8812';
mkdirSync(OUT, { recursive: true });

const checks = [];
const ok = (name, pass, detail) => checks.push({ name, pass, detail });

const INVITE_URL = `${ORIGIN}/staff-register.html?t=TESTTOKEN.SIG`;
const TOKEN_DATA = {
  ok: true, display_name: 'صالح بن عبدالله الميداني', email: 'saleh@aldeyabi.com',
  sector: 'الصيانة والتشغيل', job_title: 'فنّي صيانة أوّل',
  expires_at: new Date(Date.now() + 14 * 86400000).toISOString(), domain: 'aldeyabi.com',
};

const browser = await chromium.launch({ executablePath: resolveChromiumExecutable() });

/* ── ١) صفحة تفعيل الموظّف (سطح مكتب + جوال) ── */
for (const [tag, vw] of [['desktop', { width: 1280, height: 900 }], ['mobile', { width: 393, height: 852 }]]) {
  const ctx = await browser.newContext({ viewport: vw, locale: 'ar-SA' });
  const page = await ctx.newPage();
  const errors = [], csp = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });
  await page.route('**/api/staff-invite*', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(TOKEN_DATA) }));

  await page.goto(INVITE_URL, { waitUntil: 'networkidle' });
  await page.waitForSelector('#form:not(.hidden)', { timeout: 5000 });
  await page.screenshot({ path: `${OUT}/1-activate-${tag}.png`, fullPage: true });

  if (tag === 'desktop') {
    ok('الصفحة تعرض اسم المدعوّ وبريده ومسمّاه من الرمز',
      (await page.textContent('#w-name')) === TOKEN_DATA.display_name
      && (await page.textContent('#w-email')) === TOKEN_DATA.email
      && (await page.textContent('#w-job')) === TOKEN_DATA.job_title);
    ok('ولا حقل لتعديل البريد ولا الاسم (لا انتحال)',
      (await page.locator('#f-email').count()) === 0 && (await page.locator('#f-name').count()) === 0);
    ok('والحقول المتاحة: الجوال وكلمتا المرور فقط',
      (await page.locator('form input:not([disabled])').count()) === 3);
    ok('وشارة القطاع ظاهرة',
      /الصيانة والتشغيل/.test(await page.textContent('#sector-chip')));

    // كلمتان غير متطابقتين ⇒ منع محلّي قبل أي رحلة
    await page.fill('#f-pass', 'Passw0rd!'); await page.fill('#f-pass2', 'Different1');
    await page.click('#submit');
    await page.waitForTimeout(150);
    ok('وعدم تطابق كلمتَي المرور يُمنَع محلّياً',
      /غير متطابقتين/.test(await page.textContent('#out')));

    // مسار النجاح
    await page.route('**/api/staff-invite?t=*', (route) => route.request().method() === 'POST'
      ? route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, active: true }) })
      : route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(TOKEN_DATA) }));
    await page.fill('#f-pass2', 'Passw0rd!');
    await page.click('#submit');
    await page.waitForTimeout(400);
    ok('والنجاح يقول «يمكنك الدخول الآن» لا «بانتظار التفعيل»',
      /يمكنك الدخول الآن/.test(await page.textContent('#out')));
    await page.screenshot({ path: `${OUT}/2-activated.png`, fullPage: true });
  }

  if (tag === 'mobile') {
    const slide = await page.evaluate(() => {
      document.documentElement.style.overflowX = 'visible';   // القناع يقيس نفسه
      const w = document.documentElement.scrollWidth - document.documentElement.clientWidth;
      document.documentElement.style.overflowX = '';
      return w;
    });
    ok('وصفر انزلاق أفقيّ على 393px', slide <= 0, `slide=${slide}`);
    const small = await page.evaluate(() => [...document.querySelectorAll('input')]
      .filter((i) => parseFloat(getComputedStyle(i).fontSize) < 16).length);
    ok('ولا حقل دون 16px (فلا يُقرّب iOS)', small === 0, `small=${small}`);
  }

  ok(`صفر خطأ صفحة (${tag})`, errors.length === 0, errors[0]);
  ok(`صفر انتهاك CSP (${tag})`, csp.length === 0, csp[0]);
  await ctx.close();
}

/* ── ٢) قالب البريد — يُولَّد من الدالّة نفسها ── */
{
  const src = await import('node:fs').then((m) => m.promises.readFile('functions/api/staff-invite.js', 'utf8'));
  const { BRAND, esc } = await import('../../functions/api/_pr-shared.js');
  // نستخرج الدالّة ونشغّلها بحقن esc/BRAND — فاللقطة من القالب الحيّ لا من نسخة.
  const body = src.slice(src.indexOf('function inviteEmail('));
  const fnSrc = body.slice(0, body.indexOf('\n}\n') + 3);
  const inviteEmail = new Function('esc', 'BRAND', `${fnSrc}; return inviteEmail;`)(esc, BRAND);
  const html = inviteEmail({
    displayName: TOKEN_DATA.display_name, sector: TOKEN_DATA.sector,
    jobTitle: TOKEN_DATA.job_title, email: TOKEN_DATA.email,
    link: INVITE_URL, expiresAt: Date.now() + 14 * 86400000, inviter: 'عبدالله الذيابي',
  });
  writeFileSync(`${OUT}/invite-email.html`, html);

  const ctx = await browser.newContext({ viewport: { width: 700, height: 900 }, locale: 'ar-SA' });
  const page = await ctx.newPage();
  await page.setContent(html, { waitUntil: 'load' });
  await page.screenshot({ path: `${OUT}/3-email.png`, fullPage: true });
  ok('قالب البريد يُرسَم بلا أي مصدر خارجيّ', !/https?:\/\/(?!127\.0\.0\.1)/.test(html.replace(/href="[^"]*"/g, '')));
  ok('وفيه زرّ التفعيل والرابط الاحتياطيّ',
    html.includes('تفعيل الحساب وإنشاء كلمة المرور') && html.includes('لا يعمل الزرّ؟'));

  // جوال: عملاء البريد على الهاتف
  const m = await browser.newContext({ viewport: { width: 393, height: 852 }, locale: 'ar-SA' });
  const mp = await m.newPage();
  await mp.setContent(html, { waitUntil: 'load' });
  await mp.screenshot({ path: `${OUT}/3-email-mobile.png`, fullPage: true });
  const mSlide = await mp.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  ok('والقالب لا ينزلق أفقيّاً على 393px', mSlide <= 1, `slide=${mSlide}`);
  await ctx.close(); await m.close();
}

/* ── ٣) نموذج الدعوة في لوحة الإدارة ── */
{
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'ar-SA' });
  const page = await ctx.newPage();
  const errors = [], csp = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

  await page.goto(`${ORIGIN}/index.html`, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => typeof window.staffInviteOpen === 'function', { timeout: 15000 });
  /* ⚠️ `hideLoginScreen()` لازمة: بطاقة الدخول تبقى فوق الصفحة وتعترض النقر،
     فالزرّ «مرئيّ ومُمكَّن» ومع ذلك لا يُنقَر — وهو ما أوقف أوّل تشغيل. */
  await page.evaluate(() => {
    STATE.currentUser = { username: 'Abdullah', display_name: 'عبدالله', role: 'admin', permissions: {} };
    try { hideLoginScreen(); } catch (e) {}
    try { hydSettle('ready'); } catch (e) {}
    staffInviteOpen();
  });
  await page.waitForSelector('#modal-staff-invite', { timeout: 5000 });
  await page.fill('#si-name', 'صالح بن عبدالله الميداني');
  await page.fill('#si-email', 'saleh@aldeyabi.com');
  await page.selectOption('#si-sector', 'الصيانة والتشغيل');
  await page.fill('#si-job', 'فنّي صيانة أوّل');
  await page.screenshot({ path: `${OUT}/4-admin-form.png`, fullPage: false });

  ok('نموذج الدعوة فيه الاسم والبريد والقطاع والمسمّى',
    (await page.locator('#si-name').count()) === 1 && (await page.locator('#si-email').count()) === 1
    && (await page.locator('#si-sector').count()) === 1 && (await page.locator('#si-job').count()) === 1);
  /* ⚠️ الفحص مُنطاق **بالنافذة** لا بالصفحة: «توليد الرابط» ترد في وحدة RFQ
     غير ذات صلة داخل السكربت المضمَّن، فمسحُ `page.content()` كلّه يُنتج
     إيجابية كاذبة (وقعت فعلاً في أوّل تشغيل). */
  const modalTxt = await page.locator('#modal-staff-invite').innerHTML();
  ok('ولا أثر لتوليد رابط مشترك في النافذة',
    (await page.locator('#si-days').count()) === 0
    && !/توليد الرابط/.test(modalTxt) && !/staffInviteMint/.test(modalTxt)
    && !/wa\.me/.test(modalTxt));

  // بريد خارجيّ ⇒ منع محلّي بلا رحلة
  await page.fill('#si-email', 'saleh@gmail.com');
  await page.click('text=إرسال الدعوة');
  await page.waitForTimeout(150);
  ok('وبريد خارج النطاق يُمنَع قبل أي طلب', /بريد الشركة/.test(await page.textContent('#si-out')));

  // نجاح الإرسال
  await page.route('**/api/staff-invite', (route) => route.fulfill({
    status: 200, contentType: 'application/json',
    body: JSON.stringify({ ok: true, sent: true, url: INVITE_URL, email: 'saleh@aldeyabi.com',
      sector: 'الصيانة والتشغيل', expires_at: TOKEN_DATA.expires_at }) }));
  await page.fill('#si-email', 'saleh@aldeyabi.com');
  await page.click('text=إرسال الدعوة');
  await page.waitForTimeout(400);
  const out = await page.textContent('#si-out');
  ok('والنجاح يؤكّد الإرسال ويعرض الرابط احتياطاً',
    /أُرسلت الدعوة/.test(out) && (await page.locator('#si-out input').inputValue()) === INVITE_URL);
  await page.screenshot({ path: `${OUT}/5-admin-sent.png`, fullPage: false });

  ok('صفر خطأ صفحة (لوحة الإدارة)', errors.length === 0, errors[0]);
  ok('صفر انتهاك CSP (لوحة الإدارة)', csp.length === 0, csp[0]);
  await ctx.close();
}

await browser.close();

let bad = 0;
for (const c of checks) { if (!c.pass) bad++; console.log(`${c.pass ? '✓' : '✗ FAIL'}  ${c.name}${c.detail ? '  — ' + c.detail : ''}`); }
console.log(`\nاللقطات في ${OUT}`);
if (bad) { console.error(`\n❌ ${bad} فحص فشل`); process.exit(1); }
console.log(`✅ ${checks.length}/${checks.length} فحصاً نجحت`);

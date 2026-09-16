import { resolveChromiumExecutable } from '/home/user/MR/scripts/e2e/chromium-path.mjs';
const { chromium } = await import('/home/user/MR/node_modules/playwright/index.mjs');

// موظّف ميدانيّ مُنطَّق بحزمة قالب «موظّف ميدانيّ» — كما يصل من رابط الدعوة:
// المفاتيح الستّة فقط، و can_use_ai غائبة عمداً (هي لبّ البلاغ).
const FIELD = {
  can_create_pr: true, can_upload_docs: true, can_comment: true,
  can_print_followup: true, can_receive_po: true, can_view_amounts: false,
};

const ep = resolveChromiumExecutable();
const b = await chromium.launch(ep ? { headless: true, executablePath: ep } : { headless: true });
const page = await b.newPage({ viewport: { width: 1280, height: 900 } });
const errs = [], csp = [];
page.on('pageerror', (e) => errs.push(String(e)));
page.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()); });

await page.goto('http://127.0.0.1:8812/index.html', { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => typeof window.hasPermission === 'function');

const out = await page.evaluate(async (perms) => {
  STATE.currentUser = {
    username: 'field.staff', displayName: 'موظّف ميدانيّ', role: 'user',
    permissions: perms, scopeSectors: ['الصيانة والتشغيل'],
  };
  const r = { scoped: isScopedUser(), create: hasPermission('can_create_pr'), ai: hasPermission('can_use_ai') };
  // اعترِض التوست لنعرف إن ظهر «صلاحية مرفوضة»
  const toasts = [];
  const realToast = window.toast;
  window.toast = (kind, title, msg) => { toasts.push(`${kind}|${title}|${msg}`); };
  // امنع فتح مُنتقي الملفات ونافذة الشبكة — نختبر البوّابة وحدها
  const realCreate = document.createElement.bind(document);
  document.createElement = (t) => { const el = realCreate(t); if (t === 'input') el.click = () => { r.filePickerOpened = true; }; return el; };
  window.loadAIConfig = async () => ({ enabled: true, useProxy: true, model: 'gemini-2.5-flash' });
  await window.prParseForm();
  document.createElement = realCreate; window.toast = realToast;
  r.toasts = toasts;
  r.denied = toasts.some((t) => /صلاحية مرفوضة/.test(t));
  return r;
}, FIELD);

console.log(JSON.stringify({ ...out, pageErrors: errs.length, cspViolations: csp.length }, null, 1));
await b.close();
process.exit(out.scoped && out.create && !out.ai && out.filePickerOpened && !out.denied && !errs.length && !csp.length ? 0 : 1);

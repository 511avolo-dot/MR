/**
 * تأكيدات تذكير الاستلام لصاحب الطلب (/api/receipt-reminder?sweep=1)
 * ════════════════════════════════════════════════════════════════════════════
 * سلوكيّة على شبكة مُقلَّدة: تُشغّل الكنس الحقيقيّ وتقرأ ما أُرسل لـResend وما كُتب
 * في التدقيق. الحرّاس: مُطفأ افتراضاً · فشل مغلق عند تعذّر أيّ قراءة · ملخّص واحد
 * لكل شخص · الإيقاع لكل أمر (أوّل يوم تأخير · كل 3 أيام · إسكات 5 أيام بعد ردّ
 * أو استلام جزئي) · لا مبالغ في البريد · لا أوامر مغلقة/ملغاة/لطلب منتهٍ أو مؤرشَف ·
 * لا حساب موقوف · سقف الأوامر في البريد وما فاض لا يُقيَّد · الكرون والموظّف فقط.
 *
 * التشغيل:  node db/portal-tests/receipt-reminder.test.mjs   (خروج غير صفري عند أي فشل)
 */
const ep = await import('../../functions/api/receipt-reminder.js');
const lib = await import('../../functions/api/_receipt-reminder.js');

let failed = 0, total = 0;
const T = (name, cond, extra = '') => {
  total++; if (!cond) failed++;
  console.log(`${cond ? '✓' : '✗ FAIL'}  ${name}${extra ? '  — ' + extra : ''}`);
};

const ENV = {
  SUPABASE_URL: 'https://x.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'svc-key',
  SUPABASE_ANON_KEY: 'anon-key',
  RESEND_API_KEY: 're_test',
  CRON_SECRET: 'cron-secret-xyz',
  PUBLIC_ORIGIN: 'https://suppliers.aldeyabi.com',
};
const DAY = 86400000;
const NOW = Date.now();
const TODAY = lib.rrToday(NOW);
const dAgo = (n) => new Date(Date.parse(TODAY) - n * DAY).toISOString().slice(0, 10);
const iso = (msAgo) => new Date(NOW - msAgo).toISOString();
const items = (n = 2) => Array.from({ length: n }, (_, i) => ({ desc: `صنف ${i + 1}`, unit: 'حبة', qty: 4, price: 24999, received_qty: 0 }));

/* أوامر بأحوال الإيقاع كلّها. المبالغ مميّزة (99999/114999) لإثبات أنها لا تتسرّب */
const PO = (po_number, extra = {}) => ({
  po_number, status: 'تسليم للإدارة المالية', project: 'جامعة الملك سعود', supplier: 'مؤسسة الاختبار',
  expected_delivery: dAgo(10), items: items(), receipts: [], subtotal: 99999, total: 114999, ...extra,
});
const POS = [
  PO('PO-LATE10'),
  PO('PO-LATE1', { expected_delivery: dAgo(1), status: 'قيد التوريد' }),
  PO('PO-TODAY', { expected_delivery: dAgo(0) }),
  PO('PO-DONE', { status: 'تسليم كامل', expected_delivery: dAgo(20) }),
  PO('PO-ALIAS', { status: 'مُسلَّم', expected_delivery: dAgo(20) }),
  PO('PO-CANCEL', { status: 'ملغى', expected_delivery: dAgo(20) }),
  PO('PO-SENT2', { expected_delivery: dAgo(15) }),
  PO('PO-SENT3', { expected_delivery: dAgo(15) }),
  PO('PO-REPLIED', { expected_delivery: dAgo(15) }),
  PO('PO-RCV', { status: 'تسليم جزئي', expected_delivery: dAgo(15), receipts: [{ at: iso(1 * DAY), lines: [] }] }),
  PO('PO-NODATE', { expected_delivery: null }),
  PO('PO-CLOSEDPR'), PO('PO-ARCH'), PO('PO-OFFLINK'),
  PO('PO-TWO', { expected_delivery: dAgo(3), items: items(5) }),
  PO('PO-ALI', { expected_delivery: dAgo(5) }),
  PO('PO-SUSP'),
];
const PRS = [
  { id: 'PR-1', requester: 'mostafa.kishk', status: 'approved', archived_at: null },
  { id: 'PR-2', requester: 'mostafa.kishk', status: 'approved', archived_at: null },
  { id: 'PR-CLOSED', requester: 'mostafa.kishk', status: 'closed', archived_at: null },
  { id: 'PR-ARCH', requester: 'mostafa.kishk', status: 'approved', archived_at: iso(DAY) },
  { id: 'PR-ALI', requester: 'Ali', status: 'approved', archived_at: null },
  { id: 'PR-SUSP', requester: 'old', status: 'approved', archived_at: null },
];
const LINK = (pr_id, po_number, active = true) => ({ pr_id, po_number, active });
const LINKS = [
  ...['PO-LATE10', 'PO-LATE1', 'PO-TODAY', 'PO-DONE', 'PO-ALIAS', 'PO-CANCEL', 'PO-SENT2', 'PO-SENT3',
      'PO-REPLIED', 'PO-RCV', 'PO-NODATE', 'PO-TWO'].map((p) => LINK('PR-1', p)),
  LINK('PR-2', 'PO-TWO'),
  LINK('PR-CLOSED', 'PO-CLOSEDPR'), LINK('PR-ARCH', 'PO-ARCH'), LINK('PR-1', 'PO-OFFLINK', false),
  LINK('PR-ALI', 'PO-ALI'), LINK('PR-SUSP', 'PO-SUSP'),
];
const USERS = [
  { username: 'mostafa.kishk', display_name: 'مصطفى كشك', email: 'mostafa.kishk@aldeyabi.com', notify_email: null, active: true },
  { username: 'ali', display_name: 'علي', email: 'ali@aldeyabi.com', notify_email: 'ali.notify@aldeyabi.com', active: true },
  { username: 'old', display_name: 'موقوف', email: 'old@aldeyabi.com', active: false },
];
const AUD = (po, action, msAgo, nv = {}) => ({ entity_type: 'receipt_reminder', entity_id: po, action, new_value: nv, ts: iso(msAgo) });
const AUDIT = [
  AUD('PO-SENT2', 'notify', 2 * DAY),
  AUD('PO-SENT3', 'notify', 6 * DAY), AUD('PO-SENT3', 'notify', 3 * DAY),
  AUD('PO-REPLIED', 'notify', 4 * DAY), AUD('PO-REPLIED', 'reply', 2 * DAY, { reason: 'supplier' }),
  AUD('PO-RCV', 'notify', 10 * DAY),
];

function net(o = {}) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url), m = (init.method || 'GET').toUpperCase();
    calls.push({ url: u, method: m, body: init.body });
    const ok = (v) => new Response(JSON.stringify(v), { status: 200 });
    const bad = () => new Response('{"message":"x"}', { status: 500 });
    if (u.includes('/auth/v1/user')) {
      const a = (init.headers && (init.headers.Authorization || init.headers.authorization)) || '';
      return a.includes('good-jwt') ? ok({ email: 'staff@aldeyabi.com' }) : new Response('{}', { status: 401 });
    }
    if (u.includes('/rest/v1/proc_settings')) {
      if (o.settingsFail) return bad();
      return ok(o.noSetting ? [] : [{ value: { enabled: o.enabled !== false } }]);
    }
    if (u.includes('/rest/v1/proc_audit_log') && m === 'GET' && u.includes('action=eq.sweep')) {
      if (o.throttleFail) return bad();
      return ok(o.throttled ? [{ id: 1 }] : []);
    }
    if (u.includes('/rest/v1/proc_audit_log') && m === 'GET') return o.auditFail ? bad() : ok(o.audit || AUDIT);
    if (u.includes('/rest/v1/proc_pr_po_links')) return o.linksFail ? bad() : ok(o.links || LINKS);
    if (u.includes('/rest/v1/proc_purchase_requests')) return o.prsFail ? bad() : ok(o.prs || PRS);
    if (u.includes('/rest/v1/proc_purchase_orders')) return o.posFail ? bad() : ok(o.pos || POS);
    if (u.includes('/rest/v1/proc_users')) return o.usersFail ? bad() : ok(o.users || USERS);
    if (u.includes('api.resend.com')) return new Response('{"id":"e"}', { status: o.mailFail ? 500 : 200 });
    return ok({});
  };
  const mails = () => calls.filter((c) => c.url.includes('api.resend.com')).map((c) => JSON.parse(c.body));
  const audits = () => calls.filter((c) => c.url.includes('/proc_audit_log') && c.method === 'POST')
    .flatMap((c) => JSON.parse(c.body));
  return { calls, mails, audits, restore: () => { globalThis.fetch = real; } };
}
const REQ = (headers = {}, qs = '?sweep=1', origin = 'https://suppliers.aldeyabi.com') => new Request(
  `https://suppliers.aldeyabi.com/api/receipt-reminder${qs}`,
  { method: 'POST', headers: { origin, host: 'suppliers.aldeyabi.com', ...headers } });
const CRON = { Authorization: 'Bearer cron-secret-xyz' };
const run = async (o, headers = CRON, qs = '?sweep=1', origin) => {
  const n = net(o);
  try {
    const res = await ep.onRequestPost({ request: REQ(headers, qs, origin), env: ENV });
    return { res, body: await res.json(), mails: n.mails(), audits: n.audits(), calls: n.calls };
  } finally { n.restore(); }
};
const mailTo = (r, addr) => r.mails.find((m) => (m.to || []).includes(addr));

console.log('— الصلاحية —');
{
  const r = await run({}, {});
  T('بلا سرّ ولا جلسة ⇒ 401', r.res.status === 401 && r.mails.length === 0);
  const r2 = await run({}, { Authorization: 'Bearer wrong' });
  T('سرّ خاطئ ⇒ 401', r2.res.status === 401 && r2.mails.length === 0);
  const r3 = await run({}, { Authorization: 'Bearer good-jwt' });
  T('جلسة موظّف same-origin ⇒ يعمل (by=staff)', r3.body.ok && r3.body.by === 'staff', JSON.stringify(r3.body));
  const r4 = await run({}, { Authorization: 'Bearer good-jwt' }, '?sweep=1', 'https://evil.example');
  T('جلسة من أصل آخر ⇒ 401', r4.res.status === 401 && r4.mails.length === 0);
  const g = await ep.onRequestGet({ request: new Request('https://suppliers.aldeyabi.com/api/receipt-reminder'), env: ENV });
  const gt = await g.text();
  T('فحص الصحّة منطقيات فقط (لا قيمة سرّ)', /"ok":true/.test(gt) && !gt.includes('re_test') && !gt.includes('cron-secret') && !gt.includes('svc-key'));
  const p = await ep.onRequestPost({ request: REQ(CRON, ''), env: ENV });
  T('POST بلا sweep ⇒ 405', p.status === 405);
}

console.log('— مُطفأ افتراضاً وفشل مغلق —');
{
  const r = await run({ noSetting: true });
  T('بلا صفّ إعداد ⇒ لا إرسال', r.body.skipped === 'disabled' && r.mails.length === 0);
  const r2 = await run({ enabled: false });
  T('enabled=false ⇒ لا إرسال', r2.body.skipped === 'disabled' && r2.mails.length === 0);
  for (const [k, label] of [['settingsFail', 'الإعداد'], ['throttleFail', 'الخانق'], ['linksFail', 'الروابط'],
                            ['prsFail', 'الطلبات'], ['posFail', 'الأوامر'], ['usersFail', 'المستخدمين'],
                            ['auditFail', 'سجلّ الإرسال']]) {
    const x = await run({ [k]: true });
    T(`تعذّر قراءة ${label} ⇒ 502 بلا إرسال`, x.res.status === 502 && x.mails.length === 0, `${x.res.status}`);
  }
  const t = await run({ throttled: true });
  T('دفعة خلال 20 ساعة ⇒ throttled بلا إرسال', t.body.skipped === 'throttled' && t.mails.length === 0);
  const tf = await run({ throttled: true }, CRON, '?sweep=1&force=1');
  T('الكرون بـforce=1 يتجاوز الخانق', tf.body.ok && tf.mails.length > 0);
  const ts = await run({ throttled: true }, { Authorization: 'Bearer good-jwt' }, '?sweep=1&force=1');
  T('الموظّف لا يتجاوز الخانق بـforce', ts.body.skipped === 'throttled' && ts.mails.length === 0);
}

console.log('— الملخّص والإيقاع —');
{
  const r = await run({});
  T('بريد واحد لكل شخص (اثنان) لا لكل أمر', r.mails.length === 2, `mails=${r.mails.length}`);
  const k = mailTo(r, 'mostafa.kishk@aldeyabi.com');
  T('صاحب الطلب يصله على بريده المخزَّن', !!k);
  const a = mailTo(r, 'ali.notify@aldeyabi.com');
  T('بريد المراسلة يتقدّم على بريد الدخول', !!a && !mailTo(r, 'ali@aldeyabi.com'));
  T('المستخدم الموقوف لا يُراسَل', !r.mails.some((m) => (m.to || []).includes('old@aldeyabi.com')));
  const h = k ? k.html : '';
  const has = (p) => h.includes(`?po=${p}&`);
  T('أوّل تذكير بعد تجاوز الموعد (10 أيام)', has('PO-LATE10'));
  T('يوم تأخير واحد يكفي', has('PO-LATE1'));
  T('موعده اليوم ⇒ لم يتأخّر بعد', !has('PO-TODAY'));
  T('تسليم كامل لا يُسأل عنه', !has('PO-DONE'));
  T('المرادف «مُسلَّم» مغلق أيضاً', !has('PO-ALIAS'));
  T('الملغى لا يُسأل عنه', !has('PO-CANCEL'));
  T('ذُكِّر قبل يومين ⇒ لا تكرار', !has('PO-SENT2'));
  T('ذُكِّر قبل 3 أيام ⇒ يُعاد', has('PO-SENT3'));
  T('ردّ «لم يصل» قبل يومين ⇒ مُسكَت', !has('PO-REPLIED'));
  T('استلام جزئي أمس ⇒ مُسكَت', !has('PO-RCV'));
  T('بلا موعد تسليم ⇒ لا حكم', !has('PO-NODATE'));
  T('طلب مُقفَل ⇒ أمره خارج التذكير', !has('PO-CLOSEDPR'));
  T('طلب مؤرشَف ⇒ أمره خارج التذكير', !has('PO-ARCH'));
  T('رابط غير نشط ⇒ لا تذكير', !has('PO-OFFLINK'));
  T('أمر مربوط بطلبين يظهر مرّة واحدة بالرقمين', (h.match(/\?po=PO-TWO&amp;act=receive/g) || []).length === 1
    && /طلبات الشراء: <span[^>]*>PR-1<\/span> · <span[^>]*>PR-2<\/span>/.test(h));
  T('الأشدّ تأخيراً أوّلاً', h.indexOf('?po=PO-SENT3&') < h.indexOf('?po=PO-LATE10&')
    && h.indexOf('?po=PO-LATE10&') < h.indexOf('?po=PO-TWO&') && h.indexOf('?po=PO-TWO&') < h.indexOf('?po=PO-LATE1&'));
  T('الموضوع بصيغة العدد العربية', k && k.subject.includes('4 أوامر شراء'), k && k.subject);
  T('«متأخر 10 أيام» و«متأخر يوم واحد»', h.includes('متأخر 10 أيام') && h.includes('متأخر يوم واحد'));
  T('المرحلة بلغة صاحب الطلب', h.includes('لدى الإدارة المالية'));
  T('زرّا الاستلام و«لم تصل» روابط عميقة للنظام',
    h.includes('https://suppliers.aldeyabi.com/?po=PO-LATE10&amp;act=receive') && h.includes('https://suppliers.aldeyabi.com/?po=PO-LATE10&amp;act=wait'));
  T('البنود تُذكر (3 ثم «و2 أخرى»)', h.includes('صنف 1 · صنف 2 · صنف 3 · و2 أخرى'));
  T('لا مبالغ في البريد إطلاقاً', !/99999|114999|24999|ر\.س/.test(h) && !/99999|114999|24999|ر\.س/.test(k ? k.text : ''));
  T('نسخة نصّية مرفقة', k && typeof k.text === 'string' && k.text.includes('PO-LATE10'));
  const notes = r.audits.filter((x) => x.action === 'notify');
  T('يُقيَّد كل أمر ظهر في البريد (5 = 4 لمصطفى + 1 لعلي)', notes.length === 5, `n=${notes.length}`);
  T('القيد بالجولة والمستلِم والطلبات', notes.every((x) => x.entity_type === 'receipt_reminder' && x.new_value.to && x.new_value.round >= 1)
    && notes.find((x) => x.entity_id === 'PO-SENT3').new_value.round === 3);
  const sw = r.audits.find((x) => x.action === 'sweep');
  T('قيد التشغيلة بالأعداد', sw && sw.new_value.people === 2 && sw.new_value.sent === 2 && sw.new_value.orders === 5);
  T('الاستجابة بالأعداد', r.body.sent === 2 && r.body.orders === 5 && r.body.failed === 0);
}

console.log('— الفشل والسقف —');
{
  const r = await run({ mailFail: true });
  T('فشل Resend ⇒ لا قيد إرسال (يُعاد غداً)', r.audits.filter((x) => x.action === 'notify').length === 0 && r.body.failed === 2 && r.body.sent === 0);
  const many = Array.from({ length: 30 }, (_, i) => PO(`PO-M${String(i).padStart(2, '0')}`, { expected_delivery: dAgo(5 + i) }));
  const r2 = await run({ pos: many, links: many.map((p) => LINK('PR-1', p.po_number)), audit: [] });
  const notes = r2.audits.filter((x) => x.action === 'notify');
  T('سقف 25 أمراً في البريد الواحد', notes.length === 25, `n=${notes.length}`);
  T('ويُعلَن الباقي بلا قيد له', r2.mails[0] && r2.mails[0].html.includes('والباقي (5 أوامر شراء)'));
  T('وأشدّها تأخيراً هي المعروضة', notes.some((x) => x.entity_id === 'PO-M29') && !notes.some((x) => x.entity_id === 'PO-M00'));
}

{
  // الإنتاج يحمل أسماء مستخدمين تختلف بالحالة فقط: الطلبان لشخص واحد ⇒ بريد واحد
  const prs = [{ id: 'PR-A', requester: 'mostafa.kishk', status: 'approved' }, { id: 'PR-B', requester: 'Mostafa.Kishk', status: 'approved' }];
  const r = await run({ prs, links: [LINK('PR-A', 'PO-LATE10'), LINK('PR-B', 'PO-LATE1')], audit: [] });
  T('اسم الطالب بحالتي أحرف ⇒ بريد واحد بالأمرين', r.mails.length === 1 && r.mails[0].html.includes('?po=PO-LATE10&')
    && r.mails[0].html.includes('?po=PO-LATE1&'), `mails=${r.mails.length}`);
}

console.log('— الوحدة الخالصة —');
{
  T('«اليوم» بتوقيت الرياض: 22:00 UTC يُحسب الغد', lib.rrToday(Date.UTC(2026, 10, 3, 22, 0)) === '2026-11-04');
  T('وقبل منتصف ليل الرياض يبقى اليوم نفسه', lib.rrToday(Date.UTC(2026, 10, 3, 20, 59)) === '2026-11-03');
  T('أيام التأخير', lib.rrDaysLate('2026-10-24', '2026-11-03') === 10 && lib.rrDaysLate('', '2026-11-03') === null);
  T('صيغ العدد', lib.rrCountPO(1) === 'أمر شراء واحد' && lib.rrCountPO(2) === 'أمرا شراء' && lib.rrCountPO(11) === '11 أمر شراء');
  const ev = lib.rrEventsFromAudit([{ entity_type: 'receipt_reminder', entity_id: 'sweep', action: 'notify', ts: iso(1) }]);
  T('قيد التشغيلة لا يُحتسَب إرسالاً لأمر', ev.size === 0);
  const due = lib.rrPoDue(PO('X', { expected_delivery: dAgo(9) }), { sent: 1, lastSent: NOW - (3 * DAY - 5 * 3600000), lastReply: 0 }, NOW);
  T('هامش الساعات: تشغيلة اليوم الثالث لا تتأخّر لليوم الرابع', due.due === true);
}

console.log(`\n${total - failed}/${total} ناجح${failed ? ` · ${failed} فاشل` : ''}`);
if (failed) process.exit(1);

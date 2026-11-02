/**
 * تأكيدات الإرسال الآليّ لدعوات تسجيل الموردين (/api/supplier-invite-link?sweep=1)
 * ════════════════════════════════════════════════════════════════════════════
 * سلوكيّة على شبكة مُقلَّدة: تُشغّل الكنس الحقيقيّ وتقرأ ما أُرسل لـResend وما كُتب
 * في التدقيق. الحرّاس: مُطفأ افتراضاً · فشل مغلق عند تعذّر قراءة الإعداد/التسجيلات/
 * سجلّ الإرسال/الخانق · لا دعوة لمن سجّل · المراحل الثلاث وتوقيتها · واتساب يدويّ
 * يُحتسب «الدعوة» · سقف وخانق · الكرون والموظّف فقط.
 *
 * التشغيل:  node db/portal-tests/supplier-invite.test.mjs   (خروج غير صفري عند أي فشل)
 */
const ep = await import('../../functions/api/supplier-invite-link.js');
const lib = await import('../../functions/api/_supplier-invite.js');

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
  DOC_RENEW_SECRET: 'unit-test-secret',
  PUBLIC_ORIGIN: 'https://suppliers.aldeyabi.com',
};
const DAY = 86400000;
const iso = (msAgo) => new Date(Date.now() - msAgo).toISOString();

/* الدليل: أربعة غير مسجَّلين بأحوال مختلفة + مسجَّلان (بالرابط وبالسجل التجاري) */
const SUPS = [
  { id: 'S-NEW',   name: 'مؤسسة جديدة',      email: 'new@example.com' },
  { id: 'S-WA',    name: 'شركة الواتساب',     email: 'wa@example.com' },     // دُعي واتساب قبل 8 أيام
  { id: 'S-SOON',  name: 'شركة قريبة',        email: 'soon@example.com' },   // دُعي بريداً قبل 3 أيام
  { id: 'S-DONE',  name: 'شركة مكتملة',       email: 'done@example.com' },   // المراحل الثلاث
  { id: 'S-NOMAIL', name: 'بلا بريد',         email: '—' },
  { id: 'S-LINKED', name: 'مسجَّل بالرابط',    email: 'linked@example.com' },
  { id: 'S-CR',    name: 'مسجَّل بالسجل',     email: 'cr@example.com', commercial_reg: '1010101010' },
  { id: 'S-NAME',  name: 'شركة الأنوار للتجارة', email: 'name@example.com' },
];
const REGS = [
  { commercial_reg: '', vat_number: '', legal_name_ar: 'أخرى', link_supplier_id: 'S-LINKED' },
  { commercial_reg: '1010101010', vat_number: '', legal_name_ar: 'غير مطابق', link_supplier_id: null },
  { commercial_reg: '', vat_number: '', legal_name_ar: 'مؤسسة الانوار للتجاره', link_supplier_id: null },
];
const AUDIT = [
  { entity_id: 'S-WA', action: 'supplier_invite_wa', new_value: { name: 'شركة الواتساب' }, ts: iso(8 * DAY) },
  { entity_id: 'S-SOON', action: 'notify', new_value: { stage: 'inv1', channel: 'email' }, ts: iso(3 * DAY) },
  { entity_id: 'S-DONE', action: 'notify', new_value: { stage: 'inv1' }, ts: iso(40 * DAY) },
  { entity_id: 'S-DONE', action: 'notify', new_value: { stage: 'inv2' }, ts: iso(30 * DAY) },
  { entity_id: 'S-DONE', action: 'supplier_invite_wa', new_value: { stage: 'inv3', channel: 'wa' }, ts: iso(15 * DAY) },
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
    if (u.includes('/rest/v1/proc_suppliers')) return ok(o.sups || SUPS);
    if (u.includes('/rest/v1/proc_supplier_registrations')) return o.regsFail ? bad() : ok(REGS);
    if (u.includes('api.resend.com')) return new Response('{"id":"e"}', { status: o.mailFail ? 500 : 200 });
    return ok({});
  };
  const mails = () => calls.filter((c) => c.url.includes('api.resend.com')).map((c) => JSON.parse(c.body));
  const audits = () => calls.filter((c) => c.url.includes('/proc_audit_log') && c.method === 'POST')
    .flatMap((c) => JSON.parse(c.body));
  return { calls, mails, audits, restore: () => { globalThis.fetch = real; } };
}
const REQ = (headers = {}, qs = '?sweep=1') => new Request(
  `https://suppliers.aldeyabi.com/api/supplier-invite-link${qs}`,
  { method: 'POST', headers: { origin: 'https://suppliers.aldeyabi.com', host: 'suppliers.aldeyabi.com', ...headers } });
const CRON = { Authorization: 'Bearer cron-secret-xyz' };
const run = async (o, headers = CRON) => {
  const n = net(o);
  try {
    const res = await ep.onRequestPost({ request: REQ(headers), env: ENV });
    return { res, body: await res.json(), mails: n.mails(), audits: n.audits(), calls: n.calls };
  } finally { n.restore(); }
};

console.log('— الصلاحية —');
{
  const r = await run({}, {});
  T('بلا سرّ ولا جلسة ⇒ 401', r.res.status === 401 && r.mails.length === 0);
  const r2 = await run({}, { Authorization: 'Bearer wrong' });
  T('سرّ خاطئ ⇒ 401', r2.res.status === 401);
  const r3 = await run({ enabled: true }, { Authorization: 'Bearer good-jwt' });
  T('جلسة موظّف same-origin ⇒ يعمل (by=staff)', r3.body.ok && r3.body.by === 'staff', JSON.stringify(r3.body));
}

console.log('— مُطفأ افتراضاً وفشل مغلق —');
{
  const r = await run({ noSetting: true });
  T('بلا صفّ إعداد ⇒ لا إرسال', r.body.skipped === 'disabled' && r.mails.length === 0);
  const r2 = await run({ enabled: false });
  T('enabled=false ⇒ لا إرسال', r2.body.skipped === 'disabled' && r2.mails.length === 0);
  const r3 = await run({ settingsFail: true });
  T('تعذّر قراءة الإعداد ⇒ 502 بلا إرسال', r3.res.status === 502 && r3.mails.length === 0);
  const r4 = await run({ regsFail: true });
  T('تعذّر قراءة التسجيلات ⇒ 502 بلا إرسال (وإلّا دُعي من سجّل)', r4.res.status === 502 && r4.mails.length === 0);
  const r5 = await run({ auditFail: true });
  T('تعذّر قراءة سجلّ الإرسال ⇒ 502 بلا إرسال (وإلّا تكرّرت الرسائل)', r5.res.status === 502 && r5.mails.length === 0);
  const r6 = await run({ throttleFail: true });
  T('تعذّر قراءة الخانق ⇒ 502 بلا إرسال', r6.res.status === 502 && r6.mails.length === 0);
  const r7 = await run({ throttled: true });
  T('دفعة في آخر 20 ساعة ⇒ throttled بلا إرسال', r7.body.skipped === 'throttled' && r7.mails.length === 0);
}

console.log('— من يُراسَل وبأي مرحلة —');
{
  const r = await run({});
  const to = r.mails.map((m) => m.to[0]).sort();
  T('يُراسَل فقط: الجديد + من دُعي واتساب قبل 8 أيام', JSON.stringify(to) === JSON.stringify(['new@example.com', 'wa@example.com']), JSON.stringify(to));
  T('لا دعوة لمن سجّل (بالرابط · بالسجل · بالاسم المطبَّع)',
    !to.some((e) => ['linked@example.com', 'cr@example.com', 'name@example.com'].includes(e)));
  T('لا رسالة قبل موعدها (دُعي قبل 3 أيام)', !to.includes('soon@example.com'));
  T('السلسلة تتوقّف بعد ثلاث رسائل', !to.includes('done@example.com'));
  T('القيمة النائبة «—» ليست بريداً', r.mails.length === 2);
  const wa = r.mails.find((m) => m.to[0] === 'wa@example.com');
  T('واتساب يدويّ سابق يُحتسَب «الدعوة» ⇒ البريد تذكير لا دعوة ثانية', wa && /^تذكير: /.test(wa.subject), wa && wa.subject);
  const nw = r.mails.find((m) => m.to[0] === 'new@example.com');
  T('الجديد يأخذ نصّ الدعوة الأولى', nw && /^استكمال ملف المورد/.test(nw.subject), nw && nw.subject);
  T('الرابط شخصيّ موقَّع على /register?s=', nw && /https:\/\/suppliers\.aldeyabi\.com\/register\?s=[\w-]+\.[\w-]+/.test(nw.html));
  T('نسخة نصّية مرفقة (لا HTML وحده)', nw && nw.text && !/<[a-z]/i.test(nw.text) && nw.text.includes('/register?s='));
  const notes = r.audits.filter((a) => a.action === 'notify' && a.entity_type === 'supplier_invite');
  T('كل إرسال يُقيَّد بمرحلته وقناته', notes.length === 2
    && notes.find((a) => a.entity_id === 'S-WA').new_value.stage === 'inv2'
    && notes.every((a) => a.new_value.channel === 'email'), JSON.stringify(notes.map((a) => a.new_value)));
  const sw = r.audits.find((a) => a.action === 'sweep');
  T('قيد التشغيلة يحمل العدد (الخانق يقرؤه)', sw && sw.entity_type === 'supplier_invite' && sw.new_value.sent === 2);
  // الرمز الذي في الرابط يفتح بطاقة المورد نفسه
  const tok = nw.html.match(/register\?s=([\w.-]+)/)[1];
  const n2 = net({});
  try {
    const g = await ep.onRequestGet({ request: new Request(`https://suppliers.aldeyabi.com/api/supplier-invite-link?s=${tok}`), env: ENV });
    const fetched = n2.calls.find((c) => c.url.includes('/proc_suppliers?id=eq.'));
    T('رمز البريد صالح ويخصّ بطاقة المورد نفسه', g.status === 200 && fetched && fetched.url.includes('id=eq.S-NEW'));
  } finally { n2.restore(); }
}

console.log('— فشل الإرسال لا يُقيَّد —');
{
  const r = await run({ mailFail: true });
  T('فشل Resend ⇒ لا قيد notify (فيُعاد في الدفعة التالية)',
    r.body.sent === 0 && r.body.failed === 2 && !r.audits.some((a) => a.action === 'notify'));
}

console.log('— السقف والترتيب —');
{
  const many = Array.from({ length: 55 }, (_, i) => ({ id: 'S-' + String(i).padStart(3, '0'), name: 'مورد ' + i, email: `m${i}@example.com` }));
  const r = await run({ sups: many, audit: [] });
  T('سقف 40 رسالة في التشغيلة والباقي يُعلَن capped', r.mails.length === 40 && r.body.capped === true && r.body.candidates === 55);
}

console.log('— منطق المراحل (الوحدة الخالصة) —');
{
  const now = Date.now();
  const n0 = lib.inviteNextStage([], now);
  T('بلا إرسال ⇒ الدعوة مستحقّة', n0.stage === 'inv1' && n0.due);
  const n1 = lib.inviteNextStage([{ stage: 'inv1', at: now - 6 * DAY }], now);
  T('بعد 6 أيام من الدعوة ⇒ التذكير غير مستحقّ', n1.stage === 'inv2' && !n1.due);
  const n2 = lib.inviteNextStage([{ stage: 'inv1', at: now - 7 * DAY - 1000 }], now);
  T('بعد 7 أيام ⇒ التذكير مستحقّ', n2.stage === 'inv2' && n2.due);
  const n3 = lib.inviteNextStage([{ stage: 'inv1', at: now - 20 * DAY }, { stage: 'inv2', at: now - 13 * DAY }], now);
  T('التذكير الأخير بعد 14 يوماً من التذكير لا من الدعوة', n3.stage === 'inv3' && !n3.due);
  const n4 = lib.inviteNextStage([{ stage: 'inv1', at: 1 }, { stage: 'inv2', at: 2 }, { stage: 'inv3', at: 3 }], now);
  T('ثلاث مراحل ⇒ done', n4.done === true);
  const s = lib.inviteSendsFromAudit([{ entity_id: 'A', action: 'supplier_invite_wa', new_value: { name: 'x' }, ts: iso(1) }]);
  T('قيد واتساب قديم بلا مرحلة ⇒ inv1 عبر wa', s.get('A')[0].stage === 'inv1' && s.get('A')[0].channel === 'wa');
  const s2 = lib.inviteSendsFromAudit([{ entity_id: 'A', action: 'supplier_invite_wa', new_value: { stage: 'extra' }, ts: iso(1) }]);
  T('مرحلة غير معروفة (إرسال إضافيّ) لا تُحرّك السلسلة', s2.get('A')[0].stage === 'inv1');
  const subjects = ['inv1', 'inv2', 'inv3'].map((st) => lib.supplierInviteEmail('شركة <b>x</b>', 'https://x/register?s=a.b', st));
  T('العنوان يختلف بالمرحلة', new Set(subjects.map((x) => x.subject.split(':')[0])).size === 3);
  T('الاسم مُهرَّب في البريد', subjects.every((x) => !x.html.includes('<b>x</b>') && x.html.includes('&lt;b&gt;x&lt;/b&gt;')));
  T('قرار المالك: لا نبرة «الرابط خاصّ بكم / ملفّكم موجود»',
    subjects.every((x) => !/خاصّ بكم|خاص بكم|ملفّكم موجود|ملفكم موجود/.test(x.html)));
}

console.log('— فحص الصحّة —');
{
  const g = await ep.onRequestGet({ request: new Request('https://suppliers.aldeyabi.com/api/supplier-invite-link'), env: ENV });
  const j = await g.json();
  T('يكشف وجود Resend والكرون (منطقيات لا قيم)', j.checks.resend === true && j.checks.cron_secret === true
    && !JSON.stringify(j).includes('re_test') && !JSON.stringify(j).includes('cron-secret'));
}

if (failed) { console.error(`\n❌ دعوات الموردين: ${failed} من ${total} فشل`); process.exit(1); }
console.log(`\n✅ دعوات الموردين الآليّة: ${total}/${total} PASS`);

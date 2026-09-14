/**
 * تأكيدات حارس الملفات المرفوعة (functions/api/_file-guard.js)
 * ════════════════════════════════════════════════════════════════════════════
 * يحمي مسار رفع المورّد الخارجي (/api/portal-supplier-doc) ومسارَي الموظّفين
 * (/api/portal-quote و/api/portal-doc)، ونقطة وثائق تسجيل الموردين في النظام 1
 * (/api/reg-doc). أي تراجع في الحارس يُفشِل الـCI.
 *
 * التشغيل:  node db/portal-tests/file-guard.test.mjs        (خروج غير صفري عند أي فشل)
 */
import { inspectUpload } from '../../functions/api/_file-guard.js';

const B = (...parts) => {
  const b = Buffer.concat(parts.map((p) => (typeof p === 'string' ? Buffer.from(p, 'latin1') : Buffer.from(p))));
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
};
const pad = (n) => 'x'.repeat(n);

const cases = [
  // ── يجب أن تُقبَل: مستندات سليمة ──────────────────────────────────────────
  ['PDF سليم', true, B(
    '%PDF-1.7\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n',
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n',
    'stream\n' + pad(400) + '\nendstream\nxref\ntrailer<</Root 1 0 R>>\nstartxref\n0\n%%EOF\n')],
  ['JPEG سليم', true, B([0xff, 0xd8, 0xff, 0xe0], pad(500), [0xff, 0xd9])],
  ['PNG سليم', true, B([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13],
    'IHDR', pad(400), 'IEND', [0xae, 0x42, 0x60, 0x82])],

  // ── يجب أن تُرفَض: ناقلات هجوم ────────────────────────────────────────────
  ['PDF بجافاسكربت (OpenAction)', false,
    B('%PDF-1.7\n1 0 obj<</Type/Catalog/OpenAction<</S/JavaScript/JS(app.alert(1))>>>>endobj\n' + pad(300) + '\n%%EOF\n')],
  ['PDF بجافاسكربت مُخفّى بترميز #xx', false,
    B('%PDF-1.7\n1 0 obj<</Type/Catalog/Open#41ction<</S/#4Aava#53cript/JS(x)>>>>endobj\n' + pad(300) + '\n%%EOF\n')],
  ['PDF بمرفق مضمّن (EmbeddedFile)', false,
    B('%PDF-1.4\n1 0 obj<</Type/Filespec/EF<</F 2 0 R>>/EmbeddedFile>>endobj\n' + pad(300) + '\n%%EOF\n')],
  ['PDF بتشغيل خارجي (Launch)', false,
    B('%PDF-1.4\n1 0 obj<</A<</S/Launch/F(cmd.exe)>>>>endobj\n' + pad(300) + '\n%%EOF\n')],
  ['PDF مبتور (بلا %%EOF)', false, B('%PDF-1.4\n' + pad(400))],
  ['HTML متنكّر باسم PDF', false, B('<!DOCTYPE html><html><script>fetch("/x")</script></html>' + pad(200))],
  ['JPEG + PHP ملحق (polyglot)', false,
    B([0xff, 0xd8, 0xff, 0xe0], pad(300), [0xff, 0xd9], '<?php system($_GET["c"]); ?>')],
  ['JPEG ببيانات ملحقة بعد النهاية', false,
    B([0xff, 0xd8, 0xff, 0xe0], pad(300), [0xff, 0xd9], pad(500))],
  ['PNG ببيانات ملحقة بعد IEND', false,
    B([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13], 'IHDR', pad(200),
      'IEND', [0xae, 0x42, 0x60, 0x82], pad(500))],
  ['SVG (سكربت داخلي)', false, B('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>' + pad(200))],
  ['ZIP', false, B([0x50, 0x4b, 0x03, 0x04], pad(300))],
  ['تنفيذي Windows (MZ)', false, B([0x4d, 0x5a, 0x90, 0x00], pad(300))],
  ['ملف يتجاوز 10 ميجابايت', false, B('%PDF-1.4\n', pad(11 * 1024 * 1024), '%%EOF')],
  ['ملف صغير جداً', false, B('%PDF')],
  ['ملف فارغ', false, B('')],
];

let failed = 0;
for (const [name, expectOk, buf] of cases) {
  const r = inspectUpload(buf);
  const pass = r.ok === expectOk;
  if (!pass) failed++;
  console.log(`${pass ? '✓' : '✗ FAIL'}  ${name.padEnd(34)} ${r.ok ? 'قُبِل [' + r.ext + ']' : 'رُفض: ' + r.error.slice(0, 52)}`);
}

if (failed) {
  console.error(`\n❌ حارس الملفات: ${failed} حالة مخالفة للمتوقّع`);
  process.exit(1);
}
console.log(`\n✅ حارس الملفات: ${cases.length}/${cases.length} PASS`);

/* ── تأكيدات نقطة رفع وثائق تسجيل الموردين (نظام 1) ─────────────────────────
   لا تُلامس الشبكة: كل هذه الحالات تُرفض قبل أي اتصال بالتخزين. */
const { onRequestPost: regDocPost } = await import('../../functions/api/reg-doc.js');

const REQ = (qs, body, headers = {}) => new Request(`https://suppliers.aldeyabi.com/api/reg-doc${qs}`, {
  method: 'POST', body,
  headers: { origin: 'https://suppliers.aldeyabi.com', host: 'suppliers.aldeyabi.com', ...headers },
});
const ENV_OK  = { SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'k' };
const ENV_OFF = { SUPABASE_URL: 'https://x.supabase.co' };
const goodPdfBuf = Buffer.from('%PDF-1.4\n' + pad(300) + '\n%%EOF\n', 'latin1');
const evilPdfBuf = Buffer.from('%PDF-1.4\n/OpenAction<</S/JavaScript/JS(x)>>\n' + pad(300) + '\n%%EOF\n', 'latin1');

const epCases = [
  ['أصل مختلف (cross-origin) يُرفض', 403, ENV_OK, '?reg_id=DG-ABC123&doc=cr', goodPdfBuf,
    { origin: 'https://evil.example', host: 'suppliers.aldeyabi.com' }],
  ['بلا إعداد خادم ⇒ 503', 503, ENV_OFF, '?reg_id=DG-ABC123&doc=cr', goodPdfBuf, {}],
  ['رقم تسجيل غير صالح', 400, ENV_OK, '?reg_id=../../etc&doc=cr', goodPdfBuf, {}],
  ['نوع وثيقة غير صالح (اجتياز مسار)', 400, ENV_OK, '?reg_id=DG-ABC123&doc=../x', goodPdfBuf, {}],
  // SEC-06: نوع سليم الصيغة لكنه خارج القائمة البيضاء المغلقة ⇒ يُرفض (يختبر الـallowlist لا الـregex)
  ['نوع وثيقة خارج القائمة البيضاء (passport)', 400, ENV_OK, '?reg_id=DG-ABC123&doc=passport', goodPdfBuf, {}],
  ['PDF بمحتوى نشِط يُرفض', 400, ENV_OK, '?reg_id=DG-ABC123&doc=cr', evilPdfBuf, {}],
];
for (const [name, expect, env, qs, body, hdr] of epCases) {
  const res = await regDocPost({ request: REQ(qs, body, hdr), env });
  const pass = res.status === expect;
  if (!pass) failed++;
  console.log(`${pass ? '✓' : '✗ FAIL'}  ${name.padEnd(34)} HTTP ${res.status} (المتوقّع ${expect})`);
}
// ── مسار الرفع الناجح: تأكيد أنّه POST واحد لكائن عشوائي بلا list/DELETE (SEC-06: لا حذف مُتلِف) ──
{
  const calls = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, opts = {}) => {
    calls.push({ url: String(url), method: (opts.method || 'GET').toUpperCase() });
    return new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  let ok = true;
  try {
    const res = await regDocPost({ request: REQ('?reg_id=DG-ABC123&doc=cr', goodPdfBuf, {}), env: ENV_OK });
    const body = await res.json().catch(() => ({}));
    const posts = calls.filter(c => c.method === 'POST');
    const listCalls = calls.filter(c => /\/storage\/v1\/object\/list\//.test(c.url));
    const deleteCalls = calls.filter(c => c.method === 'DELETE');
    const uploadOk = res.status === 200 && body.path && posts.length === 1;
    const noDestruct = listCalls.length === 0 && deleteCalls.length === 0;
    ok = uploadOk && noDestruct;
    console.log(`${ok ? '✓' : '✗ FAIL'}  رفع ناجح = POST واحد بلا list/DELETE      status ${res.status}, posts ${posts.length}, list ${listCalls.length}, del ${deleteCalls.length}`);
  } finally {
    globalThis.fetch = realFetch;
  }
  if (!ok) failed++;
}

if (failed) { console.error('\n❌ فشل في تأكيدات نقطة الرفع'); process.exit(1); }
const epTotal = epCases.length + 1;   // +1 = تأكيد مسار الرفع الناجح
console.log(`\n✅ نقطة /api/reg-doc: ${epTotal}/${epTotal} PASS`);

/* ── تأكيدات نقطة تجديد وثائق المورّد (/api/doc-renew) ──────────────────────
   قرار المالك (2026-09-07): المستند المنتهي يُتابَع ببريد فيه رابط رفع خاصّ،
   والنسخة الجديدة **تستبدل** القديمة بتاريخها الجديد. الحرّاس المُختبَرة هنا:
   صلاحية الموظّف · توقيع الرمز · نطاق الوثائق داخل الرمز · إلزام التاريخ
   وصلاحيته · حارس الملفات · وأن الاستبدال **منطقيّ بلا أي حذف**. */
const dr = await import('../../functions/api/doc-renew.js');

const DR_ENV = {
  SUPABASE_URL: 'https://x.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'svc-key',
  SUPABASE_ANON_KEY: 'anon-key',
  RESEND_API_KEY: 're_test',
  DOC_RENEW_SECRET: 'unit-test-secret',
  PUBLIC_ORIGIN: 'https://suppliers.aldeyabi.com',
  SUPPLIER_DOCS: null,   // يُضبط في اختبار الرفع
};
const DR_ROW = {
  id: 'DG-ABC123', legal_name_ar: 'شركة الاختبار', legal_name_en: 'Test Co',
  contact_email: 'buyer@example.com', email: 'info@example.com', status: 'approved',
  cr_expiry_date: '2020-01-01', chamber_expiry: '2030-01-01',
  doc_paths: { cr: 'DG-ABC123/cr/old.pdf', vat: 'DG-ABC123/vat/v.pdf' },
};
const DR_REQ = (qs, init = {}, headers = {}) => new Request(
  `https://suppliers.aldeyabi.com/api/doc-renew${qs}`,
  { headers: { origin: 'https://suppliers.aldeyabi.com', host: 'suppliers.aldeyabi.com', ...headers }, ...init });

/* شبكة مُقلَّدة: تصادق الموظّف · تُعيد الصفّ · تقبل Resend/PATCH/التدقيق وتسجّلها */
function drNet(opts = {}) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, o = {}) => {
    const u = String(url), m = (o.method || 'GET').toUpperCase();
    calls.push({ url: u, method: m, body: o.body });
    if (u.includes('/auth/v1/user')) {
      const auth = (o.headers && (o.headers.Authorization || o.headers.authorization)) || '';
      return auth.includes('good-jwt')
        ? new Response(JSON.stringify({ email: 'staff@aldeyabi.com' }), { status: 200 })
        : new Response('{}', { status: 401 });
    }
    if (u.includes('/rest/v1/proc_supplier_registrations') && m === 'GET') {
      return new Response(JSON.stringify(opts.noRow ? [] : [opts.row || DR_ROW]), { status: 200 });
    }
    if (u.includes('api.resend.com')) {
      return new Response(JSON.stringify({ id: 'e1' }), { status: opts.mailFail ? 500 : 200 });
    }
    return new Response('{}', { status: 200 });
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}
const STAFF = { Authorization: 'Bearer good-jwt' };
let drFailed = 0, drTotal = 0;
const drT = (name, cond, extra = '') => {
  drTotal++; if (!cond) drFailed++;
  console.log(`${cond ? '✓' : '✗ FAIL'}  ${name}${extra ? '  — ' + extra : ''}`);
};

/* (أ) حرّاس إرسال الطلب */
{
  const net = drNet();
  try {
    let r = await dr.onRequestPost({ request: DR_REQ('', { method: 'POST', body: '{}' }, { origin: 'https://evil.example' }), env: DR_ENV });
    drT('أصل مختلف يُرفض عند طلب الإرسال', r.status === 403, 'HTTP ' + r.status);

    r = await dr.onRequestPost({ request: DR_REQ('', { method: 'POST', body: JSON.stringify({ reg_id: 'DG-ABC123', docs: ['cr'] }) }), env: DR_ENV });
    drT('بلا رمز جلسة موظّف ⇒ 401 (فشل مغلق)', r.status === 401, 'HTTP ' + r.status);

    r = await dr.onRequestPost({ request: DR_REQ('', { method: 'POST', body: JSON.stringify({ reg_id: '../etc', docs: ['cr'] }) }, STAFF), env: DR_ENV });
    drT('رقم تسجيل غير صالح يُرفض', r.status === 400, 'HTTP ' + r.status);

    r = await dr.onRequestPost({ request: DR_REQ('', { method: 'POST', body: JSON.stringify({ reg_id: 'DG-ABC123', docs: ['passport'] }) }, STAFF), env: DR_ENV });
    drT('نوع وثيقة خارج القائمة البيضاء يُرفض', r.status === 400, 'HTTP ' + r.status);
  } finally { net.restore(); }
}

/* (ب) المسار الناجح: بريد واحد + رابط يحمل رمزاً موقَّعاً */
let DR_TOKEN = '';
{
  const net = drNet();
  try {
    const r = await dr.onRequestPost({
      request: DR_REQ('', { method: 'POST', body: JSON.stringify({ reg_id: 'DG-ABC123', docs: ['cr', 'chamber'] }) }, STAFF),
      env: DR_ENV });
    const body = await r.json().catch(() => ({}));
    const mail = net.calls.find(c => c.url.includes('api.resend.com'));
    const payload = mail ? JSON.parse(mail.body) : {};
    const m = /renew-doc\.html\?t=([^"<\s]+)/.exec(payload.html || '');
    DR_TOKEN = m ? decodeURIComponent(m[1]) : '';
    drT('إرسال ناجح: بريد واحد إلى بريد مسؤول التواصل',
      r.status === 200 && body.ok && body.sent_to === 'buyer@example.com' && !!mail,
      'HTTP ' + r.status);
    drT('الرابط يشير لصفحة التجديد ويحمل رمزاً موقَّعاً', !!DR_TOKEN && DR_TOKEN.split('.').length === 2);
    drT('الرابط مبنيّ على PUBLIC_ORIGIN لا على ترويسة الطلب',
      (payload.html || '').includes('https://suppliers.aldeyabi.com/renew-doc.html'));
    drT('لا حذف ولا إفراغ لأي مسار عند الإرسال',
      net.calls.every(c => c.method !== 'DELETE'));
  } finally { net.restore(); }
}

/* (ج) قراءة الرمز */
{
  const net = drNet();
  try {
    let r = await dr.onRequestGet({ request: DR_REQ('?t=' + encodeURIComponent(DR_TOKEN)), env: DR_ENV });
    const body = await r.json().catch(() => ({}));
    drT('رمز صالح يفتح البيانات المطلوبة فقط',
      r.status === 200 && body.ok && body.company === 'شركة الاختبار' && body.docs.length === 2 &&
      body.docs[0].key === 'cr' && body.docs[0].has_expiry === true &&
      !('email' in body) && !('contact_email' in body));

    const tampered = DR_TOKEN.slice(0, -3) + 'AAA';
    r = await dr.onRequestGet({ request: DR_REQ('?t=' + encodeURIComponent(tampered)), env: DR_ENV });
    drT('رمز معبوث به يُرفض (توقيع HMAC)', r.status === 403, 'HTTP ' + r.status);

    r = await dr.onRequestGet({ request: DR_REQ('?t=' + encodeURIComponent(DR_TOKEN)), env: { ...DR_ENV, DOC_RENEW_SECRET: 'other-secret' } });
    drT('رمز موقَّع بمفتاح آخر يُرفض', r.status === 403, 'HTTP ' + r.status);
  } finally { net.restore(); }
}

/* (د) الرفع: الحرّاس ثم الاستبدال المنطقيّ */
{
  const puts = [];
  const bucket = { put: async (k, b, o) => { puts.push({ key: k, ct: o && o.httpMetadata && o.httpMetadata.contentType }); } };
  const ENV_R2 = { ...DR_ENV, SUPPLIER_DOCS: bucket };
  const UP = (qs, body) => DR_REQ(qs, { method: 'POST', body });
  const tk = encodeURIComponent(DR_TOKEN);
  const net = drNet();
  try {
    let r = await dr.onRequestPost({ request: UP(`?t=${tk}&doc=vat&expiry=2030-01-01`, goodPdfBuf), env: ENV_R2 });
    drT('وثيقة خارج نطاق الرمز تُرفض', r.status === 400, 'HTTP ' + r.status);

    r = await dr.onRequestPost({ request: UP(`?t=${tk}&doc=cr`, goodPdfBuf), env: ENV_R2 });
    drT('السجل التجاري بلا تاريخ انتهاء يُرفض', r.status === 400, 'HTTP ' + r.status);

    r = await dr.onRequestPost({ request: UP(`?t=${tk}&doc=cr&expiry=2020-01-01`, goodPdfBuf), env: ENV_R2 });
    drT('تاريخ انتهاء ماضٍ يُرفض', r.status === 400, 'HTTP ' + r.status);

    r = await dr.onRequestPost({ request: UP(`?t=${tk}&doc=cr&expiry=2030-01-01`, evilPdfBuf), env: ENV_R2 });
    drT('PDF بمحتوى نشِط يُرفض عند التجديد', r.status === 400, 'HTTP ' + r.status);

    const before = net.calls.length;
    r = await dr.onRequestPost({ request: UP(`?t=${tk}&doc=cr&expiry=2030-06-30`, goodPdfBuf), env: ENV_R2 });
    const body = await r.json().catch(() => ({}));
    const after = net.calls.slice(before);
    const patch = after.find(c => c.method === 'PATCH');
    const patched = patch ? JSON.parse(patch.body) : {};
    // ⚠️ يوجد الآن نداءان لسجلّ التدقيق: عدّ السقف (GET) ثمّ القيد نفسه (POST)
    const auditCall = after.find(c => c.url.includes('proc_audit_log') && c.method === 'POST');
    const audited = auditCall ? JSON.parse(auditCall.body)[0] : {};

    drT('رفع ناجح ⇒ كائن جديد في R2 بمسار المورّد',
      r.status === 200 && body.ok && puts.length === 1 && /^DG-ABC123\/cr\//.test(puts[0].key), 'HTTP ' + r.status);
    drT('المؤشّر يُستبدل بالجديد مع بقاء بقيّة الوثائق',
      patched.doc_paths && patched.doc_paths.cr === puts[0].key && patched.doc_paths.vat === 'DG-ABC123/vat/v.pdf');
    drT('تاريخ الانتهاء الجديد يُكتب في عموده الصحيح', patched.cr_expiry_date === '2030-06-30');
    drT('لا حذف للنسخة القديمة (استبدال منطقيّ لا تدميريّ)',
      after.every(c => c.method !== 'DELETE') && puts.length === 1);
    drT('مسار النسخة القديمة محفوظ في التدقيق',
      audited && audited.old_value && audited.old_value.path === 'DG-ABC123/cr/old.pdf');
  } finally { net.restore(); }
}

/* (هـ) سقف الإغراق + إشعار المراجعين + عدم كسر الحقول الأخرى */
{
  const puts = [];
  const bucket = { put: async (k) => { puts.push(k); } };
  const ENV_R2 = { ...DR_ENV, SUPPLIER_DOCS: bucket };
  const tk = encodeURIComponent(DR_TOKEN);

  // سقف 20 رفعاً/24س: نُقلّد عدّاداً بلغ الحدّ
  {
    const real = globalThis.fetch;
    globalThis.fetch = async (url) => {
      const u = String(url);
      if (u.includes('proc_audit_log') && u.includes('select=id'))
        return new Response('[]', { status: 200, headers: { 'content-range': '0-0/25' } });
      if (u.includes('/rest/v1/proc_supplier_registrations')) return new Response(JSON.stringify([DR_ROW]), { status: 200 });
      return new Response('{}', { status: 200 });
    };
    try {
      const r = await dr.onRequestPost({
        request: DR_REQ(`?t=${tk}&doc=cr&expiry=2031-01-01`, { method: 'POST', body: goodPdfBuf }), env: ENV_R2 });
      const b = await r.json().catch(() => ({}));
      drT('تجاوز سقف الرفع اليوميّ يُرفض قبل لمس التخزين',
        r.status === 429 && b.reason === 'rate_limited' && puts.length === 0, 'HTTP ' + r.status);
    } finally { globalThis.fetch = real; }
  }

  // إشعار داخليّ للمراجعين بعد رفع ناجح
  {
    const net = drNet();
    const realFetch = globalThis.fetch;
    globalThis.fetch = async (url, o = {}) => {
      const u = String(url);
      if (u.includes('proc_audit_log') && u.includes('select=id'))
        return new Response('[]', { status: 200, headers: { 'content-range': '0-0/0' } });
      if (u.includes('/rest/v1/proc_users'))
        return new Response(JSON.stringify([
          { username: 'admin', role: 'admin', active: true, permissions: {} },
          { username: 'buyer', role: 'user', active: true, permissions: { can_review_registrations: true } },
          { username: 'store', role: 'user', active: true, permissions: { can_review_registrations: false } },
        ]), { status: 200 });
      return realFetch(url, o);
    };
    try {
      const r = await dr.onRequestPost({
        request: DR_REQ(`?t=${tk}&doc=chamber&expiry=2032-02-02`, { method: 'POST', body: goodPdfBuf }), env: ENV_R2 });
      const notif = net.calls.find(c => c.url.includes('proc_notifications'));
      const rows = notif ? JSON.parse(notif.body) : [];
      drT('رفع المورّد يُشعِر المراجعين داخل النظام',
        r.status === 200 && rows.length === 2 &&
        rows.every(x => x.link === 'registrations' && /شركة الاختبار/.test(x.body)) &&
        !rows.some(x => x.recipient === 'store'), 'مستلمون: ' + rows.map(x => x.recipient).join('،'));
      const patch = net.calls.filter(c => c.method === 'PATCH').pop();
      const patched = patch ? JSON.parse(patch.body) : {};
      drT('تجديد الغرفة يكتب عمودها ولا يمسّ عمود السجل',
        patched.chamber_expiry === '2032-02-02' && !('cr_expiry_date' in patched));
    } finally { globalThis.fetch = realFetch; net.restore(); }
  }
}

/* (و) شهادة المحتوى المحلي: مقبولة، وتاريخها عمود ترقية يسقط بهدوء قبل تشغيلها */
{
  const puts = [];
  const ENV_R2 = { ...DR_ENV, SUPPLIER_DOCS: { put: async (k) => { puts.push(k); } } };
  const exp = Math.floor(Date.now()/1000) + 86400;
  // رمز يغطّي شهادة المحتوى المحلي (نوقّعه بنفس مفتاح البيئة عبر نقطة الإرسال)
  let lcToken = '';
  {
    const net = drNet();
    try {
      const r = await dr.onRequestPost({
        request: DR_REQ('', { method:'POST', body: JSON.stringify({ reg_id:'DG-ABC123', docs:['local_content'] }) }, STAFF),
        env: DR_ENV });
      const mail = net.calls.find(c => c.url.includes('api.resend.com'));
      const m = /renew-doc\.html\?t=([^"<\s]+)/.exec(mail ? JSON.parse(mail.body).html : '');
      lcToken = m ? decodeURIComponent(m[1]) : '';
      drT('شهادة المحتوى المحلي نوع صالح لطلب التجديد', r.status === 200 && !!lcToken, 'HTTP ' + r.status);
    } finally { net.restore(); }
  }
  // العمود موجود ⇒ يُكتب التاريخ
  {
    const net = drNet();
    try {
      const r = await dr.onRequestPost({
        request: DR_REQ(`?t=${encodeURIComponent(lcToken)}&doc=local_content&expiry=2031-05-05&cert_no=M207667&pct=61`,
          { method:'POST', body: goodPdfBuf }), env: ENV_R2 });
      const b = await r.json().catch(()=>({}));
      const patch = net.calls.filter(c => c.method === 'PATCH').pop();
      const patched = patch ? JSON.parse(patch.body) : {};
      drT('مع الترقية: يُكتب local_content_expiry ويُبلَّغ بالحفظ',
        r.status === 200 && patched.local_content_expiry === '2031-05-05' && b.expiry_saved === true);
    } finally { net.restore(); }
  }
  // العمود غير موجود ⇒ يُحفَظ المستند ويُتخطّى التاريخ (لا يضيع الرفع)
  {
    const calls = [];
    const real = globalThis.fetch;
    globalThis.fetch = async (url, o = {}) => {
      const u = String(url), m = (o.method || 'GET').toUpperCase();
      calls.push({ url: u, method: m, body: o.body });
      if (u.includes('proc_audit_log') && u.includes('select=id'))
        return new Response('[]', { status:200, headers:{ 'content-range':'0-0/0' } });
      if (u.includes('/rest/v1/proc_supplier_registrations') && m === 'GET')
        return new Response(JSON.stringify([DR_ROW]), { status:200 });
      if (m === 'PATCH' && String(o.body).includes('local_content_expiry'))
        return new Response('{"code":"42703","message":"column \\"local_content_expiry\\" does not exist"}', { status:400 });
      return new Response('{}', { status:200 });
    };
    try {
      const r = await dr.onRequestPost({
        request: DR_REQ(`?t=${encodeURIComponent(lcToken)}&doc=local_content&expiry=2031-05-05&cert_no=M207667&pct=61`,
          { method:'POST', body: goodPdfBuf }), env: ENV_R2 });
      const b = await r.json().catch(()=>({}));
      const patches = calls.filter(c => c.method === 'PATCH').map(c => JSON.parse(c.body));
      const last = patches[patches.length-1] || {};
      drT('بلا الترقية: المستند يُحفَظ والتاريخ يُتخطّى بهدوء (لا خسارة رفع)',
        r.status === 200 && b.ok && b.expiry_saved === false &&
        !!last.doc_paths.local_content && !('local_content_expiry' in last), 'HTTP ' + r.status);
    } finally { globalThis.fetch = real; }
  }

  /* ── حملة شهادة المحتوى المحلي (طلب المالك 2026-09-07) ────────────────────
     الشهادة بلا رقمها ونسبتها لا تُفيد التقييم، ورفعُها يُثبِت الامتلاك.
     وزرّ «لا توجد» يُنهي السؤال بدل أن يختلط الصمت بعدم الامتلاك. */
  {
    const net = drNet();
    let campToken = '';
    try {
      const r = await dr.onRequestPost({
        request: DR_REQ('', { method:'POST', body: JSON.stringify({
          reg_id:'DG-ABC123', docs:['local_content'], purpose:'local_content' }) }, STAFF),
        env: DR_ENV });
      const b = await r.json().catch(()=>({}));
      const mail = net.calls.find(c => c.url.includes('api.resend.com'));
      const body = mail ? JSON.parse(mail.body) : {};
      const m = /renew-doc\.html\?t=([^"&<\s]+)/.exec(body.html || '');
      campToken = m ? decodeURIComponent(m[1]) : '';
      drT('الحملة تستعمل قالباً مستقلّاً بنبرة دعوة لا مطالبة بمتأخّر',
        r.status===200 && b.purpose==='local_content' &&
        /شهادة المحتوى المحلي —/.test(body.subject||'') && !/منتهية منذ/.test(body.html||''),
        body.subject||'');
      drT('البريد يحمل زرَّي «لدينا شهادة» و«لا توجد لدينا شهادة»',
        /لدينا شهادة — رفعها الآن/.test(body.html||'') &&
        /لا توجد لدينا شهادة محتوى محلي/.test(body.html||'') && /&a=none/.test(body.html||''));
      drT('البريد يذكر البيانات المطلوبة الأربع',
        /رقم الشهادة/.test(body.html||'') && /نسبة المحتوى المحلي/.test(body.html||'') &&
        /تاريخ الانتهاء/.test(body.html||''));
      const aud = net.calls.filter(c => c.url.includes('proc_audit_log') && c.method==='POST').pop();
      drT('التدقيق يميّز الحملة عن التجديد (فلا تختلط في المتابعة)',
        !!aud && JSON.parse(aud.body)[0].meta.kind === 'local_content_campaign');
    } finally { net.restore(); }

    // الرفع بلا رقم الشهادة أو بنسبة خارج المدى يُرفض قبل لمس التخزين
    {
      const net = drNet();
      try {
        const noCert = await dr.onRequestPost({ request: DR_REQ(
          `?t=${encodeURIComponent(campToken)}&doc=local_content&expiry=2031-01-01&pct=61`,
          { method:'POST', body: goodPdfBuf }), env: ENV_R2 });
        const badPct = await dr.onRequestPost({ request: DR_REQ(
          `?t=${encodeURIComponent(campToken)}&doc=local_content&expiry=2031-01-01&cert_no=M1&pct=180`,
          { method:'POST', body: goodPdfBuf }), env: ENV_R2 });
        drT('رفع الشهادة بلا رقمها يُرفض', noCert.status === 400, 'HTTP ' + noCert.status);
        drT('نسبة خارج 0–100 تُرفض', badPct.status === 400, 'HTTP ' + badPct.status);
        drT('الرفض قبل لمس التخزين', net.calls.filter(c=>/r2|put/i.test(c.url)).length === 0);
      } finally { net.restore(); }
    }
    // الرفع الكامل يكتب الرقم والنسبة ويُثبِت الامتلاك
    {
      const net = drNet();
      try {
        const r = await dr.onRequestPost({ request: DR_REQ(
          `?t=${encodeURIComponent(campToken)}&doc=local_content&expiry=2031-01-01&cert_no=M307458&pct=70.09`,
          { method:'POST', body: goodPdfBuf }), env: ENV_R2 });
        const patch = net.calls.filter(c => c.method === 'PATCH').pop();
        const p = patch ? JSON.parse(patch.body) : {};
        drT('الرفع يحفظ الرقم والنسبة ويُثبِت `local_content_has`',
          r.status===200 && p.local_content_cert_no==='M307458' &&
          p.local_content_percentage==='70.09' && p.local_content_has === true, JSON.stringify(p));
      } finally { net.restore(); }
    }
    // إفادة «لا توجد شهادة»
    {
      const net = drNet();
      try {
        const r = await dr.onRequestPost({ request: DR_REQ(
          `?declare=none&t=${encodeURIComponent(campToken)}`, { method:'POST' }), env: DR_ENV });
        const b = await r.json().catch(()=>({}));
        const patch = net.calls.filter(c => c.method === 'PATCH').pop();
        const p = patch ? JSON.parse(patch.body) : {};
        drT('إفادة «لا توجد شهادة» تُثبَت في السجلّ بوقتها',
          r.status===200 && b.ok && p.local_content_has === false && !!p.local_content_none_at,
          JSON.stringify(p));
        const aud = net.calls.filter(c => c.url.includes('proc_audit_log') && c.method==='POST').pop();
        drT('الإفادة تُقيَّد في التدقيق',
          !!aud && JSON.parse(aud.body)[0].meta.kind === 'local_content_none');
      } finally { net.restore(); }
    }
    // مَن رفع الشهادة فعلاً لا يُلغيها بضغطة — الدليل أقوى من الإفادة
    {
      const net = drNet({ row: { ...DR_ROW, doc_paths: { local_content: 'p.pdf' } } });
      try {
        const r = await dr.onRequestPost({ request: DR_REQ(
          `?declare=none&t=${encodeURIComponent(campToken)}`, { method:'POST' }), env: DR_ENV });
        drT('من لديه شهادة مرفوعة لا يُلغيها بزرّ «لا توجد»', r.status === 409, 'HTTP ' + r.status);
      } finally { net.restore(); }
    }
    // رمز تجديد عاديّ (بلا local_content) لا يُستعمَل للإفادة
    {
      const net = drNet();
      try {
        const mk = await dr.onRequestPost({ request: DR_REQ('', { method:'POST',
          body: JSON.stringify({ reg_id:'DG-ABC123', docs:['cr'] }) }, STAFF), env: DR_ENV });
        const mail = net.calls.find(c => c.url.includes('api.resend.com'));
        const m = /renew-doc\.html\?t=([^"&<\s]+)/.exec(mail ? JSON.parse(mail.body).html : '');
        const crToken = m ? decodeURIComponent(m[1]) : '';
        const r = await dr.onRequestPost({ request: DR_REQ(
          `?declare=none&t=${encodeURIComponent(crToken)}`, { method:'POST' }), env: DR_ENV });
        drT('رمز لا يشمل شهادة المحتوى المحلي لا يُفيد بعدمها',
          mk.status===200 && r.status === 400, 'HTTP ' + r.status);
      } finally { net.restore(); }
    }
  }
}

/* (ز) التذكير المجدوَل: صلاحية الكرون · اختيار المستحقّين · منع التكرار بالمرحلة · الخانق */
{
  const iso = (d) => new Date(Date.now() + d*86400000).toISOString().slice(0,10);
  const REGS = [
    { id:'DG-EXPIRED', legal_name_ar:'منتهية', contact_email:'a@b.com', doc_paths:{},
      cr_expiry_date: iso(-9), chamber_expiry: iso(500) },
    { id:'DG-SOON7',   legal_name_ar:'خلال أسبوع', contact_email:'c@d.com', doc_paths:{},
      cr_expiry_date: iso(5), chamber_expiry: iso(500) },
    { id:'DG-SOON30',  legal_name_ar:'خلال شهر', contact_email:'e@f.com', doc_paths:{},
      cr_expiry_date: iso(25), chamber_expiry: iso(500) },
    { id:'DG-FAR',     legal_name_ar:'بعيدة', contact_email:'g@h.com', doc_paths:{},
      cr_expiry_date: iso(200), chamber_expiry: iso(500) },
    { id:'DG-NOMAIL',  legal_name_ar:'بلا بريد', contact_email:null, email:null, doc_paths:{},
      cr_expiry_date: iso(-3), chamber_expiry: iso(500) },
    { id:'DG-LCGAP',   legal_name_ar:'شهادة محتوى ناقصة', contact_email:'i@j.com', doc_paths:{},
      cr_expiry_date: iso(400), chamber_expiry: iso(400), local_content_has:true },
  ];
  const ENV_CRON = { ...DR_ENV, CRON_SECRET: 'cron-secret' };
  const net = (opts={}) => {
    const calls = [];
    const real = globalThis.fetch;
    globalThis.fetch = async (url, o={}) => {
      const u = String(url), m = (o.method||'GET').toUpperCase();
      calls.push({ url:u, method:m, body:o.body });
      if (u.includes('/auth/v1/user')) {
        const auth = (o.headers && (o.headers.Authorization || o.headers.authorization)) || '';
        return auth.includes('good-jwt')
          ? new Response(JSON.stringify({ email:'staff@aldeyabi.com' }), {status:200})
          : new Response('{}', {status:401});
      }
      if (u.includes('action=eq.sweep')) return new Response(JSON.stringify(opts.throttled ? [{id:1}] : []), {status:200});
      if (u.includes('action=eq.notify')) return new Response(JSON.stringify(opts.alreadySent || []), {status:200});
      if (u.includes('/rest/v1/proc_supplier_registrations')) return new Response(JSON.stringify(REGS), {status:200});
      if (u.includes('api.resend.com')) return new Response('{"id":"e"}', {status:200});
      return new Response('{}', {status:200});
    };
    return { calls, restore: () => { globalThis.fetch = real; } };
  };
  const REQ_SWEEP = (hdr={}, qs='?sweep=1') => new Request('https://suppliers.aldeyabi.com/api/doc-renew'+qs,
    { headers: { host:'suppliers.aldeyabi.com', ...hdr } });

  // صلاحية
  {
    const n = net();
    try {
      let r = await dr.onRequestGet({ request: REQ_SWEEP(), env: ENV_CRON });
      drT('التذكير المجدوَل بلا سرّ الكرون ⇒ 401', r.status === 401, 'HTTP ' + r.status);
      r = await dr.onRequestGet({ request: REQ_SWEEP({ Authorization:'Bearer wrong-secret' }), env: ENV_CRON });
      drT('سرّ خاطئ ⇒ 401 (مقارنة ثابتة الزمن)', r.status === 401, 'HTTP ' + r.status);
      r = await dr.onRequestGet({ request: REQ_SWEEP({ Authorization:'Bearer cron-secret' }), env: DR_ENV });
      drT('بلا CRON_SECRET مضبوط: السرّ نفسه لا يُصرَّح ⇒ 401 لا إرسال', r.status === 401, 'HTTP ' + r.status);
      const mails = n.calls.filter(c => c.url.includes('api.resend.com'));
      drT('لا بريد يُرسَل في أيٍّ من حالات المنع الثلاث', mails.length === 0, mails.length + ' رسالة');
    } finally { n.restore(); }
  }
  /* النبضة الكسولة: جلسة موظّف مُصادَقة same-origin تُغني عن مُشغِّل الكرون */
  {
    const SO = { host:'suppliers.aldeyabi.com', origin:'https://suppliers.aldeyabi.com' };
    const n = net();
    try {
      let r = await dr.onRequestPost({ request: new Request('https://suppliers.aldeyabi.com/api/doc-renew?sweep=1',
        { method:'POST', headers:{ ...SO, Authorization:'Bearer good-jwt' } }), env: DR_ENV });
      let b = await r.json();
      drT('نبضة موظّف مُصادَق (بلا CRON_SECRET إطلاقاً) تُشغّل الكنسة',
        r.status===200 && b.ok && b.by==='staff' && b.sent===4, 'HTTP '+r.status+' — '+JSON.stringify(b));

      r = await dr.onRequestPost({ request: new Request('https://suppliers.aldeyabi.com/api/doc-renew?sweep=1',
        { method:'POST', headers:{ ...SO, Authorization:'Bearer bad-jwt' } }), env: DR_ENV });
      drT('رمز جلسة غير صالح ⇒ 401 (فشل مغلق)', r.status === 401, 'HTTP ' + r.status);

      r = await dr.onRequestPost({ request: new Request('https://suppliers.aldeyabi.com/api/doc-renew?sweep=1',
        { method:'POST', headers:{ host:'suppliers.aldeyabi.com', Authorization:'Bearer good-jwt' } }), env: DR_ENV });
      drT('رمز صالح لكن من أصل مختلف ⇒ 401 (same-origin شرط)', r.status === 401, 'HTTP ' + r.status);
    } finally { n.restore(); }
  }
  /* الموظّف لا يتجاوز الخانق — `force=1` للكرون وحده */
  {
    const SO = { host:'suppliers.aldeyabi.com', origin:'https://suppliers.aldeyabi.com' };
    const n = net({ throttled: true });
    try {
      let r = await dr.onRequestPost({ request: new Request('https://suppliers.aldeyabi.com/api/doc-renew?sweep=1&force=1',
        { method:'POST', headers:{ ...SO, Authorization:'Bearer good-jwt' } }), env: ENV_CRON });
      let b = await r.json();
      drT('نبضة الموظّف تحترم الخانق ولو مرّرت force=1',
        b.skipped === 'throttled' && n.calls.filter(c=>c.url.includes('api.resend.com')).length===0, JSON.stringify(b));

      r = await dr.onRequestGet({ request: REQ_SWEEP({ Authorization:'Bearer cron-secret' }, '?sweep=1&force=1'), env: ENV_CRON });
      b = await r.json();
      drT('الكرون وحده يتجاوز الخانق بـforce=1', b.ok === true && b.by === 'cron' && b.sent === 4, JSON.stringify(b));
    } finally { n.restore(); }
  }
  // الاختيار الصحيح
  {
    const n = net();
    try {
      const r = await dr.onRequestGet({ request: REQ_SWEEP({ Authorization:'Bearer cron-secret' }), env: ENV_CRON });
      const b = await r.json();
      const mails = n.calls.filter(c => c.url.includes('api.resend.com')).map(c => JSON.parse(c.body).to[0]);
      drT('يرسل للمنتهي وللمقارب (7 و30) وللنقص فقط',
        r.status===200 && b.sent===4 &&
        mails.includes('a@b.com') && mails.includes('c@d.com') &&
        mails.includes('e@f.com') && mails.includes('i@j.com'), 'أُرسل: ' + mails.join('،'));
      drT('لا يُزعج البعيد ولا من بلا بريد صالح',
        !mails.includes('g@h.com') && !mails.includes(undefined) && mails.length === 4);
      const stages = n.calls.filter(c => c.url.includes('proc_audit_log') && c.method==='POST')
        .map(c => { try { return JSON.parse(c.body)[0].new_value.stage; } catch(_) { return null; } }).filter(Boolean);
      drT('كل إرسال يُقيَّد بوسم مرحلته (أساس منع التكرار)',
        stages.some(s => s.startsWith('exp')) && stages.includes('d7') && stages.includes('d30') &&
        stages.some(s => s.startsWith('gap')), stages.join('،'));
    } finally { n.restore(); }
  }
  // منع التكرار
  {
    const n = net({ alreadySent: [
      { entity_id:'DG-SOON7',  new_value:{ stage:'d7'  } },
      { entity_id:'DG-SOON30', new_value:{ stage:'d30' } },
    ]});
    try {
      const r = await dr.onRequestGet({ request: REQ_SWEEP({ Authorization:'Bearer cron-secret' }), env: ENV_CRON });
      const b = await r.json();
      const mails = n.calls.filter(c => c.url.includes('api.resend.com')).map(c => JSON.parse(c.body).to[0]);
      drT('من أُرسِل له في هذه المرحلة لا يُرسَل له ثانيةً',
        b.sent === 2 && !mails.includes('c@d.com') && !mails.includes('e@f.com'), 'أُرسل: ' + mails.join('،'));
    } finally { n.restore(); }
  }
  // الخانق
  {
    const n = net({ throttled: true });
    try {
      const r = await dr.onRequestGet({ request: REQ_SWEEP({ Authorization:'Bearer cron-secret' }), env: ENV_CRON });
      const b = await r.json();
      const mails = n.calls.filter(c => c.url.includes('api.resend.com'));
      drT('تشغيلة خلال 20 ساعة ⇒ تخطٍّ بلا أي بريد',
        r.status===200 && b.skipped==='throttled' && mails.length===0);
    } finally { n.restore(); }
  }
}

if (drFailed) { console.error(`\n❌ نقطة /api/doc-renew: ${drFailed} فشل`); process.exit(1); }
console.log(`\n✅ نقطة /api/doc-renew: ${drTotal}/${drTotal} PASS`);

/* ── تأكيدات نقطة دعوة الموظّف الشخصية (/api/staff-invite) ──────────────────
   قرار المالك (2026-09-13): المدير يُدخل الاسم والبريد والإدارة وملف الصلاحيات والمسمّى، ويصل
   الموظّف **بريد دعوة** يضبط منه كلمة مروره ويدخل مباشرةً. الرابط المشترك حُذِف.

   ⚠️ المبدأ الحاكم المُختبَر هنا: **الرمز صار الاعتماد**، فالهويّة كلّها من
   داخله — البريد والإدارة وملف الصلاحيات والاسم والمسمّى. لو قرأ الخادم أيّاً منها من جسم
   الطلب لاستطاع حاملُ الرابط انتحال بريد غيره أو منح نفسه إدارة أو ملف صلاحيات آخر. */
const si = await import('../../functions/api/staff-invite.js');

const SI_ENV = {
  SUPABASE_URL: 'https://x.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'svc-key',
  SUPABASE_ANON_KEY: 'anon-key',
  RESEND_API_KEY: 're_test',
  STAFF_INVITE_SECRET: 'invite-unit-secret',
  PUBLIC_ORIGIN: 'https://suppliers.aldeyabi.com',
};
const SI_REQ = (qs, init = {}, headers = {}) => new Request(
  `https://suppliers.aldeyabi.com/api/staff-invite${qs}`,
  { headers: { origin: 'https://suppliers.aldeyabi.com', host: 'suppliers.aldeyabi.com',
               'Content-Type': 'application/json', ...headers }, ...init });

/* شبكة مُقلَّدة: تصادق الأدمن · تُعيد صفوف proc_users/settings · تلتقط الكتابات */
const ROWS_ALL = {
  abdullah: [
    { username:'abdullah', role:'user',  active:false, email:'abdullah@aldeyabi.com', display_name:'عبدالله' },
    { username:'Abdullah', role:'admin', active:true,  email:'abdullah@aldeyabi.com', display_name:'عبدالله' },
  ],
  mostafa:  [{ username:'Mostafa', role:'admin', active:true, email:null, display_name:'مصطفى' }],
  mahmoud:  [{ username:'Mahmoud', role:'user',  active:true, email:null, display_name:'محمود' }],
};
/* ⚠️ `saleh` **غير موجود عمداً** — هو المدعوّ في المسار السعيد. أي صفّ باسمه هنا
   يجعل فحص «بريد له حساب» يُرجِع 409 فيسقط كل ما بعده. */
function siNet(opts = {}) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, o = {}) => {
    const u = String(url), m = (o.method || 'GET').toUpperCase();
    calls.push({ url: u, method: m, body: o.body, headers: o.headers });
    if (u.includes('/auth/v1/user')) {
      const a = (o.headers && (o.headers.Authorization || o.headers.authorization)) || '';
      if (a.includes('admin-jwt')) return new Response(JSON.stringify({ email: 'abdullah@aldeyabi.com' }), { status: 200 });
      /* موظّف **قائم فعلاً** (نشط، غير أدمن) — أقوى من هويّة مجهولة: يُثبِت أنّ
         الرفض جاء من فحص الرتبة لا من تعذّر العثور على الصفّ. */
      if (a.includes('user-jwt'))  return new Response(JSON.stringify({ email: 'mahmoud@aldeyabi.com' }), { status: 200 });
      return new Response('{}', { status: 401 });
    }
    if (u.includes('/rest/v1/proc_settings') && m === 'GET') {
      return new Response(JSON.stringify([{ value: { epoch: opts.epoch || 0 } }]), { status: 200 });
    }
    if (u.includes('/rest/v1/proc_departments') && m === 'GET') {
      return new Response(JSON.stringify([{ id:'DEP-MAINT', name_ar:'إدارة الصيانة والتشغيل', sector:'الصيانة والتشغيل' }]), { status: 200 });
    }
    if (u.includes('/rest/v1/proc_users') && m === 'GET') {
      if (u.includes('or=(')) {
        if (opts.existingFail) return new Response('{}', { status: 500 });
        if (opts.existing) return new Response(JSON.stringify(opts.existing), { status: 200 });
        /* نُحاكي `or=(username.ilike.X,email.eq.Y)` كما تفعل القاعدة: مطابقة
           الاسم **غير حسّاسة لحالة الأحرف**، ومطابقة البريد تامّة. */
        const dec = decodeURIComponent(u);
        const un = (/username\.i?like\.([^,)]*)/.exec(dec) || [, ''])[1].replace(/\\(.)/g, '$1').toLowerCase();
        const em = (/email\.eq\.([^,)]*)/.exec(dec) || [, ''])[1].toLowerCase();
        const all = Object.values(ROWS_ALL).flat();
        const hit = all.filter((x) => String(x.username).toLowerCase() === un
                                   || (x.email && String(x.email).toLowerCase() === em));
        return new Response(JSON.stringify(hit), { status: 200 });
      }
      if (u.includes('role=eq.admin')) return new Response(JSON.stringify([{ username:'admin', email:'abdullah@aldeyabi.com' }]), { status: 200 });
      /* ⚠️ **مطابق لصفوف الإنتاج حرفيّاً** (مُتحقَّق على yofcaxvstjcrmbgciwym):
         صفّان يختلفان بحالة الأحرف فقط — `abdullah` مستخدم **موقوف** و`Abdullah`
         أدمن نشط — والموقوف **أوّلاً** عمداً. الكعب السابق كان يتخيّل صفّاً واحداً
         (`abdullah` أدمن نشط) فمرّ عيب `eq.` الذي يرفض المالك نفسه بـ403.
         ⚠️ والمطابقة هنا **غير حسّاسة لحالة الأحرف** كدلالة `ilike` في القاعدة:
         كعبٌ يطابق النصّ الصغير وحده يُخفق على استعلام `ilike.Abdullah` الحقيقيّ
         (وهو ما يقع فعلاً حين يُشتقّ الاسم من صفّ الأدمن `Abdullah`). */
      const mName = /username=i?like\.([^&]*)/.exec(u) || /username=eq\.([^&]*)/.exec(u);
      const want = mName ? decodeURIComponent(mName[1]).replace(/\\(.)/g, '$1').toLowerCase() : '';
      /* ⚠️ صفوف الإنتاج الحقيقية (مقيسة على yofcaxvstjcrmbgciwym 2026-09-13):
         `Mostafa` و`Mahmoud` بحرف كبير و**بلا بريد** — وهما ما جعل `eq.` تُخفق
         وتسمح بدعوة بريدٍ له حساب. و`supply@aldeyabi.com` اسمه `mostafa` عبر
         AUTH_EMAIL_MAP لا `supply`. */
      const ROWS = ROWS_ALL;
      let rows = ROWS[want] || [];
      if (u.includes('active=eq.true')) rows = rows.filter((x) => x.active !== false);
      return new Response(JSON.stringify(rows), { status: 200 });
    }
    if (u.includes('/auth/v1/admin/users') && m === 'POST') {
      /* ردّ GoTrue الحقيقيّ حين يكون البريد مسجَّلاً في Auth أصلاً. */
      if (opts.authAlready) return new Response(
        JSON.stringify({ code: 422, msg: 'A user with this email address has already been registered' }), { status: 422 });
      return new Response(JSON.stringify({ id: 'auth-uid-1' }), { status: opts.authFail ? 500 : 200 });
    }
    if (u.includes('/rest/v1/proc_users') && m === 'POST') {
      return new Response('', { status: opts.profileFail ? 400 : 201 });
    }
    if (u.includes('api.resend.com')) {
      return new Response(opts.mailFail ? 'blocked' : JSON.stringify({ id: 'e1' }), { status: opts.mailFail ? 422 : 200 });
    }
    return new Response('{}', { status: 200 });
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}
const ADMIN = { Authorization: 'Bearer admin-jwt' };
let siFailed = 0, siTotal = 0;
const siT = (name, cond, extra = '') => {
  siTotal++; if (!cond) siFailed++;
  console.log(`${cond ? '✓' : '✗ FAIL'}  ${name}${extra ? '  — ' + extra : ''}`);
};
const INVITE = { action:'invite', display_name:'صالح الصيانة', email:'saleh@aldeyabi.com',
                 department_id:'DEP-MAINT', profile_key:'requester', job_title:'فنّي صيانة' };
const invite = async (env = SI_ENV, headers = ADMIN, body = INVITE) => {
  const r = await si.onRequestPost({ request: SI_REQ('', { method:'POST', body: JSON.stringify(body) }, headers), env });
  return { status: r.status, j: await r.json() };
};
const tokenOf = (u) => new URL(u).searchParams.get('t');

/* (أ) إصدار الدعوة: أدمن فقط، ومن نفس الأصل، وبتحقّق المدخلات */
{
  const n = siNet();
  try {
    let r = await si.onRequestPost({ request: SI_REQ('', { method:'POST', body:'{}' }, { origin:'https://evil.example' }), env: SI_ENV });
    siT('إصدار الدعوة يُرفض من أصل مختلف', r.status === 403);

    r = await si.onRequestPost({ request: SI_REQ('', { method:'POST', body: JSON.stringify(INVITE) }), env: SI_ENV });
    siT('وبلا رمز جلسة يُرفض', r.status === 403);

    const asUser = await invite(SI_ENV, { Authorization: 'Bearer user-jwt' });
    siT('وموظّف عاديّ لا يدعو أحداً', asUser.status === 403);

    siT('وبريد خارج نطاق الشركة يُرفض (وإلّا لم يصله شيء أصلاً)',
      (await invite(SI_ENV, ADMIN, { ...INVITE, email:'saleh@gmail.com' })).status === 400);
    siT('واسم ناقص يُرفض', (await invite(SI_ENV, ADMIN, { ...INVITE, display_name:'ا' })).status === 400);
    siT('وإدارة فارغة تُرفض', (await invite(SI_ENV, ADMIN, { ...INVITE, department_id:'' })).status === 400);

    const ok = await invite();
    siT('والأدمن يُصدرها برابط الصفحة العامّة',
      ok.status === 200 && ok.j.ok && ok.j.url.includes('/staff-register.html?t='),
      ok.status !== 200 ? `status=${ok.status} ${JSON.stringify(ok.j)}` : '');
    /* ⚠️ العيب الحقيقيّ الذي أوقف المالك سابقاً: صفّان يختلفان بحالة الأحرف،
       والموقوف أوّلاً. فمطابقة `eq.` أو أخذ «أوّل صفّ» تُرجِعان الصفّ الخاطئ. */
    siT('ولا يوقفه صفٌّ موقوف يطابق اسمه بحالة أحرف مختلفة',
      n.calls.some(c => c.url.includes('username=ilike.')) &&
      !n.calls.some(c => c.url.includes('proc_users?username=eq.')));
  } finally { n.restore(); }
}

/* (ب) بريد الدعوة: يُرسَل للمدعوّ وحده، وفيه الرابط، وبلا كلمة مرور */
{
  const n = siNet();
  try {
    const ok = await invite();
    const mail = n.calls.find(c => c.url.includes('api.resend.com'));
    const body = mail ? JSON.parse(mail.body) : null;
    siT('الدعوة تُرسَل عبر Resend', !!mail && ok.j.sent === true);
    siT('وإلى المدعوّ وحده لا إلى غيره',
      !!body && JSON.stringify(body.to) === JSON.stringify(['saleh@aldeyabi.com']));
    siT('والرسالة تحمل رابط الدعوة نفسه',
      !!body && body.html.includes(ok.j.url.replace(/&/g, '&amp;')));
    siT('وتذكر اسم المدعوّ وقطاعه ومسمّاه',
      !!body && body.html.includes('صالح الصيانة') && body.html.includes('الصيانة والتشغيل')
      && body.html.includes('فنّي صيانة'));
    /* ⚠️ الحارس الجوهريّ: لا كلمة مرور في البريد إطلاقاً — الرابط دعوة لا اعتماد. */
    siT('ولا تحمل كلمة مرور إطلاقاً',
      !!body && !/كلمة المرور\s*[:：]/.test(body.html) && !/password["'\s:=]/i.test(body.html));
    siT('وموضوعها واضح', !!body && /دعوة للانضمام/.test(body.subject));
  } finally { n.restore(); }
}

/* (ج) دعوة لبريد له حساب: تُرفض **عند الإصدار** لا بعد أن يضغط الموظّف */
{
  const n = siNet({ existing: [{ username:'saleh', active:true }] });
  try {
    const r = await invite();
    siT('ودعوة بريدٍ له حساب تُرفض فوراً لا بعد ضغط الموظّف الرابط',
      r.status === 409 && !n.calls.some(c => c.url.includes('api.resend.com')));
  } finally { n.restore(); }
}

/* (د) فشل الإرسال: الرابط يعود للمدير فلا يبقى الموظّف بلا طريق */
{
  const n = siNet({ mailFail: true });
  try {
    const r = await invite();
    siT('وفشل البريد لا يُسقِط الدعوة — الرابط يعود للمدير لينسخه',
      r.status === 200 && r.j.ok && r.j.sent === false && !!r.j.url && !!r.j.send_error);
  } finally { n.restore(); }
}

/* (هـ) الرمز: التوقيع والانتهاء والإبطال، ومحتواه */
{
  const n = siNet();
  let url = '';
  try { url = (await invite()).j.url; } finally { n.restore(); }
  const tk = tokenOf(url);

  {
    const n2 = siNet();
    try {
      let r = await si.onRequestGet({ request: SI_REQ(`?t=${encodeURIComponent(tk)}`), env: SI_ENV });
      const b = await r.json();
      siT('الرمز الصحيح يكشف بيانات المدعوّ لتعبئة الصفحة',
        r.status === 200 && b.email === 'saleh@aldeyabi.com' && b.display_name === 'صالح الصيانة'
        && b.department_id === 'DEP-MAINT' && b.profile_key === 'requester'
        && b.sector === 'الصيانة والتشغيل' && b.job_title === 'فنّي صيانة');
      siT('ولا يكشف من دعاه ولا أي مستخدم آخر', !('by' in b) && !('users' in b));

      r = await si.onRequestGet({ request: SI_REQ(`?t=${encodeURIComponent(tk)}x`), env: SI_ENV });
      siT('ورمز معبوث يُرفض', r.status === 401);

      r = await si.onRequestGet({ request: SI_REQ(`?t=${encodeURIComponent(tk)}`), env: { ...SI_ENV, STAFF_INVITE_SECRET:'other' } });
      siT('ورمز بمفتاح آخر يُرفض', r.status === 401);
    } finally { n2.restore(); }
  }
  {
    const n3 = siNet({ epoch: Date.now() + 60000 });
    try {
      const r = await si.onRequestGet({ request: SI_REQ(`?t=${encodeURIComponent(tk)}`), env: SI_ENV });
      siT('وإبطال المالك يُسقِط كل الدعوات الصادرة قبله', r.status === 401);
    } finally { n3.restore(); }
  }
}

/* (و) الإتمام: الهويّة من الرمز حصراً، والحساب نشط */
{
  const n0 = siNet();
  let tk = '';
  try { tk = tokenOf((await invite()).j.url); } finally { n0.restore(); }
  const DONE = (body, t = tk) => SI_REQ(`?t=${encodeURIComponent(t)}`, { method:'POST', body: JSON.stringify(body) });

  {
    const n = siNet();
    try {
      let r = await si.onRequestPost({ request: DONE({ password:'123' }), env: SI_ENV });
      siT('كلمة مرور قصيرة تُرفض', r.status === 400);
      r = await si.onRequestPost({ request: DONE({ password:'Passw0rd!' }, tk + 'x'), env: SI_ENV });
      siT('ورمز غير صالح يُرفض قبل أي كتابة', r.status === 401);
    } finally { n.restore(); }
  }

  /* ⚠️ جوهر الأمان بعد التحوّل: العميل يُرسل بريداً وقطاعاً ودوراً مخالفة —
     ويجب أن **يُتجاهَل كلّه** لصالح ما في الرمز. */
  {
    const n = siNet();
    try {
      const r = await si.onRequestPost({ request: DONE({
        password:'Passw0rd!', mobile:'0500000000',
        email: 'attacker@aldeyabi.com', display_name: 'منتحِل',
        sector: 'الإدارة العامة', job_title: 'مدير عام',
        role: 'admin', active: true,
        scope_sectors: ['الإنشاءات','الإدارة العامة'],
        permissions: { can_view_amounts: true, can_manage_users: true },
      }), env: SI_ENV });
      const b = await r.json();
      const wrote = n.calls.find(c => c.url.includes('/rest/v1/proc_users') && c.method === 'POST');
      const row = JSON.parse(wrote.body);
      const auth = JSON.parse(n.calls.find(c => c.url.includes('/auth/v1/admin/users') && c.method === 'POST').body);
      siT('الإتمام ينجح ويُبلِغ أنّ الحساب نشط', r.status === 200 && b.ok && b.active === true);
      siT('والحساب يُنشأ **نشطاً** (قرار المالك: المراجعة تمّت عند الدعوة)', row.active === true);
      siT('والبريد من **الرمز** لا من العميل (لا انتحال بريد غيره)',
        row.email === 'saleh@aldeyabi.com' && auth.email === 'saleh@aldeyabi.com');
      siT('والاسم والمسمّى من الرمز',
        row.display_name === 'صالح الصيانة' && row.job_title === 'فنّي صيانة');
      siT('والدعوة المكتبية لا تنشئ نطاقاً ميدانياً ولا تقبل نطاق العميل',
        JSON.stringify(row.scope_sectors) === JSON.stringify([]));
      siT('والدور مفروض user مهما أرسل العميل', row.role === 'user');
      siT('وملف الصلاحيات والإدارة من الرمز بلا صلاحيات خام من العميل',
        row.pr_profile_key === 'requester' && row.department_id === 'DEP-MAINT'
        && JSON.stringify(row.pr_department_ids) === JSON.stringify(['DEP-MAINT'])
        && JSON.stringify(row.permissions) === '{}');
      siT('والجوال وحده يُقبل من العميل', row.mobile === '0500000000');
      const mail = n.calls.find(c => c.url.includes('api.resend.com'));
      siT('ويصل الداعي إشعار بالإتمام لا «بانتظار التفعيل»',
        !!mail && JSON.parse(mail.body).to.includes('abdullah@aldeyabi.com')
        && /فعّل حسابه/.test(JSON.parse(mail.body).subject));
    } finally { n.restore(); }
  }

  /* أحاديّة الاستعمال بلا جدول رموز: بعد الإتمام يوجد صفّ، فإعادة الضغط تسقط. */
  {
    const n = siNet({ existing: [{ username:'saleh', active:true }] });
    try {
      const r = await si.onRequestPost({ request: DONE({ password:'Passw0rd!' }), env: SI_ENV });
      const b = await r.json();
      const wrote = n.calls.filter(c => c.url.includes('/rest/v1/proc_users') && c.method === 'POST');
      siT('وإعادة استعمال الرابط بعد الإتمام لا تُنشئ صفّاً ثانياً',
        r.status === 200 && b.already === true && wrote.length === 0);
    } finally { n.restore(); }
  }

  /* ⚠️ فشل قراءة الحسابات القائمة يجب أن **يمنع** لا أن يمرّ: تمريره يفتح
     الباب لصفّ مكرَّر بحساب دخول ثانٍ لنفس البريد. */
  {
    const n = siNet({ existingFail: true });
    try {
      const r = await si.onRequestPost({ request: DONE({ password:'Passw0rd!' }), env: SI_ENV });
      const wrote = n.calls.filter(c => c.url.includes('/rest/v1/proc_users') && c.method === 'POST');
      siT('وتعذّر فحص الحسابات القائمة يفشل مغلقاً (لا صفّ مكرَّر)',
        r.status === 502 && wrote.length === 0);
    } finally { n.restore(); }
  }

  // فشل حفظ الملف ⇒ لا حساب دخول يتيم يمنع إعادة المحاولة
  {
    const n = siNet({ profileFail: true });
    try {
      const r = await si.onRequestPost({ request: DONE({ password:'Passw0rd!' }), env: SI_ENV });
      const del = n.calls.find(c => c.url.includes('/auth/v1/admin/users/') && c.method === 'DELETE');
      siT('وفشل حفظ الملف يحذف حساب الدخول (لا حساب يتيم)', r.status === 400 && !!del);
    } finally { n.restore(); }
  }

  /* ⚠️ الحساب موجود في **Auth** لا في `proc_users` (مثلاً حُذِف ملفه وبقي دخوله):
     كان يُقرَأ نجاحاً فيُكتَب ملفٌ ثانٍ بلا حساب دخول يملكه. الآن 409 بلا كتابة. */
  {
    const n = siNet({ authAlready: true });
    try {
      const r = await si.onRequestPost({ request: DONE({ password:'Passw0rd!' }), env: SI_ENV });
      const wrote = n.calls.filter(c => c.url.includes('/rest/v1/proc_users') && c.method === 'POST');
      siT('وحسابُ دخولٍ قائم في Auth يُرفض 409 ولا يُكتَب ملفٌ ثانٍ',
        r.status === 409 && wrote.length === 0);
    } finally { n.restore(); }
  }
}

/* ══ (ز) اسم الدخول: مشتقّ بنفس قاعدة النظام، والمطابقة غير حسّاسة للحالة ══
   عيبان أبلغ عنهما Codex على PR #100 وأُكِّدا بالقياس على صفوف الإنتاج:
   (١) اسم الدخول كان يُشتقّ محليّاً (`split('@')[0]` بحذف كل ما ليس a-z0-9_)
       بدل `emailToUsername` — فـ`supply@aldeyabi.com` (اسمه `mostafa` عبر
       AUTH_EMAIL_MAP) كان يُقرَأ `supply` فلا يطابق شيئاً ⇒ **دعوة تُنشئ ملفاً
       ثانياً ببريد مصطفى**، و`proc_me()` يطابق البريد أوّلاً ⇒ **الأدمن ينقلب
       موظّف ميدان مُنطَّقاً**. و`ali.salem@` كان يصير `alisalem` فلا يطابق ملفّه.
   (٢) المطابقة كانت `eq.` حسّاسة للحالة — و`Mahmoud`/`Mostafa` بحرف كبير. */
{
  const n = siNet();
  try {
    const r = await invite(SI_ENV, ADMIN, { ...INVITE, email:'supply@aldeyabi.com' });
    siT('دعوة بريد مصطفى (supply@) تُرفض — لا ملفّ ثانٍ ينقلب به الأدمن موظّفاً',
      r.status === 409 && !n.calls.some(c => c.url.includes('api.resend.com')),
      r.status !== 409 ? `status=${r.status} ${JSON.stringify(r.j)}` : '');
  } finally { n.restore(); }
}
{
  const n = siNet();
  try {
    const r = await invite(SI_ENV, ADMIN, { ...INVITE, email:'mahmoud@aldeyabi.com' });
    siT('ودعوة صفٍّ اسمه بحرف كبير (Mahmoud) تُرفض رغم اختلاف الحالة',
      r.status === 409, r.status !== 409 ? `status=${r.status}` : '');
  } finally { n.restore(); }
}
{
  const n = siNet();
  try {
    const r = await invite(SI_ENV, ADMIN, { ...INVITE, email:'ali.salem@aldeyabi.com' });
    const mail = n.calls.find(c => c.url.includes('api.resend.com'));
    const html = mail ? JSON.parse(mail.body).html : '';
    siT('وبريدٌ بنقطة يبقى اسم دخوله كما يشتقّه النظام (ali.salem لا alisalem)',
      r.status === 200 && html.includes('ali.salem') && !html.includes('alisalem'),
      r.status !== 200 ? `status=${r.status} ${JSON.stringify(r.j)}` : '');
    siT('والبريد يُعلِم المدعوّ باسم دخوله صراحةً', /اسم الدخول/.test(html));
  } finally { n.restore(); }
}

if (siFailed) { console.error(`\n❌ نقطة /api/staff-invite: ${siFailed} فشل`); process.exit(1); }
console.log(`\n✅ نقطة /api/staff-invite: ${siTotal}/${siTotal} PASS`);

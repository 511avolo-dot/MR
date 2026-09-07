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
      return new Response(JSON.stringify(opts.noRow ? [] : [DR_ROW]), { status: 200 });
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

if (drFailed) { console.error(`\n❌ نقطة /api/doc-renew: ${drFailed} فشل`); process.exit(1); }
console.log(`\n✅ نقطة /api/doc-renew: ${drTotal}/${drTotal} PASS`);

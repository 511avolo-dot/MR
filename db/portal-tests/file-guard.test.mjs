/**
 * تأكيدات حارس الملفات المرفوعة (functions/api/_file-guard.js)
 * ════════════════════════════════════════════════════════════════════════════
 * يحمي مسار رفع المورّد الخارجي (/api/portal-supplier-doc) ومسارَي الموظّفين
 * (/api/portal-quote و/api/portal-doc). أي تراجع في الحارس يُفشِل الـCI.
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

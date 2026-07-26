/**
 * حارس الملفات المرفوعة (البوابة، نظام 3) — دفاع طبقيّ ضد الملفات الخبيثة/الملغومة
 * ════════════════════════════════════════════════════════════════════════════
 * المسار الأخطر: /api/portal-supplier-doc — يرفع فيه **طرف خارجي بلا حساب** ملفاً.
 * لا يوجد محرّك مضاد فيروسات داخل Worker، فالاستراتيجية = **تضييق ما يُقبَل**
 * إلى ثلاثة أنواع خاملة، ثم التحقّق من بنيتها، ثم تحييد ما يُقدَّم للمتصفّح:
 *
 *  الطبقة 1 — قائمة بيضاء بالتوقيع السحري لا بترويسة Content-Type (يسهل تزويرها):
 *             PDF · JPEG · PNG فقط. أي شيء آخر (zip/exe/svg/html/office) يُرفض.
 *  الطبقة 2 — كشف المتعدّد الصيغ (polyglot): ملف يجتاز توقيع صورة لكنه يحمل
 *             HTML/PHP/سكربت في جسمه (GIFAR/JPEG-PHP) — يُرفض.
 *  الطبقة 3 — سلامة بنيوية: PDF بترويسة + %%EOF · JPEG ينتهي بـFFD9 ·
 *             PNG بـIHDR/IEND. الملف المبتور/المُلفَّق يُرفض.
 *  الطبقة 4 — رفض المحتوى النشِط داخل PDF: /JavaScript /OpenAction /Launch
 *             /EmbeddedFile /RichMedia /XFA /SubmitForm /ImportData /GoToR — وهي
 *             ناقلات التنفيذ التلقائي والتصيّد. يُفحَص بعد **فكّ ترميز #xx**
 *             لأنّ صيغة PDF تسمح بإخفاء الأسماء هكذا (/J#61vaScript).
 *  الطبقة 5 — (في نقطة العرض) لا تُبَثّ الملفات إلا بترويسات تحييد:
 *             nosniff + CSP sandbox + no-store. راجع securityHeaders أدناه.
 *
 * ملاحظات مقصودة:
 *  • اسم الملف من المستخدم **لا يُستعمل إطلاقاً** — المفتاح عشوائي من الخادم
 *    وامتداده مشتقّ من التوقيع، فلا اجتياز مسار ولا امتداد مزدوج (x.pdf.html).
 *  • R2 تخزين كائنات لا يُنفّذ شيئاً؛ والوصول للقراءة عبر دالة محروسة فقط.
 *  • رفض المحتوى النشِط قد يرفض PDF نماذج (XFA) نادراً — الرسالة تُرشد المورّد
 *    لإعادة التصدير كـPDF عادي أو إرسال صورة، وهو تنازل مقبول أمام المخاطرة.
 */

export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024; // 10 MB
export const MIN_UPLOAD_BYTES = 64;               // أقل من ذلك ليس مستنداً

const SIG = [
  { ext: 'pdf', ct: 'application/pdf', b: [0x25, 0x50, 0x44, 0x46] },            // %PDF
  { ext: 'jpg', ct: 'image/jpeg',      b: [0xff, 0xd8, 0xff] },                  // JPEG
  { ext: 'png', ct: 'image/png',       b: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] },
];

// علامات محتوى نصّي تنفيذي — لا مكان لها في PDF/صورة سليمة.
// ⚠️ كل علامة ≥ 5 محارف عمداً: الفحص يمرّ على بايتات مضغوطة أيضاً، والعلامات
//   القصيرة (مثل "<%") تتصادف عشوائياً في 10 ميجابايت فتُنتج رفضاً كاذباً.
const POLYGLOT = ['<!doctype html', '<html', '<script', '<?php', '<svg ', '<svg>', '<iframe',
                  'javascript:', 'onerror=', '#!/bin/', '#!/usr/bin/'];

// ناقلات التنفيذ/الإجراء التلقائي داخل PDF (لنفس السبب: أسماء طويلة مميّزة فقط —
// /JS و/AA القصيران مُغطّيان ضمناً لأنّ أي إجراء نشِط يحمل نوعه الصريح: /JavaScript
// أو /Launch أو /GoToR أو /SubmitForm).
const PDF_ACTIVE = ['/javascript', '/openaction', '/launch', '/embeddedfile',
                    '/richmedia', '/xfa', '/submitform', '/importdata', '/gotor'];

const DEC = new TextDecoder('latin1');
function latin1(buf, from, to) { return DEC.decode(new Uint8Array(buf.slice(from, to))); }
function startsWith(u8, bytes) {
  for (let i = 0; i < bytes.length; i++) if (u8[i] !== bytes[i]) return false;
  return true;
}
const esc = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// تعبيران مُجمَّعان بدل عشرات تمريرات indexOf — تمريرة واحدة غير حسّاسة لحالة الأحرف
// (قياس على PDF بحجم 5.7MB: ~11ms بدل ~100ms، وبلا نسخة مُصغَّرة الحروف في الذاكرة).
const POLYGLOT_RE = new RegExp(POLYGLOT.map(esc).join('|'), 'i');
const PDF_ACTIVE_RE = new RegExp(PDF_ACTIVE.map(esc).join('|'), 'i');
// أسماء PDF قد تُخفى بترميز #xx (/J#61vaScript) — نلتقط الرموز المشبوهة ونفكّها وحدها
// بدل فكّ الملف كلّه (توفير ذاكرة ووقت؛ الرموز المرمَّزة نادرة أصلاً).
const HASHED_NAME_RE = /\/(?:[A-Za-z0-9]|#[0-9A-Fa-f]{2})*#[0-9A-Fa-f]{2}(?:[A-Za-z0-9]|#[0-9A-Fa-f]{2})*/g;
const decodeHashName = (n) => n.replace(/#([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));

/**
 * يفحص المخزن المؤقّت ويعيد { ok:true, ext, ct } أو { ok:false, error } برسالة عربية.
 * لا يعتمد إطلاقاً على اسم الملف أو ترويسة Content-Type القادمة من العميل.
 */
export function inspectUpload(buf) {
  if (!buf || buf.byteLength === 0) return { ok: false, error: 'ملف فارغ' };
  if (buf.byteLength < MIN_UPLOAD_BYTES) return { ok: false, error: 'الملف صغير جداً — تأكّد أنّه مستند صالح' };
  if (buf.byteLength > MAX_UPLOAD_BYTES) return { ok: false, error: 'حجم الملف يتجاوز 10 ميجابايت' };

  const head = new Uint8Array(buf.slice(0, 16));
  const sig = SIG.find((s) => startsWith(head, s.b));
  if (!sig) return { ok: false, error: 'نوع الملف غير مقبول — يُقبل PDF أو صورة (JPG/PNG) فقط' };

  // نطاق الفحص النصّي: الملف كلّه لـPDF (الأوامر والأسماء منثورة فيه)، وأول 64KB
  // فقط للصور — هناك تعيش مقاطع EXIF/COM التي تُدسّ فيها الحمولات، أمّا الإلحاق في
  // الذيل فيمسكه الفحص البنيوي، وبقيّة الجسم بيانات بكسل مضغوطة لا تُنفَّذ.
  // (يوفّر فكّ ترميز عدّة ميجابايت لكل صورة — الصور هي الحالة الشائعة من الجوّال.)
  const SCAN = sig.ext === 'pdf' ? buf.byteLength : Math.min(buf.byteLength, 65536);
  const text = latin1(buf, 0, SCAN);

  // الطبقة 2 — متعدّد الصيغ: توقيع سليم + حمولة نصّية تنفيذية
  if (POLYGLOT_RE.test(text)) {
    return { ok: false, error: 'الملف يحتوي محتوى برمجياً مضمّناً — يُرفض لأسباب أمنية' };
  }

  if (sig.ext === 'pdf') {
    // الطبقة 3 — بنية: ترويسة إصدار + علامة نهاية
    if (!/^%PDF-\d\.\d/i.test(text.slice(0, 16))) return { ok: false, error: 'ترويسة PDF غير صالحة' };
    const eofAt = text.lastIndexOf('%%EOF');
    if (eofAt === -1 || eofAt < buf.byteLength - 4096) {
      return { ok: false, error: 'ملف PDF غير مكتمل (لا علامة نهاية) — أعِد تصديره وحاول مجدداً' };
    }
    // الطبقة 4 — محتوى نشِط، صريحاً أو مُخفّى بترميز #xx
    const ACTIVE_MSG = 'الملف يحتوي محتوى نشِطاً (سكربت أو إجراء تلقائي أو مرفق مضمّن) — '
                     + 'أعِد تصديره كـPDF عادي (طباعة إلى PDF) أو أرسل صورة واضحة منه';
    if (PDF_ACTIVE_RE.test(text)) return { ok: false, error: ACTIVE_MSG };
    if (text.indexOf('#') !== -1) {
      HASHED_NAME_RE.lastIndex = 0;
      let m, guard = 0;
      while ((m = HASHED_NAME_RE.exec(text)) !== null && guard++ < 5000) {
        if (PDF_ACTIVE_RE.test(decodeHashName(m[0]))) return { ok: false, error: ACTIVE_MSG };
      }
    }
  } else {
    // الطبقة 3 للصور — الذيل: لا بيانات ملحقة بعد علامة النهاية
    const tail = latin1(buf, Math.max(0, buf.byteLength - 4096), buf.byteLength);
    if (sig.ext === 'jpg') {
      const end = tail.lastIndexOf('\u00ff\u00d9');            // FFD9
      if (end === -1) return { ok: false, error: 'صورة JPEG غير مكتملة أو معدَّلة' };
      if (tail.length - (end + 2) > 64) return { ok: false, error: 'الصورة تحمل بيانات ملحقة بعد نهايتها — تُرفض' };
    } else {
      if (text.slice(12, 16) !== 'IHDR') return { ok: false, error: 'صورة PNG غير صالحة' };
      const iendAt = tail.lastIndexOf('IEND');
      if (iendAt === -1 || tail.length - iendAt > 64) {
        return { ok: false, error: 'صورة PNG غير مكتملة أو تحمل بيانات ملحقة' };
      }
    }
  }

  return { ok: true, ext: sig.ext, ct: sig.ct };
}

/**
 * ترويسات تحييد عند بثّ ملف مرفوع للمتصفّح (الطبقة 5).
 * nosniff يمنع إعادة تفسير النوع؛ CSP بـsandbox يمنع أي تنفيذ/ملاحة/نماذج
 * حتى لو أفلت محتوى ما من الفحص؛ frame-ancestors 'self' يمنع التأطير الخارجي.
 */
export function fileResponseHeaders(contentType) {
  return {
    'Content-Type': contentType || 'application/octet-stream',
    'Content-Disposition': 'inline',
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'; img-src 'self' data:; object-src 'none'; " +
                               "script-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'self'; sandbox",
    'Referrer-Policy': 'no-referrer',
    'Cross-Origin-Resource-Policy': 'same-origin',
  };
}

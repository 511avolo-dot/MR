/**
 * منطق حملة دعوة الموردين غير المسجَّلين — وحدة خالصة مشتركة (لا مسار: البادئة `_`)
 * ============================================================================
 * القياس على الإنتاج (2026-11-02): **132 مورداً** في الدليل بلا طلب تسجيل
 * (أُدخِلوا يدويّاً أو من عروض الأسعار)، و**دعوة واحدة فقط أُرسلت خلال شهرين**
 * منذ بناء الحملة في 10 سبتمبر — لأنّ كل دعوة زرٌّ يدويّ لكل مورد. وصفر مورد
 * سجّل عبر رابط شخصيّ. فالأتمتة لا التحسين الشكليّ هي العلاج.
 *
 * ما هنا خالص (بلا شبكة) فيُختبَر مباشرةً، ونظيره في الواجهة (`index.html`)
 * محروس بتأكيد يقارن مُخرَجَي النسختين على الحالات نفسها:
 *   • `inviteKeyStrong` = `supKeyStrong` في الواجهة (مطابقة «من سجّل»).
 *   • `inviteNextStage` = `regCampNextStage` في الواجهة (المرحلة التالية).
 *
 * ⚠️ المراحل لكل **مورد** لا لكل قناة: دعوة أُرسلت واتساباً لا يُعاد إرسالها
 *    بريداً في المرحلة نفسها — رسالة واحدة لكل خطوة مهما تعدّدت القنوات.
 * ⚠️ ثلاث رسائل ثمّ توقّف: الصمت بعد التذكير الأخير قرارٌ من المورّد لا يُكسَر
 *    بإلحاح آليّ. والتسجيل (بأي حالة) يُوقف السلسلة فوراً في التشغيلة التالية.
 */

/* المراحل: الدعوة · تذكير بعد 7 أيام · تذكير أخير بعد 14 يوماً من الثاني */
export const INVITE_STAGES = [
  { key: 'inv1', afterDays: 0,  label: 'الدعوة' },
  { key: 'inv2', afterDays: 7,  label: 'تذكير' },
  { key: 'inv3', afterDays: 14, label: 'تذكير أخير' },
];
export const INVITE_AUTO_KEY = 'supplier_invite_auto';   // مفتاح proc_settings

/* نسخة من `arNorm` في الواجهة — تطبيع عربيّ للمطابقة (NFKC أوّلاً لرموز العرض) */
export function inviteArNorm(s) {
  return String(s == null ? '' : s)
    .normalize('NFKC')
    .replace(/[ً-ْٰـ]/g, '')
    .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06F0))
    .replace(/[أإآٱ]/g, 'ا').replace(/ى/g, 'ي').replace(/ؤ/g, 'و')
    .replace(/ئ/g, 'ي').replace(/ة/g, 'ه')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();
}
const ENTITY_RE = /^(شركه|شركة|مؤسسه|مؤسسة|موسسه|مصنع|معرض|مجموعه|مجموعة|مكتب|وكاله|وكالة|محل)\s+/;
/* نسخة من `supKeyStrong`: يُسقِط كلمة الكيان الافتتاحية والمسافات */
export function inviteKeyStrong(name) {
  let s = inviteArNorm(name);
  for (let i = 0; i < 2; i++) s = s.replace(ENTITY_RE, '');
  return s.replace(/\s+/g, '');
}
const val = (v) => {
  const t = String(v == null ? '' : v).trim();
  return (!t || t === '—' || t === '-' || /^ـ+$/.test(t)) ? '' : t;
};

/* من سجّل؟ (بأي حالة: معلّق/معتمد/مرفوض — كلّها تفاعلٌ يُنهي الدعوة).
   ⚠️ متساهلة عمداً كـ`regCampBuild`: دعوة مسجَّلٍ إزعاج، أهون من بطاقة مكرّرة. */
export function inviteRegisteredFn(regs) {
  const crs = new Set(), taxes = new Set(), keys = new Set(), ids = new Set();
  (regs || []).forEach((r) => {
    if (val(r.commercial_reg)) crs.add(String(r.commercial_reg).trim());
    if (val(r.vat_number)) taxes.add(String(r.vat_number).trim());
    const k = inviteKeyStrong(r.legal_name_ar || ''); if (k) keys.add(k);
    if (val(r.link_supplier_id)) ids.add(String(r.link_supplier_id).trim());
  });
  return (s) => {
    if (ids.has(String(s.id))) return true;
    if (val(s.commercial_reg) && crs.has(String(s.commercial_reg).trim())) return true;
    if (val(s.tax_id) && taxes.has(String(s.tax_id).trim())) return true;
    const k = inviteKeyStrong(s.name || '');
    return !!(k && keys.has(k));
  };
}

/* بريد صالح للمراسلة؟ (لا قيمة نائبة ولا صيغة مكسورة) */
export function inviteEmailOf(s) {
  const e = val(s && s.email).toLowerCase();
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e) ? e : '';
}

/* سجلّ الإرسال من قيود التدقيق → [{stage, at, channel}] لكل مورد.
   القيد القديم (`supplier_invite_wa` بلا مرحلة، قبل 2026-11-02) يُعَدّ «الدعوة». */
export function inviteSendsFromAudit(rows) {
  const by = new Map();
  (rows || []).forEach((r) => {
    if (!r || !r.entity_id) return;
    const nv = (r.new_value && typeof r.new_value === 'object') ? r.new_value : {};
    const stage = INVITE_STAGES.some((x) => x.key === nv.stage) ? nv.stage : 'inv1';
    const channel = nv.channel || (r.action === 'supplier_invite_wa' ? 'wa' : 'email');
    const at = Date.parse(r.ts || '');
    if (!isFinite(at)) return;
    const k = String(r.entity_id);
    if (!by.has(k)) by.set(k, []);
    by.get(k).push({ stage, at, channel });
  });
  return by;
}

/* المرحلة التالية لمورد من سجلّ إرساله.
   ← { stage, label, index, due, dueAt, last, sent }  أو  { done:true, sent, last }  */
export function inviteNextStage(sends, now) {
  const list = Array.isArray(sends) ? sends : [];
  const doneKeys = new Set(list.map((x) => x.stage));
  const last = list.reduce((m, x) => Math.max(m, x.at || 0), 0) || null;
  const idx = INVITE_STAGES.findIndex((x) => !doneKeys.has(x.key));
  if (idx < 0) return { done: true, sent: list.length, last };
  const st = INVITE_STAGES[idx];
  const dueAt = (idx === 0 || !last) ? 0 : last + st.afterDays * 86400000;
  return { stage: st.key, label: st.label, index: idx, due: dueAt <= now, dueAt, last, sent: list.length };
}

/* ── البريد ──────────────────────────────────────────────────────────────
   ⚠️ قرار المالك 2026-09-10 (محروس): لغة مؤسسيّة لاستكمال البيانات، **لا نبرة
   «ملفّكم موجود لدينا والرابط خاصّ بكم»** — آليّة الربط شأن داخليّ لا يُشرَح. */
export function inviteEsc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
const BRAND = { navy: '#0B1B36', gold: '#C4A265', ink: '#1f2937', muted: '#6b7280' };
export function supplierInviteEmail(name, link, stage) {
  const company = val(name) || 'المورد';
  const lead = stage === 'inv3'
    ? 'نذكّركم للمرّة الأخيرة بدعوة إدارة المشتريات في <b>مجموعة الذيابي</b> إلى استكمال بيانات منشأتكم واعتماد ملفّها عبر بوابة تسجيل الموردين.'
    : stage === 'inv2'
      ? 'نذكّركم بدعوة إدارة المشتريات في <b>مجموعة الذيابي</b> إلى استكمال بيانات منشأتكم واعتماد ملفّها عبر بوابة تسجيل الموردين.'
      : 'في إطار تحديث <b>سجل الموردين المعتمدين</b>، تدعوكم إدارة المشتريات في <b>مجموعة الذيابي</b> إلى استكمال بيانات منشأتكم واعتماد ملفّها عبر بوابة تسجيل الموردين.';
  const subject = stage === 'inv3' ? `تذكير أخير: استكمال ملف المورد — ${company}`
    : stage === 'inv2' ? `تذكير: استكمال ملف المورد — ${company}`
    : `استكمال ملف المورد لدى مجموعة الذيابي — ${company}`;
  const li = (t) => `<li style="margin:0 0 6px">${t}</li>`;
  const html = `<!doctype html><html dir="rtl" lang="ar"><body style="margin:0;background:#f4f6f9;font-family:'Segoe UI',Tahoma,Arial,sans-serif">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6f9;padding:24px 12px">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;box-shadow:0 2px 12px rgba(11,27,54,.08)">
        <tr><td style="background:${BRAND.navy};padding:22px 26px">
          <div style="color:#ffffff;font-size:18px;font-weight:800">مجموعة الذيابي</div>
          <div style="color:${BRAND.gold};font-size:12px;margin-top:4px">إدارة المشتريات — سجل الموردين المعتمدين</div>
        </td></tr>
        <tr><td style="padding:26px">
          <div style="font-size:15px;color:${BRAND.ink};line-height:1.9">السادة / <b>${inviteEsc(company)}</b> المحترمين،<br>تحية طيبة وبعد،</div>
          <div style="font-size:14.5px;color:${BRAND.ink};line-height:1.95;margin-top:10px">${lead}</div>
          <div style="margin:16px 0 4px;font-size:13px;font-weight:800;color:${BRAND.navy}">متطلبات استكمال الملف</div>
          <ul style="margin:0;padding-inline-start:20px;font-size:13.5px;color:${BRAND.ink};line-height:1.8">
            ${li('تعبئة نموذج التسجيل الإلكتروني — بيانات المنشأة وجهات التواصل والحساب البنكي')}
            ${li('إرفاق الوثائق النظامية: السجل التجاري · الشهادة الضريبية · شهادة التأمينات الاجتماعية · عضوية الغرفة التجارية · العنوان الوطني · شهادة الآيبان')}
          </ul>
          <div style="margin:14px 0 4px;font-size:13px;font-weight:800;color:${BRAND.navy}">أثر استكمال الملف</div>
          <ul style="margin:0;padding-inline-start:20px;font-size:13.5px;color:${BRAND.ink};line-height:1.8">
            ${li('اعتماد البيانات البنكية ضمن دورة صرف المستحقات')}
            ${li('الإدراج في قوائم طلبات التسعير والمناقصات')}
            ${li('الإشعار المسبق قبل انتهاء صلاحية السجلات والشهادات')}
          </ul>
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:22px 0 6px">
            <tr><td align="center" bgcolor="${BRAND.gold}" style="background:${BRAND.gold};border-radius:12px">
              <a href="${inviteEsc(link)}" style="display:block;padding:15px 18px;color:#ffffff;text-decoration:none;font-weight:800;font-size:15px">استكمال ملف المورد</a>
            </td></tr>
          </table>
          <div style="font-size:12px;color:${BRAND.muted};line-height:1.8;margin-top:10px">
            إن لم يعمل الزرّ، انسخ هذا الرابط في المتصفّح:<br>
            <span style="word-break:break-all;color:${BRAND.ink}">${inviteEsc(link)}</span>
          </div>
        </td></tr>
        <tr><td style="background:#f8fafc;padding:14px 26px;font-size:12px;color:${BRAND.muted};text-align:center">
          للاستفسار — إدارة المشتريات: <span dir="ltr">920000194</span> · <a href="mailto:supply@aldeyabi.com" style="color:${BRAND.navy}">supply@aldeyabi.com</a>
        </td></tr>
      </table>
    </td></tr>
  </table></body></html>`;
  return { subject, html };
}

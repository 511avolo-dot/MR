/**
 * منطق تذكير الاستلام لصاحب الطلب — وحدة خالصة بلا شبكة
 * ============================================================================
 * المشكلة المقيسة (2026-11-03): 32 من 38 طلب شراء حيّاً واقفة على «بانتظار
 * استلام البضاعة»، و24 أمر شراء مربوطاً بطلب تجاوز موعد تسليمه. إقفال الطلب
 * آليّ منذ #131 — لكنه ينتظر **من يسجّل الاستلام**، ولا شيء يذكّره بذلك.
 * قرار المالك: «صاحب الطلب هو المستلم».
 *
 * القواعد:
 *   • التذكير **لكل أمر** بإيقاعه، والإرسال **لكل شخص** في ملخّص واحد —
 *     صاحب 24 أمراً متأخراً يصله بريد واحد لا 24.
 *   • أوّل تذكير في اليوم التالي لموعد التسليم، ثمّ كل 3 أيام ما دام مفتوحاً.
 *   • أيّ نشاط من الميدان (استلام جزئي مسجَّل · أو «لم يصل بعد» بسبب) يُسكِت
 *     الأمر 5 أيام — لا نسأل عن شيء أُجيب عنه للتوّ.
 *   • لا مبالغ في البريد إطلاقاً: البريد لا تحرسه RLS، وصاحب الطلب الميدانيّ
 *     محجوبة عنه المبالغ (قرار «الرؤية المالية تُمنَح منّي»).
 *
 * ⚠️ نسخة مطابقة في `index.html` (معاينة لوحة الإنذارات) محروسة بتأكيد تكافؤ.
 */

export const RECEIPT_AUTO_KEY = 'receipt_reminder_auto';
export const RR_EVERY_DAYS = 3;          // إعادة التذكير لأمر ما زال مفتوحاً
export const RR_AFTER_REPLY_DAYS = 5;    // إسكات بعد ردّ «لم يصل» أو استلام جزئي
export const RR_MAX_ROWS = 25;           // سقف الأوامر في الملخّص الواحد
const DAY = 86400000;
// هامش: الكنس يومي بخانق 20 ساعة، فلا يتأخّر تذكير «بعد 3 أيام» إلى اليوم الرابع
// لأنّ تشغيلة اليوم الثالث سبقت ساعةَ إرسال الأوّل بدقائق.
const SLACK = 6 * 3600000;

/* حالات أمر الشراء التي لا يُسأل عنها: اكتمل الاستلام أو أُلغي.
   (`مُسلَّم` مرادف قديم يطابقه `PO_STATUS_ALIAS` على «تسليم كامل».) */
export const RR_TERMINAL = ['تسليم كامل', 'مُسلَّم', 'ملغى'];
const PR_DONE = ['closed', 'cancelled', 'rejected'];

/* المرحلة كما يفهمها صاحب الطلب — هو لا يعرف مصطلحات المشتريات الداخلية،
   لكنّه يحتاج أن يعرف أين يقف أمره قبل أن يقول «لم يصل». */
const RR_STAGE_TEXT = {
  'قيد المراجعة': 'قيد مراجعة المشتريات',
  'اعتماد مدير الشراء': 'بانتظار اعتماد مدير المشتريات',
  'تسليم للإدارة المالية': 'لدى الإدارة المالية',
  'تم التحويل': 'حُوِّلت الدفعة للمورد',
  'قيد التوريد': 'قيد التوريد',
  'تسليم جزئي': 'تسليم جزئي',
};
export function rrStageText(status) {
  const s = String(status || '').trim();
  return RR_STAGE_TEXT[s] || s || '—';
}

/* «اليوم» بتوقيت الرياض (UTC+3 بلا توقيت صيفي) — موعد التسليم تاريخ بلا ساعة،
   ومقارنته بتاريخ UTC تُعلن التأخير قبل وقته بثلاث ساعات كل ليلة. */
export function rrToday(now) {
  return new Date(Number(now) + 3 * 3600000).toISOString().slice(0, 10);
}
export function rrDaysLate(expected, today) {
  const e = String(expected || '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(e)) return null;
  return Math.round((Date.parse(today) - Date.parse(e)) / DAY);
}
export function rrIsOpenPO(po) {
  return !!po && !RR_TERMINAL.includes(String(po.status || '').trim());
}
/* آخر استلام مسجَّل على الأمر (ms) — نشاطٌ من الميدان يُسكِت التذكير */
export function rrLastReceiptAt(po) {
  let last = 0;
  for (const r of (Array.isArray(po && po.receipts) ? po.receipts : [])) {
    const t = Date.parse(r && r.at);
    if (t > last) last = t;
  }
  return last;
}
/* الكمية المستلمة من المطلوب — بالكميّات لا بالقيم */
export function rrReceived(po) {
  let ordered = 0, received = 0;
  for (const it of (Array.isArray(po && po.items) ? po.items : [])) {
    const q = Number(it && it.qty) || 0;
    ordered += q;
    received += Math.min(q, Number(it && it.received_qty) || 0);
  }
  return { ordered, received };
}

/* سجلّ التدقيق ← لكل أمر: آخر إرسال وعدده، وآخر ردّ وسببه.
   الصفوف: `entity_type=receipt_reminder` بـ`action` = notify (إرسال) | reply (ردّ). */
export function rrEventsFromAudit(rows) {
  const m = new Map();
  for (const r of (Array.isArray(rows) ? rows : [])) {
    if (!r || r.entity_type && r.entity_type !== 'receipt_reminder') continue;
    const po = String(r.entity_id || '').trim();
    if (!po || po === 'sweep') continue;
    const t = Date.parse(r.ts);
    if (!(t > 0)) continue;
    const e = m.get(po) || { sent: 0, lastSent: 0, lastReply: 0, reason: '' };
    if (r.action === 'notify') { e.sent++; if (t > e.lastSent) e.lastSent = t; }
    else if (r.action === 'reply') {
      if (t > e.lastReply) {
        e.lastReply = t;
        const v = r.new_value && typeof r.new_value === 'object' ? r.new_value : {};
        e.reason = String(v.reason || '');
      }
    }
    m.set(po, e);
  }
  return m;
}

/* هل يستحقّ هذا الأمر تذكيراً الآن؟ */
export function rrPoDue(po, ev, now) {
  if (!rrIsOpenPO(po)) return { due: false, why: 'closed' };
  const late = rrDaysLate(po.expected_delivery, rrToday(now));
  if (late == null) return { due: false, why: 'no_date' };
  if (late < 1) return { due: false, why: 'not_late', late };
  const e = ev || { sent: 0, lastSent: 0, lastReply: 0 };
  const lastAct = Math.max(e.lastReply || 0, rrLastReceiptAt(po));
  let nextAt = 0;
  if (e.lastSent) nextAt = e.lastSent + RR_EVERY_DAYS * DAY - SLACK;
  if (lastAct) nextAt = Math.max(nextAt, lastAct + RR_AFTER_REPLY_DAYS * DAY - SLACK);
  return { due: now >= nextAt, why: now >= nextAt ? 'due' : 'waiting', late, nextAt,
           sent: e.sent || 0, lastReply: e.lastReply || 0, reason: e.reason || '' };
}

/* الملخّصات: لكل صاحب طلب نشط، أوامره المستحقّة الآن (الأشدّ تأخيراً أوّلاً).
   المدخلات صفوف كما تأتي من القاعدة؛ تحديد البريد خارج هذه الدالّة. */
export function rrBuildDigests({ links, prs, pos, users, audit, now }) {
  const prById = new Map((prs || []).map((p) => [String(p.id), p]));
  const poByNum = new Map((pos || []).map((o) => [String(o.po_number), o]));
  const userBy = new Map((users || []).map((u) => [String(u.username || '').toLowerCase(), u]));
  const events = rrEventsFromAudit(audit);

  const byReq = new Map();     // requester → Map(po_number → {po, pr_ids:Set})
  for (const l of (links || [])) {
    if (!l || l.active === false) continue;
    const pr = prById.get(String(l.pr_id));
    if (!pr || pr.archived_at || PR_DONE.includes(String(pr.status || ''))) continue;
    const po = poByNum.get(String(l.po_number));
    if (!po) continue;
    // ⚠️ مفتاح التجميع بحالة أحرف موحَّدة: الإنتاج يحمل أسماء تختلف بالحالة فقط،
    // ولو جُمِّعت حرفيّاً وصل الشخصَ الواحد بريدان في اليوم نفسه.
    const req = String(pr.requester || '').trim().toLowerCase();
    if (!req) continue;
    const m = byReq.get(req) || new Map();
    const row = m.get(po.po_number) || { po, pr_ids: new Set() };
    row.pr_ids.add(String(pr.id));
    m.set(po.po_number, row);
    byReq.set(req, m);
  }

  const out = [];
  for (const [req, m] of byReq) {
    const u = userBy.get(req);
    if (!u || u.active === false) continue;     // حساب موقوف لا يُراسَل
    const items = [];
    for (const { po, pr_ids } of m.values()) {
      const d = rrPoDue(po, events.get(String(po.po_number)), now);
      if (!d.due) continue;
      items.push({ po, pr_ids: [...pr_ids], late: d.late, sent: d.sent });
    }
    if (!items.length) continue;
    items.sort((a, b) => b.late - a.late || String(a.po.po_number).localeCompare(String(b.po.po_number)));
    out.push({ username: u.username, name: u.display_name || u.username, user: u, items });
  }
  out.sort((a, b) => b.items[0].late - a.items[0].late);
  return out;
}

/* ── البريد ─────────────────────────────────────────────────────────────── */
export function rrEsc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
/* «24 أمر شراء» لا «24 أمر» — صيغ العدد العربية كـ`arCountWord` */
export function rrCountPO(n) {
  n = Number(n) || 0;
  if (n === 1) return 'أمر شراء واحد';
  if (n === 2) return 'أمرا شراء';
  if (n >= 3 && n <= 10) return `${n} أوامر شراء`;
  return `${n} أمر شراء`;
}
export function rrDaysText(n) {
  n = Number(n) || 0;
  if (n === 1) return 'يوم واحد';
  if (n === 2) return 'يومان';
  if (n >= 3 && n <= 10) return `${n} أيام`;
  return `${n} يوماً`;
}
export function rrActionUrl(origin, poNumber, act) {
  if (!origin) return '';
  return `${origin}/?po=${encodeURIComponent(poNumber)}&act=${act === 'wait' ? 'wait' : 'receive'}`;
}

export function receiptReminderEmail({ name, items, origin, more = 0 }) {
  const navy = '#0B1B36', gold = '#B8923D', ink = '#1f2937', soft = '#6b7280', line = '#e6e8ee', wash = '#f6f4ee';
  const n = items.length + (Number(more) || 0);
  const rows = items.map(({ po, pr_ids, late }) => {
    const rc = rrReceived(po);
    const rcText = rc.ordered ? (rc.received ? `مستلَم ${rc.received} من ${rc.ordered}` : 'لم يُسجَّل استلام') : '—';
    const descs = (Array.isArray(po.items) ? po.items : []).map((it) => String(it && it.desc || '').trim()).filter(Boolean);
    const descText = descs.slice(0, 3).join(' · ') + (descs.length > 3 ? ` · و${descs.length - 3} أخرى` : '');
    const recv = rrActionUrl(origin, po.po_number, 'receive');
    const wait = rrActionUrl(origin, po.po_number, 'wait');
    const btns = recv ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin-top:10px"><tr>
        <td bgcolor="#15803d" style="background:#15803d;border-radius:9px"><a href="${rrEsc(recv)}" style="display:block;padding:9px 14px;color:#fff;text-decoration:none;font-weight:700;font-size:13px">✓ وصلت — سجّل الاستلام</a></td>
        <td style="width:8px"></td>
        <td style="border:1px solid ${line};border-radius:9px"><a href="${rrEsc(wait)}" style="display:block;padding:8px 14px;color:${ink};text-decoration:none;font-weight:700;font-size:13px">لم تصل بعد</a></td>
      </tr></table>` : '';
    return `<tr><td dir="rtl" style="padding:14px 16px;border-bottom:1px solid ${line};text-align:right">
      <div style="font-size:14.5px;font-weight:800;color:${navy}"><span dir="ltr" style="font-family:Consolas,'Courier New',monospace">${rrEsc(po.po_number)}</span>
        <span style="font-size:12px;font-weight:700;color:#b42318;background:#fef3f2;border-radius:20px;padding:2px 9px;margin-right:6px">متأخر ${rrEsc(rrDaysText(late))}</span></div>
      <div style="font-size:13px;color:${ink};margin-top:6px;line-height:1.8">
        <b>المشروع:</b> ${rrEsc(po.project || '—')} &nbsp;·&nbsp; <b>المورد:</b> ${rrEsc(po.supplier || '—')}<br>
        <b>موعد التسليم:</b> <span dir="ltr">${rrEsc(String(po.expected_delivery || '').slice(0, 10))}</span>
        &nbsp;·&nbsp; <b>مرحلته الآن:</b> ${rrEsc(rrStageText(po.status))} &nbsp;·&nbsp; ${rrEsc(rcText)}
        ${pr_ids.length ? `<br><span style="color:${soft}">${pr_ids.length > 1 ? 'طلبات الشراء' : 'طلب الشراء'}: ${pr_ids.map((id) => `<span dir="ltr" style="white-space:nowrap">${rrEsc(id)}</span>`).join(' · ')}</span>` : ''}
        ${descText ? `<br><span style="color:${soft}">${rrEsc(descText)}</span>` : ''}
      </div>${btns}
    </td></tr>`;
  }).join('');
  const moreRow = more > 0 ? `<tr><td dir="rtl" style="padding:12px 16px;text-align:right;font-size:13px;color:${soft}">والباقي (${rrEsc(rrCountPO(more))}) يصلك في التذكير القادم.</td></tr>` : '';
  const html = `<!DOCTYPE html><html dir="rtl" lang="ar"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:${wash};font-family:'Segoe UI',Tahoma,Arial,sans-serif;color:${ink}">
<span style="display:none;max-height:0;overflow:hidden">${rrEsc(rrCountPO(n))} تجاوز موعد التسليم — هل وصلت البضاعة؟</span>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${wash};padding:22px 12px"><tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#fff;border-radius:18px;overflow:hidden">
  <tr><td style="background:${navy};padding:20px 28px" align="center">
    <div style="color:#E9D9B4;font-size:11.5px;letter-spacing:.08em">AL-DEYABI GROUP · مجموعة الذيابي</div>
    <div style="color:#fff;font-size:18px;font-weight:800;margin-top:8px">متابعة استلام البضاعة</div>
  </td></tr>
  <tr><td style="height:3px;background:${gold}"></td></tr>
  <tr><td dir="rtl" style="padding:22px 28px 8px;text-align:right">
    <p style="font-size:14.5px;line-height:1.95;margin:0;color:${ink}">مرحباً ${rrEsc(name || '')}،</p>
    <p style="font-size:14.5px;line-height:1.95;margin:6px 0 0;color:${ink}">تجاوز ${rrEsc(rrCountPO(n))} من طلباتك موعد التسليم المتوقّع. أنت مستلم البضاعة، فأخبرنا بما حدث لكلٍّ منها:</p>
    <ul style="font-size:13.5px;line-height:1.9;margin:8px 0 0;padding-right:18px;color:${ink}">
      <li><b>وصلت:</b> سجّل الكميات المستلمة فعلاً — يُغلَق الطلب تلقائياً عند اكتمالها.</li>
      <li><b>لم تصل بعد:</b> اختر السبب في نقرة، فيصل لفريق المشتريات ليتابع المورد.</li>
    </ul>
  </td></tr>
  <tr><td style="padding:10px 16px 4px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid ${line};border-radius:12px">${rows}${moreRow}</table></td></tr>
  <tr><td dir="rtl" style="padding:12px 28px 20px;text-align:right;font-size:12px;color:${soft};line-height:1.8">
    تفتح الأزرار النظام بحسابك. يتكرّر التذكير كل ${RR_EVERY_DAYS} أيام لكل أمر لم يُستلَم، ويتوقّف ${RR_AFTER_REPLY_DAYS} أيام بعد ردّك.
  </td></tr>
  <tr><td style="background:${navy};padding:14px 28px" align="center">
    <div style="color:#fff;font-size:12px;opacity:.9">مجموعة الذيابي · نظام المشتريات</div>
  </td></tr>
</table></td></tr></table></body></html>`;
  return { subject: `متابعة استلام: ${rrCountPO(n)} تجاوز موعد التسليم | مجموعة الذيابي`, html };
}

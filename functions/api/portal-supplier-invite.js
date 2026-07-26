/**
 * Cloudflare Pages Function — دعوة مورّد لتقديم عرضه ذاتياً (نظام 3، معزولة)
 * ════════════════════════════════════════════════════════════════════════════
 * POST /api/portal-supplier-invite
 *   body: { request_id, supplier, email?, phone?, ttl_days? }
 *   • same-origin + رمز جلسة (Bearer JWT) + مستخدم بوابة نشط + can_manage_procurement.
 *   • تُنشئ الرمز عبر RPC portal_supplier_invite **بجلسة المستخدم نفسه** (لا service_role)
 *     فيبقى حارس القاعدة هو المرجع — دفاع في العمق: لو تسرّبت هذه النقطة لا تمنح امتيازاً.
 *   • تُعيد الرابط دائماً (لينسخه الموظّف أو يرسله بواتساب)، وترسله بالبريد إن وُجد بريد.
 *
 * ⚠️ ملاحظة تصميمية: لا نُعيد استخدام sendResend المشتركة لأنّها — عمداً — لا تقبل
 * إلا مستقبِلاً على @aldeyabi.com (حارس ضد إساءة استخدام مسار الإشعارات الداخلية).
 * المورّدون خارجيون بطبيعتهم، فنرسل هنا بمُرسِل مستقلّ مقيّد: مستقبِل واحد فقط،
 * بريده مأخوذ من جسم الطلب بعد تحقّق الصيغة، ولا يُرسَل شيء إلا بعد نجاح إنشاء الرمز
 * (أي بعد أن أثبت المستدعي صلاحيته في القاعدة).
 */
import { portalUrl, portalKey, portalConfigured, fromAddress, replyTo, htmlToText, esc } from './_portal-shared.js';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i;

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}
function sameOrigin(request) {
  const host = request.headers.get('host');
  const src = request.headers.get('origin') || request.headers.get('referer');
  if (!host || !src) return false;
  try { return new URL(src).host === host; } catch (_) { return false; }
}
function originOf(env, request) {
  const cfg = (env.PUBLIC_ORIGIN || '').trim().replace(/\/+$/, '');
  if (cfg) return cfg;
  try { return new URL(request.url).origin; } catch (_) { return ''; }
}

function inviteHtml(supplier, title, link, days) {
  const s = esc(supplier || 'المورّد الكريم');
  return `<!doctype html><html dir="rtl" lang="ar"><body style="margin:0;background:#F7F5F2;padding:24px;
    font-family:'IBM Plex Sans Arabic',Tahoma,Arial,sans-serif;color:#231F20">
    <div style="max-width:560px;margin:0 auto;background:#fff;border:1px solid #E6E0D7;border-radius:12px;overflow:hidden">
      <div style="background:linear-gradient(165deg,#171415,#231F20 60%,#39312C);color:#F6EFE0;padding:18px 20px;border-bottom:2px solid #C4A265">
        <div style="font-size:11px;letter-spacing:.14em;color:#C4A265">AL-DEYABI GROUP</div>
        <div style="font-weight:700;font-size:16px;margin-top:2px">دعوة لتقديم عرض سعر</div>
      </div>
      <div style="padding:20px;line-height:1.9;font-size:14px">
        <p style="margin:0 0 10px">السادة <b>${s}</b> المحترمين،</p>
        <p style="margin:0 0 14px">يسرّ مجموعة الذيابي دعوتكم لتقديم عرض سعر بخصوص:
          <b>${esc(title || 'طلب تسعير')}</b>.</p>
        <p style="margin:0 0 14px">يمكنكم إدخال أسعاركم لكل بند مباشرةً عبر الرابط أدناه — تُحفظ مدخلاتكم
          تلقائياً، ويمكنكم تعديل العرض ما دام باب التسعير مفتوحاً.</p>
        <p style="margin:0 0 18px;background:#FAF6EE;border-inline-start:3px solid #C4A265;padding:9px 12px;border-radius:8px">
          <b>مطلوب:</b> إرفاق عرض السعر الرسمي بترويسة مؤسستكم (ملف PDF أو صورة واضحة) من داخل الصفحة —
          يُحفظ سنداً للعرض في ملف المعاملة.</p>
        <p style="margin:0 0 20px;text-align:center">
          <a href="${esc(link)}" style="display:inline-block;background:#231F20;color:#F6EFE0;text-decoration:none;
            padding:13px 26px;border-radius:11px;font-weight:700;font-size:15px">تقديم عرض السعر</a></p>
        <p style="margin:0 0 6px;font-size:12.5px;color:#6E6459">صلاحية الرابط: ${Number(days) || 14} يوماً.
          الرابط خاصّ بكم — يُرجى عدم مشاركته.</p>
        <p style="margin:14px 0 0;font-size:12px;color:#9C9287;word-break:break-all">إن تعذّر فتح الزر:<br>${esc(link)}</p>
      </div>
      <div style="background:#FAF8F5;border-top:1px solid #F1ECE4;padding:12px 20px;font-size:11.5px;color:#6E6459">
        إدارة المشتريات · مجموعة الذيابي
      </div>
    </div></body></html>`;
}

export async function onRequestPost({ request, env }) {
  if (!portalConfigured(env)) return json({ error: 'إعداد البوابة غير مكتمل على الخادم' }, 503);
  if (!sameOrigin(request)) return json({ error: 'طلب غير مصرّح به (origin)' }, 403);

  const jwt = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'رمز الجلسة مفقود' }, 401);

  let body;
  try { body = await request.json(); } catch (_) { return json({ error: 'JSON غير صالح' }, 400); }
  const requestId = String(body?.request_id || '').trim();
  const supplier  = String(body?.supplier || '').trim();
  const email     = String(body?.email || '').trim();
  const ttlDays   = Math.max(1, Math.min(60, Number(body?.ttl_days) || 14));
  if (!requestId || !supplier) return json({ error: 'رقم الطلب واسم المورّد مطلوبان' }, 400);
  if (email && !EMAIL_RE.test(email)) return json({ error: 'صيغة البريد غير صحيحة' }, 400);

  const base = portalUrl(env);

  // إنشاء الرمز **بجلسة المستخدم** — الحارس في القاعدة يتحقّق من can_manage_procurement
  // ومن أنّ الطلب في مرحلة التسعير. لا نتجاوزه بمفتاح الخدمة.
  let inv;
  try {
    const r = await fetch(`${base}/rest/v1/rpc/portal_supplier_invite`, {
      method: 'POST',
      headers: { apikey: portalKey(env), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_request_id: requestId, p_supplier: supplier, p_email: email || null, p_ttl_days: ttlDays }),
    });
    const t = await r.text();
    let j = null; try { j = JSON.parse(t); } catch (_) {}
    if (!r.ok) return json({ error: (j && (j.message || j.hint)) || 'تعذّر إنشاء الدعوة' }, r.status === 401 ? 401 : 403);
    inv = j;
  } catch (_) { return json({ error: 'تعذّر الاتصال بقاعدة البيانات' }, 502); }

  const token = inv && inv.token;
  if (!token) return json({ error: 'لم يُنشأ الرمز' }, 500);

  const origin = originOf(env, request);
  const link = `${origin}/supplier-quote.html?t=${encodeURIComponent(token)}`;

  // إرسال البريد (اختياري) — مستقبِل واحد فقط هو بريد المورّد المُتحقَّق من صيغته
  let emailed = null;
  if (email) {
    if (!env.RESEND_API_KEY) {
      emailed = { ok: false, reason: 'email_not_configured' };
    } else {
      try {
        const html = inviteHtml(supplier, String(body?.title || ''), link, ttlDays);
        const r = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            from: fromAddress(env), to: [email],
            subject: `دعوة لتقديم عرض سعر · ${supplier}`,
            html, text: htmlToText(html), reply_to: replyTo(env),
          }),
        });
        emailed = r.ok ? { ok: true } : { ok: false, status: r.status };
      } catch (_) { emailed = { ok: false, reason: 'send_failed' }; }
    }
  }

  return json({ ok: true, link, expires_days: ttlDays, emailed });
}

export function onRequestGet({ env }) {
  return json({ ok: !!(portalConfigured(env)), checks: { portal: !!portalConfigured(env), resend: !!env.RESEND_API_KEY } });
}

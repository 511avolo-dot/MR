// ════════════════════════════════════════════════════════════════════════════
//  functions/api/portal-outbox-drain.js
//  عامل الصيانة المجدوَل — البوابة (النظام 3): تصعيد SLA + تسليم صندوق الصادر.
//
//  الغرض: تحويل الأشياء الحسّاسة للوقت من «نبضة كسولة تعتمد زيارة الواجهة» إلى
//  تشغيل مجدوَل موثوق. يُستدعى دورياً (Cloudflare Cron Trigger كل دقيقة، أو أي
//  مجدوِل خارجي، أو نبضة من الواجهة كخط دفاع ثانٍ). كل نداء:
//    0) يشغّل تصعيد SLA (portal_run_sla) — لا يعتمد بعد الآن على فتح أحدهم للتطبيق.
//    1) يسحب دفعة إشعارات مستحقّة عبر RPC ذرّية (portal_outbox_claim، FOR UPDATE SKIP LOCKED).
//    2) يحلّ بريد المستلِم ويُرسل عبر Resend.
//    3) يعلّم النتيجة (portal_outbox_mark): نجاح ⇒ sent؛ فشل ⇒ تراجع أُسّي / dead-letter.
//  (إشعارات تصعيد SLA تُلتقط في portal_outbox عبر مُشغِّل 029 فتُرسَل في نفس الدورة.)
//
//  الحماية: سرّ مشترك CRON_SECRET (ترويسة Authorization: Bearer <secret> أو ?key=).
//  يعيد استخدام PORTAL_SUPABASE_* وRESEND_API_KEY القائمة — لا متغيّر جديد سوى CRON_SECRET.
//
//  التفعيل (خطوة المالك — النظام خامل حتى تُنفَّذ):
//    • أضِف CRON_SECRET في Cloudflare Pages (Production) — قيمة عشوائية طويلة.
//    • اربط Cron Trigger (Worker صغير) أو مجدوِلاً خارجياً يطلب هذا المسار كل دقيقة
//      بترويسة Authorization: Bearer <CRON_SECRET>.
//    • عند التحويل: أزِل نداءات pa_notify الفورية من الواجهة (تُصبح زائدة) تفادياً
//      لازدواج البريد — الصادر يغطّي كل إشعار تلقائياً عبر مُشغِّل القاعدة.
// ════════════════════════════════════════════════════════════════════════════
import {
  portalUrl, portalKey, portalConfigured, svcHeaders,
  userEmail, sendResend, esc, BRAND, publicOrigin,
} from './_portal-shared.js';

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}

// تحقّق السرّ المشترك — فشل مغلق (يرفض عند غياب الإعداد)
function authorized(request, env) {
  const secret = String((env && env.CRON_SECRET) || '').trim();
  if (!secret) return false; // لا سرّ مضبوط ⇒ رفض (لا يُفتح المسار للعامة)
  const auth = String(request.headers.get('authorization') || '');
  const bearer = auth.toLowerCase().startsWith('bearer ') ? auth.slice(7).trim() : '';
  let qkey = '';
  try { qkey = new URL(request.url).searchParams.get('key') || ''; } catch (_) {}
  return bearer === secret || qkey === secret;
}

// قالب بريد بسيط بهوية المجموعة
function emailHtml(env, row) {
  const origin = publicOrigin(env, '');
  const portalLink = origin ? `${origin}/portal` : '#';
  const title = esc(row.title || 'إشعار من بوابة المشتريات');
  const body = esc(row.body || '');
  return `<div dir="rtl" style="font-family:system-ui,-apple-system,'Segoe UI',Tahoma,sans-serif;background:${BRAND.wash};padding:24px">
    <div style="max-width:560px;margin:0 auto;background:${BRAND.surface};border:1px solid ${BRAND.line};border-radius:14px;overflow:hidden">
      <div style="background:${BRAND.navy};color:#fff;padding:18px 22px;font-weight:700">مجموعة الذيابي — بوابة المشتريات</div>
      <div style="padding:22px">
        <h2 style="margin:0 0 10px;color:${BRAND.ink};font-size:18px">${title}</h2>
        ${body ? `<p style="margin:0 0 18px;color:${BRAND.soft};line-height:1.7">${body}</p>` : ''}
        <a href="${portalLink}" style="display:inline-block;background:${BRAND.gold};color:${BRAND.navy};text-decoration:none;font-weight:700;padding:11px 20px;border-radius:9px">فتح البوابة</a>
      </div>
      <div style="padding:12px 22px;color:${BRAND.soft};font-size:12px;border-top:1px solid ${BRAND.line}">هذه رسالة آلية — لا تُرَدّ عليها مباشرة.</div>
    </div>
  </div>`;
}

// تصعيد SLA المجدوَل: يستبدل الاعتماد على «نبضة كسولة من الواجهة». portal_run_sla
// خادمية (service_role) ومخنوقة داخلياً (last_escalation_at) فآمنة للاستدعاء كل دقيقة.
// إشعارات التصعيد التي تُنشئها تُلتقط في portal_outbox (مُشغِّل 029) فتُرسَل بنفس الدورة.
async function runSla(env, base) {
  try {
    const r = await fetch(`${base}/rest/v1/rpc/portal_run_sla`, {
      method: 'POST', headers: { ...svcHeaders(env), 'Content-Type': 'application/json' }, body: '{}',
    });
    if (!r.ok) return { ok: false, detail: (await r.text().catch(() => '')).slice(0, 200) };
    const n = await r.json().catch(() => null);
    return { ok: true, escalated: typeof n === 'number' ? n : 0 };
  } catch (e) { return { ok: false, detail: String(e).slice(0, 200) }; }
}

async function claim(env, base, limit) {
  const r = await fetch(`${base}/rest/v1/rpc/portal_outbox_claim`, {
    method: 'POST', headers: { ...svcHeaders(env), 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_limit: limit }),
  });
  if (!r.ok) throw new Error(`claim ${r.status}: ${(await r.text().catch(() => '')).slice(0, 200)}`);
  return await r.json();
}

async function mark(env, base, id, ok, error) {
  await fetch(`${base}/rest/v1/rpc/portal_outbox_mark`, {
    method: 'POST', headers: { ...svcHeaders(env), 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_id: id, p_ok: ok, p_error: error ? String(error).slice(0, 300) : null }),
  }).catch(() => {}); // تعليم فاشل لا يجب أن يُسقط الدفعة كلها
}

async function drain({ request, env }) {
  if (!authorized(request, env)) return json({ error: 'unauthorized' }, 401);
  if (!portalConfigured(env)) return json({ error: 'portal not configured' }, 500);
  if (!env.RESEND_API_KEY) return json({ error: 'email not configured' }, 500);

  const base = portalUrl(env);
  let limit = 20;
  try { limit = Math.max(1, Math.min(100, parseInt(new URL(request.url).searchParams.get('limit') || '20', 10) || 20)); } catch (_) {}

  // (1) تصعيد SLA المجدوَل أولاً — فتُلتقط إشعاراته في الصادر وتُرسَل في نفس هذه الدورة.
  const sla = await runSla(env, base);

  // (2) تسليم صندوق الصادر.
  let rows;
  try { rows = await claim(env, base, limit); } catch (e) { return json({ error: 'claim_failed', detail: String(e).slice(0, 200), sla }, 502); }
  if (!Array.isArray(rows) || !rows.length) return json({ ok: true, processed: 0, sla });

  let sent = 0, skipped = 0, failed = 0;
  for (const row of rows) {
    try {
      const email = await userEmail(env, base, row.recipient);
      if (!email) { await mark(env, base, row.id, true, null); skipped++; continue; } // مستلِم بلا بريد ⇒ لا شيء لإرساله (نهائي)
      const res = await sendResend(env, [email], row.title || 'إشعار بوابة المشتريات', emailHtml(env, row));
      if (res && res.ok) { await mark(env, base, row.id, true, null); sent++; }
      else if (res && res.skipped) { await mark(env, base, row.id, true, res.reason || 'skipped'); skipped++; } // بريد غير مؤهَّل ⇒ نهائي
      else { await mark(env, base, row.id, false, (res && res.detail) || 'resend_error'); failed++; }
    } catch (e) {
      await mark(env, base, row.id, false, String(e)); failed++;
    }
  }
  return json({ ok: true, processed: rows.length, sent, skipped, failed, sla });
}

export const onRequestPost = drain;
export const onRequestGet = drain; // يسمح بالنبضة الكسولة/الاستدعاء المجدوَل عبر GET أيضاً (محميّ بالسرّ)

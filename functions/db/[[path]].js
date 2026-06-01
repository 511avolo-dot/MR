// وكيل عكسي لـ Supabase عبر نطاق التطبيق نفسه (Cloudflare Pages Function).
//
// السبب: بعض شبكات الشركات تحجب الوصول المباشر إلى *.supabase.co من المتصفح،
// بينما تسمح بنطاق التطبيق (aldeyabi.com). هذه الدالة تعيد توجيه الطلب من
// جهة الخادم (حافة Cloudflare) إلى Supabase، فلا يخضع الاتصال لقيود شبكة العميل.
//
// المتصفح يطلب: /db/auth/v1/token  أو  /db/rest/v1/<table>
// والدالة تمرّره إلى: https://<project>.supabase.co/auth/v1/token ...
//
// ملاحظة أمنية: لا يضيف هذا الوكيل أي صلاحيات؛ ترويسات المصادقة (apikey و
// Authorization: Bearer <jwt>) تمر كما هي، وتبقى سياسات RLS مطبَّقة بالكامل.

const SUPABASE_ORIGIN = 'https://yofcaxvstjcrmbgciwym.supabase.co';

// ترويسات لا يجوز تمريرها (hop-by-hop) أو تخص شبكة Cloudflare.
const STRIP_REQUEST_HEADERS = [
  'host', 'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade', 'content-length',
  'cf-connecting-ip', 'cf-ipcountry', 'cf-ray', 'cf-visitor', 'cf-worker',
  'x-forwarded-host', 'x-forwarded-proto', 'x-real-ip'
];

export async function onRequest(context){
  const { request, params } = context;
  const reqUrl = new URL(request.url);

  // إعادة بناء المسار بعد /db/
  const segs = params && params.path;
  const path = Array.isArray(segs) ? segs.join('/') : (segs || '');
  const target = SUPABASE_ORIGIN + '/' + path + reqUrl.search;

  // طلب فحص مسبق (نادر على نفس النطاق) — نردّ بسماح بسيط.
  if(request.method === 'OPTIONS'){
    return new Response(null, {
      status: 204,
      headers: {
        'access-control-allow-origin': reqUrl.origin,
        'access-control-allow-methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS',
        'access-control-allow-headers': request.headers.get('access-control-request-headers') || '*',
        'access-control-max-age': '86400'
      }
    });
  }

  const headers = new Headers(request.headers);
  for(const h of STRIP_REQUEST_HEADERS) headers.delete(h);

  const init = { method: request.method, headers, redirect: 'manual' };
  if(request.method !== 'GET' && request.method !== 'HEAD'){
    init.body = await request.arrayBuffer();
  }

  let upstream;
  try{
    upstream = await fetch(target, init);
  }catch(e){
    return new Response(
      JSON.stringify({ error: 'proxy_upstream_unreachable', message: String((e && e.message) || e) }),
      { status: 502, headers: { 'content-type': 'application/json' } }
    );
  }

  // نزيل الترويسات الخاصة بالضغط/الطول لأن وقت التشغيل يعيد ضبطها تلقائياً.
  const respHeaders = new Headers(upstream.headers);
  respHeaders.delete('content-encoding');
  respHeaders.delete('content-length');
  respHeaders.delete('transfer-encoding');
  respHeaders.set('access-control-allow-origin', reqUrl.origin);

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: respHeaders
  });
}

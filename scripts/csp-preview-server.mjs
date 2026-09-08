/* خادم معاينة يُطبّق CSP الإنتاج من _headers حرفيّاً.
   ⚠️ استعمله لأي اختبار متصفّح لمسار جديد — خادم عارٍ يُخفي انتهاكات CSP
   (هكذا مرّ عيب pdf.js إلى الإنتاج: blob: ممنوعة في connect-src). */
import http from 'http'; import fs from 'fs'; import path from 'path';
// خادم يُطبّق **نفس CSP الإنتاج حرفيّاً** من _headers — وهو ما فات اختباري السابق
const hdr = fs.readFileSync(new URL('../_headers', import.meta.url),'utf8');
const CSP = (hdr.match(/Content-Security-Policy:\s*(.+)/)||[])[1].trim();
console.log('CSP قيد التطبيق:', CSP.slice(0,90)+'…');
const types={'.html':'text/html','.mjs':'application/javascript','.js':'application/javascript','.pdf':'application/pdf','.png':'image/png','.webmanifest':'application/manifest+json'};
http.createServer((req,res)=>{
  const f = path.join(new URL('..', import.meta.url).pathname, decodeURIComponent(req.url.split('?')[0]));
  fs.readFile(f,(e,d)=>{
    if(e){res.writeHead(404);return res.end('nf');}
    res.writeHead(200,{'Content-Type':types[path.extname(f)]||'application/octet-stream','Content-Security-Policy':CSP});
    res.end(d);
  });
}).listen(8812, ()=>console.log('ready'));

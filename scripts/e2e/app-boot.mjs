/**
 * app-boot.mjs — إقلاع حتميّ لفحوص المتصفّح (النظام 2): قطع الشبكة عن Supabase + إدخال التطبيق.
 *
 * ⚠️ لماذا هذا لازم، مقيساً لا مفترَضاً:
 *   `index.html` ينادي `hydrateFromCloud()` **فور الإقلاع**، وهي تستدعي
 *   `tryAutoConnectCloud()` التي تقرأ `getCloudConfig()` — و**تسقط إلى إعداد
 *   مُضمَّن في الصفحة** إن لم يكن في `localStorage` شيء. فأي فحص متصفّح يفتح
 *   الصفحة يطلب من **قاعدة الإنتاج** فعلاً (مُتحقَّق: طلب واحد يُعترَض في كل
 *   جلسة). وعلى عدّاءٍ شبكتُه تعمل يكتمل المسار فيجري `refreshFromCloud()`
 *   فيستبدل الحالة المبذورة، ثمّ `setupRealtime()` يفتح `wss://…supabase.co`
 *   فتُسجَّل انتهاكات CSP (`connect-src` تسمح بـhttps لا wss).
 *
 *   ولهذا كان السلوك يختلف بين بيئة التطوير (الشبكة مقطوعة ⇒ المسار يسقط
 *   مبكّراً ⇒ الفحص يمرّ) وCI (الشبكة تعمل ⇒ الحالة تُدهَس ⇒ فحوص تسقط
 *   بلا سبب ظاهر). الإجهاض يجعل البيئتين واحدة.
 *
 * ⚠️ وهو **شرط سلامة** لا تحسين أداء: بلا الإجهاض يقرأ كل فحص متصفّح بيانات
 *   الإنتاج الحقيقية. لا فحص يلمس الإنتاج.
 *
 * الاستعمال: `await blockSupabase(contextOrPage)` **قبل** أوّل `goto`.
 */
export async function blockSupabase(target) {
  await target.route(/supabase\.(co|com|net)/i, r => r.abort());
}

/**
 * enterApp — يُدخِل الصفحة حالةَ «التطبيق ظاهر» **ويُبقيها**.
 *
 * ⚠️ لماذا حلقة لا نداءٌ واحد: مسارات الإقلاع اللاتزامنيّة في `index.html`
 *   (`bootstrap` · `hydrateFromCloud` · `verifyAuthSession` · دورة إعادة
 *   الاتّصال) تُنادي `showLoginScreen()` في لحظات مختلفة حسب سرعة العدّاء
 *   وحالة الشبكة — فأي `hideLoginScreen()` مفردٍ قد يُنقَض بعد لحظة فتُقاس
 *   شجرةٌ ارتفاعها صفر. الشرط الحتميّ الوحيد هو **الأثر**: `#app-root` مرئيّ
 *   ويبقى مرئيّاً. فنُعيد الإخفاء في كل دورة حتى يثبت.
 *
 * (هذا يُغني عن انتظار «ظهور بطاقة الدخول» — فهو يفترض أنّ الإقلاع انتهى
 *  عند أوّل ظهور، وليس كذلك حين تتأخّر دورة لاتزامنيّة أخرى.)
 */
export async function enterApp(page, { timeout = 20000, stableMs = 600 } = {}) {
  await page.waitForFunction(() => typeof window.hideLoginScreen === 'function', { timeout });
  await page.waitForFunction((ms) => {
    const app = document.getElementById('app-root');
    if (!app) return false;
    try { window.hideLoginScreen(); } catch (_) {}
    if (getComputedStyle(app).display === 'none') { window.__appVisibleSince = 0; return false; }
    if (!window.__appVisibleSince) { window.__appVisibleSince = Date.now(); return false; }
    return Date.now() - window.__appVisibleSince >= ms;
  }, stableMs, { timeout, polling: 100 });
  /* ⚠️ وإنهاء الترطيب: بقطع الشبكة يستقرّ على `offline` فيبقى **الهيكل النابض**
     (`body.data-loading`) وشريط «تعذّر الاتصال» يتحرّكان بلا توقّف — فأي
     `locator.screenshot` ينتظر «استقرار العنصر» إلى أن تنقضي مهلته (مُقاس:
     `pr-items-rows` سقط بـTimeout بعد قطع الشبكة وحده). وهو ليس موضوع أي فحص
     هنا: الحالة تُبذَر محليّاً، فالترطيب ضجيج. */
  await page.evaluate(() => {
    try { window.hydSettle('ready'); } catch (_) {}
    try { document.body.classList.remove('data-loading'); } catch (_) {}
    try { document.getElementById('hyd-bar')?.classList.remove('show'); } catch (_) {}
  });
}

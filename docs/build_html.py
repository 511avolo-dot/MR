# -*- coding: utf-8 -*-
"""نسخة HTML من العرض التنفيذي — RTL، ملف واحد مستقل، صالح للعرض والطباعة PDF."""
import os, html

AX = [
    ("أولاً: تنظيم الطلبات والدورة المستندية", [
        ("طلبات عبر البريد والواتساب بصفة «عاجل» دون نموذج رسمي.",
         "غياب الالتزام والتتبّع وإرباك التنفيذ.",
         "نموذج طلب شراء موحّد إلزامي موقّع من صاحب الصلاحية؛ ولا يُعتدّ بأي طلب خارجه."),
        ("الإفراط في وصف الطلبات بالعاجل وأغلبها لا يُستكمل بأمر شراء.",
         "فتور استجابة الموردين وارتفاع الأسعار.",
         "قصر «العاجل» على ما يعتمده مدير الإدارة الطالبة خطياً بمبرّر، مع سقف عددي."),
        ("طلبات تبقى معلّقة دون اعتماد أو تحويل للمورد لفترات طويلة.",
         "تأخّر التوريد وتعطّل الأعمال.",
         "مدة معيارية للبتّ (٣ أيام عمل)، ولوحة متابعة بحالة كل طلب، وإغلاق المنتفي."),
        ("غموض في الدورة المستندية ومن يوقّع ومن يعتمد.",
         "عشوائية وتأخير وتكرار للإجراءات.",
         "دورة مستندية موثّقة، ومصفوفة صلاحيات تحدّد الموقّع والمعتمِد لكل قيمة."),
        ("طلبات بمواصفات ناقصة وتشتّت قنوات المستندات.",
         "أخطاء في التوريد وإعادة عمل.",
         "إلزام إرفاق صورة البند أو اسم العلامة التجارية، واعتماد قناة رسمية واحدة."),
    ]),
    ("ثانياً: ازدواجية التوريد والشراء المباشر", [
        ("تُكلَّف المشتريات بالتوريد ثم يتبيّن أن الصيانة وردّت الصنف من مورد أجل.",
         "التزام مالي مزدوج وإرباك المورد وإهدار الجهد.",
         "إشعار فوري عند انتفاء الحاجة، ومنع أي توريد موازٍ بعد إصدار أمر الشراء."),
        ("تنفيذ عمليات شراء مباشرة خارج إدارة المشتريات.",
         "فقدان الرقابة وضعف التفاوض وتعدّد قنوات المورد.",
         "حصر كل شراء وتوريد لقطاعات المجموعة عبر المشتريات حصراً بقرار من الإدارة العليا."),
        ("التعامل مع موردين بعينهم والشراء منهم مباشرة دون الرجوع للمشتريات.",
         "ازدواج الحسابات وصعوبة التدقيق.",
         "إدراجهم ضمن قائمة موردين معتمدة موحّدة تُدار عبر المشتريات."),
        ("عدم ربط الطلب برصيد المستودع قبل الشراء.",
         "شراء أصناف متوفّرة أصلاً في المخزون.",
         "جعل فحص رصيد المستودع خطوة إلزامية قبل أي طلب شراء."),
    ]),
    ("رابعاً: التسعير وسجل الأسعار المرجعي", [
        ("إعادة تسعير البنود نفسها لكل مشروع رغم التزويد بالأسعار سابقاً.",
         "إهدار الوقت وتفاوت سعر الصنف الواحد.",
         "إنشاء سجل أسعار مرجعي موحّد يُرجَع إليه قبل أي استفسار من المورد."),
        ("لا يوجد تاريخ لأسعار المواد رغم الشراء المستمر.",
         "غياب مرجع للمقارنة والرقابة على الأسعار.",
         "تغذية السجل آلياً من فواتير الشراء في النظام المالي وتحديثه دورياً."),
        ("تسعير منافسات المشاريع تحت ضغط وقت غير كافٍ.",
         "أسعار غير دقيقة وضياع فرص التقديم.",
         "تحديد مدة معيارية كافية لتسعير المنافسات تُتّفق عليها مسبقاً."),
        ("تكرار مخاطبة الموردين لكل تسعيرة جديدة.",
         "استهلاك علاقة المورد بكثرة طلبات التسعير.",
         "الرجوع للسجل أولاً، ثم تحديث العروض للبنود المتغيّرة فقط."),
    ]),
    ("خامساً: الموردون والعلاقات التجارية", [
        ("تآكل مصداقية طلباتنا لدى الموردين وفتور تجاوبهم.",
         "تراجع الاستجابة وجودة العروض.",
         "ضبط صفة «العاجل» والالتزام بإغلاق الطلبات يعيدان جدية الموردين."),
        ("الطلبات الشهرية المتكررة وكبيرة الحجم بلا عقود.",
         "أسعار متذبذبة وتفاوض متكرّر.",
         "إبرام عقود إطارية سنوية بأسعار ثابتة مع الموردين الرئيسيين."),
        ("الطلبات المستديمة لقطاعات المجموعة تُسعّر كل مرة.",
         "بطء متكرّر في التوريد.",
         "توفير ثلاثة عروض للمرة الأولى فقط، ثم اعتماد مورد ثابت."),
        ("مشاكل مع الموردين موزّعة على إدارات متعددة.",
         "تضارب وتكرار في معالجة المشاكل.",
         "تسليم المشتريات حصراً بالمشاكل القائمة والشخص المسؤول لتوحيد التعامل."),
        ("مديونيات على الصيانة والتشغيل لدى الموردين.",
         "مخاطر ائتمانية وتعليق توريد.",
         "تسليم المشتريات كشف حساب بالمديونية لتسويتها ضمن خطة."),
    ]),
    ("سادساً: تنظيم العلاقة مع الصيانة والتشغيل", [
        ("غياب إطار منظّم للعلاقة بين الإدارتين.",
         "تداخل المسؤوليات والاحتكاك.",
         "اتفاقية تنظيمية تحدّد المسارات: العادية والعاجلة والموردون ومقاولو الباطن."),
        ("لا توجد جهة تنسيق واحدة من الصيانة والتشغيل.",
         "تشتّت التواصل وتعدّد المرجعيات.",
         "تعيين منسّق إداري من الصيانة على دراية بآلية المشتريات."),
        ("مشرفو الشراء بالموقع خارج مظلة المشتريات.",
         "شراء ميداني غير منضبط.",
         "جعل مشرفي الشراء في المواقع تابعين إشرافياً لإدارة المشتريات."),
        ("اختلاف آلية التعامل حسب نوع الطلب.",
         "ارتباك في التنفيذ وتأخير.",
         "توضيح آلية موحّدة لكل نوع طلب يلتزم بها الطرفان."),
    ]),
    ("سابعاً: العهد والموارد التشغيلية", [
        ("عهدة قصر الياسمين مسجّلة على مندوب المشتريات رغم أن الشراء عبر المشروع.",
         "عدم تطابق المسؤولية مع المنفّذ.",
         "نقل العهدة إلى مسؤول المشروع باعتباره المنفّذ الفعلي للشراء."),
        ("طلبات البنية التحتية أسبوعية صغيرة متكررة وليست تحت سقف مورد واحد.",
         "تأخّر احتياجات متكررة منخفضة القيمة.",
         "اعتمادها دون عروض ضمن سقف محدّد ومورد إطاري."),
        ("لا توجد عهدة نقدية لدى المشتريات للحالات الصغيرة العاجلة.",
         "بطء تنفيذ البنود البسيطة.",
         "تخصيص عهدة مالية مستديمة للمشتريات باعتماد مديرها."),
        ("لا توجد وسيلة توريد مخصّصة للمواقع.",
         "تأخّر التسليم والاعتماد على الغير.",
         "تعيين سائق تابع لإدارة المشتريات لتوريد الطلبات إلى المواقع."),
    ]),
    ("ثامناً: التكامل مع الإدارة المالية", [
        ("بطء استجابة الإدارة المالية لتحويلات الموردين.",
         "تعطّل الموردين وتحميل المشتريات تبعة التأخير.",
         "التزام زمني للتحويل (٣–٥ أيام عمل، و٢٤ ساعة للطوارئ) ودفعات أسبوعية مجمّعة."),
        ("عدم تغذية سجل الأسعار من النظام المالي.",
         "استمرار تكرار التسعير وغياب المرجع.",
         "ربط فواتير الشراء بسجل الأسعار آلياً لتغذيته أولاً بأول."),
        ("غياب مسار طوارئ مالي محكوم.",
         "استخدام صفة «العاجل» للالتفاف على الإجراءات.",
         "اعتماد مسار طوارئ بموافقة مسبقة موثّقة وسقف محدّد."),
    ]),
]

MATRIX = [
    ("الشريحة الأولى", "حتى ٥٬٠٠٠ ريال", "مدير المشتريات", "دون عروض، ضمن السقف", "g"),
    ("الشريحة الثانية", "حتى ٢٥٬٠٠٠ ريال", "مدير المشتريات", "عرضان كحد أدنى", "g"),
    ("الشريحة الثالثة", "حتى ١٠٠٬٠٠٠ ريال", "المشتريات والمالية", "ثلاثة عروض ومقارنة", "a"),
    ("الشريحة الرابعة", "أكثر من ١٠٠٬٠٠٠", "المدير العام ولجنة", "ثلاثة عروض وتفاوض", "r"),
    ("مسار الطوارئ", "حالات حرجة فعلاً", "موافقة مسبقة موثّقة", "سقف محدّد مع تبرير", "i"),
]

FLOW = ["نشوء الاحتياج", "طلب شراء رسمي بالمواصفات", "فحص رصيد المستودع",
        "الرجوع لسجل الأسعار", "عروض ومقارنة عند اللزوم", "الاعتماد حسب الصلاحية",
        "إصدار أمر الشراء", "التحويل المالي ضمن المدة", "التوريد والاستلام والمطابقة",
        "الإغلاق وتحديث سجل الأسعار"]

ASKS = [
    "حصر كل شراء وتوريد لقطاعات المجموعة عبر المشتريات حصراً.",
    "اعتماد النموذج الموحّد للطلبات ومصفوفة الصلاحيات.",
    "إلزام الإدارة المالية بمدة زمنية للتحويل ومسار طوارئ.",
    "إنشاء سجل أسعار مرجعي يُغذّى من النظام المالي.",
    "تفويض إبرام عقود إطارية للطلبات المتكررة والبنية التحتية.",
    "نقل عهدة قصر الياسمين إلى مسؤول المشروع.",
    "تخصيص عهدة مالية وسائق لإدارة المشتريات.",
    "اعتماد خارطة الطريق ومؤشرات الأداء.",
]

ROADMAP = [
    ("أول ٣٠ يوماً", "تثبيت الحوكمة", ["النموذج الموحّد للطلبات", "مصفوفة الصلاحيات بقيمها",
        "حصر الشراء عبر المشتريات", "التزام المالية الزمني", "إيقاف ازدواجية التوريد"]),
    ("حتى ٩٠ يوماً", "البناء المؤسسي", ["سجل الأسعار من المالية", "العقود الإطارية للمتكرر",
        "عهدة وسائق للمشتريات", "معالجة قصر الياسمين والبنية التحتية", "تعيين منسّق الصيانة"]),
    ("المدى البعيد", "الاستدامة والتميّز", ["نظام مشتريات موحّد", "لوحات متابعة الأداء",
        "تقييم دوري للموردين", "تطوير استراتيجية التوريد"]),
]

KPIS = [
    ("زمن دورة الشراء", "من الطلب حتى أمر الشراء", "تقليصه إلى النصف"),
    ("التزام الطلبات بالدورة", "نسبة الطلبات الرسمية", "لا تقل عن ٩٥٪"),
    ("إغلاق الطلبات في وقتها", "دون معلّقات متراكمة", "لا معلّقات متأخرة"),
    ("الوفر المحقّق", "مقارنةً بسجل الأسعار", "يُقاس كل ربع سنة"),
    ("التزام المالية بالتحويل", "ضمن المدة المعتمدة", "لا تقل عن ٩٠٪"),
    ("استجابة الموردين", "نسبة الرد على العروض", "اتجاه متصاعد"),
]

e = html.escape

def axis_html(title, rows):
    trs = "".join(
        f"<tr><td class='prob'>{e(p)}</td><td class='eff'>{e(ef)}</td><td class='sol'>{e(so)}</td></tr>"
        for p, ef, so in rows)
    return f"""<section class="slide">
  <div class="band">{e(title)}</div>
  <table class="sol">
    <thead><tr><th>المشكلة / الوضع الحالي</th><th>الأثر على العمل</th><th>الحل المقترح</th></tr></thead>
    <tbody>{trs}</tbody>
  </table>
</section>"""

def build():
    cls = {"g": "lvl-g", "a": "lvl-a", "r": "lvl-r", "i": "lvl-i"}
    matrix_cards = "".join(
        f"""<div class="mcard {cls[c]}">
              <div class="mh">{e(t)}</div>
              <div class="mv">{e(v)}</div>
              <div class="ml">المعتمِد</div><div class="md">{e(w)}</div>
              <div class="ml">الإجراء</div><div class="md">{e(n)}</div>
            </div>""" for t, v, w, n, c in MATRIX)
    flow_steps = "".join(
        f"<div class='step{' key' if i in (2,3,5) else ''}'>{e(s)}</div>"
        + ("<div class='arr'>◀</div>" if i < len(FLOW)-1 else "")
        for i, s in enumerate(FLOW))
    asks = "".join(f"<div class='ask'><span class='n'>{i+1}</span>{e(a)}</div>"
                   for i, a in enumerate(ASKS))
    road = "".join(
        f"""<div class="phase">
              <div class="ph">{e(t)}<small>{e(s)}</small></div>
              <ul>{''.join(f'<li>{e(x)}</li>' for x in items)}</ul>
            </div>""" for t, s, items in ROADMAP)
    kpis = "".join(
        f"""<div class="kpi"><div class="kh">{e(t)}</div>
            <div class="kd">{e(d)}</div><div class="kt">{e(g)}</div></div>"""
        for t, d, g in KPIS)
    axes = "".join(axis_html(t, r) for t, r in AX)

    return f"""<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>تطوير وحوكمة منظومة المشتريات — مجموعة الذيابي</title>
<style>
:root{{--ink:#0E2A38;--ink2:#143A4C;--gold:#C9A24B;--sand:#F6F3ED;--line:#DDD4C2;
--slate:#3A4650;--mute:#6B747C;--red:#9E2B25;--amber:#C57A0C;--green:#2E6B3E;--card:#fff}}
*{{box-sizing:border-box}}
body{{margin:0;background:#e9e4d8;color:var(--slate);
font-family:"Segoe UI","Tahoma","Geeza Pro","Noto Naskh Arabic","Arial",sans-serif;line-height:1.7}}
.wrap{{max-width:1000px;margin:0 auto;padding:18px}}
.slide{{background:var(--sand);border:1px solid var(--line);border-radius:14px;
padding:26px 24px;margin:18px 0;box-shadow:0 4px 18px rgba(14,42,56,.08)}}
.cover{{background:var(--ink);color:#fff;text-align:center;padding:54px 26px;border:none}}
.cover .br{{color:var(--gold);font-weight:700;letter-spacing:1px}}
.cover h1{{font-size:34px;margin:14px 0 8px}}
.cover .sub{{color:var(--gold);font-size:18px}}
.cover .meta{{margin-top:26px;border-top:3px solid var(--gold);padding-top:18px;font-size:15px;color:#eee}}
.band{{background:var(--ink);color:#fff;font-weight:700;font-size:20px;
padding:12px 16px;border-radius:10px;border-right:6px solid var(--gold);margin-bottom:16px}}
h2.t{{color:var(--ink);font-size:24px;margin:4px 0 2px}}
.kick{{color:var(--gold);font-weight:700;margin-bottom:12px}}
table.sol{{width:100%;border-collapse:collapse;font-size:15px;overflow:hidden;border-radius:10px}}
table.sol th{{background:var(--ink);color:#fff;padding:11px 10px;font-size:15px}}
table.sol td{{padding:11px 12px;border-bottom:1px solid var(--line);vertical-align:middle}}
table.sol tr:nth-child(even) td{{background:#efeadf}}
table.sol tr:nth-child(odd) td{{background:#fff}}
.prob{{color:var(--ink);font-weight:700;width:40%}}
.eff{{color:var(--slate);width:26%}}
.sol{{color:var(--green);font-weight:600;width:34%}}
.decision{{background:var(--ink2);color:#fff;border-right:6px solid var(--gold);
padding:12px 16px;border-radius:10px;margin-top:16px}}
.decision b{{color:var(--gold);display:block;font-size:13px;margin-bottom:3px}}
.cards{{display:grid;grid-template-columns:1fr 1fr;gap:14px}}
.cards .c{{background:#fff;border:1px solid var(--line);border-radius:10px;
padding:14px;border-right:7px solid var(--gold)}}
.cards .c h3{{margin:0 0 6px;color:var(--ink)}}
.matrix{{display:grid;grid-template-columns:repeat(5,1fr);gap:10px}}
.mcard{{background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden;text-align:center}}
.mcard .mh{{color:#fff;font-weight:700;padding:8px}}
.mcard.lvl-g .mh{{background:var(--green)}} .mcard.lvl-a .mh{{background:var(--amber)}}
.mcard.lvl-r .mh{{background:var(--red)}} .mcard.lvl-i .mh{{background:var(--ink)}}
.mcard .mv{{font-weight:700;color:var(--ink);padding:8px 6px 4px}}
.mcard .ml{{color:var(--gold);font-weight:700;font-size:12px;margin-top:6px}}
.mcard .md{{font-size:13px;padding:0 6px}}
.flow{{display:flex;flex-wrap:wrap;gap:8px;align-items:center;justify-content:flex-start}}
.step{{background:var(--ink);color:#fff;border-radius:10px;padding:12px 10px;
font-weight:700;font-size:14px;flex:1 1 160px;text-align:center;min-width:140px}}
.step.key{{background:var(--gold);color:var(--ink)}}
.arr{{color:var(--mute);font-weight:700}}
.asks{{display:grid;grid-template-columns:1fr 1fr;gap:12px}}
.ask{{background:#fff;border:1px solid var(--line);border-radius:10px;padding:12px 14px;
font-weight:700;color:var(--ink);display:flex;align-items:center;gap:10px}}
.ask .n{{background:var(--green);color:#fff;width:34px;height:34px;border-radius:8px;
display:flex;align-items:center;justify-content:center;font-size:18px;flex:none}}
.road{{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}}
.phase{{background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden}}
.phase .ph{{background:var(--ink);color:#fff;padding:12px;font-weight:700;font-size:18px;text-align:center}}
.phase .ph small{{display:block;color:var(--sand);font-weight:400;font-size:13px;margin-top:2px}}
.phase ul{{margin:10px 14px;padding:0 16px 6px}}
.phase li{{margin:6px 0}}
.kpis{{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}}
.kpi{{background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden;text-align:center}}
.kpi .kh{{background:var(--ink);color:#fff;font-weight:700;padding:9px}}
.kpi .kd{{padding:8px;color:var(--slate)}}
.kpi .kt{{color:var(--green);font-weight:700;padding-bottom:10px}}
.heat{{display:grid;grid-template-columns:1fr 1fr;gap:10px}}
.hrow{{background:#fff;border:1px solid var(--line);border-radius:8px;padding:10px 12px;
display:flex;justify-content:space-between;align-items:center;font-weight:700;color:var(--ink)}}
.tag{{color:#fff;border-radius:6px;padding:3px 10px;font-size:13px}}
.tag.r{{background:var(--red)}} .tag.a{{background:var(--amber)}} .tag.g{{background:var(--green)}}
@media(max-width:760px){{.cards,.asks,.road,.kpis,.heat{{grid-template-columns:1fr}}
.matrix{{grid-template-columns:1fr 1fr}} .cover h1{{font-size:26px}}
table.sol{{font-size:13px}} .step{{flex-basis:120px}}}}
@media print{{body{{background:#fff}} .slide{{page-break-inside:avoid;box-shadow:none}}}}
</style></head><body><div class="wrap">

<section class="slide cover">
  <div class="br">مجموعة الذيابي للمقاولات</div>
  <h1>تطوير وحوكمة منظومة المشتريات وسلسلة الإمداد</h1>
  <div class="sub">تشخيص الوضع الراهن — وحلول عملية لكل تحدٍّ — وخارطة طريق للاعتماد</div>
  <div class="meta">وثيقة قرار تنفيذية مرفوعة إلى سعادة المدير العام والإدارة العليا<br>
  إعداد: إدارة العمليات والمشتريات</div>
</section>

<section class="slide"><h2 class="t">السياق والهدف</h2><div class="kick">لماذا الآن؟</div>
<ul>
<li><b>إدارة المشتريات هي القلب الذي يربط المشاريع والصيانة والمالية والمستودعات والموردين</b>، وأي خلل في تنظيمها ينعكس على الجميع.</li>
<li>تراكمت ملاحظات متكرّرة تؤثر على كفاءة الإنفاق وانتظام التوريد وعلاقتنا بالموردين.</li>
<li>الهدف ليس تحميل أي إدارة اللوم، بل وضع سياسات ثابتة ومُلزِمة تحمي مصلحة الشركة.</li>
<li>المسار: مناقشة النقاط مع الإدارات ذات العلاقة، ثم رفعها للإدارة العليا لاعتماد القرار المناسب لكل بند.</li>
</ul>
<div class="decision"><b>القرار / السياسة المطلوبة</b>اعتماد هذه الوثيقة أساساً للنقاش المؤسسي ثم إقرار سياسة ثابتة لكل بند فيها.</div></section>

<section class="slide"><h2 class="t">الملخص التنفيذي</h2><div class="kick">الصورة الكاملة في صفحة واحدة</div>
<div class="cards">
<div class="c"><h3>جوهر المشكلة</h3>غياب دورة مستندية مُلزِمة وقناة موحّدة للطلبات وصلاحيات واضحة وسجل أسعار مرجعي.</div>
<div class="c"><h3>الأثر</h3>ازدواج في الإنفاق، وتأخّر في التوريد، وتآكل في ثقة الموردين، وضعف في الرقابة على التكلفة.</div>
<div class="c"><h3>الحل</h3>مأسسة المشتريات: قناة واحدة إلزامية ودورة موثّقة ومصفوفة صلاحيات وسجل أسعار وعقود إطارية.</div>
<div class="c"><h3>المطلوب</h3>إقرار السياسات الثابتة وخارطة الطريق (٣٠ يوماً / ٩٠ يوماً / المدى البعيد).</div>
</div></section>

<section class="slide"><h2 class="t">لوحة التحديات المرصودة</h2><div class="kick">مصنّفة حسب درجة الأثر</div>
<div class="heat">
<div class="hrow"><span>ازدواجية التوريد</span><span class="tag r">حرج</span></div>
<div class="hrow"><span>الشراء المباشر خارج المشتريات</span><span class="tag r">حرج</span></div>
<div class="hrow"><span>بطء التحويل المالي للموردين</span><span class="tag r">حرج</span></div>
<div class="hrow"><span>الإفراط في «العاجل» وتآكل الثقة</span><span class="tag a">مرتفع</span></div>
<div class="hrow"><span>الطلبات المعلّقة دون إجراء</span><span class="tag a">مرتفع</span></div>
<div class="hrow"><span>تكرار التسعير وغياب سجل الأسعار</span><span class="tag a">مرتفع</span></div>
<div class="hrow"><span>غياب الصلاحيات والدورة المستندية</span><span class="tag a">مرتفع</span></div>
<div class="hrow"><span>عهدة قصر الياسمين</span><span class="tag g">متوسط</span></div>
<div class="hrow"><span>طلبات البنية التحتية المتكررة</span><span class="tag g">متوسط</span></div>
<div class="hrow"><span>غياب العقود الإطارية</span><span class="tag g">متوسط</span></div>
</div></section>

{axes}

<section class="slide"><h2 class="t">مصفوفة الصلاحيات والاعتماد</h2><div class="kick">أرقام مقترحة قابلة للاعتماد</div>
<div class="matrix">{matrix_cards}</div>
<div class="decision"><b>القرار / السياسة المطلوبة</b>إقرار حد أدنى (٥٬٠٠٠ ريال) يُشترى باعتماد مدير المشتريات دون عروض، واعتماد بقية الشرائح.</div></section>

<section class="slide"><h2 class="t">خريطة الدورة المستندية الموحّدة</h2><div class="kick">مسار واحد إلزامي من الاحتياج حتى الإغلاق</div>
<div class="flow">{flow_steps}</div>
<div class="decision"><b>القرار / السياسة المطلوبة</b>منع أي توريد خارج هذا المسار، ووقف أي توريد موازٍ بعد إصدار أمر الشراء.</div></section>

<section class="slide"><h2 class="t">نموذج الحوكمة المقترح</h2><div class="kick">المشتريات قناة واحدة محكومة بأربع ركائز</div>
<div class="cards" style="grid-template-columns:repeat(4,1fr)">
<div class="c">دورة مستندية موثّقة</div><div class="c">مصفوفة صلاحيات</div>
<div class="c">سجل أسعار مرجعي</div><div class="c">قائمة موردين معتمدة</div></div>
<p style="text-align:center;margin-top:14px;color:var(--ink);font-weight:700">
الإدارة العليا ← إدارة المشتريات (القناة الموحّدة) ← الإدارات الطالبة / المالية / المستودعات / الموردون</p>
</section>

<section class="slide"><h2 class="t">خارطة طريق التنفيذ</h2><div class="kick">مراحل زمنية واضحة وقابلة للقياس</div>
<div class="road">{road}</div></section>

<section class="slide"><h2 class="t">مؤشرات قياس النجاح</h2><div class="kick">ما لا يُقاس لا يُمكن تطويره</div>
<div class="kpis">{kpis}</div></section>

<section class="slide"><h2 class="t">القرارات المطلوبة من الإدارة العليا</h2><div class="kick">ثمانية قرارات تُنهي التكرار</div>
<div class="asks">{asks}</div></section>

<section class="slide cover">
<h1 style="font-size:28px">الحوكمة ليست قيداً على العمل، بل ضمانة استمراره وكفاءته</h1>
<div class="sub">لسنا بصدد معالجة أخطاء فردية، بل تأسيس منظومة تحمي مال الشركة وتنظّم توريدها وتعيد لها ثقة موردِيها</div>
<div class="meta">وفريق المشتريات على أتم الاستعداد للتنفيذ فور اعتماد القرارات<br>
مع وافر الاحترام والتقدير — إدارة العمليات والمشتريات</div>
</section>

</div></body></html>"""

out = os.path.join(os.path.dirname(__file__), 'procurement-executive-deck.html')
open(out, 'w', encoding='utf-8').write(build())
print('Saved', out, os.path.getsize(out), 'bytes')

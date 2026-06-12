# -*- coding: utf-8 -*-
"""نسخة HTML مبسّطة — عمودان (الوضع ← المعالجة)، خط Neo Sans Arabic، ثلاثة أجزاء."""
import os, html

AXES = [
    ("أولاً: تنظيم الطلبات", [
        ("طلبات بالبريد والواتساب بصفة «عاجل» بلا نموذج", "نموذج طلب رسمي موحّد موقّع، ولا يُعتدّ بغيره"),
        ("الإفراط في «عاجل» وأغلبه لا يُنفّذ", "«عاجل» باعتماد خطّي مبرّر وسقف شهري"),
        ("طلبات معلّقة دون إجراء", "مدة بتّ ٣ أيام، ولوحة متابعة، وإغلاق المنتفي"),
        ("غموض الدورة ومن يعتمد", "دورة موثّقة ومصفوفة صلاحيات"),
        ("مواصفات ناقصة وقنوات متفرّقة", "إرفاق صورة/علامة تجارية، وقناة رسمية واحدة"),
    ]),
    ("ثانياً: ازدواجية التوريد والشراء المباشر", [
        ("المشتريات تُورّد صنفاً ورّدته الصيانة", "إشعار فوري بالاكتفاء، ومنع توريد موازٍ بعد أمر الشراء"),
        ("شراء مباشر خارج المشتريات", "كل شراء وتوريد عبر المشتريات حصراً"),
        ("شراء من موردين بعينهم دون رجوع", "إدراجهم في قائمة معتمدة تُدار مركزياً"),
        ("شراء صنف متوفّر بالمخزون", "فحص المستودع إلزامي قبل الطلب"),
    ]),
    ("ثالثاً: تسعير المناقصات وسجل الأسعار", [
        ("إعادة تجميع الأسعار لكل مناقصة", "سجل أسعار مرجعي للمناقصات فقط"),
        ("لا تاريخ لأسعار المواد", "تغذية السجل آلياً من النظام المالي"),
        ("تسعير المناقصات بوقت ضيّق", "تخصيص مدة كافية متّفق عليها"),
        ("الخلط بين السجل وعروض الشراء", "الشراء دائماً بثلاثة عروض، والسجل للمناقصات فقط"),
    ]),
    ("رابعاً: الموردون والعلاقات", [
        ("تآكل ثقة الموردين بطلباتنا", "ضبط «العاجل» والالتزام بإغلاق الطلبات"),
        ("طلبات شهرية متكررة بلا عقود", "عقود إطارية سنوية بأسعار ثابتة"),
        ("الطلبات المستديمة تُسعّر كل مرة", "ثلاثة عروض أول مرة ثم مورد ثابت بعقد"),
        ("مشاكل الموردين موزّعة على الإدارات", "حصرها لدى المشتريات لتوحيد التعامل"),
        ("مديونيات لدى الموردين", "كشف حساب للتسوية ضمن خطة"),
    ]),
    ("خامساً: العلاقة مع الصيانة والتشغيل", [
        ("لا إطار منظّم للعلاقة", "اتفاقية تحدّد المسارات الأربعة"),
        ("لا جهة تنسيق واحدة", "منسّق من الصيانة ملمّ بالمشتريات"),
        ("مشرفو الموقع خارج المظلة", "تبعيتهم للمشتريات إشرافياً"),
        ("آليات مختلفة لكل طلب", "آلية موحّدة لكل نوع طلب"),
    ]),
    ("سادساً: العهد والموارد", [
        ("عهدة قصر الياسمين على المندوب", "نقلها لمسؤول المشروع"),
        ("تعثّر طلبات البنية التحتية", "عقد إطاري وسقف محدّد"),
        ("لا عهدة نقدية للمشتريات", "عهدة مستديمة بضوابط صرف"),
        ("لا وسيلة توريد للمواقع", "سائق تابع للمشتريات"),
    ]),
    ("سابعاً: التكامل مع الإدارة المالية", [
        ("بطء التحويل للموردين", "مدة ملزمة (٣–٥ أيام) ودفعات أسبوعية"),
        ("لا تغذية لسجل المناقصات", "ربطه بفواتير النظام المالي"),
        ("لا مسار طوارئ محكوم", "مسار بموافقة مسبقة وسقف محدّد"),
    ]),
]

POLICIES = [
    ("القناة الموحّدة", "كل شراء عبر المشتريات حصراً"),
    ("ثلاثة عروض إلزامية", "لأي شراء مهما كان حجمه"),
    ("مصفوفة الصلاحيات", "الاعتماد حسب القيمة"),
    ("الدورة المستندية", "مسار موحّد من الاحتياج للإغلاق"),
    ("اعتماد الموردين", "قائمة معتمدة وتقييم دوري"),
    ("العقود الإطارية", "للطلبات المتكررة والمستديمة"),
    ("سجل أسعار المناقصات", "للمناقصات فقط لا للشراء"),
    ("مسار الطوارئ", "بموافقة مسبقة موثّقة"),
    ("عهدة المشتريات", "عهدة مستديمة بضوابط"),
    ("الاستثناءات الموثّقة", "النثريات والبنية التحتية بسقف"),
    ("المطابقة قبل الصرف", "طلب وأمر وفاتورة واستلام"),
    ("النزاهة والتوثيق", "سرية العروض وأرشفة كاملة"),
]

PROC = [
    ("١) الاحتياج", "تعبئة طلب الشراء", "الطالبة"),
    ("٢) التسجيل", "ترقيم ومراجعة الطلب", "المشتريات"),
    ("٣) فحص المخزون", "التأكد من عدم توفّره", "المستودعات"),
    ("٤) طلب العروض", "مخاطبة ثلاثة موردين", "المشتريات"),
    ("٥) المقارنة", "جدول مفاضلة", "المشتريات"),
    ("٦) التوصية", "ترشيح الأنسب", "المشتريات"),
    ("٧) الاعتماد", "الموافقة بالصلاحية", "صاحب الصلاحية"),
    ("٨) أمر الشراء", "إصدار أمر الشراء", "المشتريات"),
    ("٩) الإشعار", "إشعار المورد", "المشتريات"),
    ("١٠) التوريد", "متابعة التسليم", "المشتريات"),
    ("١١) الاستلام", "فحص المطابقة", "المستودعات"),
    ("١٢) المطابقة", "مطابقة المستندات", "المشتريات"),
    ("١٣) الصرف", "تحويل المستحق", "المالية"),
    ("١٤) الإغلاق", "إقفال وأرشفة", "المشتريات"),
]

FLOW = ["نشوء الاحتياج", "طلب رسمي بالمواصفات", "فحص المستودع", "طلب ثلاثة عروض",
        "المقارنة", "الاعتماد حسب الصلاحية", "أمر الشراء", "الاستلام والمطابقة",
        "الصرف للمورد", "الإغلاق"]

MATRIX = [
    ("المستوى الأول", "حتى 25,000 ريال", "مدير المشتريات", "g"),
    ("المستوى الثاني", "حتى 100,000 ريال", "المشتريات والمالية", "a"),
    ("المستوى الثالث", "حتى 500,000 ريال", "المدير العام", "r"),
    ("المستوى الرابع", "أكثر من 500,000 ريال", "المدير العام ولجنة", "i"),
]

ROADMAP = [
    ("أول ٣٠ يوماً", "g", ["النموذج الموحّد", "مصفوفة الصلاحيات", "حصر الشراء بالمشتريات", "التزام المالية الزمني"]),
    ("حتى ٩٠ يوماً", "a", ["سجل أسعار المناقصات", "العقود الإطارية", "عهدة وسائق للمشتريات", "معالجة الملفات العالقة"]),
    ("المدى البعيد", "i", ["نظام مشتريات موحّد", "لوحات متابعة", "تقييم الموردين", "استراتيجية التوريد"]),
]

KPIS = [
    ("زمن دورة الشراء", "تقليصه إلى النصف"), ("الالتزام بالدورة", "٩٥٪ فأكثر"),
    ("الالتزام بالعروض الثلاثة", "٩٥٪ فأكثر"), ("الطلبات المعلّقة", "إلى الصفر"),
    ("التزام المالية بالتحويل", "٩٠٪ فأكثر"), ("استجابة الموردين", "اتجاه متصاعد"),
]

ASKS = [
    "حصر كل شراء عبر المشتريات حصراً.",
    "اعتماد السياسات والدورة الكاملة.",
    "إقرار مصفوفة الصلاحيات والعروض الثلاثة.",
    "إلزام المالية بمدة التحويل.",
    "إنشاء سجل أسعار للمناقصات.",
    "تفويض العقود الإطارية.",
    "معالجة العهد وموارد المشتريات.",
    "اعتماد خارطة الطريق والمؤشرات.",
]

TILES = [
    ("53", "أمر شراء", "في السجل", "i"),
    ("405", "ألف ريال", "إجمالي قيمة الأوامر", "gold"),
    ("68٪", "طلبات متأخرة", "٣٦ من ٥٣", "r"),
    ("19", "يوم متوسط التأخير", "أقصى تأخير ٥٢ يوماً", "r"),
    ("42", "مورد", "٣٨ مستخدماً فعلياً", "i"),
    ("23٪", "لم تكتمل", "ملغاة أو قيد المراجعة", "a"),
]
STATUS = [("مُسلَّم", 38, "g"), ("قيد المراجعة", 7, "a"), ("ملغى", 5, "r"),
          ("مُسلَّم جزئياً", 2, "a"), ("قيد التوريد", 1, "i")]
PRIORITY = [("متوسط", 22, "i"), ("عالي", 18, "a"), ("عاجل", 13, "r")]
SECTORS = [("الصيانة والتشغيل", 27, "i"), ("الإنشاءات", 12, "a"),
           ("الإدارة العامة", 9, "g"), ("النقليات", 4, "gold")]
BIG3 = [("44٪", "من الطلبات المتأخرة", "سببها التحويل المالي", "r"),
        ("336", "يوم تأخير", "من أصل 688 بسبب المالية", "r"),
        ("15.6", "يوم متوسط", "زمن التوريد الكلي", "a")]

e = html.escape
clr = {"g": "g", "a": "a", "r": "r", "i": "i"}


def axis_html(title, rows):
    trs = "".join(f"<tr><td class='p'>{e(p)}</td><td class='s'>{e(s)}</td></tr>" for p, s in rows)
    return f"""<section class="slide"><div class="part">الجزء الأول · المشاكل ومعالجتها</div>
<div class="band">{e(title)}</div>
<table class="tc"><thead><tr><th class="hp">الوضع الحالي</th><th class="hs">المعالجة المقترحة</th></tr></thead>
<tbody>{trs}</tbody></table></section>"""


def build():
    axes = "".join(axis_html(t, r) for t, r in AXES)
    pols = "".join(f"<div class='pol'><h4>{e(t)}</h4><p>{e(d)}</p></div>" for t, d in POLICIES)
    proc = "".join(f"<tr><td class='st'>{e(a)}</td><td>{e(b)}</td><td class='ow'>{e(c)}</td></tr>" for a, b, c in PROC)
    flow = "".join(f"<div class='step{' key' if i in (3,4,5) else ''}'>{e(x)}</div>"
                   + ("<div class='arr'>◀</div>" if i < len(FLOW)-1 else "") for i, x in enumerate(FLOW))
    mat = "".join(f"<div class='mc {clr[c]}'><div class='mh'>{e(t)}</div><div class='mv'>{e(v)}</div><div class='mo'>{e(w)}</div></div>"
                  for t, v, w, c in MATRIX)
    road = "".join(f"<div class='ph {c}'><div class='pht'>{e(t)}</div><ul>{''.join(f'<li>{e(x)}</li>' for x in it)}</ul></div>"
                   for t, c, it in ROADMAP)
    kpis = "".join(f"<div class='kpi'><div class='kh'>{e(t)}</div><div class='kt'>{e(g)}</div></div>" for t, g in KPIS)
    asks = "".join(f"<div class='ask'><span class='n'>{i+1}</span>{e(a)}</div>" for i, a in enumerate(ASKS))
    tiles = "".join(f"<div class='tile {c}'><div class='big'>{e(b)}</div><div class='tl'>{e(l)}</div><div class='ts'>{e(s)}</div></div>"
                    for b, l, s, c in TILES)

    def bars(rows, mx):
        return "".join(
            f"<div class='br'><span class='bl'>{e(l)}</span>"
            f"<span class='bt'><span class='bf {c}' style='width:{round(100*v/mx)}%'>{v}</span></span></div>"
            for l, v, c in rows)
    big3 = "".join(f"<div class='tile {c}'><div class='big'>{e(b)}</div><div class='tl'>{e(l)}</div><div class='ts'>{e(s)}</div></div>"
                   for b, l, s, c in BIG3)

    return f"""<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>تطوير منظومة المشتريات — مجموعة الذيابي</title>
<style>
:root{{--ink:#0E2A38;--ink2:#143A4C;--gold:#C9A24B;--sand:#F6F3ED;--line:#DDD4C2;
--slate:#33404A;--mute:#6B747C;--red:#9E2B25;--amber:#C57A0C;--green:#2E6B3E}}
*{{box-sizing:border-box}}
body{{margin:0;background:#e9e4d8;color:var(--slate);
font-family:"Neo Sans Arabic","Segoe UI","Tahoma","Geeza Pro","Arial",sans-serif;line-height:1.7}}
.wrap{{max-width:980px;margin:0 auto;padding:18px}}
.slide{{background:var(--sand);border:1px solid var(--line);border-radius:14px;
padding:24px;margin:18px 0;box-shadow:0 4px 18px rgba(14,42,56,.08)}}
.cover{{background:var(--ink);color:#fff;text-align:center;padding:56px 26px;border:none}}
.cover .br{{color:var(--gold);font-weight:700}} .cover h1{{font-size:40px;margin:14px 0 10px}}
.cover .sub{{color:var(--gold);font-size:18px}} .cover .meta{{margin-top:26px;border-top:3px solid var(--gold);padding-top:18px;color:#eee}}
.part{{color:var(--gold);font-weight:700;font-size:13px;margin-bottom:6px}}
.band{{background:var(--ink);color:#fff;font-weight:700;font-size:22px;padding:12px 16px;
border-radius:10px;border-right:6px solid var(--gold);margin-bottom:16px}}
h2.t{{color:var(--ink);font-size:26px;margin:2px 0 14px}}
table.tc{{width:100%;border-collapse:collapse;font-size:16px;border-radius:10px;overflow:hidden}}
table.tc th{{padding:12px;color:#fff}} .hp{{background:var(--ink);width:50%}} .hs{{background:var(--green);width:50%}}
table.tc td{{padding:13px 14px;border-bottom:1px solid var(--line)}}
table.tc tr:nth-child(even) td{{background:#f1ece2}} table.tc tr:nth-child(odd) td{{background:#fff}}
.p{{color:var(--ink);font-weight:700}} .s{{color:var(--green);font-weight:600}}
table.pr{{width:100%;border-collapse:collapse;font-size:15px;border-radius:10px;overflow:hidden}}
table.pr th{{background:var(--ink);color:#fff;padding:10px}} table.pr td{{padding:9px 12px;border-bottom:1px solid var(--line)}}
table.pr tr:nth-child(even) td{{background:#f1ece2}} .st{{color:var(--ink);font-weight:700}} .ow{{text-align:center;color:var(--ink)}}
.agz{{display:flex;flex-direction:column;gap:14px}}
.ag{{display:flex;align-items:center;background:#fff;border:1px solid var(--line);border-radius:12px;overflow:hidden}}
.ag .num{{color:#fff;font-size:38px;font-weight:700;width:90px;text-align:center;padding:18px 0;flex:none}}
.ag.g .num{{background:var(--green)}} .ag.a .num{{background:var(--amber)}} .ag.i .num{{background:var(--ink)}}
.ag .tx{{padding:14px 18px}} .ag .tx h3{{margin:0 0 4px;color:var(--ink);font-size:22px}} .ag .tx p{{margin:0;color:var(--slate)}}
.cards{{display:grid;grid-template-columns:1fr 1fr;gap:14px}}
.cards .c{{background:#fff;border:1px solid var(--line);border-radius:12px;padding:16px;border-right:8px solid var(--gold)}}
.cards .c h3{{margin:0 0 6px;font-size:20px}} .c.red{{border-right-color:var(--red)}} .c.amber{{border-right-color:var(--amber)}}
.c.green{{border-right-color:var(--green)}} .c.ink{{border-right-color:var(--ink)}}
.pols{{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}}
.pol{{background:#fff;border:1px solid var(--line);border-radius:10px;padding:12px;border-right:6px solid var(--gold)}}
.pol h4{{margin:0 0 4px;color:var(--ink);font-size:16px}} .pol p{{margin:0;font-size:13px;color:var(--slate)}}
.flow{{display:flex;flex-wrap:wrap;gap:8px;align-items:center}}
.step{{background:var(--ink);color:#fff;border-radius:10px;padding:14px 10px;font-weight:700;
font-size:15px;flex:1 1 150px;text-align:center;min-width:130px}} .step.key{{background:var(--gold);color:var(--ink)}}
.arr{{color:var(--mute);font-weight:700}}
.matrix{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}}
.mc{{background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden;text-align:center}}
.mc .mh{{color:#fff;font-weight:700;padding:10px}} .mc.g .mh{{background:var(--green)}} .mc.a .mh{{background:var(--amber)}}
.mc.r .mh{{background:var(--red)}} .mc.i .mh{{background:var(--ink)}}
.mc .mv{{font-weight:700;color:var(--ink);font-size:18px;padding:12px 6px 4px}} .mc .mo{{padding:0 6px 12px;color:var(--slate)}}
.note{{background:var(--gold);color:var(--ink);font-weight:700;text-align:center;border-radius:10px;padding:12px;margin-top:14px}}
.sub2{{text-align:center;color:var(--slate);margin-top:10px;font-size:14px}}
.road{{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}}
.ph{{background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden}}
.pht{{color:#fff;font-weight:700;font-size:20px;text-align:center;padding:12px}}
.ph.g .pht{{background:var(--green)}} .ph.a .pht{{background:var(--amber)}} .ph.i .pht{{background:var(--ink)}}
.ph ul{{margin:10px 14px;padding:0 16px 8px}} .ph li{{margin:8px 0}}
.kpis{{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}}
.kpi{{background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden;text-align:center}}
.kpi .kh{{background:var(--ink);color:#fff;font-weight:700;padding:10px}} .kpi .kt{{color:var(--green);font-weight:700;font-size:20px;padding:14px}}
.asks{{display:grid;grid-template-columns:1fr 1fr;gap:12px}}
.ask{{background:#fff;border:1px solid var(--line);border-radius:10px;padding:14px;font-weight:700;color:var(--ink);display:flex;align-items:center;gap:12px}}
.ask .n{{background:var(--green);color:#fff;width:38px;height:38px;border-radius:8px;display:flex;align-items:center;justify-content:center;font-size:20px;flex:none}}
.heat{{display:grid;grid-template-columns:1fr 1fr;gap:10px}}
.hrow{{background:#fff;border:1px solid var(--line);border-radius:8px;padding:12px 14px;display:flex;justify-content:space-between;align-items:center;font-weight:700;color:var(--ink)}}
.tag{{color:#fff;border-radius:6px;padding:4px 12px}} .tag.r{{background:var(--red)}} .tag.a{{background:var(--amber)}} .tag.g{{background:var(--green)}}
.tiles{{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}}
.tile{{background:#fff;border:1px solid var(--line);border-radius:12px;padding:16px 10px;text-align:center;border-top:6px solid var(--gold)}}
.tile.r{{border-top-color:var(--red)}} .tile.a{{border-top-color:var(--amber)}} .tile.g{{border-top-color:var(--green)}}
.tile.i{{border-top-color:var(--ink)}} .tile.gold{{border-top-color:var(--gold)}}
.tile .big{{font-size:40px;font-weight:700;color:var(--ink)}} .tile.r .big{{color:var(--red)}} .tile.a .big{{color:var(--amber)}} .tile.gold .big{{color:var(--gold)}}
.tile .tl{{font-weight:700;color:var(--ink);margin-top:4px}} .tile .ts{{font-size:12px;color:var(--mute)}}
.chartbox{{margin-top:8px}} .chartbox h3{{color:var(--gold);font-size:16px;margin:14px 0 8px}}
.br{{display:flex;align-items:center;gap:10px;margin:9px 0}}
.bl{{width:130px;text-align:left;font-weight:700;color:var(--ink);flex:none;font-size:14px}}
.bt{{flex:1;background:#ece6da;border-radius:6px;overflow:hidden;direction:ltr}}
.bf{{display:block;text-align:right;color:#fff;font-weight:700;padding:6px 10px;border-radius:6px;font-size:14px;min-width:34px}}
.bf.g{{background:var(--green)}} .bf.a{{background:var(--amber)}} .bf.r{{background:var(--red)}} .bf.i{{background:var(--ink)}} .bf.gold{{background:var(--gold)}}
.urg{{background:#f7e9e7;border:1px solid var(--red);border-radius:10px;padding:14px;margin-top:14px}}
.urg b{{color:var(--red)}}
.src{{text-align:left;color:var(--mute);font-size:12px;margin-top:10px}}
.two{{display:grid;grid-template-columns:1fr 1fr;gap:24px}}
@media(max-width:760px){{.cards,.asks,.heat{{grid-template-columns:1fr}} .pols,.matrix,.road,.kpis{{grid-template-columns:1fr 1fr}}
table.tc{{font-size:14px}} .cover h1{{font-size:30px}}}}
@media print{{body{{background:#fff}} .slide{{page-break-inside:avoid;box-shadow:none}}}}
</style></head><body><div class="wrap">

<section class="slide cover"><div class="br">مجموعة الذيابي للمقاولات</div>
<h1>تطوير منظومة المشتريات</h1>
<div class="sub">المشاكل ومعالجتها · المنظومة المقترحة · المطلوب من الإدارة</div>
<div class="meta">مرفوع إلى سعادة المدير العام والإدارة العليا<br>إعداد: إدارة العمليات والمشتريات</div></section>

<section class="slide"><h2 class="t">محتوى العرض</h2>
<div class="agz">
<div class="ag g"><div class="num">١</div><div class="tx"><h3>المشاكل ومعالجتها</h3><p>سبعة محاور: كل مشكلة ومعالجتها المقترحة</p></div></div>
<div class="ag a"><div class="num">٢</div><div class="tx"><h3>المنظومة المقترحة</h3><p>السياسات · الدورة الكاملة · مصفوفة الصلاحيات</p></div></div>
<div class="ag i"><div class="num">٣</div><div class="tx"><h3>التنفيذ والقرار</h3><p>خارطة الطريق · مؤشرات النجاح · القرارات المطلوبة</p></div></div>
</div></section>

<section class="slide"><h2 class="t">الملخص التنفيذي</h2>
<div class="cards">
<div class="c red"><h3>المشكلة</h3>لا توجد قناة موحّدة ولا دورة مُلزِمة ولا صلاحيات واضحة للمشتريات.</div>
<div class="c amber"><h3>الأثر</h3>ازدواج إنفاق، وتأخّر توريد، وتآكل ثقة الموردين.</div>
<div class="c green"><h3>الحل</h3>قناة واحدة + دورة موثّقة + ثلاثة عروض لكل شراء + صلاحيات واضحة.</div>
<div class="c ink"><h3>المطلوب</h3>إقرار السياسات وخارطة الطريق من الإدارة العليا.</div>
</div></section>

<section class="slide"><h2 class="t">أبرز التحديات</h2>
<div class="heat">
<div class="hrow"><span>ازدواجية التوريد</span><span class="tag r">حرج</span></div>
<div class="hrow"><span>الشراء المباشر خارج المشتريات</span><span class="tag r">حرج</span></div>
<div class="hrow"><span>بطء التحويل المالي</span><span class="tag r">حرج</span></div>
<div class="hrow"><span>الإفراط في صفة «عاجل»</span><span class="tag a">مرتفع</span></div>
<div class="hrow"><span>الطلبات المعلّقة</span><span class="tag a">مرتفع</span></div>
<div class="hrow"><span>غياب الدورة والصلاحيات</span><span class="tag a">مرتفع</span></div>
<div class="hrow"><span>بطء تسعير المناقصات</span><span class="tag g">متوسط</span></div>
<div class="hrow"><span>عهدة قصر الياسمين</span><span class="tag g">متوسط</span></div>
</div></section>

<section class="slide"><div class="part">الجزء الأول · الوضع الراهن</div><h2 class="t">الوضع الراهن بالأرقام</h2>
<div class="tiles">{tiles}</div>
<div class="src">المصدر: نظام المشتريات — سجل أوامر الشراء (٥٣ أمراً)</div></section>

<section class="slide"><div class="part">الجزء الأول · الوضع الراهن</div><h2 class="t">حالة الأوامر والأولوية</h2>
<div class="two">
<div class="chartbox"><h3>حسب الحالة</h3>{bars(STATUS,38)}</div>
<div class="chartbox"><h3>حسب الأولوية</h3>{bars(PRIORITY,22)}
<div class="urg"><b>مفارقة «العاجل»:</b> من ١٣ طلباً «عاجلاً» تأخّر ٨ وأُلغي ١ — أي أن صفة العاجل لا تضمن السرعة.</div></div>
</div>
<div class="src">المصدر: نظام المشتريات — سجل أوامر الشراء (٥٣ أمراً)</div></section>

<section class="slide"><div class="part">الجزء الأول · الوضع الراهن</div><h2 class="t">أين يضيع الوقت؟ تشخيص التأخير</h2>
<div class="tiles">{big3}</div>
<div class="chartbox"><h3>أوامر الشراء حسب القطاع</h3>{bars(SECTORS,27)}</div>
<div class="src">نحو نصف أيام التأخير سببها التحويل المالي — المصدر: نظام المشتريات (٥٣ أمراً)</div></section>

{axes}

<section class="slide"><div class="part">الجزء الثاني · المنظومة المقترحة</div><h2 class="t">سياسات المشتريات الحاكمة</h2>
<div class="pols">{pols}</div></section>

<section class="slide"><div class="part">الجزء الثاني · المنظومة المقترحة</div><h2 class="t">الدورة الكاملة للمشتريات</h2>
<div class="flow">{flow}</div>
<div class="note">ثلاثة عروض إلزامية في كل دورة — ولا توريد خارج هذا المسار</div></section>

<section class="slide"><div class="part">الجزء الثاني · المنظومة المقترحة</div><h2 class="t">إجراءات الدورة — المرحلة والمسؤول</h2>
<table class="pr"><thead><tr><th>المرحلة</th><th>الإجراء</th><th>المسؤول</th></tr></thead><tbody>{proc}</tbody></table></section>

<section class="slide"><div class="part">الجزء الثاني · المنظومة المقترحة</div><h2 class="t">مصفوفة الصلاحيات</h2>
<div class="matrix">{mat}</div>
<div class="note">العروض الثلاثة قاعدة ثابتة في كل المستويات</div>
<div class="sub2">الاستثناءات (باعتماد مدير المشتريات): النثريات — البنية التحتية — المتعاقد عليه إطارياً — الطوارئ.</div></section>

<section class="slide"><div class="part">الجزء الثالث · التنفيذ والقرار</div><h2 class="t">خارطة الطريق</h2>
<div class="road">{road}</div></section>

<section class="slide"><div class="part">الجزء الثالث · التنفيذ والقرار</div><h2 class="t">مؤشرات النجاح</h2>
<div class="kpis">{kpis}</div></section>

<section class="slide"><div class="part">الجزء الثالث · التنفيذ والقرار</div><h2 class="t">القرارات المطلوبة</h2>
<div class="asks">{asks}</div></section>

<section class="slide cover"><h1 style="font-size:30px">منظومة واضحة تحمي المال وتنظّم التوريد</h1>
<div class="sub">وفريق المشتريات جاهز للتنفيذ فور الاعتماد</div>
<div class="meta">مع وافر الاحترام والتقدير — إدارة العمليات والمشتريات</div></section>

</div></body></html>"""


out = os.path.join(os.path.dirname(__file__), 'procurement-executive-deck.html')
open(out, 'w', encoding='utf-8').write(build())
print('Saved', out, os.path.getsize(out), 'bytes')

# -*- coding: utf-8 -*-
"""
عرض تنفيذي شامل لتطوير وحوكمة منظومة المشتريات — مجموعة الذيابي للمقاولات.
عربية مهنية خالصة (دون مصطلحات أجنبية)، يعالج كل المشاكل المرصودة بصيغة:
المشكلة ← الأثر ← الحل المقترح، ويقترح سياسات وإجراءات المشتريات ودورتها الداخلية الكاملة.
ملاحظة مبدئية: عروض الأسعار الثلاثة إلزامية لأي شراء مهما كان حجمه. وسجل الأسعار
أداة لتسعير المناقصات فقط، وليس بديلاً عن العروض ولا جزءاً من دورة الشراء.
"""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
import os

# ---------------- لوحة الألوان ----------------
INK = RGBColor(0x0E, 0x2A, 0x38)
INK2 = RGBColor(0x14, 0x3A, 0x4C)
GOLD = RGBColor(0xC9, 0xA2, 0x4B)
SAND = RGBColor(0xF6, 0xF3, 0xED)
CARD = RGBColor(0xFF, 0xFF, 0xFF)
LINE = RGBColor(0xDD, 0xD4, 0xC2)
SLATE = RGBColor(0x3A, 0x46, 0x50)
MUTE = RGBColor(0x6B, 0x74, 0x7C)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
RED = RGBColor(0x9E, 0x2B, 0x25)
AMBER = RGBColor(0xC5, 0x7A, 0x0C)
GREEN = RGBColor(0x2E, 0x6B, 0x3E)
ROWALT = RGBColor(0xEF, 0xEA, 0xDF)

F = "Arial"
prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
SW, SH = prs.slide_width, prs.slide_height
BLANK = prs.slide_layouts[6]


def rtl(p):
    p._p.get_or_add_pPr().set('rtl', '1')


def rect(s, l, t, w, h, fill, line=None, lw=1.0):
    sp = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, l, t, w, h)
    sp.shadow.inherit = False
    if fill is None:
        sp.fill.background()
    else:
        sp.fill.solid(); sp.fill.fore_color.rgb = fill
    if line is None:
        sp.line.fill.background()
    else:
        sp.line.color.rgb = line; sp.line.width = Pt(lw)
    return sp


def txt(s, l, t, w, h, lines, *, size=16, color=SLATE, bold=False,
        align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.TOP, is_rtl=True, space=6):
    tb = s.shapes.add_textbox(l, t, w, h); tf = tb.text_frame
    tf.word_wrap = True; tf.vertical_anchor = anchor
    tf.margin_left = tf.margin_right = Pt(6); tf.margin_top = tf.margin_bottom = Pt(3)
    if isinstance(lines, str):
        lines = [lines]
    for i, it in enumerate(lines):
        d = it if isinstance(it, dict) else {'t': it}
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        if is_rtl:
            rtl(p)
        p.alignment = d.get('align', align); p.space_after = Pt(d.get('space', space))
        r = p.add_run(); r.text = d['t']
        r.font.size = Pt(d.get('size', size)); r.font.bold = d.get('bold', bold)
        r.font.name = F; r.font.color.rgb = d.get('color', color)
    return tb


def bullets(s, l, t, w, h, items, size=15, gap=9, color=SLATE, mark="•  "):
    tb = s.shapes.add_textbox(l, t, w, h); tf = tb.text_frame; tf.word_wrap = True
    for i, it in enumerate(items):
        d = it if isinstance(it, dict) else {'t': it}
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        rtl(p); p.alignment = PP_ALIGN.RIGHT; p.space_after = Pt(gap)
        r = p.add_run(); r.text = mark + d['t']
        r.font.size = Pt(d.get('size', size)); r.font.bold = d.get('bold', False)
        r.font.name = F; r.font.color.rgb = d.get('color', color)
    return tb


def page(s, idx):
    txt(s, Inches(0.3), SH - Inches(0.46), Inches(2), Inches(0.32),
        f"{idx} / {TOTAL}", size=10, color=MUTE, align=PP_ALIGN.LEFT, is_rtl=False)


def brandbar(s, title, kicker):
    rect(s, 0, 0, SW, SH, SAND)
    rect(s, 0, 0, SW, Inches(1.18), INK)
    rect(s, 0, Inches(1.18), SW, Pt(4), GOLD)
    txt(s, SW - Inches(3.5), Inches(0.2), Inches(3.25), Inches(0.85),
        [{'t': 'مجموعة الذيابي للمقاولات', 'size': 14, 'color': GOLD, 'bold': True, 'space': 0},
         {'t': 'إدارة المشتريات وسلسلة الإمداد', 'size': 10, 'color': WHITE, 'space': 0}],
        align=PP_ALIGN.RIGHT)
    txt(s, Inches(0.35), Inches(0.16), Inches(9.4), Inches(0.6), title, size=23,
        color=WHITE, bold=True, align=PP_ALIGN.RIGHT)
    txt(s, Inches(0.35), Inches(0.74), Inches(9.4), Inches(0.4), kicker, size=13,
        color=GOLD, bold=True, align=PP_ALIGN.RIGHT)


def decision(s, text, label="القرار / السياسة المطلوبة"):
    y = SH - Inches(1.02)
    rect(s, Inches(0.3), y, SW - Inches(0.6), Inches(0.78), INK2)
    rect(s, SW - Inches(0.3) - Pt(6), y, Pt(6), Inches(0.78), GOLD)
    txt(s, Inches(0.5), y + Inches(0.05), SW - Inches(1.0), Inches(0.7),
        [{'t': label, 'size': 11, 'color': GOLD, 'bold': True, 'space': 2},
         {'t': text, 'size': 13.5, 'color': WHITE}],
        anchor=MSO_ANCHOR.MIDDLE, align=PP_ALIGN.RIGHT)


def soltable(s, top, rows, *, fsize=12, row_h=0.9,
             headers=("الحل المقترح", "الأثر على العمل", "المشكلة / الوضع الحالي"),
             col_w=(4.4, 3.1, 4.6)):
    l = Inches(0.4); w = SW - Inches(0.8)
    g = s.shapes.add_table(len(rows) + 1, 3, l, top, w, Inches(row_h * (len(rows) + 1)))
    tb = g.table; tb._tbl.set('rtl', '1')
    total = sum(col_w)
    for i, cw in enumerate(col_w):
        tb.columns[i].width = Emu(int(w * cw / total))
    for j, h in enumerate(headers):
        c = tb.cell(0, j); c.fill.solid(); c.fill.fore_color.rgb = INK
        c.vertical_anchor = MSO_ANCHOR.MIDDLE
        c.margin_left = c.margin_right = Pt(5); c.margin_top = c.margin_bottom = Pt(3)
        p = c.text_frame.paragraphs[0]; rtl(p); p.alignment = PP_ALIGN.CENTER
        r = p.add_run(); r.text = h; r.font.size = Pt(12.5); r.font.bold = True
        r.font.color.rgb = WHITE; r.font.name = F
    for i, (sol, eff, prob) in enumerate(rows, start=1):
        for j, (text, col, bd) in enumerate([(sol, GREEN, False), (eff, SLATE, False), (prob, INK, True)]):
            c = tb.cell(i, j); c.fill.solid()
            c.fill.fore_color.rgb = CARD if i % 2 else ROWALT
            c.vertical_anchor = MSO_ANCHOR.MIDDLE
            c.margin_left = c.margin_right = Pt(6); c.margin_top = c.margin_bottom = Pt(4)
            p = c.text_frame.paragraphs[0]; rtl(p); p.alignment = PP_ALIGN.RIGHT
            r = p.add_run(); r.text = text; r.font.size = Pt(fsize); r.font.name = F
            r.font.color.rgb = col; r.font.bold = bd
    return g


def proctable(s, top, rows, row_h=0.62):
    """إجراءات الدورة: المرحلة / الإجراء / المسؤول / المستند (تُعرض من اليمين)."""
    headers = ("المرحلة", "الإجراء", "المسؤول", "المستند")
    col_w = (2.5, 4.6, 2.4, 2.6)
    l = Inches(0.4); w = SW - Inches(0.8)
    g = s.shapes.add_table(len(rows) + 1, 4, l, top, w, Inches(row_h * (len(rows) + 1)))
    tb = g.table; tb._tbl.set('rtl', '1')
    total = sum(col_w)
    for i, cw in enumerate(col_w):
        tb.columns[i].width = Emu(int(w * cw / total))
    for j, h in enumerate(headers):
        c = tb.cell(0, j); c.fill.solid(); c.fill.fore_color.rgb = INK
        c.vertical_anchor = MSO_ANCHOR.MIDDLE
        c.margin_left = c.margin_right = Pt(5); c.margin_top = c.margin_bottom = Pt(3)
        p = c.text_frame.paragraphs[0]; rtl(p); p.alignment = PP_ALIGN.CENTER
        r = p.add_run(); r.text = h; r.font.size = Pt(12.5); r.font.bold = True
        r.font.color.rgb = WHITE; r.font.name = F
    palette = [(INK, True), (SLATE, False), (INK, False), (GREEN, False)]
    for i, row in enumerate(rows, start=1):
        for j, cell in enumerate(row):
            c = tb.cell(i, j); c.fill.solid()
            c.fill.fore_color.rgb = CARD if i % 2 else ROWALT
            c.vertical_anchor = MSO_ANCHOR.MIDDLE
            c.margin_left = c.margin_right = Pt(6); c.margin_top = c.margin_bottom = Pt(3)
            p = c.text_frame.paragraphs[0]; rtl(p)
            p.alignment = PP_ALIGN.CENTER if j in (0, 2, 3) else PP_ALIGN.RIGHT
            col, bd = palette[j]
            r = p.add_run(); r.text = cell; r.font.size = Pt(12); r.font.name = F
            r.font.color.rgb = col; r.font.bold = bd
    return g


TOTAL = 22
slides = []


def new():
    s = prs.slides.add_slide(BLANK); slides.append(s); return s


# ===================================================== 1) الغلاف
s = new()
rect(s, 0, 0, SW, SH, INK)
rect(s, 0, Inches(3.15), SW, Pt(4), GOLD)
txt(s, Inches(1), Inches(0.85), SW - Inches(2), Inches(0.5),
    'مجموعة الذيابي للمقاولات', size=17, color=GOLD, bold=True, align=PP_ALIGN.CENTER)
txt(s, Inches(0.7), Inches(1.8), SW - Inches(1.4), Inches(1.2),
    'تطوير وحوكمة منظومة المشتريات وسلسلة الإمداد', size=40, color=WHITE,
    bold=True, align=PP_ALIGN.CENTER)
txt(s, Inches(1), Inches(3.3), SW - Inches(2), Inches(0.6),
    'تشخيص الوضع الراهن — وحلول عملية لكل تحدٍّ — وسياسات وإجراءات ودورة داخلية كاملة',
    size=17, color=GOLD, align=PP_ALIGN.CENTER)
txt(s, Inches(1), Inches(4.7), SW - Inches(2), Inches(1.5),
    [{'t': 'وثيقة قرار تنفيذية مرفوعة إلى سعادة المدير العام والإدارة العليا', 'size': 16, 'color': WHITE, 'bold': True, 'space': 8},
     {'t': 'إعداد: إدارة العمليات والمشتريات', 'size': 14, 'color': SAND}],
    align=PP_ALIGN.CENTER)

# ===================================================== 2) السياق
s = new(); brandbar(s, 'السياق والهدف من هذه الوثيقة', 'لماذا الآن؟')
bullets(s, Inches(0.5), Inches(1.5), SW - Inches(1), Inches(2.7), [
    {'t': 'إدارة المشتريات هي القلب الذي يربط المشاريع والصيانة والمالية والمستودعات والموردين؛ وأي خلل في تنظيمها ينعكس على الجميع.', 'bold': True, 'color': INK, 'size': 16},
    {'t': 'تراكمت ملاحظات متكرّرة في آلية العمل تؤثر على كفاءة الإنفاق وانتظام التوريد وعلاقتنا بالموردين.', 'size': 16},
    {'t': 'الهدف ليس تحميل أي إدارة اللوم، بل وضع سياسات وإجراءات ثابتة ومُلزِمة تنظّم العمل وتحمي مصلحة الشركة.', 'size': 16},
    {'t': 'المسار: مناقشة النقاط مع الإدارات ذات العلاقة، ثم رفعها للإدارة العليا لاعتماد القرار المناسب لكل بند.', 'size': 16},
], gap=15)
decision(s, 'اعتماد هذه الوثيقة أساساً للنقاش المؤسسي ثم إقرار سياسة وإجراء ثابت لكل بند فيها.')
page(s, 2)

# ===================================================== 3) الملخص التنفيذي
s = new(); brandbar(s, 'الملخص التنفيذي', 'الصورة الكاملة في صفحة واحدة')
cards = [
    ('جوهر المشكلة', 'غياب دورة مستندية مُلزِمة وقناة موحّدة للطلبات وصلاحيات واضحة وضوابط ثابتة للعمل.', RED),
    ('الأثر', 'ازدواج في الإنفاق، وتأخّر في التوريد، وتآكل في ثقة الموردين، وضعف في الرقابة على التكلفة.', AMBER),
    ('الحل', 'مأسسة المشتريات: قناة واحدة إلزامية + دورة موثّقة + ثلاثة عروض لكل شراء + مصفوفة صلاحيات + عقود إطارية.', GREEN),
    ('المطلوب', 'إقرار السياسات والإجراءات وخارطة الطريق (أول 30 يوماً / حتى 90 يوماً / المدى البعيد).', INK),
]
cw = (SW - Inches(1.1)) / 2
for i, (ti, de, co) in enumerate(cards):
    r, c = divmod(i, 2)
    x = Inches(0.45) + c * (cw + Inches(0.2)); y = Inches(1.55) + r * Inches(1.55)
    rect(s, x, y, cw, Inches(1.35), CARD, line=LINE)
    rect(s, x + cw - Pt(8), y, Pt(8), Inches(1.35), co)
    txt(s, x + Inches(0.15), y + Inches(0.12), cw - Inches(0.45), Inches(1.15),
        [{'t': ti, 'size': 18, 'color': co, 'bold': True, 'space': 4},
         {'t': de, 'size': 14, 'color': SLATE}], align=PP_ALIGN.RIGHT)
decision(s, 'الانتقال بالمشتريات من العمل التفاعلي اليومي إلى منظومة محوكمة تحمي الربحية وتضبط التوريد.')
page(s, 3)

# ===================================================== 4) لوحة التحديات
s = new(); brandbar(s, 'لوحة التحديات المرصودة', 'مصنّفة حسب درجة الأثر')
rowsT = [
    ('ازدواجية التوريد (شراء صنف ورّدته الصيانة فعلاً)', 'حرج', RED),
    ('الشراء المباشر خارج إدارة المشتريات', 'حرج', RED),
    ('بطء التحويل المالي للموردين', 'حرج', RED),
    ('الإفراط في صفة «عاجل» وتآكل ثقة الموردين', 'مرتفع', AMBER),
    ('الطلبات المعلّقة دون اعتماد أو تحويل', 'مرتفع', AMBER),
    ('غياب دورة مستندية وإجراءات موحّدة', 'مرتفع', AMBER),
    ('غياب مصفوفة صلاحيات للاعتماد والتعميد', 'مرتفع', AMBER),
    ('بطء تسعير المناقصات وغياب سجل أسعار مرجعي', 'متوسط', GREEN),
    ('عهدة قصر الياسمين على غير المنفّذ الفعلي', 'متوسط', GREEN),
    ('تعثّر طلبات البنية التحتية المتكررة الصغيرة', 'متوسط', GREEN),
]
colw = (SW - Inches(1.0)) / 2
for i, (t, lvl, co) in enumerate(rowsT):
    c, r = divmod(i, 5)
    x = Inches(0.4) + (1 - c) * (colw + Inches(0.2)); y = Inches(1.5) + r * Inches(0.86)
    rect(s, x, y, colw, Inches(0.72), CARD, line=LINE)
    rect(s, x + colw - Inches(1.05), y, Inches(1.05), Inches(0.72), co)
    txt(s, x + colw - Inches(1.05), y, Inches(1.05), Inches(0.72), lvl, size=13,
        color=WHITE, bold=True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    txt(s, x + Inches(0.12), y, colw - Inches(1.2), Inches(0.72), t, size=12.5,
        color=INK, bold=True, align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.MIDDLE)
page(s, 4)

# ===================================================== 5) لماذا يهم
s = new(); brandbar(s, 'لماذا يستحق الأمر قراراً عاجلاً', 'من ملاحظة تشغيلية إلى أثر على الربحية')
imp = [
    ('ازدواجية التوريد', 'دفعٌ مزدوج لنفس الاحتياج، والتزام مالي لم يكن ضرورياً.'),
    ('الشراء المباشر', 'فقدان قوة التفاوض ووفورات الشراء المجمّع لدى مورد واحد.'),
    ('«العاجل» الزائف', 'أسعار أعلى مقابل السرعة، وفتور تدريجي في استجابة الموردين.'),
    ('الطلبات المعلّقة', 'تأخّر التوريد وتعطّل الأعمال في المواقع.'),
    ('بطء التحويل المالي', 'توقّف الموردين عن التوريد، وتحميل المشتريات تبعة التأخير.'),
    ('بطء تسعير المناقصات', 'تجهيز عروض غير دقيقة وضياع فرص الترسية.'),
]
cw = (SW - Inches(1.1)) / 2
for i, (ti, de) in enumerate(imp):
    r, c = divmod(i, 2)
    x = Inches(0.45) + c * (cw + Inches(0.2)); y = Inches(1.5) + r * Inches(1.18)
    rect(s, x, y, cw, Inches(1.0), CARD, line=LINE)
    rect(s, x + cw - Pt(7), y, Pt(7), Inches(1.0), GOLD)
    txt(s, x + Inches(0.12), y + Inches(0.08), cw - Inches(0.35), Inches(0.85),
        [{'t': ti, 'size': 15, 'color': INK, 'bold': True, 'space': 3},
         {'t': de, 'size': 13, 'color': SLATE}], align=PP_ALIGN.RIGHT)
decision(s, 'المشتريات ليست مركز صرف فحسب، بل مصدر وفر وحماية للتكلفة متى أُحسِن تنظيمها.')
page(s, 5)

# ===================================================== 6) المحور 1
s = new(); brandbar(s, 'أولاً: تنظيم الطلبات والدورة المستندية', 'المشكلة ← الأثر ← الحل')
soltable(s, Inches(1.45), [
    ('نموذج طلب شراء موحّد إلزامي موقّع من صاحب الصلاحية؛ ولا يُعتدّ بأي طلب خارجه.',
     'غياب الالتزام والتتبّع وإرباك التنفيذ.',
     'طلبات تصل عبر البريد والواتساب بصفة «عاجل» دون نموذج رسمي.'),
    ('قصر صفة «عاجل» على ما يعتمده مدير الإدارة الطالبة خطياً بمبرّر، مع سقف عددي.',
     'فتور استجابة الموردين وارتفاع الأسعار.',
     'الإفراط في وصف الطلبات بالعاجل وأغلبها لا يُستكمل بأمر شراء.'),
    ('مدة معيارية للبتّ (3 أيام عمل)، ولوحة متابعة بحالة كل طلب، وإغلاق المنتفي.',
     'تأخّر التوريد وتعطّل الأعمال.',
     'طلبات تبقى معلّقة دون اعتماد أو تحويل للمورد لفترات طويلة.'),
    ('دورة مستندية موثّقة، ومصفوفة صلاحيات تحدّد الموقّع والمعتمِد لكل قيمة.',
     'عشوائية وتأخير وتكرار للإجراءات.',
     'غموض في الدورة المستندية ومن يوقّع ومن يعتمد.'),
    ('إلزام إرفاق صورة البند أو اسم العلامة التجارية، واعتماد قناة رسمية واحدة للمستندات.',
     'أخطاء في التوريد وإعادة عمل.',
     'طلبات بمواصفات ناقصة وتشتّت قنوات المستندات.'),
], row_h=0.92, fsize=12)
page(s, 6)

# ===================================================== 7) المحور 2
s = new(); brandbar(s, 'ثانياً: ازدواجية التوريد والشراء المباشر', 'حماية الإنفاق وتوحيد القناة')
soltable(s, Inches(1.5), [
    ('إشعار فوري من الإدارة الطالبة عند انتفاء الحاجة، ومنع أي توريد موازٍ بعد إصدار أمر الشراء.',
     'التزام مالي مزدوج وإرباك المورد وإهدار الجهد.',
     'تُكلَّف المشتريات بالتوريد ثم يتبيّن أن الصيانة وردّت الصنف من مورد أجل.'),
    ('حصر كل شراء وتوريد لقطاعات المجموعة عبر المشتريات حصراً بقرار من الإدارة العليا.',
     'فقدان الرقابة وضعف التفاوض وتعدّد قنوات المورد.',
     'تنفيذ عمليات شراء مباشرة خارج إدارة المشتريات.'),
    ('إدراج هؤلاء الموردين ضمن قائمة معتمدة موحّدة تُدار عبر المشتريات.',
     'ازدواج الحسابات وصعوبة التدقيق.',
     'التعامل مع موردين بعينهم والشراء منهم مباشرة دون الرجوع للمشتريات.'),
    ('جعل فحص رصيد المستودع خطوة إلزامية قبل أي طلب شراء.',
     'شراء أصناف متوفّرة أصلاً في المخزون.',
     'عدم ربط الطلب برصيد المستودع قبل الشراء.'),
], row_h=1.05, fsize=12.5)
page(s, 7)

# ===================================================== 8) المحور: تسعير المناقصات
s = new(); brandbar(s, 'ثالثاً: تسعير المناقصات وسجل الأسعار', 'سجل الأسعار لتسعير المناقصات فقط — لا بديل عن العروض')
soltable(s, Inches(1.5), [
    ('إنشاء سجل أسعار مرجعي يُستعان به عند إعداد عروض المناقصات فقط (دون أن يُستخدم في الشراء أو يُغني عن العروض).',
     'بطء تجهيز عروض المناقصات وتفويت فرص الترسية.',
     'إعادة تجميع الأسعار يدوياً عند تسعير كل مناقصة رغم توفّر بيانات سابقة.'),
    ('تغذية السجل آلياً من فواتير الشراء والنظام المالي وتحديثه دورياً.',
     'غياب مرجع يدعم دقة تسعير المناقصات.',
     'لا يوجد تاريخ لأسعار المواد رغم الشراء المستمر.'),
    ('تخصيص مدة معيارية كافية لتسعير المناقصات تُتّفق عليها مسبقاً.',
     'أسعار غير دقيقة وضياع فرص التقديم.',
     'تسعير المناقصات تحت ضغط وقت غير كافٍ.'),
    ('الفصل التام: الشراء يخضع دائماً لثلاثة عروض، والسجل أداة لتسعير المناقصات حصراً.',
     'إضعاف الرقابة على الشراء عند الخلط بينهما.',
     'الخلط بين سجل الأسعار وعروض الشراء.'),
], row_h=1.05, fsize=12)
page(s, 8)

# ===================================================== 9) المحور: الموردون
s = new(); brandbar(s, 'رابعاً: الموردون والعلاقات التجارية', 'استعادة الثقة وضبط التعامل')
soltable(s, Inches(1.45), [
    ('ضبط صفة «العاجل» والالتزام بإغلاق الطلبات يعيدان جدية الموردين.',
     'تراجع الاستجابة وجودة العروض.',
     'تآكل مصداقية طلباتنا لدى الموردين وفتور تجاوبهم.'),
    ('إبرام عقود إطارية سنوية بأسعار ثابتة مع الموردين الرئيسيين (بعد ترسيتها بثلاثة عروض).',
     'أسعار متذبذبة وتفاوض متكرّر.',
     'الطلبات الشهرية المتكررة وكبيرة الحجم بلا عقود.'),
    ('ثلاثة عروض للمرة الأولى ثم اعتماد مورد ثابت بعقد للطلبات المستديمة.',
     'بطء متكرّر في التوريد.',
     'الطلبات المستديمة لقطاعات المجموعة تُسعّر كل مرة.'),
    ('تسليم المشتريات حصراً بالمشاكل القائمة والشخص المسؤول لتوحيد التعامل.',
     'تضارب وتكرار في معالجة المشاكل.',
     'مشاكل مع الموردين موزّعة على إدارات متعددة.'),
    ('تسليم المشتريات كشف حساب بالمديونية لتسويتها ضمن خطة.',
     'مخاطر ائتمانية وتعليق توريد.',
     'مديونيات على الصيانة والتشغيل لدى الموردين.'),
], row_h=0.92, fsize=12)
page(s, 9)

# ===================================================== 10) المحور: الصيانة والتشغيل
s = new(); brandbar(s, 'خامساً: تنظيم العلاقة مع الصيانة والتشغيل', 'إطار واضح للأدوار والمسارات')
soltable(s, Inches(1.55), [
    ('اتفاقية تنظيمية تحدّد المسارات: الطلبات العادية والعاجلة والموردون ومقاولو الباطن.',
     'تداخل المسؤوليات والاحتكاك.',
     'غياب إطار منظّم للعلاقة بين الإدارتين.'),
    ('تعيين منسّق إداري من الصيانة والتشغيل على دراية بآلية المشتريات.',
     'تشتّت التواصل وتعدّد المرجعيات.',
     'لا توجد جهة تنسيق واحدة من الصيانة والتشغيل.'),
    ('جعل مشرفي الشراء في المواقع تابعين إشرافياً لإدارة المشتريات.',
     'شراء ميداني غير منضبط.',
     'مشرفو الشراء بالموقع خارج مظلة المشتريات.'),
    ('توضيح آلية موحّدة لكل نوع طلب يلتزم بها الطرفان.',
     'ارتباك في التنفيذ وتأخير.',
     'اختلاف آلية التعامل حسب نوع الطلب.'),
], row_h=1.05, fsize=12.5)
page(s, 10)

# ===================================================== 11) المحور: العهد والموارد
s = new(); brandbar(s, 'سادساً: العهد والموارد التشغيلية', 'معالجة الملفات العالقة وتمكين المشتريات')
soltable(s, Inches(1.55), [
    ('نقل عهدة قصر الياسمين إلى مسؤول المشروع باعتباره المنفّذ الفعلي للشراء.',
     'عدم تطابق المسؤولية مع المنفّذ.',
     'عهدة قصر الياسمين مسجّلة على مندوب المشتريات رغم أن الشراء عبر المشروع.'),
    ('اعتماد طلبات البنية التحتية ضمن عقد إطاري وسقف محدّد لتسريع تنفيذها.',
     'تأخّر احتياجات متكررة منخفضة القيمة.',
     'طلبات البنية التحتية أسبوعية صغيرة متكررة وليست تحت سقف مورد واحد.'),
    ('تخصيص عهدة مالية مستديمة للمشتريات باعتماد مديرها للحالات الصغيرة.',
     'بطء تنفيذ البنود البسيطة العاجلة.',
     'لا توجد عهدة نقدية لدى المشتريات.'),
    ('تعيين سائق تابع لإدارة المشتريات لتوريد الطلبات إلى المواقع.',
     'تأخّر التسليم والاعتماد على الغير.',
     'لا توجد وسيلة توريد مخصّصة للمواقع.'),
], row_h=1.05, fsize=12.5)
page(s, 11)

# ===================================================== 12) المحور: المالية
s = new(); brandbar(s, 'سابعاً: التكامل مع الإدارة المالية', 'إزالة اختناق التحويل')
soltable(s, Inches(1.7), [
    ('التزام زمني للتحويل (3–5 أيام عمل، و24 ساعة للطوارئ المعتمدة) ودفعات أسبوعية مجمّعة.',
     'تعطّل الموردين وتحميل المشتريات تبعة التأخير.',
     'بطء استجابة الإدارة المالية لتحويلات الموردين.'),
    ('تغذية سجل أسعار المناقصات من فواتير الشراء في النظام المالي أولاً بأول.',
     'ضعف دقة تسعير المناقصات.',
     'عدم تغذية سجل الأسعار من النظام المالي.'),
    ('اعتماد مسار طوارئ مالي بموافقة مسبقة موثّقة وسقف محدّد.',
     'استخدام صفة «العاجل» للالتفاف على الإجراءات.',
     'غياب مسار طوارئ مالي محكوم.'),
], row_h=1.15, fsize=13)
page(s, 12)

# ===================================================== 13) السياسات الحاكمة
s = new(); brandbar(s, 'سياسات إدارة المشتريات الحاكمة', 'الإطار الذي تُبنى عليه الإجراءات')
pols = [
    ('القناة الموحّدة', 'كل شراء وتوريد لقطاعات المجموعة عبر المشتريات حصراً.'),
    ('ثلاثة عروض إلزامية', 'لكل طلب شراء مهما كان حجمه؛ والاستثناءات موثّقة فقط.'),
    ('مصفوفة الصلاحيات', 'الاعتماد حسب القيمة وصاحب الصلاحية المحدّد.'),
    ('الدورة المستندية', 'مسار موحّد موثّق من الاحتياج حتى الإغلاق.'),
    ('اعتماد الموردين', 'قائمة موردين معتمدة وتقييم دوري لأدائهم.'),
    ('العقود الإطارية', 'للطلبات المتكررة والمستديمة بأسعار ثابتة.'),
    ('سجل أسعار المناقصات', 'مرجع لتسعير المناقصات فقط، لا للشراء ولا بديلاً عن العروض.'),
    ('المشتريات العاجلة', 'مسار طوارئ محكوم بموافقة مسبقة موثّقة.'),
    ('العهد المالية', 'عهدة مستديمة للمشتريات بضوابط صرف واضحة.'),
    ('الاستثناءات الموثّقة', 'النثريات والبنية التحتية ضمن سقف باعتماد مدير المشتريات.'),
    ('المطابقة قبل الصرف', 'مطابقة الطلب وأمر الشراء والفاتورة والاستلام.'),
    ('النزاهة والتوثيق', 'سرية العروض ومنع تعارض المصالح وأرشفة كاملة.'),
]
cw = (SW - Inches(1.0)) / 2
for i, (ti, de) in enumerate(pols):
    r, c = divmod(i, 2)
    x = SW - Inches(0.4) - (c + 1) * cw - c * Inches(0.1) + Inches(0.1)
    y = Inches(1.42) + r * Inches(0.86)
    rect(s, x, y, cw, Inches(0.76), CARD, line=LINE)
    rect(s, x + cw - Pt(6), y, Pt(6), Inches(0.76), GOLD)
    txt(s, x + Inches(0.12), y + Inches(0.04), cw - Inches(0.3), Inches(0.7),
        [{'t': ti, 'size': 14, 'color': INK, 'bold': True, 'space': 1},
         {'t': de, 'size': 11.5, 'color': SLATE}], align=PP_ALIGN.RIGHT,
        anchor=MSO_ANCHOR.MIDDLE)
page(s, 13)

# ===================================================== 14) الدورة الداخلية (خريطة)
s = new(); brandbar(s, 'الدورة الداخلية الكاملة للمشتريات', 'مسار واحد إلزامي من الاحتياج حتى الإغلاق')
steps = ['نشوء الاحتياج', 'طلب شراء رسمي\nبالمواصفات', 'فحص رصيد\nالمستودع',
         'طلب ثلاثة\nعروض', 'تحليل العروض\nوالمقارنة', 'الاعتماد حسب\nالصلاحية',
         'إصدار أمر\nالشراء', 'التوريد والاستلام\nوالمطابقة', 'الصرف للمورد\nضمن المدة',
         'الإغلاق\nوالأرشفة']
per = 5; bw = Inches(2.32); bh = Inches(1.05)
gapx = (SW - Inches(0.6) - per * bw) / (per - 1)
for i, st in enumerate(steps):
    row = i // per; col = i % per
    x = SW - Inches(0.3) - bw - col * (bw + gapx)
    y = Inches(1.75) + row * Inches(2.0)
    co = GOLD if i in (3, 4, 5) else INK
    rect(s, x, y, bw, bh, co)
    tcol = INK if co == GOLD else WHITE
    txt(s, x, y, bw, bh, st.replace('\n', ' '), size=13, color=tcol, bold=True,
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    if col < per - 1:
        txt(s, x - gapx, y, gapx, bh, '◄', size=20, color=MUTE, align=PP_ALIGN.CENTER,
            anchor=MSO_ANCHOR.MIDDLE, is_rtl=False)
    elif row == 0:
        txt(s, x, y + bh, bw, Inches(0.95), '▼', size=20, color=MUTE,
            align=PP_ALIGN.CENTER, is_rtl=False)
decision(s, 'ثلاثة عروض إلزامية في كل دورة، ومنع أي توريد خارج هذا المسار أو موازٍ بعد أمر الشراء.')
page(s, 14)

# ===================================================== 15) إجراءات الدورة (1)
s = new(); brandbar(s, 'إجراءات الدورة الداخلية — من الاحتياج إلى الاعتماد', 'المرحلة والإجراء والمسؤول والمستند')
proctable(s, Inches(1.55), [
    ('1) الاحتياج', 'تحديد الحاجة وتعبئة طلب الشراء بالمواصفات', 'الإدارة الطالبة', 'نموذج طلب شراء'),
    ('2) التسجيل', 'استلام الطلب ومنحه رقماً مرجعياً ومراجعة اكتماله', 'المشتريات', 'سجل الطلبات'),
    ('3) فحص المخزون', 'التأكد من عدم توفّر الصنف في المستودع', 'المستودعات', 'تقرير الرصيد'),
    ('4) طلب العروض', 'مخاطبة ثلاثة موردين معتمدين على الأقل', 'المشتريات', 'طلب عروض أسعار'),
    ('5) تحليل العروض', 'إعداد جدول المقارنة فنياً ومالياً', 'المشتريات', 'جدول المفاضلة'),
    ('6) التوصية', 'ترشيح المورد الأنسب مع المبرّر', 'المشتريات', 'محضر توصية'),
    ('7) الاعتماد', 'الموافقة حسب مصفوفة الصلاحيات', 'صاحب الصلاحية', 'اعتماد موقّع'),
], row_h=0.62)
page(s, 15)

# ===================================================== 16) إجراءات الدورة (2)
s = new(); brandbar(s, 'إجراءات الدورة الداخلية — من أمر الشراء إلى الإغلاق', 'المرحلة والإجراء والمسؤول والمستند')
proctable(s, Inches(1.55), [
    ('8) أمر الشراء', 'تحرير أمر الشراء المعتمد وإصداره', 'المشتريات', 'أمر الشراء'),
    ('9) التعاقد والإشعار', 'إشعار المورد وتأكيد الشروط والمدة', 'المشتريات', 'أمر شراء / عقد'),
    ('10) المتابعة والتوريد', 'متابعة المورد حتى التسليم في الموعد', 'المشتريات', 'إشعار تسليم'),
    ('11) الاستلام والفحص', 'استلام الصنف وفحص مطابقته للمواصفات', 'المستودعات / الطالبة', 'محضر استلام'),
    ('12) المطابقة', 'مطابقة الطلب وأمر الشراء والفاتورة والاستلام', 'المشتريات', 'حزمة المطابقة'),
    ('13) الصرف', 'تحويل المستحق للمورد ضمن المدة المعتمدة', 'المالية', 'سند صرف'),
    ('14) الإغلاق', 'إقفال المعاملة وحفظ الملف كاملاً', 'المشتريات', 'ملف المعاملة'),
], row_h=0.62)
page(s, 16)

# ===================================================== 17) مصفوفة الصلاحيات
s = new(); brandbar(s, 'مصفوفة الصلاحيات والاعتماد', 'مستويات الاعتماد حسب القيمة — والعروض الثلاثة قاعدة ثابتة')
tiers = [
    ('المستوى الأول', 'حتى 25,000 ريال', 'مدير المشتريات', 'ثلاثة عروض', GREEN),
    ('المستوى الثاني', 'حتى 100,000 ريال', 'المشتريات والمالية', 'ثلاثة عروض ومقارنة', AMBER),
    ('المستوى الثالث', 'حتى 500,000 ريال', 'المدير العام', 'ثلاثة عروض وتفاوض', RED),
    ('المستوى الرابع', 'أكثر من 500,000', 'المدير العام ولجنة', 'لجنة وثلاثة عروض', INK),
    ('مسار الطوارئ', 'حالات حرجة فعلاً', 'موافقة مسبقة موثّقة', 'حسب المتاح وتسوية لاحقة', INK2),
]
cw = (SW - Inches(0.8)) / 5
for i, (ti, val, who, note, co) in enumerate(tiers):
    x = SW - Inches(0.4) - (i + 1) * cw + Inches(0.06); y = Inches(1.5)
    rect(s, x, y, cw - Inches(0.12), Inches(0.58), co)
    txt(s, x, y, cw - Inches(0.12), Inches(0.58), ti, size=14, color=WHITE, bold=True,
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    rect(s, x, y + Inches(0.64), cw - Inches(0.12), Inches(2.5), CARD, line=LINE)
    txt(s, x + Inches(0.03), y + Inches(0.74), cw - Inches(0.18), Inches(2.35),
        [{'t': val, 'size': 14.5, 'color': INK, 'bold': True, 'space': 7},
         {'t': 'المعتمِد', 'size': 11, 'color': GOLD, 'bold': True, 'space': 1},
         {'t': who, 'size': 12.5, 'color': SLATE, 'space': 7},
         {'t': 'العروض', 'size': 11, 'color': GOLD, 'bold': True, 'space': 1},
         {'t': note, 'size': 12.5, 'color': SLATE}], align=PP_ALIGN.CENTER)
# صندوق الاستثناءات
ey = Inches(4.8)
rect(s, Inches(0.4), ey, SW - Inches(0.8), Inches(0.95), RGBColor(0xF0, 0xE7, 0xD2), line=GOLD, lw=1.5)
txt(s, Inches(0.6), ey + Inches(0.08), SW - Inches(1.2), Inches(0.8),
    [{'t': 'الاستثناءات من قاعدة العروض الثلاثة (موثّقة وباعتماد مدير المشتريات):', 'size': 13, 'color': RED, 'bold': True, 'space': 3},
     {'t': 'المشتريات النثرية تحت الحد الأدنى — أصناف البنية التحتية المتكررة ضمن سقف — الأصناف المتعاقد عليها بعقود إطارية (سبق ترسيتها بثلاثة عروض) — الطوارئ المعتمدة مسبقاً.', 'size': 12.5, 'color': SLATE}],
    align=PP_ALIGN.RIGHT)
decision(s, 'اعتماد مستويات الصلاحية بقيمها، مع إبقاء العروض الثلاثة قاعدةً، وحصر الاستثناءات في الحالات الموثّقة.')
page(s, 17)

# ===================================================== 18) نموذج الحوكمة
s = new(); brandbar(s, 'نموذج الحوكمة المقترح', 'المشتريات قناة واحدة محكومة بأربع ركائز')
rect(s, SW/2 - Inches(2.0), Inches(1.45), Inches(4.0), Inches(0.7), INK)
txt(s, SW/2 - Inches(2.0), Inches(1.45), Inches(4.0), Inches(0.7), 'الإدارة العليا / المدير العام',
    size=16, color=WHITE, bold=True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
txt(s, SW/2 - Inches(0.3), Inches(2.18), Inches(0.6), Inches(0.4), '▼', size=18,
    color=MUTE, align=PP_ALIGN.CENTER, is_rtl=False)
rect(s, SW/2 - Inches(2.4), Inches(2.6), Inches(4.8), Inches(0.85), GOLD)
txt(s, SW/2 - Inches(2.4), Inches(2.6), Inches(4.8), Inches(0.85),
    'إدارة المشتريات — القناة الموحّدة الإلزامية', size=16, color=INK, bold=True,
    align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
parts = ['الإدارات الطالبة', 'الإدارة المالية', 'المستودعات', 'الموردون']
pw = Inches(2.9); gap = (SW - Inches(0.8) - 4 * pw) / 3
for i, p in enumerate(parts):
    x = SW - Inches(0.4) - pw - i * (pw + gap); y = Inches(3.95)
    rect(s, x, y, pw, Inches(0.8), INK2)
    txt(s, x, y, pw, Inches(0.8), p, size=14, color=WHITE, bold=True,
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
txt(s, Inches(0.4), Inches(4.95), SW - Inches(0.8), Inches(0.4),
    'الركائز الحاكمة الأربع', size=13, color=GOLD, bold=True, align=PP_ALIGN.CENTER)
pillars = ['دورة مستندية موثّقة', 'مصفوفة صلاحيات', 'قائمة موردين معتمدة', 'سجل أسعار المناقصات']
pw2 = (SW - Inches(1.0)) / 4
for i, p in enumerate(pillars):
    x = SW - Inches(0.4) - (i + 1) * pw2 + Inches(0.05); y = Inches(5.35)
    rect(s, x, y, pw2 - Inches(0.1), Inches(0.6), CARD, line=GOLD, lw=1.5)
    txt(s, x, y, pw2 - Inches(0.1), Inches(0.6), p, size=12.5, color=INK, bold=True,
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
decision(s, 'اعتماد المشتريات قناةً موحّدة لكل القطاعات، محكومةً بالركائز الأربع.')
page(s, 18)

# ===================================================== 19) خارطة الطريق
s = new(); brandbar(s, 'خارطة طريق التنفيذ', 'مراحل زمنية واضحة وقابلة للقياس')
phases = [
    ('أول 30 يوماً', 'تثبيت الحوكمة', GREEN,
     ['النموذج الموحّد للطلبات', 'مصفوفة الصلاحيات بقيمها',
      'حصر الشراء عبر المشتريات', 'التزام المالية الزمني', 'إيقاف ازدواجية التوريد']),
    ('حتى 90 يوماً', 'البناء المؤسسي', AMBER,
     ['سجل أسعار المناقصات', 'العقود الإطارية للمتكرر',
      'عهدة وسائق للمشتريات', 'معالجة قصر الياسمين والبنية التحتية', 'تعيين منسّق الصيانة']),
    ('المدى البعيد', 'الاستدامة والتميّز', INK,
     ['نظام مشتريات موحّد', 'لوحات متابعة الأداء',
      'تقييم دوري للموردين', 'تطوير استراتيجية التوريد']),
]
cw = (SW - Inches(1.0)) / 3
for i, (ti, sub, co, items) in enumerate(phases):
    x = SW - Inches(0.4) - (i + 1) * cw - i * Inches(0.05) + Inches(0.05)
    rect(s, x, Inches(1.5), cw - Inches(0.1), Inches(0.95), co)
    txt(s, x, Inches(1.56), cw - Inches(0.1), Inches(0.85),
        [{'t': ti, 'size': 22, 'color': WHITE, 'bold': True, 'space': 1},
         {'t': sub, 'size': 13, 'color': SAND}], align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    rect(s, x, Inches(2.5), cw - Inches(0.1), Inches(3.4), CARD, line=LINE)
    bullets(s, x + Inches(0.12), Inches(2.65), cw - Inches(0.35), Inches(3.1), items,
            size=14, gap=14, color=SLATE)
decision(s, 'المصادقة على المراحل وتكليف فريق تنفيذي بمتابعة الإنجاز ورفع تقارير دورية.')
page(s, 19)

# ===================================================== 20) مؤشرات النجاح
s = new(); brandbar(s, 'مؤشرات قياس النجاح', 'ما لا يُقاس لا يُمكن تطويره')
kpis = [
    ('زمن دورة الشراء', 'من الطلب حتى أمر الشراء', 'تقليصه إلى النصف'),
    ('التزام الطلبات بالدورة', 'نسبة الطلبات الرسمية', 'لا تقل عن 95٪'),
    ('التزام الشراء بالعروض', 'نسبة الطلبات بثلاثة عروض', 'لا تقل عن 95٪'),
    ('إغلاق الطلبات في وقتها', 'دون معلّقات متراكمة', 'لا معلّقات متأخرة'),
    ('التزام المالية بالتحويل', 'ضمن المدة المعتمدة', 'لا تقل عن 90٪'),
    ('استجابة الموردين', 'نسبة الرد على العروض', 'اتجاه متصاعد'),
]
cw = (SW - Inches(1.1)) / 3
for i, (ti, de, tg) in enumerate(kpis):
    r, c = divmod(i, 3)
    x = SW - Inches(0.45) - (c + 1) * cw - c * Inches(0.1) + Inches(0.1)
    y = Inches(1.6) + r * Inches(1.75)
    rect(s, x, y, cw, Inches(1.5), CARD, line=LINE)
    rect(s, x, y, cw, Inches(0.5), INK)
    txt(s, x, y, cw, Inches(0.5), ti, size=15, color=WHITE, bold=True,
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    txt(s, x + Inches(0.1), y + Inches(0.58), cw - Inches(0.2), Inches(0.5), de,
        size=13, color=SLATE, align=PP_ALIGN.CENTER)
    txt(s, x + Inches(0.1), y + Inches(1.05), cw - Inches(0.2), Inches(0.4), tg,
        size=14, color=GREEN, bold=True, align=PP_ALIGN.CENTER)
decision(s, 'اعتماد هذه المؤشرات ضمن تقرير أداء ربع سنوي يُرفع للإدارة العليا.')
page(s, 20)

# ===================================================== 21) القرارات المطلوبة
s = new(); brandbar(s, 'القرارات المطلوبة من الإدارة العليا', 'ثمانية قرارات تُنهي التكرار')
asks = [
    'حصر كل شراء وتوريد لقطاعات المجموعة عبر المشتريات حصراً.',
    'اعتماد سياسات وإجراءات المشتريات ودورتها الداخلية الكاملة.',
    'إقرار مصفوفة الصلاحيات وقاعدة العروض الثلاثة واستثناءاتها الموثّقة.',
    'إلزام الإدارة المالية بمدة زمنية للتحويل ومسار طوارئ.',
    'إنشاء سجل أسعار لتسعير المناقصات يُغذّى من النظام المالي.',
    'تفويض إبرام عقود إطارية للطلبات المتكررة والبنية التحتية.',
    'نقل عهدة قصر الياسمين، وتخصيص عهدة وسائق للمشتريات.',
    'اعتماد خارطة الطريق ومؤشرات الأداء.',
]
cw = (SW - Inches(1.1)) / 2
for i, a in enumerate(asks):
    r, c = divmod(i, 2)
    x = SW - Inches(0.45) - (c + 1) * cw - c * Inches(0.2) + Inches(0.2)
    y = Inches(1.55) + r * Inches(1.0)
    rect(s, x, y, cw, Inches(0.82), CARD, line=LINE)
    rect(s, x + cw - Inches(0.7), y, Inches(0.7), Inches(0.82), GREEN)
    txt(s, x + cw - Inches(0.7), y, Inches(0.7), Inches(0.82), str(i + 1), size=24,
        color=WHITE, bold=True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, is_rtl=False)
    txt(s, x + Inches(0.12), y, cw - Inches(0.85), Inches(0.82), a, size=13,
        color=INK, bold=True, align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.MIDDLE)
page(s, 21)

# ===================================================== 22) الخاتمة
s = new()
rect(s, 0, 0, SW, SH, INK)
rect(s, 0, Inches(2.85), SW, Pt(4), GOLD)
txt(s, Inches(1), Inches(1.7), SW - Inches(2), Inches(1.1),
    'الحوكمة ليست قيداً على العمل، بل ضمانة استمراره وكفاءته.',
    size=30, color=WHITE, bold=True, align=PP_ALIGN.CENTER)
txt(s, Inches(1.2), Inches(3.15), SW - Inches(2.4), Inches(1.0),
    'لسنا بصدد معالجة أخطاء فردية، بل تأسيس منظومة تحمي مال الشركة وتنظّم توريدها وتعيد لها ثقة موردِيها.',
    size=17, color=GOLD, align=PP_ALIGN.CENTER)
txt(s, Inches(1), Inches(4.6), SW - Inches(2), Inches(0.7),
    'وفريق المشتريات على أتم الاستعداد للتنفيذ فور اعتماد القرارات.',
    size=16, color=SAND, align=PP_ALIGN.CENTER)
txt(s, Inches(1), Inches(5.6), SW - Inches(2), Inches(0.5),
    'مع وافر الاحترام والتقدير — إدارة العمليات والمشتريات', size=14, color=MUTE,
    align=PP_ALIGN.CENTER)

TOTAL = len(slides)
out = os.path.join(os.path.dirname(__file__), 'procurement-executive-deck.pptx')
prs.save(out)
print('Saved', out, '|', os.path.getsize(out), 'bytes |', TOTAL, 'slides')

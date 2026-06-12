# -*- coding: utf-8 -*-
"""
عرض تنفيذي شامل لتطوير وحوكمة منظومة المشتريات — مجموعة الذيابي للمقاولات.
عربية مهنية خالصة (دون مصطلحات أجنبية)، يعالج كل المشاكل المرصودة بصيغة:
المشكلة ← الأثر ← الحل المقترح.
"""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
import os

# ---------------- لوحة الألوان ----------------
INK    = RGBColor(0x0E, 0x2A, 0x38)   # كحلي عميق
INK2   = RGBColor(0x14, 0x3A, 0x4C)
GOLD   = RGBColor(0xC9, 0xA2, 0x4B)   # ذهبي
SAND   = RGBColor(0xF6, 0xF3, 0xED)   # خلفية رملية فاتحة
CARD   = RGBColor(0xFF, 0xFF, 0xFF)
LINE   = RGBColor(0xDD, 0xD4, 0xC2)
SLATE  = RGBColor(0x3A, 0x46, 0x50)   # نص رمادي داكن
MUTE   = RGBColor(0x6B, 0x74, 0x7C)
WHITE  = RGBColor(0xFF, 0xFF, 0xFF)
RED    = RGBColor(0x9E, 0x2B, 0x25)   # حرج
AMBER  = RGBColor(0xC5, 0x7A, 0x0C)   # متوسط
GREEN  = RGBColor(0x2E, 0x6B, 0x3E)   # حل/إيجابي
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
        align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.TOP, is_rtl=True, space=6,
        line_spacing=None):
    tb = s.shapes.add_textbox(l, t, w, h); tf = tb.text_frame
    tf.word_wrap = True; tf.vertical_anchor = anchor
    tf.margin_left = tf.margin_right = Pt(6)
    tf.margin_top = tf.margin_bottom = Pt(3)
    if isinstance(lines, str):
        lines = [lines]
    for i, it in enumerate(lines):
        d = it if isinstance(it, dict) else {'t': it}
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        if is_rtl:
            rtl(p)
        p.alignment = d.get('align', align)
        p.space_after = Pt(d.get('space', space))
        if line_spacing:
            p.line_spacing = line_spacing
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
    """ترويسة موحّدة."""
    rect(s, 0, 0, SW, SH, SAND)
    rect(s, 0, 0, SW, Inches(1.18), INK)
    rect(s, 0, Inches(1.18), SW, Pt(4), GOLD)
    txt(s, SW - Inches(3.5), Inches(0.2), Inches(3.25), Inches(0.85),
        [{'t': 'مجموعة الذيابي للمقاولات', 'size': 14, 'color': GOLD, 'bold': True, 'space': 0},
         {'t': 'إدارة المشتريات وسلسلة الإمداد', 'size': 10, 'color': WHITE, 'space': 0}],
        align=PP_ALIGN.RIGHT)
    txt(s, Inches(0.35), Inches(0.16), Inches(9.4), Inches(0.6),
        title, size=23, color=WHITE, bold=True, align=PP_ALIGN.RIGHT)
    txt(s, Inches(0.35), Inches(0.74), Inches(9.4), Inches(0.4),
        kicker, size=13, color=GOLD, bold=True, align=PP_ALIGN.RIGHT)


def decision(s, text, label="القرار / السياسة المطلوبة"):
    y = SH - Inches(1.02)
    rect(s, Inches(0.3), y, SW - Inches(0.6), Inches(0.78), INK2)
    rect(s, SW - Inches(0.3) - Pt(6), y, Pt(6), Inches(0.78), GOLD)
    txt(s, Inches(0.5), y + Inches(0.05), SW - Inches(1.0), Inches(0.7),
        [{'t': label, 'size': 11, 'color': GOLD, 'bold': True, 'space': 2},
         {'t': text, 'size': 13.5, 'color': WHITE}],
        anchor=MSO_ANCHOR.MIDDLE, align=PP_ALIGN.RIGHT)


def soltable(s, top, rows, *, fsize=12, row_h=0.9, headers=("الحل المقترح", "الأثر على العمل", "المشكلة / الوضع الحالي"),
             col_w=(4.4, 3.1, 4.6)):
    """جدول حلول: الأعمدة تُعرض من اليمين (المشكلة) إلى اليسار (الحل)."""
    l = Inches(0.4); w = SW - Inches(0.8)
    nrows = len(rows) + 1
    g = s.shapes.add_table(nrows, 3, l, top, w, Inches(row_h * nrows))
    tb = g.table
    tb._tbl.set('rtl', '1')
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
        cells = [(sol, GREEN, False), (eff, SLATE, False), (prob, INK, True)]
        for j, (text, col, bd) in enumerate(cells):
            c = tb.cell(i, j)
            c.fill.solid(); c.fill.fore_color.rgb = CARD if i % 2 else ROWALT
            c.vertical_anchor = MSO_ANCHOR.MIDDLE
            c.margin_left = c.margin_right = Pt(6); c.margin_top = c.margin_bottom = Pt(4)
            p = c.text_frame.paragraphs[0]; rtl(p); p.alignment = PP_ALIGN.RIGHT
            r = p.add_run(); r.text = text; r.font.size = Pt(fsize); r.font.name = F
            r.font.color.rgb = col; r.font.bold = bd
    return g


# إجمالي عدد الشرائح (يُستخدم في ترقيم الصفحات)
TOTAL = 19
slides = []


def new():
    s = prs.slides.add_slide(BLANK); slides.append(s); return s


# ============================================================= 1) الغلاف
s = new()
rect(s, 0, 0, SW, SH, INK)
rect(s, 0, Inches(3.15), SW, Pt(4), GOLD)
txt(s, Inches(1), Inches(0.85), SW - Inches(2), Inches(0.5),
    'مجموعة الذيابي للمقاولات', size=17, color=GOLD, bold=True, align=PP_ALIGN.CENTER)
txt(s, Inches(0.7), Inches(1.85), SW - Inches(1.4), Inches(1.2),
    'تطوير وحوكمة منظومة المشتريات وسلسلة الإمداد', size=40, color=WHITE,
    bold=True, align=PP_ALIGN.CENTER)
txt(s, Inches(1), Inches(3.35), SW - Inches(2), Inches(0.6),
    'تشخيص الوضع الراهن — وحلول عملية لكل تحدٍّ — وخارطة طريق للاعتماد',
    size=18, color=GOLD, align=PP_ALIGN.CENTER)
txt(s, Inches(1), Inches(4.7), SW - Inches(2), Inches(1.5),
    [{'t': 'وثيقة قرار تنفيذية مرفوعة إلى سعادة المدير العام والإدارة العليا', 'size': 16, 'color': WHITE, 'bold': True, 'space': 8},
     {'t': 'إعداد: إدارة العمليات والمشتريات', 'size': 14, 'color': SAND}],
    align=PP_ALIGN.CENTER)

# ============================================================= 2) السياق والهدف
s = new(); brandbar(s, 'السياق والهدف من هذه الوثيقة', 'لماذا الآن؟')
bullets(s, Inches(0.5), Inches(1.5), SW - Inches(1), Inches(2.7), [
    {'t': 'إدارة المشتريات هي القلب الذي يربط المشاريع والصيانة والمالية والمستودعات والموردين؛ وأي خلل في تنظيمها ينعكس على الجميع.', 'bold': True, 'color': INK, 'size': 16},
    {'t': 'تراكمت ملاحظات متكرّرة في آلية العمل تؤثر على كفاءة الإنفاق وانتظام التوريد وعلاقتنا بالموردين.', 'size': 16},
    {'t': 'الهدف ليس تحميل أي إدارة اللوم، بل وضع سياسات ثابتة ومُلزِمة تنظّم العلاقة وتحمي مصلحة الشركة.', 'size': 16},
    {'t': 'المسار المقترح: مناقشة هذه النقاط مع الإدارات ذات العلاقة، ثم رفعها للإدارة العليا لاعتماد القرار المناسب لكل بند.', 'size': 16},
], gap=16)
decision(s, 'اعتماد هذه الوثيقة أساساً للنقاش المؤسسي ثم إقرار سياسة ثابتة لكل بند فيها.')
page(s, 2)

# ============================================================= 3) الملخص التنفيذي
s = new(); brandbar(s, 'الملخص التنفيذي', 'الصورة الكاملة في صفحة واحدة')
cards = [
    ('جوهر المشكلة', 'غياب دورة مستندية مُلزِمة وقناة موحّدة للطلبات وصلاحيات واضحة وسجل أسعار مرجعي.', RED),
    ('الأثر', 'ازدواج في الإنفاق، وتأخّر في التوريد، وتآكل في ثقة الموردين، وضعف في الرقابة على التكلفة.', AMBER),
    ('الحل', 'مأسسة المشتريات: قناة واحدة إلزامية + دورة موثّقة + مصفوفة صلاحيات + سجل أسعار + عقود إطارية.', GREEN),
    ('المطلوب', 'إقرار السياسات الثابتة وخارطة الطريق (أول 30 يوماً / حتى 90 يوماً / المدى البعيد).', INK),
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

# ============================================================= 4) لوحة التحديات
s = new(); brandbar(s, 'لوحة التحديات المرصودة', 'مصنّفة حسب درجة الأثر')
rowsT = [
    ('ازدواجية التوريد (شراء صنف ورّدته الصيانة فعلاً)', 'حرج', RED),
    ('الشراء المباشر خارج إدارة المشتريات', 'حرج', RED),
    ('بطء التحويل المالي للموردين', 'حرج', RED),
    ('الإفراط في صفة «عاجل» وتآكل ثقة الموردين', 'مرتفع', AMBER),
    ('الطلبات المعلّقة دون اعتماد أو تحويل', 'مرتفع', AMBER),
    ('تكرار التسعير وغياب سجل أسعار موحّد', 'مرتفع', AMBER),
    ('غياب مصفوفة صلاحيات ودورة مستندية واضحة', 'مرتفع', AMBER),
    ('عهدة قصر الياسمين على غير المنفّذ الفعلي', 'متوسط', GREEN),
    ('تعثّر طلبات البنية التحتية المتكررة الصغيرة', 'متوسط', GREEN),
    ('غياب عقود إطارية للطلبات الشهرية المتكررة', 'متوسط', GREEN),
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

# ============================================================= 5) لماذا يهم (الأثر)
s = new(); brandbar(s, 'لماذا يستحق الأمر قراراً عاجلاً', 'من ملاحظة تشغيلية إلى أثر على الربحية')
imp = [
    ('ازدواجية التوريد', 'دفعٌ مزدوج لنفس الاحتياج، والتزام مالي لم يكن ضرورياً.'),
    ('تكرار التسعير', 'إهدار وقت الفريق، وتفاوت سعر الصنف الواحد بين المشاريع.'),
    ('الشراء المباشر', 'فقدان قوة التفاوض ووفورات الشراء المجمّع لدى مورد واحد.'),
    ('«العاجل» الزائف', 'أسعار أعلى مقابل السرعة، وفتور تدريجي في استجابة الموردين.'),
    ('الطلبات المعلّقة', 'تأخّر التوريد وتعطّل الأعمال في المواقع.'),
    ('بطء التحويل المالي', 'توقّف الموردين عن التوريد، وتحميل المشتريات تبعة التأخير.'),
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

# ============================================================= 6) المحور 1
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

# ============================================================= 7) خريطة الدورة المستندية
s = new(); brandbar(s, 'خريطة الدورة المستندية الموحّدة', 'مسار واحد إلزامي من الاحتياج حتى الإغلاق')
steps = ['نشوء الاحتياج', 'طلب شراء رسمي\nبالمواصفات', 'فحص رصيد\nالمستودع',
         'الرجوع لسجل\nالأسعار', 'عروض ومقارنة\n(عند اللزوم)', 'الاعتماد حسب\nالصلاحية',
         'إصدار أمر\nالشراء', 'التحويل المالي\nضمن المدة', 'التوريد والاستلام\nوالمطابقة',
         'الإغلاق وتحديث\nسجل الأسعار']
per = 5; bw = Inches(2.32); bh = Inches(1.05)
gapx = (SW - Inches(0.6) - per * bw) / (per - 1)
for i, st in enumerate(steps):
    row = i // per; col = i % per
    x = SW - Inches(0.3) - bw - col * (bw + gapx)
    y = Inches(1.75) + row * Inches(2.0)
    co = GOLD if i in (2, 3, 5) else INK
    rect(s, x, y, bw, bh, co)
    txt(s, x, y, bw, bh, st.replace('\n', ' '), size=13, color=WHITE, bold=True,
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    if col < per - 1:
        txt(s, x - gapx, y, gapx, bh, '◄', size=20, color=MUTE, align=PP_ALIGN.CENTER,
            anchor=MSO_ANCHOR.MIDDLE, is_rtl=False)
    elif row == 0:
        txt(s, x, y + bh, bw, Inches(0.95), '▼', size=20, color=MUTE,
            align=PP_ALIGN.CENTER, is_rtl=False)
decision(s, 'منع أي توريد خارج هذا المسار، ووقف أي توريد موازٍ بعد إصدار أمر الشراء.')
page(s, 7)

# ============================================================= 8) المحور 2
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
page(s, 8)

# ============================================================= 9) المحور 3 (الصلاحيات بالأرقام)
s = new(); brandbar(s, 'ثالثاً: مصفوفة الصلاحيات والاعتماد', 'أرقام مقترحة قابلة للاعتماد')
tiers = [
    ('الشريحة الأولى', 'حتى 5,000 ريال', 'مدير المشتريات', 'دون عروض، ضمن السقف', GREEN),
    ('الشريحة الثانية', 'حتى 25,000 ريال', 'مدير المشتريات', 'عرضان كحد أدنى', GREEN),
    ('الشريحة الثالثة', 'حتى 100,000 ريال', 'المشتريات والمالية', 'ثلاثة عروض ومقارنة', AMBER),
    ('الشريحة الرابعة', 'أكثر من 100,000', 'المدير العام ولجنة', 'ثلاثة عروض وتفاوض', RED),
    ('مسار الطوارئ', 'حالات حرجة فعلاً', 'موافقة مسبقة موثّقة', 'سقف محدّد مع تبرير', INK),
]
cw = (SW - Inches(0.8)) / 5
for i, (ti, val, who, note, co) in enumerate(tiers):
    x = SW - Inches(0.4) - (i + 1) * cw + Inches(0.06); y = Inches(1.6)
    rect(s, x, y, cw - Inches(0.12), Inches(0.6), co)
    txt(s, x, y, cw - Inches(0.12), Inches(0.6), ti, size=14, color=WHITE, bold=True,
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    rect(s, x, y + Inches(0.66), cw - Inches(0.12), Inches(2.85), CARD, line=LINE)
    txt(s, x + Inches(0.03), y + Inches(0.76), cw - Inches(0.18), Inches(2.7),
        [{'t': val, 'size': 15, 'color': INK, 'bold': True, 'space': 8},
         {'t': 'المعتمِد', 'size': 11, 'color': GOLD, 'bold': True, 'space': 1},
         {'t': who, 'size': 13, 'color': SLATE, 'space': 8},
         {'t': 'الإجراء', 'size': 11, 'color': GOLD, 'bold': True, 'space': 1},
         {'t': note, 'size': 13, 'color': SLATE}], align=PP_ALIGN.CENTER)
txt(s, Inches(0.4), Inches(4.95), SW - Inches(0.8), Inches(0.5),
    'كل اعتماد يتبعه إصدار أمر شراء موثّق وأرشفته في سجل الاعتمادات للرجوع والتدقيق.',
    size=14, color=INK, bold=True, align=PP_ALIGN.CENTER)
decision(s, 'إقرار حد أدنى (5,000 ريال) يُشترى باعتماد مدير المشتريات دون عروض، واعتماد بقية الشرائح.')
page(s, 9)

# ============================================================= 10) المحور 4 (التسعير)
s = new(); brandbar(s, 'رابعاً: التسعير وسجل الأسعار المرجعي', 'إنهاء تكرار التسعير ودعم تسعير المشاريع')
soltable(s, Inches(1.5), [
    ('إنشاء سجل أسعار مرجعي موحّد يُرجَع إليه قبل أي استفسار من المورد.',
     'إهدار الوقت وتفاوت سعر الصنف الواحد.',
     'إعادة تسعير البنود نفسها لكل مشروع رغم التزويد بالأسعار سابقاً.'),
    ('تغذية السجل آلياً من فواتير الشراء في النظام المالي وتحديثه دورياً.',
     'غياب مرجع للمقارنة والرقابة على الأسعار.',
     'لا يوجد تاريخ لأسعار المواد رغم الشراء المستمر.'),
    ('تحديد مدة معيارية كافية لتسعير المنافسات تُتّفق عليها مسبقاً.',
     'أسعار غير دقيقة وضياع فرص التقديم.',
     'تسعير منافسات المشاريع تحت ضغط وقت غير كافٍ.'),
    ('الرجوع للسجل أولاً، ثم تحديث العروض للبنود المتغيّرة فقط.',
     'استهلاك علاقة المورد بكثرة طلبات التسعير.',
     'تكرار مخاطبة الموردين لكل تسعيرة جديدة.'),
], row_h=1.0, fsize=12.5)
page(s, 10)

# ============================================================= 11) المحور 5 (الموردون)
s = new(); brandbar(s, 'خامساً: الموردون والعلاقات التجارية', 'استعادة الثقة وضبط التعامل')
soltable(s, Inches(1.45), [
    ('ضبط صفة «العاجل» والالتزام بإغلاق الطلبات يعيدان جدية الموردين.',
     'تراجع الاستجابة وجودة العروض.',
     'تآكل مصداقية طلباتنا لدى الموردين وفتور تجاوبهم.'),
    ('إبرام عقود إطارية سنوية بأسعار ثابتة مع الموردين الرئيسيين.',
     'أسعار متذبذبة وتفاوض متكرّر.',
     'الطلبات الشهرية المتكررة وكبيرة الحجم بلا عقود.'),
    ('توفير ثلاثة عروض للمرة الأولى فقط، ثم اعتماد مورد ثابت.',
     'بطء متكرّر في التوريد.',
     'الطلبات المستديمة لقطاعات المجموعة تُسعّر كل مرة.'),
    ('تسليم المشتريات حصراً بالمشاكل القائمة والشخص المسؤول لتوحيد التعامل.',
     'تضارب وتكرار في معالجة المشاكل.',
     'مشاكل مع الموردين موزّعة على إدارات متعددة.'),
    ('تسليم المشتريات كشف حساب بالمديونية لتسويتها ضمن خطة.',
     'مخاطر ائتمانية وتعليق توريد.',
     'مديونيات على الصيانة والتشغيل لدى الموردين.'),
], row_h=0.92, fsize=12)
page(s, 11)

# ============================================================= 12) المحور 6 (الصيانة والتشغيل)
s = new(); brandbar(s, 'سادساً: تنظيم العلاقة مع الصيانة والتشغيل', 'إطار واضح للأدوار والمسارات')
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
page(s, 12)

# ============================================================= 13) المحور 7 (العهد والموارد)
s = new(); brandbar(s, 'سابعاً: العهد والموارد التشغيلية', 'معالجة الملفات العالقة وتمكين المشتريات')
soltable(s, Inches(1.55), [
    ('نقل عهدة قصر الياسمين إلى مسؤول المشروع باعتباره المنفّذ الفعلي للشراء.',
     'عدم تطابق المسؤولية مع المنفّذ.',
     'عهدة قصر الياسمين مسجّلة على مندوب المشتريات رغم أن الشراء عبر المشروع.'),
    ('اعتماد طلبات البنية التحتية دون عروض ضمن سقف محدّد ومورد إطاري.',
     'تأخّر احتياجات متكررة منخفضة القيمة.',
     'طلبات البنية التحتية أسبوعية صغيرة متكررة وليست تحت سقف مورد واحد.'),
    ('تخصيص عهدة مالية مستديمة للمشتريات باعتماد مديرها للحالات الصغيرة.',
     'بطء تنفيذ البنود البسيطة العاجلة.',
     'لا توجد عهدة نقدية لدى المشتريات.'),
    ('تعيين سائق تابع لإدارة المشتريات لتوريد الطلبات إلى المواقع.',
     'تأخّر التسليم والاعتماد على الغير.',
     'لا توجد وسيلة توريد مخصّصة للمواقع.'),
], row_h=1.05, fsize=12.5)
page(s, 13)

# ============================================================= 14) المحور 8 (المالية)
s = new(); brandbar(s, 'ثامناً: التكامل مع الإدارة المالية', 'إزالة اختناق التحويل')
soltable(s, Inches(1.7), [
    ('التزام زمني للتحويل (3–5 أيام عمل، و24 ساعة للطوارئ المعتمدة) ودفعات أسبوعية مجمّعة.',
     'تعطّل الموردين وتحميل المشتريات تبعة التأخير.',
     'بطء استجابة الإدارة المالية لتحويلات الموردين.'),
    ('ربط فواتير الشراء بسجل الأسعار آلياً لتغذيته أولاً بأول.',
     'استمرار تكرار التسعير وغياب المرجع.',
     'عدم تغذية سجل الأسعار من النظام المالي.'),
    ('اعتماد مسار طوارئ مالي بموافقة مسبقة موثّقة وسقف محدّد.',
     'استخدام صفة «العاجل» للالتفاف على الإجراءات.',
     'غياب مسار طوارئ مالي محكوم.'),
], row_h=1.15, fsize=13)
page(s, 14)

# ============================================================= 15) نموذج الحوكمة
s = new(); brandbar(s, 'نموذج الحوكمة المقترح', 'المشتريات قناة واحدة محكومة بأربع ركائز')
# المدير العام
rect(s, SW/2 - Inches(2.0), Inches(1.45), Inches(4.0), Inches(0.7), INK)
txt(s, SW/2 - Inches(2.0), Inches(1.45), Inches(4.0), Inches(0.7), 'الإدارة العليا / المدير العام',
    size=16, color=WHITE, bold=True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
txt(s, SW/2 - Inches(0.3), Inches(2.18), Inches(0.6), Inches(0.4), '▼', size=18,
    color=MUTE, align=PP_ALIGN.CENTER, is_rtl=False)
# المشتريات (العقدة المركزية)
rect(s, SW/2 - Inches(2.4), Inches(2.6), Inches(4.8), Inches(0.85), GOLD)
txt(s, SW/2 - Inches(2.4), Inches(2.6), Inches(4.8), Inches(0.85),
    'إدارة المشتريات — القناة الموحّدة الإلزامية', size=16, color=INK, bold=True,
    align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
# الأطراف
parts = ['الإدارات الطالبة\n(المشاريع والصيانة)', 'الإدارة المالية', 'المستودعات', 'الموردون']
pw = Inches(2.9); gap = (SW - Inches(0.8) - 4 * pw) / 3
for i, p in enumerate(parts):
    x = SW - Inches(0.4) - pw - i * (pw + gap); y = Inches(3.95)
    rect(s, x, y, pw, Inches(0.8), INK2)
    txt(s, x, y, pw, Inches(0.8), p.replace('\n', ' '), size=13, color=WHITE, bold=True,
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
# الركائز الأربع
txt(s, Inches(0.4), Inches(4.95), SW - Inches(0.8), Inches(0.4),
    'الركائز الحاكمة الأربع', size=13, color=GOLD, bold=True, align=PP_ALIGN.CENTER)
pillars = ['دورة مستندية موثّقة', 'مصفوفة صلاحيات', 'سجل أسعار مرجعي', 'قائمة موردين معتمدة']
pw2 = (SW - Inches(1.0)) / 4
for i, p in enumerate(pillars):
    x = SW - Inches(0.4) - (i + 1) * pw2 + Inches(0.05); y = Inches(5.35)
    rect(s, x, y, pw2 - Inches(0.1), Inches(0.6), CARD, line=GOLD, lw=1.5)
    txt(s, x, y, pw2 - Inches(0.1), Inches(0.6), p, size=13, color=INK, bold=True,
        align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
decision(s, 'اعتماد المشتريات قناةً موحّدة لكل القطاعات، محكومةً بالركائز الأربع.')
page(s, 15)

# ============================================================= 16) خارطة الطريق
s = new(); brandbar(s, 'خارطة طريق التنفيذ', 'مراحل زمنية واضحة وقابلة للقياس')
phases = [
    ('أول 30 يوماً', 'تثبيت الحوكمة', GREEN,
     ['النموذج الموحّد للطلبات', 'مصفوفة الصلاحيات بقيمها',
      'حصر الشراء عبر المشتريات', 'التزام المالية الزمني', 'إيقاف ازدواجية التوريد']),
    ('حتى 90 يوماً', 'البناء المؤسسي', AMBER,
     ['سجل الأسعار من المالية', 'العقود الإطارية للمتكرر',
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
page(s, 16)

# ============================================================= 17) مؤشرات النجاح
s = new(); brandbar(s, 'مؤشرات قياس النجاح', 'ما لا يُقاس لا يُمكن تطويره')
kpis = [
    ('زمن دورة الشراء', 'من الطلب حتى أمر الشراء', 'تقليصه الى النصف'),
    ('التزام الطلبات بالدورة', 'نسبة الطلبات الرسمية', 'لا تقل عن 95٪'),
    ('إغلاق الطلبات في وقتها', 'دون معلّقات متراكمة', 'لا معلّقات متأخرة'),
    ('الوفر المحقّق', 'مقارنةً بسجل الأسعار', 'يُقاس كل ربع سنة'),
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
page(s, 17)

# ============================================================= 18) القرارات المطلوبة
s = new(); brandbar(s, 'القرارات المطلوبة من الإدارة العليا', 'ثمانية قرارات تُنهي التكرار')
asks = [
    'حصر كل شراء وتوريد لقطاعات المجموعة عبر المشتريات حصراً.',
    'اعتماد النموذج الموحّد للطلبات ومصفوفة الصلاحيات.',
    'إلزام الإدارة المالية بمدة زمنية للتحويل ومسار طوارئ.',
    'إنشاء سجل أسعار مرجعي يُغذّى من النظام المالي.',
    'تفويض إبرام عقود إطارية للطلبات المتكررة والبنية التحتية.',
    'نقل عهدة قصر الياسمين إلى مسؤول المشروع.',
    'تخصيص عهدة مالية وسائق لإدارة المشتريات.',
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
    txt(s, x + Inches(0.12), y, cw - Inches(0.85), Inches(0.82), a, size=13.5,
        color=INK, bold=True, align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.MIDDLE)
page(s, 18)

# ============================================================= 19) الخاتمة
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

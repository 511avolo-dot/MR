#!/usr/bin/env python3
"""بناء عرض تقديمي تنفيذي لمنظومة المشتريات — RTL عربي بترميز لوني."""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.oxml.ns import qn
import copy

# ---------- لوحة الألوان المؤسسية ----------
NAVY   = RGBColor(0x1F, 0x2A, 0x37)   # خلفية داكنة
GOLD   = RGBColor(0xB0, 0x8D, 0x57)   # ذهبي/برونزي (هوية الذيابي)
LIGHT  = RGBColor(0xF4, 0xF1, 0xEA)   # خلفية فاتحة
GREY   = RGBColor(0x5B, 0x66, 0x70)
WHITE  = RGBColor(0xFF, 0xFF, 0xFF)
RED    = RGBColor(0xC0, 0x39, 0x2B)   # أولوية عالية
AMBER  = RGBColor(0xE0, 0x8E, 0x0B)   # أولوية متوسطة
GREEN  = RGBColor(0x2E, 0x7D, 0x32)   # أولوية/إيجابي
DARK   = RGBColor(0x22, 0x2A, 0x33)

FONT = "Arial"
prs = Presentation()
prs.slide_width  = Inches(13.333)
prs.slide_height = Inches(7.5)
SW, SH = prs.slide_width, prs.slide_height
BLANK = prs.slide_layouts[6]


def set_rtl(p):
    pPr = p._pPr if p._pPr is not None else p.get_or_add_pPr()
    pPr.set('rtl', '1')


def add_text(slide, l, t, w, h, lines, *, size=18, color=DARK, bold=False,
             align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.TOP, rtl=True,
             font=FONT, space=6, fill=None, line_color=None):
    tb = slide.shapes.add_textbox(l, t, w, h)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_left = tf.margin_right = Pt(8)
    tf.margin_top = tf.margin_bottom = Pt(4)
    if fill is not None:
        tb.fill.solid(); tb.fill.fore_color.rgb = fill
    else:
        tb.fill.background()
    if line_color is not None:
        tb.line.color.rgb = line_color; tb.line.width = Pt(0.75)
    else:
        tb.line.fill.background()
    if isinstance(lines, str):
        lines = [lines]
    for i, item in enumerate(lines):
        if isinstance(item, dict):
            txt = item.get('t', ''); sz = item.get('size', size)
            col = item.get('color', color); bd = item.get('bold', bold)
        else:
            txt, sz, col, bd = item, size, color, bold
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        if rtl:
            set_rtl(p)
        p.alignment = align
        p.space_after = Pt(space)
        r = p.add_run(); r.text = txt
        r.font.size = Pt(sz); r.font.bold = bd; r.font.name = font
        r.font.color.rgb = col
    return tb


def rect(slide, l, t, w, h, fill, line=None):
    from pptx.enum.shapes import MSO_SHAPE
    sp = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, l, t, w, h)
    sp.fill.solid(); sp.fill.fore_color.rgb = fill
    if line: sp.line.color.rgb = line; sp.line.width = Pt(1)
    else: sp.line.fill.background()
    sp.shadow.inherit = False
    return sp


def bg(slide, color):
    rect(slide, 0, 0, SW, SH, color)


def header(slide, kicker, title, idx):
    """ترويسة موحّدة للشرائح الداخلية."""
    bg(slide, LIGHT)
    rect(slide, 0, 0, SW, Inches(1.25), NAVY)
    rect(slide, 0, Inches(1.25), SW, Pt(5), GOLD)
    # شعار نصي يمين
    add_text(slide, SW-Inches(3.4), Inches(0.18), Inches(3.2), Inches(0.9),
             [{'t':'مجموعة الذيابي للمقاولات','size':14,'color':GOLD,'bold':True},
              {'t':'AL-DEYABI GROUP','size':10,'color':WHITE}],
             align=PP_ALIGN.RIGHT, space=0)
    # عنوان يسار/وسط
    add_text(slide, Inches(0.3), Inches(0.16), Inches(9.6), Inches(0.55),
             title, size=24, color=WHITE, bold=True, align=PP_ALIGN.RIGHT)
    add_text(slide, Inches(0.3), Inches(0.74), Inches(9.6), Inches(0.4),
             kicker, size=13, color=GOLD, bold=True, align=PP_ALIGN.RIGHT)
    # رقم الشريحة
    add_text(slide, Inches(0.3), SH-Inches(0.5), Inches(2), Inches(0.35),
             f"{idx} / 16", size=11, color=GREY, align=PP_ALIGN.LEFT, rtl=False)


def decision(slide, text, y=None):
    """شريط القرار المطلوب أسفل الشريحة."""
    if y is None:
        y = SH - Inches(1.15)
    rect(slide, Inches(0.3), y, SW-Inches(0.6), Inches(0.8), NAVY)
    rect(slide, SW-Inches(0.6)-Pt(6), y, Pt(6), Inches(0.8), GOLD)
    add_text(slide, Inches(0.5), y+Inches(0.06), SW-Inches(1.1), Inches(0.7),
             [{'t':'القرار المطلوب','size':12,'color':GOLD,'bold':True},
              {'t':text,'size':14,'color':WHITE}],
             anchor=MSO_ANCHOR.MIDDLE, align=PP_ALIGN.RIGHT, space=2)


def bullets(slide, l, t, w, h, items, size=16, gap=10):
    tb = slide.shapes.add_textbox(l, t, w, h); tf = tb.text_frame
    tf.word_wrap = True
    for i, it in enumerate(items):
        txt = it['t'] if isinstance(it, dict) else it
        col = it.get('color', DARK) if isinstance(it, dict) else DARK
        bd  = it.get('bold', False) if isinstance(it, dict) else False
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        set_rtl(p); p.alignment = PP_ALIGN.RIGHT; p.space_after = Pt(gap)
        r = p.add_run(); r.text = "•  " + txt
        r.font.size = Pt(size); r.font.name = FONT; r.font.color.rgb = col; r.font.bold = bd
    return tb


def table(slide, l, t, w, headers, rows, col_w=None, fsize=12, hsize=12, row_h=0.42):
    nrows = len(rows) + 1; ncols = len(headers)
    h = Inches(row_h * nrows)
    gframe = slide.shapes.add_table(nrows, ncols, l, t, w, h)
    tbl = gframe.table
    # اتجاه RTL للجدول
    tblPr = tbl._tbl.tblPr
    tblPr.set('{http://schemas.openxmlformats.org/drawingml/2006/main}rtl', '1')
    tbl._tbl.set('rtl', '1')
    if col_w:
        total = sum(col_w)
        for i, cw in enumerate(col_w):
            tbl.columns[i].width = Emu(int(w * cw / total))
    # رؤوس
    for j, htext in enumerate(headers):
        c = tbl.cell(0, j); c.fill.solid(); c.fill.fore_color.rgb = NAVY
        c.vertical_anchor = MSO_ANCHOR.MIDDLE
        c.margin_left = c.margin_right = Pt(4); c.margin_top = c.margin_bottom = Pt(2)
        p = c.text_frame.paragraphs[0]; set_rtl(p); p.alignment = PP_ALIGN.CENTER
        r = p.add_run(); r.text = htext; r.font.size = Pt(hsize); r.font.bold = True
        r.font.color.rgb = WHITE; r.font.name = FONT
    for i, row in enumerate(rows, start=1):
        for j, cell in enumerate(row):
            txt = cell['t'] if isinstance(cell, dict) else cell
            cfill = cell.get('fill') if isinstance(cell, dict) else None
            ccol  = cell.get('color', DARK) if isinstance(cell, dict) else DARK
            cbold = cell.get('bold', False) if isinstance(cell, dict) else False
            c = tbl.cell(i, j)
            c.fill.solid(); c.fill.fore_color.rgb = cfill if cfill else (WHITE if i % 2 else RGBColor(0xEC,0xE7,0xDD))
            c.vertical_anchor = MSO_ANCHOR.MIDDLE
            c.margin_left = c.margin_right = Pt(4); c.margin_top = c.margin_bottom = Pt(2)
            p = c.text_frame.paragraphs[0]; set_rtl(p); p.alignment = PP_ALIGN.CENTER
            r = p.add_run(); r.text = txt; r.font.size = Pt(fsize); r.font.name = FONT
            r.font.color.rgb = ccol; r.font.bold = cbold
    return gframe


# ===================== الشريحة 1: الغلاف =====================
s = prs.slides.add_slide(BLANK)
bg(s, NAVY)
rect(s, 0, Inches(3.05), SW, Pt(4), GOLD)
add_text(s, Inches(1), Inches(0.7), SW-Inches(2), Inches(0.7),
         [{'t':'مجموعة الذيابي للمقاولات   |   AL-DEYABI GROUP','size':16,'color':GOLD,'bold':True}],
         align=PP_ALIGN.CENTER)
add_text(s, Inches(0.8), Inches(2.0), SW-Inches(1.6), Inches(1.1),
         'إعادة هيكلة وحوكمة منظومة المشتريات وسلسلة الإمداد',
         size=40, color=WHITE, bold=True, align=PP_ALIGN.CENTER)
add_text(s, Inches(1), Inches(3.25), SW-Inches(2), Inches(0.7),
         'من العمل التفاعلي (Reactive) إلى منظومة مؤسسية محوكمة (Governed Procurement)',
         size=18, color=GOLD, align=PP_ALIGN.CENTER)
add_text(s, Inches(1), Inches(4.5), SW-Inches(2), Inches(1.6),
         [{'t':'وثيقة قرار تنفيذي — Executive Decision Document','size':16,'color':WHITE,'bold':True},
          {'t':'مُوجَّه إلى: سعادة المدير العام والإدارة التنفيذية','size':15,'color':LIGHT},
          {'t':'إعداد: إدارة العمليات / المشتريات','size':15,'color':LIGHT}],
         align=PP_ALIGN.CENTER, space=8)

# ===================== الشريحة 2: الملخص التنفيذي =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Executive Summary', 'الملخص التنفيذي', 2)
bullets(s, Inches(0.5), Inches(1.55), SW-Inches(1), Inches(2.4), [
    {'t':'قسم المشتريات يُدار ضمن بيئة غير محوكمة (Ungoverned) تفتقر لنظام موحّد ومصفوفة صلاحيات وسجل أسعار مرجعي.','bold':True},
    'النتيجة: تسرّب مالي (Cost Leakage)، وازدواجية إنفاق، وتآكل قوّتنا التفاوضية مع الموردين.',
    'المشكلة ليست في الأداء الفردي، بل في غياب البنية المؤسسية (Operating Model) التي تحكم التدفق.',
    'المشتريات نقطة التقاء حرجة بين: المالية، المستودعات، إدارات المشاريع، والصيانة والتشغيل — أي خلل يتضخّم عبر السلسلة.',
], size=17, gap=14)
decision(s, 'اعتماد مبدأ «قناة مشتريات موحّدة وإلزامية» (Single Procurement Channel) والمصادقة على خارطة الطريق (30/90 يوماً + مدى بعيد).')

# ===================== الشريحة 3: خريطة التحديات =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Current State & Gap Analysis', 'خريطة التحديات الحالية', 3)
table(s, Inches(0.4), Inches(1.5), SW-Inches(0.8),
      ['#','التحدي التشغيلي','التصنيف','الأثر على الشركة'],
      [
       ['1','تعدّد جهات الطلب وغياب القناة الموحّدة',{'t':'حوكمة','color':GREY},'فقدان الرؤية الكاملة (E2E Visibility)'],
       ['2','ازدواجية التوريد (صنف ورّدته الصيانة فعلاً)',{'t':'مالي حرج','color':WHITE,'fill':RED,'bold':True},'التزام مالي مزدوج + إهدار جهد'],
       ['3','الشراء المباشر خارج المشتريات',{'t':'رقابي','color':WHITE,'fill':AMBER},'تسرّب التكلفة + ضعف تفاوضي'],
       ['4','الإفراط في صفة «عاجل/مستعجل»',{'t':'سمعة','color':WHITE,'fill':AMBER},'تآكل مصداقيتنا كعميل لدى الموردين'],
       ['5','طلبات معلّقة دون بتّ لفترات طويلة',{'t':'تشغيلي','color':GREY},'تراكم + تأخّر تنفيذ'],
       ['6','غياب سجل أسعار مرجعي (Price Master)',{'t':'مالي','color':WHITE,'fill':AMBER},'تكرار التسعير + تفاوت أسعار الصنف'],
       ['7','غياب مصفوفة الصلاحيات (Approval Matrix)',{'t':'حوكمة','color':GREY},'عشوائية الاعتماد والتعميد'],
       ['8','اختناق التحويل المالي للموردين',{'t':'مالي حرج','color':WHITE,'fill':RED,'bold':True},'تعطّل التوريد + إضرار بالعلاقات'],
      ],
      col_w=[0.5,4,1.6,4], fsize=12.5, row_h=0.46)
decision(s, 'إقرار القائمة كـ«سجل مخاطر تشغيلية رسمي» (Operational Risk Register) يُتابَع دورياً.')

# ===================== الشريحة 4: من شكوى إلى ربحية =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Reframing the Narrative', 'من «الشكوى» إلى «الأثر على الربحية»', 4)
add_text(s, SW/2+Inches(0.1), Inches(1.55), SW/2-Inches(0.5), Inches(0.5),
         'المشتريات = مركز توفير محتمل (Value Center) لا مركز تكلفة',
         size=15, color=NAVY, bold=True, align=PP_ALIGN.RIGHT)
# بطاقات آلية التسرب
cards = [
    ('ازدواجية التوريد','دفع مرتين لنفس الاحتياج (Double Payment Risk)',RED),
    ('غياب سجل الأسعار','تفاوت سعر الصنف عبر المشاريع (Price Variance)',AMBER),
    ('الشراء المباشر','فقدان وفورات التجميع (Economies of Scale)',AMBER),
    ('«العاجل» الزائف','أسعار أعلى مقابل السرعة (Urgency Premium)',RED),
]
cy = Inches(2.2)
for i,(ti,de,co) in enumerate(cards):
    row, col = divmod(i,2)
    cx = Inches(0.5) + col*(SW/2-Inches(0.35))
    yy = cy + row*Inches(1.25)
    rect(s, cx, yy, SW/2-Inches(0.6), Inches(1.05), WHITE, line=RGBColor(0xDD,0xD6,0xC8))
    rect(s, cx, yy, Pt(7), Inches(1.05), co)
    add_text(s, cx+Inches(0.1), yy+Inches(0.08), SW/2-Inches(0.8), Inches(0.9),
             [{'t':ti,'size':16,'color':NAVY,'bold':True},{'t':de,'size':13,'color':GREY}],
             align=PP_ALIGN.RIGHT, space=4)
decision(s, 'تكليف المشتريات بقياس «الوفر المحقّق» (Realized Savings) كمؤشر أداء معتمد ربع سنوي.')

# ===================== الشريحة 5: الفجوة الجوهرية =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Root-Cause Gap', 'الفجوة الجوهرية: غياب النموذج التشغيلي الموحّد', 5)
gaps = [
    ('1','فجوة الأنظمة','System Gap','لا نظام موحّد لتلقّي الطلبات (بريد / واتساب / شفهي)'),
    ('2','فجوة الصلاحيات','Authority Gap','لا مصفوفة اعتماد واضحة حسب القيمة'),
    ('3','فجوة البيانات','Data Gap','لا سجل أسعار ولا قاعدة موردين معتمدة'),
    ('4','فجوة الالتزام','Compliance Gap','الدورة المعتمدة غير مُلزِمة عملياً'),
]
for i,(n,ar,en,de) in enumerate(gaps):
    yy = Inches(1.7) + i*Inches(1.0)
    rect(s, Inches(0.5), yy, SW-Inches(1), Inches(0.85), WHITE, line=RGBColor(0xDD,0xD6,0xC8))
    rect(s, SW-Inches(1.3), yy, Inches(0.8), Inches(0.85), NAVY)
    add_text(s, SW-Inches(1.3), yy, Inches(0.8), Inches(0.85), n, size=28, color=GOLD,
             bold=True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, rtl=False)
    add_text(s, Inches(0.7), yy+Inches(0.06), SW-Inches(2.2), Inches(0.75),
             [{'t':f'{ar}  —  {en}','size':17,'color':NAVY,'bold':True},
              {'t':de,'size':14,'color':GREY}], align=PP_ALIGN.RIGHT, space=2,
             anchor=MSO_ANCHOR.MIDDLE)

# ===================== الشريحة 6: العقدة المركزية =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Cross-Functional Dependencies', 'المشتريات كعقدة مركزية في سلسلة القيمة', 6)
table(s, Inches(0.4), Inches(1.55), SW-Inches(0.8),
      ['الإدارة','مُدخل للمشتريات','تتأثر بالمشتريات','نقطة الاحتكاك الحالية'],
      [
       ['الإدارات الطالبة','طلب احتياج (PR) بمواصفات','استلام الصنف في الوقت','طلبات ناقصة + شراء مباشر'],
       ['المالية','اعتماد + تحويل للمورد','كفاءة الإنفاق والسيولة',{'t':'بطء التحويل (Bottleneck)','color':RED,'bold':True}],
       ['المستودعات','رصيد متاح + استلام','دقة التخطيط ومنع التكرار','ضعف ربط الرصيد بالطلب'],
       ['الموردون','عروض + توريد','استمرارية وأسعار تنافسية',{'t':'تآكل الثقة بسبب «العاجل»','color':RED,'bold':True}],
      ],
      col_w=[1.6,3,3,3.2], fsize=13, row_h=0.62)
decision(s, 'اعتماد اتفاقيات مستوى خدمة داخلية (Internal SLAs) بين المشتريات وكل إدارة.')

# ===================== الشريحة 7: RACI =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Governance — RACI Matrix', 'مصفوفة المسؤوليات RACI لدورة الشراء', 7)
def chip(t):
    cmap={'R':GREEN,'A':RED,'C':AMBER,'I':GREY}
    return {'t':t,'color':WHITE,'fill':cmap.get(t,GREY),'bold':True}
table(s, Inches(0.8), Inches(1.6), SW-Inches(1.6),
      ['النشاط','الإدارة الطالبة','المشتريات','المالية','المدير العام'],
      [
       ['رفع الاحتياج (PR)',chip('R'),chip('C'),chip('I'),chip('I')],
       ['التسعير والمقارنة',chip('I'),chip('R'),chip('I'),chip('I')],
       ['اعتماد القيمة',chip('I'),chip('C'),chip('A'),chip('A')],
       ['إصدار أمر الشراء (PO)',chip('I'),chip('R'),chip('I'),chip('I')],
       ['التحويل المالي',chip('I'),chip('C'),chip('R'),chip('I')],
       ['الاستلام والمطابقة',chip('R'),chip('C'),chip('I'),chip('I')],
      ],
      col_w=[3,1.7,1.7,1.7,1.7], fsize=13, row_h=0.5)
add_text(s, Inches(0.8), Inches(5.05), SW-Inches(1.6), Inches(0.4),
         'R = منفّذ   |   A = معتمِد   |   C = يُستشار   |   I = يُبلَّغ',
         size=13, color=GREY, align=PP_ALIGN.CENTER)
decision(s, 'اعتماد مصفوفة RACI كمرجع إلزامي لجميع الإدارات.')

# ===================== الشريحة 8: الفلو الأول =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Workflow 1 — Standard Procurement', 'مسار الطلب الموحّد: من الاحتياج حتى الاستلام', 8)
steps = ['نشوء الاحتياج','رفع PR رسمي\n+ مواصفات','فحص المستودعات','فحص سجل الأسعار',
         'طلب عروض ومقارنة\n(3 عروض)','الاعتماد حسب\nمصفوفة الصلاحيات','إصدار أمر الشراء (PO)',
         'التحويل المالي\nضمن SLA','التوريد والاستلام\n(3-Way Match)','إغلاق + تغذية\nسجل الأسعار']
# تدفق من اليمين لليسار، صفّان
per_row = 5; bw, bh = Inches(2.3), Inches(1.0)
gap_x = (SW - Inches(0.6) - per_row*bw) / (per_row-1)
for i, st in enumerate(steps):
    row = i // per_row; idx_in = i % per_row
    # يمين لليسار
    x = SW - Inches(0.3) - bw - idx_in*(bw+gap_x)
    y = Inches(1.7) + row*Inches(1.9)
    col = GOLD if i in (2,3,5) else NAVY
    rect(s, x, y, bw, bh, col)
    num = {'t':str(i+1)}
    add_text(s, x, y+Inches(0.04), bw, bh-Inches(0.08),
             [{'t':st.replace('\n',' '),'size':13,'color':WHITE,'bold':True}],
             align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    # سهم
    if idx_in < per_row-1:
        add_text(s, x-gap_x, y, gap_x, bh, '◄', size=18, color=GREY,
                 align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, rtl=False)
    elif row == 0 and i == per_row-1:
        add_text(s, x-Inches(0.1), y+bh, bw, Inches(0.9), '▼', size=18, color=GREY,
                 align=PP_ALIGN.CENTER, rtl=False)
decision(s, 'اعتماد هذا المسار كالدورة الإلزامية الوحيدة؛ ومنع أي توريد خارجها بعد إصدار الـ PO.')

# ===================== الشريحة 9: الفلو الثاني (صلاحيات بأرقام) =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Workflow 2 — Approval Matrix', 'مسار الاعتماد والتعميد حسب القيمة (أرقام مقترحة)', 9)
tiers = [
    ('الشريحة A','حتى 5,000 ر.س','مدير المشتريات','بدون عروض (ضمن السقف)',GREEN),
    ('الشريحة B','حتى 25,000 ر.س','مدير المشتريات','عرضان كحد أدنى',GREEN),
    ('الشريحة C','حتى 100,000 ر.س','مشتريات + المالية','ثلاثة عروض ومقارنة',AMBER),
    ('الشريحة D','أكثر من 100,000','المدير العام + لجنة','ثلاثة عروض + تفاوض',RED),
    ('Fast-Track','طوارئ فعلية','موافقة مسبقة موثّقة','سقف محدد + تبرير',NAVY),
]
cw = (SW - Inches(0.8)) / 5
for i,(ti,val,appr,note,co) in enumerate(tiers):
    x = SW - Inches(0.4) - (i+1)*cw + Inches(0.05)
    y = Inches(1.75)
    rect(s, x, y, cw-Inches(0.1), Inches(0.55), co)
    add_text(s, x, y, cw-Inches(0.1), Inches(0.55), ti, size=15, color=WHITE,
             bold=True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    rect(s, x, y+Inches(0.6), cw-Inches(0.1), Inches(2.7), WHITE, line=RGBColor(0xDD,0xD6,0xC8))
    add_text(s, x+Inches(0.03), y+Inches(0.7), cw-Inches(0.16), Inches(2.5),
             [{'t':val,'size':14,'color':NAVY,'bold':True},
              {'t':'—','size':10,'color':WHITE},
              {'t':'المعتمِد:','size':11,'color':GOLD,'bold':True},
              {'t':appr,'size':13,'color':DARK},
              {'t':'—','size':10,'color':WHITE},
              {'t':'الإجراء:','size':11,'color':GOLD,'bold':True},
              {'t':note,'size':13,'color':DARK}],
             align=PP_ALIGN.CENTER, space=3)
add_text(s, Inches(0.4), Inches(4.7), SW-Inches(0.8), Inches(0.5),
         'كل اعتماد ← إصدار PO بختم موثّق ← أرشفة في سجل الاعتمادات (Audit Trail)',
         size=14, color=NAVY, bold=True, align=PP_ALIGN.CENTER)
decision(s, 'اعتماد قيم الشرائح (قابلة للتعديل) وربط Fast-Track بموافقة مسبقة موثّقة فقط — لإنهاء فوضى «العاجل».')

# ===================== الشريحة 10: اختناق المالية =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Finance Bottleneck & SLA', 'معالجة اختناق المالية', 10)
add_text(s, Inches(0.5), Inches(1.5), SW-Inches(1), Inches(0.9),
         [{'t':'بطء التحويل المالي = اختناق (Bottleneck) يُبطل كفاءة كل المراحل السابقة، ويُنسب التأخير ظلماً للمشتريات أمام الموردين.','size':16,'color':RED,'bold':True}],
         align=PP_ALIGN.RIGHT)
sols = [
    ('1','اتفاقية مستوى خدمة (Finance SLA)','سقف ملزم: 3–5 أيام عمل اعتيادي / 24 ساعة للطوارئ المعتمدة'),
    ('2','الدفعات المجمّعة (Batch Runs)','دورتا صرف أسبوعيتان ثابتتان بدل المعالجة الفردية العشوائية'),
    ('3','مسار الطوارئ المحكوم (Fast-Track)','قناة سريعة للحالات الحرجة فقط بموافقة مسبقة وسقف محدد'),
    ('4','تنبيهات وتصعيد تلقائي (Auto-Escalation)','تنبيه عند تجاوز SLA + لوحة متابعة المعلّقات (Aging Dashboard)'),
]
for i,(n,ti,de) in enumerate(sols):
    row,col = divmod(i,2)
    x = Inches(0.5)+col*(SW/2-Inches(0.35)); y=Inches(2.5)+row*Inches(1.2)
    rect(s, x, y, SW/2-Inches(0.6), Inches(1.0), WHITE, line=RGBColor(0xDD,0xD6,0xC8))
    rect(s, x+SW/2-Inches(0.6)-Inches(0.7), y, Inches(0.7), Inches(1.0), GOLD)
    add_text(s, x+SW/2-Inches(0.6)-Inches(0.7), y, Inches(0.7), Inches(1.0), n,
             size=26, color=WHITE, bold=True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, rtl=False)
    add_text(s, x+Inches(0.1), y+Inches(0.08), SW/2-Inches(1.4), Inches(0.85),
             [{'t':ti,'size':15,'color':NAVY,'bold':True},{'t':de,'size':12,'color':GREY}],
             align=PP_ALIGN.RIGHT, space=3, anchor=MSO_ANCHOR.MIDDLE)
decision(s, 'الاعتراف بزمن التحويل كمؤشر مشترك (Shared KPI)؛ اعتماد (1) و(2) فوراً و(3) و(4) خلال 90 يوماً.')

# ===================== الشريحة 11: خارطة الطريق =====================
s = prs.slides.add_slide(BLANK)
header(s, 'Institutionalization Roadmap', 'خارطة طريق المأسسة', 11)
phases = [
    ('أول 30 يوماً','Quick Wins — تثبيت الحوكمة',GREEN,
     ['القناة الموحّدة للطلبات (PR رسمي إلزامي)','إصدار مصفوفة الصلاحيات بقيمها',
      'توقيع Finance SLA','وقف الشراء المباشر رسمياً']),
    ('حتى 90 يوماً','البناء المؤسسي',AMBER,
     ['إطلاق سجل الأسعار (Price Master) من المالية','قاعدة موردين + عقود إطارية للمتكرر',
      'مسار الطوارئ + لوحة المعلّقات','معالجة عهدة قصر الياسمين والبنية التحتية']),
    ('المدى البعيد','التحول الرقمي والتميّز',NAVY,
     ['نظام e-Procurement متكامل','لوحات KPI آنية',
      'تقييم موردين (Vendor Scorecard)','استراتيجية مصادر (Sourcing)']),
]
cw = (SW - Inches(1.0)) / 3
for i,(ti,sub,co,items) in enumerate(phases):
    x = Inches(0.4) + i*(cw+Inches(0.1))
    rect(s, x, Inches(1.6), cw, Inches(0.9), co)
    add_text(s, x, Inches(1.66), cw, Inches(0.8),
             [{'t':ti,'size':20,'color':WHITE,'bold':True},{'t':sub,'size':12,'color':LIGHT}],
             align=PP_ALIGN.CENTER, space=2, anchor=MSO_ANCHOR.MIDDLE)
    rect(s, x, Inches(2.55), cw, Inches(3.3), WHITE, line=RGBColor(0xDD,0xD6,0xC8))
    bullets(s, x+Inches(0.1), Inches(2.7), cw-Inches(0.2), Inches(3.0),
            items, size=14, gap=14)
decision(s, 'المصادقة على خارطة الطريق الزمنية وتكليف لجنة تنفيذية بمتابعة الإنجاز.')

# ===================== الشريحة 12: KPIs =====================
s = prs.slides.add_slide(BLANK)
header(s, 'KPIs Dashboard', 'مؤشرات القياس — ما لا يُقاس لا يُدار', 12)
table(s, Inches(0.5), Inches(1.6), SW-Inches(1),
      ['المؤشر (KPI)','التعريف','المستهدف المقترح'],
      [
       ['زمن دورة الشراء (Cycle Time)','من PR إلى PO',{'t':'تخفيض 30%','color':GREEN,'bold':True}],
       ['التزام القناة (Channel Compliance)','نسبة الطلبات عبر الدورة الرسمية',{'t':'≥ 95%','color':GREEN,'bold':True}],
       ['الوفر المحقّق (Realized Savings)','فرق السعر مقابل المرجع','يُقاس ربع سنوياً'],
       ['التزام SLA المالية','نسبة التحويلات ضمن المهلة',{'t':'≥ 90%','color':GREEN,'bold':True}],
       ['الطلبات المعلّقة (Aging PRs)','طلبات تجاوزت المهلة',{'t':'← الصفر','color':RED,'bold':True}],
       ['موثوقية الموردين (Responsiveness)','نسبة الاستجابة للعروض','اتجاه تصاعدي'],
       ['دقة الطلب (PR Accuracy)','طلبات مكتملة المواصفات أول مرة',{'t':'≥ 90%','color':GREEN,'bold':True}],
      ],
      col_w=[3,4,2], fsize=13, row_h=0.5)
decision(s, 'اعتماد هذه المؤشرات ضمن تقرير أداء ربع سنوي يُرفع للإدارة العليا.')

# ===================== الشريحة 13: القرارات المطلوبة =====================
s = prs.slides.add_slide(BLANK)
header(s, 'The Ask — Executive Decisions', 'القرارات السبعة المطلوبة من الإدارة العليا', 13)
asks = [
    'اعتماد مبدأ القناة الموحّدة الإلزامية للمشتريات',
    'إقرار مصفوفة الصلاحيات (Approval Matrix) بقيمها',
    'توقيع Finance SLA لزمن التحويل المالي',
    'اعتماد سجل الأسعار المرجعي المُغذّى من المالية',
    'تفويض إبرام عقود إطارية للطلبات المتكررة والبنية التحتية',
    'معالجة عهدة قصر الياسمين بنقلها لمسؤول المشروع',
    'المصادقة على خارطة الطريق ومؤشرات الأداء',
]
for i,a in enumerate(asks):
    row,col = divmod(i,2)
    if i==6:
        x=Inches(3.3); w=SW-Inches(6.6)
    else:
        x = Inches(0.5)+col*(SW/2-Inches(0.35)); w=SW/2-Inches(0.6)
    y = Inches(1.7)+row*Inches(0.85)
    rect(s, x, y, w, Inches(0.7), WHITE, line=RGBColor(0xDD,0xD6,0xC8))
    rect(s, x+w-Inches(0.6), y, Inches(0.6), Inches(0.7), GREEN)
    add_text(s, x+w-Inches(0.6), y, Inches(0.6), Inches(0.7), '✓', size=22, color=WHITE,
             bold=True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, rtl=False)
    add_text(s, x+Inches(0.1), y, w-Inches(0.75), Inches(0.7), a, size=14, color=NAVY,
             bold=True, align=PP_ALIGN.RIGHT, anchor=MSO_ANCHOR.MIDDLE)

# ===================== الشريحة 14: الخاتمة =====================
s = prs.slides.add_slide(BLANK)
bg(s, NAVY)
rect(s, 0, Inches(3.0), SW, Pt(4), GOLD)
add_text(s, Inches(1), Inches(2.0), SW-Inches(2), Inches(1.5),
         'الحوكمة ليست قيداً على العمل،\nبل الضمانة الوحيدة لاستدامته وكفاءته.',
         size=30, color=WHITE, bold=True, align=PP_ALIGN.CENTER)
add_text(s, Inches(1), Inches(3.4), SW-Inches(2), Inches(0.8),
         'لسنا بصدد معالجة أخطاء فردية، بل مأسسة وظيفة حيوية تحوّل المشتريات من حلقة ضعف إلى ميزة تنافسية.',
         size=16, color=GOLD, align=PP_ALIGN.CENTER)
add_text(s, Inches(1), Inches(4.7), SW-Inches(2), Inches(0.7),
         'شكراً لحُسن إصغائكم — وفريق المشتريات جاهز للتنفيذ فور الاعتماد.',
         size=16, color=LIGHT, align=PP_ALIGN.CENTER)

import os
out = os.path.join(os.path.dirname(__file__), 'procurement-executive-deck.pptx')
prs.save(out)
print('Saved:', out, os.path.getsize(out), 'bytes,', len(prs.slides.__iter__.__self__._sldIdLst), 'slides')

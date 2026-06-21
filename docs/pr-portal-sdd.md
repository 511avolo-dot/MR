# وثيقة تصميم النظام (SDD) وخطة التطوير
## بوابة طلبات الشراء المركزية — Purchase Request Portal
### مجموعة الذيابي للمقاولات · نظام المشتريات الإلكتروني (e‑Procurement)

> **الإصدار:** 1.0 — مسودة معمارية للاعتماد
> **المُعِدّ:** كبير مهندسي البرمجيات المؤسسية
> **الحالة:** جاهزة للمراجعة قبل البدء بالتنفيذ (Phase 0)

---

## 0. الملخّص التنفيذي (Executive Summary)

نبني **بوابة طلبات شراء (PR Portal)** مركزية تُؤتمت دورة الشراء من **«حاجة قسم»** حتى **«طلب تسعير مُرسَل للموردين»** دون انقطاع. البوابة ليست نظاماً منفصلاً، بل **امتداد عضوي** للنظام الأساسي القائم على:

- **الواجهة:** SPA أحادية الملف (`index.html`) + بوابة عامّة (`register.html`) على **Cloudflare Pages**.
- **الخلفية:** **Supabase** (PostgreSQL + Auth/JWT + Row‑Level Security + Storage + Realtime).
- **الذكاء:** **Gemini** (عبر `aiComplete`/`aiFetch` ووسيط `/api/ai`) — يقرأ المستندات ويستخرج البيانات (مُطبَّق فعلاً في «الاستيراد الذكي»).
- **خدمات الحافة:** **Pages Functions** (`functions/api/notify.js` للبريد، `verify.js`) — قناة الإشعارات جاهزة.

**ما هو موجود ويُعاد استخدامه (لا يُبنى من الصفر):**

| القدرة القائمة | الموقع | كيف تُستثمر في البوابة |
|---|---|---|
| وحدة طلبات التسعير RFQ + بوابة المورد بالرموز | `proc_rfqs`/`proc_rfq_quotes`، `rfqCreate`, `rfqEnsureToken`, `/q/<token>` | تحوّل PR المعتمد إلى RFQ تلقائياً وترسله للموردين |
| سجل الموردين + بوابة التسجيل | `proc_suppliers`, `proc_supplier_registrations`, `register.html` | قائمة الموردين المعتمدين لتوجيه RFQ |
| سلسلة اعتماد أوامر الشراء | حالات PO + `can_approve_l1/l2` | نموذج جاهز لمحرّك الاعتماد الديناميكي |
| قراءة المستندات بالذكاء (OCR+AI) | «الاستيراد الذكي» (`SI_STATE`, Gemini Vision لـ PDF/صور/Excel) | محرّك تعبئة نموذج PR تلقائياً |
| `submitPurchaseRequest()` | يُستدعى من `rfqAward` | يُرقّى إلى كيان PR رسمي بدل سجل اعتماد مبسّط |
| الإشعارات بالبريد | `functions/api/notify.js` | إشعارات الاعتماد والترسية |
| التدقيق + الصلاحيات + RLS | `proc_audit_log`, `pushAuditToCloud`, `proc_users.permissions` | حوكمة كاملة لكل انتقال حالة |

**النتيجة المستهدفة:** تقليل التدخل البشري ~70%، وتقصير زمن دورة الموافقة من أيام إلى ساعات، مع مسار تدقيق كامل وشفافية لحظية.

---

## 1. المبادئ المعمارية (Architecture Principles)

1. **توسعة لا استبدال:** كل كيان جديد يرتبط بالكيانات القائمة بمفاتيح خارجية، ويُعاد استخدام دوال الواجهة والخلفية.
2. **مصدر حقيقة واحد (Single Source of Truth):** كل البيانات في Supabase؛ الواجهة تعرض فقط. الحالة تُدار بآلة حالات صريحة (State Machine) لا بحقول نصّية حرّة.
3. **الأمان أولاً (Security by Default):** كل جدول محكوم بـ RLS؛ لا منطق اعتماد يعتمد على الواجهة وحدها — التحقق على الخادم (Postgres RPC/Policies).
4. **لا‑مزامنة ولا‑حجب (Async, Non‑blocking):** الإشعارات والـ OCR وإرسال RFQ تعمل بـ fire‑and‑forget مع إعادة محاولة.
5. **قابلية التتبّع (Auditability):** كل انتقال حالة يُكتب في `proc_audit_log` و`proc_pr_approvals` (مَن/متى/ماذا/لماذا).
6. **التدهور الرشيق (Graceful Degradation):** غياب تكامل HR/مالي لا يكسر البوابة؛ يسقط إلى مصفوفة صلاحيات داخلية.

```
            ┌──────────────────────── Cloudflare Pages (CDN) ─────────────────────────┐
            │  index.html (SPA: لوحات الأقسام/الاعتماد)   register.html (بوابة المورد) │
            └───────────────┬───────────────────────────────────┬──────────────────────┘
                            │ JWT (Supabase Auth)               │ Token عام (RFQ/التسجيل)
                ┌───────────▼───────────┐          ┌────────────▼─────────────┐
                │   Pages Functions      │          │      Supabase Edge        │
                │  /api/ai  /api/notify  │          │ Postgres + RLS + Realtime │
                │  /api/parse (جديد)     │          │ Storage (مرفقات/مستندات)  │
                └───────────┬───────────┘          └────────────┬─────────────┘
                            │ Gemini (OCR/استخراج)               │ Triggers/RPC (محرّك الحالة)
                            ▼                                    ▼
                    استخراج بيانات النموذج            PR → Approval → RFQ تلقائي
```

---

## 2. نموذج البيانات (Data Model)

### 2.1 الكيانات الجديدة (مع إعادة ربط بالقائم)

```sql
-- (1) الأقسام والهيكل التنظيمي (يغذّيه HR أو يُدار يدوياً)
create table proc_departments (
  id            text primary key,             -- 'DEP-FIN'
  name_ar       text not null,
  cost_center   text,                          -- مركز التكلفة للربط المالي
  manager_user  text references proc_users(username),  -- مدير القسم (المعتمِد L1)
  budget_annual numeric default 0,
  active        boolean default true
);

-- (2) امتداد المستخدمين بمعلومات تنظيمية (مرآة HR)
alter table proc_users add column department_id text references proc_departments(id);
alter table proc_users add column job_title    text;
alter table proc_users add column manager_user text references proc_users(username);
alter table proc_users add column hr_employee_id text;        -- مفتاح ربط HR

-- (3) طلب الشراء (رأس الطلب) — آلة حالات
create table proc_purchase_requests (
  id            text primary key,             -- 'PR-DG26-0001'
  title         text not null,
  department_id text references proc_departments(id),
  requester     text references proc_users(username),
  priority      text default 'متوسط',          -- عاجل/عالي/متوسط/منخفض
  needed_by     date,
  justification text,                           -- مبرّر الحاجة
  cost_center   text,
  est_total     numeric default 0,             -- التقدير المبدئي
  currency      text default 'SAR',
  status        text default 'draft',          -- آلة الحالات (انظر §5)
  current_stage int  default 0,                -- مؤشر المرحلة في السلسلة
  source        jsonb,                          -- {parsed_from:'doc', file:'...'} مصدر القراءة الآلي
  rfq_id        text references proc_rfqs(id),  -- يُملأ بعد التحويل التلقائي
  po_number     text references proc_purchase_orders(po_number),
  created_at    timestamptz default now(),
  updated_at    timestamptz default now(),
  updated_by    text
);

-- (4) بنود الطلب
create table proc_pr_items (
  id          bigserial primary key,
  pr_id       text references proc_purchase_requests(id) on delete cascade,
  item_code   text references proc_items(code),   -- ربط بالكتالوج إن وُجد
  description text not null,
  qty         numeric not null,
  unit        text,
  est_price   numeric,                            -- سعر مرجعي من proc_history
  est_total   numeric generated always as (coalesce(qty,0)*coalesce(est_price,0)) stored,
  category    text,
  notes       text
);

-- (5) سجل الاعتمادات (خطوة بخطوة) — مسار التدقيق
create table proc_pr_approvals (
  id          bigserial primary key,
  pr_id       text references proc_purchase_requests(id) on delete cascade,
  seq         int not null,                       -- ترتيب المرحلة في السلسلة المُهيّأة (1..N)
  stage_label text,                               -- 'مدير القسم' / 'المالية' / 'المدير العام' ...
  role_key    text,                               -- can_approve_l1 / can_approve_l2 / مخصّص
  approver    text references proc_users(username),
  decision    text,                               -- approved/rejected/returned/pending
  comment     text,
  acted_at    timestamptz
);

-- (5b) محرّك قواعد الاعتماد القابل للتهيئة — سلسلة ديناميكية مخصّصة (لا مبرمَجة صلباً)
-- كل قاعدة تُطابَق بـ(القسم/الفئة/نطاق القيمة)، وتُنتج سلسلة مراحل مُرتّبة.
create table proc_approval_rules (
  id          bigserial primary key,
  name        text,
  active      boolean default true,
  priority    int default 100,                    -- الأدنى يُطابَق أولاً
  -- شروط المطابقة (NULL = أي قيمة)
  department_id text references proc_departments(id),
  category    text,
  min_total   numeric default 0,
  max_total   numeric,                            -- NULL = بلا حد أعلى
  -- السلسلة الناتجة: مصفوفة مراحل مرتّبة
  stages      jsonb not null
  -- مثال stages:
  -- [ {"seq":1,"label":"مدير القسم","resolver":"dept_manager","role_key":"can_approve_l1"},
  --   {"seq":2,"label":"المالية","resolver":"role","role_key":"can_approve_finance"},
  --   {"seq":3,"label":"المدير العام","resolver":"role","role_key":"can_approve_l2"} ]
);

-- (6) المرفقات (النماذج الأصلية + مخرجات OCR)
create table proc_pr_attachments (
  id        bigserial primary key,
  pr_id     text references proc_purchase_requests(id) on delete cascade,
  storage_path text,                              -- Supabase Storage
  kind      text,                                 -- 'source_form' | 'quote' | 'support'
  ocr_json  jsonb,                                -- ناتج الاستخراج الخام
  created_at timestamptz default now()
);

-- (7) [مُرجأ — اختياري لمرحلة لاحقة] الميزانيات للفحص المالي المؤتمت.
-- قرار العميل الحالي: الاعتماد المالي «بشري فقط»، فلا حجز ميزانية آلي في MVP.
-- يبقى المخطط جاهزاً للتفعيل مستقبلاً دون تغيير بنيوي:
-- create table proc_budgets (id bigserial primary key, cost_center text, fiscal_year int,
--   allocated numeric, committed numeric, spent numeric);
```

### 2.2 العلاقات
```
proc_departments 1───* proc_users 1───* proc_purchase_requests 1───* proc_pr_items
                                                 │ 1───* proc_pr_approvals
                                                 │ 1───* proc_pr_attachments
                                                 │ ──(عند الاعتماد النهائي)──▶ proc_rfqs ──▶ proc_rfq_quotes (الموردون)
                                                 │ ──(بعد الترسية)──────────▶ proc_purchase_orders
proc_budgets (cost_center) ◀── فحص/حجز عند مرحلة المالية
```

---

## 3. تصميم الوحدات

### 3.1 وحدة قراءة النماذج (Document Parsing — OCR + AI)

**الهدف:** يرفع الموظف نموذج الشركة (PDF/صورة) فيُستخرَج محتواه ويُعبّأ نموذج PR تلقائياً للمراجعة قبل الإرسال.

**يُعاد استخدام:** خط أنابيب «الاستيراد الذكي» القائم (`SI_STATE`, Gemini Vision، تحليل PDF/صور/Excel) الذي يستخرج بنوداً بالفعل من عروض الموردين — يُعمَّم على نموذج PR.

**التدفّق:**
```
رفع الملف → Storage (proc_pr_attachments.kind='source_form')
   → /api/parse (Pages Function) يستدعي Gemini Vision بمخطط استخراج صارم (JSON Schema)
   → ناتج {requester, department, needed_by, items:[{desc,qty,unit,price?}], justification}
   → ملء النموذج في الواجهة مع تمييز الحقول «مستخرَجة آلياً» (قابلة للتعديل)
   → مطابقة كل بند بكتالوج proc_items (fuzzy match) واقتراح سعر مرجعي من proc_history
```

**نقاط التصميم:**
- **قالب موحّد واحد (قرار العميل):** بما أن نموذج طلب الشراء **موحّد** لكل الأقسام، نُحسّن الدقّة بـ:
  - **مُلقّن مُهيّأ للقالب (Template‑aware prompt):** نُعطي Gemini وصف الحقول وأماكنها المتوقّعة في القالب، فترتفع الدقّة ويقلّ الخطأ مقارنةً بنماذج متنوّعة.
  - **مخطط استخراج مُقيَّد (Structured Output):** JSON يطابق `proc_pr_items`/رأس الطلب تماماً (نمط مُطبَّق في `rfqAIImport`).
  - **تحقّق قالبي (Validation):** قواعد بسيطة بعد الاستخراج (الكمية رقم موجب، الوحدة من قائمة، التاريخ صالح) ترفع الموثوقية.
- **درجة ثقة (Confidence):** كل حقل مستخرَج يحمل علامة ثقة؛ المنخفضة تُبرَز للمراجعة البشرية قبل الإرسال.
- **مطابقة الكتالوج:** إعادة استخدام منطق المطابقة في الاستيراد الذكي لربط الوصف بـ `item_code` وجلب `est_price` من آخر سعر (`proc_history`).
- **خصوصية:** المستند يُعالَج عبر الوسيط `/api/parse` (مفتاح Gemini على الخادم لا الواجهة)، ويُحذف الملف الأصلي اختيارياً بعد الاستخراج (نمط مُطبَّق في `rfqDownloadQuoteFile`).

### 3.2 بوابة الأقسام (Department Portal + Live Tracking)

**واجهة جديدة داخل SPA:** صفحة `#page-pr` بثلاث حالات عرض (نمط `STATE.poView` القائم): **«طلباتي» / «إنشاء طلب» / «التتبّع»**.

**المكوّنات:**
- **منشئ الطلب (PR Builder):** رفع نموذج (→ §3.1) أو إدخال يدوي ببنود؛ يقترح القسم/مركز التكلفة من ملف المستخدم (`proc_users.department_id`).
- **التتبّع اللحظي (Live Tracking):** شريط مراحل (Stepper) يطابق `proc_pr_approvals`، يتحدّث فوراً عبر **Supabase Realtime** (الاشتراك مُطبَّق فعلاً في النظام). كل مرحلة تعرض: المعتمِد، الزمن المنقضي، الحالة، الملاحظات.
- **لوحة «طلباتي»:** بطاقات بحالة ملوّنة (نمط `PO_STATUS_META` القائم) + مؤشرات SLA (تأخّر الاعتماد).

**التتبّع لحظة بلحظة:** قناة Realtime على `proc_purchase_requests` و`proc_pr_approvals` مُرشَّحة بـ `requester` (للموظف) أو `department_id` (للمدير) — فيرى التحديث دون تحديث الصفحة.

### 3.3 سلسلة الاعتمادات الديناميكية (Dynamic, Configurable Approval Workflow)

> **قرار العميل:** سلسلة **أطول/مخصّصة** قابلة للتهيئة (لا 3 طبقات ثابتة)، وإدارة تنظيمية **داخلية**، واعتماد مالي **بشري** (بلا حجز ميزانية آلي الآن).

**آلة حالات معمّمة على N مرحلة** — عدد المراحل وترتيبها يأتيان من `proc_approval_rules` وقت التشغيل:

```
draft ──submit──▶ in_review (المرحلة seq=1)
   in_review ─(اعتماد المرحلة الحالية)→ المرحلة التالية ... حتى آخر مرحلة → approved
   أي مرحلة ─(رفض)→ rejected   |   ─(إرجاع للتعديل)→ returned → (تعديل المُقدِّم) → in_review
   approved ──(محرّك تلقائي)──▶ rfq_issued ──ترسية──▶ converted_to_po
```

**محرّك التوجيه القابل للتهيئة (Configurable Routing Engine):**
- **بناء السلسلة وقت الإرسال:** عند `submit` يُطابِق المحرّك الطلب بأعلى قاعدة أولوية في `proc_approval_rules` حسب (القسم + الفئة + نطاق القيمة)، ثم **يُنشئ صفوف `proc_pr_approvals` للمراحل المُعرَّفة في `stages`** بترتيبها. هكذا تختلف السلسلة وطولها بين قسم وآخر دون أي تعديل برمجي — يكفي إضافة/تعديل قاعدة.
  - مثال: قسم المقاولات وقيمة > 100,000 → [مدير القسم → المالية → المدير العام]؛ قسم الإدارة وقيمة صغيرة → [مدير القسم → المالية] فقط.
- **حلّ المعتمِد لكل مرحلة (Resolver):** يُشتق وقت التشغيل:
  - `dept_manager` → `proc_departments.manager_user` للطلب،
  - `user_manager` → `proc_users.manager_user` للمُقدِّم (سلسلة المدراء)،
  - `role` → أي مستخدم يملك `role_key` المطلوب (مثل `can_approve_finance` / `can_approve_l2`).
  - تُدار هذه البيانات **داخلياً** (شاشة إدارة الأقسام/المستخدمين) — لا تكامل HR خارجي في هذه المرحلة.
- **تفويض/إنابة (Delegation):** حقل `proc_users.delegate_to` (يُدار يدوياً عند الإجازات) يحوّل الاعتماد لنائب — جاهز للأتمتة لاحقاً عند ربط HR.
- **الاعتماد المالي بشري:** مرحلة المالية اعتماد يدوي (موافقة/إرجاع/رفض مع تعليق) — **بلا فحص/حجز ميزانية آلي** الآن (المخطط مُرجأ في §2).

**التنفيذ على الخادم:** دالة `pr_transition(pr_id, action, comment)` بصيغة **Postgres RPC (SECURITY DEFINER)** في معاملة واحدة:
1. تتحقق أن المستخدم هو المعتمِد المُحلّ للمرحلة الحالية (Resolver) ويملك `role_key`، وأنه ليس مُقدِّم الطلب (فصل المهام).
2. تكتب القرار في `proc_pr_approvals`، وتُحرّك `current_stage`.
3. إن كانت آخر مرحلة → `approved` ثم تستدعي `pr_to_rfq`؛ وإلا تُشعِر المعتمِد التالي.
كل ذلك ذرّياً لمنع حالات السباق والاعتماد المزدوج.

### 3.4 التكامل (Integration) — داخلي أولاً، مع جاهزية للربط لاحقاً

> **قرار العميل:** الإدارة التنظيمية **داخلية الآن** (Internal)؛ ربط HR/المالية الخارجي **مُرجأ**.

**المبدأ:** طبقة تكامل مجرّدة (Adapter Pattern) تُقرأ منها «الهوية التنظيمية» و(لاحقاً) «الميزانية» من واجهة موحّدة — حتى يكون الربط المستقبلي **إضافة لا إعادة هيكلة**.

| المصدر | الوصف | الحالة |
|---|---|---|
| **Internal** | جداول `proc_departments`/`proc_users` تُدار **داخل النظام** (شاشة إدارة الأقسام/المستخدمين القائمة) | ✅ المعتمد الآن (MVP) |
| **HR Sync** (مُرجأ) | مزامنة دورية (Pages Cron) من نظام HR عبر API/CSV → تحدّث المدراء/الصلاحيات/الإجازات | مرحلة لاحقة عند توفّر نظام HR |
| **Finance API** (مُرجأ) | ربط نظام مالي للتحقق/الالتزام بالميزانية | مرحلة لاحقة (الاعتماد المالي بشري الآن) |

- **الإدارة الداخلية (الآن):** يُضاف للنظام **شاشة إدارة الأقسام** (تعيين `manager_user`/`cost_center`) وتوسيع شاشة المستخدمين بـ(`department_id`, `manager_user`, `delegate_to`, `job_title`). كل ذلك بصلاحية `can_manage_users` القائمة.
- **العزل للمستقبل:** كل محوّل خارجي سيكون خلف Pages Function (`/api/hr-sync`, `/api/finance`) بمفاتيح على الخادم — الواجهة والبوابة لا تتأثران عند تفعيله.

### 3.5 وحدة RFQ والموردين (PR → RFQ التلقائي + بوابة المورد)

**التحويل التلقائي (Auto‑Conversion):** بمجرد وصول PR إلى `approved`، يُطلق محرّك الحالة دالة `pr_to_rfq(pr_id)` التي:
1. تُنشئ `proc_rfqs` (إعادة استخدام `rfqCreate`) من بنود PR: `lines` من `proc_pr_items`, `budget` من `est_total`.
2. **تختار الموردين ذكياً:** من `proc_suppliers` المعتمدين، مُرشَّحين بالفئة/التخصص وأداء سابق (نعيد استخدام `poSupplierRating`/`offers_count` و`rfqSuggestSuppliers` القائمة).
3. **تولّد روابط الموردين** عبر `rfqEnsureToken` (الرموز الآمنة القائمة) وتُرسلها عبر `/api/notify` (بريد) — وواجهة المورد `/q/<token>` **موجودة فعلاً** لإدخال الأسعار.
4. تربط `proc_purchase_requests.rfq_id` = RFQ الجديد (تتبّع متواصل في نفس شريط المراحل).

**واجهة المورد المبسّطة:** قائمة (موجودة) عبر رابط رمزي بلا تسجيل دخول؛ المورد يُدخل أسعار البنود + (مدة التوريد/الجودة/مدة السداد) — وكلها مدعومة في `proc_rfq_quotes.attrs`. يدعم أيضاً **رفع عرض كصورة/PDF** يُقرأ بالذكاء (`rfqAIImport` قائم).

**الترسية → أمر شراء:** بعد المقارنة والترسية (`rfqAward` قائم) يتحوّل تلقائياً إلى **أمر شراء** (الجسر `award → PO` مُطبَّق فعلاً) فتكتمل الدورة `PR → RFQ → PO`.

---

## 4. الأمن والصلاحيات (Security & Governance)

- **RLS على كل جدول جديد:** الموظف يرى طلباته فقط؛ مدير القسم يرى قسمه؛ المالية ترى مرحلة المالية؛ الأدمن الكل. (نمط RLS مُطبَّق بالنظام.)
- **اعتماد على الخادم:** انتقالات الحالة عبر RPC `SECURITY DEFINER` تتحقق من `proc_users.permissions` (`can_approve_l1/l2`) — لا يمكن تزوير اعتماد من الواجهة.
- **فصل المهام (SoD):** لا يعتمد المستخدم طلباً أنشأه؛ يُفرض في RPC.
- **مسار تدقيق كامل:** `proc_pr_approvals` + `proc_audit_log` لكل حدث (مَن/متى/قرار/تعليق/فحص ميزانية).
- **بوابة المورد:** رموز عشوائية ≥119 بت (قائم)، صلاحية محدودة، لا كشف بنية تحتية (تمّت معالجة تسريب «قاعدة البيانات» مؤخراً).

---

## 5. الإشعارات والتتبّع (Notifications & Realtime)

- **بريد:** عبر `/api/notify` عند: إرسال الطلب، طلب اعتماد (للمعتمِد التالي)، اعتماد/رفض/إرجاع، إصدار RFQ، استلام عرض، الترسية.
- **داخل التطبيق:** جرس إشعارات + Realtime (مُطبَّق). كل معتمِد يرى «بانتظار اعتمادك» فوراً.
- **SLA/تذكير:** Pages Cron يفحص الطلبات المتأخرة عن عتبة SLA ويُذكّر/يُصعّد (نمط «التصعيد» القائم في تقارير المشتريات).

---

## 6. خطة التطوير (Delivery Roadmap)

| المرحلة | النطاق | المخرجات الرئيسية | الاعتماد على القائم | المدة التقديرية |
|---|---|---|---|---|
| **P0 — التأسيس** | مخطط البيانات + RLS + RPC الحالة + الإدارة الداخلية | جداول `proc_pr_*` + `proc_approval_rules` + `proc_departments`، RLS، `pr_transition`، شاشة إدارة الأقسام | بنية Supabase + شاشة المستخدمين القائمة | 1–1.5 أسبوع |
| **P1 — بوابة الأقسام (MVP)** | إنشاء/عرض/تتبّع PR يدوي | صفحة `#page-pr`، Realtime tracking، «طلباتي» | `STATE.poView`، Realtime، `PO_STATUS_META` | 1.5–2 أسبوع |
| **P2 — محرّك الاعتماد القابل للتهيئة** | سلسلة مراحل ديناميكية (N مرحلة) + Resolvers + شاشات الاعتماد + إشعارات + تفويض | `proc_approval_rules`، `can_approve_*`، `/api/notify`، التدقيق | الصلاحيات + الإشعارات القائمة | 2–2.5 أسبوع |
| **P3 — قراءة النموذج الموحّد (OCR/AI)** | رفع النموذج الموحّد → تعبئة تلقائية + تحقّق قالبي + مطابقة كتالوج | `/api/parse`، Gemini، مراجعة الثقة | «الاستيراد الذكي»، `aiComplete` | 1–1.5 أسبوع |
| **P4 — التحويل التلقائي إلى RFQ** | PR معتمد → RFQ + اختيار موردين + إرسال | `pr_to_rfq`, اختيار ذكي، روابط الموردين | `rfqCreate`, `rfqEnsureToken`, `/q/<token>` | 1 أسبوع |
| **P5 — التحصين** | SLA/تصعيد، تقارير PR في مركز التقارير، اختبار قبول E2E | لوحات + تقارير + توثيق | مركز التقارير القائم | 1 أسبوع |
| **P6 — (مُرجأ/اختياري) تكاملات خارجية** | HR Sync + Finance/Budget عند توفّر الأنظمة | `/api/hr-sync`, `/api/finance`, `proc_budgets` | طبقة Adapter الجاهزة | عند الطلب |

> **المسار الكامل للقيمة:** P0→P4 يُغلق دورة «طلب → موافقات مخصّصة → RFQ → أمر شراء» خلال ~6–7 أسابيع، بلا حاجة لأي نظام خارجي. P6 إضافة مستقبلية اختيارية.

---

## 7. واجهات/دوال رئيسية (API Surface)

```
-- Postgres RPC (الخادم)
pr_create(payload jsonb)                 -- ينشئ PR + بنود
pr_submit(pr_id)                         -- يُطابق قاعدة الاعتماد ويبني سلسلة proc_pr_approvals
pr_transition(pr_id, action, comment)    -- آلة الحالة (N مرحلة) + التحقق + التدقيق + التحويل
pr_resolve_approver(pr_id, seq)          -- يحلّ المعتمِد للمرحلة (dept_manager/user_manager/role)
pr_to_rfq(pr_id)                         -- التحويل التلقائي إلى RFQ

-- Pages Functions (الحافة)
POST /api/parse      { filePath } → { fields, items[], confidence }   (جديد — قالب موحّد)
POST /api/notify     { to, template, data }                          (قائم — يُوسَّع بقوالب PR)
-- [مُرجأ] POST /api/hr-sync , POST /api/finance — عند تفعيل التكاملات الخارجية

-- الواجهة (SPA) — إعادة استخدام الأنماط القائمة
renderPRPortal(), prSubmit(), prTrack(id), prApprove(id, decision)
```

---

## 8. المخاطر والتخفيف (Risks & Mitigations)

| الخطر | الأثر | التخفيف |
|---|---|---|
| دقّة OCR | تعبئة خاطئة | قالب موحّد + مُلقّن مُهيّأ + تحقّق قالبي + مراجعة بشرية إلزامية + درجة ثقة |
| الاعتماد على إدارة تنظيمية يدوية | بيانات مدراء قديمة | شاشة إدارة داخلية واضحة + تنبيه عند غياب معتمِد + طبقة Adapter جاهزة لربط HR لاحقاً |
| حالات سباق في الاعتماد المتزامن | اعتماد مزدوج | RPC معاملاتي ذرّي + فصل المهام (لا يعتمد المُقدِّم طلبه) |
| تعقيد السلاسل المخصّصة الطويلة | صعوبة الصيانة | قواعد مُعرَّفة بياناتياً في `proc_approval_rules` (لا كود) + معاينة السلسلة قبل الإرسال |
| ضخامة `index.html` | صعوبة التطوّر | عزل وحدة PR في أقسام مُعلَّمة + اختبار `node --check` لكل دفعة |

---

## 9. معايير القبول والاختبار (Acceptance & Verification)

1. **E2E:** موظف يرفع النموذج الموحّد → يُعبَّأ تلقائياً → يُرسل → **تُبنى سلسلة الاعتماد حسب القاعدة المطابقة** → كل معتمِد في السلسلة يوافق يدوياً (مدير القسم → المالية → … حسب القيمة/القسم) → عند آخر مرحلة: RFQ يُرسل لـ≥3 موردين → مورد يُقدّم عرضاً عبر `/q/<token>` → ترسية → أمر شراء — مع تتبّع لحظي وسجل تدقيق كامل.
2. **أمني:** محاولة اعتماد بلا صلاحية / اعتماد طلب ذاتي / اعتماد مرحلة ليست دورك — كلها تُرفض على الخادم (RPC).
3. **تهيئة:** تغيير قاعدة في `proc_approval_rules` يغيّر طول/ترتيب السلسلة فوراً دون نشر كود.
4. **تدهور:** تعطّل البريد/الذكاء لا يكسر المسار الأساسي.
5. **أداء:** فتح لوحة الطلبات < 2s مع ترقيم (نمط `fetchAll` المُطبَّق حديثاً يضمن جلب كل الصفوف).
6. **تحقق بناء:** `node --check` على السكربتات + مراجعة RLS بمستخدمين بأدوار مختلفة.

---

---

## 10. حالة التنفيذ (Implementation Status)

| المرحلة | الحالة | المُخرَج |
|---|---|---|
| **P0 — الأساس (المخطط)** | ✅ مُنجَز | `db/pr-portal.sql` — 6 جداول + فهارس + RLS + Realtime + قواعد اعتماد أوّلية، **مطابقة لحقول نموذج «طلب شراء مواد» الفعلي** (الوحدة/كمية العقد/رصيد مستودعي/الكمية المطلوبة/سعر الوحدة/الإجمالي/أخر تأمين) وسلسلة تواقيعه (أمين المستودع ← مدير المشروع/القطاع ← مسؤول المشتريات ← الاعتماد). |
| P1–P5 | ✅ مُنجَز | بوابة الأقسام (داخل النظام) + محرّك الاعتماد + قراءة النموذج + تحويل RFQ تلقائي + تقارير/أقسام/SLA |
| **بوابة خارجية مستقلّة** | ✅ مُنجَز | `requests.html` — صفحة خفيفة بدخول مخصّص (Supabase Auth، نفس الحسابات) لرفع الطلبات (الاسم/القسم/الجوال) ومتابعتها والاعتماد — دون الحاجة لدخول النظام الأساسي الثقيل. النظام الأساسي يبقى لإدارة المشتريات. |

> **ملاحظة معمارية:** محرّك سلسلة الاعتماد يعمل في **التطبيق** (JavaScript) قراءةً من `proc_approval_rules`، اتساقاً مع نمط النظام القائم (اعتمادات PO/RFQ عميل-جانبية مع RLS `auth_all`). التحصين بـ RPC على الخادم يبقى ترقية اختيارية لاحقة (كطبقة `hardened-rls.sql`).

### الخلاصة
البوابة قابلة للبناء **بالكامل فوق المكدّس الحالي** بإضافات منضبطة: 7 جداول، حفنة من دوال RPC، 3 خدمات حافة، وصفحة واجهة واحدة — مع إعادة استخدام مكثّف لوحدتَي RFQ والموردين والاستيراد الذكي وسلسلة الاعتماد. المسار `PR → موافقات ديناميكية → RFQ → PO` يغلق دورة الشراء آلياً مع حوكمة وأمان وتتبّع كامل.

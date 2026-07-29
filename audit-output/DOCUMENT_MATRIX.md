# DOCUMENT / EVIDENCE MATRIX — current state (pre-062) + target

Evidence-based inventory of every document type in the portal **before** the supporting-documents work (migration 062).
Verified against `db/portal-standalone.sql`, `functions/api/portal-doc.js`, `functions/api/portal-quote.js`,
`purchase-portal.html`. "Inline preview" = renders **inside** the portal (authenticated blob) vs. opens an external
tab / public URL.

| Document | Created / uploaded where | Stored where | Linked entity | Mandatory? | Visible during which stage | Inline preview? | Authorization | Gap |
|---|---|---|---|---|---|---|---|---|
| Quotation PDF | Buyer offer entry / supplier self-upload (`portal_submit_offer`, `portal_supplier_submit`, `portal-quote.js`) | `portal_offers.quote_pdf_key` (**single** key per offer) | offer → request | Yes since 049 (`quote_doc_required`) | pricing → award → closed | **Partial** — viewer restored to `#modal`, but single file per offer | request-visibility (`portal_can_see_request`) | Single key; no type/version/history |
| Generated request document | Client-rendered HTML (`docReqHTML`) | not stored (rendered) | request | n/a | any | in-portal (print) | UI | Not a persisted evidence file |
| Quote comparison | Client-rendered (`comparisonPanel`, `paComparisonDoc`) | not stored | request | n/a | award → closed | in-portal | UI | Not persisted |
| Purchase order | Client-rendered (`docPoHTML`) | not stored | request | n/a | PO → closed | in-portal | UI | Not persisted |
| Supplier invoice | `portal_invoice_record` + `portal-doc.js` kind=`inv` | `portal_supplier_invoices.doc_key` (**single**) | request (+ invoice_no) | three-way only (`three_way_enforce`) | payment | via portal-doc GET | `can_manage_procurement`/`can_see_finance` | Single key; no multi-doc |
| Goods receipt / GRN | `portal_record_receipt` + kind=`grn` | `portal_receipts.doc_key` (**single**) | request | No | receipt → closed | via portal-doc GET | `can_verify_stock` | Single key |
| Return / debit note | `portal_return_record` + kind=`ret` | `portal_returns.doc_key` (**single**) | request | No | post-receipt | via portal-doc GET | `can_verify_stock`/`can_manage_procurement` | Single key |
| Payment proof (محضر الصرف) | `portal_payment_transition` execute + kind=`pay` | **`portal_payments.details->>'proof_key'` (JSON, single)** | payment | No (config) | payment execution → closed | via portal-doc GET | `can_disburse` | **JSON single key — exactly the anti-pattern the new requirement forbids** |
| Installment proof | kind=`inst` | payment `details` JSON | payment | No | installment payment | via portal-doc GET | `can_manage_procurement` | Single/JSON |
| **Direct-expense evidence** | **— none —** | **— none —** | — | **NO (the gap)** | — | — | — | **No supporting-document capability at all for direct disbursement; `portal_create_expense` creates+submits atomically with zero evidence** |

## Verified gaps (drive the 062 design)
1. **No direct-expense supporting documents.** `portal_create_expense` (050/060/061) creates a `direct_expense` request and
   immediately submits it into the approval chain with **no** attached evidence. This is the release-blocking gap.
2. **Single-key / JSON storage.** Every existing evidence type is one key on its row (or `details->>'proof_key'` in JSON).
   No normalized model → no multiple documents, no type classification, no versioning, no immutable history, no per-document
   authorization/audit.
3. **Atomic create+submit.** No draft→upload→submit flow anywhere; uploads always attach to an already-submitted entity.
4. **No payment-document completeness rule.** A procurement-linked payment request can be raised with no payment-specific
   evidence; the DB does not block it.
5. **No unified dossier.** When a procurement request enters payment there is no single "ملف المعاملة" surfacing the full
   history (request → quotes → comparison → award → PO → invoice → receipt → returns → prior payments → audit) in one place.
6. **Preview scattering risk.** Historic viewers used iframes/tabs; some paths still risk external navigation. Requirement E
   mandates in-portal authenticated blob preview everywhere in the approval experience.

## Target model (062+)
- `portal_request_documents` — normalized, immutable, versioned, per-document type/authorization/audit (schema in migration 062).
- Draft→upload→submit RPC flow with **server-side** enforcement of "≥1 active supporting document before the chain is built".
- Payment-document completeness rule (config-gated) for procurement-linked payments.
- Authenticated in-portal preview endpoint; المستندات الداعمة section in every approval panel; unified dossier on payment entry.

> **Not yet browser-verified.** Per requirement J, the procurement dossier and in-portal preview claims are **not** asserted
> complete until a browser-level pass confirms them; this environment runs DB/API + static checks only. Browser E2E is a
> tracked deliverable pending a migrated preview environment + owner authorization.

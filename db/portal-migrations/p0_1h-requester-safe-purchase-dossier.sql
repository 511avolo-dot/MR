-- ═══════════════════════════════════════════════════════════════════════════
-- P0-1h — عقد بيانات آمن وموجّه لتجربة طالب الاحتياج
--
-- لا يجوز لواجهة الطالب تحميل جداول مالية ثم إخفاء الحقول بصرياً. هذه RPC
-- parameterless تربط الهوية بجلسة Auth، وتعيد فقط:
--   • طلبات الشراء التي أنشأها المستخدم نفسه؛
--   • البنود بلا unit_price/line_total/est_total؛
--   • مراحل اعتماد الحاجة/التعميد/أمر الشراء ببيانات تشغيلية مُعقّمة؛
--   • اسم المورد الفائز بعد اعتماد التعميد، بلا مبلغ؛
--   • الاستلامات وخطوطها الكمية فقط؛
--   • metadata آمنة لمرفقات الطلب، بلا storage_key/checksum/مستندات دفع.
--
-- لا تعيد: عروض، مقارنة، مبالغ ترسية/PO، دفع، ميزانية، IBAN، فواتير، أو
-- audit.detail الخام. واجهة الطالب الجديدة يجب أن تعتمد هذا العقد حصراً.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.portal_my_purchase_dossiers()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_me text := public.portal_username();
  v_result jsonb;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'غير مصرّح — يلزم تسجيل الدخول';
  END IF;

  SELECT jsonb_build_object(
    'contract_version', 1,
    'requester', v_me,
    'generated_at', to_jsonb(now()),
    'requests', coalesce(jsonb_agg(q.dossier ORDER BY q.created_at DESC), '[]'::jsonb)
  )
  INTO v_result
  FROM (
    SELECT
      r.created_at,
      jsonb_build_object(
        'id', r.id,
        'title', r.title,
        'department_id', r.department_id,
        'requester_name', r.requester_name,
        'priority', r.priority,
        'status', r.status,
        'public_phase',
          CASE
            WHEN r.status = 'returned' THEN 'returned'
            WHEN r.status = 'rejected' THEN 'rejected'
            WHEN r.status = 'cancelled' THEN 'cancelled'
            WHEN r.status = 'on_hold' THEN 'on_hold'
            WHEN r.phase = 'closed' OR r.status = 'closed' THEN 'closed_delivered'
            WHEN r.phase = 'receipt' OR r.status = 'receipt_pending' THEN 'receipt'
            WHEN r.phase IN ('pricing','comparison','award','po_review','po') THEN 'procurement'
            WHEN r.phase IN ('payment','disbursement') THEN 'supply_preparation'
            WHEN r.status = 'in_review' THEN 'need_approval'
            ELSE 'processing'
          END,
        'project', r.project,
        'need_by', r.need_by,
        'proc_type', r.proc_type,
        'justification', r.justification,
        'note', r.note,
        'created_at', r.created_at,
        'updated_at', r.updated_at,
        'cancel_reason', CASE WHEN r.status = 'cancelled' THEN r.cancel_reason ELSE NULL END,
        'revision', r.revision,

        'current_stage', coalesce(
          (
            SELECT jsonb_build_object(
              'group', 'need',
              'label', a.stage_label,
              'holder', coalesce(d.display_name, a.approver, 'الجهة المعتمدة'),
              'decision', a.decision,
              'due_at', r.stage_due_at
            )
            FROM public.portal_approvals a
            LEFT JOIN public.portal_user_directory d ON d.username = a.approver
            WHERE a.request_id = r.id
              AND coalesce(a.cycle, 'need') = 'need'
              AND a.decision = 'pending'
            ORDER BY a.seq
            LIMIT 1
          ),
          (
            SELECT jsonb_build_object(
              'group', 'award',
              'label', aa.stage_label,
              'holder', coalesce(d.display_name, aa.approver, 'الجهة المعتمدة'),
              'decision', aa.decision,
              'due_at', r.stage_due_at
            )
            FROM public.portal_award_approvals aa
            LEFT JOIN public.portal_user_directory d ON d.username = aa.approver
            WHERE aa.request_id = r.id AND aa.decision = 'pending'
            ORDER BY aa.seq
            LIMIT 1
          ),
          (
            SELECT jsonb_build_object(
              'group', 'po',
              'label', pa.stage_label,
              'holder', coalesce(d.display_name, pa.approver, 'الجهة المعتمدة'),
              'decision', pa.decision,
              'due_at', r.stage_due_at
            )
            FROM public.portal_po_approvals pa
            LEFT JOIN public.portal_user_directory d ON d.username = pa.approver
            WHERE pa.request_id = r.id AND pa.decision = 'pending'
            ORDER BY pa.seq
            LIMIT 1
          ),
          CASE
            WHEN r.phase IN ('pricing','comparison','award','po_review','po') THEN
              jsonb_build_object('group','procurement','label','إجراءات المشتريات','holder','إدارة المشتريات','decision','active','due_at',r.stage_due_at)
            WHEN r.phase IN ('payment','disbursement') THEN
              jsonb_build_object('group','internal','label','استكمال إجراءات التوريد','holder','الجهة المختصة','decision','active','due_at',r.stage_due_at)
            WHEN r.phase = 'receipt' OR r.status = 'receipt_pending' THEN
              jsonb_build_object('group','receipt','label','بانتظار الاستلام','holder','المستلِم المعيّن','decision','active','due_at',r.stage_due_at)
            WHEN r.phase = 'closed' OR r.status = 'closed' THEN
              jsonb_build_object('group','closed','label','مغلق وتم التسليم','holder',NULL,'decision','completed','due_at',NULL)
            ELSE NULL
          END
        ),

        'winner_supplier_name', (
          SELECT o.supplier_name
          FROM public.portal_award aw
          JOIN public.portal_offers o ON o.id = aw.winner_offer_id
          WHERE aw.request_id = r.id AND aw.status = 'approved'
          LIMIT 1
        ),

        'items', coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', i.id,
              'seq', i.seq,
              'description', i.description,
              'unit', i.unit,
              'qty', i.qty,
              'received_qty', coalesce(i.received_qty, 0),
              'category', i.category,
              'notes', i.notes
            ) ORDER BY i.seq
          )
          FROM public.portal_request_items i
          WHERE i.request_id = r.id
        ), '[]'::jsonb),

        'need_approvals', coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'seq', a.seq,
              'stage_label', a.stage_label,
              'approver_name', coalesce(d.display_name, a.approver),
              'decision', a.decision,
              'acted_at', a.acted_at,
              'requester_comment', CASE
                WHEN a.decision IN ('returned','rejected') THEN a.comment
                ELSE NULL
              END
            ) ORDER BY a.seq
          )
          FROM public.portal_approvals a
          LEFT JOIN public.portal_user_directory d ON d.username = a.approver
          WHERE a.request_id = r.id AND coalesce(a.cycle, 'need') = 'need'
        ), '[]'::jsonb),

        'award_approvals', coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'seq', a.seq,
              'stage_label', a.stage_label,
              'approver_name', coalesce(d.display_name, a.approver),
              'decision', a.decision,
              'acted_at', a.acted_at
            ) ORDER BY a.seq
          )
          FROM public.portal_award_approvals a
          LEFT JOIN public.portal_user_directory d ON d.username = a.approver
          WHERE a.request_id = r.id
        ), '[]'::jsonb),

        'po_approvals', coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'seq', a.seq,
              'stage_label', a.stage_label,
              'approver_name', coalesce(d.display_name, a.approver),
              'decision', a.decision,
              'acted_at', a.acted_at
            ) ORDER BY a.seq
          )
          FROM public.portal_po_approvals a
          LEFT JOIN public.portal_user_directory d ON d.username = a.approver
          WHERE a.request_id = r.id
        ), '[]'::jsonb),

        'receipts', coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', rc.id,
              'received_by_name', coalesce(d.display_name, rc.received_by),
              'received_at', rc.received_at,
              'note', rc.note,
              'lines', coalesce((
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'item_id', nullif(line->>'item_id','')::bigint,
                    'qty', nullif(line->>'qty','')::numeric
                  )
                )
                FROM jsonb_array_elements(coalesce(rc.lines, '[]'::jsonb)) line
              ), '[]'::jsonb)
            ) ORDER BY rc.received_at
          )
          FROM public.portal_receipts rc
          LEFT JOIN public.portal_user_directory d ON d.username = rc.received_by
          WHERE rc.request_id = r.id
        ), '[]'::jsonb),

        'documents', coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', doc.id,
              'document_type', doc.document_type,
              'title', doc.title,
              'original_file_name', doc.original_file_name,
              'mime_type', doc.mime_type,
              'size_bytes', doc.size_bytes,
              'uploaded_by_name', coalesce(d.display_name, doc.uploaded_by),
              'uploaded_at', doc.uploaded_at,
              'version', doc.version
            ) ORDER BY doc.uploaded_at, doc.id
          )
          FROM public.portal_request_documents doc
          LEFT JOIN public.portal_user_directory d ON d.username = doc.uploaded_by
          WHERE doc.request_id = r.id
            AND doc.active = true
            AND doc.payment_id IS NULL
            AND doc.document_type IN ('memo','other','receipt')
        ), '[]'::jsonb)
      ) AS dossier
    FROM public.portal_requests r
    WHERE r.requester = v_me
      AND coalesce(r.req_type, 'purchase') = 'purchase'
  ) q;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.portal_my_purchase_dossiers() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_my_purchase_dossiers() TO authenticated;

COMMENT ON FUNCTION public.portal_my_purchase_dossiers() IS
  'Requester-safe purchase workspace contract. Owner-only by JWT; intentionally excludes all financial, quote, payment, banking, budget, invoice, and storage-key data.';

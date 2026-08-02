# Enterprise UI Owner Acceptance Checklist

Use this checklist only on the hosted Cloudflare PR Preview connected to isolated staging. Use dummy users, dummy transactions, and dummy files.

## Environment gate

- [ ] PR #74 is still Draft and unmerged.
- [ ] Preview URL belongs to the PR/branch, not production.
- [ ] `/api/portal-config` resolves to isolated staging only.
- [ ] No browser request references the production Supabase project.
- [ ] Uploads use the staging R2 bucket only.
- [ ] Migration `063` remains absent.

## Visual system

- [ ] Arabic RTL layout feels intentional on desktop and mobile.
- [ ] Navigation, cards, tables, forms, modal spacing, and focus states are visually consistent.
- [ ] No screen appears overcrowded or like a generic generated dashboard.
- [ ] The current transaction, stage, owner, and next action are obvious.
- [ ] Keyboard navigation and visible focus work across primary workflows.

## Supporting documents

- [ ] PDF opens inside the portal.
- [ ] JPEG and PNG open inside the portal.
- [ ] Fit width, fit page, zoom, rotate, download, and close work.
- [ ] Escape closes the viewer and returns focus.
- [ ] Version history and active/replaced status are understandable.
- [ ] Unauthorized users receive no document data through direct endpoint calls.

## Generated documents

- [ ] Purchase request opens in the generated-document preview.
- [ ] Purchase order opens in the generated-document preview.
- [ ] Receipt minutes open in the generated-document preview.
- [ ] Payment voucher opens in the generated-document preview.
- [ ] Preview and printed/saved PDF have the same content and hierarchy.
- [ ] Requester-facing generated documents omit unauthorized financial values.
- [ ] Branding, page breaks, signatures, and Arabic text are owner-approved.

## Quotation studio

- [ ] Three dummy quotations appear in the supplier list.
- [ ] Two quotations can be compared side by side.
- [ ] Single-offer mode works.
- [ ] Supplier total and delivery duration are correct.
- [ ] Lowest-price indication is informational and does not auto-award.
- [ ] Requester cannot retrieve quotation files even when they can view their request.
- [ ] Procurement and explicitly authorized roles can retrieve quotation files.

## Policy Studio

- [ ] Only the portal administrator can open the studio.
- [ ] Current published version, publisher, and time are correct.
- [ ] Enable/disable committee preview is understandable.
- [ ] Minimum and maximum boundaries simulate correctly.
- [ ] Fallback approver preview is correct.
- [ ] Draft-versus-published diff is clear.
- [ ] Publishing requires an explicit second confirmation.
- [ ] Existing transactions retain their original policy snapshot.

## Access Inspector

- [ ] Only the portal administrator can open it.
- [ ] Search by user, job, and department works.
- [ ] Effective capabilities match the existing job/permission model.
- [ ] Direct grants are distinguished from job inheritance where available.
- [ ] Scope, department, sector, and delegation are correct.
- [ ] Approval-plus-execution conflicts are highlighted.
- [ ] Inspector performs no write or permission mutation.

## Role walkthrough

- [ ] Requester sees own request and operational progress only.
- [ ] Requester cannot see quotations, comparison, award amount, PO amount, invoices, IBAN, or payment details.
- [ ] Sector manager sees only the authorized organizational scope.
- [ ] Procurement can manage RFQ, comparison, award, and PO as permitted.
- [ ] Committee sees a transaction only when it reaches the committee stage.
- [ ] Receiver can record partial/full receipt without changing supplier or price.
- [ ] Finance can review payment evidence without modifying procurement evidence.
- [ ] Administrator can configure and diagnose but does not gain implicit operational approval powers.

## Final decision

- [ ] No Blocker, Critical, or High defect remains.
- [ ] All Medium defects have an accepted owner decision and target release.
- [ ] Hosted Preview browser E2E is attached as evidence.
- [ ] Staging test data and files are cleaned after acceptance.
- [ ] Independent reviewer signs off.
- [ ] Owner explicitly authorizes the next release gate.

Completion of this checklist does not itself authorize merge or production deployment. The PR must remain Draft until all separate security, database, infrastructure, and release gates are satisfied.

/**
 * Bounded staging-only cleanup for expired upload receipts and orphaned R2
 * objects.  This endpoint deliberately refuses every Supabase project and R2
 * bucket except the isolated release-candidate staging resources.
 */
import { portalUrl, portalConfigured, svcHeaders } from './_portal-shared.js';

const STAGING_PROJECT_REF = 'vpfnycxzqziltsnzxbpb';
const STAGING_BUCKET = 'aldeyabi-quotes-staging';
const KEY_RE = /^docs\/(pay|grn|inst|inv|ret|disb|reqdoc)\/[A-Za-z0-9._-]{3,40}\/[A-Za-z0-9._-]{6,80}\.(pdf|jpg|jpeg|png)$/;
const MAX_EXPIRED_RECEIPTS = 50;
const MAX_LIST_PAGES = 2;
const LIST_PAGE_SIZE = 100;
const ORPHAN_GRACE_MS = 60 * 60 * 1000;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

function constantTimeEqual(a, b) {
  const left = new TextEncoder().encode(String(a || ''));
  const right = new TextEncoder().encode(String(b || ''));
  let mismatch = left.length ^ right.length;
  const size = Math.max(left.length, right.length);
  for (let i = 0; i < size; i += 1) {
    mismatch |= (left[i % Math.max(left.length, 1)] || 0)
      ^ (right[i % Math.max(right.length, 1)] || 0);
  }
  return mismatch === 0;
}

function stagingEnvironmentOk(env) {
  try {
    const ref = new URL(portalUrl(env)).hostname.split('.')[0];
    return ref === STAGING_PROJECT_REF
      && String(env.PORTAL_R2_BUCKET_NAME || '') === STAGING_BUCKET;
  } catch (_) {
    return false;
  }
}

async function serviceRequest(env, path, init = {}) {
  return fetch(`${portalUrl(env)}/rest/v1/${path}`, {
    ...init,
    headers: { ...svcHeaders(env), ...(init.headers || {}) },
  });
}

async function getRows(env, path) {
  const response = await serviceRequest(env, path);
  if (!response.ok) throw new Error(`database read failed (${response.status})`);
  const rows = await response.json();
  return Array.isArray(rows) ? rows : [];
}

function inFilter(keys) {
  return encodeURIComponent(`in.(${keys.map((key) => `"${key}"`).join(',')})`);
}

async function referencedKeys(env, keys, includeReceipts = true) {
  const safeKeys = [...new Set(keys.filter((key) => KEY_RE.test(key)))];
  const found = new Set();
  if (!safeKeys.length) return found;
  const filter = inFilter(safeKeys);

  const lookups = [
    [`portal_request_documents?storage_key=${filter}&select=storage_key`, 'storage_key'],
    [`portal_receipts?doc_key=${filter}&select=doc_key`, 'doc_key'],
    [`portal_supplier_invoices?doc_key=${filter}&select=doc_key`, 'doc_key'],
    [`portal_returns?doc_key=${filter}&select=doc_key`, 'doc_key'],
    [`portal_payments?details-%3E%3Eproof_key=${filter}&select=details`, 'payment'],
  ];
  if (includeReceipts) {
    lookups.push([`portal_upload_receipts?storage_key=${filter}&select=storage_key`, 'storage_key']);
  }

  const results = await Promise.all(lookups.map(async ([path, field]) => {
    const rows = await getRows(env, path);
    return { rows, field };
  }));

  for (const { rows, field } of results) {
    for (const row of rows) {
      const key = field === 'payment' ? row.details && row.details.proof_key : row[field];
      if (KEY_RE.test(String(key || ''))) found.add(key);
    }
  }
  return found;
}

async function deleteReceipt(env, key) {
  const response = await serviceRequest(
    env,
    `portal_upload_receipts?storage_key=eq.${encodeURIComponent(key)}&consumed_at=is.null`,
    { method: 'DELETE', headers: { Prefer: 'return=minimal' } },
  );
  if (!response.ok) throw new Error(`receipt delete failed (${response.status})`);
}

async function cleanupExpiredReceipts(env) {
  const now = new Date().toISOString();
  const receipts = await getRows(
    env,
    `portal_upload_receipts?consumed_at=is.null&expires_at=lt.${encodeURIComponent(now)}`
      + `&select=storage_key&order=expires_at.asc&limit=${MAX_EXPIRED_RECEIPTS}`,
  );
  const keys = receipts.map((row) => row.storage_key).filter((key) => KEY_RE.test(key));
  const referenced = await referencedKeys(env, keys, false);
  let objectsDeleted = 0;
  let receiptsDeleted = 0;
  let failures = 0;

  for (const key of keys) {
    try {
      if (!referenced.has(key)) {
        await env.QUOTES_BUCKET.delete(key);
        objectsDeleted += 1;
      }
      await deleteReceipt(env, key);
      receiptsDeleted += 1;
    } catch (_) {
      failures += 1;
    }
  }
  return { scanned: keys.length, objectsDeleted, receiptsDeleted, failures };
}

async function cleanupOrphanObjects(env) {
  let cursor;
  let pages = 0;
  let scanned = 0;
  let deleted = 0;
  let failures = 0;
  const cutoff = Date.now() - ORPHAN_GRACE_MS;

  while (pages < MAX_LIST_PAGES) {
    const page = await env.QUOTES_BUCKET.list({
      prefix: 'docs/',
      limit: LIST_PAGE_SIZE,
      ...(cursor ? { cursor } : {}),
    });
    pages += 1;
    const objects = (page.objects || []).filter((obj) => {
      const uploaded = obj.uploaded instanceof Date ? obj.uploaded.getTime() : Date.parse(obj.uploaded);
      return KEY_RE.test(obj.key) && Number.isFinite(uploaded) && uploaded < cutoff;
    });
    scanned += (page.objects || []).length;
    const refs = await referencedKeys(env, objects.map((obj) => obj.key), true);
    const orphanKeys = objects.map((obj) => obj.key).filter((key) => !refs.has(key));

    if (orphanKeys.length) {
      try {
        await env.QUOTES_BUCKET.delete(orphanKeys.slice(0, 1000));
        deleted += orphanKeys.length;
      } catch (_) {
        failures += orphanKeys.length;
      }
    }

    if (!page.truncated || !page.cursor) break;
    cursor = page.cursor;
  }
  return { pages, scanned, deleted, failures };
}

export async function onRequestPost({ request, env }) {
  if (!portalConfigured(env) || !env.QUOTES_BUCKET || !env.CRON_SECRET) {
    return json({ error: 'cleanup unavailable' }, 503);
  }
  if (!stagingEnvironmentOk(env)) {
    return json({ error: 'cleanup is restricted to the approved staging resources' }, 403);
  }
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!constantTimeEqual(token, env.CRON_SECRET)) {
    return json({ error: 'unauthorized' }, 401);
  }

  try {
    const expiredReceipts = await cleanupExpiredReceipts(env);
    const orphanObjects = await cleanupOrphanObjects(env);
    return json({
      ok: true,
      bounded: {
        maxExpiredReceipts: MAX_EXPIRED_RECEIPTS,
        maxListPages: MAX_LIST_PAGES,
        listPageSize: LIST_PAGE_SIZE,
      },
      expiredReceipts,
      orphanObjects,
    });
  } catch (_) {
    return json({ error: 'cleanup failed closed' }, 502);
  }
}


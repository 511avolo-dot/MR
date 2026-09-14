#!/usr/bin/env node
import assert from 'node:assert/strict';
import { onRequestPost } from '../../functions/api/admin-users.js';

const ENV = { SUPABASE_URL: 'https://project.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'service-test-key' };
const baseProfiles = {
  manager: { username: 'manager', role: 'user', active: true, permissions: {}, pr_profile_key: 'requester', pr_permission_overrides: { pr_manage_users: true } },
  module: { username: 'module', role: 'user', active: true, permissions: {}, pr_profile_key: 'module_admin', pr_permission_overrides: {} },
  employee: { username: 'employee', role: 'user', active: true, permissions: {}, pr_profile_key: 'requester', pr_permission_overrides: {} },
  sysadmin: { username: 'sysadmin', role: 'admin', active: true, permissions: {}, pr_profile_key: 'module_admin', pr_permission_overrides: {} },
  inactive: { username: 'inactive', role: 'user', active: false, permissions: {}, pr_profile_key: 'requester', pr_permission_overrides: {} },
};

function request(body, caller = 'manager') {
  return new Request('https://preview.example/api/admin-users', {
    method: 'POST',
    headers: { host: 'preview.example', origin: 'https://preview.example', authorization: `Bearer ${caller}-jwt`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}
function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });
}
function mockNetwork(options = {}) {
  const calls = [];
  const original = globalThis.fetch;
  const profiles = { ...baseProfiles, ...(options.profiles || {}) };
  globalThis.fetch = async (url, init = {}) => {
    const text = String(url); const method = String(init.method || 'GET').toUpperCase();
    calls.push({ url: text, method, body: init.body });
    if (text.includes('/auth/v1/user')) {
      const token = String((init.headers && (init.headers.Authorization || init.headers.authorization)) || '');
      const caller = /Bearer\s+([a-z]+)-jwt/i.exec(token)?.[1] || 'manager';
      return json({ email: `${caller}@aldeyabi.com` });
    }
    if (text.includes('/rest/v1/proc_users?username=ilike.')) {
      const encoded = /username=ilike\.([^&]*)/.exec(text)?.[1] || '';
      const username = decodeURIComponent(encoded).replace(/\\(.)/g, '$1').toLowerCase();
      return json(profiles[username] ? [profiles[username]] : []);
    }
    if (text.endsWith('/auth/v1/admin/users') && method === 'POST') return json({ id: 'new-auth-id' });
    if (text.includes('/auth/v1/admin/users/new-auth-id') && method === 'DELETE') return json({});
    if (text.endsWith('/rest/v1/proc_users') && method === 'POST') {
      return new Response(options.profileWriteFails ? 'profile write failed' : '', { status: options.profileWriteFails ? 500 : 201 });
    }
    if (text.includes('/rest/v1/proc_users?username=eq.') && method === 'PATCH') return new Response(null, { status: 204 });
    return json([]);
  };
  return { calls, restore: () => { globalThis.fetch = original; } };
}
async function call(body, caller = 'manager', options = {}) {
  const net = mockNetwork(options);
  try {
    const response = await onRequestPost({ request: request(body, caller), env: ENV });
    return { response, body: await response.json(), calls: net.calls };
  } finally { net.restore(); }
}

let passed = 0;
function ok(label) { passed += 1; console.log(`  ✓ ${label}`); }
console.log('▶ purchase-request user administration boundary');

{
  const result = await call({ action: 'create', username: 'newadmin', password: 'Passw0rd!', displayName: 'New Admin', role: 'admin', permissions: {} });
  assert.equal(result.response.status, 403);
  assert.equal(result.calls.some((x) => x.url.endsWith('/auth/v1/admin/users') && x.method === 'POST'), false);
  ok('a module user manager cannot create a system administrator or orphan Auth account');
}
{
  const result = await call({ action: 'create', username: 'newmodule', password: 'Passw0rd!', displayName: 'New Module Admin', role: 'user', permissions: {}, pr_profile_key: 'module_admin' });
  assert.equal(result.response.status, 403);
  assert.equal(result.calls.some((x) => x.url.endsWith('/auth/v1/admin/users') && x.method === 'POST'), false);
  ok('a lower user manager cannot grant the module-admin profile');
}
{
  const result = await call({ action: 'setProfile', username: 'sysadmin', job_title: 'changed' });
  assert.equal(result.response.status, 403);
  assert.equal(result.calls.some((x) => x.method === 'PATCH'), false);
  ok('a module user manager cannot mutate a system administrator');
}
{
  const result = await call({ action: 'setProfile', username: 'module', job_title: 'changed' });
  assert.equal(result.response.status, 403);
  ok('a lower user manager cannot mutate a module administrator');
}
{
  const result = await call({ action: 'setActive', username: 'manager', active: false });
  assert.equal(result.response.status, 400);
  ok('the current manager cannot disable their own account');
}
{
  const result = await call({ action: 'setProfile', username: 'employee', delegate_to: 'employee' });
  assert.equal(result.response.status, 400);
  ok('self-delegation is rejected');
}
{
  const result = await call({ action: 'setProfile', username: 'employee', delegate_to: 'inactive' });
  assert.equal(result.response.status, 400);
  ok('delegation to an inactive account is rejected');
}
{
  const result = await call({ action: 'setProfile', username: 'employee', pr_profile_key: 'procurement_officer', pr_permission_overrides: {} }, 'module');
  assert.equal(result.response.status, 200);
  assert.equal(result.calls.some((x) => x.method === 'PATCH'), true);
  ok('a module administrator can assign an ordinary module profile');
}
{
  const result = await call({ action: 'create', username: 'newemployee', password: 'Passw0rd!', displayName: 'New Employee', role: 'user', permissions: {}, pr_profile_key: 'requester' }, 'module', { profileWriteFails: true });
  assert.equal(result.response.status, 400);
  assert.equal(result.calls.some((x) => x.url.includes('/auth/v1/admin/users/new-auth-id') && x.method === 'DELETE'), true);
  ok('a failed profile write compensates by deleting the newly created Auth account');
}

console.log(`\nPurchase-request administration: ${passed} checks passed.`);

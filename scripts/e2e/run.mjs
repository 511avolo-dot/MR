#!/usr/bin/env node
/**
 * run.mjs — طبقة تحقّق Node قبل E2E ثم **تفويض إلزاميّ** لمتصفّح Playwright الفعليّ (G1-R6-03).
 * يُثبِّت حارس Node-fetch (self-test للمُشغّل، ليس حدّ متصفّح)، يؤكّد أنّ الهدف ليس الإنتاج، ثم — بلا شرط —
 * يُفوّض إلى `scripts/e2e/browser-run.mjs` (حدّ سياق المتصفّح + سيناريو smoke) فلا يبقى الأخير معزولاً.
 * ⚠️ env-guard يستدعي browser-run.mjs مباشرةً؛ هذا المسار مكافئ ويصل المتصفّح الفعليّ أيضاً.
 */
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { installNetworkAllowlist } from './net-allow.mjs';

const PROD_REF = 'mwbjoysuybgbrvfrprex';
function die(m) { console.error('❌ e2e-run: ' + m); process.exit(2); }

const url = process.env.E2E_SUPABASE_URL || '';
const m = /^https:\/\/([a-z0-9]{20})\.supabase\.co\/?$/.exec(url);
const ref = m ? m[1] : (process.env.GUARDED_REF || '').toLowerCase();
if (!/^[a-z0-9]{20}$/.test(ref)) die('لا مرجع staging صالح (E2E_SUPABASE_URL/GUARDED_REF يُضبطان عبر env-guard).');
if (ref === PROD_REF) die('الهدف هو الإنتاج — مرفوض.');

// حارس Node-fetch للمُشغّل (ليس حدّ متصفّح — الحدّ الحقيقيّ في browser-run.mjs).
installNetworkAllowlist(ref);
console.log(`▶ e2e-run: حارس Node-fetch مُثبَّت (${ref})؛ تفويض إلى متصفّح Playwright الفعليّ (browser-run.mjs)…`);

// (G1-R6-03) تفويض إلزاميّ إلى المتصفّح الفعليّ — يفشل مغلقاً بلا Playwright/‏staging (لا نجاح زائف).
const here = dirname(fileURLToPath(import.meta.url));
const r = spawnSync('node', [join(here, 'browser-run.mjs')], { stdio: 'inherit', env: process.env });
process.exit(typeof r.status === 'number' ? r.status : 1);

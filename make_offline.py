#!/usr/bin/env python3
"""
تحويل diwan-logistics.html إلى ملف يعمل بدون إنترنت
تشغيل: python3 make_offline.py
"""
import urllib.request
import base64
import re
import os
import sys

INPUT  = 'diwan-logistics.html'
OUTPUT = 'diwan-logistics-offline.html'

HEADERS = {
    'User-Agent': (
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Safari/537.36'
    )
}

def fetch(url):
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read()
    except Exception as e:
        print(f'  ✗ خطأ في التحميل: {url}\n    {e}')
        sys.exit(1)

# ── 1. Chart.js ────────────────────────────────────────────────
print('📥 تحميل Chart.js 4.4.0 ...')
chartjs_url = 'https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js'
chartjs = fetch(chartjs_url).decode('utf-8')
print(f'  ✓ Chart.js  ({len(chartjs)//1024} KB)')

# ── 2. Lucide Icons ────────────────────────────────────────────
print('📥 تحميل Lucide Icons ...')
lucide_url = 'https://unpkg.com/lucide@0.358.0/dist/umd/lucide.min.js'
lucide = fetch(lucide_url).decode('utf-8')
print(f'  ✓ Lucide    ({len(lucide)//1024} KB)')

# ── 3. Cairo Font ──────────────────────────────────────────────
print('📥 تحميل خط Cairo ...')
font_css_url = (
    'https://fonts.googleapis.com/css2'
    '?family=Cairo:wght@300;400;500;600;700&display=swap'
)
font_css = fetch(font_css_url).decode('utf-8')

# Embed every .woff2 file referenced in the CSS as base64
woff_urls = re.findall(r'url\((https://fonts\.gstatic\.com/[^)]+)\)', font_css)
for wurl in sorted(set(woff_urls)):
    wdata = fetch(wurl)
    b64   = base64.b64encode(wdata).decode('ascii')
    font_css = font_css.replace(wurl, f'data:font/woff2;base64,{b64}')
print(f'  ✓ Cairo ({len(woff_urls)} ملف خط مضمّن)')

# ── 4. قراءة الملف الأصلي ──────────────────────────────────────
if not os.path.exists(INPUT):
    print(f'✗ لم يُعثر على الملف: {INPUT}')
    sys.exit(1)

with open(INPUT, encoding='utf-8') as f:
    html = f.read()

# ── 5. استبدال روابط CDN بنسخ مضمّنة ─────────────────────────

# Chart.js
html = re.sub(
    r'<script\s+src="https://cdn\.jsdelivr\.net/npm/chart\.js[^"]*"\s*></script>',
    f'<script>\n{chartjs}\n</script>',
    html
)

# Lucide
html = re.sub(
    r'<script\s+src="https://unpkg\.com/lucide[^"]*"\s*></script>',
    f'<script>\n{lucide}\n</script>',
    html
)

# Google Fonts preconnect (remove)
html = re.sub(r'<link\s+rel="preconnect"\s+href="https://fonts\.googleapis\.com"\s*>', '', html)
html = re.sub(r'<link\s+rel="preconnect"\s+href="https://fonts\.gstatic\.com"[^>]*>', '', html)

# All Google Fonts link tags → embedded <style> with base64 fonts
embedded_font_tag = f'<style>\n{font_css}\n</style>'
html = re.sub(
    r'<link\s+href="https://fonts\.googleapis\.com/css2[^"]*"\s+rel="stylesheet"\s*/?>',
    embedded_font_tag,
    html
)

# ── 6. كتابة الملف الناتج ──────────────────────────────────────
with open(OUTPUT, 'w', encoding='utf-8') as f:
    f.write(html)

size_mb = os.path.getsize(OUTPUT) / 1024 / 1024
print(f'\n✅ اكتمل!')
print(f'   الملف الناتج : {OUTPUT}')
print(f'   الحجم        : {size_mb:.1f} MB')
print(f'   يعمل الآن بدون إنترنت تماماً 🌐✗')

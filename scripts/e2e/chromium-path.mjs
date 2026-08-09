import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

function firstExisting(candidates) {
  return candidates.find((candidate) => candidate && existsSync(candidate));
}

/**
 * Resolve an already-installed Chromium-compatible executable without weakening
 * Playwright's default managed-browser behavior. Explicit CI configuration wins;
 * system browsers are only a local fallback when Playwright has no bundled binary.
 */
export function resolveChromiumExecutable() {
  const explicit = firstExisting([
    process.env.PW_CHROMIUM_PATH,
    process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
    process.env.CHROME_BIN,
  ]);
  if (explicit) return explicit;

  const browserRoot = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (browserRoot) {
    try {
      const dirs = readdirSync(browserRoot).filter((name) =>
        name.startsWith('chromium-') || name.startsWith('chromium_headless_shell-'));
      for (const dir of dirs) {
        const found = firstExisting([
          join(browserRoot, dir, 'chrome-win', 'chrome.exe'),
          join(browserRoot, dir, 'chrome-win64', 'chrome.exe'),
          join(browserRoot, dir, 'chrome-linux', 'chrome'),
          join(browserRoot, dir, 'chrome-linux64', 'chrome'),
          join(browserRoot, dir, 'chrome-headless-shell-win64', 'headless_shell.exe'),
          join(browserRoot, dir, 'chrome-headless-shell-linux64', 'chrome-headless-shell'),
        ]);
        if (found) return found;
      }
    } catch (_) { /* Playwright will report the managed-browser error if needed. */ }
  }

  if (process.platform === 'win32') {
    return firstExisting([
      process.env.PROGRAMFILES && join(process.env.PROGRAMFILES, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      process.env['PROGRAMFILES(X86)'] && join(process.env['PROGRAMFILES(X86)'], 'Google', 'Chrome', 'Application', 'chrome.exe'),
      process.env.LOCALAPPDATA && join(process.env.LOCALAPPDATA, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      process.env.PROGRAMFILES && join(process.env.PROGRAMFILES, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      process.env['PROGRAMFILES(X86)'] && join(process.env['PROGRAMFILES(X86)'], 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    ]);
  }

  if (process.platform === 'darwin') {
    return firstExisting([
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
    ]);
  }

  return firstExisting([
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/usr/bin/microsoft-edge',
  ]);
}

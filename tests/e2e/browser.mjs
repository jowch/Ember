// Chromium launch, shared across every e2e test. `EMBER_CHROMIUM` picks the
// binary explicitly; failing that, this Mac's local Playwright cache path
// (set up once, outside this suite: see docs/ui-tests.md, "Running
// locally" — `playwright install` is never run from here); failing that
// (CI, where `npx playwright install --with-deps chromium` put the browser
// in playwright-core's own default cache), playwright-core's normal
// discovery, by not passing `executablePath` at all. Mirrors
// spikes/server-worker/browser3.mjs's local-Mac path.

import { chromium } from "playwright-core";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

function macCacheExecutable() {
  const base = path.join(os.homedir(), "Library", "Caches", "ms-playwright", "chromium-1234");
  return path.join(base, "chrome-mac-arm64", "Google Chrome for Testing.app", "Contents", "MacOS",
                   "Google Chrome for Testing");
}

function resolveExecutable() {
  if (process.env.EMBER_CHROMIUM) return process.env.EMBER_CHROMIUM;
  const mac = macCacheExecutable();
  return existsSync(mac) ? mac : undefined;
}

export async function launchBrowser() {
  const executablePath = resolveExecutable();
  return chromium.launch({ executablePath, headless: true });
}

/** A page wired to fail the test on a console error, an uncaught page
 * error, or an unexpected dialog — the same signals browser3.mjs collects
 * by hand, surfaced here as thrown errors instead of a printed list. */
export async function newPage(browser) {
  // An explicit context, not browser.newPage(): axe's analyze() opens a
  // second page in the same context, which a newPage() context refuses.
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error") problems.push("console: " + m.text()); });
  page.on("pageerror", (e) => problems.push("pageerror: " + e.message));
  page.on("dialog", async (d) => { problems.push("dialog: " + d.message()); await d.dismiss(); });
  page.problems = problems;
  return page;
}

export function assertNoProblems(page) {
  if (page.problems.length > 0) {
    throw new Error("unexpected browser console/page errors:\n  " + page.problems.join("\n  "));
  }
}

/** Open a notebook through /open (the URL a bookmark would use), wait for
 * the editor to finish loading, and return the id from the resulting
 * /edit?id=... URL. `origin` is the server's base URL (`http://host:port/`,
 * no query string). */
export async function openNotebook(page, origin, secret, notebookPath) {
  const url = `${origin}open?path=${encodeURIComponent(notebookPath)}&secret=${secret}`;
  await page.goto(url);
  await page.waitForSelector("pluto-cell", { timeout: 30000 });
  await page.waitForFunction(
    () => !document.querySelector("pluto-editor")?.classList.contains("loading"),
    null, { timeout: 30000 });
  return new URL(page.url()).searchParams.get("id");
}

export function cellSelector(id) { return `pluto-cell[id="${id}"]`; }

/** Click into a cell's editor and select-all + type new code, the way a
 * person retyping a cell would (CellInput's CodeMirror instance). */
export async function setCellCode(page, id, code) {
  // A cell off screen renders as CellInput.js's StaticCodeMirrorFaker (a
  // `.cm-editor.cm-ssr-fake` placeholder), swapped for the real CodeMirror
  // once it scrolls into view; clicking the placeholder loses focus to
  // <body>.
  await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
  const sel = `${cellSelector(id)} .cm-editor:not(.cm-ssr-fake) .cm-content`;
  await page.locator(sel).click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await page.keyboard.type(code, { delay: 2 });
}

export async function runCell(page, id) {
  await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
  await page.locator(`${cellSelector(id)} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.keyboard.press("Shift+Enter");
}

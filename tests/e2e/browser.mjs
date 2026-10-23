// Chromium launch, shared across every e2e test. `EMBER_CHROMIUM` picks the
// binary explicitly; failing that, this Mac's local Playwright cache path
// (set up once, outside this suite: see docs/ui-tests.md, "Running
// locally" — `playwright install` is never run from here); failing that
// (CI, where `npx playwright install --with-deps chromium` put the browser
// in playwright-core's own default cache), playwright-core's normal
// discovery, by not passing `executablePath` at all. Mirrors
// spikes/server-worker/browser3.mjs's local-Mac path.

import { chromium, webkit } from "playwright-core";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { artifactsDir } from "./server.mjs";

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

/** `EMBER_BROWSER=webkit` runs the suite in Playwright's WebKit instead
 * (on Linux, the WebKitGTK engine Endeavor's notebook pane uses). Only the
 * UI sweep runs there in CI; the rest of the suite assumes Chromium. */
export async function launchBrowser() {
  if (process.env.EMBER_BROWSER === "webkit") return webkit.launch({ headless: true });
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
  // A failed load's message doesn't say what failed; its location does (#412).
  page.on("console", (m) => { if (m.type() === "error") problems.push("console: " + m.text() + (m.location()?.url ? ` (${m.location().url})` : "")); });
  page.on("pageerror", (e) => problems.push("pageerror: " + e.message));
  page.on("dialog", async (d) => { problems.push("dialog: " + d.message()); await d.dismiss(); });
  page.problems = problems;
  page.on("requestfailed", (r) => { if (/ERR_NO_BUFFER_SPACE/.test(r.failure()?.errorText ?? "")) noBufferSpace(page, r.url()); });
  return page;
}

/** On Windows, when a load fails with ERR_NO_BUFFER_SPACE (#412), write
 * what the machine looks like at that moment to test-results/: the time, the
 * nonpaged pool, the TCP connections by state, the UDP endpoints, the
 * processes holding the most nonpaged memory, and netstat. The 5 s socket
 * samples ruled out running out of ports; this looks at the rest. Once per
 * page. Read-only. */
function noBufferSpace(page, url) {
  if (process.platform !== "win32" || page.noBufferSpace) return;
  page.noBufferSpace = true;
  const file = path.join(artifactsDir(), `412-${Date.now()}.txt`);
  const ps = `& {
    "$(Get-Date -Format HH:mm:ss.fff) ERR_NO_BUFFER_SPACE: ${url.split("?")[0].replace(/[`"$]/g, "")}"
    "nonpaged pool MB: " + [math]::Round((Get-CimInstance Win32_PerfRawData_PerfOS_Memory).PoolNonpagedBytes / 1MB, 1)
    Get-NetTCPConnection | Group-Object State | Select-Object Count, Name | Format-Table -AutoSize | Out-String
    "UDP endpoints: " + @(Get-NetUDPEndpoint).Count
    Get-Process | Sort-Object NPM -Descending | Select-Object -First 15 Name, Id, Handles, NPM | Format-Table -AutoSize | Out-String
    netstat -ano -p tcp
  } *> '${file}'`;
  execFile("powershell.exe", ["-NoProfile", "-Command", ps], () => {});
  console.error(`#412: ERR_NO_BUFFER_SPACE on ${url.split("?")[0]}; the machine's state is in ${file}`);
}

export function assertNoProblems(page) {
  if (page.problems.length > 0) {
    throw new Error("unexpected browser console/page errors:\n  " + page.problems.join("\n  "));
  }
}

/** Open a notebook through /open (the URL a bookmark would use), wait for
 * the editor to finish loading, and return the id from the resulting
 * /edit?id=... URL. `origin` is the server's base URL (`http://host:port/`,
 * no query string).
 *
 * No timeouts of our own on the waits: the page and its notebook arrive
 * when the server sends them, and the test runner's timeout bounds them.
 * 30 s ran out for the first tests of a Windows run, while three files'
 * first servers and browsers started at once (#417). */
export async function openNotebook(page, origin, secret, notebookPath) {
  const url = `${origin}open?path=${encodeURIComponent(notebookPath)}&secret=${secret}`;
  await page.goto(url, { timeout: 0 });
  await page.waitForSelector("pluto-cell", { timeout: 0 });
  await page.waitForFunction(
    () => !document.querySelector("pluto-editor")?.classList.contains("loading"),
    null, { timeout: 0 });
  return new URL(page.url()).searchParams.get("id");
}

export function cellSelector(id) { return `pluto-cell[id="${id}"]`; }

/** Cell `id`'s live editor, or `part` inside it. A cell still showing
 * CellInput.js's static copy of its code (`.cm-ssr-fake`) never matches:
 * a wait the copy satisfies ends before the real editor is there, and a
 * click on the copy loses focus to <body>. */
export function codeSelector(id, part = ".cm-content") {
  return `${cellSelector(id)} .cm-editor:not(.cm-ssr-fake)${part ? " " + part : ""}`;
}

/** Waits for `n` animation frames: what the page renders from state it
 * already has is on screen by then. */
export async function frames(page, n = 2) {
  await page.evaluate((n) => new Promise((resolve) => {
    const step = (left) => (left === 0 ? resolve() : requestAnimationFrame(() => step(left - 1)));
    step(n);
  }), n);
}

/** Waits until the server has handled everything this page sent before
 * the call and the page has rendered the state it sent back
 * (window.ember_round_trip, Editor.js). A check that nothing more
 * happened (no second run, no move, nothing undone) waits on this, not on
 * a fixed time: whatever would happen has come back by then. */
export async function roundTrip(page) {
  await page.evaluate(() => window.ember_round_trip());
  await frames(page);
}

/** Waits until a passing state (queued, running, "Not run yet", ...) the
 * page held back before the call has either shown or been dropped: one
 * shows only once it has lasted common/useSettled.js's SETTLE_MS, on a
 * timer, and a timer set after it for as long runs after it. Call it once
 * the page has rendered what it waits on, e.g. after roundTrip(). */
export async function afterSettle(page) {
  await page.evaluate(async () => {
    const src = document.querySelector('script[src$="editor.js"]').src;
    const { SETTLE_MS } = await import(new URL("common/useSettled.js", src).href);
    await new Promise((resolve) => setTimeout(resolve, SETTLE_MS));
  });
  await frames(page);
}

/** Waits until the page's layout holds still: no CSS transition running,
 * and the boxes of the cells, the column and the side panel the same in
 * two frames in a row. For a check after a resize, a scroll or a theme
 * change. */
export async function layoutSettled(page) {
  await page.evaluate(() => new Promise((resolve) => {
    const boxes = () => JSON.stringify([...document.querySelectorAll("pluto-cell, pluto-notebook, #helpbox-wrapper, header")]
      .map((el) => { const r = el.getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; }));
    let last = null;
    const check = () => {
      const now = boxes();
      const moving = document.getAnimations().some((a) => a instanceof CSSTransition && a.playState === "running");
      if (!moving && now === last) resolve();
      else { last = now; requestAnimationFrame(check); }
    };
    requestAnimationFrame(check);
  }));
}

/** Waits until the page has finished what its clock last started: no try
 * and no key check still out (window.ember_connection, PlutoConnection.js),
 * so it is waiting for its next try, connected, or knows its key was
 * refused. The tries run for real, on the network, so this is what a step
 * of a fake clock (page.clock) waits on. Polled from here: the page's own
 * timers and frames run on that clock, which may be paused. */
export async function connectionSettled(page) {
  const done = () => page.evaluate(() => {
    const c = window.ember_connection;
    return c != null && c.state !== "trying" && c.state !== "syncing" && c.key_checks_out === 0;
  });
  while (!(await done())) await new Promise((resolve) => setTimeout(resolve, 20));
}

/** The websocket messages `page` sends whose bytes include `type`, as a
 * list that grows while the page runs. msgpack keeps a short string's
 * UTF-8 bytes as they are, so the message type's name shows up verbatim.
 * Playwright reports frames in the order they were sent, so after
 * roundTrip() the list holds every one sent before it. `reach(n)` waits
 * until the list holds `n`. */
export function sentMessages(page, type) {
  const seen = [];
  const waiting = [];
  seen.reach = (n) => new Promise((resolve) => {
    if (seen.length >= n) resolve();
    else waiting.push([n, resolve]);
  });
  page.on("websocket", (ws) => {
    ws.on("framesent", (frame) => {
      const payload = frame.payload ?? "";
      const text = Buffer.isBuffer(payload) ? payload.toString("latin1") : String(payload);
      let found = text.includes(type);
      if (!found && !Buffer.isBuffer(payload)) {
        try { found = Buffer.from(text, "base64").toString("latin1").includes(type); } catch { /* not base64 */ }
      }
      if (!found) return;
      seen.push(Date.now());
      for (const w of waiting.filter(([n]) => seen.length >= n)) { waiting.splice(waiting.indexOf(w), 1); w[1](); }
    });
  });
  return seen;
}

/** Wait until the worker is ready and no cell is running or queued. No
 * timeout of its own, as openNotebook(): a cold worker start is still a
 * start (#417). */
export async function waitIdle(page) {
  await page.waitForFunction(() => {
    const nb = window.editor_state?.notebook;
    return nb?.process_status === "ready" && Object.values(nb.cell_results).every((r) => !r.running && !r.queued);
  }, null, { timeout: 0 });
}

/** Hover a cell (at `part` inside it, if given) and wait until the cell is
 * :hover, which is what lets its run button and menu take the pointer
 * (cells.css). Call it once the cells above have stopped changing size: a
 * run's outputs arriving after the hover move the cell out from under a
 * pointer that doesn't move (#271). */
export async function hoverCell(page, id, part = "") {
  await page.locator(part ? `${cellSelector(id)} ${part}` : cellSelector(id)).hover();
  await page.waitForFunction((sel) => document.querySelector(sel)?.matches(":hover"), cellSelector(id), { timeout: 15000 });
}

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

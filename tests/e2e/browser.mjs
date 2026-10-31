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
import { addSection, untimed, waitingFor } from "./waits.mjs";

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
 * UI sweep runs there in CI; the rest of the suite assumes Chromium.
 *
 * No Playwright call on its pages has a time limit (waits.mjs): a wait
 * ends when what it waits for happens, and the runner bounds the test.
 * The browser stays up on a signal, so the report of what a stopped test
 * was waiting for can still ask its pages; it goes when node exits. */
export async function launchBrowser() {
  const options = { headless: true, handleSIGINT: false, handleSIGTERM: false, handleSIGHUP: false };
  if (process.env.EMBER_BROWSER === "webkit") return untimed(await webkit.launch(options));
  const executablePath = resolveExecutable();
  if (process.platform === "win32") return untimed(await chromium.launch(await withoutPortRandomization({ executablePath, ...options })));
  return untimed(await chromium.launch({ executablePath, ...options }));
}

/** On Windows 11 22H2 and later (the runner's Server 2025 among them),
 * Chromium picks each connection's local port at random
 * (TcpPortRandomizationWin), and a connect then fails now and then with
 * WSAENOBUFS, net::ERR_NO_BUFFER_SPACE, while ports are free (#412;
 * microsoft/playwright#43545 reproduced it after about 1,100 page loads,
 * and not with the feature off). Windows 10 doesn't enable it, which fits
 * William never reproducing it.
 *
 * Playwright passes its own --disable-features list, and Chromium keeps
 * only the last one given, so the feature is added to that list rather
 * than passed alone. The list isn't public: it is read from the command
 * line of a browser server started for that, then closed. */
async function withoutPortRandomization(options) {
  const server = await chromium.launchServer(options);
  const theirs = server.process().spawnargs.find((a) => a.startsWith("--disable-features="));
  await server.close();
  if (!theirs) throw new Error("Playwright's Chromium was launched without --disable-features; #412's workaround needs it");
  return { ...options, ignoreDefaultArgs: [theirs], args: [theirs + ",TcpPortRandomizationWin"] };
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

/** Every openNotebook() still under way, with when each step of its open
 * happened, for the report of a wait that never ends (waits.mjs). On
 * #533's probe the wait between the socket's first frame and the first
 * cell was 3 to 4 s for some first opens on Windows (#417), the step
 * #529's open stalled in. #550 split it in two: the server building the
 * notebook's first state, its answer to the page's first
 * `update_notebook`, and then the page drawing it. These times say which
 * of the two a slow open spent its time in. They are only printed, never
 * checked. */
const opening = new Set();
addSection(() => [...opening].map((o) => {
  const at = (t) => (t === undefined ? "not yet" : `${((t - o.start) / 1000).toFixed(2)} s`);
  const took = (a, b) => (a !== undefined && b !== undefined ? ` (${((b - a) / 1000).toFixed(2)} s)` : "");
  return `opening ${o.notebook}, started ${at(Date.now())} ago: socket open ${at(o.socket)}, ` +
    `first update_notebook sent ${at(o.asked)}, first notebook_diff back ${at(o.answered)}${took(o.asked, o.answered)}, ` +
    `first pluto-cell ${at(o.cell)}${took(o.answered, o.cell)}`;
}).join("\n"));

// A Pluto message's msgpack carries its type as the string after the key
// "type": a4 "type", then the type's own fixstr header and bytes.
const typeBytes = (type) => Buffer.concat([Buffer.from([0xa4]), Buffer.from("type"), Buffer.from([0xa0 | type.length]), Buffer.from(type)]);
const UPDATE_NOTEBOOK = typeBytes("update_notebook");
const NOTEBOOK_DIFF = typeBytes("notebook_diff");
const isType = (payload, bytes) => Buffer.isBuffer(payload) && payload.includes(bytes);

/** Open a notebook through /open (the URL a bookmark would use), wait for
 * the editor to finish loading, and return the id from the resulting
 * /edit?id=... URL. `origin` is the server's base URL (`http://host:port/`,
 * no query string).
 *
 * The page and its notebook arrive when the server sends them. 30 s ran
 * out for the first tests of a Windows run, while three files' first
 * servers and browsers started at once (#417). */
export async function openNotebook(page, origin, secret, notebookPath) {
  const url = `${origin}open?path=${encodeURIComponent(notebookPath)}&secret=${secret}`;
  // One of the editor's own files that fails to load leaves it loading for
  // good. Fail now and name the file, not after the test file's 5-minute
  // timeout, which also cancels the file's other tests (#412).
  let onFailed;
  const failed = new Promise((_, reject) => {
    onFailed = (r) => {
      const error = r.failure()?.errorText ?? "";
      if (r.url().startsWith(origin) && error !== "net::ERR_ABORTED")
        reject(new Error(`opening the notebook: ${r.url().split("?")[0]} failed to load: ${error}`));
    };
  });
  failed.catch(() => {});
  page.on("requestfailed", onFailed);
  const open = { notebook: path.basename(notebookPath), start: Date.now() };
  const onSocket = (ws) => {
    open.socket ??= Date.now();
    ws.on("framesent", (f) => { if (opening.has(open) && isType(f.payload, UPDATE_NOTEBOOK)) open.asked ??= Date.now(); });
    ws.on("framereceived", (f) => { if (opening.has(open) && isType(f.payload, NOTEBOOK_DIFF)) open.answered ??= Date.now(); });
  };
  page.on("websocket", onSocket);
  opening.add(open);
  try {
    const loaded = (async () => {
      await page.goto(url);
      await page.waitForSelector("pluto-cell");
      open.cell = Date.now();
      await page.waitForFunction(() => !document.querySelector("pluto-editor")?.classList.contains("loading"));
    })();
    // After a failed load, these waits end when the test closes the page.
    loaded.catch(() => {});
    await Promise.race([failed, loaded]);
    // Pluto draws a long notebook's cells in chunks, after `loading` drops:
    // wait for every cell, so a raw querySelector of a late one finds it (#428).
    await page.waitForFunction(() => {
      const order = window.editor_state?.notebook?.cell_order;
      return Array.isArray(order) && order.every((id) => document.querySelector(`pluto-cell[id="${id}"]`));
    });
  } finally {
    page.off("requestfailed", onFailed);
    page.off("websocket", onSocket);
    opening.delete(open);
  }
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

/** Pauses the page's fake clock (page.clock.install()) about `ahead` ms
 * from now. pauseAt() needs a time ahead of the page's own, which keeps
 * running while the test reads it and asks; on a slow runner the time
 * read can already be past, and pauseAt() throws (#557). It has paused the
 * clock by then (Playwright pauses first, then moves to the time), so the
 * time read again stays put and the second try succeeds. */
export async function pauseClock(page, ahead) {
  for (;;) {
    try {
      return await page.clock.pauseAt(await page.evaluate((ms) => Date.now() + ms, ahead));
    } catch (e) {
      if (!/Cannot fast-forward to the past/.test(e.message)) throw e;
    }
  }
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
  const settled = (async () => { while (!(await done())) await new Promise((resolve) => setTimeout(resolve, 20).unref()); })();
  await waitingFor("the connection settles (connectionSettled)", settled,
    () => page.evaluate(() => JSON.stringify(window.ember_connection)));
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
  seen.reach = (n) => waitingFor(`${n} sent "${type}" messages (sentMessages)`, new Promise((resolve) => {
    if (seen.length >= n) resolve();
    else waiting.push([n, resolve]);
  }), () => `${seen.length} sent`);
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

/** Wait until the worker is ready and no cell is running or queued. A
 * cold worker start is still a start (#417). */
export async function waitIdle(page) {
  await page.waitForFunction(() => {
    const nb = window.editor_state?.notebook;
    return nb?.process_status === "ready" && Object.values(nb.cell_results).every((r) => !r.running && !r.queued);
  });
}

/** Hover a cell (at `part` inside it, if given) and wait until the cell is
 * :hover, which is what lets its run button and menu take the pointer
 * (cells.css). Call it once the cells above have stopped changing size: a
 * run's outputs arriving after the hover move the cell out from under a
 * pointer that doesn't move (#271). */
export async function hoverCell(page, id, part = "") {
  await page.locator(part ? `${cellSelector(id)} ${part}` : cellSelector(id)).hover();
  await page.waitForFunction((sel) => document.querySelector(sel)?.matches(":hover"), cellSelector(id));
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

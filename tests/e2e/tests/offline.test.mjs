// Piece 2 (docs/ui-2.md, "Offline bundle"), scenarios 18, 19, 21 of
// docs/ui-2-tests.md: the page works with no network but to the server
// itself (MathJax aside), every vendored library does its job, and a
// second load re-uses the browser's cache for the hashed vendor files.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector } from "../browser.mjs";

const FRONTEND = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "inst", "frontend");

/** Abort every request whose host isn't 127.0.0.1 (a real offline browser
 * still resolves and fails non-local hosts quickly; aborting in Playwright
 * mirrors "no internet" without the server itself needing network). Returns
 * the list of aborted URLs. */
function blockNonLocal(page) {
  const aborted = [];
  page.route("**/*", (route) => {
    const url = new URL(route.request().url());
    if (url.hostname === "127.0.0.1") return route.continue();
    aborted.push(url.href);
    return route.abort();
  });
  return aborted;
}

/** `assertNoProblems()`, but tolerating the one console error an aborted
 * MathJax request itself produces (the browser logs "Failed to load
 * resource" for any failed request, intentionally aborted or not) --
 * exactly the exception ui-2-tests.md 18 names ("no failed requests other
 * than aborted MathJax"). */
function assertNoProblemsOffline(page) {
  const real = page.problems.filter((p) => !/Failed to load resource: net::ERR_FAILED/.test(p));
  if (real.length > 0) {
    throw new Error("unexpected browser console/page errors:\n  " + real.join("\n  "));
  }
}

test("offline: rich.R works with every non-local request aborted (18)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "offline.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  const aborted = blockNonLocal(page);

  const failedRequests = [];
  page.on("requestfailed", (req) => {
    const url = new URL(req.url());
    if (url.hostname !== "127.0.0.1") return; // expected: MathJax etc., already in `aborted`
    failedRequests.push(`${req.url()}: ${req.failure()?.errorText}`);
  });

  const iconResponses = [];
  page.on("response", (res) => {
    if (/\/img\/icons\/.*\.svg$/.test(new URL(res.url()).pathname)) iconResponses.push(res.status());
  });

  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "DF");
  await page.waitForSelector(`${cellSelector("DF")} pluto-output`, { timeout: 20000 });

  // `df <- ...` is an assignment (an invisible result, same as the
  // fixture's own code): editing it to a bare expression instead makes the
  // rerun's output visibly change, which is what this step is checking.
  await setCellCode(page, "DF", "mtcars[1:5, ]");
  await runCell(page, "DF");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Mazda"),
    `${cellSelector("DF")} pluto-output`, { timeout: 20000 });

  // Settings panel: SettingsBoolean listens for this window event.
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("pluto open settings")));
  await page.waitForSelector("dialog.psettings[open]", { timeout: 5000 });
  await page.keyboard.press("Escape");

  await page.locator('header#pluto-nav button[aria-label="Export"]').click();
  await page.waitForSelector("dialog#export[open]", { timeout: 5000 });

  // Code highlighted as R: the MD cell's fenced block (` ```r\n1 + 1\n``` `)
  // is rendered as output regardless of the cell's own code-fold state (only
  // the *input* editor folds), so highlight.js's R grammar should have
  // tagged "1" as a number by now. ("1 + 1" has no keyword, so
  // `.hljs-keyword` would never appear here -- `.hljs-number` is what this
  // specific fixture actually produces.)
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.querySelector(".hljs-number") != null,
    cellSelector("MD"), { timeout: 10000 });

  assert.ok(aborted.some((u) => u.includes("mathjax")), "expected MathJax to be the thing aborted");
  assert.deepEqual(failedRequests, []);
  assert.ok(iconResponses.length > 0, "expected at least one local icon request");
  assert.ok(iconResponses.every((s) => s === 200), `expected all icon requests to succeed: ${iconResponses}`);

  assertNoProblemsOffline(page);
});

test("offline: each vendored library does its job (19)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "offline-vendor.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  blockNonLocal(page);
  // A slow CPU makes CodeMirror parse in slices, which is the only way a
  // second copy of @lezer/common in the bundle showed up (MD's fenced R code).
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 8 });
  await openNotebook(page, server.origin, server.secret, notebook);

  // Preact + htm: the page rendered at all (pluto-cell elements exist).
  const cellCount = await page.locator("pluto-cell").count();
  assert.ok(cellCount > 0);

  // immer + msgpack-lite: an edit round-trips through the websocket.
  await setCellCode(page, "DF", "mtcars[1:3, ]");
  await runCell(page, "DF");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Mazda"),
    `${cellSelector("DF")} pluto-output`, { timeout: 20000 });

  // ansi_up: ANSI's coloured output.
  await runCell(page, "ANSI");
  await page.waitForFunction(
    () => document.querySelector("span.ansi-red-fg") != null, null, { timeout: 20000 });

  // dialog-polyfill: the export dialog opens (uses <dialog>, polyfilled where needed).
  await page.locator('header#pluto-nav button[aria-label="Export"]').click();
  await page.waitForSelector("dialog#export[open]", { timeout: 5000 });
  await page.keyboard.press("Escape")

  // highlight.js: the fenced R block inside MD is highlighted. Its output
  // (unlike its input editor) isn't affected by the cell's code-fold state,
  // and "1 + 1" has no keyword, so the real tag to expect is `.hljs-number`
  // (not `.cm-content`, which is just CodeMirror's own editor and would
  // make this pass even if highlight.js never ran).
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.querySelector(".hljs-number") != null,
    cellSelector("MD"), { timeout: 10000 });

  // lodash, semver, DOMPurify: each vendored file is a real ES module
  // served from the page's own origin, so it can be imported and exercised
  // directly -- a cheap, real check of the library's own behaviour rather
  // than just "the module loaded".
  const libChecks = await page.evaluate(async () => {
    const [{ default: _ }, { default: semver }, { default: purify }] = await Promise.all([
      import("./imports/lodash-es.js"),
      import("./imports/semver-es.js"),
      import("./imports/DOMPurify.js"),
    ]);
    return {
      lodash: _.last([1, 2, 3]),
      semver: semver.gt("1.2.0", "1.1.0"),
      dompurifyStripsScript: !purify.sanitize("<script>window.pwned = true</script><b>ok</b>").includes("<script"),
    };
  });
  assert.equal(libChecks.lodash, 3, "expected lodash's _.last to work");
  assert.equal(libChecks.semver, true, "expected semver's gt() to work");
  assert.ok(libChecks.dompurifyStripsScript, "expected DOMPurify to strip a <script> tag");

  assertNoProblemsOffline(page);
});

test("offline: the three bundled fonts load with no network request leaving localhost (116)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "offline-fonts.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  const aborted = blockNonLocal(page);

  await openNotebook(page, server.origin, server.secret, notebook);

  const checks = await page.evaluate(async () => {
    await document.fonts.ready;
    return {
      figtree: document.fonts.check("16px Figtree"),
      sourceSerif: document.fonts.check("16px 'Source Serif 4'"),
      plexMono: document.fonts.check("13px 'IBM Plex Mono'"),
    };
  });

  assert.equal(checks.figtree, true, "expected Figtree to be a loadable font");
  assert.equal(checks.sourceSerif, true, "expected Source Serif 4 to be a loadable font");
  assert.equal(checks.plexMono, true, "expected IBM Plex Mono to be a loadable font");
  assert.ok(aborted.every((u) => /mathjax/.test(u)), `expected no non-MathJax request to leave localhost: ${aborted}`);

  assertNoProblemsOffline(page);
});

test("cache: a hashed vendor file is served from cache on a second fetch (21)", async (t) => {
  // Not page.reload() + counting page.on("request") events: attaching a
  // request/response listener keeps Playwright's CDP Network domain
  // enabled on the page, which (independent of Cache-Control) makes
  // Chromium revalidate every sub-resource of a reload or fresh
  // navigation -- confirmed by hand: even a brand new tab to the same
  // notebook re-fetched every vendor file with `fromDiskCache: false`.
  // The Resource Timing API's `transferSize` isn't affected by that: a
  // cache hit reports `transferSize: 0` (no bytes went over the wire)
  // regardless of whether Network domain instrumentation is attached,
  // which is what actually matters here -- a slow tunnel carrying the
  // file once per browser (docs/ui-2.md, "Offline bundle").
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cache.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const hashed = fs.readdirSync(path.join(FRONTEND, "imports", "vendor"))
    .find((f) => f.startsWith("preact-") && f.endsWith(".js"));
  assert.ok(hashed, "expected a hashed preact-*.js vendor file");
  const url = server.origin + "imports/vendor/" + hashed;

  const sizes = await page.evaluate(async (u) => {
    performance.clearResourceTimings();
    await (await fetch(u, { cache: "default" })).arrayBuffer();
    await new Promise((r) => setTimeout(r, 200));
    await (await fetch(u, { cache: "default" })).arrayBuffer();
    await new Promise((r) => setTimeout(r, 200));
    return performance.getEntriesByType("resource")
      .filter((e) => e.name === u)
      .map((e) => e.transferSize);
  }, url);

  assert.equal(sizes.length, 2);
  assert.equal(sizes[1], 0, `expected the second fetch to be a cache hit (transferSize 0), got sizes ${sizes}`);

  assertNoProblems(page);
});

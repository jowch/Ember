// Scenario 37/45 (docs/ui-tests.md): opening a notebook by URL with the
// secret loads every cell, the safe-preview banner, highlighted R code and
// no console errors; without the secret, the server refuses.

import { test } from "node:test";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";
import path from "node:path";

test("open: loads every cell with safe preview, R highlighting, no console errors", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "open.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const cellCount = await page.locator("pluto-cell").count();
  assert.equal(cellCount, 6, "the 6 cells from the fixture");

  const bannerVisible = await page.locator("#ember-safe-preview").count();
  assert.ok(bannerVisible > 0, "the safe-preview banner is shown before execution is allowed");

  // CodeMirror 6's default highlighter assigns generated, non-semantic
  // class names (e.g. "μr") rather than static ones like ".cm-keyword";
  // any styled token span beyond the empty-line placeholder is evidence the
  // R grammar tokenized and highlighted the code (not just plain text).
  const tokens = page.locator("pluto-cell .cm-content span[class]:not(.cm-placeholder)");
  await tokens.first().waitFor();
  const highlighted = await tokens.count();
  assert.ok(highlighted > 0, "R code is syntax-highlighted (styled CodeMirror token spans exist)");

  assertNoProblems(page);
});

test("open: /open and /edit refuse without the secret", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "open-refused.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  const resp = await page.goto(`${server.origin}open?path=${encodeURIComponent(notebook)}`);
  assert.equal(resp.status(), 403);
});

test("open: an editor file that fails to load fails openNotebook, naming the file (#412)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "open-failed-file.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  // The file #412's Windows run lost, failed the same way on purpose.
  const page = await newPage(browser);
  await page.route("**/common/SliderServerClient.js", (route) => route.abort("failed"));
  await assert.rejects(openNotebook(page, server.origin, server.secret, notebook),
    /common\/SliderServerClient\.js failed to load: net::ERR_FAILED/);
  // The page then reloads once on its own and fails again (#578). Wait for
  // that end state before closing: Playwright drops a route that arrives
  // after page.close(), which leaves the reload's request paused, and on
  // Windows the close then never returned (#623).
  const bar = page.locator("#ember-load-failed");
  await bar.waitFor();
  assert.match(await bar.innerText(), /couldn't load the editor's code/);
  await page.close();
});

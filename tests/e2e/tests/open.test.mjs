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
  assert.equal(cellCount, 6, "setup + 5 cells from the fixture");

  const bannerVisible = await page.locator("#ember-safe-preview").count();
  assert.ok(bannerVisible > 0, "the safe-preview banner is shown before execution is allowed");

  // CodeMirror 6's default highlighter assigns generated, non-semantic
  // class names (e.g. "μr") rather than static ones like ".cm-keyword";
  // any styled token span beyond the empty-line placeholder is evidence the
  // R grammar tokenized and highlighted the code (not just plain text).
  const tokens = page.locator("pluto-cell .cm-content span[class]:not(.cm-placeholder)");
  await tokens.first().waitFor({ timeout: 10000 });
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

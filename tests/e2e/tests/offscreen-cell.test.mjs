// browser.mjs's runCell()/setCellCode() click a cell's `.cm-content`.
// CellInput.js renders a cell that's off screen as a static placeholder
// (StaticCodeMirrorFaker, `.cm-editor.cm-ssr-fake`) and only swaps in the
// real CodeMirror once it scrolls into view; clicking the placeholder
// loses focus to <body>, so Shift+Enter or typing never reaches the
// editor. This notebook has ~30 cells, tall enough that a late one sits
// well below an 800px window, to exercise that path.

import { test } from "node:test";
import path from "node:path";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector } from "../browser.mjs";

test("runCell on a cell below an 800px window actually runs it", async (t) => {
  const notebook = tempNotebook("many-cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "offscreen-cell.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("30"),
    cellSelector("C30") + " pluto-output", { timeout: 20000 });

  const top = await page.evaluate(
    (sel) => document.querySelector(sel)?.getBoundingClientRect().top, cellSelector("C30"));
  assert.ok(top > 800, `C30 should start below the 800px window (top was ${top})`);

  await setCellCode(page, "C30", "999");
  await runCell(page, "C30");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("999"),
    cellSelector("C30") + " pluto-output", { timeout: 20000 });

  assertNoProblems(page);
});

test("the off-screen placeholder's code is not spellchecked or translated", async (t) => {
  const notebook = tempNotebook("many-cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "offscreen-fake.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const attrs = await page.locator(`${cellSelector("C30")} .cm-editor.cm-ssr-fake .cm-content`).evaluate((el) =>
    [el.getAttribute("spellcheck"), el.getAttribute("translate"), el.spellcheck, el.translate]);
  assert.deepEqual(attrs, ["false", "no", false, false]);
  assertNoProblems(page);
});

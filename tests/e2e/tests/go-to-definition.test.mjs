// Go-to-definition (docs/ui-2.md 4e, ui-2-tests.md 63): the engine's
// analysis marks each name a cell reads that another cell defines, and
// Ctrl/Cmd-click on it focuses the defining cell with the definition
// selected. The marks go away while the cell's text differs from what the
// analysis read, and come back once it's submitted.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

const MOD = process.platform === "darwin" ? "Meta" : "Control";
const mark = (cell, name) => `${cellSelector(cell)} .cm-editor:not(.cm-ssr-fake) [data-pluto-variable="${name}"]`;

/** The text selected in the focused editor, and the cell it's in. */
const focused = (page) => page.evaluate(() => ({
  cell: document.activeElement?.closest("pluto-cell")?.id ?? null,
  text: window.getSelection()?.toString() ?? "",
}));

test("go-to-definition: Ctrl/Cmd-click on a name another cell defines selects its definition (63)", { timeout: 120000 }, async (t) => {
  const notebook = tempNotebook("goto.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "go-to-definition.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // B reads total.n and tiny from A, and mean from base R: only A's names
  // are links. A dotted name is an ordinary R name.
  await page.locator(cellSelector("B")).scrollIntoViewIfNeeded();
  await page.waitForSelector(mark("B", "total.n"), { timeout: 30000 });
  await page.waitForSelector(mark("B", "tiny"), { timeout: 30000 });
  assert.equal(await page.locator(mark("B", "mean")).count(), 0, "a base function isn't a link");
  assert.equal(await page.locator(mark("B", "total.n")).innerText(), "total.n");

  await page.keyboard.down(MOD);
  await page.locator(mark("B", "tiny")).click();
  await page.keyboard.up(MOD);
  await page.waitForFunction(() => {
    const cell = document.activeElement?.closest("pluto-cell")?.id;
    return cell === "A" && window.getSelection()?.toString() === "tiny";
  }, null, { timeout: 10000 });
  assert.deepEqual(await focused(page), { cell: "A", text: "tiny" });

  // A replacement call links to the replacement function: `r(w) <- 3`
  // runs `r<-`, which R defines.
  await page.locator(cellSelector("W")).scrollIntoViewIfNeeded();
  await page.waitForSelector(mark("W", "r<-"), { timeout: 30000 });
  assert.equal(await page.locator(mark("W", "r<-")).innerText(), "r");
  await page.keyboard.down(MOD);
  await page.locator(mark("W", "r<-")).click();
  await page.keyboard.up(MOD);
  await page.waitForFunction(() => {
    const cell = document.activeElement?.closest("pluto-cell")?.id;
    return cell === "R" && window.getSelection()?.toString() === "`r<-`";
  }, null, { timeout: 10000 });

  // A plain click (no modifier) edits as usual and jumps nowhere.
  await page.locator(cellSelector("B")).scrollIntoViewIfNeeded();
  await page.locator(mark("B", "total.n")).click();
  assert.equal((await focused(page)).cell, "B");

  // Typing in B removes its marks (their offsets no longer match the text)...
  await page.keyboard.press("End");
  await page.keyboard.type(" + 0", { delay: 10 });
  await page.waitForFunction(
    (sel) => document.querySelectorAll(sel).length === 0,
    `${cellSelector("B")} [data-pluto-variable]`, { timeout: 10000 });

  // ...until B is submitted, when the engine's new analysis brings them back.
  await runCell(page, "B");
  await page.waitForSelector(mark("B", "total.n"), { timeout: 30000 });
  await page.waitForSelector(mark("B", "tiny"), { timeout: 30000 });

  const loaded = await page.evaluate(() => performance.getEntriesByType("resource").map((e) => e.name));
  assert.ok(!loaded.some((u) => u.includes("scopestate_statefield")), "Pluto's Julia scope analysis isn't loaded");

  await page.screenshot({ path: path.join(artifactsDir(), "go-to-definition.png") });
  assertNoProblems(page);
});

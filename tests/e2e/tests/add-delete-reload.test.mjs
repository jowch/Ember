// Scenario 41 (docs/ui-tests.md): add a cell below, type, run; delete it;
// reload and the order/code survive, matching the file.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

test("add + run + delete a cell, then reload: state matches the file", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "add-delete.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("B"));
  // B's "after" button and ERR's "before" button sit at the same boundary
  // and overlap; force the click rather than fighting Playwright's
  // actionability check over which one is on top.
  await page.locator(`${cellSelector("B")} button.add_cell.after`).click({ force: true });

  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "B");
  assert.ok(newCellId, "a new cell was inserted right after B");

  const newSel = `pluto-cell[id="${newCellId}"]`;
  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("41 + 1", { delay: 2 });
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("42"),
    `${newSel} pluto-output`, { timeout: 20000 });

  await page.locator(`${newSel} button.input_context_menu`).click();
  await page.locator(`${newSel} button.delete`).click();
  await page.waitForFunction((id) => !document.getElementById(id), newCellId, { timeout: 10000 });

  const countBefore = await page.locator("pluto-cell").count();

  // The page drops the cell before the server has saved the deletion (about
  // 100 ms later); a reload inside that window would bring the cell back.
  const deadline = Date.now() + 15000;
  while (/41 \+ 1/.test(fs.readFileSync(notebook, "utf8")) && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 100));
  }

  await page.reload();
  await page.waitForSelector("pluto-cell", { timeout: 30000 });
  await page.waitForFunction(
    () => !document.querySelector("pluto-editor")?.classList.contains("loading"),
    null, { timeout: 30000 });

  const countAfter = await page.locator("pluto-cell").count();
  assert.equal(countAfter, countBefore, "cell count survives the reload");
  assert.equal(await page.locator(newSel).count(), 0, "the deleted cell stays gone");

  const onDisk = fs.readFileSync(notebook, "utf8");
  assert.doesNotMatch(onDisk, /41 \+ 1/);

  assertNoProblems(page);
});

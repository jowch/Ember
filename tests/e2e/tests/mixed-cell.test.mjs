// A cell mixing #' lines and code is a graph error with a Split button
// (ui-3-tests.md 59): clicking it leaves the text in the first cell and
// puts the code in a new cell below, which hasn't run.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, runCell, cellSelector } from "../browser.mjs";

test("mixed cell: shows the mixed error and a Split button; clicking it splits the cell (59)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "mixed-cell.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // Enter on a #' line starts the next with "#' ", which the Backspaces remove.
  await setCellCode(page, "B", "#' A note.\n");
  for (let i = 0; i < 3; i++) await page.keyboard.press("Backspace");
  await page.keyboard.type("sum(x)", { delay: 2 });
  // Shift+Enter both commits the edit and allows execution; B can't
  // actually run (its own graph error), so it just shows the error.
  await runCell(page, "B");

  const box = `${cellSelector("B")} jlerror.ember`;
  await page.waitForSelector(box, { timeout: 15000 });
  assert.equal(await page.locator(`${box} > header > p:first-child`).innerText(), "Text and code in one cell");
  assert.equal(await page.locator(`${box} > header > p.ember-error-note`).innerText(),
    "A cell is either text (only #' lines) or code. Nothing in it has run.");
  assert.equal(await page.locator(`${box} > header code`).innerText(), "#'");
  assert.equal(await page.locator(`${cellSelector("B")} ember-chip`).count(), 0, "no \"Not run yet\" chip on the errored cell");

  // The Split button is inside the error box (board Insert5).
  const splitButton = page.locator(`${box} > button.ember-split`);
  await splitButton.waitFor({ timeout: 15000 });
  assert.equal(await splitButton.innerText(), "Split into 2 cells");
  assert.equal(await page.locator(`${cellSelector("B")} > button.ember-split`).count(), 0);
  assert.equal(await splitButton.evaluate((el) => el.getBoundingClientRect().height), 26);

  const countBefore = await page.locator("pluto-cell").count();
  await splitButton.click();

  await page.waitForFunction(
    (n) => document.querySelectorAll("pluto-cell").length === n,
    countBefore + 1, { timeout: 15000 });

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("A note."),
    cellSelector("B") + " pluto-output", { timeout: 15000 });
  const bText = await page.locator(`${cellSelector("B")} pluto-output`).innerText();
  assert.match(bText, /A note\./);
  assert.equal(await page.locator(cellSelector("B")).evaluate((el) => el.classList.contains("code_folded")), false, "the text half is not folded for you");

  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "B");
  assert.ok(newCellId, "a new code cell was inserted right after B");
  const newSel = `pluto-cell[id="${newCellId}"]`;
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.querySelector(".cm-content")?.innerText.includes("sum(x)"),
    newSel, { timeout: 10000 });
  assert.equal(await page.locator(`${newSel} pluto-output`).innerText(), "");

  assertNoProblems(page);
});

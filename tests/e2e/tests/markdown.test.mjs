// Text cells are editable (docs/ui.md, "Decisions"): editing and running
// one re-renders with the new content. A cell's kind comes from its code
// (ui-3.md): every non-blank line has to start with `#'` for it to read
// as text.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, runCell, cellSelector } from "../browser.mjs";

test("markdown: editing and running a text cell renders the new text", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "markdown.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // Enter on a #' line starts the next with "#' ".
  await setCellCode(page, "MD", "#' # Changed\n\nNew text.");
  await runCell(page, "MD");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Changed"),
    cellSelector("MD") + " pluto-output", { timeout: 15000 });

  assertNoProblems(page);
});

test("markdown: a new cell typed as `#' ...` becomes a text cell and stays unfolded", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "markdown-new-cell.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const cellCountBefore = await page.locator("pluto-cell").count();
  await page.locator(`${cellSelector("B")} .cm-content`).click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+Enter" : "Control+Enter");
  await page.waitForFunction(
    (before) => document.querySelectorAll("pluto-cell").length > before,
    cellCountBefore, { timeout: 15000 });

  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "B");
  assert.ok(newCellId, "a new cell was inserted right after B");
  const newSel = `pluto-cell[id="${newCellId}"]`;

  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("#' Hello", { delay: 2 });
  await page.keyboard.press("Shift+Enter");

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Hello"),
    `${newSel} pluto-output`, { timeout: 15000 });
  assert.equal(await page.locator(newSel).evaluate((el) => el.classList.contains("text_cell") && el.classList.contains("code_folded")), false,
    "a text cell is never folded for you");
  assert.ok(await page.locator(newSel).evaluate((el) => el.classList.contains("text_cell")));
  await page.locator(`${newSel} pluto-input .cm-editor`).waitFor({ state: "visible", timeout: 5000 });

  assertNoProblems(page);
});

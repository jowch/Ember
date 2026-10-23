// The run button and cell menu are either shown or hidden (cells.css),
// never left at Pluto's 0.6 by a cell that has focus inside it but not in
// its code.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector, hoverCell, codeSelector } from "../browser.mjs";

test("run button: a selected cell's run button is hidden, not half faded", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "run-button-opacity.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const opacity = (id) => page.locator(`${cellSelector(id)} button.ember-run`).evaluate((el) => getComputedStyle(el).opacity);
  // The opacity eases over 0.15 s, so wait for the value it should end at
  // rather than read it after a fixed pause (#144); a timeout says what it was.
  const opacityBecomes = async (id, want, what) => {
    try {
      await page.waitForFunction(([sel, want]) => getComputedStyle(document.querySelector(sel)).opacity === want,
        [`${cellSelector(id)} button.ember-run`, want], { timeout: 5000 });
    } catch {
      assert.equal(await opacity(id), want, what);
    }
  };
  const idle = (id) => page.waitForFunction((sel) => document.querySelector(sel)?.dataset.rail === "idle", cellSelector(id), { timeout: 15000 });

  await runCell(page, "B");
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("55"), cellSelector("B") + " pluto-output", { timeout: 30000 });
  await page.locator(codeSelector("A")).click();
  await page.mouse.move(1, 1);
  await opacityBecomes("A", "1", "shown while typing in A");

  // Esc selects the cell: focus moves to pluto-cell, still inside it.
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => document.activeElement.id === "A", null, { timeout: 5000 });
  await opacityBecomes("A", "0", "a selected cell shows no run button");

  // Clicking the run button leaves focus on it, without :focus-visible
  // (the user's screenshot: A's button half faded while B was hovered).
  await page.locator(codeSelector("A")).hover();
  await page.locator(`${cellSelector("A")} button.ember-run`).click();
  await idle("A");
  await idle("B");
  await hoverCell(page, "B", ".cm-editor:not(.cm-ssr-fake) .cm-content");
  assert.equal(await page.evaluate(() => document.activeElement.classList.contains("ember-run")), true, "focus stays on the clicked button");
  await opacityBecomes("B", "1", "the hovered cell's button");
  await opacityBecomes("A", "0", "the clicked button, once the pointer leaves its cell");

  assertNoProblems(page);
});

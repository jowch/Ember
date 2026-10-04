// The run button and cell menu are either shown or hidden (cells.css),
// never left at Pluto's 0.6 by a cell that has focus inside it but not in
// its code.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

test("run button: a selected cell's run button is hidden, not half faded", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "run-button-opacity.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const opacity = (id) => page.locator(`${cellSelector(id)} button.ember-run`).evaluate((el) => getComputedStyle(el).opacity);
  const settle = () => page.waitForTimeout(400);
  const idle = (id) => page.waitForFunction((sel) => document.querySelector(sel)?.dataset.rail === "idle", cellSelector(id), { timeout: 15000 });

  await runCell(page, "B");
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("55"), cellSelector("B") + " pluto-output", { timeout: 30000 });
  await page.locator(`${cellSelector("A")} .cm-content`).click();
  await page.mouse.move(1, 1);
  await settle();
  assert.equal(await opacity("A"), "1", "shown while typing in A");

  // Esc selects the cell: focus moves to pluto-cell, still inside it.
  await page.keyboard.press("Escape");
  await settle();
  assert.equal(await page.evaluate(() => document.activeElement.id), "A");
  assert.equal(await opacity("A"), "0", "a selected cell shows no run button");

  // Clicking the run button leaves focus on it, without :focus-visible
  // (the user's screenshot: A's button half faded while B was hovered).
  await page.locator(`${cellSelector("A")} .cm-content`).hover();
  await page.locator(`${cellSelector("A")} button.ember-run`).click();
  await idle("A");
  await idle("B");
  await page.locator(`${cellSelector("B")} .cm-content`).hover();
  await settle();
  assert.equal(await page.evaluate(() => document.activeElement.classList.contains("ember-run")), true, "focus stays on the clicked button");
  assert.equal(await opacity("B"), "1", "the hovered cell's button");
  assert.equal(await opacity("A"), "0", "the clicked button, once the pointer leaves its cell");

  assertNoProblems(page);
});

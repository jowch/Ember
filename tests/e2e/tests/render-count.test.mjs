// #289: adding a cell to a notebook re-rendered every cell, because the
// names → cell map handed to each cell was a new object after any change
// to cell_dependencies. Adding an empty cell should render only the new
// cell (and at most its neighbours), not all N.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, layoutSettled } from "../browser.mjs";

test("adding a cell re-renders O(1) cells, not every cell", async (t) => {
  const notebook = tempNotebook("many-cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "render-count.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  // Past 20 cells the rest render after a short delay; wait for all.
  const total = await page.evaluate(() => Object.keys(window.editor_state?.notebook?.cell_inputs ?? {}).length);
  assert.ok(total >= 30, `fixture has 30+ cells (got ${total})`);
  await page.waitForFunction((n) => document.querySelectorAll("pluto-cell").length === n, total);
  await layoutSettled(page);

  const anchor = "C15";
  await page.locator(cellSelector(anchor)).scrollIntoViewIfNeeded();
  // Cells scrolled into view swap their static stand-in for a real editor,
  // which renders them; count only from after that has settled.
  // The swap happens once a cell's code box is in view (CellInput.js).
  await page.waitForFunction(() => [...document.querySelectorAll("pluto-input")].every((input) => {
    const r = input.getBoundingClientRect();
    return r.bottom < 0 || r.top > window.innerHeight || input.querySelector(".cm-ssr-fake") == null;
  }), null, { timeout: 0 });
  await layoutSettled(page);
  await page.evaluate(() => {
    window.__ember_renders = {};
    window.__ember_on_cell_render = (id) => { window.__ember_renders[id] = (window.__ember_renders[id] ?? 0) + 1; };
  });

  await page.hover(cellSelector(anchor));
  await page.locator(`${cellSelector(anchor)} button.add_cell.after`).click({ force: true });
  await page.waitForFunction((n) => document.querySelectorAll("pluto-cell").length === n + 1, total);
  const newId = await page.evaluate((a) => document.getElementById(a)?.nextElementSibling?.id, anchor);
  // The re-renders came with the server's reply, which adds the new cell's
  // cell_dependencies (#289): wait for it, then let renders settle.
  await page.waitForFunction((id) => window.editor_state?.notebook?.cell_dependencies?.[id] != null, newId, { timeout: 15000 });
  // The same counts in two frames in a row.
  await page.evaluate(() => new Promise((resolve) => {
    let last = null;
    const check = () => {
      const now = JSON.stringify(window.__ember_renders);
      if (now === last) resolve();
      else { last = now; requestAnimationFrame(check); }
    };
    requestAnimationFrame(check);
  }));

  const renders = await page.evaluate(() => window.__ember_renders);
  const others = Object.keys(renders).filter((id) => id !== newId && id !== anchor);
  assert.ok(renders[newId] >= 1, "the new cell rendered");
  assert.ok(others.length <= 2,
    `adding a cell re-rendered ${others.length} other cells of ${total}: ${others.join(", ")}`);

  assertNoProblems(page);
});

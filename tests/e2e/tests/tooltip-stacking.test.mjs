// A cell's completion list is drawn above the cell below it, not under that
// cell's code box (every pluto-input stacks at the same z-index).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

test("tooltips: the completion list covers the next cell's code", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "tooltip-stacking.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "A");
  await page.waitForFunction(() => window.editor_state.notebook.cell_results.A?.output?.last_run_timestamp > 0, null, { timeout: 30000 });

  await page.locator(`${cellSelector("A")} .cm-content`).click();
  await page.keyboard.press("End");
  await page.keyboard.type("\nli", { delay: 20 });
  const list = page.locator(`${cellSelector("A")} .cm-tooltip-autocomplete`);
  await list.waitFor({ timeout: 15000 });
  await page.waitForTimeout(200);

  const listBox = await list.boundingBox();
  const nextBox = await page.locator(`${cellSelector("B")} > pluto-input .cm-editor`).boundingBox();
  const point = { x: listBox.x + 20, y: nextBox.y + Math.min(10, nextBox.height / 2) };
  assert.ok(point.y > listBox.y && point.y < listBox.y + listBox.height, `the list reaches into B's code box: ${JSON.stringify({ listBox, nextBox })}`);

  const hit = await page.evaluate(({ x, y }) => {
    const el = document.elementFromPoint(x, y);
    return { in_list: el?.closest(".cm-tooltip-autocomplete") != null, cell: el?.closest("pluto-cell")?.id ?? null };
  }, point);
  assert.deepEqual(hit, { in_list: true, cell: "A" });

  assertNoProblems(page);
});

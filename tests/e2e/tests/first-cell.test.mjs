// #284: the first cell is like any other. FIRST and LATER hold the same
// code and neither has run, so on load they show the same chip, at every
// moment of the load, not only once it has settled. Running RUN allows
// execution without running them, and a reload is the "on load" part.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, runCell } from "../browser.mjs";

/** What a cell shows of its run state: its chip's text and whether the
 * chip is visible, plus the state classes the chip's style keys on. */
const look = (page, id) => page.evaluate((id) => {
  const cell = document.getElementById(id);
  const chip = cell?.querySelector(":scope > ember-chip");
  const shown = chip != null && chip.getClientRects().length > 0 && getComputedStyle(chip).visibility !== "hidden";
  return {
    chip: chip ? chip.innerText.trim() : null,
    shown,
    classes: ["not_run_yet", "stale", "no_output_yet"].filter((c) => cell?.classList.contains(c)),
  };
}, id);

test("the first cell shows the same chip on load as an identical cell further down", async (t) => {
  const notebook = tempNotebook("first-cell.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "first-cell.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "RUN");
  await page.waitForFunction(() => document.querySelectorAll("pluto-cell.running, pluto-cell.queued").length === 0
    && document.getElementById("RUN")?.classList.contains("no_output_yet") === false, null, { timeout: 60000 });

  for (const width of [1200, 600]) {
    await page.setViewportSize({ width, height: 800 });
    await page.reload();
    await page.waitForFunction(() => !document.querySelector("pluto-editor")?.classList.contains("loading"),
      null, { timeout: 30000 });
    const samples = [];
    for (const wait of [0, 50, 150, 300, 600, 1500]) {
      await page.waitForTimeout(wait);
      samples.push([wait, await look(page, "FIRST"), await look(page, "LATER")]);
    }
    for (const [wait, first, later] of samples) {
      assert.deepEqual(first, later, `at ${width} px, ${wait} ms into the load, FIRST and LATER differ`);
    }
    const [, settled] = samples.at(-1);
    assert.deepEqual(settled, { chip: "Not run yet", shown: true, classes: ["not_run_yet", "no_output_yet"] },
      `at ${width} px the unrun cells show "Not run yet" once the load settles`);
  }

  assertNoProblems(page);
});

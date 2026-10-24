// #284: the first cell is like any other. FIRST and LATER hold the same
// code and neither has run, so on load they show the same chip, at every
// moment of the load, not only once it has settled. Running RUN allows
// execution without running them, and a reload is the "on load" part.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, afterSettle } from "../browser.mjs";

test("the first cell shows the same chip on load as an identical cell further down", async (t) => {
  const notebook = tempNotebook("first-cell.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "first-cell.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // What each cell shows, in every frame of a load asked for below.
  await page.addInitScript(() => {
    window.__look = (id) => {
      const cell = document.getElementById(id);
      const chip = cell?.querySelector(":scope > ember-chip");
      const shown = chip != null && chip.getClientRects().length > 0 && getComputedStyle(chip).visibility !== "hidden";
      return {
        chip: chip ? chip.innerText.trim() : null,
        shown,
        classes: ["not_run_yet", "stale", "no_output_yet"].filter((c) => cell?.classList.contains(c)),
      };
    };
    if (sessionStorage.getItem("record_looks") !== "1") return;
    window.__looks = [];
    window.__stop_looks = false;
    const tick = () => {
      if (window.__stop_looks) return;
      if (document.getElementById("FIRST") && document.getElementById("LATER")) {
        window.__looks.push([performance.now(), window.__look("FIRST"), window.__look("LATER")]);
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "RUN");
  await page.waitForFunction(() => document.querySelectorAll("pluto-cell.running, pluto-cell.queued").length === 0
    && document.getElementById("RUN")?.classList.contains("no_output_yet") === false);

  for (const width of [1200, 600]) {
    await page.setViewportSize({ width, height: 800 });
    // Every frame of the load, from the first that has both cells, until
    // the page has settled: LATER, the cell any other is like, shows its
    // chip, and any passing state held back from before then has shown.
    await page.evaluate(() => sessionStorage.setItem("record_looks", "1"));
    await page.reload();
    await page.waitForFunction(() => !document.querySelector("pluto-editor")?.classList.contains("loading"));
    await page.waitForFunction(() => window.__look("LATER").shown);
    await afterSettle(page);
    const samples = await page.evaluate(() => { window.__stop_looks = true; return window.__looks; });
    assert.ok(samples.length > 0, "frames were recorded during the load");
    for (const [at, first, later] of samples) {
      assert.deepEqual(first, later, `at ${width} px, ${Math.round(at)} ms into the load, FIRST and LATER differ`);
    }
    const [, settled] = samples.at(-1);
    assert.deepEqual(settled, { chip: "Not run yet", shown: true, classes: ["not_run_yet", "no_output_yet"] },
      `at ${width} px the unrun cells show "Not run yet" once the load settles`);
  }

  assertNoProblems(page);
});

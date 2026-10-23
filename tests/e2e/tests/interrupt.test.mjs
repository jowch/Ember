// Scenario 40 (docs/ui-tests.md): a long-running cell loses `.running`
// after clicking the stop button, stopped rather than run to its end.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, openNotebook, setCellCode, cellSelector } from "../browser.mjs";

test("interrupt: a long-running cell is stopped by clicking stop", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "interrupt.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // A loop far longer than any runner takes to stop it. Stop is clicked
  // once the run is R's (`running`, not `queued`): an interrupt then waits
  // for the worker to begin the run, while one clicked while the cell is
  // still queued, as R starts, takes it off the queue. The cell's own text
  // can't tell the two apart: its code is in it, and what it prints doesn't
  // show until the run ends (#470, #477).
  await setCellCode(page, "LOOP", "t0 <- Sys.time(); while (Sys.time() - t0 < 60) NULL");
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction(() => window.editor_state?.notebook?.cell_results?.LOOP?.running === true, null, { timeout: 0 });

  await page.locator(`${cellSelector("LOOP")} button.ember-run.busy`).click();
  await page.waitForSelector(`${cellSelector("LOOP")}:not(.running)`, { timeout: 0 });
  assert.match(await page.locator(`${cellSelector("LOOP")} > pluto-output`).innerText(), /Interrupted/, "the loop was stopped, not run to its end");
});

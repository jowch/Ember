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

  // A loop far longer than any runner takes to stop it, that says once R
  // is inside it: an interrupt that comes before the run has started is
  // dropped, as one between runs is (test-worker.R).
  // message(), not cat(): the worker sends a message to the page at once,
  // while printed text waits for the next message or the run's end.
  await setCellCode(page, "LOOP", 'message("inside the loop"); t0 <- Sys.time(); while (Sys.time() - t0 < 60) NULL');
  await page.keyboard.press("Shift+Enter");
  // In the cell's console, not anywhere in the cell: its code says it too,
  // and a click while the run is still queued only cancels it.
  await page.waitForFunction((sel) => document.querySelector(`${sel}.running pluto-logs`)?.innerText.includes("inside the loop"), cellSelector("LOOP"));

  await page.locator(`${cellSelector("LOOP")} button.ember-run.busy`).click();
  await page.waitForSelector(`${cellSelector("LOOP")}:not(.running)`);
  assert.match(await page.locator(`${cellSelector("LOOP")} > pluto-output`).innerText(), /Interrupted/, "the loop was stopped, not run to its end");
});

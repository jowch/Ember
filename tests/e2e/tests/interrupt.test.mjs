// Scenario 40 (docs/ui-tests.md): a long-running cell loses `.running`
// shortly after clicking the stop button.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, openNotebook, runCell, cellSelector } from "../browser.mjs";

test("interrupt: a long-running cell is stopped shortly after clicking stop", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "interrupt.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "LOOP");
  await page.waitForSelector(`${cellSelector("LOOP")}.running`, { timeout: 15000 });
  await page.waitForTimeout(500);   // give it a moment to be truly inside the loop

  const t0 = Date.now();
  await page.locator(`${cellSelector("LOOP")} pluto-runarea.interrupt button.runcell`).click();
  await page.waitForSelector(`${cellSelector("LOOP")}:not(.running)`, { timeout: 15000 });
  const elapsed = Date.now() - t0;
  assert.ok(elapsed < 10000, `interrupted within 10s (was ${elapsed}ms)`);
});

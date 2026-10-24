// Scenario 48 (docs/ui-tests.md): what a running cell prints shows while it
// runs, and a progress bar redrawn with "\r" moves in place (#470, #483).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { writeFileSync } from "node:fs";
import { startServer, tempNotebook, tempDir, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, openNotebook, setCellCode, cellSelector } from "../browser.mjs";

test("console: a progress bar redrawn with \\r moves while the cell runs", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "console-live.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // Each drawing waits for a file the test writes once the page shows it,
  // so the cell is still running at every check. R reads the path with
  // forward slashes on Windows too.
  const dir = tempDir("ember-e2e-go-").replaceAll("\\", "/");
  const go = (i) => `${dir}/go${i}`;
  await setCellCode(page, "LOOP", `for (i in 1:3) { cat("\\rstep", i); while (!file.exists(sprintf("${dir}/go%d", i))) NULL }; cat("\\n")`);
  await page.keyboard.press("Shift+Enter");

  // In the running cell's console, not anywhere in the cell: its code says
  // "step" too.
  const logs = (sel) => document.querySelector(`${sel}.running pluto-logs`)?.innerText ?? "";
  for (const i of [1, 2, 3]) {
    await page.waitForFunction(([sel, want]) => (document.querySelector(`${sel}.running pluto-logs`)?.innerText ?? "").includes(want), [cellSelector("LOOP"), `step ${i}`]);
    // Redrawn in place: the drawing before it is gone.
    const text = await page.evaluate(logs, cellSelector("LOOP"));
    assert.equal((text.match(/step/g) ?? []).length, 1, `one drawing at step ${i}: ${JSON.stringify(text)}`);
    writeFileSync(go(i), "");
  }

  await page.waitForSelector(`${cellSelector("LOOP")}:not(.running)`);
  const final = await page.locator(`${cellSelector("LOOP")} pluto-logs`).innerText();
  assert.equal(final.trim(), "step 3");
});

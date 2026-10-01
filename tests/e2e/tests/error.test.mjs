// Scenario 43 (docs/ui-tests.md): a cell that throws shows the error
// element with its message.

import { test } from "node:test";
import path from "node:path";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, openNotebook, runCell, cellSelector } from "../browser.mjs";

test("error: stop('boom') shows the error element with its message", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "error.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "ERR");
  await page.waitForSelector(`${cellSelector("ERR")} jlerror`, { timeout: 20000 });
  const text = await page.locator(`${cellSelector("ERR")} jlerror`).innerText();
  assert.match(text, /boom/);
});

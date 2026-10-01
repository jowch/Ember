// docs/ui.md, "Decisions": "Run notebook code" in the safe-preview banner
// allows execution and runs every cell, as the button says.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, openNotebook, cellSelector } from "../browser.mjs";

test('safe preview: "run this notebook" allows execution and runs every cell', async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "safe-preview.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator(".safe-preview button").click();
  await page.getByText("run this notebook", { exact: false }).click();

  // B (sum(x)) and ERR (stop("boom")) both ran, which only happens once
  // execution is allowed and "run every cell" actually reached them.
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output", { timeout: 30000 });
  await page.waitForSelector(`${cellSelector("ERR")} jlerror`, { timeout: 30000 });

  assert.equal(await page.locator(".safe-preview-info").count(), 0, "the banner is gone once execution is allowed");
});

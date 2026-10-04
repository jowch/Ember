// Piece 5 ("Identity and layout"), docs/ui-3-plan.md's "Safe preview
// banner". docs/ui-3-tests.md 120 (replaces safe-preview.test.mjs's
// ".safe-preview button" and ".safe-preview-info" steps): one banner,
// "Run this notebook" starts R and runs every cell, no cell says
// "not executed" any more.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

test('safe preview: "Run this notebook" allows execution and runs every cell (120)', async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "safe-preview.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const banner = page.locator("#ember-safe-preview");
  await banner.waitFor({ state: "visible" });
  assert.match(await banner.innerText(), /Safe preview/);
  const run_button = banner.locator("button");
  assert.equal(await run_button.innerText(), "Run this notebook");

  const body_before = await page.locator("body").innerText();
  assert.doesNotMatch(body_before, /not executed/);

  await run_button.click();

  // B (sum(x)) and ERR (stop("boom")) both ran, which only happens once
  // execution is allowed and "run every cell" actually reached them.
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output", { timeout: 30000 });
  await page.waitForSelector(`${cellSelector("ERR")} jlerror`, { timeout: 30000 });

  assert.equal(await banner.count(), 0, "the banner is gone once execution is allowed");
  const body_after = await page.locator("body").innerText();
  assert.doesNotMatch(body_after, /not executed/);

  // The run it started is announced once it ends; ERR is the cell that fails.
  await page.waitForFunction(() => document.querySelector("#ember-run-status").textContent === "A cell: error", null, { timeout: 30000 });
  assertNoProblems(page);
});

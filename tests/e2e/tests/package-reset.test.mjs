// #61: a package that resets one of its own options when it loads. mgcv
// sets mgcv.vc.logrange in .onLoad, so a settings cell's value is lost
// under Rscript, where settings cells come first in the file. The notebook
// keeps the user's value for the cells after the load, and the loading
// cell says so and how to make the script agree.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

// mgcv is locked like any CRAN package, so the notebook's library has to be
// installed first: gated the same way as packages.R's scenario.
test("a package that resets a settings cell's option leaves a note on the cell that loads it (#61)", {
  skip: !process.env.EMBER_E2E_INSTALLS && "set EMBER_E2E_INSTALLS=1 (needs network to resolve the lock)",
  timeout: 150000,
}, async (t) => {
  const notebook = tempNotebook("package-reset.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "package-reset.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();

  const note = `${cellSelector("LOAD")} ember-settings-note.load-note`;
  await page.waitForSelector(note, { timeout: 120000 });
  assert.equal(await page.locator(note).innerText(),
    "Loading mgcv resets mgcv.vc.logrange, which a settings cell sets. Under Rscript the setting is lost, " +
    "because settings cells come first in the file. Set it in this cell, after mgcv loads.");
  assert.equal(await page.locator(`${cellSelector("S")} ember-settings-note`).count(), 0, "no note on the settings cell");

  // The cell after the load still sees the settings cell's value.
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("50"),
    `${cellSelector("AFTER")} pluto-output`, { timeout: 20000 });
  assert.equal(await page.locator(`${cellSelector("AFTER")} ember-settings-note`).count(), 0, "no note on the later cell");

  assertNoProblems(page);
});

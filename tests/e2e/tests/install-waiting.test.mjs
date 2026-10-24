// #590: a queued cell that waits for a package install says so in the
// cell, with how long the install has run, and the name opens the
// Packages tab. Before this the cell showed only the queued rail, so a
// slow install looked like a hung cell.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SLOW_INSTALLER = path.join(HERE, "..", "..", "testthat", "fixtures", "slow-installer.R");

test("install waiting: the cell says what it waits for and how long the install has run; the name opens Packages (#590)", async (t) => {
  const notebook = tempNotebook("failing.R");
  const server = await startServer([notebook], {
    installerScript: SLOW_INSTALLER,
    logFile: path.join(artifactsDir(), "install-waiting.server.log"),
  });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "S");

  const chip = page.locator(`${cellSelector("S")} > ember-chip.waiting`);
  await chip.waitFor();
  const time = chip.locator(".ember-chip-time");
  await time.waitFor();
  assert.match(await chip.innerText(), /^Waiting for brokenpkg to install · \d+:\d\d$/);
  // The clock is left out of the status region, so it isn't read out each second.
  assert.equal(await time.getAttribute("aria-hidden"), "true");

  // It ticks on its own: the cell gets no new state while the install runs.
  const first = await time.innerText();
  await page.waitForFunction(([sel, before]) => document.querySelector(sel)?.textContent !== before,
    [`${cellSelector("S")} > ember-chip.waiting .ember-chip-time`, first]);

  await chip.getByRole("link", { name: "brokenpkg", exact: true }).click();
  await page.locator("tr.ember-package-row.ember-package-installing").waitFor();

  assertNoProblems(page);
});

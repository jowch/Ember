// Piece 5 (docs/ui-2.md, "Status views"), docs/ui-2-tests.md items 71-75:
// worker memory in the header, the "N cells not run" bar and "Run all",
// stale labels, the Packages tab, and Endeavor's Pluto-shaped fields
// staying filled.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector } from "../browser.mjs";

// 70. Worker memory: null in safe preview, a number after the first run.
// (ui-3-plan.md piece 5 moves its display into the Status tab and the
// Variables footer, test 117/121; this test covers the data, which both
// of those read from `notebook.ember.worker_memory`.)
test("header: worker memory shows after the first run, nothing in safe preview (71)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-70.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  assert.equal(await page.evaluate(() => window.editor_state?.notebook?.ember?.worker_memory ?? null), null, "nothing in safe preview");

  await runCell(page, "A");
  await page.waitForFunction(
    () => typeof window.editor_state?.notebook?.ember?.worker_memory === "number",
    null, { timeout: 30000 });

  assertNoProblems(page);
});

// 71. "N cells not run" bar; restart resets it; "Run all" clears it.
test('"N cells not run" bar counts, grows after a restart, and "Run all" clears it (72)', async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-71.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "B"); // also runs A, its ancestor
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output", { timeout: 30000 });

  // Restart from the Status tab's Restart R button: every cell, including
  // A and B, is not run again.
  await page.locator("#ember-r-status").click();
  await page.waitForSelector("#ember-status-restart");
  await page.locator("#ember-status-restart").click();
  await page.waitForFunction(
    () => document.querySelector("header#pluto-nav button.ember-btn")?.innerText.includes("4 not run"),
    null, { timeout: 30000 });

  await page.locator("header#pluto-nav button.ember-btn").click();
  await page.waitForFunction(
    () => document.querySelector("header#pluto-nav button.ember-btn") == null,
    null, { timeout: 30000 });

  assertNoProblems(page);
});

// 72. Stale label on an edited ancestor's dependent, lazy mode.
test('lazy.R: editing A shows B as "stale", running B clears it (73)', async (t) => {
  const notebook = tempNotebook("lazy.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-72.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 30000 });

  await setCellCode(page, "A", "x <- 2");
  await runCell(page, "A");

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText === "Stale · x changed",
    cellSelector("B") + " > ember-chip", { timeout: 30000 });
  assert.equal(await page.locator(`${cellSelector("B")} ember-cell-label`).count(), 0);

  await runCell(page, "B");
  await page.waitForFunction(
    (sel) => document.querySelector(sel) == null,
    cellSelector("B") + " > ember-chip", { timeout: 30000 });

  assertNoProblems(page);
});

// 73. Packages tab in safe preview. Resolving the lock needs CRAN's index
// (network), as `widget.R`'s install scenario does (ui-2-tests.md's new
// fixtures note); gated the same way.
test("Packages tab lists a missing package and the preview banner names the install (74)", {
  skip: !process.env.EMBER_E2E_INSTALLS && "set EMBER_E2E_INSTALLS=1 (needs network to resolve the lock)",
}, async (t) => {
  const notebook = tempNotebook("packages.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-73.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // Read the banner's plan sentence before running anything: clicking
  // "Run this notebook" starts execution immediately, and the banner (and
  // its sentence) is gone once process_waiting_for_permission is false.
  await page.waitForFunction(
    () => /installs \d+ packages?/.test(document.querySelector("#ember-safe-preview")?.innerText ?? ""),
    null, { timeout: 10000 });
  const bannerText = await page.locator("#ember-safe-preview").innerText();
  assert.match(bannerText, /installs \d+ packages?/);

  // The "missing" status, in safe preview, before anything installs.
  await page.getByRole("button", { name: "Packages", exact: true }).click();
  await page.waitForSelector("#ember-packages-tab .ember-packages-table", { timeout: 10000 });
  const rows = await page.locator("#ember-packages-tab .ember-package-row").count();
  assert.ok(rows > 0, "expected at least one package row");
  const statuses = await page.locator("#ember-packages-tab .ember-package-row td:last-child").allInnerTexts();
  assert.ok(statuses.some((s) => s.includes("missing")));

  // Close the panel first: open, it covers the banner's own button.
  await page.getByRole("button", { name: "Packages", exact: true }).click();
  await page.waitForSelector("#helpbox-wrapper:not(.open)", { state: "attached" });
  await page.locator("#ember-safe-preview button").click();

  assertNoProblems(page);
});

// 75. The Pluto-shaped fields the page still reads survive; status_tree, which nothing reads, is gone.
test("nbpkg and process_status stay filled; status_tree is gone (75)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-74.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const fields = await page.evaluate(() => {
    const nb = window.editor_state?.notebook;
    return { nbpkg: nb?.nbpkg, status_tree: nb?.status_tree, process_status: nb?.process_status };
  });
  assert.ok(fields.nbpkg != null, "nbpkg is present");
  assert.equal(fields.status_tree, undefined, "status_tree is not projected");
  assert.equal(typeof fields.process_status, "string");

  assertNoProblems(page);
});

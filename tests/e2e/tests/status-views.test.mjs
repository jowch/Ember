// Piece 5 (docs/ui-2.md, "Status views"), docs/ui-2-tests.md items 70-74:
// worker memory in the header, the "N cells not run" bar and "Run all",
// stale labels, the Packages tab, and Endeavor's Pluto-shaped fields
// staying filled.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector } from "../browser.mjs";

// 70. Header memory, nothing in safe preview.
test("header: worker memory shows after the first run, nothing in safe preview (70)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-70.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  assert.equal(await page.locator("#ember-status").count(), 0, "nothing shown in safe preview");

  await runCell(page, "A");
  await page.waitForSelector("#ember-status", { timeout: 30000 });
  await page.waitForFunction(
    () => /R · \d+ MB/.test(document.querySelector("#ember-status")?.innerText ?? ""),
    null, { timeout: 30000 });

  assertNoProblems(page);
});

// 71. "N cells not run" bar; restart resets it; "Run all" clears it.
test('"N cells not run" bar counts, grows after a restart, and "Run all" clears it (71)', async (t) => {
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

  // Restart from the header's memory display: every cell, including A and
  // B, is not run again.
  await page.waitForSelector("#ember-status-restart", { timeout: 30000 });
  page.on("dialog", (d) => d.accept());
  await page.locator("#ember-status-restart").click();
  await page.waitForFunction(
    () => document.querySelector("#ember-not-run-bar")?.innerText.includes("4 cells not run"),
    null, { timeout: 30000 });

  await page.locator("#ember-not-run-bar button").click();
  await page.waitForFunction(
    () => document.querySelector("#ember-not-run-bar") == null,
    null, { timeout: 30000 });

  assertNoProblems(page);
});

// 72. Stale label on an edited ancestor's dependent, lazy mode.
test('lazy.R: editing A shows B as "stale", running B clears it (72)', async (t) => {
  const notebook = tempNotebook("lazy.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-72.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator(".safe-preview button").click();
  await page.getByText("run this notebook", { exact: false }).click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 30000 });

  await setCellCode(page, "A", "x <- 2");
  await runCell(page, "A");

  await page.waitForSelector(`${cellSelector("B")}.stale ember-cell-label`, { timeout: 30000 });
  const label = await page.locator(`${cellSelector("B")} ember-cell-label`).innerText();
  assert.match(label, /stale/);

  await runCell(page, "B");
  await page.waitForFunction(
    (sel) => !document.querySelector(sel)?.classList.contains("stale"),
    cellSelector("B"), { timeout: 30000 });

  assertNoProblems(page);
});

// 73. Packages tab in safe preview. Resolving the lock needs CRAN's index
// (network), as `widget.R`'s install scenario does (ui-2-tests.md's new
// fixtures note); gated the same way.
test("Packages tab lists a missing package and the preview banner names the install (73)", {
  skip: !process.env.EMBER_E2E_INSTALLS && "set EMBER_E2E_INSTALLS=1 (needs network to resolve the lock)",
}, async (t) => {
  const notebook = tempNotebook("packages.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "status-73.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator(".safe-preview button").click();
  await page.waitForFunction(
    () => /installs \d+ packages?/.test(document.querySelector(".safe-preview-info")?.innerText ?? document.body.innerText),
    null, { timeout: 10000 }).catch(() => {});
  const bannerText = await page.locator("body").innerText();
  assert.match(bannerText, /installs \d+ packages?/);
  await page.keyboard.press("Escape");

  await page.getByTitle(/Packages/).click();
  await page.waitForSelector("#ember-packages-tab .ember-packages-table", { timeout: 10000 });
  const rows = await page.locator("#ember-packages-tab .ember-package-row").count();
  assert.ok(rows > 0, "expected at least one package row");
  const statuses = await page.locator("#ember-packages-tab .ember-package-row td:last-child").allInnerTexts();
  assert.ok(statuses.some((s) => s.includes("missing")));

  assertNoProblems(page);
});

// 74. Endeavor's Pluto-shaped fields survive.
test("Endeavor's nbpkg, status_tree and process_status stay filled (74)", async (t) => {
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
  assert.ok(fields.status_tree != null, "status_tree is present");
  assert.equal(typeof fields.process_status, "string");

  assertNoProblems(page);
});

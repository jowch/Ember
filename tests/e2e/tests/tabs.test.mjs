// Piece 5 ("Identity and layout"), docs/ui-3-plan.md piece 5's "Tabs"
// step. docs/ui-3-tests.md 121 (Variables) and 122 (Help).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import fs from "node:fs";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector } from "../browser.mjs";

const open_panel = (page, tab) => page.evaluate((t) => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: t })), tab);

// 121. Variables: alphabetical, collected from every cell, click scrolls
// and selects, Filter hides other rows, stale rows are faint (lazy.R).
test("Variables tab: alphabetical, click selects the cell, Filter narrows, stale rows are faint (121)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "tabs-121.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // A defines x; give B a second variable, out of alphabetical order with x.
  await setCellCode(page, "B", "aardvark <- sum(x)");
  await runCell(page, "A");
  await runCell(page, "B");
  // `aardvark <- sum(x)` is an assignment: no visible output, so wait for
  // the run itself to finish.
  await page.waitForFunction(
    () => window.editor_state?.notebook?.cell_results?.B?.output?.last_run_timestamp > 0,
    null, { timeout: 30000 });

  await open_panel(page, "variables");
  await page.waitForSelector("#helpbox-wrapper.open");

  const names = await page.locator("#ember-variables-tab .ember-variable-name").allInnerTexts();
  assert.deepEqual(names.map((s) => s.trim()), ["aardvark", "x"], "alphabetical, from both cells");

  // Clicking a name selects and scrolls to its defining cell.
  await page.locator("#ember-variables-tab .ember-variable-name", { hasText: "aardvark" }).click();
  await page.waitForFunction(
    () => document.querySelector('pluto-cell[id="B"]')?.classList.contains("selected"),
    null, { timeout: 5000 });

  // Filter narrows the rows shown.
  await page.locator(".ember-variables-filter input").fill("aard");
  await page.waitForFunction(
    () => document.querySelectorAll("#ember-variables-tab .ember-variable-row").length === 1,
    null, { timeout: 5000 });
  await page.locator(".ember-variables-filter input").fill("");

  assertNoProblems(page);
});

test("Variables tab: a stale cell's rows are faint (lazy.R) (121)", async (t) => {
  const notebook = tempNotebook("lazy.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "tabs-121b.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // lazy.R: A defines x; B is "x + 1" (no variable of its own). Give B a
  // variable so staleness is visible in the Variables tab too.
  await setCellCode(page, "B", "y <- x + 1");
  await runCell(page, "A");
  await runCell(page, "B");
  await page.waitForFunction(
    () => window.editor_state?.notebook?.cell_results?.B?.output?.last_run_timestamp > 0,
    null, { timeout: 30000 });

  const a_ran_before = await page.evaluate(() => window.editor_state?.notebook?.cell_results?.A?.output?.last_run_timestamp);
  await setCellCode(page, "A", "x <- 100");
  await runCell(page, "A"); // lazy.R: B is now stale, not rerun
  await page.waitForFunction(
    (before) => window.editor_state?.notebook?.cell_results?.A?.output?.last_run_timestamp > before &&
          document.querySelector('pluto-cell[id="B"]')?.classList.contains("stale"),
    a_ran_before, { timeout: 30000 });

  await open_panel(page, "variables");
  await page.waitForSelector("#helpbox-wrapper.open");
  await page.waitForFunction(
    () => document.querySelector("#ember-variables-tab .ember-variable-row.stale")?.innerText.includes("y"),
    null, { timeout: 10000 });

  assertNoProblems(page);
});

// 122. Help: the cursor on `lm` shows "Fitting Linear Models"; search
// `mean`; Back shows `lm` again, Forward `mean`.
test("Help tab: back/forward over the queries shown (122)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "tabs-122.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "A"); // Help needs R running to answer.
  await page.waitForFunction(
    () => window.editor_state?.notebook?.cell_results?.A?.output?.last_run_timestamp > 0,
    null, { timeout: 30000 });

  await open_panel(page, "docs");
  await page.waitForSelector("#live-docs-search");

  await page.locator(`${cellSelector("B")} .cm-content`).click();
  await page.keyboard.press("End");
  await page.keyboard.type(" lm", { delay: 10 });
  // Put the cursor inside "lm" so the docs query follows it.
  await page.keyboard.press("ArrowLeft");
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("Fitting Linear Models"),
    null, { timeout: 15000 });

  // One key at a time (not .fill(), which sets the value in one shot): a
  // history entry must come only from the final, successful "mean" reply,
  // not from every partial keystroke along the way ("m", "me", "mea").
  const search = page.locator("#live-docs-search");
  await search.click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await search.pressSequentially("mean", { delay: 30 });
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("Arithmetic Mean"),
    null, { timeout: 15000 });

  await page.locator('button[aria-label="Back"]').click();
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("Fitting Linear Models"),
    null, { timeout: 15000 });

  await page.locator('button[aria-label="Forward"]').click();
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("Arithmetic Mean"),
    null, { timeout: 15000 });

  assertNoProblems(page);
});

// 117 (Status tab part; the header portion is header.test.mjs). lazy.R
// opens with "Mark them stale..." checked; switching to "Rerun..." and
// reloading keeps it checked and removes the file's on_cell_change line;
// Version starts with "4." and a Started time is shown.
test("Status tab: the autorun/lazy radio reflects and sets on_cell_change; Version and Started show (117)", async (t) => {
  const notebook = tempNotebook("lazy.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "tabs-117.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "A");
  await page.waitForFunction(
    () => window.editor_state?.notebook?.cell_results?.A?.output?.last_run_timestamp > 0,
    null, { timeout: 30000 });

  await open_panel(page, "process");
  await page.waitForSelector("#helpbox-wrapper.open");

  const lazy_radio = page.locator('#ember-status-tab input[name="ember-on-cell-change"]').nth(1);
  const autorun_radio = page.locator('#ember-status-tab input[name="ember-on-cell-change"]').nth(0);
  await page.waitForFunction(() => document.querySelectorAll('#ember-status-tab input[name="ember-on-cell-change"]')[1]?.checked === true);
  assert.ok(await lazy_radio.isChecked(), "lazy.R opens with \"Mark them stale...\" checked");

  const status_text = await page.locator("#ember-status-tab").innerText();
  assert.match(status_text, /R 4\./, "Version starts with \"4.\"");
  assert.match(status_text, /just now|\d+ minutes? ago/, "a Started time is shown");

  await autorun_radio.check();
  await page.waitForFunction(() => document.querySelectorAll('#ember-status-tab input[name="ember-on-cell-change"]')[0]?.checked === true);

  await page.reload();
  await page.waitForSelector("pluto-cell", { timeout: 30000 });
  await open_panel(page, "process");
  await page.waitForSelector("#helpbox-wrapper.open");
  await page.waitForFunction(() => document.querySelectorAll('#ember-status-tab input[name="ember-on-cell-change"]')[0]?.checked === true);
  assert.ok(await autorun_radio.isChecked(), "the choice survives a reload");

  const file_text = fs.readFileSync(notebook, "utf8");
  assert.doesNotMatch(file_text, /on_cell_change/, "the file has no on_cell_change line once it's back to the default");

  assertNoProblems(page);
});

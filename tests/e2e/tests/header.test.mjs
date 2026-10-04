// Piece 5 ("Identity and layout"), docs/ui-3-plan.md's "Header contents"
// (ui-3-plan.md piece 5 step 6). docs/ui-3-tests.md 117 (header portion;
// the Status tab's own content is step 8's, status-views.test.mjs and
// docstring-adjacent tests), 118, 119, 126.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

// 117 (header portion). "R ready" after the first run; clicking it opens
// the panel at Status.
test("header: R status reads \"R ready\" after a run and opens Status (117)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "header-117.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "A");
  await page.waitForFunction(
    () => document.querySelector("#ember-r-status .ember-r-status-words")?.innerText === "R ready",
    null, { timeout: 30000 });

  await page.locator("#ember-r-status").click();
  await page.waitForSelector("#helpbox-wrapper.open");
  assert.equal(await page.locator('[role="tab"][aria-selected="true"]').innerText(), "Status");

  assertNoProblems(page);
});

// 118. While busy: "Running i of n cells" and Stop; Stop ends the run.
test("header: busy shows \"Running N of N cells\" and Stop, which ends the run (118)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "header-118.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "LOOP");
  await page.waitForSelector(`${cellSelector("LOOP")}.running`, { timeout: 15000 });
  await page.waitForFunction(
    () => /Running \d+ of \d+ cells/.test(document.querySelector("#ember-r-status .ember-r-status-words")?.innerText ?? ""),
    null, { timeout: 15000 });

  await page.locator('header#pluto-nav button.ember-btn').filter({ hasText: "Stop" }).click();
  await page.waitForSelector(`${cellSelector("LOOP")}:not(.running)`, { timeout: 15000 });
  await page.waitForFunction(
    () => document.querySelector("#ember-r-status .ember-r-status-words")?.innerText === "R ready",
    null, { timeout: 15000 });

  assertNoProblems(page);
});

// 119. "Run N not run" (replaces ui-2-tests.md 72): after a restart, the
// header button reads "Run 4 not run"; clicking it runs them and the
// button disappears.
test('header: "Run N not run" counts, and clicking it clears it (119)', async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "header-119.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "A");
  await page.waitForFunction(
    () => document.querySelector("#ember-r-status .ember-r-status-words")?.innerText === "R ready",
    null, { timeout: 30000 });

  // Restart from the Status tab, where the plan puts it.
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
  assert.equal(await page.locator("#ember-not-run-bar").count(), 0, "no separate bar above the notebook");

  assertNoProblems(page);
});

// 126. The ⋯ menu by keyboard: focus ⋯, Enter opens it with focus on
// "Keyboard shortcuts"; ↓ moves to "Settings"; Esc closes it and focus is
// back on ⋯.
test("header: the ⋯ menu opens, navigates and closes by keyboard (126)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "header-126.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const more = page.locator('header#pluto-nav button[aria-label="More"]');
  await more.focus();
  await page.keyboard.press("Enter");
  await page.waitForSelector('.ember-menu[role="menu"]');
  await page.waitForFunction(() => document.activeElement?.getAttribute("role") === "menuitem");
  assert.equal(await page.evaluate(() => document.activeElement?.textContent.trim()), "Keyboard shortcuts");

  await page.keyboard.press("ArrowDown");
  await page.waitForFunction(() => document.activeElement?.textContent.trim() === "Settings");
  assert.equal(await page.evaluate(() => document.activeElement?.textContent.trim()), "Settings");

  await page.keyboard.press("Escape");
  await page.waitForSelector('.ember-menu[role="menu"]', { state: "detached" });
  assert.ok(await more.evaluate((el) => el === document.activeElement), "focus returns to ⋯");

  assertNoProblems(page);
});

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

// Header geometry: at 1440px the right-hand group (R status, the panel
// icons, Export, ⋯) sits against the right edge, not packed left next to
// the file name (a regression once "Saved" and "Run N not run" are both
// absent/hidden, since nothing else pushed the group right).
test("header: the right-hand group is pushed to the right edge at 1440px", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "header-geometry.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 1440, height: 900 });
  await openNotebook(page, server.origin, server.secret, notebook);

  const nav = await page.locator("nav#at_the_top").boundingBox();
  const more = await page.locator('header#pluto-nav button[aria-label="More"]').boundingBox();
  assert.ok(nav.x + nav.width - (more.x + more.width) < 24, "the ⋯ button sits near the right edge of the header");

  assertNoProblems(page);
});

// The R status button's accessible name is the state words themselves
// ("R ready"), not a generic "Open Status" -- matching its title, and the
// same at every width, including the phone dot-only layout.
test("header: the R status button's accessible name is the state words, at every width", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "header-r-status-name.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 1440, height: 900 });
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.waitForFunction(
    () => document.querySelector("#ember-r-status .ember-r-status-words")?.innerText === "R not started",
    null, { timeout: 15000 });

  const wide_button = page.locator("#ember-r-status");
  assert.equal(await wide_button.getAttribute("aria-label"), "R not started");
  assert.equal(await wide_button.getAttribute("title"), "R not started");

  await page.setViewportSize({ width: 390, height: 844 });
  const phone_button = page.locator("#ember-r-status");
  assert.equal(await phone_button.getAttribute("aria-label"), "R not started");
  assert.equal(await phone_button.getAttribute("title"), "R not started");

  assertNoProblems(page);
});

test("header: the flame goes back to the start page, which lists the open notebook", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "header-flame.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const [resp] = await Promise.all([
    page.waitForNavigation(),
    page.locator("nav#at_the_top > a").first().click(),
  ]);
  assert.equal(resp.status(), 200, "the start page accepts the flame's link");
  await page.locator(".ember-start-row").first().waitFor({ state: "visible", timeout: 10000 });
  assert.ok(await page.locator('a[href*="edit?id="]').count() > 0, "the open notebook is listed");

  assertNoProblems(page);
});

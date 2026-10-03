// Piece 5 ("Identity and layout"), docs/ui-3-plan.md's "Layout" and "Side
// panel": the 720 px column, the sticky header shell, and the panel's three
// responsive modes. docs/ui-3-tests.md 110-114.
//
// 111-113 open the panel with `open_bottom_right_panel()` directly (the
// same event Endeavor's drawer and, from piece 5's "Header contents" step
// on, the header's own icons send) rather than clicking a header icon:
// this step builds the panel's frame, not the header buttons that will
// normally open it.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

// 110. The column at a wide (1440 x 900) viewport; the header's own shell.
test("layout: the 720px column and sticky header at 1440x900 (110)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "layout-110.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 1440, height: 900 });
  await openNotebook(page, server.origin, server.secret, notebook);

  const main = await page.locator("main").boundingBox();
  assert.ok(main, "expected a main box");
  assert.ok(Math.abs(main.x - 120) <= 1, `expected main.x ~= 120, got ${main.x}`);
  assert.ok(Math.abs(main.width - (720 + 31)) <= 1, `expected main.width ~= 751, got ${main.width}`);

  const header = page.locator("header#pluto-nav");
  const before = await header.boundingBox();
  assert.ok(Math.abs(before.height - 52) <= 1, `expected header height ~= 52, got ${before.height}`);
  assert.ok(Math.abs(before.y - 0) <= 1, `expected header.y ~= 0 before scroll, got ${before.y}`);

  await page.evaluate(() => window.scrollTo(0, 1000));
  await page.waitForTimeout(100);
  const after = await header.boundingBox();
  assert.ok(Math.abs(after.y - 0) <= 1, `expected header.y ~= 0 after scrolling 1000px, got ${after.y}`);

  assertNoProblems(page);
});

// 114. No horizontal scroll at 640 x 800 (the mobile column breakpoint;
// side-panel-open isn't exercised here since piece 5's side panel frame,
// which this piece doesn't yet build, is what the panel-open half of this
// scenario needs).
test("layout: no horizontal scroll at 640x800 (114)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "layout-114.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 640, height: 800 });
  await openNotebook(page, server.origin, server.secret, notebook);

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  assert.ok(overflow <= 1, `expected no horizontal scroll, got ${overflow}px of overflow`);

  assertNoProblems(page);
});

const open_panel = (page, tab) => page.evaluate((t) => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: t })), tab);

// 111. Docked (>= 1240px): the panel sits in the free space; main doesn't move.
test("layout: the side panel docks at 1440x900 without moving main (111)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "layout-111.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 1440, height: 900 });
  await openNotebook(page, server.origin, server.secret, notebook);

  const main_before = await page.locator("main").boundingBox();

  await open_panel(page, "variables");
  await page.waitForSelector("#helpbox-wrapper.open");
  const panel = await page.locator("#helpbox-wrapper").boundingBox();
  assert.ok(Math.abs(panel.width - 400) <= 1, `expected panel width ~= 400, got ${panel.width}`);
  assert.ok(Math.abs(panel.x + panel.width - 1440) <= 1, `expected panel at the right edge, got x=${panel.x} width=${panel.width}`);

  const main_after = await page.locator("main").boundingBox();
  assert.deepEqual(main_after, main_before, "main must not move when the panel docks");
  assert.ok(main_after.x + main_after.width <= panel.x + 1, "main and the panel must not overlap");

  await open_panel(page, null);
  await page.waitForSelector("#helpbox-wrapper:not(.open)", { state: "attached" });

  await open_panel(page, "docs");
  await page.waitForSelector("#helpbox-wrapper.open");
  assert.equal(await page.locator('[role="tab"][aria-selected="true"]').innerText(), "Help");
  await open_panel(page, "packages");
  assert.equal(await page.locator('#helpbox-wrapper.open').count(), 1, "still one panel");
  assert.equal(await page.locator('[role="tab"][aria-selected="true"]').innerText(), "Packages");

  assertNoProblems(page);
});

// 112. Slide-over (641-1239px): narrower, with a shadow, over the notebook.
test("layout: the side panel slides over at 1100x800 (112)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "layout-112.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 1100, height: 800 });
  await openNotebook(page, server.origin, server.secret, notebook);

  const main_before = await page.locator("main").boundingBox();
  assert.ok(Math.abs(main_before.x - 64) <= 1, `expected main.x ~= 64, got ${main_before.x}`);

  await open_panel(page, "variables");
  await page.waitForSelector("#helpbox-wrapper.open");
  const panel = await page.locator("#helpbox-wrapper").boundingBox();
  assert.ok(Math.abs(panel.width - 380) <= 1, `expected panel width ~= 380, got ${panel.width}`);

  const box_shadow = await page.locator("#helpbox-wrapper").evaluate((el) => getComputedStyle(el).boxShadow);
  assert.notEqual(box_shadow, "none", "expected a box-shadow on the slide-over panel");

  const main_after = await page.locator("main").boundingBox();
  assert.deepEqual(main_after, main_before, "main must not move when the panel slides over");

  assertNoProblems(page);
});

// 113. Sheet (<= 640px): from the bottom, over a scrim that closes it.
test("layout: the side panel opens as a bottom sheet at 390x844 (113)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "layout-113.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 390, height: 844 });
  await openNotebook(page, server.origin, server.secret, notebook);

  await open_panel(page, "variables");
  await page.waitForSelector("#helpbox-wrapper.open");
  const panel = await page.locator("#helpbox-wrapper").boundingBox();
  assert.ok(Math.abs(panel.x + panel.width - 390) <= 1, "the sheet spans the full width");
  assert.ok(panel.y + panel.height >= 844 - 1, "the sheet is anchored to the bottom");

  // The sheet covers the bottom of the viewport; click the scrim where it's
  // not covered by the sheet (the top-left corner).
  await page.locator(".ember-scrim").click({ position: { x: 10, y: 150 } });
  await page.waitForSelector("#helpbox-wrapper:not(.open)", { state: "attached" });

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  assert.ok(overflow <= 1, `expected no horizontal scroll, got ${overflow}px of overflow`);

  assertNoProblems(page);
});

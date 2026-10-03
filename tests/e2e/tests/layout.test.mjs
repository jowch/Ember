// Piece 5 ("Identity and layout"), docs/ui-3-plan.md's "Layout": the
// 720 px column and the sticky header shell. docs/ui-3-tests.md 110, 114
// (111-113, the side panel's own layout, are piece 5's "Side panel frame"
// step and come with it).

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

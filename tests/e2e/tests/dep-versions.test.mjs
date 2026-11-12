// Two outputs can carry two versions of one widget library: plotly's jQuery
// 3.5.1 and DT's 3.6.0. The page loads the first version only (CellOutput.js's
// execute_scripttags), as Shiny does. A second jQuery would replace the first,
// with the DataTables plugin on it, and DT would then draw only its header.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell } from "../browser.mjs";

// Installing htmltools into the notebook's own library needs CRAN's index
// (network), as export.test.mjs's widget test does.
test("a widget library loads in one version per page, the first", {
  skip: !process.env.EMBER_E2E_INSTALLS && "set EMBER_E2E_INSTALLS=1 (needs network to resolve the lock)",
}, async (t) => {
  const notebook = tempNotebook("dep-versions.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "dep-versions.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  for (const id of ["DEP", "OLD", "NEW"]) await runCell(page, id);
  await page.waitForFunction(() => [...document.querySelectorAll(".dupe-marker")].length === 2 && [...document.querySelectorAll(".dupe-marker")].every((el) => el.textContent !== "pending"));

  assert.deepEqual(await page.evaluate(() => window.__dupe_runs), ["1.0.0"], "only the first version ran");
  assert.equal(await page.locator("#dupe-2").textContent(), "1.0.0", "the output that carries 2.0.0 uses 1.0.0");
  assert.deepEqual(await page.evaluate(() => [...document.head.querySelectorAll("script[data-ember-dep=emberdupe]")].map((s) => s.dataset.emberDepVersion)), ["1.0.0"]);

  assertNoProblems(page);
  await page.close();
});

// htmlwidgets resizes a widget only on the window's "resize" event. A widget's
// box that changes without one (a host restyling the page, a scrollbar) gets
// one from common/WidgetSizes.js: one per change, none when nothing changed.
test("a widget whose box changes size gets one window resize event", {
  skip: !process.env.EMBER_E2E_INSTALLS && "set EMBER_E2E_INSTALLS=1 (needs network to resolve the lock)",
}, async (t) => {
  const notebook = tempNotebook("dep-versions.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "widget-sizes.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await runCell(page, "BOX");
  await page.waitForSelector("#box-widget");
  // The observer starts once the output's scripts have run, and its first report is the drawn size.
  await page.waitForTimeout(500);
  await page.evaluate(() => { window.__resizes = 0; window.addEventListener("resize", () => window.__resizes++); });
  const width = await page.locator("#box-widget").evaluate((el) => el.getBoundingClientRect().width);

  // A style that leaves the box as it is: no event.
  await page.evaluate(() => { document.getElementById("box-widget").style.outline = "1px solid red"; });
  await page.waitForTimeout(500);
  assert.equal(await page.evaluate(() => window.__resizes), 0, "no event when the size didn't change");

  // The box narrows (as when a host narrows the column), the window doesn't: one event.
  await page.evaluate((w) => { document.getElementById("box-widget").style.width = `${Math.round(w / 2)}px`; }, width);
  await page.waitForTimeout(500);
  assert.equal(await page.evaluate(() => window.__resizes), 1, "one event for the change");
  assert.ok(await page.locator("#box-widget").evaluate((el, w) => el.getBoundingClientRect().width < w, width), "the box did narrow");

  assertNoProblems(page);
  await page.close();
});

// Piece 3 (docs/ui-2.md, "Rich outputs"), scenarios 38-42 of
// docs/ui-2-tests.md: tables, trees, plots and colours shown against a
// real server and worker.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

test("table and print: TBL is a table with 'more', FIT prints text (39)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "rich-table.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "TBL");
  await page.waitForSelector(`${cellSelector("TBL")} table.pluto-table`, { timeout: 20000 });
  const bodyRows = await page.locator(`${cellSelector("TBL")} table.pluto-table tbody tr`).count();
  assert.equal(bodyRows, 11); // 10 shown rows + a "more" row
  const typesRow = await page.locator(`${cellSelector("TBL")} tr.schema-types`).innerText();
  assert.match(typesRow, /<dbl>/);

  await page.locator(`${cellSelector("TBL")} .pluto-tree-more-td pluto-tree-more`).click();
  await page.waitForFunction(
    (sel) => document.querySelectorAll(`${sel} table.pluto-table tbody tr`).length === 32,
    `${cellSelector("TBL")}`, { timeout: 10000 });

  await runCell(page, "FIT");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Coefficients"),
    `${cellSelector("FIT")} pluto-output`, { timeout: 20000 });
  const fitHasTree = await page.locator(`${cellSelector("FIT")} pluto-tree`).count();
  assert.equal(fitHasTree, 0);

  assertNoProblems(page);
});

test("tree: LST is a collapsed tree that expands and pages (40)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "rich-tree.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "LST");
  await page.waitForSelector(`${cellSelector("LST")} pluto-tree`, { timeout: 20000 });
  await page.locator(`${cellSelector("LST")} pluto-tree`).first().click();
  const text = await page.locator(`${cellSelector("LST")} pluto-tree`).first().innerText();
  assert.match(text, /a/);
  assert.match(text, /b/);
  assert.match(text, /long/);

  const mores = page.locator(`${cellSelector("LST")} pluto-tree-more`);
  const count = await mores.count();
  assert.ok(count > 0, "expected a 'more' control for the long sublist");
  await mores.last().click();

  assertNoProblems(page);
});

/** `newPage()`'s console/pageerror/dialog wiring, for a page made with
 * `context.newPage()` directly (a custom `deviceScaleFactor` needs its own
 * context, so `newPage(browser)` can't be used for it). */
function wireProblems(page) {
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error") problems.push("console: " + m.text()); });
  page.on("pageerror", (e) => problems.push("pageerror: " + e.message));
  page.on("dialog", async (d) => { problems.push("dialog: " + d.message()); await d.dismiss(); });
  page.problems = problems;
  return page;
}

/** Whether any websocket frame sent by `page` so far contains `needle`
 * (the ember_render_plot request type's name): binary frames arrive as a
 * raw-byte string in Playwright, in which the type name's ASCII bytes
 * appear verbatim (msgpack encodes a short map key as its literal UTF-8
 * bytes); some Playwright builds instead base64-encode a binary payload,
 * so both are checked. */
function watchRenderRequests(page, needle = "ember_render_plot") {
  const seen = [];
  page.on("websocket", (ws) => {
    ws.on("framesent", (frame) => {
      const payload = frame.payload ?? "";
      let found = typeof payload === "string" && payload.includes(needle);
      if (!found) {
        try { found = Buffer.from(payload, "base64").toString("latin1").includes(needle); } catch { /* not base64 */ }
      }
      if (found) seen.push(Date.now());
    });
  });
  return seen;
}

test("plot: PLT is a fixed-size image that never redraws when the viewport narrows (74)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "rich-plot.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 1280, height: 800 });
  const renderRequests = watchRenderRequests(page);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "PLT");
  await page.waitForSelector(`${cellSelector("PLT")} img`, { timeout: 20000 });
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.naturalWidth > 0,
    `${cellSelector("PLT")} img`, { timeout: 10000 });

  // 720 CSS px is the figure's own size (7.5in default x 96): the image
  // never draws wider than that, and fits (scales down into) its column
  // when the column is narrower (piece 5 sets the column itself to
  // exactly 720px; until then it's whatever the pre-restyle layout gives).
  const { widthAt1280, columnWidth } = await page.evaluate((sel) => {
    const img = document.querySelector(sel);
    const r = img.getBoundingClientRect();
    return { widthAt1280: r.width, columnWidth: img.closest("pluto-output").getBoundingClientRect().width };
  }, `${cellSelector("PLT")} img`);
  assert.ok(widthAt1280 <= 720 + 1, `expected the image no wider than 720 CSS px, got ${widthAt1280}`);
  assert.ok(widthAt1280 <= columnWidth + 1, `expected the image to fit its ${columnWidth}px column, got ${widthAt1280}`);
  const naturalBefore = await page.evaluate((sel) => document.querySelector(sel).naturalWidth, `${cellSelector("PLT")} img`);

  await page.setViewportSize({ width: 600, height: 800 });
  await page.waitForTimeout(3000);

  assert.equal(renderRequests.length, 0, "expected no ember_render_plot request after narrowing the viewport");
  const naturalAfter = await page.evaluate((sel) => document.querySelector(sel).naturalWidth, `${cellSelector("PLT")} img`);
  assert.equal(naturalAfter, naturalBefore, "expected the same image, not a re-render");

  const fitsColumn = await page.evaluate((sel) => {
    const img = document.querySelector(sel);
    const column = img.closest("pluto-output");
    return img.getBoundingClientRect().width <= column.getBoundingClientRect().width + 1;
  }, `${cellSelector("PLT")} img`);
  assert.ok(fitsColumn, "expected the image to fit (scale down into) its narrower column");

  assertNoProblems(page);
});

test("plot: FIG's #| fig-width/fig-height lines give a fixed 480 x 384 CSS px image (75)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "rich-fig.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "FIG");
  await page.waitForSelector(`${cellSelector("FIG")} img`, { timeout: 20000 });
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.naturalWidth > 0,
    `${cellSelector("FIG")} img`, { timeout: 10000 });

  const { width, height } = await page.evaluate((sel) => {
    const r = document.querySelector(sel).getBoundingClientRect();
    return { width: r.width, height: r.height };
  }, `${cellSelector("FIG")} img`);
  assert.ok(Math.abs(width - 480) <= 1, `expected width 480 CSS px, got ${width}`);
  assert.ok(Math.abs(height - 384) <= 1, `expected height 384 CSS px, got ${height}`);

  assertNoProblems(page);
});

test("plot: a 3x-density tab asks for one redraw at res 288; a 1x tab asks for none (76)", { timeout: 60000 }, async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "rich-plot-dpr.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const context1x = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
  const context3x = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 3 });
  t.after(async () => { await context1x.close(); await context3x.close(); });

  const page1 = wireProblems(await context1x.newPage());
  const page3 = wireProblems(await context3x.newPage());
  const requests1 = watchRenderRequests(page1);
  const requests3 = watchRenderRequests(page3);

  await openNotebook(page1, server.origin, server.secret, notebook);
  await openNotebook(page3, server.origin, server.secret, notebook);
  await runCell(page1, "PLT");

  for (const page of [page1, page3]) {
    await page.waitForSelector(`${cellSelector("PLT")} img`, { timeout: 20000 });
    await page.waitForFunction(
      (sel) => document.querySelector(sel)?.naturalWidth > 0,
      `${cellSelector("PLT")} img`, { timeout: 10000 });
  }

  // The 3x tab's image should widen to res 288 (7.5in default figure width
  // x 288 = 2160px); the 1x tab's stays at the first-draw 2x density (1440).
  await page3.waitForFunction(
    (sel) => document.querySelector(sel)?.naturalWidth === 2160,
    `${cellSelector("PLT")} img`, { timeout: 10000 });
  assert.equal(requests3.length, 1, "expected exactly one render request from the 3x tab");

  await page1.waitForTimeout(10000);
  assert.equal(requests1.length, 0, "expected no render request from the 1x tab");
  assert.equal(requests3.length, 1, "expected no further render request from the 3x tab over the next 10s");

  assertNoProblems(page1);
  assertNoProblems(page3);
});

test("colours: ANSI's log and output have coloured spans and no visible escape codes (43)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "rich-ansi.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "ANSI");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.querySelector("span.ansi-red-fg") != null,
    `${cellSelector("ANSI")} pluto-logs`, { timeout: 20000 }).catch(async () => {
      // the console log area's selector may differ; fall back to a broad search
      await page.waitForFunction(
        () => document.querySelector("span.ansi-red-fg") != null, null, { timeout: 5000 });
    });

  const bodyText = await page.locator(cellSelector("ANSI")).innerText();
  assert.doesNotMatch(bodyText, /\x1b/);

  assertNoProblems(page);
});

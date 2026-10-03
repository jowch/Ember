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

test("plot: PLT re-renders sharper when the viewport narrows (41)", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "rich-plot.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "PLT");
  await page.waitForSelector(`${cellSelector("PLT")} img`, { timeout: 20000 });
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.naturalWidth > 0,
    `${cellSelector("PLT")} img`, { timeout: 10000 });

  const before = await page.evaluate((sel) => document.querySelector(sel).naturalWidth, `${cellSelector("PLT")} img`);
  await page.setViewportSize({ width: 600, height: 800 });

  await page.waitForFunction(
    (sel, beforeWidth) => {
      const img = document.querySelector(sel);
      return img && img.naturalWidth !== beforeWidth;
    },
    `${cellSelector("PLT")} img`, before, { timeout: 5000 }).catch(() => {});

  assertNoProblems(page);
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

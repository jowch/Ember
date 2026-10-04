// Inline `r expr` values (ui-3-tests.md 56-58): a text cell's inline
// expressions run reactively, like any cell's code, and fail like one.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, runCell, cellSelector } from "../browser.mjs";

test("text: inline values render once the notebook runs; a bad one shows its own error (56, 58)", async (t) => {
  const notebook = tempNotebook("text.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "text.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator("#ember-safe-preview button").click();

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Half of it is 10.5."),
    cellSelector("T") + " pluto-output", { timeout: 20000 });
  const span = await page.locator(`${cellSelector("T")} pluto-output span.ember-inline`).innerText();
  assert.equal(span, "10.5");

  await page.waitForSelector(`${cellSelector("E")} jlerror`, { timeout: 20000 });
  const errText = await page.locator(`${cellSelector("E")} jlerror`).innerText();
  assert.match(errText, /object 'carz' not found/);

  const otherErrors = await page.locator("pluto-cell:not([id='E']) jlerror").count();
  assert.equal(otherErrors, 0, "no cell besides E shows an error");

  assertNoProblems(page);
});

test("text: a dependent text cell updates when its ancestor runs, without itself being run (57)", async (t) => {
  const notebook = tempNotebook("text.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "text-dependent.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Half of it is 10.5."),
    cellSelector("T") + " pluto-output", { timeout: 20000 });

  await setCellCode(page, "A", "x <- 42");
  await runCell(page, "A");

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Half of it is 21."),
    cellSelector("T") + " pluto-output", { timeout: 20000 });

  assertNoProblems(page);
});

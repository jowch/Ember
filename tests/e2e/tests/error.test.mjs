// Scenario 43 (docs/ui-tests.md): a cell that throws shows the error
// element with its message. A parse error uses the same box (ui-3-plan.md
// 6.4): the message and its line, no traceback.

import { test } from "node:test";
import path from "node:path";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector, setCellCode } from "../browser.mjs";

test("error: stop('boom') shows the error element with its message", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "error.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "ERR");
  await page.waitForSelector(`${cellSelector("ERR")} jlerror`, { timeout: 20000 });
  const text = await page.locator(`${cellSelector("ERR")} jlerror`).innerText();
  assert.match(text, /boom/);
  assert.equal(await page.locator(`${cellSelector("ERR")} jlerror.ember > header > p:first-child`).innerText(), "boom");
  assert.doesNotMatch(text, /Error message|stack trace/i, "none of Pluto's error box wording");
});

test("error: a parse error shows its message and line, and no traceback", async (t) => {
  const notebook = tempNotebook("rich.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "error-parse.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();

  const box = `${cellSelector("PARSE")} jlerror.ember.syntax-error`;
  await page.waitForSelector(box, { timeout: 20000 });
  assert.notEqual(await page.locator(`${box} > header > p:first-child`).innerText(), "");
  assert.equal(await page.locator(`${box} > header > p.ember-error-where`).innerText(), "Error · line 1");
  assert.equal(await page.locator(`${box} > section`).count(), 0);

  assertNoProblems(page);
});

test("error: a name defined twice and a cycle are worded for R users (Words6)", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "error-graph.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const message = (id) => page.locator(`${cellSelector(id)} jlerror.ember > header > p:first-child`);

  await setCellCode(page, "ERR", "x <- 2");
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction((sel) => /more than one cell/.test(document.querySelector(sel)?.innerText ?? ""),
    `${cellSelector("ERR")} jlerror`, { timeout: 20000 });
  assert.equal((await message("ERR").innerText()).split("\n")[0], "x is defined in more than one cell. Keep one, or put them in one cell.");

  await setCellCode(page, "ERR", "y <- z");
  await page.keyboard.press("Shift+Enter");
  await setCellCode(page, "LOOP", "z <- y");
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction((sel) => /each other/.test(document.querySelector(sel)?.innerText ?? ""),
    `${cellSelector("LOOP")} jlerror`, { timeout: 20000 });
  assert.equal((await message("LOOP").innerText()).split("\n")[0], "y and z depend on each other, so neither can run.");
  assertNoProblems(page);
});

test("error: running broken code in a cell that ran shows only the error, not edited, and no cell id", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "error-parse-run.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.add_cell.after`).click({ force: true });
  const id = await page.evaluate(() => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    return cells[cells.findIndex((c) => c.id === "B") + 1]?.id ?? null;
  });
  assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-/);
  const cell = cellSelector(id);

  await page.locator(`${cell} .cm-content`).click();
  await page.keyboard.type("41 + 1", { delay: 2 });
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("42"),
    `${cell} pluto-output`, { timeout: 20000 });

  await setCellCode(page, id, "barplot(table(sample(1:3, size=1000, replace=TRUE, prob=(.30,.60,.10))))");
  await page.waitForSelector(`${cell}.code_differs`, { timeout: 10000 });
  await page.keyboard.press("Shift+Enter");

  const box = `${cell} jlerror.ember.syntax-error`;
  await page.waitForSelector(box, { timeout: 20000 });
  // The edit reaches the server before the run request, and in between the
  // cell is briefly errored and edited at once.
  await page.waitForSelector(`${cell}.errored:not(.code_differs):not(.code_changed)`, { timeout: 10000 });
  assert.equal(await page.locator(`${box} > header > p:first-child`).innerText(), "Syntax error: unexpected ','");
  assert.doesNotMatch(await page.locator(box).innerText(), /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-/);
  assert.equal(await page.locator(`${box} > header > p.ember-error-where`).innerText(), "Error · line 1");
  assertNoProblems(page);
});

// Scenario 43 (docs/ui-tests.md): a cell that throws shows the error
// element with its message. A parse error uses the same box (ui-3-plan.md
// 6.4): the message and its line, no traceback.

import { test } from "node:test";
import path from "node:path";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

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

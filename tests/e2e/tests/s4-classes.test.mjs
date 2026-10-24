// #41: an S4 class named as a string links the cell that uses it to the
// setClass() cell. A class cell placed after its user still runs first;
// a failed one gives its user "Another cell defining class Bad contains
// errors.", and the class cell's name reads "class Ok", never R's binding
// name `.__C__Ok`.

import { test } from "node:test";
import path from "node:path";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

test("s4 classes: a class cell runs before the cell using it, and is named as a class", async (t) => {
  const notebook = tempNotebook("s4-classes.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "s4-classes.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("[1] 2"),
    cellSelector("U1") + " pluto-output");

  await page.waitForSelector(`${cellSelector("U2")} jlerror`);
  assert.equal(await page.locator(`${cellSelector("U2")} jlerror`).innerText(),
    "Another cell defining class Bad contains errors.");

  assert.match(await page.locator(cellSelector("C1")).getAttribute("aria-label"), /^Cell defining class Ok\b/);
  assert.doesNotMatch(await page.locator("body").innerText(), /__C__/);

  assertNoProblems(page);
});

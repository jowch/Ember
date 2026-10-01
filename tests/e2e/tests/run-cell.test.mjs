// Scenario 38/39 (docs/ui-tests.md): running a cell runs its ancestors
// first; editing a cell and Shift-Entering it shows the new output and
// saves the new code to the file on disk.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector } from "../browser.mjs";

test("run: running B runs its ancestor A first, and shows the output", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "run.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "B");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  const bClass = await page.locator(cellSelector("B")).getAttribute("class");
  assert.ok(!bClass.includes("running") && !bClass.includes("queued"));

  const aClass = await page.locator(cellSelector("A")).getAttribute("class");
  assert.ok(!aClass.includes("running") && !aClass.includes("queued"), "A ran too, as B's ancestor");

  assertNoProblems(page);
});

test("edit + Shift-Enter: new output appears, and the file on disk has the new code", async (t) => {
  const notebook = tempNotebook();
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "edit-run.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await setCellCode(page, "B", "sum(x) * 2");
  await runCell(page, "B");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("110"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  const onDisk = fs.readFileSync(notebook, "utf8");
  assert.match(onDisk, /sum\(x\) \* 2/);

  assertNoProblems(page);
});

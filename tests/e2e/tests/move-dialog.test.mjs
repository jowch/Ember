// Test 98 (docs/ui-3-tests.md, piece 4): clicking the header's file name
// opens MoveDialog (board Move5), built on dialogs.js's `Dialog` shell in
// place of the old FilePicker. Renaming keeps R running -- an existing
// cell's output survives untouched -- and the worker's working directory
// still matches the notebook's folder afterward.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector } from "../browser.mjs";

test("header: click the file name, rename, Save: title changes, R keeps running, getwd() matches the folder (98)", async (t) => {
  const notebook = tempNotebook();
  const dir = path.dirname(notebook);
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "move-dialog.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "B");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  await page.locator("#ember-file-name").click();
  const dialog = page.locator("dialog.ember-dialog[open]");
  await dialog.waitFor({ state: "visible", timeout: 5000 });

  const nameField = dialog.locator("#ember-move-name");
  await nameField.click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await page.keyboard.type("renamed");
  await dialog.getByRole("button", { name: "Save" }).click();
  await dialog.waitFor({ state: "hidden", timeout: 5000 });

  await page.waitForFunction(() => document.title === "renamed.R — Ember", null, { timeout: 5000 });

  assert.equal(fs.existsSync(notebook), false, "the old file is gone");
  const renamedPath = path.join(dir, "renamed.R");
  assert.equal(fs.existsSync(renamedPath), true, "the renamed file exists on disk");

  // R wasn't restarted: B's output from before the rename is still shown,
  // with nothing re-run.
  assert.match(await page.locator(cellSelector("B") + " pluto-output").innerText(), /55/);
  const bClass = await page.locator(cellSelector("B")).getAttribute("class");
  assert.ok(!bClass.includes("running") && !bClass.includes("queued"));

  // The worker's working directory follows the file: a cell run now sees
  // the (unchanged, since only the name changed) folder.
  await setCellCode(page, "LOOP", "basename(getwd())");
  await runCell(page, "LOOP");
  const needle = path.basename(dir);
  await page.waitForFunction(
    ({ sel, needle }) => document.querySelector(sel)?.innerText.includes(needle),
    { sel: cellSelector("LOOP") + " pluto-output", needle }, { timeout: 20000 });

  assertNoProblems(page);
});

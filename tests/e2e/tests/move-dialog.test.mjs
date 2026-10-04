// Test 98 (docs/ui-3-tests.md, piece 4): clicking the header's file name
// opens MoveDialog, built on dialogs.js's `Dialog` shell in place of the
// old FilePicker. Renaming and moving to a different folder keeps R
// running -- an existing cell's output survives untouched -- and the
// worker's working directory follows the file to the new folder.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector } from "../browser.mjs";

test("header: click the file name, rename and move to a different folder, Save: title changes, R keeps running, getwd() matches the new folder (98)", async (t) => {
  const notebook = tempNotebook();
  const dir = path.dirname(notebook);
  const newDir = mkdtempSync(path.join(tmpdir(), "ember-e2e-move-dest-"));
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

  // Moving the folder too, not just the name: a folder that stays the
  // same (as an earlier version of this test did) would never exercise
  // chdir() actually changing anything.
  await dialog.locator(".ember-link-btn", { hasText: "Change" }).click();
  const folderField = dialog.locator("#ember-move-folder");
  await folderField.click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await page.keyboard.type(newDir);
  // Blur the folder field (click the Name field instead) rather than
  // press Escape: with no completion match for a brand-new temp folder,
  // Escape isn't handled by the folder field at all and closes the
  // whole dialog instead (dialogs.js's own Esc-to-close).
  await nameField.click();

  await dialog.getByRole("button", { name: "Save" }).click();
  await dialog.waitFor({ state: "hidden", timeout: 15000 });

  await page.waitForFunction(() => document.title === "renamed.R — Ember", null, { timeout: 5000 });

  assert.equal(fs.existsSync(notebook), false, "the old file is gone");
  const renamedPath = path.join(newDir, "renamed.R");
  assert.equal(fs.existsSync(renamedPath), true, "the renamed, moved file exists in the new folder");

  // R wasn't restarted: B's output from before the move is still shown,
  // with nothing re-run.
  assert.match(await page.locator(cellSelector("B") + " pluto-output").innerText(), /55/);
  const bClass = await page.locator(cellSelector("B")).getAttribute("class");
  assert.ok(!bClass.includes("running") && !bClass.includes("queued"));

  // The worker's working directory follows the file to the new folder.
  await setCellCode(page, "LOOP", "basename(getwd())");
  await runCell(page, "LOOP");
  const needle = path.basename(newDir);
  await page.waitForFunction(
    ({ sel, needle }) => document.querySelector(sel)?.innerText.includes(needle),
    { sel: cellSelector("LOOP") + " pluto-output", needle }, { timeout: 20000 });

  assertNoProblems(page);
});

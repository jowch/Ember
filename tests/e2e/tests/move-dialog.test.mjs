// Test 98 (docs/ui-3-tests.md, piece 4): clicking the header's file name
// opens MoveDialog, built on dialogs.js's `Dialog` shell in place of the
// old FilePicker. Renaming and moving to a different folder keeps R
// running -- an existing cell's output survives untouched -- and the
// worker's working directory follows the file to the new folder.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir, tempDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, setCellCode, cellSelector, sentMessages } from "../browser.mjs";
import { waitingFor } from "../waits.mjs";

test("header: click the file name, rename and move to a different folder, Save: title changes, R keeps running, getwd() matches the new folder (98)", async (t) => {
  const notebook = tempNotebook();
  const dir = path.dirname(notebook);
  const newDir = tempDir("ember-e2e-move-dest-");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "move-dialog.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // If the dialog stays open after Save, say which of the three ways it
  // can (#473): it shows a move error, it is still saving with the reply
  // never come, or the Save click never sent the request. Counted from
  // before the page opens its socket, which `websocket` reports only once.
  const asked = sentMessages(page, "ember_move_notebook");
  const answered = [];
  page.on("websocket", (ws) => ws.on("framereceived", (frame) => {
    const payload = frame.payload ?? "";
    if ((Buffer.isBuffer(payload) ? payload.toString("latin1") : String(payload)).includes("ember_move_notebook")) answered.push(Date.now());
  }));
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "B");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output");

  await page.locator("#ember-file-name").click();
  const dialog = page.locator("dialog.ember-dialog[open]");
  await dialog.waitFor({ state: "visible" });

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

  const sentBefore = asked.length;
  const answeredBefore = answered.length;
  await dialog.getByRole("button", { name: "Save" }).click();
  await waitingFor("the move dialog closes after Save", dialog.waitFor({ state: "hidden" }), async () => {
    const shown = await page.evaluate(() => {
      const d = document.querySelector("dialog.ember-dialog[open]");
      if (!d) return { open: false };
      const button = (label) => [...d.querySelectorAll("button")].find((b) => b.textContent.trim() === label)?.disabled;
      return {
        open: true,
        error: d.querySelector(".ember-dialog-error")?.textContent ?? null,
        saveDisabled: button("Save"), cancelDisabled: button("Cancel"),
        name: d.querySelector("#ember-move-name")?.value, folder: d.querySelector("#ember-move-folder")?.value,
      };
    }).catch((e) => ({ unreadable: String(e) }));
    return { ...shown, sentSinceSave: asked.length - sentBefore, repliesSinceSave: answered.length - answeredBefore };
  });

  await page.waitForFunction(() => document.title === "renamed.R — Ember");

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
    { sel: cellSelector("LOOP") + " pluto-output", needle });

  assertNoProblems(page);
});

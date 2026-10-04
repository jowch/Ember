// Test 79 (docs/ui-3-tests.md, piece 7a): deleting several cells asks
// through common/dialogs.js's in-page `ask`, not window.confirm(). Selects
// A and B through window.editor_state_set, the same hook Endeavor uses
// (Editor.js:editor_state_set), then drives the dialog with the keyboard:
// focus starts on Delete, Tab stays inside, Esc cancels (keeping both
// cells and returning focus where it was), then a second run confirms the
// delete. newPage()'s dialog handler fails the test on any *native*
// alert()/confirm(), so a regression back to window.confirm() would show
// up as an unexpected dialog, not a hang.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook } from "../browser.mjs";

test("delete several cells: in-page dialog, Tab trapped, Esc cancels and restores focus", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "delete-dialog.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const selectAandB = () => page.evaluate(() => window.editor_state_set({ selected_cells: ["A", "B"] }));

  // --- Esc: cancels, keeps both cells, returns focus ---

  // A real, always-present header button: focusing it (not clicking --
  // that would open the export menu) puts a genuine element in
  // document.activeElement, not document.body, so the later check that
  // focus comes back to it actually exercises dialogs.js's restore. Its
  // own keydown has no handler, so Backspace still bubbles to Editor's
  // document-level listener.
  const beforeEsc = await page.evaluateHandle(() => {
    const el = document.querySelector('header#pluto-nav button[aria-label="Export"]');
    el.focus();
    return el;
  });
  assert.notEqual(await page.evaluate((el) => el.tagName, beforeEsc), "BODY");
  assert.ok(await page.evaluate((el) => el === document.activeElement, beforeEsc), "the header button took focus");

  await selectAandB();
  await page.keyboard.press("Backspace");

  const dialog = page.locator("dialog.ember-dialog[open]");
  await dialog.waitFor({ state: "visible", timeout: 5000 });
  assert.match(await dialog.innerText(), /Delete 2 cells\?/);

  const deleteButton = dialog.getByRole("button", { name: "Delete" });
  await assert.doesNotReject(deleteButton.evaluate((el) => { if (document.activeElement !== el) throw new Error("not focused"); }));

  // Tab a few times and check focus never lands on anything outside the
  // dialog. Chromium's native modal-dialog trapping rests briefly on
  // <body> between wrapping from the last control back to the first
  // (nothing else is focusable then), so that's allowed too; landing on
  // any other page control would not be.
  for (let i = 0; i < 4; i++) {
    await page.keyboard.press("Tab");
    const inside = await dialog.evaluate((d) => d.contains(document.activeElement) || document.activeElement === document.body);
    assert.ok(inside, "Tab stays inside the dialog");
  }

  await page.keyboard.press("Escape");
  await dialog.waitFor({ state: "hidden", timeout: 5000 });

  assert.equal(await page.locator('pluto-cell[id="A"]').count(), 1, "A survives Esc");
  assert.equal(await page.locator('pluto-cell[id="B"]').count(), 1, "B survives Esc");

  // dialogs.js defers its own restoration a frame to land after Chromium's
  // own post-close focus handling, so the dialog being hidden doesn't
  // guarantee focus has settled yet; wait for the real end state instead
  // of checking once right away.
  await page.waitForFunction((el) => el === document.activeElement, beforeEsc, { timeout: 2000 });

  // --- Delete: removes both cells ---

  await selectAandB();
  await page.keyboard.press("Backspace");
  await dialog.waitFor({ state: "visible", timeout: 5000 });
  await dialog.getByRole("button", { name: "Delete" }).click();
  await dialog.waitFor({ state: "hidden", timeout: 5000 });

  await page.waitForFunction(
    () => !document.getElementById("A") && !document.getElementById("B"),
    null, { timeout: 10000 });

  // A host embedding the page reads what was asked and answered here.
  const log = await page.evaluate(() => window.ember_dialogs.map(({ body, answer }) => ({ body, answer })));
  assert.deepEqual(log, [
    { body: "Delete 2 cells?", answer: null },
    { body: "Delete 2 cells?", answer: "Delete" },
  ]);

  assertNoProblems(page);
});

test("delete several cells: a click on the dialog's backdrop cancels", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "delete-dialog-backdrop.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.evaluate(() => window.editor_state_set({ selected_cells: ["A", "B"] }));
  await page.keyboard.press("Backspace");

  const dialog = page.locator("dialog.ember-dialog[open]");
  await dialog.waitFor({ state: "visible", timeout: 5000 });

  // A click in a corner of the viewport lands on the <dialog> element
  // itself (its backdrop covers the page once shown modally), not on its
  // centred content box.
  await page.mouse.click(5, 5);
  await dialog.waitFor({ state: "hidden", timeout: 5000 });

  assert.equal(await page.locator('pluto-cell[id="A"]').count(), 1, "A survives a backdrop click");
  assert.equal(await page.locator('pluto-cell[id="B"]').count(), 1, "B survives a backdrop click");

  assertNoProblems(page);
});

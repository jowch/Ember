// #349: a cell delete is a step in the undo history. In an editor, Ctrl+Z
// goes back through that cell's typing and the deletes recorded in it, in
// order; a restored cell comes back with its own history, so Ctrl+Z goes on
// into it. Outside the editors, Ctrl+Z brings back the last delete.
// #353: Backspace pressed while a delete is still in flight isn't dropped.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

const MOD = process.platform === "darwin" ? "Meta" : "Control";

const setup = async (t, name) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), `${name}.server.log`) });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });
  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  return page;
};

const order = (page) => page.evaluate(() => window.editor_state.notebook.cell_order);
const waitOrder = (page, expected) =>
  page.waitForFunction((e) => JSON.stringify(window.editor_state.notebook.cell_order) === JSON.stringify(e), expected, { timeout: 10000 })
    .catch(async () => assert.deepEqual(await order(page), expected));
// The editor's text, through the getValue CellInput.js puts on its DOM.
const editorText = (page, id) =>
  page.evaluate((sel) => document.querySelector(sel)?.CodeMirror?.getValue() ?? null, `${cellSelector(id)} .cm-editor:not(.cm-ssr-fake)`);
const waitText = (page, id, text) =>
  page.waitForFunction(([sel, text]) => document.querySelector(sel)?.CodeMirror?.getValue() === text,
    [`${cellSelector(id)} .cm-editor:not(.cm-ssr-fake)`, text], { timeout: 10000 })
    .catch(async () => assert.equal(await editorText(page, id), text));
const focusedCell = () => document.activeElement?.closest("pluto-cell")?.id ?? null;
const inEditor = () => document.activeElement?.closest(".cm-editor") != null;

test("Ctrl+Z in an editor steps back through typing and the cell deleted from it, then into the restored cell (#349)", async (t) => {
  const page = await setup(t, "undo-delete-editor");
  const original = await order(page);

  // Empty B and delete it with Backspace: the cursor goes to A.
  const b = page.locator(`${cellSelector("B")} .cm-editor:not(.cm-ssr-fake) .cm-content`);
  await page.locator(cellSelector("B")).scrollIntoViewIfNeeded();
  await b.click();
  await page.keyboard.press(`${MOD}+A`);
  await page.keyboard.press("Backspace");
  await page.keyboard.press("Backspace");
  await page.locator(cellSelector("B")).waitFor({ state: "detached", timeout: 10000 });
  assert.equal(await page.evaluate(focusedCell), "A");

  // Type in A after the delete.
  await page.keyboard.type(" # more");
  await waitText(page, "A", "x <- 1:10 # more");

  // First Ctrl+Z: the typing in A goes; B stays deleted.
  await page.keyboard.press(`${MOD}+Z`);
  await waitText(page, "A", "x <- 1:10");
  assert.equal(await page.locator(cellSelector("B")).count(), 0, "B is still deleted after undoing A's typing");

  // Second: B comes back where it was, empty as it was when deleted, with
  // the cursor in it.
  await page.keyboard.press(`${MOD}+Z`);
  await waitOrder(page, original);
  await page.waitForFunction(() => document.activeElement?.closest("pluto-cell")?.id === "B", null, { timeout: 10000 });
  assert.ok(await page.evaluate(inEditor), "the cursor is in B's editor");
  await waitText(page, "B", "");
  // Its run code is unchanged: emptying it was never run.
  assert.equal(await page.evaluate(() => window.editor_state.notebook.cell_inputs.B.code), "sum(x)");

  // Third: B's own history goes on, so its text comes back, and A's typing
  // is untouched.
  await page.keyboard.press(`${MOD}+Z`);
  await waitText(page, "B", "sum(x)");
  await waitText(page, "A", "x <- 1:10");
  assert.equal(await page.locator(`${cellSelector("B")}.code_differs`).count(), 0, "B is back in step with its run code");

  // Redo goes forward again from where undo left the cursor: in B, first
  // its text goes, then B itself, and the cursor is back in A. Ctrl+Z in A
  // then brings B back once more.
  await page.keyboard.press(`${MOD}+Shift+Z`);
  await waitText(page, "B", "");
  await page.keyboard.press(`${MOD}+Shift+Z`);
  await page.locator(cellSelector("B")).waitFor({ state: "detached", timeout: 10000 });
  await page.waitForFunction(() => document.activeElement?.closest("pluto-cell")?.id === "A", null, { timeout: 5000 });
  await page.keyboard.press(`${MOD}+Z`);
  await waitOrder(page, original);

  assertNoProblems(page);
});

test("Backspace pressed while a delete is in flight isn't dropped (#353); Ctrl+Z outside the editors brings deletes back in order (#349)", async (t) => {
  const page = await setup(t, "undo-delete-selection");
  const original = await order(page);

  // Select A (Esc from its editor), then three Backspaces with no pause.
  await page.locator(cellSelector("A")).scrollIntoViewIfNeeded();
  await page.locator(`${cellSelector("A")} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => window.editor_state.selected_cells.join() === "A", null, { timeout: 5000 });
  await page.keyboard.press("Backspace");
  await page.keyboard.press("Backspace");
  await page.keyboard.press("Backspace");
  const remaining = original.filter((id) => !["A", "B", "ERR"].includes(id));
  await waitOrder(page, remaining);
  assert.deepEqual(await page.evaluate(() => window.editor_state.selected_cells), ["LOOP"]);
  await page.locator("#undo_delete:not(.hidden)").waitFor({ timeout: 5000 });

  // Ctrl+Z on the selected cell: the last delete first, then the others.
  await page.keyboard.press(`${MOD}+Z`);
  await waitOrder(page, original.filter((id) => !["A", "B"].includes(id)));
  await page.locator("#undo_delete.hidden").waitFor({ state: "attached", timeout: 5000 });
  // It comes back selected, like the bottom bar's Undo.
  await page.waitForFunction(() => window.editor_state.selected_cells.join() === "ERR", null, { timeout: 5000 });
  await page.keyboard.press(`${MOD}+Z`);
  await page.keyboard.press(`${MOD}+Z`);
  await waitOrder(page, original);

  // Ctrl+Shift+Z deletes the last one brought back again.
  await page.keyboard.press(`${MOD}+Shift+Z`);
  await waitOrder(page, original.filter((id) => id !== "A"));

  // Nothing left to bring back but A: one more Ctrl+Z, then nothing.
  await page.keyboard.press(`${MOD}+Z`);
  await waitOrder(page, original);
  await page.keyboard.press(`${MOD}+Z`);
  await page.waitForTimeout(300);
  assert.deepEqual(await order(page), original);

  assertNoProblems(page);
});

test("menu Delete, then two quick Backspaces, removes three cells (#353)", async (t) => {
  const page = await setup(t, "undo-delete-menu");
  const original = await order(page);

  const cell = page.locator(cellSelector("A"));
  await cell.scrollIntoViewIfNeeded();
  await cell.locator(".cm-editor:not(.cm-ssr-fake) .cm-content").click();
  await cell.locator("button.input_context_menu").click();
  await cell.locator("div.input_context_menu button.delete").click();
  await page.keyboard.press("Backspace");
  await page.keyboard.press("Backspace");
  await waitOrder(page, original.filter((id) => !["A", "B", "ERR"].includes(id)));

  assertNoProblems(page);
});

test("deletes undone out of order go back next to their old neighbours (#349)", async (t) => {
  const page = await setup(t, "undo-delete-order");
  const original = await order(page);
  const deleteWithDeleteKey = async (id) => {
    await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
    await page.locator(`${cellSelector(id)} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
    await page.keyboard.press(`${MOD}+A`);
    await page.keyboard.press("Backspace");
    await page.keyboard.press("Delete");
    await page.locator(cellSelector(id)).waitFor({ state: "detached", timeout: 10000 });
  };
  const undoIn = async (id) => {
    await page.locator(`${cellSelector(id)} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
    await page.keyboard.press(`${MOD}+Z`);
  };

  // ERR's delete goes into LOOP's history, then A's into B's. A's delete
  // moved ERR's old index, so ERR goes back after B, not at index 3.
  await deleteWithDeleteKey("ERR");
  await deleteWithDeleteKey("A");
  await undoIn("LOOP");
  await waitOrder(page, original.filter((id) => id !== "A"));
  await undoIn("B");
  await waitOrder(page, original);

  assertNoProblems(page);
});

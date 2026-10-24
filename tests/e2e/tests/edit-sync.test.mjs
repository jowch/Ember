// #318: two tabs on one notebook. Like Pluto, every tab shows the code that
// was last run, wherever it ran. Typing that wasn't run yet in the other tab
// isn't lost silently: Ctrl+Z brings it back, and the cell says so.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, waitIdle } from "../browser.mjs";

const mod = process.platform === "darwin" ? "Meta" : "Control";
const editor = (id) => `${cellSelector(id)} .cm-editor:not(.cm-ssr-fake) .cm-content`;
const note = (id) => `${cellSelector(id)} ember-settings-note.remote-replace-note`;
// One-line cells, so the editor's text is its code.
const code = (page, id) => page.evaluate((sel) => document.querySelector(sel).innerText, editor(id));
const differs = (page, id) => page.locator(cellSelector(id)).evaluate((el) => el.classList.contains("code_differs"));

/** Click at the end of cell `id`'s code and type `text`, without running it. */
async function typeAtEnd(page, id, text) {
  await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
  await page.locator(editor(id)).click();
  await page.keyboard.press(`${mod}+End`);
  await page.keyboard.type(text, { delay: 2 });
}

/** Wait until `page` shows `expected` as cell `id`'s run code. */
const remoteCode = (page, id, expected) => page.waitForFunction(
  ([id, expected]) => window.editor_state.notebook.cell_inputs[id]?.code === expected,
  [id, expected]);

test("a run in one tab replaces unrun typing in another as an undo step, with a notice (#318)", async (t) => {
  const notebook = tempNotebook("edit-sync.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "edit-sync.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const one = await newPage(browser);
  await openNotebook(one, server.origin, server.secret, notebook);
  await one.locator("#ember-safe-preview button").click();
  await waitIdle(one);
  const two = await newPage(browser);
  await two.goto(one.url());
  await two.waitForSelector(editor("B"));
  await waitIdle(two);

  // Tab 2 types in B and C without running; tab 1 edits and runs B.
  await typeAtEnd(two, "B", " # tab2");
  await typeAtEnd(two, "C", " # left alone");
  assert.equal(await differs(two, "B"), true, "tab 2's B is marked changed");
  await typeAtEnd(one, "B", " # tab1");
  await one.keyboard.press("Shift+Enter");
  await remoteCode(two, "B", "b <- a * 2 # tab1");

  // Tab 2 shows the code that ran, with the notice.
  await two.waitForSelector(note("B"));
  assert.equal(await code(two, "B"), "b <- a * 2 # tab1");
  assert.equal(await differs(two, "B"), false);
  assert.match(await two.locator(note("B")).innerText(), /^Changed elsewhere \(another tab or the agent\)\. Undo \((Ctrl|⌘)\+Z\) to get your edit back\.$/);
  assert.equal(await one.locator(note("B")).count(), 0, "no notice in the tab that ran it");
  assert.equal(await two.locator(note("C")).count(), 0, "no notice on a cell nobody else changed");
  assert.equal(await code(two, "C"), "c <- 3 # left alone", "C keeps tab 2's typing");

  // A second run from tab 1 (the agent's run, fix, run) keeps the notice:
  // tab 2's typing is still only in its undo history.
  await typeAtEnd(one, "B", " r2");
  await one.keyboard.press("Shift+Enter");
  await remoteCode(two, "B", "b <- a * 2 # tab1 r2");
  await two.waitForFunction((sel) => document.querySelector(sel).innerText === "b <- a * 2 # tab1 r2", editor("B"));
  assert.equal(await two.locator(note("B")).count(), 1, "the notice stays through a second remote change");

  // Undo steps back through the runs to tab 2's typing, marked changed
  // again; the notice stays until the typing is back.
  await two.locator(editor("B")).click();
  await two.keyboard.press(`${mod}+z`);
  await two.waitForFunction((sel) => document.querySelector(sel).innerText === "b <- a * 2 # tab1", editor("B"));
  assert.equal(await two.locator(note("B")).count(), 1, "the notice stays while the typing is still further back");
  await two.keyboard.press(`${mod}+z`);
  await two.waitForFunction((sel) => document.querySelector(sel).innerText === "b <- a * 2 # tab2", editor("B"));
  assert.equal(await differs(two, "B"), true, "B is marked changed again");
  assert.equal(await two.locator(note("B")).count(), 0, "getting the typing back clears the notice");

  // A tab with no unrun typing just follows along, with no notice.
  await typeAtEnd(two, "B", "!");
  await two.keyboard.press("Shift+Enter");
  await remoteCode(one, "B", "b <- a * 2 # tab2!");
  await one.waitForFunction((sel) => document.querySelector(sel).innerText === "b <- a * 2 # tab2!", editor("B"));
  assert.equal(await one.locator(note("B")).count(), 0, "no notice where nothing was lost");

  assertNoProblems(one);
  assertNoProblems(two);
});

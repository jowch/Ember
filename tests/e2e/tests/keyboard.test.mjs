// The keyboard path and the focus ring, tests 166 and 167 of
// docs/ui-3-tests.md (piece 7e).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import fs from "node:fs";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, sentMessages, roundTrip } from "../browser.mjs";
import { waitingFor } from "../waits.mjs";

const mac = process.platform === "darwin";

/** Click into cell `id`'s code, Esc to select the cell, Enter to go back to the code. */
async function reenterCode(page, id) {
  await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
  await page.locator(`${cellSelector(id)} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.keyboard.press("Escape");
  await page.waitForFunction((id) => document.activeElement === document.getElementById(id), id);
  await page.keyboard.press("Enter");
  await page.waitForFunction((id) => document.activeElement?.matches(`pluto-cell[id="${id}"] .cm-content`) ?? false, id);
}

/** What has focus: the element's tag, cell id, classes and accessible name. */
function focused(page) {
  return page.evaluate(() => {
    const el = document.activeElement;
    return {
      tag: el?.tagName.toLowerCase(),
      cell: el?.closest("pluto-cell")?.id ?? null,
      cm_content: el?.matches(".cm-content") ?? false,
      selected: el?.classList.contains("selected") ?? false,
      label: el?.getAttribute("aria-label") ?? null,
      text: el?.textContent.trim() ?? "",
      in_panel: el?.closest("#helpbox-wrapper") != null,
    };
  });
}

test("keyboard path: skip link, Esc selects the cell, arrows, Enter, Tab to run, Esc closes the panel (166)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "keyboard-166.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  const runs = sentMessages(page, "run_multiple_cells");
  await openNotebook(page, server.origin, server.secret, notebook);
  const order = await page.evaluate(() => window.editor_state.notebook.cell_order);
  // The skip link, and Enter on a selected cell, focus a cell's code only
  // once its real editor has replaced the static copy (#415).
  await page.waitForFunction(() => !document.querySelector("pluto-input .cm-ssr-fake"));

  await page.keyboard.press("Tab");
  const skip = await page.evaluate(() => {
    const el = document.activeElement;
    const r = el.getBoundingClientRect();
    return { cls: el.className, text: el.textContent.trim(), width: r.width, height: r.height };
  });
  assert.equal(skip.cls, "skip-link");
  assert.equal(skip.text, "Skip to the notebook");
  assert.ok(skip.width > 40 && skip.height > 20, `the focused skip link is visible: ${JSON.stringify(skip)}`);

  await page.keyboard.press("Enter");
  let f = await focused(page);
  assert.equal(f.cell, order[0]);
  assert.ok(f.cm_content, "Enter puts focus in the first cell's code");

  await page.keyboard.press("Escape");
  f = await focused(page);
  assert.deepEqual([f.tag, f.cell, f.selected], ["pluto-cell", order[0], true]);
  await page.keyboard.press("Escape");
  f = await focused(page);
  assert.deepEqual([f.tag, f.cell, f.selected], ["pluto-cell", order[0], true], "a second Esc keeps the cell selected");

  await page.keyboard.press("ArrowDown");
  f = await focused(page);
  assert.deepEqual([f.tag, f.cell, f.selected], ["pluto-cell", order[1], true]);
  assert.deepEqual(await page.evaluate(() => window.editor_state.selected_cells), [order[1]]);

  await page.keyboard.press("Enter");
  f = await focused(page);
  assert.equal(f.cell, order[1]);
  assert.ok(f.cm_content, "Enter puts focus in the selected cell's code");

  // Board A11y6: run and ⋯ show while typing and on the button Tab reaches, not on a selected cell.
  await page.mouse.move(0, 0);
  const controls = (want) => page.waitForFunction(([id, want]) => {
    const cell = document.querySelector(`pluto-cell[id="${id}"]`);
    const shown = (sel) => getComputedStyle(cell.querySelector(sel)).opacity === "1";
    return JSON.stringify([shown("button.ember-run"), shown("button.input_context_menu")]) === JSON.stringify(want);
  }, [order[1], want]);
  await controls([true, true]);
  await page.keyboard.press("Escape");
  await controls([false, false]);
  await page.keyboard.press("Tab");
  await controls([true, false]);
  f = await focused(page);
  assert.deepEqual([f.tag, f.cell, f.label], ["button", order[1], "Run cell (Shift + Enter)"]);

  await page.getByRole("button", { name: "Help", exact: true }).click();
  await page.waitForSelector("#helpbox-wrapper.open");
  await page.waitForFunction(() => document.activeElement?.closest("#helpbox-wrapper") != null);
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.querySelector("#helpbox-wrapper").classList.contains("open"));
  f = await focused(page);
  assert.deepEqual([f.tag, f.label, f.in_panel], ["button", "Help", false]);

  // Keys in the code act once, though Esc and Enter went through the selected cell.
  await reenterCode(page, "B");
  assert.deepEqual(await page.evaluate(() => window.editor_state.selected_cells), [], "going back into the code ends the selection");
  const runs_before = runs.length;
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction(() => {
    const r = window.editor_state.notebook.cell_results.B;
    return (r?.output?.last_run_timestamp ?? 0) > 0 && !r.running && !r.queued;
  });
  await roundTrip(page);
  assert.equal(runs.length - runs_before, 1, "Shift + Enter in the code sends one run");

  await reenterCode(page, "B");
  const before_move = await page.evaluate(() => window.editor_state.notebook.cell_order);
  const moved = before_move.filter((id) => id !== "B");
  moved.splice(before_move.indexOf("B") + 1, 0, "B");
  await page.keyboard.press("Alt+ArrowDown");
  await page.waitForFunction((before) => JSON.stringify(window.editor_state.notebook.cell_order) !== JSON.stringify(before), before_move);
  await roundTrip(page);
  assert.deepEqual(await page.evaluate(() => window.editor_state.notebook.cell_order), moved, "Alt + ↓ moves the cell one place");

  // A selection left on another cell: the fold key in the code folds only this one.
  await page.locator(cellSelector("ERR")).scrollIntoViewIfNeeded();
  await page.locator(`${cellSelector("ERR")} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.evaluate(() => window.editor_state_set({ selected_cells: ["A"] }));
  await page.keyboard.press(mac ? "Meta+Alt+BracketLeft" : "Control+Shift+BracketLeft");
  await page.waitForFunction(() => window.editor_state.notebook.cell_inputs.ERR.code_folded);
  await roundTrip(page);
  assert.deepEqual(await page.evaluate(() => ["A", "ERR"].map((id) => window.editor_state.notebook.cell_inputs[id].code_folded)), [false, true]);
  assertNoProblems(page);
});

// #297: with Tab set to indent (the default), tabbing through the page
// used to land in the first cell's code and indent it on every press.
// Tab now passes through code that focus only arrived in, and indents
// once the person works there: a click, or Enter on a selected cell.
test("keyboard: Tab passes through cells' code without editing it, and indents once you're working there (#297)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const on_disk = fs.readFileSync(notebook, "utf8");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "keyboard-297.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const code = () => page.evaluate(() => Object.fromEntries(
    Object.entries(window.editor_state.notebook.cell_inputs).map(([id, c]) => [id, c.code])));
  // An empty editor's placeholder ("Type R code here") isn't code.
  const local = () => page.evaluate(() => [...document.querySelectorAll("pluto-cell .cm-content")].map((el) => {
    const copy = el.cloneNode(true);
    copy.querySelectorAll(".cm-placeholder").forEach((p) => p.remove());
    return copy.textContent;
  }));
  // Each cell first shows a static copy of its code (.cm-ssr-fake), and
  // the real editor replaces it once the cell scrolls into view. Tabbing
  // before that lands in copies that are about to go (#392).
  await page.waitForFunction(() => !document.querySelector("pluto-input .cm-ssr-fake"));
  const before = await local();

  const visited = new Set();
  for (let i = 0; i < 40; i++) {
    await page.keyboard.press("Tab");
    const f = await focused(page);
    if (f.cm_content) visited.add(f.cell);
  }
  assert.ok(visited.size >= 3, `Tab went through several cells' code: ${[...visited]}`);
  assert.deepEqual(await local(), before, "no cell's code changed");
  assert.equal(await page.locator("pluto-cell.code_differs").count(), 0, "no cell is marked edited");
  // Shift+Tab goes back the same way.
  for (let i = 0; i < 10; i++) await page.keyboard.press("Shift+Tab");
  assert.deepEqual(await local(), before, "Shift+Tab didn't change code either");

  // Clicked into: Tab indents.
  const a = page.locator(`${cellSelector("A")} .cm-editor:not(.cm-ssr-fake) .cm-content`);
  await page.locator(cellSelector("A")).scrollIntoViewIfNeeded();
  await a.click();
  await page.keyboard.press("Home");
  await page.keyboard.press("Tab");
  await page.waitForFunction(() => document.querySelector('pluto-cell[id="A"]').classList.contains("code_differs"));
  assert.match(await a.textContent(), /^\s+x <- 1:10/, "Tab indented A after a click");
  assert.equal((await focused(page)).cell, "A", "and focus stayed in A");

  // Entered with Enter on a selected cell: Tab indents.
  await page.keyboard.press("Escape");
  await page.keyboard.press("ArrowDown");
  const f = await focused(page);
  assert.equal(f.tag, "pluto-cell");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Home");
  await page.keyboard.press("Tab");
  await page.waitForFunction((id) => document.querySelector(`pluto-cell[id="${id}"]`).classList.contains("code_differs"), f.cell);
  assert.equal((await focused(page)).cell, f.cell, "Tab indented the cell Enter went into");

  // Arrowed down into the next cell's code: Tab indents there too.
  const next = await page.evaluate((id) => document.getElementById(id).nextElementSibling.id, f.cell);
  await page.keyboard.press("End");
  await page.keyboard.press("ArrowDown");
  await page.waitForFunction((id) => document.activeElement?.closest("pluto-cell")?.id === id, next);
  await page.keyboard.press("Home");
  await page.keyboard.press("Tab");
  await page.waitForFunction((id) => document.querySelector(`pluto-cell[id="${id}"]`).classList.contains("code_differs"), next);
  assert.equal((await focused(page)).cell, next, "Tab indented the cell ArrowDown went into");

  // Away to another window and back: still working there, so Tab indents.
  const content_sel = `${cellSelector(next)} .cm-editor:not(.cm-ssr-fake) .cm-content`;
  const content = page.locator(content_sel);
  const text = await content.textContent();
  // How long it is away doesn't matter: what the blur starts is a 0 ms
  // timer at most (CellInput.js), done once one has run after it.
  await content.evaluate((el) => {
    el.dispatchEvent(new FocusEvent("blur", { relatedTarget: null }));
    return new Promise((resolve) => setTimeout(resolve, 0));
  });
  await content.evaluate((el) => el.dispatchEvent(new FocusEvent("focus", { relatedTarget: null })));
  await page.keyboard.press("Tab");
  assert.equal((await focused(page)).cell, next, "Tab after coming back stayed in the cell");
  await page.waitForFunction(([sel, t]) => document.querySelector(sel).textContent !== t,
    [content_sel, text]);

  assert.equal(fs.readFileSync(notebook, "utf8"), on_disk, "nothing was saved: the edits were never run");
  assertNoProblems(page);
});

test("keyboard: Backspace on a selected cell selects the next one, or the one above the last; Undo selects it again (166)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "keyboard-delete.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const state = () => page.evaluate(() => ({
    focus: document.activeElement?.matches("pluto-cell") ? document.activeElement.id : document.activeElement?.tagName.toLowerCase(),
    selected: window.editor_state.selected_cells,
    order: window.editor_state.notebook.cell_order,
  }));
  const settled = (focus) => waitingFor(`focus moves to ${focus}`, page.waitForFunction((focus) => document.activeElement?.id === focus, focus), state);
  // The neighbour is selected as soon as a delete starts (#353), before the
  // notebook's order changes, so wait for the order as well.
  const orderIs = (order) => waitingFor(`the order becomes ${order.join(", ")}`, page.waitForFunction((order) => window.editor_state.notebook.cell_order.join() === order.join(), order), state);
  const select = async (id) => {
    await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
    await page.evaluate((id) => document.getElementById(id).focus(), id);
    await page.evaluate((id) => window.editor_state_set({ selected_cells: [id] }), id);
  };

  // The cell deleted and brought back is one added here, with a UUID id;
  // disabled.test.mjs undoes the delete of a cell with a short id ("A").
  await page.locator(`${cellSelector("ERR")} button.add_cell.before`).click();
  await page.waitForFunction(() => window.editor_state.notebook.cell_order.length === 7);
  const added = (await state()).order[3];
  await page.waitForFunction((id) => document.activeElement?.matches(`pluto-cell[id="${id}"] .cm-content`) ?? false, added);
  await page.keyboard.press("Escape");
  await settled(added);
  await page.keyboard.press("Backspace");
  await settled("ERR");
  await orderIs(["S", "A", "B", "ERR", "LOOP", "MD"]);
  assert.deepEqual(await state(), { focus: "ERR", selected: ["ERR"], order: ["S", "A", "B", "ERR", "LOOP", "MD"] });

  await page.locator("#undo_delete a").click();
  await settled(added);
  await orderIs(["S", "A", "B", added, "ERR", "LOOP", "MD"]);
  assert.deepEqual(await state(), { focus: added, selected: [added], order: ["S", "A", "B", added, "ERR", "LOOP", "MD"] });

  await select("MD");
  await page.keyboard.press("Backspace");
  await settled("LOOP");
  await orderIs(["S", "A", "B", added, "ERR", "LOOP"]);
  assert.deepEqual(await state(), { focus: "LOOP", selected: ["LOOP"], order: ["S", "A", "B", added, "ERR", "LOOP"] });
  assertNoProblems(page);
});

test("focus ring: 2 px accent outline 2 px out on keyboard focus, none after a click (167)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "keyboard-167.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  for (let i = 0; i < 30; i++) {
    await page.keyboard.press("Tab");
    if (await page.evaluate(() => document.activeElement?.matches("button.toggle_export"))) break;
  }
  const ring = () => page.evaluate(() => {
    const button = document.querySelector("button.toggle_export");
    const probe = document.createElement("span");
    probe.style.color = "var(--ember-accent)";
    document.body.append(probe);
    const accent = getComputedStyle(probe).color;
    probe.remove();
    const s = getComputedStyle(button);
    return { focused: document.activeElement === button, style: s.outlineStyle, width: s.outlineWidth, color: s.outlineColor, offset: s.outlineOffset, accent };
  });
  const keyboard = await ring();
  assert.ok(keyboard.focused, "Tab reaches the Export button");
  assert.deepEqual(
    [keyboard.style, keyboard.width, keyboard.color, keyboard.offset],
    ["solid", "2px", keyboard.accent, "2px"]);

  // Opens the menu, then closes it; the menu hands focus back to the button.
  await page.locator("button.toggle_export").click();
  await page.waitForSelector("[role=menu]");
  await page.locator("button.toggle_export").click();
  await page.waitForSelector("[role=menu]", { state: "detached" });
  const mouse = await ring();
  assert.ok(mouse.focused, "the button keeps focus after the click");
  assert.equal(mouse.style, "none");
  assertNoProblems(page);
});

// #366: the cell menu focused its first item a frame after opening, so a
// key pressed in between went to the menu button and was lost. Frames are
// slowed here so "in between" is wide enough to land in every time.
test("cell menu: keys pressed right after it opens by keyboard aren't lost, even when frames are slow (#366)", async (t) => {
  const notebook = tempNotebook("basic.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "menu-keys.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.addInitScript(() => {
    const raf = window.requestAnimationFrame.bind(window);
    window.requestAnimationFrame = (cb) => raf((time) => setTimeout(() => cb(time), 150));
  });
  await openNotebook(page, server.origin, server.secret, notebook);

  const first = await page.evaluate(() => window.editor_state.notebook.cell_order[0]);
  await page.locator(`pluto-cell[id="${first}"] button.input_context_menu`).focus();
  // Open, go to the last item (Delete) and pick it, with no wait between.
  await page.keyboard.press("Enter");
  await page.keyboard.press("End");
  await page.keyboard.press("Enter");
  await page.locator(`pluto-cell[id="${first}"]`).waitFor({ state: "detached" });

  assertNoProblems(page);
});

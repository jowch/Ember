// The keyboard path and the focus ring, tests 166 and 167 of
// docs/ui-3-tests.md (piece 7e).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

const mac = process.platform === "darwin";

/** The websocket messages `page` sends whose bytes include `type`, as a
 * list that grows while the page runs. msgpack keeps a short string's
 * UTF-8 bytes as they are, so the message type's name shows up verbatim. */
function sentMessages(page, type) {
  const seen = [];
  page.on("websocket", (ws) => {
    ws.on("framesent", (frame) => {
      const payload = frame.payload ?? "";
      const text = Buffer.isBuffer(payload) ? payload.toString("latin1") : String(payload);
      let found = text.includes(type);
      if (!found && !Buffer.isBuffer(payload)) {
        try { found = Buffer.from(text, "base64").toString("latin1").includes(type); } catch { /* not base64 */ }
      }
      if (found) seen.push(Date.now());
    });
  });
  return seen;
}

/** Click into cell `id`'s code, Esc to select the cell, Enter to go back to the code. */
async function reenterCode(page, id) {
  await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
  await page.locator(`${cellSelector(id)} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.keyboard.press("Escape");
  await page.waitForFunction((id) => document.activeElement === document.getElementById(id), id, { timeout: 5000 });
  await page.keyboard.press("Enter");
  await page.waitForFunction((id) => document.activeElement?.matches(`pluto-cell[id="${id}"] .cm-content`) ?? false, id, { timeout: 5000 });
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
  }, [order[1], want], { timeout: 3000 });
  await controls([true, true]);
  await page.keyboard.press("Escape");
  await controls([false, false]);
  await page.keyboard.press("Tab");
  await controls([true, false]);
  f = await focused(page);
  assert.deepEqual([f.tag, f.cell, f.label], ["button", order[1], "Run cell (Shift + Enter)"]);

  await page.getByRole("button", { name: "Help", exact: true }).click();
  await page.waitForSelector("#helpbox-wrapper.open", { timeout: 5000 });
  await page.waitForFunction(() => document.activeElement?.closest("#helpbox-wrapper") != null, null, { timeout: 5000 });
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => !document.querySelector("#helpbox-wrapper").classList.contains("open"), null, { timeout: 5000 });
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
  }, null, { timeout: 30000 });
  await page.waitForTimeout(500);
  assert.equal(runs.length - runs_before, 1, "Shift + Enter in the code sends one run");

  await reenterCode(page, "B");
  const before_move = await page.evaluate(() => window.editor_state.notebook.cell_order);
  const moved = before_move.filter((id) => id !== "B");
  moved.splice(before_move.indexOf("B") + 1, 0, "B");
  await page.keyboard.press("Alt+ArrowDown");
  await page.waitForFunction((before) => JSON.stringify(window.editor_state.notebook.cell_order) !== JSON.stringify(before), before_move, { timeout: 5000 });
  await page.waitForTimeout(500);
  assert.deepEqual(await page.evaluate(() => window.editor_state.notebook.cell_order), moved, "Alt + ↓ moves the cell one place");

  // A selection left on another cell: the fold key in the code folds only this one.
  await page.locator(cellSelector("ERR")).scrollIntoViewIfNeeded();
  await page.locator(`${cellSelector("ERR")} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.evaluate(() => window.editor_state_set({ selected_cells: ["A"] }));
  await page.keyboard.press(mac ? "Meta+Alt+BracketLeft" : "Control+Shift+BracketLeft");
  await page.waitForFunction(() => window.editor_state.notebook.cell_inputs.ERR.code_folded, null, { timeout: 5000 });
  await page.waitForTimeout(500);
  assert.deepEqual(await page.evaluate(() => ["A", "ERR"].map((id) => window.editor_state.notebook.cell_inputs[id].code_folded)), [false, true]);
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
  const settled = (focus) => page.waitForFunction((focus) => document.activeElement?.id === focus, focus, { timeout: 5000 }).catch(() => {});
  const select = async (id) => {
    await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
    await page.evaluate((id) => document.getElementById(id).focus(), id);
    await page.evaluate((id) => window.editor_state_set({ selected_cells: [id] }), id);
  };

  // Undo re-inserts the cell, and an inserted cell's id has to be a UUID,
  // so the cell deleted and brought back is one added here.
  await page.locator(`${cellSelector("ERR")} button.add_cell.before`).click();
  await page.waitForFunction(() => window.editor_state.notebook.cell_order.length === 7, null, { timeout: 10000 });
  const added = (await state()).order[3];
  await page.waitForFunction((id) => document.activeElement?.matches(`pluto-cell[id="${id}"] .cm-content`) ?? false, added, { timeout: 5000 });
  await page.keyboard.press("Escape");
  await settled(added);
  await page.keyboard.press("Backspace");
  await settled("ERR");
  assert.deepEqual(await state(), { focus: "ERR", selected: ["ERR"], order: ["S", "A", "B", "ERR", "LOOP", "MD"] });

  await page.locator("#undo_delete a").click();
  await settled(added);
  assert.deepEqual(await state(), { focus: added, selected: [added], order: ["S", "A", "B", added, "ERR", "LOOP", "MD"] });

  await select("MD");
  await page.keyboard.press("Backspace");
  await settled("LOOP");
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
  await page.waitForSelector("[role=menu]", { timeout: 5000 });
  await page.locator("button.toggle_export").click();
  await page.waitForSelector("[role=menu]", { state: "detached", timeout: 5000 });
  const mouse = await ring();
  assert.ok(mouse.focused, "the button keeps focus after the click");
  assert.equal(mouse.style, "none");
  assertNoProblems(page);
});

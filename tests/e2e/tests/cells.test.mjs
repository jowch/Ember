// ui-3-tests.md, piece 6a steps 2-4 (ui-3-plan.md): the rail, the run/stop
// button and run-time chip, the cell menu, the "+" overlay and the empty
// notebook's hints.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, runCell, cellSelector } from "../browser.mjs";

test("rail: idle before running, amber when edited, red on error (140)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-rail.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  for (const id of ["S", "A", "B", "ERR", "LOOP"]) {
    assert.equal(await page.locator(cellSelector(id)).getAttribute("data-rail"), "idle", `${id} starts idle`);
  }

  await page.locator(`${cellSelector("B")} .cm-content`).click();
  await page.keyboard.type(" ", { delay: 2 });
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "due",
    cellSelector("B"), { timeout: 10000 });

  await page.hover(`${cellSelector("B")} pluto-trafficlight`);
  await page.waitForSelector(`${cellSelector("B")} ember-rail-tip`, { state: "visible", timeout: 5000 });
  assert.match(await page.locator(`${cellSelector("B")} ember-rail-tip`).innerText(), /Shift \+ Enter/);

  await runCell(page, "ERR");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "err",
    cellSelector("ERR"), { timeout: 15000 });

  assertNoProblems(page);
});

test("run/stop button and run time (141)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-run.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("A"));
  const runButton = page.locator(`${cellSelector("A")} button.ember-run`);
  assert.equal(await runButton.getAttribute("aria-label"), "Run cell (Shift + Enter)");
  await runButton.click();
  await page.waitForFunction(
    (sel) => /^\d+(\.\d+)? s$|min/.test(document.querySelector(sel)?.innerText ?? ""),
    cellSelector("A") + " ember-runtime", { timeout: 15000 });

  await runCell(page, "LOOP");
  await page.waitForSelector(`${cellSelector("LOOP")}.running`, { timeout: 15000 });
  await page.hover(cellSelector("LOOP"));
  const stopButton = page.locator(`${cellSelector("LOOP")} button.ember-run`);
  assert.equal(await stopButton.getAttribute("aria-label"), "Stop (Ctrl + Q)");
  await stopButton.click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Interrupted"),
    cellSelector("LOOP") + " pluto-output", { timeout: 15000 });

  assertNoProblems(page);
});

test("cell menu: item order, move down, hide code, no Disable on the setup cell (142)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-menu.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("S"));
  await page.locator(`${cellSelector("S")} button.input_context_menu`).click();
  assert.equal(await page.locator(`${cellSelector("S")} button.input_context_menu`).getAttribute("aria-label"), "Cell options");
  assert.equal(await page.locator(`${cellSelector("S")} button.disable_cell`).count(), 0, "the setup cell's menu has no Disable cell");
  await page.keyboard.press("Escape");

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  const tags = await page.locator(`${cellSelector("A")} div.input_context_menu[role="menu"] button[role="menuitem"]`).evaluateAll(
    (btns) => btns.map((b) => b.className.split(" ").find((c) => !["ember-menuitem", "ember-menuitem-danger", ""].includes(c))));
  assert.deepEqual(tags, ["hide_code", "disable_cell", "move_up", "move_down", "delete"]);
  await page.keyboard.press("Escape");

  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  await page.locator(`${cellSelector("A")} button.move_down`).click();
  await page.waitForFunction(
    () => {
      const order = window.editor_state.notebook.cell_order;
      return order.indexOf("A") > order.indexOf("B");
    },
    null, { timeout: 10000 });

  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  const hideItem = page.locator(`${cellSelector("B")} button.hide_code`);
  assert.equal(await hideItem.innerText(), "Hide code");
  await hideItem.click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.classList.contains("code_folded"),
    cellSelector("B"), { timeout: 10000 });

  assertNoProblems(page);
});

test('"+": hovering the gap shows the line and circle without moving cells; clicking adds a cell (143)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-add.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const addAfterA = page.locator(`${cellSelector("A")} button.add_cell.after`);
  const beforeTop = (await page.locator(cellSelector("B")).boundingBox()).y;

  await addAfterA.hover();
  await page.waitForFunction(
    (sel) => getComputedStyle(document.querySelector(sel).querySelector("span")).opacity > 0,
    `${cellSelector("A")} button.add_cell.after`, { timeout: 5000 });

  const afterTop = (await page.locator(cellSelector("B")).boundingBox()).y;
  assert.equal(beforeTop, afterTop, "hovering the \"+\" doesn't move B");

  const cellCountBefore = await page.locator("pluto-cell").count();
  await addAfterA.click();
  await page.waitForFunction(
    (before) => document.querySelectorAll("pluto-cell").length > before,
    cellCountBefore, { timeout: 10000 });

  const order = await page.evaluate(() => window.editor_state.notebook.cell_order);
  assert.equal(order.indexOf("A") + 1 < order.indexOf("B"), true, "the new cell landed between A and B");

  assertNoProblems(page);
});

test("Endeavor's hooks after piece 6a (extends ui-2-tests.md 12) (152)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-hooks.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForSelector(`${cellSelector("A")} > pluto-output`, { state: "attached", timeout: 15000 });

  assert.ok(await page.locator(`${cellSelector("A")} > pluto-trafficlight`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("A")} > pluto-output`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("A")} pluto-shoulder > button.foldcode`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("A")} button.add_cell.before`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("A")} button.add_cell.after`).count() > 0);

  await setCellCode(page, "A", "x <- 1");
  await runCell(page, "ERR");
  await page.waitForSelector(`${cellSelector("ERR")}.errored`, { timeout: 15000 });
  assert.ok(await page.locator(`${cellSelector("ERR")} jlerror > header`).count() > 0);

  await page.locator(`${cellSelector("B")} .cm-content`).click();
  await page.keyboard.type(" ", { delay: 2 });
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.classList.contains("code_differs"),
    cellSelector("B"), { timeout: 10000 });

  assertNoProblems(page);
});

test("argument tooltips close when the cursor leaves their cell (design-gaps.md, alongside 152)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-tooltip.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  await page.locator(`${cellSelector("A")} .cm-content`).click();
  await page.keyboard.press("End");
  await page.keyboard.type("; mean(", { delay: 10 });
  await page.waitForSelector(".cm-ember-signature-tooltip", { timeout: 5000 });

  // Clicking into a different cell moves the cursor out of A entirely:
  // the tooltip must not be left floating over B.
  await page.locator(`${cellSelector("B")} .cm-content`).click();
  await page.waitForFunction(
    () => document.querySelector(".cm-ember-signature-tooltip") == null,
    null, { timeout: 2000 });

  assertNoProblems(page);
});

test("empty notebook: placeholder and hints show, and typing removes them (151)", async (t) => {
  // Not a notebook made fresh from the start page: new_notebook() (R/api.R)
  // gives that one a setup cell plus this one, two cells, so
  // cell_order.length never reaches the 1 this hinges on. This fixture is
  // the "one cell, nothing typed yet" shape the board actually shows.
  const notebook = tempNotebook("empty.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-empty.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "platform", { get: () => "MacIntel" });
  });
  await openNotebook(page, server.origin, server.secret, notebook);

  const placeholder = await page.locator("pluto-cell .cm-placeholder").first().innerText();
  assert.equal(placeholder, "Type R code here");
  assert.match(await page.locator("ember-empty-hints").innerText(), /⌘/, "Mac modifier shown in the hints");

  await page.locator("pluto-cell .cm-content").click();
  await page.keyboard.type("1 + 1", { delay: 2 });
  await page.waitForFunction(
    () => document.querySelectorAll("ember-empty-hints").length === 0,
    null, { timeout: 10000 });

  assertNoProblems(page);
});

test('chips: "Not run yet" before running, none in safe preview, "Stale" after an upstream edit (144)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-safe.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // Safe preview: B has never run, but it's not shown yet.
  assert.equal(await page.locator(`${cellSelector("B")} ember-chip`).count(), 0, "no chip in safe preview");

  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  // B just ran: no chip now that it has output.
  assert.equal(await page.locator(`${cellSelector("B")} ember-chip`).count(), 0);

  assertNoProblems(page);
});

test('chips: a never-run cell shows "Not run yet" with no output (144)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-notrun.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  // A fresh cell with code typed but not yet submitted: has never run,
  // unlike every existing cell in the fixture by now.
  const cellCountBefore = await page.locator("pluto-cell").count();
  await page.locator(`${cellSelector("B")} .cm-content`).click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+Enter" : "Control+Enter");
  await page.waitForFunction(
    (before) => document.querySelectorAll("pluto-cell").length > before,
    cellCountBefore, { timeout: 15000 });
  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "B");
  const newSel = `pluto-cell[id="${newCellId}"]`;

  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("1 + 1", { delay: 2 });
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.classList.contains("not_run_yet"),
    newSel, { timeout: 10000 });
  assert.equal(await page.locator(`${newSel} ember-chip`).innerText(), "Not run yet");
  assert.equal(await page.locator(`${newSel} pluto-output`).innerText(), "");

  assertNoProblems(page);
});

test('chips: "Stale · x changed" after an upstream edit in lazy mode, with a greyed output (144)', async (t) => {
  const notebook = tempNotebook("lazy.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-stale.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  await setCellCode(page, "A", "x <- 2");
  await runCell(page, "A");
  await page.waitForSelector(`${cellSelector("B")}.stale`, { timeout: 20000 });
  // The chip's text depends on A's own run having landed (its new
  // last_run_timestamp), which can arrive just after the "stale" class
  // itself, so wait for the names, not only the class.
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText === "Stale · x changed",
    cellSelector("B") + " ember-chip", { timeout: 10000 });
  assert.equal(await page.locator(`${cellSelector("B")} pluto-output`).evaluate((el) => getComputedStyle(el).filter), "grayscale(1)");

  assertNoProblems(page);
});

test("disabled states: A shows Disabled with no run button; B shows Depends on a disabled cell, and Go to it focuses A (149)", async (t) => {
  const notebook = tempNotebook("disabled.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-disabled-chips.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  await page.hover(cellSelector("A"));
  await page.locator(`${cellSelector("A")} button.input_context_menu`).click();
  await page.locator(`${cellSelector("A")} button.disable_cell`).click();
  await page.waitForSelector(`${cellSelector("A")}.running_disabled`, { timeout: 15000 });

  assert.equal(await page.locator(`${cellSelector("A")} ember-chip`).innerText(), "Disabled");
  assert.equal(await page.locator(`${cellSelector("A")} button.ember-run`).count(), 0, "no run button on a disabled cell");
  assert.equal(await page.locator(`${cellSelector("A")} ember-chip`).count(), 1, "no \"Not run yet\" chip either");

  await page.waitForSelector(`${cellSelector("B")}.depends_on_disabled_cells`, { timeout: 15000 });
  const bChip = page.locator(`${cellSelector("B")} ember-chip`);
  assert.match(await bChip.innerText(), /Depends on a disabled cell\..*Go to it/s);
  assert.equal(await page.locator(`${cellSelector("B")} ember-chip`).count(), 1, "B has no \"Not run yet\" chip either");

  await bChip.locator("a").click();
  await page.waitForFunction(
    (sel) => document.activeElement?.closest(sel) != null,
    cellSelector("A"), { timeout: 10000 });

  assertNoProblems(page);
});

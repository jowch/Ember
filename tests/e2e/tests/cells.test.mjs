// ui-3-tests.md, piece 6a steps 2-4 (ui-3-plan.md): the rail, the run/stop
// button and run-time chip, the cell menu, the "+" overlay and the empty
// notebook's hints.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
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

  const addBeforeB = page.locator(`${cellSelector("B")} button.add_cell.before`);
  const beforeTop = (await page.locator(cellSelector("B")).boundingBox()).y;

  await addBeforeB.hover();
  await page.waitForFunction(
    (sel) => getComputedStyle(document.querySelector(sel).querySelector("span")).opacity > 0,
    `${cellSelector("B")} button.add_cell.before`, { timeout: 5000 });

  const afterTop = (await page.locator(cellSelector("B")).boundingBox()).y;
  assert.equal(beforeTop, afterTop, "hovering the \"+\" doesn't move B");

  const cellCountBefore = await page.locator("pluto-cell").count();
  await addBeforeB.click();
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

test("argument tooltips: a reply that arrives after blur (worker busy) doesn't reopen one (design-gaps.md)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-tooltip-slow.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });

  // Start LOOP (Sys.sleep(3)) running, so the docs request from typing
  // in A below queues behind a busy worker instead of answering at once.
  await runCell(page, "LOOP");
  await page.waitForSelector(`${cellSelector("LOOP")}.running`, { timeout: 15000 });

  await page.locator(`${cellSelector("A")} .cm-content`).click();
  await page.keyboard.press("End");
  await page.keyboard.type("; mean(1:3", { delay: 10 });
  await page.waitForTimeout(300); // past the 150ms debounce: the request is now in flight

  // Move to a different cell well before LOOP (and so the queued
  // request) can finish.
  await page.locator(`${cellSelector("B")} .cm-content`).click();

  // Give LOOP, and the request behind it, time to finish and reply.
  await page.waitForFunction(
    (sel) => !document.querySelector(sel)?.classList.contains("running"),
    cellSelector("LOOP"), { timeout: 10000 });
  await page.waitForTimeout(1000);

  assert.equal(await page.locator(".cm-ember-signature-tooltip").count(), 0, "no tooltip reopened over B");

  assertNoProblems(page);
});

test("empty notebook: placeholder and hints show, and typing removes them (151)", async (t) => {
  // A real new notebook (new_notebook(), R/api.R) has two empty cells
  // (setup, then one code cell), not one -- made through the start page,
  // like a person actually gets there.
  const dir = mkdtempSync(path.join(tmpdir(), "ember-e2e-empty-"));
  const server = await startServer([], { cwd: dir, logFile: path.join(artifactsDir(), "cells-empty.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // navigator.userAgentData, when present (every Chromium here, including
  // CI's Linux runners), wins over navigator.platform in is_mac_keyboard
  // (KeyboardShortcuts.js); both need overriding or the Mac assertion
  // below only passes by accident of which OS runs the test.
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "platform", { get: () => "MacIntel" });
    Object.defineProperty(navigator, "userAgentData", { get: () => ({ platform: "macOS" }) });
  });
  await page.goto(server.url);

  await page.locator(".ember-start-new-btn").click();
  const nameField = page.locator("#ember-start-new-name");
  await nameField.click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await page.keyboard.type("empty");
  await page.getByRole("button", { name: "Create", exact: true }).click();
  await page.waitForURL(/edit\?id=/, { timeout: 10000 });
  await page.waitForSelector("pluto-cell", { timeout: 15000 });

  assert.equal(await page.locator("pluto-cell").count(), 2, "a new notebook has a setup cell and one code cell");
  const placeholder = await page.locator("pluto-cell .cm-placeholder").first().innerText();
  assert.equal(placeholder, "Type R code here");
  assert.match(await page.locator("ember-empty-hints").innerText(), /⌘/, "Mac modifier shown in the hints");

  await page.locator("pluto-cell:last-of-type .cm-content").click();
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

test('chips: NEVER (loaded with code, never run) shows "Not run yet" with no output (144)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-notrun.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  // Running A alone (not the safe-preview bar's "Run this notebook", which
  // runs the whole file) starts R without ever reaching NEVER, which has
  // no connection to A: its code comes straight from the file on disk,
  // read but not yet run -- the "Not run yet" chip must read that remote
  // code, not local state, since nothing here has been typed at all.
  await runCell(page, "A");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.classList.contains("not_run_yet"),
    cellSelector("NEVER"), { timeout: 20000 });
  assert.equal(await page.locator(`${cellSelector("NEVER")} ember-chip`).innerText(), "Not run yet");
  assert.equal(await page.locator(`${cellSelector("NEVER")} pluto-output`).innerText(), "");

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

// Geometry from the Cells and Insert5 boards (ui-3.md "Cell anatomy",
// "Run button", "Cell menu", "Adding cells").

const rect = (page, sel) => page.locator(sel).evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
});
const near = (actual, expected, what) => assert.ok(Math.abs(actual - expected) < 0.6, `${what}: ${actual}, expected ${expected}`);

test("geometry: 26px between cells; a one-line code box is 7px 12px around 13px/1.65 text, after a 34px gutter", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-box.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.waitForSelector(`${cellSelector("A")} .cm-editor`);

  const a = await rect(page, cellSelector("A"));
  const b = await rect(page, cellSelector("B"));
  near(b.top - a.bottom, 26, "gap between A and B");

  const box = await rect(page, `${cellSelector("A")} .cm-editor`);
  const gutters = await rect(page, `${cellSelector("A")} .cm-gutters`);
  near(box.height, 7 + 13 * 1.65 + 7, "one-line code box height");
  near(gutters.width, 34, "gutter width");

  const content = await page.locator(`${cellSelector("A")} .cm-content`).evaluate((el) => {
    const cs = getComputedStyle(el);
    const range = document.createRange();
    range.selectNodeContents(el.querySelector(".cm-line"));
    return { padding: cs.padding, fontSize: cs.fontSize, lineHeight: cs.lineHeight, textLeft: range.getBoundingClientRect().left };
  });
  assert.equal(content.padding, "7px 12px");
  assert.equal(content.fontSize, "13px");
  assert.equal(content.lineHeight, "21.45px");
  near(content.textLeft - gutters.right, 12, "code text starts 12px right of the gutter");

  assertNoProblems(page);
});

test("geometry: the run button sits on the code box's top-left corner and gives way to the \"+\" above it", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-run.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // A has no output, so its code box starts at the cell's top, right under
  // the gap's "+".
  await page.hover(`${cellSelector("A")} .cm-content`);
  const run = page.locator(`${cellSelector("A")} button.ember-run`);
  await page.waitForFunction((el) => getComputedStyle(el).opacity === "1", await run.elementHandle(), { timeout: 5000 });
  const box = await rect(page, `${cellSelector("A")} .cm-editor`);
  const button = await rect(page, `${cellSelector("A")} button.ember-run`);
  near(button.left - box.left, -15, "run button left");
  near(button.top - box.top, -13, "run button top");

  const strip = await rect(page, `${cellSelector("A")} button.add_cell.before`);
  await page.mouse.move(strip.left + 300, strip.top + strip.height / 2);
  const circle = `${cellSelector("A")} button.add_cell.before > span`;
  await page.waitForFunction((sel) => getComputedStyle(document.querySelector(sel)).opacity === "1", circle, { timeout: 5000 });
  await page.waitForFunction((el) => getComputedStyle(el).opacity === "0", await run.elementHandle(), { timeout: 5000 });

  // Insert5: the circle is centred on the gap, its left edge 11px left of the rail.
  const c = await rect(page, circle);
  const rail = await rect(page, `${cellSelector("A")} > pluto-trafficlight`);
  near(c.left - rail.left, -11, "circle left");
  near(c.top + c.height / 2, strip.top + strip.height / 2, "circle centre");

  // The circle's lower half is where the run button would be: it must be
  // the "+" that takes a click there.
  const hit = await page.evaluate(([x, y]) => {
    const el = document.elementFromPoint(x, y);
    return el?.closest("button")?.className ?? null;
  }, [c.left + c.width / 2, c.bottom - 3]);
  assert.equal(hit, "add_cell before");

  assertNoProblems(page);
});

test('"+": each gap\'s live button is the lower cell\'s .before, and the last cell\'s .after below it (Endeavor)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-plus.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const ids = await page.evaluate(() => [...document.querySelectorAll("pluto-cell")].map((c) => c.id));
  for (const id of ids) {
    assert.equal(await page.locator(`${cellSelector(id)} > button.add_cell.before`).count(), 1, `${id} keeps .before`);
    assert.equal(await page.locator(`${cellSelector(id)} > button.add_cell.after`).count(), 1, `${id} keeps .after`);
  }

  const owner = (x, y) => page.evaluate(([x, y]) => {
    const b = document.elementFromPoint(x, y)?.closest("button.add_cell");
    return b ? `${b.closest("pluto-cell").id} ${b.className}` : null;
  }, [x, y]);

  for (let i = 1; i < ids.length; i++) {
    const above = await rect(page, cellSelector(ids[i - 1]));
    const below = await rect(page, cellSelector(ids[i]));
    assert.equal(await owner(above.left + 300, (above.bottom + below.top) / 2), `${ids[i]} add_cell before`, `gap above ${ids[i]}`);
  }
  const last = ids[ids.length - 1];
  const lastRect = await rect(page, cellSelector(last));
  assert.equal(await owner(lastRect.left + 300, lastRect.bottom + 13), `${last} add_cell after`, "below the last cell");

  assertNoProblems(page);
});

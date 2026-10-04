// ui-3-tests.md, piece 6a steps 2-4 (ui-3-plan.md): the rail, the run/stop
// button and run-time chip, the cell menu, the "+" overlay and the empty
// notebook's hints.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, runCell, cellSelector } from "../browser.mjs";

const rect = (page, sel) => page.locator(sel).evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
});
const near = (actual, expected, what) => assert.ok(Math.abs(actual - expected) < 0.6, `${what}: ${actual}, expected ${expected}`);

// A theme token as the browser computes it, for comparing with a computed
// background.
const tokenColor = (page, name) => page.evaluate((name) => {
  const probe = document.createElement("div");
  probe.style.backgroundColor = `var(${name})`;
  document.body.append(probe);
  const color = getComputedStyle(probe).backgroundColor;
  probe.remove();
  return color;
}, name);
const computed = (page, sel, prop) => page.locator(sel).evaluate((el, prop) => getComputedStyle(el)[prop], prop);
// The rail's colour transitions, so wait for it to arrive before comparing.
const settledStyle = async (page, sel, prop, expected, what = `${sel} ${prop}`) => {
  await page.waitForFunction(
    ([sel, prop, expected]) => getComputedStyle(document.querySelector(sel))[prop] === expected,
    [sel, prop, expected], { timeout: 2000 }).catch(() => {});
  assert.equal(await computed(page, sel, prop), expected, what);
};

test("rail: idle before running, amber when edited, red on error, blue while running or queued (140)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-rail.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const rail = (id) => `${cellSelector(id)} > pluto-trafficlight`;

  const idle = await tokenColor(page, "--ember-rail-idle");
  for (const id of ["S", "A", "B", "ERR", "LOOP", "NEVER"]) {
    assert.equal(await page.locator(cellSelector(id)).getAttribute("data-rail"), "idle", `${id} starts idle`);
    assert.equal(await computed(page, rail(id), "backgroundColor"), idle, `${id}'s rail is --ember-rail-idle`);
  }

  await page.locator(`${cellSelector("B")} .cm-content`).click();
  await page.keyboard.type(" ", { delay: 2 });
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "due",
    cellSelector("B"), { timeout: 10000 });
  await settledStyle(page, rail("B"), "backgroundColor", await tokenColor(page, "--ember-rail-due"));
  await settledStyle(page, `${cellSelector("B")} .cm-gutters`, "backgroundColor", await tokenColor(page, "--ember-due-bg"));

  // The tip belongs to the rail alone: not to hovering or focusing the
  // rest of the cell.
  const tip = page.locator(`${cellSelector("B")} ember-rail-tip`);
  await page.locator(`${cellSelector("A")} .cm-content`).click();
  await page.hover(`${cellSelector("B")} .cm-content`);
  assert.equal(await tip.isVisible(), false, "no tip while hovering B's code");
  await page.hover(rail("B"));
  await tip.waitFor({ state: "visible", timeout: 5000 });
  assert.equal(await tip.innerText(), "Press Shift + Enter to run this cell");
  await page.locator(`${cellSelector("B")} .cm-content`).click();
  assert.equal(await tip.isVisible(), false, "no tip once the pointer leaves the rail, with B focused");

  await runCell(page, "ERR");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "err",
    cellSelector("ERR"), { timeout: 15000 });
  await settledStyle(page, rail("ERR"), "backgroundColor", await tokenColor(page, "--ember-rail-err"));

  await setCellCode(page, "LOOP", "Sys.sleep(8)");
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "run",
    cellSelector("LOOP"), { timeout: 15000 });
  await runCell(page, "NEVER");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "queued",
    cellSelector("NEVER"), { timeout: 5000 });
  const blue = await tokenColor(page, "--ember-rail-run");
  await settledStyle(page, rail("LOOP"), "backgroundColor", blue);
  await settledStyle(page, rail("NEVER"), "backgroundColor", blue);
  assert.equal(await computed(page, rail("NEVER"), "opacity"), "0.4");

  assert.equal(await computed(page, rail("LOOP"), "animationName"), "ember-rail-pulse");
  await page.emulateMedia({ reducedMotion: "reduce" });
  assert.equal(await computed(page, rail("LOOP"), "animationName"), "none", "a running rail is solid under reduced motion");
  assert.equal(await computed(page, rail("LOOP"), "opacity"), "1");
  assert.equal(await page.locator(cellSelector("LOOP")).getAttribute("data-rail"), "run", "LOOP still running");

  assertNoProblems(page);
});

test("rail: re-running an unchanged cell goes back to idle, not stuck on queued", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-rerun.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    () => window.editor_state.notebook.cell_results.LOOP?.output?.last_run_timestamp > 0,
    null, { timeout: 30000 });

  const settled = (sel) => {
    const el = document.querySelector(sel);
    return el.getAttribute("data-rail") === "idle" && !el.classList.contains("queued") && !el.classList.contains("running");
  };
  for (const id of ["A", "LOOP"]) {
    await page.waitForFunction(settled, cellSelector(id), { timeout: 10000 });
    const before = await page.evaluate((id) => window.editor_state.notebook.cell_results[id].output.last_run_timestamp, id);
    await runCell(page, id);
    await page.waitForFunction(
      ([id, before]) => window.editor_state.notebook.cell_results[id].output.last_run_timestamp > before,
      [id, before], { timeout: 15000 });
    await page.waitForFunction(settled, cellSelector(id), { timeout: 5000 });
  }

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
  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  assert.equal(await page.locator(`${cellSelector("B")} button.hide_code`).innerText(), "Show code");

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

  await page.waitForFunction(
    (sel) => !document.querySelector(sel)?.matches(".running, .queued"),
    cellSelector("NEVER"), { timeout: 15000 });
  await setCellCode(page, "LOOP", "Sys.sleep(8)");
  await page.keyboard.press("Shift+Enter");
  await page.waitForSelector(`${cellSelector("LOOP")}.running`, { timeout: 15000 });
  await runCell(page, "NEVER");
  await page.waitForSelector(`${cellSelector("NEVER")}.queued:not(.running)`, { timeout: 5000 });
  assert.equal(await page.locator(`${cellSelector("LOOP")}.running`).count(), 1, "LOOP still running while NEVER waits");

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
  // Board Cells: 12px right of the rail and 12px above the code.
  const neverCell = await rect(page, cellSelector("NEVER"));
  const neverRail = await rect(page, `${cellSelector("NEVER")} > pluto-trafficlight`);
  const neverChip = await rect(page, `${cellSelector("NEVER")} > ember-chip`);
  const neverCode = await rect(page, `${cellSelector("NEVER")} .cm-editor`);
  near(neverRail.right, neverCell.left, "the rail ends where the cell starts");
  near(neverChip.left - neverRail.right, 12, "chip to rail");
  near(neverCode.top - neverChip.bottom, 12, "chip to code");
  assert.equal(await page.locator(`${cellSelector("NEVER")} ember-runtime`).count(), 0, "no run-time chip before a first run");
  await page.waitForSelector(`${cellSelector("A")} ember-runtime`, { state: "attached", timeout: 15000 });

  const formatted = await page.evaluate(async () => {
    const src = document.querySelector('script[src$="editor.js"]').src;
    const { format_runtime } = await import(new URL("components/RunButton.js", src).href);
    return [0.04, 9.994, 9.996, 12.4, 59.4, 59.996, 63.2, 119.7, 120].map((s) => format_runtime(s * 1e9));
  });
  assert.deepEqual(formatted, ["0.04 s", "9.99 s", "10 s", "12 s", "59 s", "1 min", "1 min 3 s", "2 min", "2 min"]);

  // A static export (disable_ui) shows no "Not run yet" chip.
  const id = new URL(page.url()).searchParams.get("id");
  const res = await fetch(`${server.origin}notebookexport?id=${id}&secret=${server.secret}`);
  assert.equal(res.status, 200);
  const file = path.join(mkdtempSync(path.join(tmpdir(), "ember-e2e-export-")), "cells.html");
  writeFileSync(file, await res.text(), "utf8");
  const exported = await newPage(browser);
  await exported.goto(`file://${file}`);
  await exported.waitForSelector(`pluto-editor.disable_ui ${cellSelector("NEVER")}.not_run_yet`, { state: "attached", timeout: 15000 });
  assert.equal(await exported.locator(`${cellSelector("NEVER")} ember-chip`).isVisible(), false, "no \"Not run yet\" chip in an export");

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

  // Board "Cells": output, then chip, both on one full-strength wash that
  // runs down to the code box, whose top-right corner goes square.
  const out = await rect(page, `${cellSelector("B")} > pluto-output`);
  const chip = await rect(page, `${cellSelector("B")} > ember-chip`);
  const code = await rect(page, `${cellSelector("B")} .cm-editor`);
  assert.ok(chip.top >= out.bottom, `chip (${chip.top}) under the output (${out.bottom})`);
  const wash = await page.locator(cellSelector("B")).evaluate((el) => {
    const s = getComputedStyle(el, "::before");
    return { bg: s.backgroundColor, height: parseFloat(s.height), radius: s.borderRadius };
  });
  assert.equal(wash.bg, await tokenColor(page, "--ember-wash"));
  near(wash.height, code.top - out.top, "the wash spans output and chip, down to the code box");
  assert.equal(wash.radius, "0px 6px 0px 0px");
  assert.equal(await computed(page, `${cellSelector("B")} > pluto-output`, "backgroundColor"), "rgba(0, 0, 0, 0)", "the faded output has no background of its own");
  assert.equal(await computed(page, `${cellSelector("B")} .cm-editor`, "borderTopRightRadius"), "0px");

  assertNoProblems(page);
});

test("errors: where it happened, a traceback outermost first, labelled by origin; the box joins the code (145)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-errors.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "F");
  await page.waitForFunction(
    () => window.editor_state.notebook.cell_results.F?.output?.last_run_timestamp > 0,
    null, { timeout: 30000 });
  for (const id of ["ERR", "TOP"]) {
    await runCell(page, id);
    await page.waitForSelector(`${cellSelector(id)}.errored jlerror.ember`, { timeout: 20000 });
  }

  const top = `${cellSelector("TOP")} jlerror`;
  assert.equal(await page.locator(`${top} > header > p:first-child`).innerText(), "boom");
  assert.equal(await page.locator(`${top} > header > p.ember-error-where`).innerText(), "Error · line 2");
  assert.equal(await page.locator(`${top} button`).count(), 0, "no traceback button for a top-level stop()");
  assert.equal(await page.locator(`${cellSelector("TOP")} ember-chip`).count(), 0, "no \"Not run yet\" chip on an errored cell");

  const err = `${cellSelector("ERR")} jlerror`;
  assert.equal(await page.locator(`${err} > header > p`).count(), 2, "jlerror > header holds the message, then where it happened");
  assert.equal(await page.locator(`${err} > header > p:first-child`).innerText(), "invalid type (list) for variable 'wt'");
  assert.equal(await page.locator(`${err} > header > p.ember-error-where`).innerText(), "Error in model.frame.default(…) · called from line 1");
  assert.equal(await page.locator(`${err} > header code`).innerText(), "model.frame.default(…)");

  const n = await page.evaluate(() => window.editor_state.notebook.cell_results.ERR.output.body.stacktrace.length);
  assert.ok(n >= 4, `the traceback has the notebook and stats calls (${n})`);
  assert.equal(await page.locator(`${err} ol.ember-tb`).count(), 0, "the traceback starts collapsed");
  await page.getByRole("button", { name: `Show traceback (${n} calls)`, exact: true }).click();
  await page.getByRole("button", { name: "Hide traceback", exact: true }).waitFor({ timeout: 5000 });

  const frames = await page.locator(`${err} ol.ember-tb > li`).evaluateAll((lis) => lis.map((li) => ({
    n: li.querySelector(".ember-tb-n").innerText,
    call: li.querySelector("code").innerText,
    from: li.querySelector(".ember-tb-from").innerText,
    link: li.querySelector(".ember-tb-from a") != null,
    color: getComputedStyle(li).color,
  })));
  assert.equal(frames.length, n);
  const text = await tokenColor(page, "--ember-text");
  const faint = await tokenColor(page, "--ember-faint");
  assert.notEqual(text, faint);
  assert.deepEqual(frames[0], { n: "1", call: "g(bad)", from: "this cell, line 1", link: true, color: text }, "outermost first: the call in this cell");
  assert.match(frames[n - 1].call, /^model\.frame\.default\(/, "innermost last");
  const fd = frames.find((f) => f.call === "f(d)");
  assert.deepEqual(fd, { n: "2", call: "f(d)", from: "notebook", link: true, color: text }, "a function from another cell says notebook");
  const stats = frames.find((f) => f.from === "stats");
  assert.ok(stats, "a frame is labelled stats");
  assert.equal(stats.color, faint, "package calls are faint");

  await page.locator(`${err} ol.ember-tb > li:nth-child(2) .ember-tb-from a`).click();
  await page.waitForFunction((sel) => document.activeElement?.closest(sel) != null, cellSelector("F"), { timeout: 10000 });

  // Board Outputs4 / Cells: a red-tinted box flush with the rail and joined
  // to the code box, whose top-right corner goes square.
  const box = await rect(page, err);
  const cell = await rect(page, cellSelector("ERR"));
  const code = await rect(page, `${cellSelector("ERR")} .cm-editor`);
  near(box.left, cell.left, "the box starts at the rail");
  near(box.right, code.right, "the box is as wide as the code box");
  near(code.top, box.bottom, "the box is joined to the code box");
  assert.equal(await computed(page, err, "backgroundColor"), await tokenColor(page, "--ember-err-bg"));
  assert.equal(await computed(page, err, "padding"), "10px 14px");
  assert.equal(await computed(page, err, "borderRadius"), "0px 6px 0px 0px");
  assert.equal(await computed(page, `${cellSelector("ERR")} .cm-editor`, "borderTopRightRadius"), "0px");
  const msg = `${err} > header > p:first-child`;
  assert.equal(await computed(page, msg, "fontSize"), "14px");
  assert.equal(await computed(page, msg, "fontWeight"), "600");
  assert.equal(await computed(page, msg, "color"), await tokenColor(page, "--ember-red"));
  assert.equal(await computed(page, `${err} > header > p.ember-error-where`, "color"), await tokenColor(page, "--ember-muted"));
  assert.equal(await computed(page, `${err} ol.ember-tb`, "borderTopStyle"), "dashed");

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

  const outputLeft = async (id) => (await rect(page, `${cellSelector(id)} > pluto-output pre`)).left - (await rect(page, cellSelector(id))).left;
  near(await outputLeft("B"), 12, "an output starts 12px right of the rail");

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

  // Board Cells: the chip 12px from the rail, then the greyed output with
  // no wash behind it (the wash is the stale state's).
  assert.notEqual(await tokenColor(page, "--pluto-output-bg-color"), await tokenColor(page, "--ember-wash"));
  near(await outputLeft("B"), 12, "B's output to rail");
  for (const id of ["A", "B"]) {
    near((await rect(page, `${cellSelector(id)} > ember-chip`)).left - (await rect(page, cellSelector(id))).left, 12, `${id}'s chip to rail`);
    assert.equal(await computed(page, `${cellSelector(id)} > pluto-output`, "filter"), "grayscale(1)", `${id}'s output is greyed`);
    assert.equal(await computed(page, `${cellSelector(id)} > pluto-output`, "backgroundColor"), await tokenColor(page, "--pluto-output-bg-color"), `no wash behind ${id}'s output`);
    assert.equal(await page.locator(cellSelector(id)).evaluate((el) => getComputedStyle(el, "::before").content), "none", `no wash layer on ${id}`);
  }

  await bChip.locator("a").click();
  await page.waitForFunction(
    (sel) => document.activeElement?.closest(sel) != null,
    cellSelector("A"), { timeout: 10000 });

  assertNoProblems(page);
});

// runCell's click can miss a cell near the window's bottom edge, under the
// footer, and then Shift + Enter runs nothing.
const runShown = async (page, id) => {
  await page.locator(cellSelector(id)).scrollIntoViewIfNeeded();
  await runCell(page, id);
};

test("outputs: a table's size, types, NA cells and Show more; a list tree; printed text with no box (146)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const rich = tempNotebook("rich.R");
  const server = await startServer([notebook, rich], { logFile: path.join(artifactsDir(), "cells-outputs.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  for (const id of ["NA", "VEC"]) await runShown(page, id);

  const na = cellSelector("NA");
  await page.waitForSelector(`${na} table.pluto-table`, { timeout: 30000 });
  assert.equal(await page.locator(`${na} th.ember-table-size`).innerText(), "2 rows × 2 columns");
  assert.deepEqual(await page.locator(`${na} tr.schema-types th`).allInnerTexts(), ["", "dbl", "chr"]);
  assert.deepEqual(await page.locator(`${na} td.na`).allInnerTexts(), ["NA", "NA"]);
  assert.equal(await computed(page, `${na} td.na >> nth=0`, "color"), await tokenColor(page, "--ember-faint"));
  assert.equal(await computed(page, `${na} tbody tr:first-child td >> nth=0`, "color"), await tokenColor(page, "--ember-text"));
  assert.equal(await page.locator(`${na} button.ember-show-more`).count(), 0, "no Show more for a table shown whole");

  const vec = cellSelector("VEC");
  await page.waitForSelector(`${vec} pluto-tree.ember-tree`, { timeout: 30000 });
  const root = page.locator(vec).getByRole("button", { name: "list of 3", exact: true });
  assert.equal(await root.getAttribute("aria-expanded"), "true", "the root starts open");
  const sub = page.locator(vec).getByRole("button", { name: "sub list of 1", exact: true });
  assert.equal(await sub.getAttribute("aria-expanded"), "false", "a nested list starts collapsed");
  const long = page.locator(`${vec} .ember-tree-row`).filter({ has: page.locator(".ember-tree-key", { hasText: /^long$/ }) });
  assert.equal(await long.locator(".ember-tree-value").innerText(), "1 2 3 4 5 6 7 8 9 10 … int, 100 values");
  assert.equal(await long.locator(".ember-vector-count").innerText(), "int, 100 values");
  await sub.click();
  assert.equal(await sub.getAttribute("aria-expanded"), "true");
  assert.deepEqual(await page.locator(`${vec} pluto-tree.ember-tree pluto-tree.ember-tree > .ember-tree-items > .ember-tree-row`).allInnerTexts(), ["c\nx"]);
  await root.click();
  assert.equal(await page.locator(`${vec} .ember-tree-items`).count(), 0, "the root collapses");

  await openNotebook(page, server.origin, server.secret, rich);
  for (const id of ["DF", "TBL", "FIT"]) await runShown(page, id);
  const tbl = cellSelector("TBL");
  await page.waitForSelector(`${tbl} table.pluto-table`, { timeout: 30000 });
  assert.equal(await page.locator(`${tbl} th.ember-table-size`).innerText(), "32 rows × 11 columns");
  assert.equal(await page.locator(`${tbl} table.pluto-table tbody tr`).count(), 10, "no in-table \"more\" row");
  assert.equal(await page.locator(`${tbl} tr.schema-names th`).count(), 9, "the size cell and 8 columns, no in-table \"more\" column");
  await page.locator(tbl).getByRole("button", { name: "Show 3 more columns", exact: true }).waitFor();
  await page.locator(tbl).getByRole("button", { name: "Show 22 more rows", exact: true }).click();
  // The worker adds 60 rows per click; mtcars has 32.
  await page.waitForFunction(
    (sel) => document.querySelectorAll(`${sel} table.pluto-table tbody tr`).length === 32,
    tbl, { timeout: 10000 });
  assert.equal(await page.locator(`${tbl} button.ember-show-more`).allInnerTexts().then((x) => x.join("|")), "Show 3 more columns");

  const fit = `${cellSelector("FIT")} pluto-output pre`;
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("Coefficients"), fit, { timeout: 20000 });
  assert.equal(await computed(page, fit, "backgroundColor"), "rgba(0, 0, 0, 0)");
  assert.equal(await computed(page, fit, "paddingLeft"), "0px");

  assertNoProblems(page);
});

// Geometry from the Cells and Insert5 boards (ui-3.md "Cell anatomy",
// "Run button", "Cell menu", "Adding cells").


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

test("cell menu: the ⋯ is in pluto-input after the code, on the code box even under an error, and opens on a folded cell", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-menu-place.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForSelector(`${cellSelector("ERR")}.errored`, { timeout: 20000 });

  assert.equal(await page.locator("pluto-cell > button.input_context_menu").count(), 0);
  assert.equal(await page.locator("pluto-cell > pluto-input > button.input_context_menu").count(), await page.locator("pluto-cell").count());
  const order = await page.locator(`${cellSelector("A")} > pluto-input`).evaluate((input) =>
    [...input.children].map((c) => c.matches(".cm-editor") ? "code" : c.matches("button.ember-run") ? "run" : c.matches("button.input_context_menu") ? "menu" : null).filter(Boolean));
  assert.deepEqual(order, ["code", "run", "menu"], "Tab reaches the code first, then run, then ⋯");

  await page.hover(`${cellSelector("ERR")} .cm-content`);
  const box = await rect(page, `${cellSelector("ERR")} .cm-editor`);
  const more = await rect(page, `${cellSelector("ERR")} button.input_context_menu`);
  const output = await rect(page, `${cellSelector("ERR")} > pluto-output`);
  near(box.right - more.right, 6, "⋯ right inset");
  near(more.top - box.top, 5, "⋯ top inset");
  assert.ok(more.top >= output.bottom, "the ⋯ is below the error output, not over it");

  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  await page.locator(`${cellSelector("B")} button.hide_code`).click();
  await page.waitForSelector(`${cellSelector("B")}.code_folded:not(.show_input)`, { timeout: 10000 });
  assert.equal(await page.locator(`${cellSelector("B")} .cm-editor`).isVisible(), false, "the folded cell's code is hidden");

  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  const showItem = page.locator(`${cellSelector("B")} button.hide_code`);
  assert.equal(await showItem.innerText(), "Show code");
  await showItem.click();
  await page.waitForFunction((sel) => !document.querySelector(sel).classList.contains("code_folded"), cellSelector("B"), { timeout: 10000 });
  await page.locator(`${cellSelector("B")} .cm-editor`).waitFor({ state: "visible", timeout: 5000 });

  assertNoProblems(page);
});

test("cell menu: text-only one-line items with a right-aligned key hint, panel and line colours, a 6px-radius trigger that stays on while open", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-geometry-menu-look.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("A"));
  const trigger = page.locator(`${cellSelector("A")} button.input_context_menu`);
  assert.equal(await trigger.evaluate((el) => getComputedStyle(el).borderRadius), "6px");
  await trigger.click();
  assert.match(await trigger.getAttribute("class"), /\bon\b/);

  const menu = page.locator(`${cellSelector("A")} div.input_context_menu[role="menu"]`);
  const colours = await menu.evaluate((el) => {
    const probe = document.createElement("div");
    probe.style.cssText = "border-top: 1px solid var(--ember-line); background: var(--ember-panel)";
    document.body.append(probe);
    const want = getComputedStyle(probe);
    const got = getComputedStyle(el);
    const r = { border: [got.borderTopColor, want.borderTopColor], background: [got.backgroundColor, want.backgroundColor] };
    probe.remove();
    return r;
  });
  assert.equal(colours.border[0], colours.border[1], "menu border is --ember-line");
  assert.equal(colours.background[0], colours.background[1], "menu background is --ember-panel");

  assert.equal(await menu.locator(".ctx_icon, svg, img").count(), 0, "no icons in the items");

  const moveUp = menu.locator("button.move_up");
  const item = await moveUp.evaluate((el) => {
    const cs = getComputedStyle(el);
    const key = el.querySelector(".ember-menuitem-key");
    const kr = key.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    return {
      direction: cs.flexDirection, padding: cs.padding, gap: cs.gap, height: r.height,
      key: key.textContent, keySize: getComputedStyle(key).fontSize, keyRightInset: r.right - kr.right,
      keyMiddle: kr.top + kr.height / 2 - (r.top + r.height / 2),
    };
  });
  assert.equal(item.direction, "row");
  assert.equal(item.padding, "7px 10px");
  assert.equal(item.gap, "10px");
  near(item.height, 7 + 13 * 1.65 + 7, "item height (Cells board)");
  assert.match(item.key, /^(Alt|⌥) ↑$/);
  assert.equal(item.keySize, "11.5px");
  near(item.keyRightInset, 10, "key hint is right-aligned");
  near(item.keyMiddle, 0, "key hint on the label's line");
  assert.equal(await moveUp.evaluate((el) => el.firstChild.textContent.trim()), "Move up");

  // The header's ⋯ menu keeps its stacked title-over-description items.
  const header = await page.evaluate(() => {
    const b = document.createElement("button");
    b.className = "ember-menuitem";
    document.body.append(b);
    const cs = getComputedStyle(b);
    const r = { direction: cs.flexDirection, padding: cs.padding };
    b.remove();
    return r;
  });
  assert.deepEqual(header, { direction: "column", padding: "8px 10px" });

  await page.keyboard.press("Escape");
  await page.waitForFunction((el) => !el.classList.contains("on"), await trigger.elementHandle(), { timeout: 5000 });

  assertNoProblems(page);
});

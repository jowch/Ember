// ui-3-tests.md, piece 6a steps 2-4 (ui-3-plan.md): the rail, the run/stop
// button and run-time chip, the cell menu, the "+" overlay and the empty
// notebook's hints. The chips, outputs and layout of cells are in
// cell-chips, cell-outputs and cell-layout.test.mjs: as one file they ran
// past the runner's 300 s per file on a slow Windows runner (#417).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { writeFileSync } from "node:fs";
import { startServer, tempNotebook, artifactsDir, tempDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, runCell, cellSelector, codeSelector, sentMessages, frames } from "../browser.mjs";
import { waitingFor } from "../waits.mjs";

// Where a cell is and what its editor holds, for a failure message.
const viewState = (page, id) => page.evaluate((id) => {
  const cell = document.querySelector(`pluto-cell[id="${id}"]`);
  const r = cell.getBoundingClientRect();
  const editor = cell.querySelector("pluto-input .cm-editor");
  return {
    top: r.top, bottom: r.bottom, viewHeight: innerHeight, scrollY, scrollHeight: document.documentElement.scrollHeight,
    fake: editor?.classList.contains("cm-ssr-fake") ?? null, height: editor?.style.height, minHeight: editor?.style.minHeight,
    fakes: [...document.querySelectorAll("pluto-input .cm-ssr-fake")].map((f) => f.closest("pluto-cell").id),
  };
}, id);
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
  await waitingFor(what, page.waitForFunction(
    ([sel, prop, expected]) => getComputedStyle(document.querySelector(sel))[prop] === expected,
    [sel, prop, expected]), () => computed(page, sel, prop));
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

  await page.locator(codeSelector("B")).click();
  await page.keyboard.type(" ", { delay: 2 });
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "due",
    cellSelector("B"));
  await settledStyle(page, rail("B"), "backgroundColor", await tokenColor(page, "--ember-rail-due"));
  await settledStyle(page, `${cellSelector("B")} .cm-gutters`, "backgroundColor", await tokenColor(page, "--ember-due-bg"));

  // The tip belongs to the rail alone: not to hovering or focusing the
  // rest of the cell.
  const tip = page.locator(`${cellSelector("B")} ember-rail-tip`);
  await page.locator(codeSelector("A")).click();
  await page.hover(codeSelector("B"));
  assert.equal(await tip.isVisible(), false, "no tip while hovering B's code");
  // Near the rail's foot: B is one line, so with its chip's space above
  // the code (#139) the rail's middle sits under the run button's corner.
  const railBox = await page.locator(rail("B")).boundingBox();
  await page.hover(rail("B"), { position: { x: railBox.width / 2, y: railBox.height - 3 } });
  await tip.waitFor({ state: "visible" });
  assert.equal(await tip.innerText(), "Press Shift + Enter to run this cell");
  await page.locator(codeSelector("B")).click();
  assert.equal(await tip.isVisible(), false, "no tip once the pointer leaves the rail, with B focused");

  await runCell(page, "ERR");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "err",
    cellSelector("ERR"));
  await settledStyle(page, rail("ERR"), "backgroundColor", await tokenColor(page, "--ember-rail-err"));

  await setCellCode(page, "LOOP", "Sys.sleep(8)");
  await page.keyboard.press("Shift+Enter");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "run",
    cellSelector("LOOP"));
  await runCell(page, "NEVER");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("data-rail") === "queued",
    cellSelector("NEVER"));
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
    () => window.editor_state.notebook.cell_results.LOOP?.output?.last_run_timestamp > 0);

  const settled = (sel) => {
    const el = document.querySelector(sel);
    return el.getAttribute("data-rail") === "idle" && !el.classList.contains("queued") && !el.classList.contains("running");
  };
  for (const id of ["A", "LOOP"]) {
    await page.waitForFunction(settled, cellSelector(id));
    const before = await page.evaluate((id) => window.editor_state.notebook.cell_results[id].output.last_run_timestamp, id);
    await runCell(page, id);
    await page.waitForFunction(
      ([id, before]) => window.editor_state.notebook.cell_results[id].output.last_run_timestamp > before,
      [id, before]);
    await page.waitForFunction(settled, cellSelector(id));
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
    cellSelector("A") + " ember-runtime");

  // Long enough that a click landing late still finds it running: a wait
  // for "Interrupted" below that never ends can then only mean the
  // interrupt was lost.
  await setCellCode(page, "LOOP", "Sys.sleep(60)");
  await runCell(page, "LOOP");
  await page.waitForSelector(`${cellSelector("LOOP")}.running`);
  await page.hover(cellSelector("LOOP"));
  const stopButton = page.locator(`${cellSelector("LOOP")} button.ember-run`);
  // Stop shows once the run has lasted 250 ms (common/useSettled.js).
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.getAttribute("aria-label") === "Stop (Ctrl + Q)",
    `${cellSelector("LOOP")} button.ember-run`);
  await stopButton.click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("Interrupted"),
    cellSelector("LOOP") + " pluto-output");

  assertNoProblems(page);
});

test("cell menu: item order, move down, hide code, Disable on every code cell (142, settings-cells.md)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-menu.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("S"));
  await page.locator(`${cellSelector("S")} button.input_context_menu`).click();
  assert.equal(await page.locator(`${cellSelector("S")} button.input_context_menu`).getAttribute("aria-label"), "Cell options");
  assert.equal(await page.locator(`${cellSelector("S")} button.disable_cell`).count(), 1, "the first cell's menu has Disable cell: no cell is special");
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
    });

  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  const hideItem = page.locator(`${cellSelector("B")} button.hide_code`);
  assert.equal(await hideItem.innerText(), "Hide code");
  await hideItem.click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.classList.contains("code_folded"),
    cellSelector("B"));
  await page.hover(cellSelector("B"));
  await page.locator(`${cellSelector("B")} button.input_context_menu`).click();
  assert.equal(await page.locator(`${cellSelector("B")} button.hide_code`).innerText(), "Show code");

  assertNoProblems(page);
});

// Until a cell's editor loads, its code is shown by a static copy
// (StaticCodeMirrorFaker). The copy has to be as tall as the editor, or every
// cell below moves when the editor replaces it: by 23 px per cell above
// before #375. Until an editor has measured its text, CodeMirror guesses
// line heights: a wrapped line's gutter row (L, W) far too tall, and lines
// past its first viewport too short (T; U, whose wrapped lines come after
// more lines than fit in the window). The editor holds the static code's
// height until then, so those cells sit above B too (#379).
test("opening: a cell's static code is as tall as its editor, so nothing below moves when editors load (#375, #379)", async (t) => {
  const long = `x <- c(${Array.from({ length: 300 }, (_, i) => i).join(", ")})`;
  const notebook = path.join(tempDir("ember-e2e-static-"), "static.R");
  writeFileSync(notebook, [
    "### An Ember notebook ###", "# /// environment", '# ember_version = "0.0.0.9000"', '# r_version = "4.6.1"', '# snapshot = "2026-01-01"', "# ///", "",
    "# %% id=S", "",
    "# %% id=A", "x <- 1", "",
    "# %% id=I", "f <- function(a) {", "    if (a) {", "        print(a)", "", "    }", "}", "",
    "# %% id=L", long, "",
    "# %% id=W", `s <- "${"abcdefghij".repeat(80)}"`, "",
    "# %% id=T", "y <- 2", long, ...Array.from({ length: 60 }, (_, i) => `t${i} <- ${i}`), "",
    "# %% id=U", "y <- 2", ...Array.from({ length: 150 }, (_, i) => `u${i} <- ${i}`), long, long, "",
    "# %% id=B", "x + 1", "",
  ].join("\n"), "utf8");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-static.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // From the first frame: B's top, and each cell's height while it shows
  // the static copy.
  await page.addInitScript(() => {
    window.__bTops = [];
    window.__staticHeights = {};
    window.__fontAtFirstStatic = null;
    const tick = () => {
      const b = document.querySelector('pluto-cell[id="B"]');
      if (b) window.__bTops.push(b.getBoundingClientRect().top + window.scrollY);
      for (const c of document.querySelectorAll("pluto-cell")) {
        const fake = c.querySelector("pluto-input .cm-ssr-fake");
        if (fake && !(c.id in window.__staticHeights)) window.__staticHeights[c.id] = fake.getBoundingClientRect().height;
        if (fake && window.__fontAtFirstStatic == null) window.__fontAtFirstStatic = document.fonts.check(`13px ${getComputedStyle(fake.querySelector(".cm-content")).fontFamily}`);
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  await openNotebook(page, server.origin, server.secret, notebook);
  // An editor loads once its cell is in view, so bring each static one into
  // view in turn and wait for its editor.
  for (;;) {
    const id = await page.evaluate(() => {
      const cell = document.querySelector("pluto-input .cm-ssr-fake")?.closest("pluto-cell");
      cell?.scrollIntoView();
      return cell?.id ?? null;
    });
    if (id === null) break;
    await waitingFor(`cell ${id}'s editor loads once it is scrolled into view`,
      page.waitForFunction((sel) => !document.querySelector(`${sel} .cm-ssr-fake`), cellSelector(id)), () => viewState(page, id));
  }
  // An editor scrolled past before its first measure keeps the static
  // code's height until it is back in view (#416), so bring each one into
  // view until it has measured its text and let that height go.
  for (const id of ["S", "A", "I", "L", "W", "T", "U", "B"]) {
    await page.evaluate((sel) => document.querySelector(sel).scrollIntoView(), cellSelector(id));
    await waitingFor(`cell ${id}'s editor lets go of the static code's height once in view`,
      page.waitForFunction((sel) => document.querySelector(`${sel} pluto-input .cm-editor:not(.cm-ssr-fake)`)?.style.height === "", cellSelector(id)),
      () => viewState(page, id));
  }
  // U's last lines are rendered once they come into view; until then U's
  // editor keeps the static code's height as its minimum.
  await page.evaluate(() => document.querySelector('pluto-cell[id="U"] pluto-input').scrollIntoView({ block: "end" }));
  await waitingFor("every editor lets go of the static code's height once its lines are measured",
    page.waitForFunction(() => !document.querySelector("pluto-input .cm-ssr-fake") && [...document.querySelectorAll("pluto-input .cm-editor")].every((e) => e.style.minHeight === "")));
  // One more frame, so the recorder has seen the layout with every editor.
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));

  const { tops, statics, editors, font } = await page.evaluate(() => ({
    font: window.__fontAtFirstStatic,
    tops: window.__bTops,
    statics: window.__staticHeights,
    editors: Object.fromEntries([...document.querySelectorAll("pluto-cell")].map((c) => [c.id, c.querySelector("pluto-input .cm-editor").getBoundingClientRect().height])),
  }));
  // In a fallback font a long line can wrap into a different number of
  // rows (Consolas on Windows, #400).
  assert.equal(font, true, "the code font is loaded when the first static code is drawn");
  assert.deepEqual(Object.keys(statics).sort(), ["A", "B", "I", "L", "S", "T", "U", "W"], "every cell showed its static code first");
  for (const [id, h] of Object.entries(statics)) near(h, editors[id], `cell ${id}'s static code height`);
  assert.deepEqual([...new Set(tops)], [tops[0]], "B never moves while the editors load");

  assertNoProblems(page);
});

// An editor scrolled out of view before its first measure: CodeMirror
// doesn't measure an editor it can't see, but its measure requests still
// run, so the static code's height was let go for CodeMirror's guess, 393
// px for W's 250 (the opening test's failure on macOS CI). The editor keeps
// the static height until it is in view and measured (#416).
test("opening: an editor scrolled past before its first measure keeps the static code's height until it is measured (#416)", async (t) => {
  const notebook = path.join(tempDir("ember-e2e-static-"), "scrolled.R");
  writeFileSync(notebook, [
    "### An Ember notebook ###", "# /// environment", '# ember_version = "0.0.0.9000"', '# r_version = "4.6.1"', '# snapshot = "2026-01-01"', "# ///", "",
    ...Array.from({ length: 30 }, (_, i) => [`# %% id=P${i}`, `p${i} <- ${i}`, ""]).flat(),
    "# %% id=W", `s <- "${"abcdefghij".repeat(80)}"`, "",
    ...Array.from({ length: 60 }, (_, i) => [`# %% id=Q${i}`, `q${i} <- ${i}`, ""]).flat(),
  ].join("\n"), "utf8");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-static-scrolled.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const w = cellSelector("W");
  // The notebook stops loading before every cell is drawn, so wait for W's
  // static code; it starts below the view (#420).
  await waitingFor("W shows its static code when the notebook opens", page.waitForFunction((sel) => document.querySelector(`${sel} .cm-ssr-fake`), w));
  const { staticHeight, top, viewHeight } = await page.evaluate((sel) => ({
    staticHeight: document.querySelector(`${sel} .cm-ssr-fake`).getBoundingClientRect().height,
    top: document.querySelector(sel).getBoundingClientRect().top,
    viewHeight: innerHeight,
  }), w);
  assert.ok(top > viewHeight, `W starts below the view: its top is ${top}, the view's height ${viewHeight}`);
  // Bring W into view, and scroll to the end the moment its editor replaces
  // the static code, before CodeMirror's first measure.
  await page.evaluate((sel) => new Promise((resolve) => {
    const cell = document.querySelector(sel);
    new MutationObserver((_, observer) => {
      if (cell.querySelector(".cm-ssr-fake")) return;
      observer.disconnect();
      window.scrollTo(0, document.body.scrollHeight);
      resolve();
    }).observe(cell, { subtree: true, childList: true });
    cell.scrollIntoView();
  }), w);
  // Every frame for a while out of view: the static height, never the guess.
  const editorHeight = (sel) => page.evaluate((sel) => new Promise((resolve) =>
    requestAnimationFrame(() => resolve(document.querySelector(`${sel} pluto-input .cm-editor`).getBoundingClientRect().height))), sel);
  for (let i = 0; i < 20; i++) near(await editorHeight(w), staticHeight, `W's editor out of view, frame ${i}`);

  // Back in view, it measures its text and lets the height go.
  await page.locator(w).scrollIntoViewIfNeeded();
  await page.waitForFunction((sel) => document.querySelector(`${sel} pluto-input .cm-editor:not(.cm-ssr-fake)`)?.style.height === "", w);
  near(await editorHeight(w), staticHeight, "W's editor once measured");

  assertNoProblems(page);
});

// A tall editor whose lines above the viewport are still guessed: scrolled
// to the end of the page before its first measure, it let go of the static
// code's height at that measure, for a layout or more at CodeMirror's guess,
// 364 px short. At the end of the page that pulled the scroll up for good,
// so the last cell, just scrolled into view, ended up below it and kept its
// static code (#429, #435: the opening test's failure on macOS CI).
test("opening: scrolled to the end as a tall editor above loads, the page stays at the end and the last cell loads (#429)", async (t) => {
  const long = `x <- c(${Array.from({ length: 300 }, (_, i) => i).join(", ")})`;
  const notebook = path.join(tempDir("ember-e2e-static-"), "end.R");
  writeFileSync(notebook, [
    "### An Ember notebook ###", "# /// environment", '# ember_version = "0.0.0.9000"', '# r_version = "4.6.1"', '# snapshot = "2026-01-01"', "# ///", "",
    ...Array.from({ length: 30 }, (_, i) => [`# %% id=P${i}`, `p${i} <- ${i}`, ""]).flat(),
    "# %% id=U", "y <- 2", ...Array.from({ length: 150 }, (_, i) => `u${i} <- ${i}`), long, long, "",
    "# %% id=B", "x + 1", "",
  ].join("\n"), "utf8");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-static-end.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const u = cellSelector("U");
  // The notebook stops loading before every cell is drawn, so wait for U's
  // static code; it starts below the view.
  await waitingFor("U shows its static code when the notebook opens", page.waitForFunction((sel) => document.querySelector(`${sel} .cm-ssr-fake`), u));
  // Bring U into view, and scroll B into view the moment U's editor
  // replaces the static code, before CodeMirror's first measure.
  await page.evaluate((sel) => new Promise((resolve) => {
    const cell = document.querySelector(sel);
    new MutationObserver((_, observer) => {
      if (cell.querySelector(".cm-ssr-fake")) return;
      observer.disconnect();
      document.querySelector('pluto-cell[id="B"]').scrollIntoView();
      resolve();
    }).observe(cell, { subtree: true, childList: true });
    cell.scrollIntoView();
  }), u);
  // U's first measure in view ends the hold on its height.
  await waitingFor("U's editor lets go of the static code's height once in view",
    page.waitForFunction((sel) => document.querySelector(`${sel} pluto-input .cm-editor`).style.height === "", u));
  const frame = () => page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve({
    scrollY: Math.round(scrollY),
    end: document.documentElement.scrollHeight - innerHeight,
    bTop: document.querySelector('pluto-cell[id="B"]').getBoundingClientRect().top,
    viewHeight: innerHeight,
  })))));
  const at = await frame();
  assert.ok(at.end - at.scrollY <= 1, `the page stays scrolled to the end: ${JSON.stringify(at)}`);
  assert.ok(at.bTop < at.viewHeight, `B stays in view: ${JSON.stringify(at)}`);
  await waitingFor("B's editor loads", page.waitForFunction(() => !document.querySelector('pluto-cell[id="B"] .cm-ssr-fake')), frame);

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
  const pageTop = (sel) => page.evaluate((sel) => document.querySelector(sel).getBoundingClientRect().top + window.scrollY, sel);
  // Measure once the cells above B have their editors, so only the hover
  // could move B (#375).
  await page.waitForFunction((sel) => {
    const b = document.querySelector(sel);
    return [...document.querySelectorAll("pluto-cell")]
      .filter((c) => c.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING)
      .every((c) => !c.querySelector(".cm-ssr-fake"));
  }, cellSelector("B"));
  const beforeTop = await pageTop(cellSelector("B"));

  await addBeforeB.hover();
  await page.waitForFunction(
    (sel) => getComputedStyle(document.querySelector(sel).querySelector("span")).opacity > 0,
    `${cellSelector("B")} button.add_cell.before`);

  const afterTop = await pageTop(cellSelector("B"));
  assert.equal(beforeTop, afterTop, "hovering the \"+\" doesn't move B");

  const cellCountBefore = await page.locator("pluto-cell").count();
  await addBeforeB.click();
  await page.waitForFunction(
    (before) => document.querySelectorAll("pluto-cell").length > before,
    cellCountBefore);

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
  await page.waitForSelector(`${cellSelector("A")} > pluto-output`, { state: "attached" });

  assert.ok(await page.locator(`${cellSelector("A")} > pluto-trafficlight`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("A")} > pluto-output`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("A")} pluto-shoulder > button.foldcode`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("A")} button.add_cell.before`).count() > 0);
  assert.ok(await page.locator(`${cellSelector("A")} button.add_cell.after`).count() > 0);

  await setCellCode(page, "A", "x <- 1");
  await runCell(page, "ERR");
  await page.waitForSelector(`${cellSelector("ERR")}.errored`);
  assert.ok(await page.locator(`${cellSelector("ERR")} jlerror > header`).count() > 0);

  await page.locator(codeSelector("B")).click();
  await page.keyboard.type(" ", { delay: 2 });
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.classList.contains("code_differs"),
    cellSelector("B"));

  await page.waitForFunction(
    (sel) => !document.querySelector(sel)?.matches(".running, .queued"),
    cellSelector("NEVER"));
  await setCellCode(page, "LOOP", "Sys.sleep(8)");
  await page.keyboard.press("Shift+Enter");
  await page.waitForSelector(`${cellSelector("LOOP")}.running`);
  await runCell(page, "NEVER");
  await page.waitForSelector(`${cellSelector("NEVER")}.queued:not(.running)`);
  assert.equal(await page.locator(`${cellSelector("LOOP")}.running`).count(), 1, "LOOP still running while NEVER waits");

  assertNoProblems(page);
});

test("argument tooltips close when the cursor leaves their cell (alongside 152)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-tooltip.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output");

  await page.locator(codeSelector("A")).click();
  await page.keyboard.press("End");
  await page.keyboard.type("; mean(", { delay: 10 });
  await page.waitForSelector(".cm-ember-signature-tooltip");

  // Clicking into a different cell moves the cursor out of A entirely:
  // the tooltip must not be left floating over B.
  await page.locator(codeSelector("B")).click();
  await page.waitForFunction(
    () => document.querySelector(".cm-ember-signature-tooltip") == null);

  assertNoProblems(page);
});

test("argument tooltips: a reply that arrives after blur doesn't reopen one (#467)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-tooltip-slow.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  const asked = sentMessages(page, "ember_signature");
  // Signature replies from the server, held while `held` is a list, so
  // one can be made to arrive after the blur.
  let held = null;
  let to_page = null;
  let on_held = null;
  const reply_held = new Promise((resolve) => (on_held = resolve));
  await page.routeWebSocket(/.*/, (ws) => {
    const srv = ws.connectToServer();
    to_page = ws;
    ws.onMessage((m) => srv.send(m));
    srv.onMessage((m) => {
      if (held != null && Buffer.from(m).includes("ember_signature")) {
        held.push(m);
        on_held();
      } else ws.send(m);
    });
  });
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output");

  await page.locator(codeSelector("A")).click();
  await page.keyboard.press("End");
  const replies = () => page.evaluate(() => window.pluto_get_message_log().filter((m) => m.type === "ember_signature").length);
  const replied_before = await replies();
  const asked_before = asked.length;
  held = [];
  await page.keyboard.type("; mean(1:3", { delay: 10 });
  // Past the 150 ms debounce: the request went out, and its reply is held.
  await asked.reach(asked_before + 1);
  await waitingFor("the signature reply, held", reply_held);
  assert.equal(await page.locator(".cm-ember-signature-tooltip").count(), 0, "no tooltip before the reply");

  await page.locator(codeSelector("B")).click();
  await frames(page);
  const late = held;
  held = null;
  for (const m of late) to_page.send(m);
  // The reply has come and been handled.
  await page.waitForFunction((before) => window.pluto_get_message_log().filter((m) => m.type === "ember_signature").length > before,
    replied_before);
  await frames(page);

  assert.equal(await page.locator(".cm-ember-signature-tooltip").count(), 0, "no tooltip reopened over B");

  assertNoProblems(page);
});

test("empty notebook: placeholder and hints show, and typing removes them (151)", async (t) => {
  // A real new notebook (new_notebook(), R/api.R) has two empty cells
  // (setup, then one code cell), not one -- made through the start page,
  // like a person actually gets there.
  const dir = tempDir("ember-e2e-empty-");
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
  // No timeouts of our own: the page and its notebook arrive when the
  // server sends them, and the test runner's timeout bounds the wait. 15 s
  // ran out once on Windows CI while the whole runner was slowed, other
  // files' tests 4 to 9 times their usual time with it (#417).
  await page.waitForURL(/edit\?id=/);
  await page.waitForSelector("pluto-cell");

  assert.equal(await page.locator("pluto-cell").count(), 1, "a new notebook has one empty code cell");
  const placeholder = await page.locator("pluto-cell .cm-placeholder").first().innerText();
  assert.equal(placeholder, "Type R code here");
  assert.match(await page.locator("ember-empty-hints").innerText(), /⌘/, "Mac modifier shown in the hints");

  await page.locator("pluto-cell:last-of-type .cm-content").click();
  await page.keyboard.type("1 + 1", { delay: 2 });
  await page.waitForFunction(
    () => document.querySelectorAll("ember-empty-hints").length === 0);

  assertNoProblems(page);
});

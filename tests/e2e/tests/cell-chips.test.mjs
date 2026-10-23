// ui-3-tests.md, piece 6a (ui-3-plan.md): the status chips ("Not run yet",
// "Stale") and how the page moves when a run's outputs land. Split from
// cells.test.mjs (#417).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { writeFileSync } from "node:fs";
import { startServer, tempNotebook, artifactsDir, tempDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, setCellCode, runCell, cellSelector } from "../browser.mjs";

const rect = (page, sel) => page.locator(sel).evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
});
// Several rects in one round trip, so a scroll between reads can't skew
// their differences.
const rects = (page, sels) => page.evaluate((sels) => Object.fromEntries(Object.entries(sels).map(([k, sel]) => {
  const r = document.querySelector(sel).getBoundingClientRect();
  return [k, { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }];
})), sels);
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

test('chips: "Not run yet" in safe preview and before running, "Stale" after an upstream edit (144, #298)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-safe.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  // Safe preview: B has never run, and says so, as Pluto marks every
  // cell in safe preview (#298).
  const chip = page.locator(`${cellSelector("B")} > ember-chip:not(.held)`);
  await chip.waitFor({ state: "visible", timeout: 10000 });
  assert.equal(await chip.innerText(), "Not run yet");

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
  // Board Cells: 12px right of the rail and 12px above the code. A's run
  // can still be landing (its chip goes, its output comes), which moves
  // NEVER down, so wait for it to finish and read every box in one round
  // trip: reads taken a moment apart once measured the chip 46px from the
  // code.
  await page.waitForSelector(`${cellSelector("A")} ember-runtime`, { state: "attached", timeout: 15000 });
  const { neverCell, neverRail, neverChip, neverCode } = await rects(page, {
    neverCell: cellSelector("NEVER"),
    neverRail: `${cellSelector("NEVER")} > pluto-trafficlight`,
    neverChip: `${cellSelector("NEVER")} > ember-chip`,
    neverCode: `${cellSelector("NEVER")} .cm-editor`,
  });
  near(neverRail.right, neverCell.left, "the rail ends where the cell starts");
  near(neverChip.left - neverRail.right, 12, "chip to rail");
  near(neverCode.top - neverChip.bottom, 12, "chip to code");
  assert.equal(await page.locator(`${cellSelector("NEVER")} ember-runtime`).count(), 0, "no run-time chip before a first run");

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
  const file = path.join(tempDir("ember-e2e-export-"), "cells.html");
  writeFileSync(file, await res.text(), "utf8");
  const exported = await newPage(browser);
  await exported.goto(`file://${file}`);
  await exported.waitForSelector(`pluto-editor.disable_ui ${cellSelector("NEVER")}.not_run_yet`, { state: "attached", timeout: 15000 });
  assert.equal(await exported.locator(`${cellSelector("NEVER")} ember-chip`).isVisible(), false, "no \"Not run yet\" chip in an export");

  assertNoProblems(page);
});

// #52: when a cell showing "Not run yet" runs, the chip used to go at once
// and the output came later, so the code moved up and then down. NEVER is
// made slow (Sys.sleep) so the two would be far apart; the code's place in
// its cell, read once a frame through the whole run, may change only once.
test('chips: a "Not run yet" cell that runs moves its code once, when the output lands (#52)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-notrun-run.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "A");
  await page.waitForSelector(`${cellSelector("A")} ember-runtime`, { state: "attached", timeout: 30000 });
  await setCellCode(page, "NEVER", "Sys.sleep(1); 3 + 3");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.classList.contains("not_run_yet"),
    cellSelector("NEVER"), { timeout: 20000 });

  await page.evaluate((sel) => {
    window.__code_tops = [];
    window.__stop = false;
    const tick = () => {
      const cell = document.querySelector(sel);
      const top = cell.querySelector(".cm-editor").getBoundingClientRect().top - cell.getBoundingClientRect().top;
      const output = cell.querySelector(":scope > pluto-output")?.innerText ?? "";
      const last = window.__code_tops.at(-1);
      if (last == null || Math.abs(last.top - top) > 0.5) window.__code_tops.push({ top, output });
      if (!window.__stop) requestAnimationFrame(tick);
    };
    tick();
  }, cellSelector("NEVER"));
  await page.keyboard.press("Shift+Enter");
  await page.waitForSelector(`${cellSelector("NEVER")} ember-runtime`, { state: "attached", timeout: 30000 });
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("6"), cellSelector("NEVER") + " > pluto-output", { timeout: 30000 });
  const tops = await page.evaluate(() => { window.__stop = true; return window.__code_tops; });

  assert.ok(tops.length <= 2, `the code moved once at most: ${JSON.stringify(tops)}`);
  assert.equal(await page.locator(`${cellSelector("NEVER")} ember-chip`).count(), 0, "no chip once it has output");
  assertNoProblems(page);
});

// #139: the first run used to give every unrun cell its chip at once and
// push the page down by a chip per cell. Safe preview now shows the chip
// already (#298). NEVER, LOOP and W stay unrun when A runs; the code's
// place in each, read once a frame from safe preview through A's run, must
// not move.
test('chips: leaving safe preview doesn\'t move unrun cells: their chip is already there (#139, #298)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-preview-space.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const ids = ["NEVER", "LOOP", "W"];
  const shown = page.locator(`${cellSelector("NEVER")} > ember-chip:not(.held)`);
  await shown.waitFor({ state: "visible", timeout: 10000 });
  assert.equal(await shown.innerText(), "Not run yet", "safe preview shows the chip");
  assert.equal(await shown.getAttribute("aria-hidden"), null, "and reads it out");

  await page.evaluate((sels) => {
    window.__code_tops = Object.fromEntries(sels.map((sel) => [sel, []]));
    window.__stop = false;
    const tick = () => {
      for (const sel of sels) {
        const cell = document.querySelector(sel);
        const top = cell.querySelector(":scope > pluto-input").getBoundingClientRect().top - cell.getBoundingClientRect().top;
        const tops = window.__code_tops[sel];
        if (!tops.length || Math.abs(tops.at(-1) - top) > 0.5) tops.push(top);
      }
      if (!window.__stop) requestAnimationFrame(tick);
    };
    tick();
  }, ids.map(cellSelector));
  await runCell(page, "A");
  await page.waitForSelector(`${cellSelector("A")} ember-runtime`, { state: "attached", timeout: 30000 });
  for (const id of ids) {
    await page.waitForFunction(
      (sel) => document.querySelector(sel)?.classList.contains("not_run_yet"),
      cellSelector(id), { timeout: 20000 });
  }
  const tops = await page.evaluate(() => { window.__stop = true; return window.__code_tops; });
  for (const id of ids) {
    assert.equal(tops[cellSelector(id)].length, 1, `${id}'s code didn't move: ${JSON.stringify(tops[cellSelector(id)])}`);
  }
  assert.equal(await page.locator(`${cellSelector("NEVER")} > ember-chip`).innerText(), "Not run yet");
  assert.equal(await page.locator(`${cellSelector("NEVER")} > ember-chip.held`).count(), 0, "the chip still shows once the run starts");
  assertNoProblems(page);
});

// #139, round 1 of its review: "Run this notebook" queues every cell. A
// queued cell gives its held space back at the click, with the banner, so
// a cell that finishes with no output (F, LOOP) doesn't move the page up
// mid-run. TXT's place on the page, read once a frame: once it starts
// moving down (outputs landing), it never moves up again.
test('chips: "Run this notebook" moves the page up only at the click, then only down (#139)', async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-preview-runall.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator(`${cellSelector("NEVER")} > ember-chip:not(.held)`).waitFor({ state: "visible", timeout: 15000 });

  await page.evaluate((sel) => {
    window.__txt_tops = [];
    window.__stop = false;
    // How many tops were recorded before the click. One means the page had
    // settled before it (#391); the run's moves are judged from there on.
    document.addEventListener("click", () => { window.__txt_at_click ??= window.__txt_tops.length; }, { capture: true });
    const tick = () => {
      const top = document.querySelector(sel).getBoundingClientRect().top + window.scrollY;
      const tops = window.__txt_tops;
      if (!tops.length || Math.abs(tops.at(-1) - top) > 0.5) tops.push(top);
      if (!window.__stop) requestAnimationFrame(tick);
    };
    tick();
  }, cellSelector("TXT"));
  await page.locator("#ember-safe-preview button").click();
  await page.waitForSelector(`${cellSelector("LOOP")} ember-runtime`, { state: "attached", timeout: 30000 });
  await page.waitForFunction(
    () => document.querySelectorAll('pluto-cell[data-rail="run"], pluto-cell[data-rail="queued"]').length === 0,
    null, { timeout: 30000 });
  const { all, atClick } = await page.evaluate(() => { window.__stop = true; return { all: window.__txt_tops, atClick: window.__txt_at_click }; });
  assert.equal(atClick, 1, `the page had settled before the click (#391): ${JSON.stringify(all)}`);
  const tops = all.slice(atClick - 1);
  const moves = tops.slice(1).map((top, i) => Math.round(top - tops[i]));
  const firstDown = moves.findIndex((m) => m > 0);
  assert.ok(firstDown >= 0, `outputs moved TXT down: ${JSON.stringify(moves)}`);
  assert.ok(moves.slice(firstDown).every((m) => m > 0), `no move up once the run's outputs land: ${JSON.stringify(moves)}`);
  assert.equal(await page.locator("ember-chip.held").count(), 0, "no held space left once every cell ran");
  assertNoProblems(page);
});

test('view anchor: scrolled into the notebook, "Run this notebook" leaves the code at the top of the view where it is, even as its own table lands above it', async (t) => {
  const notebook = tempNotebook("view-anchor.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-view-anchor.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await page.setViewportSize({ width: 900, height: 800 });
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.evaluate((sel) => document.querySelector(sel).scrollIntoView({ block: "start" }), cellSelector("C08"));
  await page.waitForTimeout(300);

  // Read where C08's code is in every frame something resizes, after the
  // page's own observer has run (observers run in the order they were
  // made), so this is what gets painted. C08 prints a table, which lands
  // above its code: the cell's own top holding still isn't enough.
  await page.evaluate((sel) => {
    const el = document.querySelector(sel);
    window.__tops = [];
    const ro = new ResizeObserver(() => window.__tops.push(el.getBoundingClientRect().top));
    ro.observe(document.body);
    for (const c of document.querySelectorAll("pluto-cell")) ro.observe(c);
  }, `${cellSelector("C08")} > pluto-input`);
  const before = await rect(page, `${cellSelector("C08")} > pluto-input`);
  const pageTop = () => page.evaluate((sel) => document.querySelector(sel).getBoundingClientRect().top + window.scrollY, `${cellSelector("C08")} > pluto-input`);
  const beforePage = await pageTop();
  // Clicked in script: Playwright's click would scroll the banner into view first.
  await page.evaluate(() => document.querySelector("#ember-safe-preview button").click());
  await page.waitForFunction(() => !document.querySelector("#ember-safe-preview"), null, { timeout: 30000 });
  await page.waitForFunction(() => document.querySelectorAll("pluto-cell.running, pluto-cell.queued").length === 0, null, { timeout: 60000 });
  await page.waitForTimeout(500);

  const tops = await page.evaluate(() => window.__tops);
  // Outputs landed above C08: its code is further down the page. Counting
  // resize frames instead was a weak proxy: outputs that land in the same
  // frame share one, and it failed about one run in five (#401).
  const afterPage = await pageTop();
  assert.ok(afterPage > beforePage + 50, `outputs landed above C08: its code moved down the page from ${beforePage} to ${afterPage}`);
  assert.ok(Math.abs((await rect(page, `${cellSelector("C08")} > pluto-input`)).top - before.top) <= 1, "C08's code is still where it was in the view");
  const off = tops.filter((top) => Math.abs(top - before.top) > 1);
  assert.deepEqual(off, [], `C08's code stayed at ${before.top} in every frame`);
  assert.ok(await page.locator(`${cellSelector("C08")} > pluto-output table`).count() > 0, "C08's table landed");
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
  const { out, chip, code } = await rects(page, {
    out: `${cellSelector("B")} > pluto-output`,
    chip: `${cellSelector("B")} > ember-chip`,
    code: `${cellSelector("B")} .cm-editor`,
  });
  assert.ok(chip.top >= out.bottom, `chip (${chip.top}) under the output (${out.bottom})`);
  const wash = await page.locator(cellSelector("B")).evaluate((el) => {
    const s = getComputedStyle(el, "::before");
    return { bg: s.backgroundColor, height: parseFloat(s.height), radius: s.borderRadius };
  });
  assert.equal(wash.bg, await tokenColor(page, "--ember-wash"));
  near(wash.height, code.top - out.top, "the wash spans output and chip, down to the code box");
  assert.equal(wash.radius, "0px 6px 0px 0px");
  assert.equal(await computed(page, `${cellSelector("B")} > pluto-output`, "backgroundColor"), "rgba(0, 0, 0, 0)", "the faded output has no background of its own");
  assert.equal(await computed(page, `${cellSelector("B")} .cm-editor:not(.cm-ssr-fake)`, "borderTopRightRadius"), "0px");

  assertNoProblems(page);
});

// A name in a chip or note links to the one cell defining it; clicking
// goes there and selects the definition, as go-to-definition does (#285).
const focused = (page) => page.evaluate(() => ({
  cell: document.activeElement?.closest("pluto-cell")?.id ?? null,
  text: window.getSelection()?.toString() ?? "",
}));

test('chips: the names in "Stale · x changed" link to the cell defining each, and clicking one selects its definition (#285)', async (t) => {
  const notebook = tempNotebook("lazy.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-stale-link.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("B") + " pluto-output", { timeout: 20000 });
  await setCellCode(page, "A", "y <- 0\nx <- 2");
  await runCell(page, "A");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText === "Stale · x changed",
    cellSelector("B") + " ember-chip", { timeout: 20000 });

  const link = page.locator(`${cellSelector("B")} > ember-chip a`);
  assert.equal(await link.count(), 1, "the chip has one link");
  assert.equal(await link.innerText(), "x");
  await link.click();
  await page.waitForFunction(() => document.activeElement?.closest("pluto-cell")?.id === "A" && window.getSelection()?.toString() === "x",
    null, { timeout: 10000 }).catch(async () => assert.fail(`clicking x selects x's definition in A: ${JSON.stringify(await focused(page))}`));
  // The link doesn't navigate, and B stays stale.
  assert.equal(new URL(page.url()).hash, "");
  assert.ok(await page.locator(`${cellSelector("B")}.stale`).count() === 1, "B is still stale");

  assertNoProblems(page);
});

test('notes: "Changed cnt in place, which another cell defines" links cnt to the cell defining it (#285)', async (t) => {
  const notebook = path.join(tempDir("ember-e2e-in-place-"), "in-place.R");
  writeFileSync(notebook, [
    "### An Ember notebook ###", "# /// environment", '# ember_version = "0.0.0.9000"', '# r_version = "4.6.1"', '# snapshot = "2026-01-01"', "# ///", "",
    "# %% id=S", "",
    "# %% id=A", "cnt <- new.env()", "",
    "# %% id=B", 'assign("n", 1, envir = cnt)', "",
  ].join("\n"), "utf8");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-in-place-link.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  const note = page.locator(`${cellSelector("B")} ember-settings-note.in-place-note`);
  await note.waitFor({ timeout: 20000 });
  assert.match(await note.innerText(), /^Changed cnt in place, which another cell defines/);
  const link = note.locator("a");
  assert.equal(await link.innerText(), "cnt");
  await link.click();
  await page.waitForFunction(() => document.activeElement?.closest("pluto-cell")?.id === "A" && window.getSelection()?.toString() === "cnt",
    null, { timeout: 10000 }).catch(async () => assert.fail(`clicking cnt selects cnt's definition in A: ${JSON.stringify(await focused(page))}`));

  assertNoProblems(page);
});

// A name no single cell defines reaches th() as plain text, and th() parses
// a bare string as markup, so `a<b` once showed as "b" (#454 review).
test("chips: a plain-text name keeps characters th() would read as markup (#285)", async (t) => {
  const notebook = tempNotebook("lazy.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chips-plain-name.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  const shown = await page.evaluate(async () => {
    const { th } = await import("./common/lang.js");
    const { html, render } = await import("./imports/Preact.js");
    const { join_parts } = await import("./components/Cell.js");
    const out = {};
    for (const [label, parts] of [["one", ["a<b"]], ["two", ["a<b", "<i>q</i>"]], ["with a link", [html`<a href="#">x</a>`, "a<b"]]]) {
      const el = document.createElement("div");
      render(th("t_chip_stale_names", { names: join_parts(parts) }), el);
      out[label] = { text: el.textContent, markup: el.querySelectorAll("i, b").length };
    }
    return out;
  });
  assert.deepEqual(shown, {
    "one": { text: "Stale · a<b changed", markup: 0 },
    "two": { text: "Stale · a<b and <i>q</i> changed", markup: 0 },
    "with a link": { text: "Stale · x and a<b changed", markup: 0 },
  });
  assertNoProblems(page);
});

test("chips: a chip's text can't be selected, by double-click or by dragging across the cell (#285)", async (t) => {
  const notebook = tempNotebook("cells.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "cells-chip-select.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "A");
  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.classList.contains("not_run_yet"),
    cellSelector("NEVER"), { timeout: 20000 });
  await page.waitForSelector(`${cellSelector("A")} ember-runtime`, { state: "attached", timeout: 15000 });

  const chip = page.locator(`${cellSelector("NEVER")} > ember-chip`);
  await chip.scrollIntoViewIfNeeded();
  assert.equal(await chip.innerText(), "Not run yet");
  const selection = () => page.evaluate(() => window.getSelection().toString());

  // A double-click on the chip's words selects nothing.
  await page.locator(`${cellSelector("NEVER")} > ember-chip span:not(.ember-chip-icon)`).dblclick();
  assert.equal(await selection(), "", "double-clicking a chip selects none of its text");

  // A drag from the chip's row into the cell's code copies the code but
  // not the chip. This reads the clipboard, not getSelection(): Chromium's
  // Selection.toString() still lists user-select: none text that a copy
  // leaves out.
  const box = await chip.boundingBox();
  const cell = await page.locator(cellSelector("NEVER")).boundingBox();
  // Scrolling the chip into view swaps NEVER's static code copy for its
  // editor, so measure the editor.
  const code = await page.locator(`${cellSelector("NEVER")} .cm-editor:not(.cm-ssr-fake) .cm-content`).boundingBox();
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.mouse.move(cell.x + cell.width - 4, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(code.x + 2, code.y + code.height / 2, { steps: 8 });
  await page.mouse.up();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+C" : "Control+C");
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  assert.match(copied, /3 \+ 3/, "the drag reached NEVER's code");
  assert.doesNotMatch(copied, /Not run yet/, "a drag across the cell leaves the chip out");

  assertNoProblems(page);
});

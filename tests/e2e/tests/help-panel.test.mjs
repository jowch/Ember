// The Help tab follows the cursor only for names in code (ui-3.md, "Side
// panel"): prose in a text cell, a comment, or a selection that isn't a
// name never changes the query, and the cursor never pulls a page from an
// installed but unattached package. The page itself fits the panel
// (board Panel3, "Help").

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

const SELECT_ALL = process.platform === "darwin" ? "Meta+A" : "Control+A";

async function open_idle_notebook(t, logName) {
  const notebook = tempNotebook("help.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), logName) });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });
  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "C");
  await page.waitForFunction(() => {
    const nb = window.editor_state?.notebook;
    return nb?.process_status === "ready" && nb.cell_results?.C?.runtime != null &&
      Object.values(nb.cell_results).every((r) => !r.running && !r.queued);
  }, null, { timeout: 60000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "docs" })));
  return page;
}

/** Viewport coordinates of the character `offset` characters into the
 * first occurrence of `needle` in the live editor of cell `id`. */
async function point_in_cell(page, id, needle, offset = 0) {
  return await page.evaluate(([sel, needle, offset]) => {
    const content = document.querySelector(`${sel} .cm-editor:not(.cm-ssr-fake) .cm-content`);
    const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
    let full = "";
    const nodes = [];
    for (let n = walker.nextNode(); n != null; n = walker.nextNode()) {
      nodes.push([n, full.length]);
      full += n.data;
    }
    const at = full.indexOf(needle);
    if (at < 0) return null;
    const target = at + offset;
    for (const [n, start] of nodes) {
      if (target >= start && target < start + n.data.length) {
        const r = document.createRange();
        r.setStart(n, target - start);
        r.setEnd(n, target - start + 1);
        const b = r.getBoundingClientRect();
        return { x: b.left + b.width / 2, y: b.top + b.height / 2 };
      }
    }
    return null;
  }, [cellSelector(id), needle, offset]);
}

const help_query = (page) => page.locator("#live-docs-search").inputValue();
const help_text = (page) => page.locator("#helpbox-wrapper .ember-help-page").innerText();

async function show_mean_from_code(page) {
  const p = await point_in_cell(page, "C", "mean(c(", 1);
  await page.mouse.click(p.x, p.y);
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.includes("Arithmetic Mean"),
    null, { timeout: 15000 });
  assert.equal(await help_query(page), "mean");
}

/** Lets a docs request the last action may have sent come back. */
const settle = (page) => page.waitForTimeout(1500);

test("help: a text cell, a #' line, a comment and a non-name selection never change the query", { timeout: 120000 }, async (t) => {
  const page = await open_idle_notebook(t, "help-text-query.server.log");
  await show_mean_from_code(page);

  // Open the text cell for editing, then select all of it.
  await page.locator(`${cellSelector("T")} pluto-output`).click();
  await page.waitForSelector(`${cellSelector("T")} .cm-editor:not(.cm-ssr-fake) .cm-content`, { timeout: 10000 });
  await page.locator(`${cellSelector("T")} .cm-editor:not(.cm-ssr-fake) .cm-content`).click();
  await page.keyboard.press(SELECT_ALL);
  await settle(page);
  assert.equal(await help_query(page), "mean", "select-all in a text cell");

  // A name-shaped word on a #' line, double-clicked and then with the
  // cursor resting in it.
  const lm = await point_in_cell(page, "T", "with lm", 6);
  await page.mouse.dblclick(lm.x, lm.y);
  await settle(page);
  assert.equal(await help_query(page), "mean", "double-clicking lm on a #' line");
  await page.mouse.click(lm.x, lm.y);
  await settle(page);
  assert.equal(await help_query(page), "mean", "the cursor on a #' line");

  // In a code cell: a word in a comment, and a selection over two lines.
  await page.keyboard.press("Escape");
  const comment_mean = await point_in_cell(page, "C", "the mean", 5);
  await page.mouse.dblclick(comment_mean.x, comment_mean.y);
  await settle(page);
  assert.equal(await help_query(page), "mean", "double-clicking a word in a comment");
  const from = await point_in_cell(page, "C", "x <- mean");
  const to = await point_in_cell(page, "C", "lm(mpg", 1);
  await page.mouse.click(from.x, from.y);
  await page.keyboard.down("Shift");
  await page.mouse.click(to.x, to.y);
  await page.keyboard.up("Shift");
  await settle(page);
  assert.equal(await help_query(page), "mean", "a two-line selection in code");

  assert.match(await help_text(page), /Arithmetic Mean/);

  // Typing in a comment doesn't open completions; Ctrl+Space still does.
  const comment_end = await point_in_cell(page, "C", "the mean", 7);
  await page.mouse.click(comment_end.x, comment_end.y);
  await page.keyboard.press("End");
  await page.keyboard.type(" cle", { delay: 30 });
  await page.waitForTimeout(1000);
  assert.equal(await page.locator(".cm-tooltip-autocomplete").count(), 0, "no completions while typing in a comment");
  await page.keyboard.press("Control+Space");
  await page.waitForSelector(".cm-tooltip-autocomplete", { timeout: 5000 });
  await page.keyboard.press("Escape");
  assertNoProblems(page);
});

test("help: double-clicking a word in text shows no mgcv page; the cursor finds only attached packages", { timeout: 120000 }, async (t) => {
  const page = await open_idle_notebook(t, "help-mgcv.server.log");
  await show_mean_from_code(page);

  await page.locator(`${cellSelector("T")} pluto-output`).click();
  await page.waitForSelector(`${cellSelector("T")} .cm-editor:not(.cm-ssr-fake) .cm-content`, { timeout: 10000 });
  const s = await point_in_cell(page, "T", "Let's", 4);
  await page.mouse.dblclick(s.x, s.y);
  await settle(page);
  assert.doesNotMatch(await help_text(page), /mgcv/);
  assert.equal(await help_query(page), "mean");
  await page.keyboard.press("Escape");

  // `s` in code: the cursor asks for it, but only attached packages
  // count, so mgcv's `s` (installed, never attached) isn't shown.
  const s_call = await point_in_cell(page, "G", "s(wt)", 0);
  await page.mouse.click(s_call.x + 2, s_call.y);
  await page.waitForFunction(() => document.querySelector("#live-docs-search")?.value === "s", null, { timeout: 5000 });
  await settle(page);
  assert.doesNotMatch(await help_text(page), /mgcv/);
  assert.match(await help_text(page), /Arithmetic Mean/);

  // A typed search still looks through every installed package.
  await page.locator("#live-docs-search").fill("lm");
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.includes("Fitting Linear Models"),
    null, { timeout: 15000 });
  await page.locator("#live-docs-search").fill("s");
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page")?.innerText.includes("mgcv"),
    null, { timeout: 15000 });
  assertNoProblems(page);
});

test("help: the page fits the panel, is padded, and has no Rd header table or query heading", { timeout: 120000 }, async (t) => {
  const page = await open_idle_notebook(t, "help-layout.server.log");
  const p = await point_in_cell(page, "C", "lm(mpg", 1);
  await page.mouse.click(p.x, p.y);
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page h2")?.innerText === "Fitting Linear Models",
    null, { timeout: 15000 });

  const m = await page.evaluate(() => {
    const panel = document.querySelector("pluto-helpbox").getBoundingClientRect();
    const tabpanel = document.querySelector("pluto-helpbox > section");
    const page_el = document.querySelector(".ember-help-page");
    const main = page_el.querySelector("main").getBoundingClientRect();
    const cs = getComputedStyle(page_el);
    const args_row = page_el.querySelector('table[role="presentation"] tr');
    return {
      panel_left: panel.left, panel_right: panel.right,
      main_left: main.left, main_right: main.right,
      overflow: tabpanel.scrollWidth - tabpanel.clientWidth,
      padding: [cs.paddingTop, cs.paddingRight, cs.paddingBottom, cs.paddingLeft],
      header_tables: Array.from(page_el.querySelectorAll("table")).filter((tb) => tb.innerText.includes("R Documentation")).length,
      h1s: page_el.querySelectorAll("h1").length,
      h2_size: getComputedStyle(page_el.querySelector("h2")).fontSize,
      args_columns: getComputedStyle(args_row).gridTemplateColumns,
      usage_wrap: getComputedStyle(page_el.querySelector("pre")).whiteSpace,
      package_line: page_el.querySelector(".ember-help-package")?.innerText,
    };
  });
  assert.ok(m.main_left >= m.panel_left + 16 - 0.5, `help main starts inside the panel's padding (${m.main_left} vs ${m.panel_left})`);
  assert.ok(m.main_right <= m.panel_right - 16 + 0.5, `help main ends inside the panel (${m.main_right} vs ${m.panel_right})`);
  assert.equal(m.overflow, 0, "no horizontal overflow");
  assert.deepEqual(m.padding, ["14px", "16px", "14px", "16px"]);
  assert.equal(m.header_tables, 0, "no 'R Documentation' header table");
  assert.equal(m.h1s, 0, "no query h1 once a page loaded");
  assert.equal(m.h2_size, "20px");
  assert.match(m.args_columns, /^90px \d/);
  assert.equal(m.usage_wrap, "pre-wrap");
  assert.equal(m.package_line, "stats · follows the cursor");
  assertNoProblems(page);
});

// The UI sweep: one notebook with one of each kind of output
// (fixtures/ui-sweep.R), in each state a person sees it in, at three
// widths, checked against layout-check.mjs's generic rules. The other
// tests check one thing each at 1200 x 800; this one checks every control
// on the page for being clipped, covered, off screen or under an overlay
// scrollbar, so a layout regression nobody wrote a test for still fails.
//
// Widths: 600 and 900 are Endeavor's notebook pane next to its chat;
// 1440 opens the side panel (with Help open on a long page, #433). The ⌘ S and Ctrl+S shortcut labels differ
// in size (#290), so the edited state runs under both.
//
// A problem that's a known, open bug goes in KNOWN with its issue, so the
// sweep stays green while it's open. Remove the entry in the PR that
// fixes it; a KNOWN entry that no longer matches is printed as stale.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { writeFileSync } from "node:fs";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, setCellCode, runCell } from "../browser.mjs";
import { pageProblems, emulatePlatform, formatProblems } from "../layout-check.mjs";

const WIDTHS = [600, 900, 1440];

/** Known open bugs: { rule, where (a substring of the problem's where),
 * detail (optional, a substring of its detail), issue }. */
const KNOWN = [
  // The floating "Run all changed" button covers a scrolled cell's menu.
  { rule: "covered", where: "button.input_context_menu", detail: "by preamble > div#saveall-container", issue: 456 },
];
const used = new Set();

/** Check the page at each width (and in dark mode at 900), save a
 * screenshot of each, and fail on any problem not in KNOWN. */
async function sweep(page, label) {
  const found = [];
  const shots = [...WIDTHS.map((w) => [w, "light"]), [900, "dark"]];
  for (const [width, scheme] of shots) {
    await page.emulateMedia({ colorScheme: scheme });
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(300);
    const name = `ui-sweep-${label}-${width}-${scheme}`;
    await page.screenshot({ path: path.join(artifactsDir(), name + ".png"), fullPage: true });
    for (const p of await pageProblems(page)) {
      const known = KNOWN.find((k) => k.rule === p.rule && p.where.includes(k.where) && p.detail.includes(k.detail ?? ""));
      if (known) used.add(known);
      else found.push({ ...p, at: `${width} ${scheme}` });
    }
  }
  await page.emulateMedia({ colorScheme: "light" });
  if (found.length) {
    writeFileSync(path.join(artifactsDir(), `ui-sweep-${label}.json`), JSON.stringify(found, null, 2));
  }
  assert.deepEqual(found, [], `layout problems in "${label}" (screenshots in tests/e2e/test-results/):\n` +
    found.map((p) => formatProblems([p]) + `  (at ${p.at})`).join("\n"));
}

test("ui sweep: safe preview, run, and edited with both shortcut labels", async (t) => {
  const notebook = tempNotebook("ui-sweep.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ui-sweep.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await emulatePlatform(page, "other");
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview").waitFor({ state: "visible" });
  await sweep(page, "preview");

  await page.locator("#ember-safe-preview button").click();
  await page.waitForSelector(`${cellSelector("ERR")} jlerror`, { timeout: 60000 });
  await page.waitForSelector(`${cellSelector("WIDE")} .ember-table-more`, { timeout: 30000 });
  await page.waitForSelector(`${cellSelector("PLT")} pluto-output img`, { timeout: 30000 });
  await page.waitForFunction(() => document.querySelectorAll("pluto-cell.running, pluto-cell.queued").length === 0,
    null, { timeout: 30000 });
  await sweep(page, "ran");

  for (const platform of ["other", "mac"]) {
    const p = platform === "other" ? page : await newPage(browser);
    if (p !== page) {
      await emulatePlatform(p, platform);
      await openNotebook(p, server.origin, server.secret, notebook);
    }
    await setCellCode(p, "B", "sum(x) + 1");
    await p.waitForSelector("#saveall-container.ask_to_save", { timeout: 10000 });
    await sweep(p, `edited-${platform}`);
    assertNoProblems(p);
  }
});

// #284: cells that haven't run show "Not run yet" on load, the first cell
// as much as any other. Running B allows execution without running the
// rest, and a reload is the "on load" part.
test("ui sweep: partly run, after a reload", async (t) => {
  const notebook = tempNotebook("ui-sweep.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ui-sweep-partial.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);
  await runCell(page, "B");
  await page.waitForFunction((sel) => document.querySelector(sel)?.innerText.includes("55"),
    cellSelector("B") + " pluto-output", { timeout: 60000 });
  await page.reload();
  await page.waitForSelector("pluto-cell", { timeout: 30000 });
  await page.waitForFunction(() => !document.querySelector("pluto-editor")?.classList.contains("loading"),
    null, { timeout: 30000 });
  // Chips settle in after a moment (Cell.js's useSettled).
  await page.waitForSelector(`${cellSelector("DOWN")} ember-chip:not(.held)`, { timeout: 10000 });
  await sweep(page, "partial");
  assertNoProblems(page);
});

// #433: the Help tab open on a long page. At 1240 and up the panel docks,
// and the notebook column's docked margin once reached the help page's own
// <main> (Rd2HTML's), widening it past the panel. The checker sees a link
// cut off; the page's own width is checked too, since a clipped paragraph
// has no control to flag.
test("ui sweep: the Help tab open on a long page, docked and not (#433)", async (t) => {
  const notebook = tempNotebook("ui-sweep.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "ui-sweep-help.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await emulatePlatform(page, "other");
  await openNotebook(page, server.origin, server.secret, notebook);
  await page.locator("#ember-safe-preview button").click();
  await page.waitForFunction(() => {
    const nb = window.editor_state?.notebook;
    return nb?.process_status === "ready" && Object.values(nb.cell_results ?? {}).length > 0 &&
      Object.values(nb.cell_results).every((r) => !r.running && !r.queued);
  }, null, { timeout: 60000 });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent("open_bottom_right_panel", { detail: "docs" })));
  await page.locator("#live-docs-search").fill("regmatches");
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper .ember-help-page h2")?.innerText.includes("Matched Substrings"),
    null, { timeout: 30000 });
  await sweep(page, "help");

  for (const width of [1240, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(300);
    const fit = await page.evaluate(() => {
      const panel = document.querySelector("#helpbox-wrapper").getBoundingClientRect();
      const main = document.querySelector("#helpbox-wrapper .ember-help-page main").getBoundingClientRect();
      return { panel: [panel.left, panel.right], main: [main.left, main.right], margin: getComputedStyle(document.querySelector("#helpbox-wrapper .ember-help-page main")).marginRight };
    });
    assert.ok(fit.main[0] >= fit.panel[0] && fit.main[1] <= fit.panel[1] && fit.margin === "0px",
      `at ${width} the help page fits its panel: ${JSON.stringify(fit)}`);
  }
  assertNoProblems(page);
});

test("ui sweep: KNOWN entries still match something", () => {
  // Runs last in this file (node:test runs a file's tests in order).
  const stale = KNOWN.filter((k) => !used.has(k));
  if (stale.length) {
    console.log("ui-sweep: these KNOWN entries no longer match; remove them if their issue is fixed:\n" +
      stale.map((k) => `  #${k.issue} [${k.rule}] ${k.where}`).join("\n"));
  }
});

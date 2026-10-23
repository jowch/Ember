// The UI sweep: one notebook with one of each kind of output
// (fixtures/ui-sweep.R), in each state a person sees it in, at three
// widths, checked against layout-check.mjs's generic rules. The other
// tests check one thing each at 1200 x 800; this one checks every control
// on the page for being clipped, covered, off screen or under an overlay
// scrollbar, so a layout regression nobody wrote a test for still fails.
//
// Widths: 600 and 900 are Endeavor's notebook pane next to its chat;
// 1440 opens the side panel. The ⌘ S and Ctrl+S shortcut labels differ
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
 * issue }. */
const KNOWN = [];
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
      const known = KNOWN.find((k) => k.rule === p.rule && p.where.includes(k.where));
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

test("ui sweep: KNOWN entries still match something", () => {
  // Runs last in this file (node:test runs a file's tests in order).
  const stale = KNOWN.filter((k) => !used.has(k));
  if (stale.length) {
    console.log("ui-sweep: these KNOWN entries no longer match; remove them if their issue is fixed:\n" +
      stale.map((k) => `  #${k.issue} [${k.rule}] ${k.where}`).join("\n"));
  }
});

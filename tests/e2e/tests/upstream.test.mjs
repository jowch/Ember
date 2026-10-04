// ui-3-tests.md test 14 (piece 1a, "Errors flow downstream"): a cell that
// reads a failed cell's name shows "Another cell defining a contains
// errors.", with no traceback button, and a link that scrolls to the
// failed cell. A cell with no edge to the failed one runs normally. No
// element reads "upstream error" (the old blocked-cell wording is gone).

import { test } from "node:test";
import path from "node:path";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

/** `true` when every point of `sel`'s bounding box is inside the current
 * viewport, `false` when it's fully or partly outside. */
async function isInViewport(page, sel) {
  return page.evaluate((s) => {
    const r = document.querySelector(s)?.getBoundingClientRect();
    return r != null && r.top >= 0 && r.bottom <= window.innerHeight;
  }, sel);
}

test("upstream: a dependent names the failed cell and links to it; an unrelated cell runs (14)", async (t) => {
  const notebook = tempNotebook("upstream.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "upstream.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  // A short viewport (tall enough for one cell, too short for all 4), so
  // scrolling to the last cell genuinely pushes A off screen.
  await page.setViewportSize({ width: 1200, height: 300 });
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.locator("#ember-safe-preview button").click();

  await page.waitForSelector(`${cellSelector("A")} jlerror`, { timeout: 20000 });
  const a_text = await page.locator(`${cellSelector("A")} jlerror`).innerText();
  assert.match(a_text, /boom/);

  await page.waitForSelector(`${cellSelector("B")} jlerror`, { timeout: 20000 });
  const b_error = page.locator(`${cellSelector("B")} jlerror`);
  const b_text = await b_error.innerText();
  assert.equal(b_text, "Another cell defining a contains errors.");
  assert.equal(await b_error.locator("button").count(), 0, "no traceback button for an upstream error");
  // Board Cells: the sentence in italic at normal weight, the name a mono
  // link, upright.
  const sentence = b_error.locator("header > p:first-child");
  assert.equal(await sentence.locator("em").evaluate((el) => getComputedStyle(el).fontStyle), "italic");
  assert.equal(await sentence.evaluate((el) => getComputedStyle(el).fontWeight), "400");
  assert.equal(await sentence.locator("a").evaluate((el) => getComputedStyle(el).fontStyle), "normal");
  assert.match(await sentence.locator("a").evaluate((el) => getComputedStyle(el).fontFamily), /^"?IBM Plex Mono/);

  const link = b_error.locator("header a", { hasText: "a" });
  assert.equal(await link.count(), 1);

  await page.locator(`${cellSelector("C")} .cm-content`).scrollIntoViewIfNeeded();
  assert.equal(await isInViewport(page, cellSelector("A")), false, "A is scrolled out of view");

  await link.click();
  await page.waitForFunction((sel) => {
    const r = document.querySelector(sel)?.getBoundingClientRect();
    return r != null && r.top >= 0 && r.bottom <= window.innerHeight;
  }, cellSelector("A"), { timeout: 20000 });
  assert.equal(await isInViewport(page, cellSelector("A")), true, "clicking the link brings A back into view");

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("C") + " pluto-output", { timeout: 20000 });

  const body_text = await page.locator("body").innerText();
  assert.doesNotMatch(body_text, /upstream error/i);

  assertNoProblems(page);
});

// ui-3-tests.md test 14 (piece 1a, "Errors flow downstream"): a cell that
// reads a failed cell's name shows "Another cell defining a contains
// errors.", with no traceback button, and a link that scrolls to the
// failed cell. A cell with no edge to the failed one runs normally. No
// element reads "upstream error" (the old blocked-cell wording is gone).

import { test } from "node:test";
import path from "node:path";
import assert from "node:assert/strict";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, runCell, cellSelector } from "../browser.mjs";

test("upstream: a dependent names the failed cell and links to it; an unrelated cell runs (14)", async (t) => {
  const notebook = tempNotebook("upstream.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "upstream.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await runCell(page, "B"); // also runs the setup cell and A, its ancestor
  await runCell(page, "C"); // no edge to A: runs on its own

  await page.waitForSelector(`${cellSelector("A")} jlerror`, { timeout: 20000 });
  const a_text = await page.locator(`${cellSelector("A")} jlerror`).innerText();
  assert.match(a_text, /boom/);

  await page.waitForSelector(`${cellSelector("B")} jlerror`, { timeout: 20000 });
  const b_error = page.locator(`${cellSelector("B")} jlerror`);
  const b_text = await b_error.innerText();
  assert.match(b_text, /Another cell defining a contains errors\./);
  assert.equal(await b_error.locator(".stacktrace-waiting-to-view").count(), 0,
    "no traceback button: the upstream error carries no stacktrace");

  const link = b_error.locator("header a", { hasText: "a" });
  assert.equal(await link.count(), 1);

  // Scroll A out of view, then follow the link and check it comes back.
  await page.evaluate((sel) => document.querySelector(sel)?.scrollIntoView({ block: "end" }),
    `${cellSelector("C")} .cm-content`);
  await link.click();
  await page.waitForFunction((sel) => {
    const r = document.querySelector(sel)?.getBoundingClientRect();
    return r != null && r.top >= 0 && r.bottom <= window.innerHeight;
  }, cellSelector("A"), { timeout: 20000 });

  await page.waitForFunction(
    (sel) => document.querySelector(sel)?.innerText.includes("2"),
    cellSelector("C") + " pluto-output", { timeout: 20000 });

  const body_text = await page.locator("body").innerText();
  assert.doesNotMatch(body_text, /upstream error/i);

  assertNoProblems(page);
});

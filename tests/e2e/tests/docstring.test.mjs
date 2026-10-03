// Help for a notebook-defined function shows its signature and comment
// doc, with a "Go to it" link that scrolls its cell into view (ui-3-tests.md 61).

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector } from "../browser.mjs";

test("docstring: Help shows a notebook function's signature, doc and a working Go to it link (61)", async (t) => {
  const notebook = tempNotebook("docstring.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "docstring.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  await page.hover(cellSelector("FN"));
  await page.locator(`${cellSelector("FN")} button.add_cell.after`).click({ force: true });
  const newCellId = await page.evaluate((bid) => {
    const cells = Array.from(document.querySelectorAll("pluto-cell"));
    const i = cells.findIndex((c) => c.id === bid);
    return cells[i + 1]?.id ?? null;
  }, "FN");
  assert.ok(newCellId, "a new cell was inserted right after FN");
  const newSel = `pluto-cell[id="${newCellId}"]`;

  await page.locator(`${newSel} .cm-content`).click();
  await page.keyboard.type("clean", { delay: 10 });
  await page.keyboard.press("Escape"); // close any autocomplete popup first

  await page.locator("button.helpbox-docs").click();
  await page.waitForFunction(
    () => document.querySelector("#helpbox-wrapper")?.innerText.includes("Drop rows with a missing value."),
    null, { timeout: 15000 });

  const helpText = await page.locator("#helpbox-wrapper").innerText();
  assert.match(helpText, /clean\(df\)/);
  assert.match(helpText, /Go to it/);

  // Scroll FN out of view, then click the link and confirm it comes back.
  await page.evaluate(() => document.querySelector('pluto-cell[id="S"]').scrollIntoView());
  await page.locator("#helpbox-wrapper a", { hasText: "Go to it" }).click();
  await page.waitForFunction(
    (sel) => {
      const r = document.querySelector(sel)?.getBoundingClientRect();
      return r != null && r.top >= 0 && r.top < window.innerHeight;
    },
    cellSelector("FN"), { timeout: 10000 });

  assertNoProblems(page);
});

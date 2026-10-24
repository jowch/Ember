// #357: a cell that reads globals by a computed name (`get(s)`) has no edge
// to the cell that makes them, so it doesn't rerun when they change. The
// cell says so, from its code alone: in safe preview and after a run. A
// literal `get("site_A")` is an ordinary reference and gets no note.

import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { startServer, tempNotebook, artifactsDir } from "../server.mjs";
import { launchBrowser, newPage, assertNoProblems, openNotebook, cellSelector, waitIdle } from "../browser.mjs";

test("a cell that reads globals through get() on a computed name says Ember can't track them (#357)", async (t) => {
  const notebook = tempNotebook("untracked.R");
  const server = await startServer([notebook], { logFile: path.join(artifactsDir(), "untracked.server.log") });
  const browser = await launchBrowser();
  t.after(async () => { await browser.close(); server.stop(); });

  const page = await newPage(browser);
  await openNotebook(page, server.origin, server.secret, notebook);

  const note = `${cellSelector("B")} ember-settings-note.untracked-note`;
  const text = "Ember can't tell which variables this cell reads through get(), so it doesn't rerun when they change. " +
    "Name the variables in the code, or keep the values in one list.";
  await page.waitForSelector(note);
  assert.equal(await page.locator(note).innerText(), text, "shown in safe preview, before anything runs");
  for (const id of ["N", "A", "L"]) {
    assert.equal(await page.locator(`${cellSelector(id)} ember-settings-note`).count(), 0, `no note on ${id}`);
  }

  await page.locator("#ember-safe-preview button").click();
  await waitIdle(page);
  assert.equal(await page.locator(note).innerText(), text, "still there after the run");
  assert.equal(await page.locator(`${cellSelector("L")} ember-settings-note`).count(), 0, "no note on L after the run");

  assertNoProblems(page);
});
